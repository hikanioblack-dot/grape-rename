import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: Model
    @State private var dropTargeted = false
    @State private var savePreset = false
    @State private var presetName = ""
    @State private var presetError = ""
    @State private var draggedFile: UUID?
    @State private var insertion: FileInsertion?
    var body: some View {
        editor
            .background(Color(nsColor: .windowBackgroundColor))
            .background(PreviewBridge(model: model).frame(width: 0, height: 0))
            .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted, perform: model.acceptDrop)
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 18).fill(GrapeTheme.accent.opacity(0.10))
                        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.purple, style: StrokeStyle(lineWidth: 2, dash: [8, 5])))
                        .overlay(Label(L("Отпустите файлы или папку", "Drop files or a folder"), systemImage: "plus.circle.fill").padding(18).glassEffect())
                        .padding(8).allowsHitTesting(false)
                }
            }
            .alert(L("Ошибка", "Error"), isPresented: $model.showError) { Button(L("Понятно", "OK"), role: .cancel) {} } message: { Text(model.errorMessage) }
            .sheet(item: $model.duplicateMode) { DuplicateFinderView(model: model, mode: $0) }
            .sheet(isPresented: $model.showImageTextSearch) { ImageTextSearchView(model: model) }
            .sheet(isPresented: $model.showHistory) { HistoryView(model: model) }
            .sheet(isPresented: $savePreset) { presetSheet }
            .toolbar {
                if !model.files.isEmpty {
                    ToolbarItem(placement: .navigation) { Button(action: model.reset) { Image(systemName: "chevron.left") }.help(L("Новый набор файлов", "Choose a new batch")) }
                    ToolbarItem(placement: .principal) {
                        Text(model.origin).font(.headline).lineLimit(1).truncationMode(.middle)
                            .padding(.horizontal, 12).frame(maxWidth: 300).fixedSize(horizontal: false, vertical: true).help(model.origin)
                    }
                    ToolbarItem { Button { model.preview.toggle() } label: { Image(systemName: "eye") }.help(L("Просмотр · Пробел", "Quick Look · Space")) }
                    ToolbarItem { Button(action: model.undo) { Image(systemName: "arrow.uturn.backward") }.disabled(model.undoRecord == nil || !model.persistenceError.isEmpty).help(L("Отменить последнее переименование", "Undo the last rename")) }
                }
                ToolbarItem {
                    Button { model.showInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                        .help(model.showInspector ? L("Скрыть предпросмотр и информацию", "Hide Preview and Information") : L("Показать предпросмотр и информацию", "Show Preview and Information"))
                }
                ToolbarItem { Button { model.showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }.help(L("История переименований", "Rename history")) }
            }
            .onAppear {
                let demoPath = ProcessInfo.processInfo.environment["GRAPE_TEST_FILES"] ?? Bundle.main.object(forInfoDictionaryKey: "GrapeTestFiles") as? String
                if model.files.isEmpty, let path = demoPath { model.load([URL(fileURLWithPath: path)], folder: true) }
                model.resizeWindow(loaded: !model.files.isEmpty)
            }
    }
    private var emptyBrowser: some View {
        VStack(spacing: 18) {
            Image(systemName: "doc.badge.plus").font(.system(size: 42, weight: .light)).foregroundStyle(GrapeTheme.accent)
            Text(L("Добавьте файлы для переименования", "Add files to rename")).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Button { model.choose(folder: false) } label: {
                Label(L("Выбрать файлы", "Choose Files"), systemImage: "doc.on.doc")
            }.buttonStyle(.glassProminent).controlSize(.large)
            Button { model.choose(folder: true) } label: {
                Label(L("Выбрать папку…", "Choose Folder…"), systemImage: "folder")
            }.buttonStyle(.plain).foregroundStyle(GrapeTheme.accent)
            Text(L("или перетащите сюда файлы и папки", "or drop files and folders here"))
                .font(.caption).foregroundStyle(.secondary)
            if !model.persistenceError.isEmpty {
                Text(model.persistenceError).font(.caption).foregroundStyle(.orange).lineLimit(3)
            }
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var editor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar.frame(width: 260)
                Divider()
                Group { if model.files.isEmpty { emptyBrowser } else { browser } }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.showInspector { Divider(); FileInspector(model: model).frame(width: 300) }
            }
            Divider()
            footer
        }
    }
    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
    }
    private var sidebar: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeader(L("Название", "Name"), icon: "textformat")
                        TextField(L("Общее название / префикс", "Common name / prefix"), text: $model.options.prefix)
                        HStack { Text(L("Разделитель", "Separator")); Spacer(); TextField("_", text: $model.options.separator).frame(width: 74) }
                        Toggle(L("Оставить исходное имя", "Keep original name"), isOn: $model.options.keepName)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(L("Нумерация", "Numbering"), isOn: $model.options.numbering).fontWeight(.medium)
                        HStack { Text(L("Начать с", "Start at")); Spacer(); TextField("1", value: $model.options.start, format: .number.grouping(.never)).frame(width: 74) }.disabled(!model.options.numbering)
                        HStack {
                            Text(L("Цифр", "Digits")); Spacer()
                            Picker(L("Цифр", "Digits"), selection: $model.options.digits) { ForEach(1...8, id: \.self) { Text("\($0)").tag($0) } }.labelsHidden().frame(width: 74)
                        }.disabled(!model.options.numbering)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader(L("Пример", "Example"), icon: "wand.and.stars")
                        Text(model.files.first.map { model.newName($0, index: 0) } ?? "0001.txt")
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(GrapeTheme.accent).lineLimit(3).textSelection(.enabled)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(GrapeTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    Text(L("Расширения и даты изменения сохраняются.", "Extensions and modification dates are preserved.")).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 20)
                    Divider()
                    VStack(alignment: .leading, spacing: 18) {
                        Text(L("Дополнительно", "Advanced")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 10) {
                                Picker(L("Шаблон", "Preset"), selection: Binding(get: { model.selectedPreset }, set: { model.applyPreset($0) })) {
                                    Text(L("Свои настройки", "Custom settings")).tag(nil as UUID?)
                                    ForEach(model.presets) { Text($0.name).tag(Optional($0.id)) }
                                }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                                HStack {
                                    Button(L("Сохранить…", "Save As…")) { presetName = ""; presetError = ""; savePreset = true }
                                    if model.selectedPreset != nil {
                                        Button { model.updatePreset() } label: { Image(systemName: "arrow.triangle.2.circlepath") }.help(L("Обновить шаблон", "Update preset"))
                                        Button { model.deletePreset() } label: { Image(systemName: "trash") }.help(L("Удалить шаблон", "Delete preset"))
                                    }
                                }.controlSize(.small)
                            }.padding(.top, 10)
                        } label: { Label(L("Шаблоны", "Presets"), systemImage: "slider.horizontal.3") }
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 10) {
                                TextField(L("Найти в исходном имени", "Find in original name"), text: $model.options.find)
                                    .onChange(of: model.options.find) { if !model.options.find.isEmpty { model.options.keepName = true } }
                                TextField(L("Заменить на", "Replace with"), text: $model.options.replacement)
                                Toggle(L("Без учёта регистра", "Ignore case"), isOn: $model.options.caseInsensitive)
                                if !model.options.find.isEmpty && !model.options.keepName {
                                    Text(L("Включите исходное имя для замены.", "Enable the original name to apply replacements.")).font(.caption).foregroundStyle(.orange)
                                }
                            }.padding(.top, 10)
                        } label: {
                            HStack {
                                Label(L("Поиск и замена", "Find & Replace"), systemImage: "text.magnifyingglass")
                                Spacer()
                                if !model.options.find.isEmpty { Text(L("Вкл.", "On")).font(.caption).foregroundStyle(GrapeTheme.accent) }
                            }
                        }
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 10) {
                                Toggle(L("Добавить дату из EXIF", "Add date from EXIF"), isOn: $model.options.useShotDate)
                                if model.options.useShotDate {
                                    Picker(L("Формат", "Format"), selection: $model.options.shotFormat) { ForEach(ShotFormat.allCases) { Text($0.example).tag($0) } }.labelsHidden()
                                    Text(L("Без EXIF: \(model.missingEXIF). Дата не добавляется.", "Without EXIF: \(model.missingEXIF). No date is added.")).font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.top, 10)
                        } label: {
                            HStack {
                                Label(L("Дата съёмки", "Date Taken"), systemImage: "camera")
                                Spacer()
                                if model.options.useShotDate { Text(L("Вкл.", "On")).font(.caption).foregroundStyle(GrapeTheme.accent) }
                            }
                        }
                    }
                }.frame(minHeight: max(0, geometry.size.height - 40), alignment: .topLeading).padding(20)
            }
        }.textFieldStyle(.roundedBorder).toggleStyle(.checkbox).font(.system(size: 12)).background(.thinMaterial)
    }
    private var browser: some View {
        ScrollViewReader { proxy in
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(L("Файлы", "Files")).font(.headline)
                Text("\(model.files.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Menu {
                    Button(L("Добавить файлы…", "Add Files…")) { model.choose(folder: false, append: true) }
                    Button(L("Добавить папку…", "Add Folder…")) { model.choose(folder: true, append: true) }
                } label: { Label(L("Добавить", "Add"), systemImage: "plus") }
                    .menuStyle(.automatic).fixedSize().help(L("Добавить файлы или папку", "Add files or a folder"))
            }.padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 9)
            HStack(spacing: 10) {
                Picker(L("Сортировка", "Sort"), selection: $model.sortMode) { ForEach(SortMode.allCases) { Text($0.title).tag($0) } }
                    .labelsHidden().frame(width: 148).onChange(of: model.sortMode) { model.sort() }
                Button { model.descending.toggle(); model.sort() } label: { Image(systemName: model.descending ? "arrow.down" : "arrow.up") }.disabled(model.sortMode == .manual).help(L("Направление сортировки", "Sort direction"))
                Spacer(minLength: 8)
                Picker(L("Вид", "View"), selection: $model.viewMode) {
                    ForEach(FileViewMode.allCases) { mode in Image(systemName: mode.symbol).tag(mode).help(mode.title).accessibilityLabel(mode.title) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 118)
            }.padding(.horizontal, 18).padding(.bottom, 12)
            Divider()
            if model.viewMode == .grid { gridView } else { listView }
            Divider()
            HStack(spacing: 12) {
                Text(model.grid ? L("Слева направо, сверху вниз", "Left to right, top to bottom") : L("Сверху вниз", "Top to bottom")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if model.grid {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                    Slider(value: $model.thumbnailSize, in: 120...240).frame(width: 95).help(L("Размер миниатюр", "Thumbnail size"))
                }
                Button { model.moveSelection(-1) } label: { Image(systemName: "chevron.up") }.disabled(model.selection == nil || model.files.first?.id == model.selection)
                Button { model.moveSelection(1) } label: { Image(systemName: "chevron.down") }.disabled(model.selection == nil || model.files.last?.id == model.selection)
            }.padding(.horizontal, 20).padding(.vertical, 11)
        }
        .onAppear { keepSelectionVisible(proxy) }
        .onChange(of: model.selection) { keepSelectionVisible(proxy) }
        .onChange(of: model.viewMode) { keepSelectionVisible(proxy) }
        .onChange(of: model.showInspector) { keepSelectionVisible(proxy) }
        .onChange(of: model.thumbnailSize) { keepSelectionVisible(proxy) }
        .onChange(of: model.files.map(\.id)) { keepSelectionVisible(proxy) }
        }
    }
    private func keepSelectionVisible(_ proxy: ScrollViewProxy) {
        guard let selection = model.selection else { return }
        // Wait for columns and row heights to settle after a layout change.
        DispatchQueue.main.async { proxy.scrollTo(selection) }
    }
    private var listView: some View {
        GeometryReader { geometry in
            let nameWidth = max(110, (geometry.size.width - 142) / 2)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("#").frame(width: 26, alignment: .leading)
                    Text(L("Исходное имя", "Current Name")).frame(width: nameWidth, alignment: .leading)
                    Text(L("Новое имя", "New Name")).frame(width: nameWidth, alignment: .leading)
                    Text(L("Размер", "Size")).frame(width: 54, alignment: .trailing)
                }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading).background(.quinary)
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(model.files.enumerated()), id: \.element.id) { index, row in
                            HStack(spacing: 10) {
                                Text(String(index + 1)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 26, alignment: .leading)
                                HStack(spacing: 10) {
                                    if model.viewMode == .thumbnails { FileThumbnail(row: row, width: 36, height: 40) }
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(row.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                        if model.viewMode == .thumbnails { Text(Language.date(row.stamp.modified)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.frame(width: nameWidth, alignment: .leading)
                                Text(model.newName(row, index: index)).foregroundStyle(GrapeTheme.accent).lineLimit(model.viewMode == .compact ? 1 : 2).truncationMode(.middle).frame(width: nameWidth, alignment: .leading)
                                Text(ByteCountFormatter.string(fromByteCount: row.stamp.size, countStyle: .file)).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 54, alignment: .trailing)
                            }.font(.system(size: 12)).padding(.horizontal, 16).padding(.vertical, model.viewMode == .compact ? 4 : 8)
                                .frame(maxWidth: .infinity, minHeight: model.viewMode == .compact ? 24 : 56, alignment: .leading)
                                .background(model.selection == row.id ? GrapeTheme.accent.opacity(0.13) : (index.isMultiple(of: 2) ? Color.primary.opacity(0.025) : .clear))
                                .modifier(FileInteractions(model: model, row: row, draggedFile: $draggedFile, insertion: $insertion))
                                .id(row.id)
                        }
                    }.padding(.vertical, 4)
                }
            }
        }
    }
    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: model.thumbnailSize + 24), spacing: 14)], spacing: 14) {
                ForEach(Array(model.files.enumerated()), id: \.element.id) { index, row in
                    VStack(alignment: .leading, spacing: 9) {
                        ZStack(alignment: .topLeading) {
                            FileThumbnail(row: row, width: model.thumbnailSize, height: model.thumbnailSize)
                                .frame(maxWidth: .infinity).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                            Text(String(index + 1)).font(.system(size: 10, weight: .semibold, design: .monospaced)).padding(.horizontal, 7).padding(.vertical, 4).background(.regularMaterial, in: Capsule()).padding(6)
                        }
                        Text(row.url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        Text(model.newName(row, index: index)).font(.system(size: 11)).foregroundStyle(GrapeTheme.accent).lineLimit(2).truncationMode(.middle).frame(height: 30, alignment: .topLeading)
                    }.padding(12).background(model.selection == row.id ? GrapeTheme.accent.opacity(0.10) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
                        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(model.selection == row.id ? GrapeTheme.accent.opacity(0.65) : Color.primary.opacity(0.07), lineWidth: 1))
                        .modifier(FileInteractions(model: model, row: row, draggedFile: $draggedFile, insertion: $insertion))
                        .id(row.id)
                }
            }.padding(18)
        }
    }
    private var footer: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                if let warning = model.validation { Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption).lineLimit(2) }
                else if !model.message.isEmpty { Label(model.message, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption).lineLimit(2) }
                else {
                    Text(L("К переименованию: \(model.changes)", "Ready to rename: \(model.changes)")).font(.system(size: 12, weight: .medium))
                    Text(L("Пробел — быстрый просмотр", "Space — Quick Look")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button(action: model.rename) { Label(L("Переименовать", "Rename"), systemImage: "checkmark").padding(.horizontal, 8) }
                .buttonStyle(.glassProminent).controlSize(.large).disabled(model.busy || model.validation != nil || model.changes == 0)
        }.padding(.horizontal, 22).padding(.vertical, 15).frame(minHeight: 72).background(.bar)
    }
    private var presetSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("Сохранить шаблон", "Save Preset")).font(.title2.weight(.semibold))
            TextField(L("Название шаблона", "Preset name"), text: $presetName).textFieldStyle(.roundedBorder)
            if !presetError.isEmpty { Text(presetError).foregroundStyle(.orange).font(.caption) }
            HStack { Spacer(); Button(L("Отмена", "Cancel")) { savePreset = false }.keyboardShortcut(.cancelAction); Button(L("Сохранить", "Save")) { do { try model.savePreset(name: presetName); savePreset = false } catch { presetError = error.localizedDescription } }.keyboardShortcut(.defaultAction).disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 380)
    }
}

struct FileInteractions: ViewModifier {
    @ObservedObject var model: Model
    let row: FileRow
    @Binding var draggedFile: UUID?
    @Binding var insertion: FileInsertion?
    @State private var rowHeight: CGFloat = 24
    private func select() { model.selection = row.id; model.preview.focusFiles() }
    func body(content: Content) -> some View {
        content.contentShape(Rectangle()).onTapGesture { select() }
            .simultaneousGesture(TapGesture(count: 2).onEnded { select(); model.preview.toggle() })
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowHeight = $0 }
            .draggable(row.id.uuidString)
            .onDrop(of: [UTType.plainText, .fileURL], delegate: FileOrderDrop(model: model, row: row, height: rowHeight, draggedFile: $draggedFile, insertion: $insertion))
            .overlay(alignment: insertion?.after == true ? .bottom : .top) {
                if !model.grid, draggedFile != nil, insertion?.row == row.id {
                    HStack(spacing: 0) {
                        Circle().fill(GrapeTheme.accent).frame(width: 6, height: 6)
                        Rectangle().fill(GrapeTheme.accent).frame(height: 2)
                    }.padding(.horizontal, 6).offset(y: insertion?.after == true ? 3 : -3).allowsHitTesting(false)
                }
            }
            .zIndex(insertion?.row == row.id ? 1 : 0)
            .contextMenu {
                Button(L("Быстрый просмотр", "Quick Look")) { model.selection = row.id; model.preview.toggle() }
                Button(L("Показать информацию", "Show Information")) { model.selection = row.id; model.revealInspector() }
                Button(L("Показать в Finder", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([row.url]) }
                Divider()
                Button(L("Убрать из списка", "Remove from List")) { model.remove(row.id) }
            }
            .help(row.url.path)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(model.selection == row.id ? [.isSelected] : [])
            .accessibilityAction { select() }
    }
}

struct FileInsertion: Equatable {
    let row: UUID
    let after: Bool
}

struct FileOrderDrop: DropDelegate {
    let model: Model
    let row: FileRow
    let height: CGFloat
    @Binding var draggedFile: UUID?
    @Binding var insertion: FileInsertion?
    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL, .plainText])
    }
    func dropEntered(info: DropInfo) {
        guard !info.hasItemsConforming(to: [.fileURL]), let provider = info.itemProviders(for: [.plainText]).first else { return }
        draggedFile = nil
        insertion = FileInsertion(row: row.id, after: info.location.y >= height / 2)
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let value = object as? String, let id = UUID(uuidString: value) else { return }
            Task { @MainActor in
                guard insertion?.row == row.id, model.files.contains(where: { $0.id == id }) else { return }
                draggedFile = id
            }
        }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateMarker(info)
        return DropProposal(operation: info.hasItemsConforming(to: [.fileURL]) ? .copy : .move)
    }
    func dropExited(info: DropInfo) { if insertion?.row == row.id { insertion = nil } }
    private func updateMarker(_ info: DropInfo) {
        guard !model.grid, !info.hasItemsConforming(to: [.fileURL]), insertion?.row == row.id else { return }
        insertion = FileInsertion(row: row.id, after: info.location.y >= height / 2)
    }
    func performDrop(info: DropInfo) -> Bool {
        defer { insertion = nil; draggedFile = nil }
        if !info.hasItemsConforming(to: [.fileURL]),
           let provider = info.itemProviders(for: [.plainText]).first,
           let target = model.files.firstIndex(where: { $0.id == row.id }) {
            let destination = target + (info.location.y >= height / 2 ? 1 : 0)
            let grid = model.grid
            provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let id = object as? String, let source = UUID(uuidString: id) else { return }
                Task { @MainActor in
                    guard model.files.contains(where: { $0.id == source }) else { return }
                    if grid { model.drop(id, onto: row.id) }
                    else { model.insert(source, at: destination) }
                    model.preview.focusFiles()
                }
            }
            return true
        }
        return model.acceptDrop(info.itemProviders(for: [.fileURL]))
    }
}
