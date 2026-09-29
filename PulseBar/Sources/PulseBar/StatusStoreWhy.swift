import Foundation

/// 17.0 · Why — the store's side: which record belongs to a row. 23.0: the
/// session log's spans; the export of raw hook events went with the copy of
/// them Pulse used to keep.
@MainActor
extension StatusStore {
    /// 17.0: the tray row's face, as a value — the store contributes only
    /// what only it knows.
    func trayRowModel(_ row: AgentRow) -> TrayRowModel {
        TrayRowModel.make(TrayRowModel.Input(
            row: row,
            narrator: narrator,
            notice: rowActionNotice(row),
            needsReach: isWaitingNoneNeedsReach(row),
            muted: mutedAgents.contains(row.agent)
        ))
    }

    func whyCard(_ row: AgentRow) -> WhyCardModel {
        _ = logRevision
        return WhyCardModel.make(row: row, spans: sessionLog.spans(row.rowKey), narrator: narrator)
    }
}
