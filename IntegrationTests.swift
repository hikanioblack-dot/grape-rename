import Foundation

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
    print("PASS: mixed file/folder import; deduplication; hidden, nested and symlink exclusions; natural/size/reverse sorting; drag/arrow order; insertion before/after rows and at both ends; naming template.")
}
