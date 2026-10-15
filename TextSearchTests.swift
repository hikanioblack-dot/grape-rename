import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

extension TestFixtures {
    static func textImage(_ url: URL, lines: [String]) throws {
        let width = 1400, height = 900
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw RenameError.message("Text fixture context failed")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.textMatrix = .identity
        for (index, line) in lines.enumerated() {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 44, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ]
            context.textPosition = CGPoint(x: 60, y: height - 110 - index * 90)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attributes)), context)
        }
        let type: UTType = url.pathExtension == "jpg" ? .jpeg : .png
        guard let image = context.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { throw RenameError.message("Text fixture image failed") }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw RenameError.message("Text fixture export failed") }
    }
    static func createTextSamples(at root: URL) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: root.path) else { throw RenameError.message(L("Тестовая папка уже существует.", "The test folder already exists.")) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try textImage(root.appendingPathComponent("Chat screenshot.png"), lines: [
            "Grape Rename local text search", "Meeting tomorrow at eleven", "Bring the camera and the tickets",
            "This image has no camera metadata", "Привет! Проверка текста на картинке", "Встреча завтра в одиннадцать"
        ])
        try textImage(root.appendingPathComponent("Document photo.jpg"), lines: [
            "TRAVEL NOTES", "Reservation number GRAPE2048", "Departure tomorrow at eleven",
            "Keep this document for your journey", "Билеты и документы готовы"
        ])
        try textImage(root.appendingPathComponent("Small sign.png"), lines: ["CAFE OPEN"])
        try image(root.appendingPathComponent("Landscape.jpg"), type: .jpeg, color: (0.25, 0.47, 0.80))
        try textImage(root.appendingPathComponent("Blank.png"), lines: [])
        try Data("Grape Rename OCR demo. All files are synthetic. Try With Text, Lots of Text, No Text Detected; search for Meeting, GRAPE2048 or Привет. No image has capture-date EXIF.\n".utf8).write(to: root.appendingPathComponent("Read Me.txt"))
    }
}

@MainActor
func runImageTextTests() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("Grape-OCR-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let samples = root.appendingPathComponent("images"), cache = root.appendingPathComponent("cache")
    try TestFixtures.createTextSamples(at: samples)
    let textURL = samples.appendingPathComponent("Chat screenshot.png")
    let stamp = try FileStamp(textURL), originalBytes = try Data(contentsOf: textURL)
    try Data("not an image".utf8).write(to: samples.appendingPathComponent("Broken.png"))
    let report = try ImageTextEngine.scan([samples], recursive: false, cache: cache)
    guard report.images.count == 5, report.warnings.count == 1, report.skipped == 1,
          let image = report.images.first(where: { $0.file.url == textURL }),
          image.content.text.localizedCaseInsensitiveContains("Meeting"),
          image.content.text.localizedCaseInsensitiveContains("Привет"),
          image.content.lines.count >= 5,
          report.images.first(where: { $0.file.url.lastPathComponent == "Blank.png" })?.content.lines.isEmpty == true else {
        throw RenameError.message("OCR failed: \(report.images.map { ($0.file.url.lastPathComponent, $0.content.text) }) / \(report.warnings)")
    }
    guard try FileStamp(textURL) == stamp, try Data(contentsOf: textURL) == originalBytes else { throw RenameError.message("OCR changed image contents or timestamps") }
    let repeated = try ImageTextEngine.scan([samples], recursive: false, cache: cache)
    guard repeated.cacheHits == 5 else { throw RenameError.message("OCR cache was not reused") }
    let uncached = try ImageTextEngine.recognize(image.file, cache: nil)
    guard !uncached.1, uncached.0.text == image.content.text else { throw RenameError.message("Uncached recognition differs") }
    let model = Model(storageURL: root.appendingPathComponent("state.json"))
    model.load([samples], folder: true)
    let search = ImageTextSearch(files: model.files)
    search.report = report; search.refreshFilter()
    guard search.filtered.count == 3 else { throw RenameError.message("With-text filter failed") }
    search.filter = .muchText; search.refreshFilter()
    guard search.filtered.count == 2 else { throw RenameError.message("Text-density filter failed") }
    search.minimumCharacters = 1000; search.refreshFilter()
    guard search.filtered.isEmpty else { throw RenameError.message("Text threshold ignored") }
    search.filter = .withText; search.query = "mEeTiNg"; search.refreshFilter()
    guard search.filtered.count == 1 else { throw RenameError.message("Case-insensitive OCR query failed") }
    search.selection = Set(report.images.map(\.id)); search.refreshFilter()
    guard search.selectedFiles.count == 1 else { throw RenameError.message("Hidden search results must not be selected for actions") }
    let snapshot = search.selectedFiles
    search.query = "GRAPE2048"; search.refreshFilter()
    guard search.selection.isEmpty, snapshot.count == 1, snapshot[0].url == textURL else { throw RenameError.message("Action snapshot or filter selection failed") }
    search.query = ""; search.filter = .withoutText; search.refreshFilter()
    guard search.filtered.count == 2 else { throw RenameError.message("No-text filter failed") }
    let copyFolder = root.appendingPathComponent("copies"), moveFolder = root.appendingPathComponent("moved")
    try fm.createDirectory(at: copyFolder, withIntermediateDirectories: true)
    try fm.createDirectory(at: moveFolder, withIntermediateDirectories: true)
    let copy = ImageTextFiles.apply(.copy(copyFolder), files: [image.file])
    guard copy.succeeded == 1, copy.removed.isEmpty, try Data(contentsOf: copyFolder.appendingPathComponent(textURL.lastPathComponent)) == originalBytes,
          try FileStamp(textURL) == stamp else { throw RenameError.message("OCR result copy changed source") }
    let collision = ImageTextFiles.apply(.copy(copyFolder), files: [image.file])
    guard collision.succeeded == 0, collision.failures.count == 1 else { throw RenameError.message("Export overwrote a destination") }
    try TestFixtures.textImage(textURL, lines: ["REPLACEMENT CHANGED CONTENT"])
    var trashed = [URL]()
    let stale = ImageTextFiles.apply(.trash, files: snapshot, trash: { trashed.append($0) })
    guard stale.succeeded == 0, stale.failures.count == 1, trashed.isEmpty else { throw RenameError.message("Stale OCR deletion was not blocked") }
    let fresh = DuplicateFile(url: textURL, stamp: try FileStamp(textURL))
    let replacement = try ImageTextEngine.recognize(fresh, cache: cache)
    guard !replacement.1, replacement.0.text.contains("REPLACEMENT") else { throw RenameError.message("Changed-file OCR cache invalidation failed") }
    let moved = ImageTextFiles.apply(.move(moveFolder), files: [fresh])
    guard moved.succeeded == 1, moved.removed == [textURL], !fm.fileExists(atPath: textURL.path),
          fm.fileExists(atPath: moveFolder.appendingPathComponent(textURL.lastPathComponent).path) else { throw RenameError.message("OCR result move failed") }
    let copyURL = copyFolder.appendingPathComponent(textURL.lastPathComponent)
    let trashFolder = root.appendingPathComponent("fake-trash")
    try fm.createDirectory(at: trashFolder, withIntermediateDirectories: true)
    let trash = ImageTextFiles.apply(.trash, files: [DuplicateFile(url: copyURL, stamp: try FileStamp(copyURL))], trash: {
        try fm.moveItem(at: $0, to: trashFolder.appendingPathComponent($0.lastPathComponent))
    })
    guard trash.succeeded == 1, trash.removed == [copyURL], fm.fileExists(atPath: trashFolder.appendingPathComponent(copyURL.lastPathComponent).path) else { throw RenameError.message("Recoverable OCR removal failed") }
    print("PASS: local RU/EN OCR without EXIF; text/no-text/density/phrase filters; unchanged bytes and dates; cache reuse/invalidation; filtered action snapshots; copy/move/collision protection; stale-file deletion blocked; recoverable removal.")
}
