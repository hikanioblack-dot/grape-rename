import Foundation

struct NamingOptions: Codable, Equatable {
    var prefix = ""
    var separator = "_"
    var start = 1
    var digits = 4
    var keepName = false
    var numbering = true
    var find = ""
    var replacement = ""
    var caseInsensitive = false
    var useShotDate = false
    var shotFormat: ShotFormat = .dateTime
}
struct SavedPreset: Codable, Identifiable {
    var id = UUID()
    var name: String
    var options: NamingOptions
}
struct HistoryRecord: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var steps: [RenameStep]
    var undoneAt: Date?
}
struct PendingOperation: Codable {
    var record: HistoryRecord
    var isUndo: Bool
    var steps: [RenameStep]
    var staging: [URL]
}
struct SavedState: Codable {
    var version = 1
    var history: [HistoryRecord] = []
    var presets: [SavedPreset] = []
    var pending: PendingOperation?
}

final class PersistenceStore {
    let url: URL
    var state: SavedState
    init(url: URL? = nil) throws {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Grape Rename", isDirectory: true).appendingPathComponent("state.json")
        if FileManager.default.fileExists(atPath: self.url.path) {
            state = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: self.url))
            guard state.version == 1 else { throw RenameError.message(L("Неподдерживаемая версия истории.", "Unsupported history version.")) }
        } else { state = SavedState() }
    }
    func save() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
    func begin(_ record: HistoryRecord, undo: Bool) throws -> PendingOperation {
        guard state.pending == nil else { throw RenameError.message(L("Сначала восстановите незавершённую операцию в истории.", "Recover the unfinished operation in History first.")) }
        let steps = undo ? record.steps.map { RenameStep(source: $0.destination, destination: $0.source, stamp: $0.stamp) } : record.steps
        let operation = PendingOperation(record: record, isUndo: undo, steps: steps, staging: steps.map { $0.source.deletingLastPathComponent().appendingPathComponent(".grape-\(UUID().uuidString)") })
        state.pending = operation
        do { try save() } catch { state.pending = nil; throw error }
        return operation
    }
    func finish(_ operation: PendingOperation) throws {
        if operation.isUndo {
            if let index = state.history.firstIndex(where: { $0.id == operation.record.id }) { state.history[index].undoneAt = Date() }
        } else if !state.history.contains(where: { $0.id == operation.record.id }) { state.history.append(operation.record) }
        state.pending = nil
        do { try save() } catch { state.pending = operation; throw error }
    }
    func recover() throws {
        guard let operation = state.pending else { return }
        if operation.steps.allSatisfy({ (try? FileStamp($0.destination)) == $0.stamp }) { try finish(operation); return }
        if !operation.steps.allSatisfy({ (try? FileStamp($0.source)) == $0.stamp }) {
            var locations: [URL] = []
            for (i, step) in operation.steps.enumerated() {
                guard let location = [step.source, operation.staging[i], step.destination].first(where: { (try? FileStamp($0)) == step.stamp }) else {
                    throw RenameError.message(L("Незавершённая операция: не найден исходный файл «\(step.source.lastPathComponent)». Верните файл в исходную папку и повторите восстановление.", "Unfinished operation: original file ‘\(step.source.lastPathComponent)’ was not found. Return it to its original folder and try recovery again."))
                }
                locations.append(location)
            }
            for i in locations.indices where locations[i] != operation.staging[i] {
                try RenameEngine.moveExclusive(locations[i], operation.staging[i]); locations[i] = operation.staging[i]
            }
            for i in locations.indices { try RenameEngine.moveExclusive(locations[i], operation.steps[i].source) }
        }
        state.pending = nil
        do { try save() } catch { state.pending = operation; throw error }
    }
}
