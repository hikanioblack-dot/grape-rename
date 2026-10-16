import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct FileRow: Identifiable, Sendable {
    let id = UUID()
    var url: URL
    var stamp: FileStamp
    let originalStem: String
    var metadata: MetadataSnapshot
    init(url: URL, stamp: FileStamp, readMetadata: Bool = true) {
        self.url = url; self.stamp = stamp
        originalStem = url.deletingPathExtension().lastPathComponent
        metadata = readMetadata ? MetadataReader.read(url) : MetadataSnapshot()
    }
}
enum SortMode: String, CaseIterable, Identifiable {
    case manual, name, modified, created, size, kind, shot
    var id: String { rawValue }
    var title: String {
        switch self {
        case .manual: return L("Вручную", "Manual")
        case .name: return L("Имя", "Name")
        case .modified: return L("Дата изменения", "Date modified")
        case .created: return L("Дата создания", "Date created")
        case .size: return L("Размер", "Size")
        case .kind: return L("Тип файла", "File type")
        case .shot: return L("Дата съёмки", "Date taken")
        }
    }
}

enum FileViewMode: String, CaseIterable, Identifiable {
    case compact, thumbnails, grid
    var id: String { rawValue }
    var title: String {
        switch self { case .compact: return L("Компактный список", "Compact List"); case .thumbnails: return L("Список с миниатюрами", "Thumbnail List"); case .grid: return L("Сетка", "Grid") }
    }
    var symbol: String {
        switch self { case .compact: return "line.3.horizontal"; case .thumbnails: return "list.bullet.rectangle"; case .grid: return "square.grid.2x2" }
    }
}

@MainActor
final class Model: ObservableObject {
    lazy var preview = PreviewController(model: self)
    private var store: PersistenceStore?
    @Published var files: [FileRow] = []
    @Published var selection: UUID?
    @Published var options = NamingOptions()
    @Published var sortMode: SortMode = .name
    @Published var descending = false
    @Published var viewMode: FileViewMode = .thumbnails
    var grid: Bool { get { viewMode == .grid } set { viewMode = newValue ? .grid : .thumbnails } }
    @Published var thumbnailSize: Double = 160
    @Published var message = ""
    @Published var errorMessage = ""
    @Published var showError = false
    @Published var history: [HistoryRecord] = []
    @Published var presets: [SavedPreset] = []
    @Published var selectedPreset: UUID?
    @Published var showHistory = false
    @Published var duplicateMode: DuplicateMode?
    @Published var showImageTextSearch = false
    @Published var showInspector = true
    @Published var persistenceError = ""
    @Published var importing = false
    @Published var importMessage = ""
    private(set) var importRevision = UUID()
    private var importWorker: Task<[FileRow], Error>?
    private var fileChooser: NSOpenPanel?
    @Published var busy = false
    @Published var origin = ""

    // Compatibility accessors also make naming tests independent of the UI.
    var prefix: String { get { options.prefix } set { options.prefix = newValue } }
    var separator: String { get { options.separator } set { options.separator = newValue } }
    var start: Int { get { options.start } set { options.start = newValue } }
    var digits: Int { get { options.digits } set { options.digits = newValue } }
    var keepName: Bool { get { options.keepName } set { options.keepName = newValue } }
    init(storageURL: URL? = nil) {
        let testPath = ProcessInfo.processInfo.environment["GRAPE_TEST_STORAGE"] ?? Bundle.main.object(forInfoDictionaryKey: "GrapeTestStorage") as? String
        let resolved = storageURL ?? testPath.map { URL(fileURLWithPath: $0) }
        do { store = try PersistenceStore(url: resolved); try store?.recover(); synchronizeStorage() }
        catch { persistenceError = error.localizedDescription; synchronizeStorage() }
    }
    func synchronizeStorage() { history = store?.state.history ?? []; presets = store?.state.presets ?? [] }
    var undoRecord: HistoryRecord? { history.last(where: { $0.undoneAt == nil }) }
    var selectedFile: FileRow? { files.first(where: { $0.id == selection }) }
    var missingEXIF: Int { files.filter { $0.metadata.captureDate == nil }.count }

    func newName(_ row: FileRow, index: Int) -> String {
        var components: [String] = []
        if !options.prefix.isEmpty { components.append(options.prefix) }
        if options.useShotDate, let date = row.metadata.captureDate { components.append(options.shotFormat.string(date)) }
        if options.numbering {
            // Preview is evaluated before validation, including while editing a number.
            guard (0...999_999_999).contains(options.start), (1...8).contains(options.digits), index >= 0 else { return "" }
            let (number, overflow) = options.start.addingReportingOverflow(index)
            guard !overflow else { return "" }
            let text = String(number)
            components.append(String(repeating: "0", count: max(0, options.digits - text.count)) + text)
        }
        if options.keepName {
            let original = options.find.isEmpty ? row.originalStem : row.originalStem.replacingOccurrences(of: options.find, with: options.replacement, options: options.caseInsensitive ? [.caseInsensitive] : [])
            if !original.isEmpty { components.append(original) }
        }
        let base = components.joined(separator: options.separator)
        guard !base.isEmpty else { return "" }
        return row.url.pathExtension.isEmpty ? base : base + "." + row.url.pathExtension
    }
    var plan: [RenameStep] { files.enumerated().map { i, row in RenameStep(source: row.url, destination: row.url.deletingLastPathComponent().appendingPathComponent(newName(row, index: i)), stamp: row.stamp) } }
    var validation: String? {
        if importing { return nil }
        if !persistenceError.isEmpty { return persistenceError }
        if files.isEmpty { return nil }
        if options.start < 0 || options.start > 999_999_999 || !(1...8).contains(options.digits) { return L("Проверьте начальный номер и количество цифр.", "Check the starting number and number of digits.") }
        if files.enumerated().contains(where: { newName($0.element, index: $0.offset).isEmpty }) { return L("Шаблон создаёт пустое имя. Включите нумерацию или исходное имя.", "The template creates an empty name. Enable numbering or the original name.") }
        if [options.prefix, options.separator, options.replacement].contains(where: { $0.contains("/") || $0.contains(":") || $0.contains("\0") }) { return L("В имени нельзя использовать /, : и нулевой символ.", "Names cannot contain /, : or a null character.") }
        do { try RenameEngine.validate(plan); return nil } catch { return error.localizedDescription }
    }
    var changes: Int { plan.filter { $0.source != $0.destination }.count }
    func fail(_ error: Error) { errorMessage = error.localizedDescription; showError = true }

    func choose(folder: Bool, append: Bool = false) {
        guard !busy, fileChooser == nil else { return }
        let revision = importRevision
        let panel = NSOpenPanel()
        panel.title = folder ? L("Выберите папку", "Choose a folder") : L("Выберите файлы", "Choose files")
        panel.prompt = L("Открыть", "Open")
        panel.canChooseFiles = !folder; panel.canChooseDirectories = folder; panel.allowsMultipleSelection = !folder
        panel.message = folder ? L("Файлы внутри папки, без вложенных папок.", "Files in this folder, excluding subfolders.") : L("Выберите файлы для переименования.", "Choose files to rename.")
        fileChooser = panel
        panel.begin { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.fileChooser = nil
                guard result == .OK, !self.busy, self.importRevision == revision else { return }
                self.importFiles(panel.urls, append: append)
            }
        }
    }
    /// UI entry point: enumeration, stat and metadata reading stay off MainActor.
    @discardableResult
    func importFiles(_ urls: [URL], append: Bool = false,
                     reader: @escaping @Sendable ([URL], Set<String>, @Sendable (String) -> Void) throws -> [FileRow] = { try FileImport.read($0, $1, $2) }) -> Task<Void, Never>? {
        guard !busy || importing else { return nil }
        cancelImport()
        let revision = UUID(); importRevision = revision
        let excluded = Set(append ? files.map { $0.url.path } : [])
        importing = true; busy = true
        importMessage = L("Чтение файлов…", "Reading files…")
        let update: @Sendable (String) -> Void = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                if self.importing, self.importRevision == revision { self.importMessage = message }
            }
        }
        let worker = Task.detached(priority: .utility) { try reader(urls, excluded, update) }
        importWorker = worker
        return Task { [weak self] in
            do {
                let rows = try await worker.value
                guard let self, self.importing, self.importRevision == revision else { return }
                try self.applyImported(rows, append: append)
                self.finishImport()
            } catch {
                guard let self, self.importing, self.importRevision == revision else { return }
                self.finishImport()
                if !(error is CancellationError) { self.fail(error) }
            }
        }
    }
    func cancelImport() {
        importWorker?.cancel(); importWorker = nil; importRevision = UUID()
        if importing { finishImport() }
    }
    private func finishImport() {
        importWorker = nil; importing = false; busy = false; importMessage = ""
    }
    /// Synchronous helper for CLI fixtures/tests; application UI uses importFiles.
    func load(_ urls: [URL], folder: Bool, append: Bool = false) {
        guard !busy else { return }
        do {
            let excluded = Set(append ? files.map { $0.url.path } : [])
            try applyImported(FileImport.read(urls, excluded, { _ in }), append: append)
        } catch { fail(error) }
    }
    private func applyImported(_ rows: [FileRow], append: Bool) throws {
        var seen = Set(append ? files.map { $0.url.path } : [])
        let added = rows.filter { seen.insert($0.url.path).inserted }
        let loaded = (append ? files : []) + added
        guard !loaded.isEmpty else { throw RenameError.message(L("Нет обычных файлов. Скрытые файлы, ссылки и вложенные папки пропускаются.", "No regular files. Hidden files, symbolic links and subfolders are excluded.")) }
        files = loaded
        if !append { selection = nil; sortMode = .name; descending = false }
        updateOrigin(); sort()
        if !append { selection = files.first?.id }
        message = append ? L("Добавлено: \(added.count)", "Added: \(added.count)") : ""
    }
    func updateOrigin() {
        let parents = Set(files.map { $0.url.deletingLastPathComponent().path })
        origin = parents.count == 1 ? files[0].url.deletingLastPathComponent().lastPathComponent : L("Папок: \(parents.count)", "Folders: \(parents.count)")
    }
    func sort() {
        guard sortMode != .manual else { return }
        files.sort { a, b in
            let comparison: ComparisonResult
            switch sortMode {
            case .name, .manual: comparison = a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent)
            case .kind: comparison = a.url.pathExtension.localizedStandardCompare(b.url.pathExtension)
            case .size: comparison = compare(a.stamp.size, b.stamp.size)
            case .modified: comparison = compare(a.stamp.modified, b.stamp.modified)
            case .created: comparison = compare(a.stamp.created, b.stamp.created)
            case .shot:
                // Missing dates always follow dated photos in both directions.
                if a.metadata.captureDate == nil && b.metadata.captureDate != nil { return false }
                if a.metadata.captureDate != nil && b.metadata.captureDate == nil { return true }
                comparison = compare(a.metadata.captureDate ?? .distantPast, b.metadata.captureDate ?? .distantPast)
            }
            let effective = comparison == .orderedSame ? a.url.path.localizedStandardCompare(b.url.path) : comparison
            return descending ? effective == .orderedDescending : effective == .orderedAscending
        }
        message = ""
    }
    private func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult { a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending) }
    func moveSelection(_ offset: Int) {
        guard let id = selection, let index = files.firstIndex(where: { $0.id == id }), files.indices.contains(index + offset) else { return }
        files.swapAt(index, index + offset); sortMode = .manual; message = ""
    }
    func move(_ source: IndexSet, _ destination: Int) { files.move(fromOffsets: source, toOffset: destination); sortMode = .manual; message = "" }
    func insert(_ dragged: UUID, at destination: Int) {
        guard let from = files.firstIndex(where: { $0.id == dragged }), (0...files.count).contains(destination) else { return }
        selection = dragged
        guard destination != from, destination != from + 1 else { return }
        files.move(fromOffsets: IndexSet(integer: from), toOffset: destination)
        sortMode = .manual; message = ""
    }
    func drop(_ dragged: String, onto target: UUID) {
        guard let from = files.firstIndex(where: { $0.id.uuidString == dragged }), let to = files.firstIndex(where: { $0.id == target }), from != to else { return }
        files.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        sortMode = .manual; selection = files.first(where: { $0.id.uuidString == dragged })?.id; message = ""
    }
    func remove(_ id: UUID) { files.removeAll { $0.id == id }; if selection == id { selection = files.first?.id }; if files.isEmpty { reset() } else { updateOrigin() } }
    func removeFiles(at urls: Set<URL>) {
        files.removeAll { urls.contains($0.url) }
        if !files.contains(where: { $0.id == selection }) { selection = files.first?.id }
        if files.isEmpty { reset() } else { updateOrigin() }
        preview.refresh()
    }
    func rename() {
        guard !busy, let store else { return }
        busy = true; defer { busy = false; synchronizeStorage() }
        do {
            if let validation { throw RenameError.message(validation) }
            let steps = plan.filter { $0.source != $0.destination }
            guard !steps.isEmpty else { return }
            let record = HistoryRecord(steps: steps)
            let operation = try store.begin(record, undo: false)
            _ = try RenameEngine.apply(steps, staging: operation.staging)
            updateRows(steps)
            try store.finish(operation)
            message = L("Переименовано: \(steps.count). Даты сохранены.", "Renamed: \(steps.count). Dates preserved.")
        } catch { handleOperationError(error) }
    }
    func undo() {
        guard !busy, let record = undoRecord, let store, persistenceError.isEmpty else { return }
        busy = true; defer { busy = false; synchronizeStorage() }
        do {
            let reversed = record.steps.map { RenameStep(source: $0.destination, destination: $0.source, stamp: $0.stamp) }
            try RenameEngine.validate(reversed)
            let operation = try store.begin(record, undo: true)
            _ = try RenameEngine.apply(reversed, staging: operation.staging)
            updateRows(reversed)
            try store.finish(operation)
            message = L("Имена восстановлены. Даты сохранены.", "Names restored. Dates preserved.")
        } catch { handleOperationError(error) }
    }
    private func updateRows(_ steps: [RenameStep]) {
        // Resolve old URLs once; publish one array rather than one change per file.
        let destinations = Dictionary(steps.map { ($0.source, $0.destination) }, uniquingKeysWith: { first, _ in first })
        var updated = files
        for i in updated.indices {
            if let destination = destinations[updated[i].url] { updated[i].url = destination }
        }
        files = updated
        updateOrigin()
    }
    private func handleOperationError(_ error: Error) {
        do { try store?.recover() } catch { persistenceError = error.localizedDescription }
        fail(error)
    }
    func recover() {
        do { if store == nil { store = try PersistenceStore() }; try store?.recover(); persistenceError = ""; synchronizeStorage() }
        catch { fail(error) }
    }
    func savePreset(name: String) throws {
        guard let store, persistenceError.isEmpty else { throw RenameError.message(persistenceError) }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw RenameError.message(L("Введите название шаблона.", "Enter a preset name.")) }
        guard !store.state.presets.contains(where: { $0.name.caseInsensitiveCompare(cleaned) == .orderedSame }) else { throw RenameError.message(L("Шаблон с таким именем уже есть.", "A preset with this name already exists.")) }
        let old = store.state
        let preset = SavedPreset(name: cleaned, options: options)
        store.state.presets.append(preset)
        do { try store.save(); selectedPreset = preset.id; synchronizeStorage() } catch { store.state = old; throw error }
    }
    func applyPreset(_ id: UUID?) { selectedPreset = id; if let preset = presets.first(where: { $0.id == id }) { options = preset.options }; message = "" }
    func updatePreset() {
        guard let store, let id = selectedPreset, let i = store.state.presets.firstIndex(where: { $0.id == id }) else { return }
        let old = store.state
        store.state.presets[i].options = options
        do { try store.save(); synchronizeStorage() } catch { store.state = old; fail(error) }
    }
    func deletePreset() {
        guard let store, let id = selectedPreset else { return }
        let old = store.state
        store.state.presets.removeAll { $0.id == id }
        do { try store.save(); selectedPreset = nil; synchronizeStorage() } catch { store.state = old; fail(error) }
    }
    func reset() { cancelImport(); files = []; selection = nil; message = ""; origin = "" }
    func revealInspector() { showInspector = true }
    func resizeWindow(loaded: Bool) {
        guard !CommandLine.arguments.contains("--self-test"), !CommandLine.arguments.contains("--prepare-ui-test") else { return }
        guard let app = NSApp, let window = app.windows.first(where: { $0.identifier?.rawValue == "main" }) else { return }
        window.minSize = NSSize(width: 1080, height: 620)
        let size = NSSize(width: 1280, height: 780)
        var frame = window.frame
        frame.origin.x += (frame.width - size.width) / 2; frame.origin.y += (frame.height - size.height) / 2; frame.size = size
        if let visible = window.screen?.visibleFrame {
            frame.size.width = min(frame.width, visible.width); frame.size.height = min(frame.height, visible.height)
            frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width)); frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - frame.height))
        }
        window.setFrame(frame, display: true, animate: true)
    }
}
