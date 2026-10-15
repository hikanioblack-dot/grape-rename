import Foundation
import Darwin

struct FileStamp: Equatable, Codable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let createdSeconds: Int
    let createdNanos: Int

    init(_ url: URL) throws {
        var s = stat()
        guard url.path.withCString({ lstat($0, &s) }) == 0 else {
            throw RenameError.message(L("Не удалось прочитать «\(url.lastPathComponent)»: \(String(cString: strerror(errno)))", "Unable to read ‘\(url.lastPathComponent)’: \(String(cString: strerror(errno)))"))
        }
        guard s.st_mode & S_IFMT == S_IFREG else {
            throw RenameError.message(L("«\(url.lastPathComponent)» не является обычным файлом.", "‘\(url.lastPathComponent)’ is not a regular file."))
        }
        device = s.st_dev; inode = s.st_ino; size = s.st_size
        modifiedSeconds = s.st_mtimespec.tv_sec; modifiedNanos = s.st_mtimespec.tv_nsec
        createdSeconds = s.st_birthtimespec.tv_sec; createdNanos = s.st_birthtimespec.tv_nsec
    }
    var modified: Date { Date(timeIntervalSince1970: Double(modifiedSeconds) + Double(modifiedNanos) / 1e9) }
    var created: Date { Date(timeIntervalSince1970: Double(createdSeconds) + Double(createdNanos) / 1e9) }
}

enum RenameError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct RenameStep: Codable {
    let source: URL
    let destination: URL
    let stamp: FileStamp
}

enum RenameEngine {
    static func exists(_ url: URL) -> Bool {
        var s = stat()
        return url.path.withCString { lstat($0, &s) } == 0
    }

    static func validate(_ steps: [RenameStep]) throws {
        guard !steps.isEmpty else { throw RenameError.message(L("Выберите файлы.", "Choose files.")) }
        let sources = Set(steps.map { $0.source.path })
        var targets = Set<String>()
        for step in steps {
            guard step.source.deletingLastPathComponent() == step.destination.deletingLastPathComponent() else {
                throw RenameError.message(L("Файлы можно переименовать только в исходной папке.", "Files can only be renamed in their original folder."))
            }
            let name = step.destination.lastPathComponent
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":"), !name.contains("\0"), name.utf8.count <= 255 else {
                throw RenameError.message(L("Недопустимое имя: «\(name)». Уберите /, : и слишком длинный текст.", "Invalid name: ‘\(name)’. Remove /, : or shorten the name."))
            }
            // Conservatively reject case/Unicode-equivalent names on all volumes.
            let key = step.destination.path.precomposedStringWithCanonicalMapping.lowercased()
            guard targets.insert(key).inserted else { throw RenameError.message(L("Повторяется новое имя: «\(name)».", "Duplicate new name: ‘\(name)’.")) }
            guard try FileStamp(step.source) == step.stamp else {
                throw RenameError.message(L("«\(step.source.lastPathComponent)» изменился после выбора. Выберите файлы заново.", "‘\(step.source.lastPathComponent)’ changed after selection. Choose the files again."))
            }
            if exists(step.destination) && !sources.contains(step.destination.path) {
                throw RenameError.message(L("В папке уже есть «\(name)». Измените шаблон или начальный номер.", "‘\(name)’ already exists in this folder. Change the template or starting number."))
            }
        }
    }

    static func moveExclusive(_ from: URL, _ to: URL) throws {
        let result = from.path.withCString { src in
            to.path.withCString { dst in renameatx_np(AT_FDCWD, src, AT_FDCWD, dst, UInt32(RENAME_EXCL)) }
        }
        guard result == 0 else { throw RenameError.message(L("Не удалось переименовать «\(from.lastPathComponent)»: \(String(cString: strerror(errno)))", "Unable to rename ‘\(from.lastPathComponent)’: \(String(cString: strerror(errno)))")) }
    }

    /// Same-directory rename preserves the inode, content, birth time and mtime.
    /// Staging allows swaps and prevents overwriting existing files.
    static func apply(_ allSteps: [RenameStep], staging: [URL]? = nil) throws -> [RenameStep] {
        try validate(allSteps)
        let steps = allSteps.filter { $0.source != $0.destination }
        let temporary = staging ?? steps.map { $0.source.deletingLastPathComponent().appendingPathComponent(".grape-\(UUID().uuidString)") }
        guard temporary.count == steps.count else { throw RenameError.message(L("Неверный журнал операции.", "Invalid operation journal.")) }
        var locations = steps.map(\.source)
        do {
            for i in steps.indices {
                try moveExclusive(locations[i], temporary[i]); locations[i] = temporary[i]
            }
            for i in steps.indices {
                try moveExclusive(locations[i], steps[i].destination); locations[i] = steps[i].destination
            }
            for i in steps.indices {
                guard try FileStamp(locations[i]) == steps[i].stamp else {
                    throw RenameError.message(L("Проверка сохранения дат не пройдена для «\(locations[i].lastPathComponent)».", "Date preservation verification failed for ‘\(locations[i].lastPathComponent)’."))
                }
            }
        } catch {
            let initialError = error.localizedDescription
            var rollbackErrors: [String] = []
            // Restage finalized files first, so rolling back swaps is safe.
            for i in steps.indices where locations[i] == steps[i].destination && locations[i] != temporary[i] {
                do { try moveExclusive(locations[i], temporary[i]); locations[i] = temporary[i] }
                catch { rollbackErrors.append("\(locations[i].path): \(error.localizedDescription)") }
            }
            for i in steps.indices where locations[i] != steps[i].source {
                do { try moveExclusive(locations[i], steps[i].source); locations[i] = steps[i].source }
                catch { rollbackErrors.append("\(locations[i].path) → \(steps[i].source.path): \(error.localizedDescription)") }
            }
            let suffix = rollbackErrors.isEmpty ? L("\nИсходные имена восстановлены.", "\nOriginal names restored.") : L("\nНе удалось восстановить некоторые имена:\n", "\nSome names could not be restored:\n") + rollbackErrors.joined(separator: "\n")
            throw RenameError.message(initialError + suffix)
        }
        return steps.map { RenameStep(source: $0.destination, destination: $0.source, stamp: $0.stamp) }
    }
}

func runSelfTests() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("Grape-tests-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let names = ["Ветер.txt", "alpha.csv", "img.svg", "other.md", "05.json", "écho.dat", "draft.log", "last.html"]
    var urls: [URL] = []
    for (i, name) in names.enumerated() {
        let url = dir.appendingPathComponent(name)
        try Data(repeating: UInt8(i + 1), count: (i + 1) * 1301).write(to: url)
        var times = [timespec(tv_sec: 1_700_000_000 + i * 100, tv_nsec: 123456789), timespec(tv_sec: 1_700_100_000 + i * 100, tv_nsec: 987654321)]
        guard url.path.withCString({ utimensat(AT_FDCWD, $0, &times, 0) }) == 0 else { throw RenameError.message("utimensat failed") }
        urls.append(url)
    }
    let content = try urls.map { try Data(contentsOf: $0) }
    let stamps = try urls.map { try FileStamp($0) }
    let steps = try urls.enumerated().map { i, url in
        RenameStep(source: url, destination: dir.appendingPathComponent(String(format: "Тест_%04d", i + 1)).appendingPathExtension(url.pathExtension), stamp: try FileStamp(url))
    }
    let undo = try RenameEngine.apply(steps)
    for (i, step) in steps.enumerated() {
        guard try FileStamp(step.destination) == stamps[i], try Data(contentsOf: step.destination) == content[i] else { throw RenameError.message("Preservation failed") }
    }
    _ = try RenameEngine.apply(undo)
    for (i, url) in urls.enumerated() {
        guard try FileStamp(url) == stamps[i], try Data(contentsOf: url) == content[i] else { throw RenameError.message("Undo failed") }
    }
    let swaps = [RenameStep(source: urls[0], destination: urls[1], stamp: stamps[0]), RenameStep(source: urls[1], destination: urls[0], stamp: stamps[1])]
    let reverseSwap = try RenameEngine.apply(swaps)
    _ = try RenameEngine.apply(reverseSwap)
    var conflictRejected = false
    do { _ = try RenameEngine.apply([RenameStep(source: urls[0], destination: urls[2], stamp: stamps[0])]) }
    catch { conflictRejected = true }
    guard conflictRejected else { throw RenameError.message("Conflict not rejected") }
    try Data("external change".utf8).write(to: urls[0])
    var staleRejected = false
    do { _ = try RenameEngine.apply(steps) } catch { staleRejected = true }
    guard staleRejected else { throw RenameError.message("Stale file not rejected") }
    print("PASS: 8 files; nanosecond mtime, birthtime, inode, size and bytes preserved; undo; swaps; existing-name conflict; stale-file protection.")
}
