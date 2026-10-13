import SwiftUI
import AppKit
import QuickLookUI

/// A real inline Quick Look view, including PDF pages and media controls.
struct InlineFilePreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact)!
        view.shouldCloseWithWindow = false
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if view.previewItem?.previewItemURL != url { view.previewItem = url as NSURL }
    }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}

struct FileInspector: View {
    @ObservedObject var model: Model
    @State private var expandedSections = Set<String>()
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Предпросмотр", "Preview")).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { model.showInspector = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(L("Скрыть панель", "Hide Sidebar"))
            }.padding(.horizontal, 18).padding(.vertical, 15)
            Divider()
            if let row = model.selectedFile {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        InlineFilePreview(url: row.url)
                            .frame(height: 220).frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .accessibilityLabel(L("Предпросмотр \(row.url.lastPathComponent)", "Preview of \(row.url.lastPathComponent)"))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.url.lastPathComponent).font(.system(size: 15, weight: .semibold)).lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                            Text((row.url.pathExtension.isEmpty ? L("Файл", "File") : row.url.pathExtension.uppercased()) + " — " + ByteCountFormatter.string(fromByteCount: row.stamp.size, countStyle: .file))
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Button { model.preview.toggle() } label: { Label(L("Быстрый просмотр", "Quick Look"), systemImage: "arrow.up.left.and.arrow.down.right") }
                            .controlSize(.small).help(L("Открыть полный просмотр · Пробел", "Open Full Preview · Space"))
                        Divider()
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L("Информация", "Information")).font(.system(size: 13, weight: .semibold))
                            ForEach(MetadataReader.inspectorFields(row)) { field in
                                informationRow(field)
                            }
                        }
                        ForEach(row.metadata.sections) { section in
                            DisclosureGroup(isExpanded: Binding(get: { expandedSections.contains(section.title) }, set: { opened in if opened { expandedSections.insert(section.title) } else { expandedSections.remove(section.title) } })) {
                                VStack(alignment: .leading, spacing: 12) { ForEach(section.fields) { informationRow($0) } }.padding(.top, 10)
                            } label: { Text(section.title).font(.system(size: 13, weight: .semibold)) }
                        }
                        DisclosureGroup {
                            Text(row.url.deletingLastPathComponent().path).font(.system(size: 11)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                            Button(L("Показать в Finder", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([row.url]) }.controlSize(.small).padding(.top, 5)
                        } label: { Text(L("Расположение", "Location")).font(.system(size: 13, weight: .semibold)) }
                        Text(L("Метаданные доступны только для чтения", "Metadata is read-only")).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }.padding(18)
                }
            } else {
                ContentUnavailableView(L("Выберите файл", "Select a File"), systemImage: "doc.text.magnifyingglass", description: Text(L("Здесь появятся предпросмотр и свойства", "Preview and properties appear here")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(.thinMaterial)
    }
    private func informationRow(_ field: MetadataField) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(MetadataReader.label(field.key)).foregroundStyle(.secondary).frame(width: 98, alignment: .leading)
            Text(field.value).frame(maxWidth: .infinity, alignment: .trailing).multilineTextAlignment(.trailing).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 11))
    }
}
