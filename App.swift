import SwiftUI
import AppKit

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
        if let index = CommandLine.arguments.firstIndex(of: "--make-duplicate-fixtures"), CommandLine.arguments.indices.contains(index + 1) {
            do { try TestFixtures.createDuplicateSamples(at: URL(fileURLWithPath: CommandLine.arguments[index + 1])); print("Duplicate samples created"); exit(0) }
            catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--make-fixtures"), CommandLine.arguments.indices.contains(index + 1) {
            do { try TestFixtures.create(at: URL(fileURLWithPath: CommandLine.arguments[index + 1])); print("Fixtures created"); exit(0) }
            catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--self-test") {
            do { try runSelfTests(); try runIntegrationTests(); try runFeatureTests(); try runDuplicateTests(); print("LANGUAGE: \(Language.isRussian ? "ru" : "en")"); exit(0) }
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
                    Button(L("Выбрать файлы…", "Choose Files…")) { model.choose(folder: false) }.keyboardShortcut("o")
                    Button(L("Выбрать папку…", "Choose Folder…")) { model.choose(folder: true) }.keyboardShortcut("o", modifiers: [.command, .shift])
                }
                CommandGroup(replacing: .undoRedo) { Button(L("Отменить переименование", "Undo Rename")) { model.undo() }.keyboardShortcut("z").disabled(model.undoRecord == nil || !model.persistenceError.isEmpty) }
                CommandMenu(L("Инструменты", "Tools")) {
                    Button(L("Найти точные дубликаты…", "Find Exact Duplicates…")) { model.duplicateMode = .exact }
                    Button(L("Найти похожие фотографии…", "Find Similar Photos…")) { model.duplicateMode = .similar }
                }
                CommandMenu(L("Файлы", "Files")) {
                    Button(L("Показать информацию о файле", "Show File Information")) { model.revealInspector() }.keyboardShortcut("i").disabled(model.selection == nil)
                    Button(L("История", "History")) { model.showHistory = true }.keyboardShortcut("h", modifiers: [.command, .shift])
                }
            }
    }
}
