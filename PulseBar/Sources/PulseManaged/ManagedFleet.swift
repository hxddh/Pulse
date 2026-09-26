import Foundation
import PulseCore
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
package final class ManagedFleet {
    package static let maxConcurrent = 3

    package private(set) var runners: [ManagedSessionRunner] = []

    package init() {}
    private struct PersistenceMarker: Equatable {
        package var statusKind: String
        package var turns: Int
        package var runCommand: String
        package var lastEvidence: AcceptanceEvidence?
        /// The first turn's continuation arrives mid-turn. Without it here a
        /// crash during that turn reloaded an empty id, and "reply to resume"
        /// silently started a new conversation.
        package var continuationID: String
        package var runningCheck: RunningCheck?
    }
    private var lastPersisted: [String: PersistenceMarker] = [:]
    private var pumping = false
    /// Fired after any session change, wired by the source.
    package var onChange: (() -> Void)?
    /// What "start" means — the real turn in production; tests inject a
    /// process-free stand-in to pin the queue semantics themselves.
    package var startAction: (ManagedSessionRunner) -> Void = { $0.beginQueuedTurn() }

    package var runningCount: Int {
        runners.filter { $0.model.status == .running }.count
    }

    // MARK: - Lifecycle

    /// Load every persisted session back. Called once at app start; the
    /// state layer maps a persisted "running" to `interrupted` itself.
    package func reattachFromDisk() {
        guard runners.isEmpty else { return }
        let loaded = ManagedSession.loadAll()
        let existing = Mission.loadAll()
        let migrated = Mission.migrate(sessions: loaded, existing: existing)
        missions = migrated.missions
        let before = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for mission in missions where before[mission.id] != mission {
            Mission.persist(mission)
        }
        let moved = Dictionary(migrated.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for model in loaded {
            if let assigned = moved[model.id] {
                ManagedSession.persist(assigned)
                attach(ManagedSessionRunner(model: assigned))
            } else {
                attach(ManagedSessionRunner(model: model))
            }
        }
        if !migrated.sessions.isEmpty {
            DebugLog.write("missions migrated sessions=\(migrated.sessions.count) missions=\(missions.count)")
        }
        pump()
    }

    // MARK: - Missions (13.0)

    package private(set) var missions: [Mission.Model] = []

    package func mission(id: String) -> Mission.Model? {
        missions.first { $0.id == id }
    }

    /// A Mission's Candidates in dispatch order.
    package func candidates(of missionID: String) -> [ManagedSessionRunner] {
        guard let mission = mission(id: missionID) else { return [] }
        return mission.candidateIDs.compactMap { runner(managedID: $0) }
    }

    package func lifecycle(of missionID: String) -> Mission.Lifecycle? {
        guard let mission = mission(id: missionID) else { return nil }
        return mission.lifecycle(candidateStatuses: candidates(of: missionID).map(\.model.status))
    }

    /// Record a new Mission before its Candidates are dispatched.
    package func create(_ mission: Mission.Model) {
        guard self.mission(id: mission.id) == nil else { return }
        missions.append(mission)
        Mission.persist(mission)
        onChange?()
    }

    /// Dispatch a Candidate of `missionID`: it runs the current contract.
    package func dispatch(candidate model: ManagedSession.Model, missionID: String) {
        guard let index = missions.firstIndex(where: { $0.id == missionID }) else { return }
        var candidate = model
        candidate.missionID = missionID
        candidate.contractRevision = missions[index].contract.revision
        candidate.pendingPrompt = missions[index].contract.prompt
        if !missions[index].candidateIDs.contains(candidate.id) {
            missions[index].candidateIDs.append(candidate.id)
            Mission.persist(missions[index])
        }
        dispatch(model: candidate)
    }

    /// The user's edit. Once any Candidate has started, the contract is
    /// frozen for it and the edit becomes a new revision.
    package func revise(missionID: String, goal: String, constraints: String, checks: [Mission.Check]) {
        guard let index = missions.firstIndex(where: { $0.id == missionID }) else { return }
        let frozen = candidates(of: missionID).contains {
            $0.model.status != .queued || $0.model.turns > 0
        }
        missions[index].revise(goal: goal, constraints: constraints, checks: checks, frozen: frozen)
        Mission.persist(missions[index])
        onChange?()
    }

    /// The user's choice. It marks a Candidate as chosen — nothing else:
    /// no git write, no ranking. Choosing the chosen one clears it.
    package func choose(missionID: String, candidateID: String) {
        guard let index = missions.firstIndex(where: { $0.id == missionID }),
              missions[index].candidateIDs.contains(candidateID) else { return }
        missions[index].chosenCandidateID =
            missions[index].chosenCandidateID == candidateID ? nil : candidateID
        Mission.persist(missions[index])
        onChange?()
    }

    /// Run the Mission's checks — each Candidate against the contract
    /// revision it was started on — on one Candidate or on all that are
    /// not busy. Candidates run in parallel; checks within one run in order.
    package func runChecks(missionID: String, candidateID: String? = nil) {
        guard let mission = mission(id: missionID) else { return }
        for runner in candidates(of: missionID) {
            if let candidateID, runner.model.id != candidateID { continue }
            let contract = mission.contract(revision: runner.model.contractRevision) ?? mission.contract
            runner.runChecks(contract.checks)
        }
    }

    /// A Mission whose first dispatch failed before any Candidate existed.
    package func dropIfEmpty(missionID: String) {
        guard let index = missions.firstIndex(where: { $0.id == missionID }),
              missions[index].candidateIDs.isEmpty else { return }
        Mission.remove(id: missionID)
        missions.remove(at: index)
        onChange?()
    }

    package func cancelChecks(missionID: String) {
        for runner in candidates(of: missionID) { runner.cancelChecks() }
    }

    /// A new session enters queued with its prompt held; the pump decides
    /// when it actually starts.
    package func dispatch(model: ManagedSession.Model) {
        var queued = model
        queued.status = .queued
        let runner = ManagedSessionRunner(model: queued)
        attach(runner)
        persist(runner)
        pump()
        onChange?()
    }

    package func runner(managedID: String) -> ManagedSessionRunner? {
        runners.first { $0.model.id == managedID }
    }

    /// Sessions in the same same-task attempt group, in dispatch order.
    package func attemptSiblings(group: String) -> [ManagedSessionRunner] {
        guard !group.isEmpty else { return [] }
        return runners.filter { $0.model.attemptGroup == group }
    }

    /// Remove a finished session: state file goes, the worktree stays for
    /// the user (Pulse does not delete work products on cleanup — the path
    /// is shown, the choice is theirs).
    package func remove(managedID: String) {
        guard let runner = runner(managedID: managedID),
              runner.model.status != .running else { return }
        let missionID = runner.model.missionID
        runners.removeAll { $0.model.id == managedID }
        lastPersisted[managedID] = nil
        ManagedSession.removeState(id: managedID)
        // The Mission forgets the Candidate; a Mission with none left goes.
        if let index = missions.firstIndex(where: { $0.id == missionID }) {
            missions[index].candidateIDs.removeAll { $0 == managedID }
            if missions[index].chosenCandidateID == managedID { missions[index].chosenCandidateID = nil }
            if missions[index].candidateIDs.isEmpty {
                Mission.remove(id: missionID)
                missions.remove(at: index)
            } else {
                Mission.persist(missions[index])
            }
        }
        pump()
        onChange?()
    }

    /// Quit: write everyone down exactly as they are (a running turn
    /// persists as running and reattaches as interrupted — the truthful
    /// account), then reap every child.
    package func shutdown() {
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
    package private(set) var pendingPermissions: [ManagedPermission.Request] = []

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

    package func refreshPermissions() {
        let requests = ManagedPermission.readRequests()
        if requests != pendingPermissions {
            pendingPermissions = requests
            onChange?()
        }
    }

    /// The verdict, single-use, under the Respond gate: Allow only ever
    /// lands beside the full text — a truncated request's allow is refused
    /// here again even if a caller tried.
    package func decidePermission(id: String, allow: Bool) {
        guard let request = pendingPermissions.first(where: { $0.id == id }) else { return }
        let effectiveAllow = allow && request.canOfferAllow
        let decision: ManagedApprovalDecision = effectiveAllow ? .allow : .deny(message: "denied by user")
        // The runtime that raised it answers it — the wire is its business.
        // A request whose session is gone still gets a deny, so the asking
        // process is not left waiting on a verdict nobody will write.
        if let runner = runner(managedID: request.managedID) {
            runner.resolveApproval(id: id, decision: decision)
        } else {
            ManagedPermission.writeVerdict(ManagedPermission.Verdict(
                id: id, allow: false, message: "denied: session gone"
            ))
        }
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
    package func pump() {
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
            lastEvidence: state.acceptanceEvidence.last,
            continuationID: state.continuationID,
            runningCheck: state.runningCheck
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
            lastEvidence: state.acceptanceEvidence.last,
            continuationID: state.continuationID,
            runningCheck: state.runningCheck
        )
        ManagedSession.persist(runner.model)
    }
}
