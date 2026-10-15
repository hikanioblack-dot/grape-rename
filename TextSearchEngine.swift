import Foundation
import Vision
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

struct ImageText: Codable, Sendable {
    var lines: [String]
    var text: String { lines.joined(separator: "\n") }
    var characterCount: Int { text.filter { !$0.isWhitespace }.count }
}
struct TextImage: Identifiable, Sendable {
    let file: DuplicateFile
    let content: ImageText
    var id: String { file.id }
}
enum TextImageFilter: String, CaseIterable, Identifiable {
    case withText, muchText, withoutText, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .withText: return L("С текстом", "With Text")
        case .muchText: return L("Много текста", "Lots of Text")
        case .withoutText: return L("Текст не обнаружен", "No Text Detected")
        case .all: return L("Все изображения", "All Images")
        }
    }
    func matches(_ content: ImageText, minimumCharacters: Int, minimumLines: Int) -> Bool {
        switch self {
        case .withText: return !content.lines.isEmpty
        case .muchText: return content.characterCount >= minimumCharacters && content.lines.count >= minimumLines
        case .withoutText: return content.lines.isEmpty
        case .all: return true
        }
    }
}
struct ImageTextReport: Sendable {
    var images: [TextImage] = []
    var warnings: [String] = []
    var skipped = 0
    var cacheHits = 0
}

/// A separate cache per image prevents concurrent scans from overwriting each other's entries.
/// Cached OCR is local only and keyed by the full file stamp and recognition settings.
enum ImageTextEngine {
    private struct Cached: Codable {
        let stamp: FileStamp
        let signature: String
        let content: ImageText
    }
    static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.grape.rename/ImageText-v1", isDirectory: true)
    }
    static func cacheURL(_ url: URL, directory: URL) -> URL {
        let key = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".json")
    }
    static func recognize(_ file: DuplicateFile, cache: URL?) throws -> (ImageText, Bool) {
        try Task.checkCancellation()
        try DuplicateEngine.assertUnchanged(file)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let supported = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = ["ru-RU", "en-US"].filter { supported.contains($0) }
        request.automaticallyDetectsLanguage = true
        let signature = "v1-r\(request.revision)-accurate-\(request.recognitionLanguages.joined(separator: ","))-3000-confidence0.4"
        if let cache, let data = try? Data(contentsOf: cacheURL(file.url, directory: cache)),
           let entry = try? JSONDecoder().decode(Cached.self, from: data), entry.stamp == file.stamp, entry.signature == signature {
            try DuplicateEngine.assertUnchanged(file)
            return (entry.content, true)
        }
        guard let source = CGImageSourceCreateWithURL(file.url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 3000,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            throw RenameError.message(L("Не удалось прочитать изображение.", "Unable to read image."))
        }
        try VNImageRequestHandler(cgImage: image).perform([request])
        try Task.checkCancellation()
        try DuplicateEngine.assertUnchanged(file)
        let lines = (request.results ?? []).compactMap { observation -> String? in
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.4 else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.filter({ $0.isLetter || $0.isNumber }).count >= 2 else { return nil }
            return text
        }
        let result = ImageText(lines: lines)
        if let cache {
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(Cached(stamp: file.stamp, signature: signature, content: result)) {
                try? data.write(to: cacheURL(file.url, directory: cache), options: .atomic)
            }
        }
        return (result, false)
    }
    static func scan(_ roots: [URL], recursive: Bool, cache: URL?, progress: @Sendable (DuplicateProgress) -> Void = { _ in }) throws -> ImageTextReport {
        var collected = DuplicateReport()
        let files = try DuplicateEngine.collect(roots, recursive: recursive, report: &collected)
        var report = ImageTextReport(warnings: collected.warnings)
        let images = files.filter { file in
            guard let type = UTType(filenameExtension: file.url.pathExtension) else { return false }
            return type.conforms(to: .image)
        }
        report.skipped = files.count - images.count + collected.skippedLinks
        for (index, file) in images.enumerated() {
            try Task.checkCancellation()
            progress(DuplicateProgress(fraction: Double(index) / Double(max(images.count, 1)), message: "\(index + 1)/\(images.count) · \(file.url.lastPathComponent)"))
            do {
                let (text, cached) = try autoreleasepool { try recognize(file, cache: cache) }
                report.images.append(TextImage(file: file, content: text))
                if cached { report.cacheHits += 1 }
            } catch is CancellationError { throw CancellationError() }
            catch { report.warnings.append("\(file.url.lastPathComponent): \(error.localizedDescription)") }
        }
        // Cached or newly recognized results must still refer to the scanned files.
        report.images = report.images.filter { image in
            do { try DuplicateEngine.assertUnchanged(image.file); return true }
            catch { report.warnings.append("\(image.file.url.lastPathComponent): \(error.localizedDescription)"); return false }
        }
        try Task.checkCancellation()
        progress(DuplicateProgress(fraction: 1, message: L("Готово", "Done")))
        return report
    }
}

struct ImageTextActionResult: Sendable {
    var removed = Set<URL>()
    var succeeded = 0
    var failures: [String] = []
}
enum ImageTextAction: Sendable { case trash, copy(URL), move(URL) }
enum ImageTextFiles {
    static func apply(_ action: ImageTextAction, files: [DuplicateFile],
                      trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> ImageTextActionResult {
        var result = ImageTextActionResult()
        do { for file in files { try DuplicateEngine.assertUnchanged(file) } }
        catch { result.failures = [error.localizedDescription]; return result }
        for file in files {
            do {
                try DuplicateEngine.assertUnchanged(file)
                switch action {
                case .trash: try trash(file.url); result.removed.insert(file.url)
                case .copy(let folder), .move(let folder):
                    let target = folder.appendingPathComponent(file.url.lastPathComponent)
                    guard !RenameEngine.exists(target) else { throw RenameError.message(L("В папке уже есть файл с таким именем.", "A file with this name already exists in the folder.")) }
                    switch action {
                    case .copy: try FileManager.default.copyItem(at: file.url, to: target)
                    case .move: try FileManager.default.moveItem(at: file.url, to: target); result.removed.insert(file.url)
                    case .trash: break
                    }
                }
                result.succeeded += 1
            } catch { result.failures.append("\(file.url.lastPathComponent): \(error.localizedDescription)") }
        }
        return result
    }
}
