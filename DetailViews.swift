import SwiftUI

struct HistoryView: View {
    @ObservedObject var model: Model
    @Environment(\.dismiss) private var dismiss
    @State private var selected: UUID?
    var record: HistoryRecord? { model.history.first(where: { $0.id == selected }) ?? model.history.last }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(L("История переименований", "Rename History")).font(.title2.weight(.semibold)); Spacer(); Button(L("Готово", "Done")) { dismiss() }.keyboardShortcut(.cancelAction) }.padding(22)
            Divider()
            if !model.persistenceError.isEmpty {
                HStack { Text(model.persistenceError).font(.caption).foregroundStyle(.orange); Spacer(); Button(L("Восстановить", "Recover")) { model.recover() } }.padding(16)
                Divider()
            }
            if model.history.isEmpty {
                ContentUnavailableView(L("История пока пуста", "No renames yet"), systemImage: "clock.arrow.circlepath", description: Text(L("Операции сохраняются после закрытия приложения.", "Your rename history survives app restarts."))).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 5) {
                            ForEach(model.history.reversed()) { item in
                                Button { selected = item.id } label: {
                                    VStack(alignment: .leading, spacing: 7) {
                                        Text(Language.date(item.date)).font(.system(size: 12, weight: .medium))
                                        Text(L("Файлов: \(item.steps.count)", "Files: \(item.steps.count)")).font(.caption).foregroundStyle(.secondary)
                                        Label(item.undoneAt == nil ? L("Переименовано", "Renamed") : L("Отменено", "Undone"), systemImage: item.undoneAt == nil ? "checkmark" : "arrow.uturn.backward").font(.caption).foregroundStyle(item.undoneAt == nil ? GrapeTheme.accent : .secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(record?.id == item.id ? GrapeTheme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
                                }.buttonStyle(.plain)
                            }
                        }.padding(12)
                    }.frame(width: 210)
                    Divider()
                    if let record {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(L("Изменения", "Changes")).font(.headline)
                            ScrollView {
                                VStack(alignment: .leading, spacing: 16) {
                                    ForEach(Array(record.steps.enumerated()), id: \.offset) { _, step in
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(step.source.lastPathComponent).foregroundStyle(.secondary)
                                            Label(step.destination.lastPathComponent, systemImage: "arrow.right").foregroundStyle(GrapeTheme.accent)
                                            Text(step.source.deletingLastPathComponent().path).font(.system(size: 10)).foregroundStyle(.tertiary)
                                        }.font(.system(size: 12)).textSelection(.enabled)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if record.undoneAt == nil && model.undoRecord?.id != record.id { Text(L("Сначала отмените более поздние операции.", "Undo newer operations first.")).font(.caption).foregroundStyle(.secondary) }
                            Button(L("Отменить эту операцию", "Undo This Rename")) { model.undo() }.buttonStyle(.glassProminent).disabled(record.undoneAt != nil || model.undoRecord?.id != record.id || !model.persistenceError.isEmpty)
                            Text(L("Перед отменой проверяются наличие, размер и даты файлов.", "File identity, size and dates are checked before undo.")).font(.caption).foregroundStyle(.secondary)
                        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }.frame(width: 760, height: 570, alignment: .top)
    }
}
