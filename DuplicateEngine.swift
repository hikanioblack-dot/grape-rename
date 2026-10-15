import Foundation
import CryptoKit
import Vision
import ImageIO
import UniformTypeIdentifiers

enum DuplicateMode: String, Identifiable, Sendable {
    case exact, similar
    var id: String { rawValue }
    var title: String {
        self == .exact ? L("Точные дубликаты", "Exact Duplicates") : L("Похожие фотографии", "Similar Photos")
    }
}
enum PhotoSimilarity: String, CaseIterable, Identifiable, Sendable {
    case strict, balanced, broad
    var id: String { rawValue }
    var title: String {
        switch self {
        case .strict: return L("Строго", "Strict")
        case .balanced: return L("Сбалансированно", "Balanced")
        case .broad: return L("Шире", "Broader")
        }
    }
    // Vision revision 2 only. Distances are not percentages of visual similarity.
    var threshold: Float {
        switch self { case .strict: return 0.15; case .balanced: return 0.3; case .broad: return 0.45 }
    }
    var hashDistance: Int { switch self { case .strict: return 4; case .balanced: return 8; case .broad: return 12 } }
}
struct DuplicateFile: Identifiable, Sendable {
    let url: URL
    let stamp: FileStamp
    var id: String { url.path }
}
struct DuplicateGroup: Identifiable, Sendable {
    let id = UUID()
    var files: [DuplicateFile]
}
struct DuplicateReport: Sendable {
    var groups: [DuplicateGroup] = []
    var inspected = 0
    var skippedLinks = 0
    var warnings: [String] = []
}
struct DuplicateProgress: Sendable {
    let fraction: Double
    let message: String
}

struct ImageFingerprint {
    let observation: VNFeaturePrintObservation
    let hash: UInt64
    let contrast: Double
    let aspect: Double
}

/// All reading and Vision processing happen on the caller's background task.
/// Only values (not Vision observations or open file handles) leave the worker.
enum DuplicateEngine {
    static let chunkSize = 1_048_576

    static func collect(_ roots: [URL], recursive: Bool, report: inout DuplicateReport) throws -> [DuplicateFile] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        var seenPaths = Set<String>(), seenNodes = Set<String>()
        var files: [DuplicateFile] = []
        func add(_ url: URL) throws {
            try Task.checkCancellation()
            let url = url.standardizedFileURL
            guard seenPaths.insert(url.path).inserted else { return }
            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                guard values.isSymbolicLink != true, values.isRegularFile == true else { return }
                let stamp = try FileStamp(url)
                let node = "\(stamp.device):\(stamp.inode)"
                if stamp.inode != 0, !seenNodes.insert(node).inserted { report.skippedLinks += 1; return }
                files.append(DuplicateFile(url: url, stamp: stamp))
            } catch { report.warnings.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        for root in roots {
            try Task.checkCancellation()
            do {
                let values = try root.resourceValues(forKeys: Set(keys))
                guard values.isSymbolicLink != true else { continue }
                if values.isDirectory == true {
                    if recursive {
                        var enumerationWarnings: [String] = []
                        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                            options: [.skipsHiddenFiles, .skipsPackageDescendants],
                            errorHandler: { url, error in
                                enumerationWarnings.append("\(url.lastPathComponent): \(error.localizedDescription)")
                                return true
                            }) else { continue }
                        for case let url as URL in enumerator {
                            try Task.checkCancellation()
                            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                                continue
                            }
                            try add(url)
                        }
                        report.warnings += enumerationWarnings
                    } else {
                        for url in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) { try add(url) }
                    }
                } else { try add(root) }
            } catch is CancellationError { throw CancellationError() }
            catch { report.warnings.append("\(root.lastPathComponent): \(error.localizedDescription)") }
        }
        report.inspected = files.count
        return files.sorted { $0.url.path < $1.url.path }
    }

    static func assertUnchanged(_ file: DuplicateFile) throws {
        guard try FileStamp(file.url) == file.stamp else {
            throw RenameError.message(L("«\(file.url.lastPathComponent)» изменился. Запустите поиск заново.",
                                        "‘\(file.url.lastPathComponent)’ changed. Run the search again."))
        }
    }

    static func digest(_ file: DuplicateFile, progress: (Double) -> Void = { _ in }) throws -> String {
        try assertUnchanged(file)
        let handle = try FileHandle(forReadingFrom: file.url)
        defer { try? handle.close() }
        var hash = SHA256(), read: Int64 = 0
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty { break }
            hash.update(data: data); read += Int64(data.count)
            progress(file.stamp.size == 0 ? 1 : min(1, Double(read) / Double(file.stamp.size)))
        }
        try assertUnchanged(file)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func equalBytes(_ a: DuplicateFile, _ b: DuplicateFile) throws -> Bool {
        try assertUnchanged(a); try assertUnchanged(b)
        guard a.stamp.size == b.stamp.size else { return false }
        let left = try FileHandle(forReadingFrom: a.url)
        defer { try? left.close() }
        let right = try FileHandle(forReadingFrom: b.url)
        defer { try? right.close() }
        var equal = true
        while true {
            try Task.checkCancellation()
            let x = try left.read(upToCount: chunkSize) ?? Data()
            let y = try right.read(upToCount: chunkSize) ?? Data()
            if x != y { equal = false; break }
            if x.isEmpty { break }
        }
        try assertUnchanged(a); try assertUnchanged(b)
        return equal
    }

    static func perceptualHash(_ image: CGImage) throws -> (UInt64, Double) {
        let size = 32
        var pixels = [UInt8](repeating: 0, count: size * size)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: size, height: size, bitsPerComponent: 8,
                                          bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.setFillColor(gray: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard rendered else { throw RenameError.message(L("Не удалось вычислить визуальный хеш.", "Unable to compute the visual hash.")) }
        let values = pixels.map(Double.init)
        let average = values.reduce(0, +) / Double(values.count)
        let contrast = sqrt(values.reduce(0) { $0 + pow($1 - average, 2) } / Double(values.count))
        let cosine = (0..<8).map { frequency in
            (0..<size).map { cos(.pi * Double((2 * $0 + 1) * frequency) / Double(2 * size)) }
        }
        var horizontal = [Double](repeating: 0, count: size * 8)
        for y in 0..<size { for u in 0..<8 {
            for x in 0..<size { horizontal[y * 8 + u] += values[y * size + x] * cosine[u][x] }
        } }
        var coefficients: [Double] = []
        for v in 0..<8 { for u in 0..<8 where u != 0 || v != 0 {
            var sum: Double = 0
            for y in 0..<size { sum += horizontal[y * 8 + u] * cosine[v][y] }
            coefficients.append(sum)
        } }
        let median = coefficients.sorted()[coefficients.count / 2]
        var hash: UInt64 = 0
        for (index, value) in coefficients.enumerated() where value > median { hash |= UInt64(1) << index }
        return (hash, contrast)
    }

    static func feature(_ file: DuplicateFile) throws -> ImageFingerprint {
        try Task.checkCancellation()
        try assertUnchanged(file)
        let result: ImageFingerprint = try autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(file.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 768,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else {
                throw RenameError.message(L("Изображение не удалось прочитать.", "Unable to decode the image."))
            }
            let request = VNGenerateImageFeaturePrintRequest()
            request.revision = VNGenerateImageFeaturePrintRequestRevision2
            request.imageCropAndScaleOption = .scaleFit
            try VNImageRequestHandler(cgImage: thumbnail, options: [:]).perform([request])
            guard let print = request.results?.first else {
                throw RenameError.message(L("Не удалось проанализировать изображение.", "Unable to analyze the image."))
            }
            let perceptual = try perceptualHash(thumbnail)
            return ImageFingerprint(observation: print, hash: perceptual.0, contrast: perceptual.1,
                                    aspect: Double(thumbnail.width) / Double(thumbnail.height))
        }
        try Task.checkCancellation()
        try assertUnchanged(file)
        return result
    }

    static func scan(_ roots: [URL], recursive: Bool, mode: DuplicateMode, similarity: PhotoSimilarity,
                     progress: @escaping @Sendable (DuplicateProgress) -> Void = { _ in }) throws -> DuplicateReport {
        var lastUpdate = Date.distantPast
        func update(_ fraction: Double, _ message: String, force: Bool = false) {
            let now = Date()
            if force || now.timeIntervalSince(lastUpdate) >= 0.1 {
                lastUpdate = now
                progress(DuplicateProgress(fraction: min(1, max(0, fraction)), message: message))
            }
        }
        update(0, L("Чтение списка файлов…", "Reading the file list…"), force: true)
        var report = DuplicateReport()
        let files = try collect(roots, recursive: recursive, report: &report)
        try Task.checkCancellation()
        if mode == .exact {
            let candidates = Dictionary(grouping: files, by: { $0.stamp.size }).values
                .filter { $0.count > 1 }.flatMap { $0 }.sorted { $0.id < $1.id }
            var hashes: [String: [DuplicateFile]] = [:]
            for (index, file) in candidates.enumerated() {
                do {
                    let digest = try digest(file) { fraction in
                        update(0.8 * (Double(index) + fraction) / Double(max(1, candidates.count)),
                               L("SHA-256: \(file.url.lastPathComponent)", "SHA-256: \(file.url.lastPathComponent)"))
                    }
                    hashes["\(file.stamp.size):\(digest)", default: []].append(file)
                } catch is CancellationError { throw CancellationError() }
                catch { report.warnings.append("\(file.url.lastPathComponent): \(error.localizedDescription)") }
            }
            let matches = hashes.values.filter { $0.count > 1 }.sorted { $0[0].id < $1[0].id }
            for (index, match) in matches.enumerated() {
                try Task.checkCancellation()
                update(0.8 + 0.2 * Double(index) / Double(max(1, matches.count)),
                       L("Подтверждение совпадения байтов…", "Confirming byte-for-byte matches…"), force: true)
                // Partition even in the hypothetical case of a digest collision.
                var confirmed: [[DuplicateFile]] = []
                for file in match {
                    do {
                        var found = false
                        for i in confirmed.indices {
                            if try equalBytes(confirmed[i][0], file) { confirmed[i].append(file); found = true; break }
                        }
                        if !found { try assertUnchanged(file); confirmed.append([file]) }
                    } catch is CancellationError { throw CancellationError() }
                    catch { report.warnings.append("\(file.url.lastPathComponent): \(error.localizedDescription)") }
                }
                report.groups += confirmed.filter { $0.count > 1 }.map { DuplicateGroup(files: $0) }
            }
        } else {
            let images = files.filter { file in
                (try? file.url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .image)) == true
            }
            var analyzed: [(DuplicateFile, ImageFingerprint)] = []
            for (index, file) in images.enumerated() {
                try Task.checkCancellation()
                update(0.7 * Double(index) / Double(max(1, images.count)),
                       L("Анализ \(index + 1)/\(images.count): \(file.url.lastPathComponent)",
                         "Analyzing \(index + 1)/\(images.count): \(file.url.lastPathComponent)"))
                do { analyzed.append((file, try feature(file))) }
                catch is CancellationError { throw CancellationError() }
                catch { report.warnings.append("\(file.url.lastPathComponent): \(error.localizedDescription)") }
            }
            var groups: [(files: [DuplicateFile], anchor: ImageFingerprint)] = []
            for (index, item) in analyzed.enumerated() {
                try Task.checkCancellation()
                update(0.7 + 0.3 * Double(index) / Double(max(1, analyzed.count)),
                       L("Сравнение фотографий: \(index + 1)/\(analyzed.count)", "Comparing photos: \(index + 1)/\(analyzed.count)"))
                var found = false
                for i in groups.indices {
                    try Task.checkCancellation()
                    let anchor = groups[i].anchor
                    let hashMatch = item.1.contrast >= 8 && anchor.contrast >= 8
                        && abs(item.1.aspect / anchor.aspect - 1) <= 0.05
                        && (item.1.hash ^ anchor.hash).nonzeroBitCount <= similarity.hashDistance
                    var distance: Float = 0
                    if !hashMatch { try item.1.observation.computeDistance(&distance, to: anchor.observation) }
                    if hashMatch || distance <= similarity.threshold {
                        groups[i].files.append(item.0); found = true; break
                    }
                }
                if !found { groups.append(([item.0], item.1)) }
            }
            // Every group member matches its first image; no transitive chains.
            report.groups = groups.filter { $0.files.count > 1 }.map { DuplicateGroup(files: $0.files) }
        }
        // Drop stale results if a file changed while another file was being processed.
        for i in report.groups.indices {
            if mode == .similar, let anchor = report.groups[i].files.first {
                do { try assertUnchanged(anchor) }
                catch {
                    report.warnings.append("\(anchor.url.lastPathComponent): \(error.localizedDescription)")
                    report.groups[i].files = []; continue
                }
            }
            let valid = report.groups[i].files.filter {
                do { try assertUnchanged($0); return true }
                catch { report.warnings.append("\($0.url.lastPathComponent): \(error.localizedDescription)"); return false }
            }
            report.groups[i].files = valid
        }
        report.groups.removeAll { $0.files.count < 2 }
        report.groups.sort { $0.files[0].id < $1.files[0].id }
        update(1, L("Поиск завершён", "Search complete"), force: true)
        return report
    }
}
