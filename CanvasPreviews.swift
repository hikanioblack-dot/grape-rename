#if DEBUG
import SwiftUI

/// Xcode-only previews use synthetic files and their own history.
/// Keep PreviewProvider so the command-line build does not require preview macros.
@MainActor
private struct GrapeCanvasPreview: View {
    @StateObject private var model: Model

    init(populated: Bool) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrapeRenameCanvas", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = Model(storageURL: root.appendingPathComponent("state.json"))
        if populated {
            do {
                let samples = root.appendingPathComponent("Samples", isDirectory: true)
                try FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)
                for name in ["Notes.txt", "Project overview.txt", "A longer filename for checking the layout.txt"] {
                    try "Grape Rename — Canvas sample\n".write(
                        to: samples.appendingPathComponent(name), atomically: true, encoding: .utf8)
                }
                model.load([samples], folder: true)
                model.options.prefix = "Grape"
            } catch { model.fail(error) }
        }
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        ContentView(model: model)
            .tint(GrapeTheme.accent)
            .frame(width: 1280, height: 780)
    }
}

struct GrapeRenameCanvasPreviews: PreviewProvider {
    static var previews: some View {
        Group {
            GrapeCanvasPreview(populated: true)
                .previewDisplayName("Files / Файлы")
            GrapeCanvasPreview(populated: false)
                .previewDisplayName("Empty / Пустое окно")
        }
    }
}
#endif
