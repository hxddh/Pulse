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
    private(set) var runners: [ManagedSessionRunner] = []
    /// Fired on any session change, wired by the store to re-merge.
    var onChange: (() -> Void)?

    var sessions: [AgentRow] {
        runners.map { Self.row(for: $0.model) }
    }

    func add(_ runner: ManagedSessionRunner) {
        runners.append(runner)
        runner.onChange = { [weak self] in self?.onChange?() }
        onChange?()
    }

    func runner(managedID: String) -> ManagedSessionRunner? {
        runners.first { $0.model.id == managedID }
    }

    func terminateAllForShutdown() {
        for runner in runners { runner.terminateForShutdown() }
    }

    /// Model → row, pure and pinned by tests. First-party facts: the stream
    /// is Pulse's own, so nothing here carries a "not measured" discount —
    /// but absence still renders as absence, never as zero.
    /// `nonisolated`: touches no actor state, and the tests call it from a
    /// plain XCTestCase.
    nonisolated static func row(for model: ManagedSession.Model) -> AgentRow {
        var row = AgentRow(rowKey: "managed|\(model.id)", agent: .claude)
        row.managedID = model.id
        row.sessionID = model.claudeSessionID
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
    func dispatchManagedSession(repoRoot: String, task: String, useWorktree: Bool) -> String? {
        guard ManagedSession.claudeExecutable() != nil else {
            return tr(.managedNoClaude)
        }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        var root = repoRoot
        var isWorktree = false
        if useWorktree {
            switch ManagedWorktree.create(
                repoRoot: repoRoot,
                slug: ManagedWorktree.slug(task: task, nowMs: nowMs)
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
        if managedSessions.runners.isEmpty {
            // First dispatch registers the source — after observed, so the
            // coordinator's ground-truth rule holds by construction.
            sessionSources.register(managedSessions)
            managedSessions.onChange = { [weak self] in self?.managedSessionsChanged() }
        }
        let model = ManagedSession.Model(
            id: UUID().uuidString,
            task: task,
            root: root,
            isWorktree: isWorktree,
            nowMs: nowMs
        )
        let runner = ManagedSessionRunner(model: model)
        managedSessions.add(runner)
        runner.send(prompt: task)
        DebugLog.write("managed dispatch worktree=\(isWorktree)")
        return nil
    }

    func managedRunner(for row: AgentRow) -> ManagedSessionRunner? {
        guard !row.managedID.isEmpty else { return nil }
        return managedSessions.runner(managedID: row.managedID)
    }
}
