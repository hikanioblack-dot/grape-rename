import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

private final class DuplicateCancellationResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ value: Bool) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor
func runDuplicateTests() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("Grape-duplicates-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let nested = root.appendingPathComponent("nested")
    try fm.createDirectory(at: nested, withIntermediateDirectories: true)
    let a = root.appendingPathComponent("A.bin"), b = root.appendingPathComponent("B.copy")
    let bytes = Data((0..<(DuplicateEngine.chunkSize * 2 + 73)).map { UInt8($0 % 251) })
    try bytes.write(to: a); try bytes.write(to: b)
    var different = bytes; different[different.count - 1] ^= 0xFF
    try different.write(to: root.appendingPathComponent("C.bin"))
    try Data().write(to: root.appendingPathComponent("empty-a"))
    try Data().write(to: root.appendingPathComponent("empty-b"))
    try Data("same".utf8).write(to: root.appendingPathComponent("top.txt"))
    try Data("same".utf8).write(to: nested.appendingPathComponent("child.txt"))
    try Data("same".utf8).write(to: root.appendingPathComponent(".hidden.txt"))
    try fm.createSymbolicLink(at: root.appendingPathComponent("symlink.bin"), withDestinationURL: a)
    try fm.linkItem(at: a, to: root.appendingPathComponent("hardlink.bin"))
    let originalStamp = try FileStamp(a)
    let exact = try DuplicateEngine.scan([root, a], recursive: false, mode: .exact, similarity: .balanced)
    guard exact.groups.count == 2, exact.groups.allSatisfy({ $0.files.count == 2 }),
          exact.skippedLinks == 1, exact.warnings.isEmpty else { throw RenameError.message("Exact duplicate filtering failed: \(exact)") }
    guard !exact.groups.flatMap(\.files).contains(where: { ["C.bin", ".hidden.txt", "child.txt"].contains($0.url.lastPathComponent) }) else {
        throw RenameError.message("Same-size non-duplicate or hidden file incorrectly grouped")
    }
    let recursive = try DuplicateEngine.scan([root], recursive: true, mode: .exact, similarity: .balanced)
    guard recursive.groups.count == 3 else { throw RenameError.message("Recursive duplicate scan failed: \(recursive)") }
    guard try FileStamp(a) == originalStamp, try Data(contentsOf: a) == bytes else { throw RenameError.message("Scanning changed file contents or dates") }
    let known = root.appendingPathComponent("known.txt")
    try Data("abc".utf8).write(to: known)
    let knownFile = DuplicateFile(url: known, stamp: try FileStamp(known))
    guard try DuplicateEngine.digest(knownFile) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" else {
        throw RenameError.message("SHA-256 known vector failed")
    }
    // Catch a change during streaming, not just at the beginning of the scan.
    var changed = false, changeRejected = false
    do {
        _ = try DuplicateEngine.digest(DuplicateFile(url: b, stamp: try FileStamp(b))) { _ in
            if !changed {
                changed = true
                if let writer = try? FileHandle(forWritingTo: b) { _ = try? writer.seekToEnd(); try? writer.write(contentsOf: Data([42])); try? writer.close() }
            }
        }
    } catch { changeRejected = true }
    guard changeRejected else { throw RenameError.message("Changing-file hash guard failed") }
    // A cancelled background search must stop without delivering partial matches.
    let done = DispatchSemaphore(value: 0)
    let cancelled = DuplicateCancellationResult()
    let task = Task.detached {
        while !Task.isCancelled { await Task.yield() }
        do { _ = try DuplicateEngine.scan([root], recursive: true, mode: .exact, similarity: .balanced) }
        catch is CancellationError { cancelled.set(true) }
        catch {}
        done.signal()
    }
    task.cancel()
    guard done.wait(timeout: .now() + 10) == .success, cancelled.get() else { throw RenameError.message("Duplicate search cancellation failed") }

    let imageRoot = root.appendingPathComponent("photos")
    try fm.createDirectory(at: imageRoot, withIntermediateDirectories: true)
    let original = imageRoot.appendingPathComponent("Original.jpg"), resized = imageRoot.appendingPathComponent("Resized.jpg")
    try TestFixtures.image(original, type: .jpeg, color: (0.3, 0.48, 0.78), date: "2024:06:15 08:09:10")
    guard let source = CGImageSourceCreateWithURL(original as CFURL, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 300] as CFDictionary),
          let destination = CGImageDestinationCreateWithURL(resized as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else { throw RenameError.message("Similarity fixture setup failed") }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.45] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw RenameError.message("Resized photo fixture failed") }
    let unrelated = imageRoot.appendingPathComponent("Pattern.png")
    let context = CGContext(data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 400 * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for y in 0..<20 { for x in 0..<20 {
        let value = CGFloat((x * 73 + y * 37) % 251) / 251
        context.setFillColor(CGColor(red: value, green: CGFloat((x + y) % 2), blue: 1 - value, alpha: 1))
        context.fill(CGRect(x: x * 20, y: y * 20, width: 20, height: 20))
    } }
    let patternDestination = CGImageDestinationCreateWithURL(unrelated as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(patternDestination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(patternDestination) else { throw RenameError.message("Pattern fixture failed") }
    try Data("invalid JPEG".utf8).write(to: imageRoot.appendingPathComponent("Broken.jpg"))
    try Data("not an image".utf8).write(to: imageRoot.appendingPathComponent("Notes.txt"))
    let imageStamp = try FileStamp(original)
    let visual = try DuplicateEngine.scan([imageRoot], recursive: true, mode: .similar, similarity: .strict)
    guard visual.groups.count == 1,
          Set(visual.groups[0].files.map(\.url)) == Set([original, resized]),
          visual.warnings.count == 1 else { throw RenameError.message("Similar-photo grouping failed: \(visual)") }
    let imageExact = try DuplicateEngine.scan([original, resized], recursive: false, mode: .exact, similarity: .balanced)
    guard imageExact.groups.isEmpty else { throw RenameError.message("Recompressed photo incorrectly treated as exact duplicate") }
    guard try FileStamp(original) == imageStamp else { throw RenameError.message("Vision changed image timestamps") }

    let model = Model(storageURL: root.appendingPathComponent("state.json"))
    model.load([original, resized], folder: false)
    let ui = DuplicateSearch(files: model.files)
    ui.report = exact
    for group in exact.groups { ui.keep(group.files.last!, in: group) }
    ui.selectCopies()
    guard ui.selectedFiles.count == exact.groups.count,
          exact.groups.allSatisfy({ group in
              ui.selectedFiles.filter { file in group.files.contains(where: { $0.id == file.id }) }.count == group.files.count - 1
                  && !ui.selection.contains(group.files.last!.id)
          }) else { throw RenameError.message("All copies must preserve the chosen keeper in every group") }
    ui.selection = []
    ui.keepers = [:]
    ui.report = visual
    let group = visual.groups[0]
    ui.keepers = [group.id: group.files[0].id]
    ui.selectCopies()
    guard ui.selectedFiles.count == 1, !ui.selection.contains(group.files[0].id) else { throw RenameError.message("Keep-one protection failed") }
    ui.selection = Set(group.files.map(\.id))
    guard ui.selectedFiles.count == 1, !ui.selectedFiles.contains(where: { $0.id == group.files[0].id }) else {
        throw RenameError.message("Protected file must remain excluded from actions even if selection state contains it")
    }
    ui.keep(group.files[1], in: group)
    guard !ui.selection.contains(group.files[1].id) else { throw RenameError.message("Changing kept file did not clear selection") }
    ui.selectCopies(); ui.exclude(from: model)
    guard model.files.count == 1, fm.fileExists(atPath: original.path), fm.fileExists(atPath: resized.path) else {
        throw RenameError.message("Exclude must not delete files")
    }
    model.reset()
    guard model.files.isEmpty, model.origin.isEmpty else { throw RenameError.message("Empty main window reset failed") }
    print("PASS: streamed SHA-256 and byte comparison; equal-size nonmatches; empty files; recursion; hidden/symbolic/hard links; cancellation; changing-file guard; perceptual hash + Vision resized/recompressed photos vs unrelated image; corrupt image warnings; keep-one protection; exclusion without deletion.")
}
