import SwiftUI
import AppKit

@MainActor
final class DuplicateSearch: ObservableObject {
    @Published var roots: [URL]
    @Published var recursive = true
    @Published var similarity: PhotoSimilarity = .balanced
    @Published var report: DuplicateReport?
    @Published var progress = DuplicateProgress(fraction: 0, message: "")
    @Published var running = false
    @Published var selection = Set<String>()
    @Published var keepers: [UUID: String] = [:]
    @Published var preview: DuplicateFile?
    @Published var error = ""
    @Published var notice = ""
    private var worker: Task<DuplicateReport, Error>?
    private var generation: UUID?

    init(files: [FileRow]) { roots = files.map(\.url) }
    var selectedFiles: [DuplicateFile] {
        report?.groups.flatMap { group in
            group.files.filter { selection.contains($0.id) && !isKeeper($0, in: group) }
        } ?? []
    }
    var selectedSize: Int64 { selectedFiles.reduce(0) { $0 + $1.stamp.size } }

    func invalidate() {
        cancel(); report = nil; selection = []; keepers = [:]; preview = nil; error = ""; notice = ""
        progress = DuplicateProgress(fraction: 0, message: "")
    }
    func cancel() {
        worker?.cancel(); worker = nil; generation = nil
        if running { notice = L("Поиск отменён.", "Search cancelled.") }
        running = false
    }
    func choose(folder: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !folder; panel.canChooseDirectories = folder; panel.allowsMultipleSelection = true
        panel.prompt = L("Выбрать", "Choose")
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in
                self?.invalidate(); self?.roots = panel.urls
            }
        }
    }
    func start(_ mode: DuplicateMode) {
        guard !running, !roots.isEmpty else { return }
        invalidate()
        running = true
        let id = UUID(); generation = id
        let roots = roots, recursive = recursive, similarity = similarity
        let receiveProgress: @Sendable (DuplicateProgress) -> Void = { [weak self] update in
            guard let self else { return }
            Task { @MainActor in
                guard self.generation == id else { return }
                self.progress = update
            }
        }
        let job = Task.detached(priority: .utility) {
            try DuplicateEngine.scan(roots, recursive: recursive, mode: mode, similarity: similarity, progress: receiveProgress)
        }
        worker = job
        Task { [weak self] in
            do {
                let report = try await job.value
                guard let self, self.generation == id else { return }
                self.report = report
                self.keepers = Dictionary(uniqueKeysWithValues: report.groups.map { ($0.id, $0.files[0].id) })
                self.preview = report.groups.first?.files.first
                self.running = false; self.worker = nil; self.generation = nil
            } catch {
                guard let self, self.generation == id else { return }
                self.error = error.localizedDescription
                self.running = false; self.worker = nil; self.generation = nil
            }
        }
    }
    func isKeeper(_ file: DuplicateFile, in group: DuplicateGroup) -> Bool { (keepers[group.id] ?? group.files.first?.id) == file.id }
    func keep(_ file: DuplicateFile, in group: DuplicateGroup) {
        keepers[group.id] = file.id; selection.remove(file.id)
    }
    func selectCopies() {
        selection = Set(report?.groups.flatMap { group in group.files.filter { !isKeeper($0, in: group) }.map(\.id) } ?? [])
    }
    func removeFromResults(_ urls: Set<URL>) {
        guard var report else { return }
        for i in report.groups.indices { report.groups[i].files.removeAll { urls.contains($0.url) } }
        report.groups.removeAll { $0.files.count < 2 }
        self.report = report; selection = []
        if let preview, urls.contains(preview.url) { self.preview = report.groups.first?.files.first }
        for group in report.groups where !group.files.contains(where: { $0.id == keepers[group.id] }) {
            keepers[group.id] = group.files[0].id
        }
    }
    func exclude(from model: Model) {
        let targets = Set(selectedFiles.map(\.url))
        model.removeFiles(at: targets)
        removeFromResults(targets)
        notice = L("Выбранные файлы исключены из набора. На диске всё сохранено.", "Selected files removed from the batch. Files on disk are unchanged.")
    }
    func trash(from model: Model) {
        let files = selectedFiles
        do {
            // Validate the whole selection before moving anything.
            for file in files { try DuplicateEngine.assertUnchanged(file) }
        } catch { self.error = error.localizedDescription; return }
        var moved = Set<URL>(), failures: [String] = []
        for file in files {
            do {
                try DuplicateEngine.assertUnchanged(file)
                try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
                moved.insert(file.url)
            } catch { failures.append("\(file.url.lastPathComponent): \(error.localizedDescription)") }
        }
        model.removeFiles(at: moved); removeFromResults(moved)
        notice = L("Перемещено в Корзину: \(moved.count). Восстановление доступно в Finder.",
                   "Moved to Trash: \(moved.count). Restore files in Finder.")
        if !failures.isEmpty { error = failures.joined(separator: "\n") }
    }
}

struct DuplicateFinderView: View {
    @ObservedObject var model: Model
    @State private var mode: DuplicateMode
    @StateObject private var search: DuplicateSearch
    @Environment(\.dismiss) private var dismiss
    @State private var confirmTrash = false
    init(model: Model, mode: DuplicateMode) {
        self.model = model
        _mode = State(initialValue: mode)
        _search = StateObject(wrappedValue: DuplicateSearch(files: model.files))
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if search.running {
                VStack(spacing: 14) {
                    ProgressView(value: search.progress.fraction).frame(maxWidth: 420)
                    Text(search.progress.message).font(.callout).lineLimit(2)
                    Text(L("Обработка на этом Mac. Файлы никуда не отправляются.", "Processed on this Mac. Files are never uploaded."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(L("Остановить", "Stop")) { search.cancel() }
                }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let report = search.report {
                results(report)
            } else {
                ContentUnavailableView(mode.title, systemImage: mode == .exact ? "doc.on.doc" : "photo.on.rectangle.angled",
                    description: Text(search.roots.isEmpty
                        ? L("Выберите файлы или папки для проверки.", "Choose files or folders to scan.")
                        : L("Нажмите «Начать поиск», чтобы проверить выбранный набор.", "Click Start Search to scan the chosen files.")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if !search.notice.isEmpty { Text(search.notice).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 8) }
            Divider()
            footer
        }.frame(width: 1000, height: 700)
            .onChange(of: mode) { search.invalidate() }
            .onChange(of: search.recursive) { search.invalidate() }
            .onChange(of: search.similarity) { search.invalidate() }
            .onDisappear { search.cancel() }
            .interactiveDismissDisabled(search.running)
            .alert(L("Ошибка", "Error"), isPresented: Binding(get: { !search.error.isEmpty }, set: { if !$0 { search.error = "" } })) {
                Button(L("Понятно", "OK")) { search.error = "" }
            } message: { Text(search.error) }
            .confirmationDialog(L("Переместить выбранные файлы в Корзину?", "Move selected files to Trash?"), isPresented: $confirmTrash) {
                Button(L("В Корзину: \(search.selectedFiles.count)", "Move \(search.selectedFiles.count) to Trash"), role: .destructive) { search.trash(from: model) }
                Button(L("Отмена", "Cancel"), role: .cancel) {}
            } message: {
                Text(L("В каждой группе останется сохраняемый файл. Вернуть остальные можно через Корзину Finder; отмена переименования не восстанавливает файлы из Корзины.",
                       "The file marked Keep remains in each group. Restore other files from Finder Trash; rename undo does not restore trashed files."))
            }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("Найти и изменить медиафайлы", "Find and Modify Media Files")).font(.title2.weight(.semibold))
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).disabled(search.running)
                    .help(L("Закрыть", "Close"))
            }
            Picker(L("Инструмент", "Tool"), selection: $mode) {
                Text(DuplicateMode.exact.title).tag(DuplicateMode.exact)
                Text(DuplicateMode.similar.title).tag(DuplicateMode.similar)
            }.pickerStyle(.segmented).labelsHidden().disabled(search.running)
            HStack(spacing: 12) {
                Text(search.roots.isEmpty ? L("Набор не выбран", "No files selected")
                    : (search.roots.count == 1 ? search.roots[0].lastPathComponent : L("Выбрано объектов: \(search.roots.count)", "Selected items: \(search.roots.count)")))
                    .lineLimit(1).truncationMode(.middle).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                Menu(L("Выбрать…", "Choose…")) {
                    Button(L("Файлы…", "Files…")) { search.choose(folder: false) }
                    Button(L("Папки…", "Folders…")) { search.choose(folder: true) }
                    if !model.files.isEmpty {
                        Button(L("Файлы из основного списка", "Files from Main List")) { search.invalidate(); search.roots = model.files.map(\.url) }
                    }
                }.fixedSize().disabled(search.running)
                Button(L("Начать поиск", "Start Search")) { search.start(mode) }
                    .buttonStyle(.glassProminent).disabled(search.running || search.roots.isEmpty)
            }
            HStack(spacing: 20) {
                Toggle(L("Включая вложенные папки", "Include subfolders"), isOn: $search.recursive).toggleStyle(.checkbox)
                if mode == .similar {
                    Picker(L("Сходство", "Similarity"), selection: $search.similarity) {
                        ForEach(PhotoSimilarity.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).frame(width: 320)
                }
            }.font(.caption).disabled(search.running)
        }.padding(20)
    }
    private func results(_ report: DuplicateReport) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(L("Групп: \(report.groups.count)", "Groups: \(report.groups.count)")).fontWeight(.semibold)
                    Spacer()
                    if mode == .exact, !report.groups.isEmpty {
                        Button(L("В Корзину все копии…", "Move All Copies to Trash…"), role: .destructive) {
                            search.selectCopies()
                            confirmTrash = true
                        }.controlSize(.small)
                    }
                    if !search.selection.isEmpty { Button(L("Снять выбор", "Deselect All")) { search.selection = [] }.controlSize(.small) }
                }.font(.callout).padding(16)
                if !report.groups.isEmpty {
                    Text(L("«Оставить» — сохраняемый файл. Галочки — файлы для удаления.", "Keep marks the file to preserve. Checkboxes select files for removal."))
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 12)
                }
                if report.groups.isEmpty {
                    ContentUnavailableView(L("Совпадений не найдено", "No Matches Found"), systemImage: "checkmark.circle",
                        description: Text(L("Проверено файлов: \(report.inspected)", "Files checked: \(report.inspected)")))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(Array(report.groups.enumerated()), id: \.element.id) { index, group in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(L("Группа \(index + 1) · Файлов: \(group.files.count)", "Group \(index + 1) · Files: \(group.files.count)"))
                                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 3)
                                    ForEach(group.files) { file in resultRow(file, group: group) }
                                }
                            }
                        }.padding(.horizontal, 16).padding(.bottom, 16)
                    }
                }
                if report.skippedLinks > 0 { Text(L("Повторные жёсткие ссылки пропущены: \(report.skippedLinks)", "Repeated hard links skipped: \(report.skippedLinks)")).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 8) }
                if !report.warnings.isEmpty {
                    DisclosureGroup(L("Не удалось проверить: \(report.warnings.count)", "Unable to check: \(report.warnings.count)")) {
                        ScrollView { Text(report.warnings.joined(separator: "\n")).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 75)
                    }.font(.caption).foregroundStyle(.orange).padding(16)
                }
            }
            Divider()
            resultPreview.frame(width: 260)
        }
    }
    private func resultRow(_ file: DuplicateFile, group: DuplicateGroup) -> some View {
        let keeper = search.isKeeper(file, in: group)
        return HStack(spacing: 10) {
            Toggle(L("Выбрать \(file.url.lastPathComponent)", "Select \(file.url.lastPathComponent)"), isOn: Binding(
                get: { search.selection.contains(file.id) },
                set: { if $0 { search.selection.insert(file.id) } else { search.selection.remove(file.id) } }
            )).labelsHidden().toggleStyle(.checkbox).disabled(keeper)
            FileThumbnail(row: FileRow(url: file.url, stamp: file.stamp, readMetadata: false), width: 38, height: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(file.url.deletingLastPathComponent().path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(ByteCountFormatter.string(fromByteCount: file.stamp.size, countStyle: .file)).font(.system(size: 10)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if keeper {
                Label(L("Оставить", "Keep"), systemImage: "checkmark.shield").font(.caption).foregroundStyle(.green)
            } else {
                Button(L("Оставить", "Keep")) { search.keep(file, in: group) }.controlSize(.small)
            }
        }.padding(10).contentShape(Rectangle())
            .background(search.preview?.id == file.id ? GrapeTheme.accent.opacity(0.12) : .primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
            .onTapGesture { search.preview = file }
    }
    private var resultPreview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let file = search.preview {
                    InlineFilePreview(url: file.url).frame(height: 230).clipShape(RoundedRectangle(cornerRadius: 10))
                    Text(file.url.lastPathComponent).font(.headline).textSelection(.enabled)
                    Text(file.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(ByteCountFormatter.string(fromByteCount: file.stamp.size, countStyle: .file)).font(.callout)
                    Button(L("Показать в Finder", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }.controlSize(.small)
                } else {
                    Text(L("Выберите файл для просмотра", "Select a file to preview")).font(.callout).foregroundStyle(.secondary)
                }
                Text(mode == .exact
                    ? L("Совпадение подтверждено по содержимому. В каждой группе сохраняется один файл на ваш выбор.", "Content matches have been verified. One file of your choice is kept in each group.")
                    : L("Сходство не означает одинаковое содержимое. Сравните фотографии и отметьте ненужные вручную.", "Similarity does not mean identical content. Compare the photos and select unwanted files manually."))
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }.background(.thinMaterial)
    }
    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Выбрано: \(search.selectedFiles.count)", "Selected: \(search.selectedFiles.count)")).font(.callout)
                Text(L("Размер: ", "Size: ") + ByteCountFormatter.string(fromByteCount: search.selectedSize, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("Убрать из набора", "Remove from Batch")) { search.exclude(from: model) }
                .disabled(search.running || !search.selectedFiles.contains(where: { file in model.files.contains(where: { $0.url == file.url }) }))
            Button(L("Выбранное в Корзину…", "Move Selected to Trash…"), role: .destructive) { confirmTrash = true }
                .disabled(search.running || search.selectedFiles.isEmpty)
            Button(L("Готово", "Done")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(search.running)
        }.padding(16)
    }
}
