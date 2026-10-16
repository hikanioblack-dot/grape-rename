import Foundation
import AppKit
import UniformTypeIdentifiers

enum FileImport {
    static func read(_ urls: [URL], _ excluding: Set<String>, _ progress: @Sendable (String) -> Void) throws -> [FileRow] {
        let candidates = try collect(urls).filter { !excluding.contains($0.path) }
        var rows: [FileRow] = []
        for (index, url) in candidates.enumerated() {
            try Task.checkCancellation()
            let row = try autoreleasepool { FileRow(url: url, stamp: try FileStamp(url)) }
            try Task.checkCancellation()
            rows.append(row)
            if index % 16 == 0 || index + 1 == candidates.count {
                progress(L("Прочитано: \(index + 1) / \(candidates.count)", "Read: \(index + 1) / \(candidates.count)"))
            }
        }
        return rows
    }

    static func collect(_ urls: [URL]) throws -> [URL] {
        var result: [URL] = []
        var seen = Set<String>()
        for url in urls {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { continue }
            let candidates = values.isDirectory == true
                ? try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
                : [url]
            for candidate in candidates {
                try Task.checkCancellation()
                let normalized = candidate.standardizedFileURL
                let properties = try normalized.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if properties.isRegularFile == true, properties.isSymbolicLink != true, seen.insert(normalized.path).inserted { result.append(normalized) }
            }
        }
        return result
    }
}

extension Model {
    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !busy else { return false }
        let revision = importRevision
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in files {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        let url: URL?
                        if let value = item as? URL { url = value }
                        else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                        else if let string = item as? String { url = URL(string: string) }
                        else { url = nil }
                        continuation.resume(returning: url?.isFileURL == true ? url : nil)
                    }
                }
                if let url { urls.append(url) }
            }
            guard !busy, importRevision == revision else { return }
            guard !urls.isEmpty else { fail(RenameError.message(L("Не удалось получить файлы из Finder. Попробуйте выбрать их кнопкой.", "Unable to read the dropped files. Try choosing them with the button."))); return }
            importFiles(urls, append: !self.files.isEmpty)
        }
        return true
    }
}
