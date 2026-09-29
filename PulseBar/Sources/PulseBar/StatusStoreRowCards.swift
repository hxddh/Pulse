import Foundation

/// 19.0 · the cards under a row — the store's side: the facts only it knows,
/// handed to `RowCardModel.make`, and the user's clicks carried out.
@MainActor
extension StatusStore {
    func rowCardModel(_ row: AgentRow) -> RowCardModel {
        RowCardModel.make(RowCardModel.Input(
            row: row,
            narrator: narrator,
            inbound: row.waiting ? respondRequest(for: row) : nil,
            fateNote: respondFateNote(row)
        ))
    }

    func performRowCard(_ action: RowCardModel.Action, row: AgentRow) {
        switch action {
        case .respondDeny(let requestID, let digest):
            respondDeny(row, shown: RespondShown(requestID: requestID, digest: digest))
        case .respondAllow(let requestID, let digest):
            respondAllow(row, shown: RespondShown(requestID: requestID, digest: digest))
        case .dismiss:
            dismissWaiting(row)
        case .snooze:
            snooze(row)
        case .unsnooze:
            unsnooze(row)
        }
    }
}
