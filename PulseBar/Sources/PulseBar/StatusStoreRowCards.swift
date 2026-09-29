import Foundation

/// 19.0 · the cards under a row — the store's side: the facts only it knows,
/// handed to `RowCardModel.make`, and the user's clicks carried out.
@MainActor
extension StatusStore {
    func rowCardModel(_ row: AgentRow) -> RowCardModel {
        let runner = managedRunner(for: row)
        return RowCardModel.make(RowCardModel.Input(
            row: row,
            narrator: narrator,
            permissions: managedPermissionRequests(for: row),
            inbound: row.waiting ? respondRequest(for: row) : nil,
            fateNote: respondFateNote(row),
            managedStatus: runner?.model.status,
            managedEntries: runner?.model.entries ?? []
        ))
    }

    /// The workbench's full-size cards take the same parts.
    func permissionCardModel(_ request: ManagedPermission.Request) -> RowCardModel.Permission {
        RowCardModel.permission(request, narrator: narrator)
    }

    func respondCardModel(_ row: AgentRow, inbound: RespondSpool.InboundRequest) -> RowCardModel.Respond {
        RowCardModel.respond(inbound, row: row, fateNote: respondFateNote(row), narrator: narrator)
    }

    func performRowCard(_ action: RowCardModel.Action, row: AgentRow) {
        switch action {
        case .permission(let id, let allow):
            managedPermissionDecide(id: id, allow: allow)
        case .respondDeny(let requestID, let digest):
            respondDeny(row, shown: RespondShown(requestID: requestID, digest: digest))
        case .respondAllow(let requestID, let digest):
            respondAllow(row, shown: RespondShown(requestID: requestID, digest: digest))
        case .managedCancel:
            managedRunner(for: row)?.cancel()
        case .managedSend(let text):
            managedRunner(for: row)?.send(prompt: text)
        case .dismiss:
            dismissWaiting(row)
        case .snooze:
            snooze(row)
        case .unsnooze:
            unsnooze(row)
        case .openWorkbench:
            workbenchSelectKey = row.rowKey
            openWorkbench()
        }
    }
}
