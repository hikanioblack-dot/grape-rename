import Foundation
import Combine

@MainActor
func runIntegrationTests() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("Grape-import-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let folder = root.appendingPathComponent("Folder")
    let nested = folder.appendingPathComponent("Nested")
    try fm.createDirectory(at: nested, withIntermediateDirectories: true)
    let a = folder.appendingPathComponent("photo10.txt")
    let b = folder.appendingPathComponent("photo2.csv")
    let c = root.appendingPathComponent("other.md")
    for (url, size) in [(a, 100), (b, 20), (c, 300), (nested.appendingPathComponent("inside.txt"), 15), (folder.appendingPathComponent(".hidden"), 10)] {
        try Data(repeating: 65, count: size).write(to: url)
    }
    try fm.createSymbolicLink(at: folder.appendingPathComponent("link.txt"), withDestinationURL: a)
    let imported = try FileImport.collect([folder, c, a, folder])
    guard Set(imported) == Set([a, b, c]), imported.count == 3 else { throw RenameError.message("Mixed folder/file import failed") }
    let model = Model(storageURL: root.appendingPathComponent("state.json"))
    model.files = try imported.map { FileRow(url: $0, stamp: try FileStamp($0)) }
    model.sortMode = .size; model.sort()
    guard model.files.map(\.url) == [b, a, c] else { throw RenameError.message("Size sort failed") }
    model.descending = true; model.sort()
    guard model.files.map(\.url) == [c, a, b] else { throw RenameError.message("Descending sort failed") }
    model.sortMode = .name; model.descending = false; model.sort()
    guard model.files.map(\.url) == [c, b, a] else { throw RenameError.message("Natural name sort failed") }
    let dragged = model.files[2].id
    model.drop(dragged.uuidString, onto: model.files[0].id)
    guard model.files.map(\.url) == [a, c, b], model.sortMode == .manual else { throw RenameError.message("Drag reorder failed") }
    model.selection = dragged; model.moveSelection(1)
    guard model.files.map(\.url) == [c, a, b] else { throw RenameError.message("Arrow reorder failed") }
    model.insert(dragged, at: 3)
    guard model.files.map(\.url) == [c, b, a] else { throw RenameError.message("Insert after last row failed") }
    model.insert(dragged, at: 1)
    guard model.files.map(\.url) == [c, a, b] else { throw RenameError.message("Insert between rows failed") }
    model.insert(dragged, at: 2)
    guard model.files.map(\.url) == [c, a, b] else { throw RenameError.message("Adjacent insertion should leave order unchanged") }
    model.insert(dragged, at: 0)
    guard model.files.map(\.url) == [a, c, b] else { throw RenameError.message("Insert before first row failed") }
    model.insert(dragged, at: 2)
    guard model.files.map(\.url) == [c, a, b], model.selection == dragged else { throw RenameError.message("Downward insertion boundary failed") }
    model.prefix = "Grape"; model.separator = " — "; model.keepName = true
    guard model.newName(model.files[0], index: 0) == "Grape — 0001 — other.md" else { throw RenameError.message("Template failed") }
    let savedOptions = model.options
    for invalidStart in [Int.min, -1, 1_000_000_000, Int.max] {
        model.options.start = invalidStart
        guard model.newName(model.files[0], index: 1).isEmpty, model.validation != nil else {
            throw RenameError.message("Invalid starting number must not crash preview")
        }
        _ = model.plan; _ = model.changes
    }
    model.options = savedOptions
    for invalidDigits in [Int.min, -1, 0, 9, Int.max] {
        model.options.digits = invalidDigits
        guard model.newName(model.files[0], index: 0).isEmpty, model.validation != nil else {
            throw RenameError.message("Invalid digit count must not allocate a huge preview")
        }
    }
    model.options = savedOptions
    guard model.newName(model.files[0], index: Int.max).isEmpty else { throw RenameError.message("Numbering index overflow was not rejected") }
    model.options.prefix = ""; model.options.keepName = false; model.options.start = 999_999_999
    guard model.newName(model.files[0], index: 2) == "1000000001.md" else { throw RenameError.message("Numbering near upper bound failed") }
    model.options = savedOptions
    // Swaps must update each row from its old URL and emit only one file-list change.
    let oldRows = model.files
    let swapA = root.appendingPathComponent("swap-a.txt"), swapB = root.appendingPathComponent("swap-b.txt")
    try Data("first".utf8).write(to: swapA); try Data("second".utf8).write(to: swapB)
    model.options = NamingOptions(); model.options.numbering = false; model.options.keepName = true
    model.files = [FileRow(url: swapA, stamp: try FileStamp(swapA)), FileRow(url: swapB, stamp: try FileStamp(swapB))]
    let originalRows = model.files
    model.files[0].url = swapB; model.files[0].stamp = originalRows[1].stamp
    model.files[1].url = swapA; model.files[1].stamp = originalRows[0].stamp
    var publications = 0
    let subscription = model.$files.dropFirst().sink { _ in publications += 1 }
    model.rename()
    guard !model.showError, model.files.map(\.url) == [swapA, swapB], publications == 1,
          try FileStamp(swapA) == originalRows[1].stamp, try FileStamp(swapB) == originalRows[0].stamp else {
        throw RenameError.message("Swap row mapping or single publication failed: \(model.errorMessage)")
    }
    model.undo()
    guard !model.showError, model.files.map(\.url) == [swapB, swapA], publications == 2,
          try FileStamp(swapA) == originalRows[0].stamp, try FileStamp(swapB) == originalRows[1].stamp else {
        throw RenameError.message("Swap undo row mapping failed")
    }
    subscription.cancel()
    model.files = oldRows; model.options = savedOptions
    print("PASS: mixed file/folder import; deduplication; hidden, nested and symlink exclusions; natural/size/reverse sorting; drag/arrow order; insertion before/after rows and at both ends; naming template.")
    print("PASS: extreme numbering inputs and overflow rejected before preview; large valid numbering; swapped row URLs and undo; one file-list publication per operation.")
}

/// A delayed provider is simulated without depending on iCloud availability.
private final class ImportTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private let release = DispatchSemaphore(value: 0)
    var started: Bool { lock.lock(); defer { lock.unlock() }; return didStart }
    func wait() throws {
        guard !Thread.isMainThread else { throw RenameError.message("Import reader ran on the main thread") }
        lock.lock(); didStart = true; lock.unlock()
        guard release.wait(timeout: .now() + 5) == .success else { throw RenameError.message("Import test gate timed out") }
    }
    func open() { release.signal() }
}

@MainActor
func runAsyncImportTests() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("Grape-async-import-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let a = root.appendingPathComponent("old.txt"), b = root.appendingPathComponent("new.txt")
    try Data("old".utf8).write(to: a); try Data("new".utf8).write(to: b)
    let aStamp = try FileStamp(a), bStamp = try FileStamp(b)
    let oldRows = try FileImport.read([a], [], { _ in })
    let model = Model(storageURL: root.appendingPathComponent("state.json"))
    model.load([a], folder: false)
    let oldID = model.selection
    let gate = ImportTestGate()
    let pending = model.importFiles([b], reader: { _, _, update in
        try gate.wait()
        update("obsolete progress")
        // Deliberately emulate a provider that ignores cooperative cancellation.
        return oldRows
    })!
    let deadline = Date().addingTimeInterval(3)
    while !gate.started && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
    guard gate.started, model.importing, model.busy, model.files.map(\.url) == [a], model.selection == oldID else {
        gate.open(); throw RenameError.message("Delayed import blocked MainActor or changed the previous batch")
    }
    model.rename()
    guard try FileStamp(a) == aStamp, !model.acceptDrop([]) else { gate.open(); throw RenameError.message("Import allowed a conflicting action") }
    // A newer import wins even when the first read is still blocked in a provider.
    await model.importFiles([b])?.value
    guard !model.busy, !model.importing, model.files.map(\.url) == [b] else { gate.open(); throw RenameError.message("Newest import did not finish") }
    gate.open(); await pending.value
    guard model.files.map(\.url) == [b], model.importMessage.isEmpty, !model.showError else {
        throw RenameError.message("Cancelled import overwrote the newer result or progress")
    }
    let cancelGate = ImportTestGate()
    let cancelled = model.importFiles([a], reader: { _, _, _ in try cancelGate.wait(); return oldRows })!
    let cancelDeadline = Date().addingTimeInterval(3)
    while !cancelGate.started && Date() < cancelDeadline { try await Task.sleep(for: .milliseconds(5)) }
    guard cancelGate.started else { cancelGate.open(); throw RenameError.message("Cancel test did not reach delayed read") }
    model.cancelImport()
    guard !model.busy, !model.importing, model.files.map(\.url) == [b] else {
        cancelGate.open(); throw RenameError.message("Cancel did not release UI or preserve the old batch")
    }
    cancelGate.open(); await cancelled.value
    guard model.files.map(\.url) == [b] else { throw RenameError.message("Late result survived explicit cancel") }
    let resetGate = ImportTestGate()
    let resetPending = model.importFiles([a], reader: { _, _, _ in try resetGate.wait(); return oldRows })!
    let resetDeadline = Date().addingTimeInterval(3)
    while !resetGate.started && Date() < resetDeadline { try await Task.sleep(for: .milliseconds(5)) }
    guard resetGate.started else { resetGate.open(); throw RenameError.message("Reset test did not reach delayed read") }
    model.reset(); resetGate.open(); await resetPending.value
    guard model.files.isEmpty, !model.busy, !model.importing else { throw RenameError.message("Reset allowed an obsolete import result") }
    await model.importFiles([a])?.value
    await model.importFiles([a, b], append: true)?.value
    guard model.files.count == 2, Set(model.files.map(\.url)) == [a, b] else { throw RenameError.message("Async append duplicated or dropped files") }
    await model.importFiles([root.appendingPathComponent("missing")])?.value
    guard model.showError, model.files.count == 2, !model.busy else { throw RenameError.message("Import failure damaged the previous batch or left busy set") }
    model.showError = false
    let empty = root.appendingPathComponent("Empty")
    try fm.createDirectory(at: empty, withIntermediateDirectories: true)
    await model.importFiles([empty])?.value
    guard model.showError, model.files.count == 2, !model.busy else { throw RenameError.message("Empty import did not report failure safely") }
    model.showError = false
    let mixed = root.appendingPathComponent("Mixed")
    try TestFixtures.create(at: mixed)
    await model.importFiles([mixed])?.value
    guard !model.showError, model.files.count == 13,
          model.files.first(where: { $0.url.lastPathComponent == "IMG_0102.jpg" })?.metadata.captureRaw == "2024:06:15 08:09:10" else {
        throw RenameError.message("Background import lost file formats or EXIF metadata")
    }
    guard try FileStamp(a) == aStamp, try FileStamp(b) == bStamp, try Data(contentsOf: a) == Data("old".utf8), try Data(contentsOf: b) == Data("new".utf8) else {
        throw RenameError.message("Async import changed source files")
    }
    print("PASS: background import keeps MainActor available; latest request wins; stale progress/results ignored; reset/cancellation; append deduplication; missing/empty input preserves batch; conflicting actions blocked; bytes and dates preserved.")
}
