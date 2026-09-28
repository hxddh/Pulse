import Foundation

/// 14.0 · Proof — the store's side of evidence by working copy.
///
/// The book itself (`EvidenceBook`, PulseManaged) owns checks, evidence and
/// code identity per directory; this is only the glue that maps a row to its
/// working copy and a Mission to the rows it can take in.
@MainActor
extension StatusStore {
    var evidenceBook: EvidenceBook { managedSessions.fleet.evidence }

    /// The working copy a row's evidence belongs to — empty for a remote row
    /// (its path is another machine's) and for a row with no known root.
    func proofRoot(_ row: AgentRow) -> String {
        guard !row.isRemote else { return "" }
        return EvidenceBook.key(row.workspaceRoot)
    }

    // MARK: - A working copy's own ruler

    func workingCopyChecks(_ row: AgentRow) -> [Mission.Check] {
        let root = proofRoot(row)
        return root.isEmpty ? [] : evidenceBook.checks(for: root)
    }

    /// Writing checks is the opt-in for this directory; clearing them opts out.
    func setWorkingCopyChecks(_ row: AgentRow, text: String) {
        let root = proofRoot(row)
        guard !root.isEmpty else { return }
        let checks = Mission.revisedChecks(
            fromLines: text, previous: evidenceBook.checks(for: root), newID: { UUID().uuidString }
        )
        evidenceBook.setChecks(checks, for: root)
    }

    func runWorkingCopyChecks(_ row: AgentRow) {
        let root = proofRoot(row)
        guard !root.isEmpty else { return }
        evidenceBook.runChecks(evidenceBook.checks(for: root), at: root)
    }

    func cancelWorkingCopyChecks(_ row: AgentRow) {
        let root = proofRoot(row)
        guard !root.isEmpty else { return }
        evidenceBook.cancel(at: root)
    }

    func workingCopyStanding(_ check: Mission.Check, _ row: AgentRow) -> Mission.CheckStanding {
        let root = proofRoot(row)
        return Mission.checkStanding(
            of: check,
            evidence: evidenceBook.evidence(for: root),
            running: evidenceBook.runningCheck(for: root)
        ) { self.evidenceBook.standing(of: $0, at: root) }
    }

    func workingCopyBusy(_ row: AgentRow) -> Bool {
        let root = proofRoot(row)
        return !root.isEmpty && evidenceBook.isBusy(at: root)
    }

    func refreshWorkingCopy(_ row: AgentRow) {
        let root = proofRoot(row)
        guard !root.isEmpty else { return }
        evidenceBook.refresh(at: root)
    }

    // MARK: - External Candidates

    /// Missions a row's working copy can join: every Mission, newest first.
    var missionsForJoining: [Mission.Model] {
        managedSessions.fleet.missions.filter { !$0.archived }.reversed()
    }

    /// The Mission this row's working copy is already an external Candidate
    /// of, if any.
    func joinedMission(_ row: AgentRow) -> Mission.Model? {
        let root = proofRoot(row)
        guard !root.isEmpty else { return nil }
        return managedSessions.fleet.missions.first { mission in
            mission.externals.contains { $0.root == root }
        }
    }

    func joinMission(_ mission: Mission.Model, row: AgentRow) {
        let root = proofRoot(row)
        guard !root.isEmpty else { return }
        managedSessions.fleet.addExternal(missionID: mission.id, root: root, label: row.agent.displayName)
    }

    func leaveMission(_ mission: Mission.Model, externalID: String) {
        managedSessions.fleet.removeExternal(missionID: mission.id, externalID: externalID)
    }

    /// The observed row working in an external Candidate's copy right now.
    func observedRow(forRoot root: String) -> AgentRow? {
        let key = EvidenceBook.key(root)
        return cachedAll.first { !$0.isManaged && !$0.isRemote && EvidenceBook.key($0.workspaceRoot) == key }
    }

    // MARK: - The tray's one fact

    /// Check counts for every working copy that has a ruler, keyed by root:
    /// a Mission Candidate's worktree against its contract revision, any
    /// other working copy against its own checks. Counts only.
    var proofSummaries: [String: EvidenceBook.Summary] {
        var out: [String: EvidenceBook.Summary] = [:]
        for (root, record) in evidenceBook.records where !record.checks.isEmpty && !record.evidence.isEmpty {
            out[root] = evidenceBook.summary(of: record.checks, at: root)
        }
        for runner in managedSessions.fleet.runners {
            guard let mission = managedSessions.fleet.mission(id: runner.model.missionID) else { continue }
            let checks = (mission.contract(revision: runner.model.contractRevision) ?? mission.contract).checks
            let root = EvidenceBook.key(runner.model.root)
            guard !checks.isEmpty, !runner.acceptanceEvidence.isEmpty else { continue }
            out[root] = evidenceBook.summary(of: checks, at: root)
        }
        return out
    }
}
