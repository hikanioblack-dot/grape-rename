import Foundation

@MainActor
func runFeatureTests() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("Grape-features-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let fixtures = root.appendingPathComponent("files")
    try TestFixtures.create(at: fixtures)
    let storage = root.appendingPathComponent("support/state.json")
    let photo = fixtures.appendingPathComponent("IMG_0102.jpg")
    let info = MetadataReader.read(photo)
    guard let date = info.captureDate, ShotFormat.dateTime.string(date) == "2024-06-15_08-09-10", info.sections.contains(where: { $0.title == "Exif" }) else { throw RenameError.message("EXIF read failed: raw=\(info.captureRaw ?? "none"), sections=\(info.sections.map(\.title)), values=\(info.sections.flatMap(\.fields).map { "\($0.key)=\($0.value)" })") }
    guard MetadataReader.read(fixtures.appendingPathComponent("No EXIF.png")).captureDate == nil else { throw RenameError.message("Missing EXIF failed") }
    let photoRow = FileRow(url: photo, stamp: try FileStamp(photo))
    let summary = MetadataReader.inspectorFields(photoRow)
    guard summary.contains(where: { $0.value == "640 × 420" }), summary.contains(where: { $0.value == "Grape Test Camera" }) else { throw RenameError.message("Inspector image summary failed") }
    let model = Model(storageURL: storage)
    model.load([fixtures], folder: true)
    guard model.files.count == 13, !model.showError else { throw RenameError.message("Fixture import failed") }
    let previewNames = model.plan.map(\.destination)
    for mode in FileViewMode.allCases {
        model.viewMode = mode
        guard model.plan.map(\.destination) == previewNames else { throw RenameError.message("View mode changed rename order") }
    }
    model.showInspector = false; model.revealInspector()
    guard model.showInspector else { throw RenameError.message("Inspector reveal failed") }
    model.sortMode = .shot; model.sort()
    guard model.files.first?.url.lastPathComponent == "IMG_0007.jpg" else { throw RenameError.message("EXIF sorting failed") }
    model.descending = true; model.sort()
    guard model.files.first?.url.lastPathComponent == "IMG_0102.jpg", model.files.last?.metadata.captureDate == nil else { throw RenameError.message("EXIF reverse sorting failed") }
    model.options.prefix = "Grape"; model.options.useShotDate = true
    guard model.newName(model.files[0], index: 0) == "Grape_2024-06-15_08-09-10_0001.jpg" else { throw RenameError.message("EXIF naming failed") }
    model.options.numbering = false; model.options.useShotDate = false; model.options.prefix = ""; model.options.keepName = true
    model.options.find = "img"; model.options.replacement = "Photo"; model.options.caseInsensitive = true
    guard model.newName(model.files[0], index: 0) == "Photo_0102.jpg" else { throw RenameError.message("Find/replace failed") }
    try model.savePreset(name: "Photos")
    let fresh = Model(storageURL: storage)
    guard fresh.presets.count == 1 else { throw RenameError.message("Preset persistence failed") }
    fresh.applyPreset(fresh.presets[0].id)
    guard fresh.options == model.options else { throw RenameError.message("Preset apply failed") }
    fresh.options.prefix = "Updated"; fresh.updatePreset()
    guard Model(storageURL: storage).presets[0].options.prefix == "Updated" else { throw RenameError.message("Preset update failed") }
    fresh.deletePreset()
    guard Model(storageURL: storage).presets.isEmpty else { throw RenameError.message("Preset deletion failed") }
    model.options = NamingOptions(); model.options.prefix = "First"
    let originalURLs = model.files.map(\.url)
    let originalStamps = model.files.map(\.stamp)
    let contents = try originalURLs.map { try Data(contentsOf: $0) }
    model.rename()
    guard model.history.count == 1, !model.showError else { throw RenameError.message("First history rename failed: \(model.errorMessage)") }
    model.options.prefix = "Second"; model.rename()
    guard model.history.count == 2, !model.showError else { throw RenameError.message("Second history rename failed") }
    let reopened = Model(storageURL: storage)
    guard reopened.history.count == 2 else { throw RenameError.message("History reload failed") }
    reopened.undo(); reopened.undo()
    guard !reopened.showError, reopened.history.allSatisfy({ $0.undoneAt != nil }) else { throw RenameError.message("Persistent undo failed: \(reopened.errorMessage)") }
    for (i, url) in originalURLs.enumerated() {
        guard try FileStamp(url) == originalStamps[i], try Data(contentsOf: url) == contents[i] else { throw RenameError.message("Persistent undo metadata/bytes failed") }
    }
    let pdfRow = model.files.first(where: { $0.url.pathExtension == "pdf" })!
    // Reset stale URLs after undo before inspecting PDF.
    let pdf = FileRow(url: originalURLs[model.files.firstIndex(where: { $0.id == pdfRow.id })!], stamp: pdfRow.stamp)
    guard MetadataReader.general(pdf).fields.contains(where: { $0.value == "2" }) else { throw RenameError.message("PDF metadata failed") }
    // Recover an operation that stopped during its temporary-name phase.
    let store = try PersistenceStore(url: storage)
    let step = RenameStep(source: photo, destination: fixtures.appendingPathComponent("Recovered.jpg"), stamp: try FileStamp(photo))
    let record = HistoryRecord(steps: [step])
    let pending = try store.begin(record, undo: false)
    try RenameEngine.moveExclusive(photo, pending.staging[0])
    let recovered = try PersistenceStore(url: storage); try recovered.recover()
    guard RenameEngine.exists(photo), recovered.state.pending == nil else { throw RenameError.message("Interrupted staging recovery failed") }
    let completed = try recovered.begin(record, undo: false)
    _ = try RenameEngine.apply(completed.steps, staging: completed.staging)
    let afterCrash = try PersistenceStore(url: storage); try afterCrash.recover()
    guard afterCrash.state.history.last?.id == record.id else { throw RenameError.message("Interrupted commit recovery failed") }
    let undo = try afterCrash.begin(record, undo: true)
    _ = try RenameEngine.apply(undo.steps, staging: undo.staging); try afterCrash.finish(undo)
    // A modified file must never be renamed by an old history entry.
    let guarded = Model(storageURL: storage); guarded.load([photo], folder: false); guarded.options.prefix = "Guard"; guarded.rename()
    guard let destination = guarded.history.last?.steps[0].destination else { throw RenameError.message("Guard setup failed") }
    try Data("external edit".utf8).write(to: destination)
    let blocked = Model(storageURL: storage); blocked.undo()
    guard blocked.showError, RenameEngine.exists(destination), !RenameEngine.exists(photo) else { throw RenameError.message("Changed-file undo guard failed") }
    print("PASS: 13 formats; EXIF dates/naming/sorting; missing EXIF; literal case-insensitive replacement; preset save/update/delete/reload; two-level undo across restart; bytes and timestamps preserved; interrupted staging/commit recovery; PDF metadata; changed-file undo blocked.")
}
