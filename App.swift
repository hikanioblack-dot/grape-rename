import SwiftUI
import AppKit

/// SwiftUI owns the menus; keep the former View commands in Window after rebuilds.
@MainActor
final class AppMenuOrganizer: NSObject {
    static let shared = AppMenuOrganizer()
    private var installed = false
    private var scheduled = false
    private var applying = false

    func install() {
        guard !installed else { return }
        installed = true
        for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(menuChanged), name: name, object: nil)
        }
        schedule()
    }
    @objc private func menuChanged(_ notification: Notification) { schedule() }
    private func schedule() {
        guard !applying, !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            guard let main = NSApp?.mainMenu, let window = NSApp?.windowsMenu,
                  let view = main.items.first(where: { ["View", "Вид"].contains($0.title) }),
                  let submenu = view.submenu, submenu !== window else { return }
            self.applying = true
            defer { self.applying = false }
            if !submenu.items.isEmpty && !window.items.isEmpty { window.addItem(.separator()) }
            for item in submenu.items {
                submenu.removeItem(item)
                // Full screen has a stable SwiftUI command in Window below.
                if item.action == #selector(NSWindow.toggleFullScreen(_:)) || item.title.localizedCaseInsensitiveContains("full screen") || item.title.localizedCaseInsensitiveContains("полноэкранный") { continue }
                window.addItem(item)
            }
            main.removeItem(view)
        }
    }
}

enum AppVersion {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—" }
    static func showAbout() {
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "Grape Rename", .applicationVersion: version, .version: build
        ])
    }
}

@main
struct GrapeRenameApp: App {
    @StateObject private var model: Model
    init() {
        if let index = CommandLine.arguments.firstIndex(of: "--make-review-fixtures"), CommandLine.arguments.indices.contains(index + 1) {
            do { try TestFixtures.createReviewSamples(at: URL(fileURLWithPath: CommandLine.arguments[index + 1])); print("Review samples created"); exit(0) }
            catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--prepare-ui-test"), CommandLine.arguments.indices.contains(index + 1) {
            do {
                let root = URL(fileURLWithPath: CommandLine.arguments[index + 1])
                let files = root.appendingPathComponent("files")
                try TestFixtures.create(at: files)
                let test = Model(storageURL: root.appendingPathComponent("state.json"))
                test.load([files], folder: true); test.options.prefix = "Grape"; test.options.useShotDate = true
                try test.savePreset(name: "Photos with EXIF")
                test.rename(); test.undo()
                guard !test.showError else { throw RenameError.message(test.errorMessage) }
                print("UI fixtures, preset and history prepared"); exit(0)
            } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--make-text-fixtures"), CommandLine.arguments.indices.contains(index + 1) {
            do { try TestFixtures.createTextSamples(at: URL(fileURLWithPath: CommandLine.arguments[index + 1])); print("Text samples created"); exit(0) }
            catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--make-duplicate-fixtures"), CommandLine.arguments.indices.contains(index + 1) {
            do { try TestFixtures.createDuplicateSamples(at: URL(fileURLWithPath: CommandLine.arguments[index + 1])); print("Duplicate samples created"); exit(0) }
            catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--make-fixtures"), CommandLine.arguments.indices.contains(index + 1) {
            do { try TestFixtures.create(at: URL(fileURLWithPath: CommandLine.arguments[index + 1])); print("Fixtures created"); exit(0) }
            catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--self-test") {
            do { try runSelfTests(); try runIntegrationTests(); try runFeatureTests(); try runDuplicateTests(); try runImageTextTests()
                Task { @MainActor in
                    do { try await runAsyncImportTests(); print("LANGUAGE: \(Language.isRussian ? "ru" : "en")"); exit(0) }
                    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
                }
                dispatchMain() }
            catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        _model = StateObject(wrappedValue: Model())
    }
    var body: some Scene {
        Window("Grape Rename", id: "main") { ContentView(model: model).tint(GrapeTheme.accent) }
            .defaultSize(width: 1280, height: 780)
            .commands {
                CommandGroup(replacing: .appInfo) {
                    Button(L("О Grape Rename", "About Grape Rename"), action: AppVersion.showAbout)
                }
                CommandGroup(replacing: .help) {
                    Button(L("Версия Grape Rename: \(AppVersion.version)…", "Grape Rename Version: \(AppVersion.version)…"), action: AppVersion.showAbout)
                }
                CommandGroup(replacing: .newItem) {
                    Button(L("Выбрать файлы…", "Choose Files…")) { model.choose(folder: false) }.keyboardShortcut("o").disabled(model.busy)
                    Button(L("Выбрать папку…", "Choose Folder…")) { model.choose(folder: true) }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(model.busy)
                }
                CommandGroup(after: .newItem) {
                    Divider()
                    Button(L("Показать информацию о файле", "Show File Information")) { model.revealInspector() }.keyboardShortcut("i").disabled(model.selection == nil)
                    Button(L("История", "History")) { model.showHistory = true }.keyboardShortcut("h", modifiers: [.command, .shift]).disabled(model.busy)
                }
                CommandGroup(replacing: .undoRedo) { Button(L("Отменить переименование", "Undo Rename")) { model.undo() }.keyboardShortcut("z").disabled(model.busy || model.undoRecord == nil || !model.persistenceError.isEmpty) }
                CommandGroup(after: .windowArrangement) {
                    Divider()
                    Button(L("Полноэкранный режим", "Full Screen")) {
                        NSApp.sendAction(#selector(NSWindow.toggleFullScreen(_:)), to: nil, from: nil)
                    }.keyboardShortcut("f", modifiers: [.control, .command])
                }
                CommandMenu(L("Инструменты", "Tools")) {
                    Button(L("Найти и изменить медиафайлы…", "Find and Modify Media Files…")) { model.duplicateMode = .exact }.disabled(model.busy)
                    Button(L("Поиск текста на медиафайлах…", "Find Text in Media Files…")) { model.showImageTextSearch = true }.disabled(model.busy)
                }
            }
    }
}
