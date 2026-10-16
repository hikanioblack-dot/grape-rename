import SwiftUI
import AppKit

enum ImageTextActionScope: Sendable, Equatable { case selected, filtered }

/// Captured when an action is requested; confirmation and execution share this set.
struct ImageTextActionSnapshot: Sendable {
    let scope: ImageTextActionScope
    let files: [DuplicateFile]
    let filterSummary: String
    var confirmationTitle: String {
        switch scope {
        case .selected:
            return files.count == 1
                ? L("Выбранный файл в Корзину: 1?", "Move 1 selected file to Trash?")
                : L("Выбранные файлы в Корзину: \(files.count)?", "Move \(files.count) selected files to Trash?")
        case .filtered:
            return files.count == 1
                ? L("Результат фильтра в Корзину: 1?", "Move the filtered result to Trash?")
                : L("Все результаты фильтра в Корзину: \(files.count)?", "Move all \(files.count) filtered results to Trash?")
        }
    }
}

@MainActor
final class ImageTextSearch: ObservableObject {
    @Published var roots: [URL]
    @Published var recursive = true
    @Published var useCache = true
    @Published var report: ImageTextReport?
    @Published var filter: TextImageFilter = .withText
    @Published var query = ""
    @Published var minimumCharacters = 80
    @Published var minimumLines = 3
    @Published var selection = Set<String>()
    @Published var preview: TextImage?
    @Published var running = false
    @Published var scanning = false
    @Published var progress = DuplicateProgress(fraction: 0, message: "")
    @Published var error = ""
    @Published var notice = ""
    private var worker: Task<ImageTextReport, Error>?
    private var generation: UUID?

    init(files: [FileRow]) { roots = files.map(\.url) }
    var filtered: [TextImage] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return report?.images.filter {
            filter.matches($0.content, minimumCharacters: minimumCharacters, minimumLines: minimumLines)
                && (term.isEmpty || $0.content.text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
        } ?? []
    }
    var selectedFiles: [DuplicateFile] { filtered.filter { selection.contains($0.id) }.map(\.file) }
    func snapshot(for scope: ImageTextActionScope) -> ImageTextActionSnapshot {
        let visible = filtered
        let files = scope == .selected ? visible.filter { selection.contains($0.id) }.map(\.file) : visible.map(\.file)
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var summary = filter.title
        if filter == .muchText { summary += L(" · символов от \(minimumCharacters), строк от \(minimumLines)", " · at least \(minimumCharacters) characters, \(minimumLines) lines") }
        if !term.isEmpty { summary += " · «\(term)»" }
        return ImageTextActionSnapshot(scope: scope, files: files, filterSummary: summary)
    }
    func refreshFilter() {
        let visible = Set(filtered.map(\.id))
        selection.formIntersection(visible)
        if preview == nil || !visible.contains(preview!.id) { preview = filtered.first }
    }
    func cancel() {
        worker?.cancel(); worker = nil; generation = nil
        if scanning { notice = L("Поиск отменён.", "Search cancelled."); running = false; scanning = false }
    }
    func invalidate() { cancel(); report = nil; selection = []; preview = nil; error = ""; notice = "" }
    func choose(folder: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !folder; panel.canChooseDirectories = folder; panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in self?.invalidate(); self?.roots = panel.urls }
        }
    }
    func start() {
        guard !running, !roots.isEmpty else { return }
        invalidate(); running = true; scanning = true; progress = DuplicateProgress(fraction: 0, message: L("Подготовка…", "Preparing…"))
        let id = UUID(); generation = id
        let roots = roots, recursive = recursive, cache = useCache ? ImageTextEngine.cacheDirectory : nil
        let update: @Sendable (DuplicateProgress) -> Void = { [weak self] value in
            guard let self else { return }
            Task { @MainActor in if self.generation == id { self.progress = value } }
        }
        let job = Task.detached(priority: .utility) { try await ImageTextEngine.scanConcurrent(roots, recursive: recursive, cache: cache, progress: update) }
        worker = job
        Task { [weak self] in
            do {
                let result = try await job.value
                guard let self, self.generation == id else { return }
                self.report = result; self.refreshFilter(); self.running = false; self.scanning = false; self.worker = nil; self.generation = nil
            } catch {
                guard let self, self.generation == id else { return }
                self.error = error.localizedDescription; self.running = false; self.scanning = false; self.worker = nil; self.generation = nil
            }
        }
    }
    func perform(_ action: ImageTextAction, snapshot: ImageTextActionSnapshot, model: Model) {
        let files = snapshot.files
        guard !running, !files.isEmpty else { return }
        running = true; notice = L("Обработка файлов…", "Processing files…"); error = ""
        Task {
            let result = await Task.detached(priority: .utility) { ImageTextFiles.apply(action, files: files) }.value
            model.removeFiles(at: result.removed)
            report?.images.removeAll { result.removed.contains($0.file.url) }
            selection.subtract(result.removed.map(\.path)); refreshFilter()
            running = false
            switch action {
            case .trash: notice = L("В Корзину перемещено: \(result.succeeded). Восстановить можно в Finder.", "Moved to Trash: \(result.succeeded). Restore in Finder.")
            case .copy: notice = L("Скопировано: \(result.succeeded).", "Copied: \(result.succeeded).")
            case .move: notice = L("Перемещено: \(result.succeeded).", "Moved: \(result.succeeded).")
            }
            error = result.failures.joined(separator: "\n")
        }
    }
    func export(move: Bool, model: Model) {
        let snapshot = snapshot(for: .selected)
        guard !snapshot.files.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = move ? L("Переместить сюда", "Move Here") : L("Копировать сюда", "Copy Here")
        panel.begin { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            Task { @MainActor in self?.perform(move ? .move(folder) : .copy(folder), snapshot: snapshot, model: model) }
        }
    }
    func clearCache() {
        do {
            if FileManager.default.fileExists(atPath: ImageTextEngine.cacheDirectory.path) { try FileManager.default.removeItem(at: ImageTextEngine.cacheDirectory) }
            notice = L("Локальный кэш текста очищен.", "Local text cache cleared.")
        } catch { self.error = error.localizedDescription }
    }
}

struct ImageTextSearchView: View {
    @ObservedObject var model: Model
    @StateObject private var search: ImageTextSearch
    @Environment(\.dismiss) private var dismiss
    @State private var pendingTrash: ImageTextActionSnapshot?
    @State private var confirmTrash = false
    init(model: Model) {
        self.model = model
        _search = StateObject(wrappedValue: ImageTextSearch(files: model.files))
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if search.running {
                VStack(spacing: 16) {
                    if search.scanning {
                        ProgressView(value: search.progress.fraction).frame(width: 360)
                        Text(search.progress.message).lineLimit(2)
                        Button(L("Остановить", "Stop")) { search.cancel() }
                    } else { ProgressView(); Text(search.notice) }
                }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let report = search.report { results(report) }
            else {
                ContentUnavailableView(L("Добавьте медиафайлы", "Add Media Files"), systemImage: "text.viewfinder",
                    description: Text(L("Выберите файлы или папку и начните поиск текста.", "Choose files or a folder and start searching for text.")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if !search.notice.isEmpty && !search.running {
                Text(search.notice).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 6)
            }
            Divider()
            footer
        }.frame(width: 1040, height: 740)
            .onChange(of: search.recursive) { search.invalidate() }
            .onChange(of: search.filter) { search.refreshFilter() }
            .onChange(of: search.query) { search.refreshFilter() }
            .onChange(of: search.minimumCharacters) { search.refreshFilter() }
            .onChange(of: search.minimumLines) { search.refreshFilter() }
            .onDisappear { search.cancel() }
            .interactiveDismissDisabled(search.running)
            .alert(L("Ошибка", "Error"), isPresented: Binding(get: { !search.error.isEmpty }, set: { if !$0 { search.error = "" } })) {
                Button(L("Понятно", "OK")) { search.error = "" }
            } message: { Text(search.error) }
            .confirmationDialog(pendingTrash?.confirmationTitle ?? L("Переместить файлы в Корзину?", "Move files to Trash?"), isPresented: $confirmTrash) {
                Button(L("В Корзину: \(pendingTrash?.files.count ?? 0)", "Move \(pendingTrash?.files.count ?? 0) to Trash"), role: .destructive) {
                    guard let snapshot = pendingTrash else { return }
                    search.perform(.trash, snapshot: snapshot, model: model); pendingTrash = nil
                }
                Button(L("Отмена", "Cancel"), role: .cancel) { pendingTrash = nil }
            } message: {
                Text((pendingTrash?.filterSummary ?? "") + "\n\n" + L("Файлы могут быть единственными оригиналами: сохраняемой копии нет. Восстановление — через Корзину Finder; отмена переименования эти файлы не возвращает.",
                       "Files may be the only originals: no copy is protected. Restore files from Finder Trash; rename undo does not restore them."))
            }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Поиск текста на медиафайлах", "Find Text in Media Files")).font(.title2.weight(.semibold))
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).disabled(search.running).help(L("Закрыть", "Close"))
            }
            HStack(spacing: 12) {
                Text(search.roots.isEmpty ? L("Набор не выбран", "No files selected") : (search.roots.count == 1 ? search.roots[0].lastPathComponent : L("Выбрано объектов: \(search.roots.count)", "Selected items: \(search.roots.count)")))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                Menu(L("Выбрать…", "Choose…")) {
                    Button(L("Файлы…", "Files…")) { search.choose(folder: false) }
                    Button(L("Папки…", "Folders…")) { search.choose(folder: true) }
                    if !model.files.isEmpty { Button(L("Файлы из основного списка", "Files from Main List")) { search.invalidate(); search.roots = model.files.map(\.url) } }
                }
                Button(L("Начать поиск", "Start Search")) { search.start() }.buttonStyle(.glassProminent).disabled(search.roots.isEmpty)
            }
            HStack(spacing: 18) {
                Toggle(L("Включая вложенные папки", "Include subfolders"), isOn: $search.recursive)
                Spacer()
                Menu(L("Кэш", "Cache")) {
                    Toggle(L("Использовать кэш", "Use Cache"), isOn: $search.useCache)
                    Button(L("Очистить кэш", "Clear Cache")) { search.clearCache() }
                }.controlSize(.small)
            }.toggleStyle(.checkbox).font(.caption)
        }.padding(20).disabled(search.running)
    }
    private func results(_ report: ImageTextReport) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Picker(L("Показать", "Show"), selection: $search.filter) {
                    ForEach(TextImageFilter.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                TextField(L("Слово или фраза", "Word or phrase"), text: $search.query)
                    .textFieldStyle(.roundedBorder)
                if search.filter == .muchText {
                    HStack {
                        Stepper(L("Символов от: \(search.minimumCharacters)", "Min. characters: \(search.minimumCharacters)"), value: $search.minimumCharacters, in: 10...1000, step: 10)
                        Spacer(minLength: 20)
                        Stepper(L("Строк от: \(search.minimumLines)", "Min. lines: \(search.minimumLines)"), value: $search.minimumLines, in: 1...30)
                    }.font(.caption)
                }
                HStack {
                    Text(L("Найдено: \(search.filtered.count) / \(report.images.count)", "Matches: \(search.filtered.count) / \(report.images.count)")).font(.callout.weight(.semibold))
                    Spacer()
                    Button(L("Выбрать все", "Select All")) { search.selection = Set(search.filtered.map(\.id)) }
                    Button(L("Снять выбор", "Deselect All")) { search.selection = [] }.disabled(search.selection.isEmpty)
                }.controlSize(.small)
                if search.filtered.isEmpty {
                    ContentUnavailableView(L("Совпадений не найдено", "No Matches Found"), systemImage: "text.magnifyingglass",
                        description: Text(L("Измените фильтр или запрос. Необработанные файлы указаны отдельно.", "Change the filter or query. Unprocessed files are listed separately.")))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(search.filtered) { image in row(image) }
                        }
                    }
                }
                Text(L("Текст не доказывает, что это скриншот. Мелкие или размытые надписи могут не распознаться.", "Text does not prove an image is a screenshot. Small or blurry text may be missed."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(L("Пропущено других файлов/ссылок: \(report.skipped) · Из кэша: \(report.cacheHits)", "Other files/links skipped: \(report.skipped) · From cache: \(report.cacheHits)"))
                    .font(.caption).foregroundStyle(.secondary)
                if !report.warnings.isEmpty {
                    DisclosureGroup(L("Не удалось проверить: \(report.warnings.count)", "Unable to check: \(report.warnings.count)")) {
                        ScrollView { Text(report.warnings.joined(separator: "\n")).font(.caption).textSelection(.enabled) }.frame(maxHeight: 60)
                    }.font(.caption).foregroundStyle(.orange)
                }
            }.padding(16)
            Divider()
            preview.frame(width: 300)
        }
    }
    private func row(_ image: TextImage) -> some View {
        HStack(spacing: 10) {
            Toggle(L("Выбрать \(image.file.url.lastPathComponent)", "Select \(image.file.url.lastPathComponent)"), isOn: Binding(
                get: { search.selection.contains(image.id) }, set: { if $0 { search.selection.insert(image.id) } else { search.selection.remove(image.id) } }
            )).labelsHidden().toggleStyle(.checkbox)
            FileThumbnail(row: FileRow(url: image.file.url, stamp: image.file.stamp, readMetadata: false), width: 46, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(image.file.url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(image.file.url.deletingLastPathComponent().path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(L("Строк: \(image.content.lines.count) · Символов: \(image.content.characterCount)", "Lines: \(image.content.lines.count) · Characters: \(image.content.characterCount)"))
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(10).contentShape(Rectangle())
            .background(search.preview?.id == image.id ? GrapeTheme.accent.opacity(0.12) : .primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
            .onTapGesture { search.preview = image }
    }
    private var preview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let image = search.preview {
                    InlineFilePreview(url: image.file.url).frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 10))
                    Text(image.file.url.lastPathComponent).font(.headline).textSelection(.enabled)
                    Button(L("Показать в Finder", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([image.file.url]) }.controlSize(.small)
                    Divider()
                    HStack {
                        Text(L("Распознанный текст", "Recognized Text")).font(.callout.weight(.semibold))
                        Spacer()
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(image.content.text, forType: .string) } label: { Image(systemName: "doc.on.doc") }
                            .help(L("Копировать текст", "Copy Text")).disabled(image.content.lines.isEmpty)
                    }
                    Text(image.content.lines.isEmpty ? L("Текст не обнаружен", "No text detected") : image.content.text)
                        .font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                } else { Text(L("Выберите изображение для просмотра", "Select an image to preview")).foregroundStyle(.secondary) }
            }.padding(16)
        }.background(.thinMaterial)
    }
    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Выбрано: \(search.selectedFiles.count)", "Selected: \(search.selectedFiles.count)")).font(.callout)
                Text(ByteCountFormatter.string(fromByteCount: search.selectedFiles.reduce(0) { $0 + $1.stamp.size }, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu(L("Действия…", "Actions…")) {
                Button(L("Копировать выбранное в папку…", "Copy Selected to Folder…")) { search.export(move: false, model: model) }
                    .disabled(search.selectedFiles.isEmpty)
                Button(L("Переместить выбранное в папку…", "Move Selected to Folder…")) { search.export(move: true, model: model) }
                    .disabled(search.selectedFiles.isEmpty)
                Divider()
                Button(L("Все результаты фильтра в Корзину… (\(search.filtered.count))", "All Filtered Results to Trash… (\(search.filtered.count))"), role: .destructive) { prepareTrash(.filtered) }
                    .disabled(search.filtered.isEmpty)
            }.disabled(search.running)
            Button(L("Выбранное в Корзину… (\(search.selectedFiles.count))", "Move Selected to Trash… (\(search.selectedFiles.count))"), role: .destructive) { prepareTrash(.selected) }
                .disabled(search.running || search.selectedFiles.isEmpty)
            Button(L("Готово", "Done")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(search.running)
        }.padding(16)
    }
    private func prepareTrash(_ scope: ImageTextActionScope) {
        let snapshot = search.snapshot(for: scope)
        guard !snapshot.files.isEmpty else { return }
        pendingTrash = snapshot
        confirmTrash = true
    }
}
