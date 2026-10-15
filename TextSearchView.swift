import SwiftUI
import AppKit

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
        let job = Task.detached(priority: .utility) { try ImageTextEngine.scan(roots, recursive: recursive, cache: cache, progress: update) }
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
    func perform(_ action: ImageTextAction, files: [DuplicateFile], model: Model) {
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
        let files = selectedFiles
        guard !files.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = move ? L("Переместить сюда", "Move Here") : L("Копировать сюда", "Copy Here")
        panel.begin { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            Task { @MainActor in self?.perform(move ? .move(folder) : .copy(folder), files: files, model: model) }
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
    @State private var pendingTrash: [DuplicateFile] = []
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
                ContentUnavailableView(L("Текст на изображениях", "Text in Images"), systemImage: "text.viewfinder",
                    description: Text(L("Выберите файлы или папку и начните поиск. Метаданные не требуются.", "Choose files or a folder and start scanning. Metadata is not required.")))
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
            .confirmationDialog(L("Переместить в Корзину: \(pendingTrash.count)?", "Move \(pendingTrash.count) files to Trash?"), isPresented: $confirmTrash) {
                Button(L("В Корзину: \(pendingTrash.count)", "Move \(pendingTrash.count) to Trash"), role: .destructive) {
                    search.perform(.trash, files: pendingTrash, model: model); pendingTrash = []
                }
                Button(L("Отмена", "Cancel"), role: .cancel) { pendingTrash = [] }
            } message: {
                Text(L("Будут удалены выбранные результаты, включая оригиналы. Здесь нет сохраняемой копии, как в поиске дубликатов. Восстановление — через Корзину Finder; отмена переименования эти файлы не возвращает.",
                       "These results include original files; no copy is protected as it is in duplicate search. Restore files from Finder Trash; rename undo does not restore them."))
            }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Текст на изображениях", "Text in Images")).font(.title2.weight(.semibold))
                    Text(L("Локальное распознавание · Русский и английский · Без отправки файлов", "On-device recognition · Russian and English · No uploads"))
                        .font(.caption).foregroundStyle(.secondary)
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
                Toggle(L("Кэшировать текст локально", "Cache text locally"), isOn: $search.useCache)
                Spacer()
                Button(L("Очистить кэш", "Clear Cache")) { search.clearCache() }.controlSize(.small)
            }.toggleStyle(.checkbox).font(.caption)
        }.padding(20).disabled(search.running)
    }
    private func results(_ report: ImageTextReport) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Picker(L("Показать", "Show"), selection: $search.filter) {
                    ForEach(TextImageFilter.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                TextField(L("Слово или фраза внутри изображения", "Word or phrase within an image"), text: $search.query)
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
            Menu(L("С выбранными…", "Selected Files…")) {
                Button(L("Копировать в папку…", "Copy to Folder…")) { search.export(move: false, model: model) }
                Button(L("Переместить в папку…", "Move to Folder…")) { search.export(move: true, model: model) }
                Divider()
                Button(L("Выбранное в Корзину…", "Move Selected to Trash…"), role: .destructive) { pendingTrash = search.selectedFiles; confirmTrash = true }
            }.disabled(search.running || search.selectedFiles.isEmpty)
            Button(L("Все найденные в Корзину…", "All Matches to Trash…"), role: .destructive) {
                pendingTrash = search.filtered.map(\.file); confirmTrash = true
            }.disabled(search.running || search.filtered.isEmpty)
            Button(L("Готово", "Done")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(search.running)
        }.padding(16)
    }
}
