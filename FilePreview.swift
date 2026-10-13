import SwiftUI
import AppKit
import QuickLookUI
import QuickLookThumbnailing

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let images = NSCache<NSString, NSImage>()
    init() { images.countLimit = 400; images.totalCostLimit = 48 * 1024 * 1024 }
    func image(for key: String) -> NSImage? { images.object(forKey: key as NSString) }
    func insert(_ image: NSImage, key: String) { images.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height * 16)) }
}

struct FileThumbnail: View {
    let row: FileRow
    var width: Double = 44
    var height: Double = 48
    @State private var image: NSImage?
    @State private var snippet: String?
    @State private var loading = true
    private var key: String { "\(row.url.path)|\(row.stamp.modifiedSeconds)|\(row.stamp.modifiedNanos)|\(row.stamp.size)|\(Int(width))x\(Int(height))" }
    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else if let snippet {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 3).fill(.white)
                    Text(snippet).font(.system(size: max(4, width / 18), design: .monospaced)).foregroundStyle(.black.opacity(0.8)).padding(max(4, width / 12)).lineLimit(12)
                }.padding(3).shadow(color: .black.opacity(0.12), radius: 1)
            } else if loading {
                ProgressView().controlSize(.mini)
            } else {
                Text(row.url.pathExtension.isEmpty ? "FILE" : row.url.pathExtension.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
        }.frame(width: width, height: height).accessibilityLabel(L("Миниатюра \(row.url.lastPathComponent)", "Thumbnail of \(row.url.lastPathComponent)"))
            .task(id: key) { await generate() }
    }
    @MainActor
    private func generate() async {
        image = nil; snippet = nil; loading = true
        let cacheKey = key
        if let cached = ThumbnailCache.shared.image(for: cacheKey) { image = cached; loading = false; return }
        let request = QLThumbnailGenerator.Request(fileAt: row.url, size: CGSize(width: width, height: height), scale: 2, representationTypes: .thumbnail)
        do {
            let result = try await withTaskCancellationHandler {
                try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            } onCancel: {
                QLThumbnailGenerator.shared.cancel(request)
            }
            guard !Task.isCancelled else { return }
            image = result.nsImage
            ThumbnailCache.shared.insert(result.nsImage, key: cacheKey)
        } catch {
            guard !Task.isCancelled else { return }
            let textTypes = ["txt", "md", "csv", "tsv", "json", "log", "xml", "yaml", "yml", "swift", "py", "js", "css"]
            if textTypes.contains(row.url.pathExtension.lowercased()), let handle = try? FileHandle(forReadingFrom: row.url) {
                defer { try? handle.close() }
                if let data = try? handle.read(upToCount: 512) { snippet = String(decoding: data, as: UTF8.self) }
            }
        }
        loading = false
    }
}

/// Makes the native preview controller part of the main window's responder chain.
@MainActor
final class PreviewHostView: NSView {
    weak var owner: PreviewController?
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); owner?.attach(to: window) }
}

@MainActor
final class PreviewController: NSViewController, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    weak var model: Model?
    weak var attachedWindow: NSWindow?
    private var oldResponder: NSResponder?
    private var monitor: Any?
    private var lastURLs: [URL] = []
    private var lastSelection: UUID?

    init(model: Model) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func loadView() { let host = PreviewHostView(); host.owner = self; view = host }

    func attach(to window: NSWindow?) {
        guard attachedWindow !== window else { return }
        if attachedWindow?.nextResponder === self { attachedWindow?.nextResponder = oldResponder }
        attachedWindow = window
        if let window {
            oldResponder = window.nextResponder
            nextResponder = oldResponder
            window.nextResponder = self
        }
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let model = self.model, !model.files.isEmpty,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
                let panel = QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil
                let isPreview = event.window === panel && panel?.isVisible == true
                guard event.window === self.attachedWindow || isPreview else { return event }
                if !isPreview, let text = event.window?.firstResponder as? NSTextView, text.isEditable { return event }
                if !isPreview, let field = event.window?.firstResponder as? NSTextField, field.isEditable { return event }
                if event.keyCode == 49 { self.toggle(); return nil }
                if isPreview, [123, 124, 125, 126].contains(event.keyCode) {
                    self.selectAdjacent([123, 126].contains(event.keyCode) ? -1 : 1)
                    return nil
                }
                if !isPreview, [125, 126].contains(event.keyCode) { self.selectAdjacent(event.keyCode == 126 ? -1 : 1); return nil }
                return event
            }
        }
    }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { !(model?.files.isEmpty ?? true) }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self; panel.delegate = self; synchronize(panel)
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil; panel.delegate = nil }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { model?.files.count ?? 0 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard let model, model.files.indices.contains(index) else { return nil }
        return model.files[index].url as NSURL
    }
    func toggle() {
        guard let model, !model.files.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { panel.orderOut(nil); attachedWindow?.makeKeyAndOrderFront(nil); return }
        if model.selection == nil { model.selection = model.files.first?.id }
        attachedWindow?.makeKeyAndOrderFront(nil)
        panel.updateController()
        panel.makeKeyAndOrderFront(nil)
        synchronize(panel)
    }
    func focusFiles() {
        // SwiftUI tap gestures do not resign the sidebar's field editor.
        // Give the file browser keyboard focus before handling Space or arrows.
        guard let window = attachedWindow, window.attachedSheet == nil else { return }
        window.makeFirstResponder(view)
    }
    func refresh() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        guard let model, !model.files.isEmpty else { panel.orderOut(nil); return }
        let urls = model.files.map(\.url)
        if urls != lastURLs || model.selection != lastSelection { synchronize(panel) }
    }
    private func synchronize(_ panel: QLPreviewPanel) {
        guard let model else { return }
        lastURLs = model.files.map(\.url); lastSelection = model.selection
        if panel.dataSource !== self { return }
        panel.reloadData()
        panel.currentPreviewItemIndex = model.files.firstIndex(where: { $0.id == model.selection }) ?? 0
    }
    private func selectAdjacent(_ offset: Int) {
        guard let model, !model.files.isEmpty else { return }
        let current = model.files.firstIndex(where: { $0.id == model.selection }) ?? 0
        model.selection = model.files[min(max(0, current + offset), model.files.count - 1)].id
        refresh()
    }
    func detach() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if attachedWindow?.nextResponder === self { attachedWindow?.nextResponder = oldResponder }
        attachedWindow = nil
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.dataSource === self { panel.orderOut(nil); panel.dataSource = nil; panel.delegate = nil }
    }
}

struct PreviewBridge: NSViewControllerRepresentable {
    let model: Model
    func makeNSViewController(context: Context) -> PreviewController { model.preview }
    func updateNSViewController(_ controller: PreviewController, context: Context) { controller.refresh() }
    static func dismantleNSViewController(_ controller: PreviewController, coordinator: ()) { controller.detach() }
}
