import Foundation
import Darwin

/// 6.0-α — the supervisor (docs/plan-6.0.md, scene BI).
///
/// 5.0's runners were ad hoc objects hanging off the store: alive only while
/// the app was, one at a time, unsupervised. The fleet makes them a managed
/// population — a concurrency cap with a real queue, per-session state files
/// that survive restarts, and an honest reattach: a turn that was running
/// when the app died comes back as `interrupted`, never as a success or a
/// failure nobody witnessed.
///
/// Persistence is bounded: a session is written when its status kind, turn,
/// remembered check command or newest evidence moves — never per stream line.
@MainActor
final class ManagedFleet {
    static let maxConcurrent = 3

    private(set) var runners: [ManagedSessionRunner] = []
    private struct PersistenceMarker: Equatable {
        var statusKind: String
        var turns: Int
        var runCommand: String
        var lastEvidence: AcceptanceEvidence?
    }
    private var lastPersisted: [String: PersistenceMarker] = [:]
    private var pumping = false
    /// Fired after any session change, wired by the source.
    var onChange: (() -> Void)?
    /// What "start" means — the real turn in production; tests inject a
    /// process-free stand-in to pin the queue semantics themselves.
    var startAction: (ManagedSessionRunner) -> Void = { $0.beginQueuedTurn() }

    var runningCount: Int {
        runners.filter { $0.model.status == .running }.count
    }

    // MARK: - Lifecycle

    /// Load every persisted session back. Called once at app start; the
    /// state layer maps a persisted "running" to `interrupted` itself.
    func reattachFromDisk() {
        guard runners.isEmpty else { return }
        for model in ManagedSession.loadAll() {
            attach(ManagedSessionRunner(model: model))
        }
        pump()
    }

    /// A new session enters queued with its prompt held; the pump decides
    /// when it actually starts.
    func dispatch(model: ManagedSession.Model) {
        var queued = model
        queued.status = .queued
        let runner = ManagedSessionRunner(model: queued)
        attach(runner)
        persist(runner)
        pump()
        onChange?()
    }

    func runner(managedID: String) -> ManagedSessionRunner? {
        runners.first { $0.model.id == managedID }
    }

    /// Sessions in the same same-task attempt group, in dispatch order.
    func attemptSiblings(group: String) -> [ManagedSessionRunner] {
        guard !group.isEmpty else { return [] }
        return runners.filter { $0.model.attemptGroup == group }
    }

    /// Remove a finished session: state file goes, the worktree stays for
    /// the user (Pulse does not delete work products on cleanup — the path
    /// is shown, the choice is theirs).
    func remove(managedID: String) {
        guard let runner = runner(managedID: managedID),
              runner.model.status != .running else { return }
        runners.removeAll { $0.model.id == managedID }
        lastPersisted[managedID] = nil
        ManagedSession.removeState(id: managedID)
        pump()
        onChange?()
    }

    /// Quit: write everyone down exactly as they are (a running turn
    /// persists as running and reattaches as interrupted — the truthful
    /// account), then reap every child.
    func shutdown() {
        for runner in runners {
            ManagedSession.persist(runner.model)
            runner.terminateForShutdown()
        }
    }

    // MARK: - The pump

    private func attach(_ runner: ManagedSessionRunner) {
        runners.append(runner)
        runner.onChange = { [weak self, weak runner] in
            guard let self, let runner else { return }
            self.runnerChanged(runner)
        }
        startPermissionWatcher()
    }

    // MARK: - Permission asks (6.0-β)

    private var permissionSource: DispatchSourceFileSystemObject?
    private(set) var pendingPermissions: [ManagedPermission.Request] = []

    /// One directory watch for the whole fleet, armed with the first runner
    /// and kept — a single fd, event-driven, no polling.
    private func startPermissionWatcher() {
        guard permissionSource == nil else { return }
        let dir = ManagedPermission.requestsDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main
        )
        source.setEventHandler { [weak self] in self?.refreshPermissions() }
        source.setCancelHandler { close(fd) }
        source.resume()
        permissionSource = source
        refreshPermissions()
    }

    func refreshPermissions() {
        let requests = ManagedPermission.readRequests()
        if requests != pendingPermissions {
            pendingPermissions = requests
            onChange?()
        }
    }

    /// The verdict, single-use, under the Respond gate: Allow only ever
    /// lands beside the full text — a truncated request's allow is refused
    /// here again even if a caller tried.
    func decidePermission(id: String, allow: Bool) {
        guard let request = pendingPermissions.first(where: { $0.id == id }) else { return }
        let effectiveAllow = allow && request.canOfferAllow
        ManagedPermission.writeVerdict(ManagedPermission.Verdict(
            id: id,
            allow: effectiveAllow,
            message: effectiveAllow ? "" : "denied by user"
        ))
        pendingPermissions.removeAll { $0.id == id }
        DebugLog.write("managed permission decide allow=\(effectiveAllow)")
        onChange?()
    }

    private func runnerChanged(_ runner: ManagedSessionRunner) {
        persistIfMoved(runner)
        pump()
        onChange?()
    }

    /// Start queued sessions while slots are free. Reentrancy-guarded: a
    /// started turn's own change notification pumps again and must no-op.
    func pump() {
        guard !pumping else { return }
        pumping = true
        defer { pumping = false }
        while runningCount < Self.maxConcurrent,
              let next = runners.first(where: { $0.model.status == .queued }) {
            startAction(next)
            // A refused start (no prompt, no executable) still leaves
            // .queued behind only if nothing changed — bail rather than spin.
            if next.model.status == .queued { break }
        }
    }

    // MARK: - Bounded persistence

    private func persistIfMoved(_ runner: ManagedSessionRunner) {
        let state = ManagedSession.State(model: runner.model)
        let marker = PersistenceMarker(
            statusKind: state.statusKind,
            turns: state.turns,
            runCommand: state.runCommand,
            lastEvidence: state.acceptanceEvidence.last
        )
        if lastPersisted[state.id] == marker { return }
        lastPersisted[state.id] = marker
        ManagedSession.persist(runner.model)
    }

    private func persist(_ runner: ManagedSessionRunner) {
        let state = ManagedSession.State(model: runner.model)
        lastPersisted[state.id] = PersistenceMarker(
            statusKind: state.statusKind,
            turns: state.turns,
            runCommand: state.runCommand,
            lastEvidence: state.acceptanceEvidence.last
        )
        ManagedSession.persist(runner.model)
    }
}
