import Foundation

/// 5.0-β — the second producer behind the 5.0-α boundary (scene BG).
///
/// Managed rows are ordinary `AgentRow`s: the tray keeps every rule it has
/// (a managed row earns its lamp the same way), the workbench recognizes
/// `managedID` and swaps the inspector for the live conversation. Row keys
/// carry their own namespace, so a collision with an observed key is
/// impossible by construction — and if the observed pipeline later notices
/// the same underlying claude session on disk, both views are true and the
/// coordinator's first-source rule keeps the observed row for that key.
@MainActor
final class ManagedSessionSource: SessionSource {
    let sourceID = "managed"
    /// 6.0-α: the fleet supervises the population; the source is the thin
    /// SessionSource face over it.
    let fleet = ManagedFleet()
    /// Fired on any session change, wired by the store to re-merge.
    var onChange: (() -> Void)? {
        didSet { fleet.onChange = { [weak self] in self?.onChange?() } }
    }

    var runners: [ManagedSessionRunner] { fleet.runners }

    var sessions: [AgentRow] {
        fleet.runners.map { runner in
            Self.row(
                for: runner.model,
                permissionAsk: fleet.pendingPermissions
                    .first { $0.managedID == runner.model.id }
            )
        }
    }

    func runner(managedID: String) -> ManagedSessionRunner? {
        fleet.runner(managedID: managedID)
    }

    func terminateAllForShutdown() {
        fleet.shutdown()
    }

    /// Model → row, pure and pinned by tests. First-party facts: the stream
    /// is Pulse's own, so nothing here carries a "not measured" discount —
    /// but absence still renders as absence, never as zero.
    /// `nonisolated`: touches no actor state, and the tests call it from a
    /// plain XCTestCase.
    nonisolated static func row(
        for model: ManagedSession.Model,
        permissionAsk: ManagedPermission.Request? = nil
    ) -> AgentRow {
        var row = AgentRow(rowKey: "managed|\(model.id)", agent: .claude)
        row.managedID = model.id
        row.sessionID = model.continuationID
        row.task = model.title
        row.cwd = model.root
        row.project = AgentRow.shortProject(model.root)
        row.model = model.modelName
        row.observationSource = .session
        row.liveProcess = model.status == .running
        row.processCount = row.liveProcess ? 1 : 0
        row.harvestMs = model.lastEventMs > 0 ? model.lastEventMs : model.startedMs
        row.startedMs = model.startedMs
        row.sessionStartedMs = model.startedMs
        row.tool = model.currentTool
        row.tokensIn = model.tokensIn
        row.tokensOut = model.tokensOut
        row.sessionErrors = model.errorResults
        row.lastWord = model.lastAgentText
        row.lastErrorText = model.lastErrorText
        // Pulse created this directory; it is disk-confirmed by construction,
        // so the workbench diff card works on managed rows unchanged.
        row.workspaceRoot = model.root
        if case .failed = model.status { row.outcome = "failed" }
        if model.status == .cancelled { row.outcome = "cancelled" }
        // 8.0-β (scene BO) — the principle redrawn, on the 3.0-β/5.0-γ
        // precedent: "Waiting only from a provable signal" was never about
        // *which* signal. A managed turn blocked on a permission ask carries
        // the hardest signal in the product — Pulse's own spool file, written
        // by its own MCP server, with the turn provably suspended on the
        // verdict. Denying that row the waiting state made the fleet's most
        // urgent fact wear a green "running" lamp. An idle turn stays
        // NOT-waiting: your-turn is visible (the reply box), never alarmed —
        // the lamp is for blocked, not for finished.
        if let ask = permissionAsk {
            row.waiting = true
            row.waitKind = "permission"
            row.waitMessage = ManagedPermission.summary(
                toolName: ask.toolName, inputJSON: ask.inputJSON
            )
            row.waitSinceMs = ask.createdMs
        }
        return row
    }
}

extension StatusStore {
    /// Managed changes flow through the same boundary as everything else:
    /// re-merge, re-window. No second pipeline.
    func managedSessionsChanged() {
        cachedAll = sessionSources.merged()
        applyRowWindow()
    }

    /// The dispatch verb, managed edition. Returns a user-readable failure
    /// or nil on success — the sheet shows it in place, never silently.
    /// 6.0-γ: same task, several independent tries — each in its own
    /// worktree and branch, grouped so the inspector can compare them.
    func dispatchManagedAttempts(
        repoRoot: String, task: String, useWorktree: Bool, attempts: Int
    ) -> String? {
        let count = max(1, min(4, attempts))
        guard count > 1 else {
            return dispatchManagedSession(repoRoot: repoRoot, task: task, useWorktree: useWorktree)
        }
        guard useWorktree else { return tr(.managedAttemptsNeedWorktree) }
        let group = UUID().uuidString
        for index in 1...count {
            if let error = dispatchManagedSession(
                repoRoot: repoRoot, task: task, useWorktree: true,
                attemptGroup: group, attemptIndex: index
            ) {
                return error
            }
        }
        return nil
    }

    func dispatchManagedSession(
        repoRoot: String, task: String, useWorktree: Bool,
        attemptGroup: String = "", attemptIndex: Int = 0
    ) -> String? {
        guard ClaudeManagedRuntime.executable() != nil else {
            return tr(.managedNoClaude)
        }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        var root = repoRoot
        var isWorktree = false
        if useWorktree {
            var slug = ManagedWorktree.slug(task: task, nowMs: nowMs)
            if attemptIndex > 0 { slug += "-a\(attemptIndex)" }
            switch ManagedWorktree.create(
                repoRoot: repoRoot,
                slug: slug
            ) {
            case .success(let path):
                root = path
                isWorktree = true
            case .failure(.notARepository):
                return tr(.managedNotARepo)
            case .failure(.gitFailed(let reason)):
                return String(format: tr(.managedWorktreeFailed), reason)
            }
        }
        activateManagedSessions()
        var model = ManagedSession.Model(
            id: UUID().uuidString,
            task: task,
            root: root,
            isWorktree: isWorktree,
            nowMs: nowMs
        )
        model.pendingPrompt = task
        model.attemptGroup = attemptGroup
        managedSessions.fleet.dispatch(model: model)
        DebugLog.write("managed dispatch worktree=\(isWorktree) group=\(attemptGroup.isEmpty ? "-" : "y")")
        return nil
    }

    /// Wire the source into the boundary — idempotent, ordered after
    /// observed by construction. Called on first dispatch and on reattach.
    func activateManagedSessions() {
        sessionSources.register(managedSessions)
        if managedSessions.onChange == nil {
            managedSessions.onChange = { [weak self] in self?.managedSessionsChanged() }
        }
    }

    /// 6.0-α: called once at app start — persisted sessions come back,
    /// interrupted turns honestly labelled, queued ones re-pumped.
    func reattachManagedSessions() {
        managedSessions.fleet.reattachFromDisk()
        if !managedSessions.fleet.runners.isEmpty {
            activateManagedSessions()
            managedSessionsChanged()
        }
    }

    func managedRunner(for row: AgentRow) -> ManagedSessionRunner? {
        guard !row.managedID.isEmpty else { return nil }
        return managedSessions.runner(managedID: row.managedID)
    }

    /// 6.0-α: clear a finished session's record. The fleet's own change
    /// notification re-merges the boundary.
    func managedRemove(_ row: AgentRow) {
        guard !row.managedID.isEmpty else { return }
        managedSessions.fleet.remove(managedID: row.managedID)
    }

    /// 6.0-β: the asks a session is blocked on, live.
    func managedPermissionRequests(for row: AgentRow) -> [ManagedPermission.Request] {
        guard !row.managedID.isEmpty else { return [] }
        return managedSessions.fleet.pendingPermissions.filter { $0.managedID == row.managedID }
    }

    func managedPermissionDecide(id: String, allow: Bool) {
        managedSessions.fleet.decidePermission(id: id, allow: allow)
    }

    /// 6.0-γ: the other tries of the same task, dispatch order.
    func managedAttemptSiblings(for row: AgentRow) -> [ManagedSessionRunner] {
        guard let runner = managedRunner(for: row),
              !runner.model.attemptGroup.isEmpty else { return [] }
        return managedSessions.fleet.attemptSiblings(group: runner.model.attemptGroup)
    }
}
