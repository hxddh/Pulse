import AppKit
import Foundation

/// 17.0 · Why — the store's side: which history belongs to a row, and the
/// user's click that copies it out as a replayable fixture.
@MainActor
extension StatusStore {
    /// The hook events kept for this row's session, oldest first. Empty for a
    /// row with no session: an agent-wide history would mix other sessions in.
    func attentionHistory(for row: AgentRow) -> [AttentionHistory.Event] {
        guard !row.sessionID.isEmpty else { return [] }
        return AttentionHistoryStore.current.history(
            agent: row.agent.rawValue, session: row.sessionID
        )
    }

    /// 17.0: the tray row's face, as a value — the store contributes only
    /// what only it knows.
    func trayRowModel(_ row: AgentRow) -> TrayRowModel {
        TrayRowModel.make(TrayRowModel.Input(
            row: row,
            narrator: narrator,
            snoozeLabel: row.isSnoozed ? snoozeLabel(row) : "",
            lookMarkedWhileAway: lookMarkedWhileAway(row),
            respondOffered: respondRequest(for: row) != nil && !respondVerdictSent(row),
            fateNote: respondFateNote(row),
            notice: rowActionNotice(row),
            needsReach: isWaitingNoneNeedsReach(row)
        ))
    }

    func whyCard(_ row: AgentRow) -> WhyCardModel {
        WhyCardModel.make(row: row, history: attentionHistory(for: row), narrator: narrator)
    }

    /// Copy this session's events as a v3 TSV — only on the user's click,
    /// only to their own clipboard. Returns how many events went.
    @discardableResult
    func copyAttentionFixture(_ row: AgentRow) -> Int {
        let events = attentionHistory(for: row)
        guard !events.isEmpty else { return 0 }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(AttentionHistory.fixture(events), forType: .string)
        DebugLog.write("why export events=\(events.count) \(DebugLog.key(row.rowKey))")
        return events.count
    }
}
