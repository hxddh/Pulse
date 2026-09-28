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

    // MARK: - 15.0 · surfaces as values

    /// The working-copy card for a row, as a value.
    func proofCard(_ row: AgentRow) -> ProofCardModel {
        let root = proofRoot(row)
        let book = evidenceBook
        return ProofCardModel.make(ProofCardModel.Input(
            root: root,
            checks: root.isEmpty ? [] : book.checks(for: root),
            evidence: root.isEmpty ? [] : book.evidence(for: root),
            running: root.isEmpty ? nil : book.runningCheck(for: root),
            busy: workingCopyBusy(row),
            missions: managedSessions.fleet.missions,
            lang: lang,
            judge: { book.standing(of: $0, at: root) }
        ))
    }

    func handle(_ intent: ProofIntent, row: AgentRow) {
        switch intent {
        case .save(let text): setWorkingCopyChecks(row, text: text)
        case .run: runWorkingCopyChecks(row)
        case .stop: cancelWorkingCopyChecks(row)
        case .refresh: refreshWorkingCopy(row)
        case .join(let missionID):
            if let mission = managedSessions.fleet.mission(id: missionID) { joinMission(mission, row: row) }
        case .leave(let missionID, let externalID):
            if let mission = managedSessions.fleet.mission(id: missionID) { leaveMission(mission, externalID: externalID) }
        }
    }

    /// A Mission's Candidates side by side, as a value.
    func missionBoard(_ mission: Mission.Model, currentCandidateID: String) -> MissionBoard {
        let book = evidenceBook
        let runners = managedCandidates(of: mission)
        return MissionBoard.make(MissionBoard.Input(
            mission: mission,
            candidates: runners.map(\.model),
            runningCandidateIDs: Set(runners.filter(\.isRunning).map(\.model.id)),
            currentCandidateID: currentCandidateID,
            lifecycle: managedMissionLifecycle(mission),
            lang: lang,
            observed: { self.observedRow(forRoot: $0) },
            evidence: { book.evidence(for: $0) },
            running: { book.runningCheck(for: $0) },
            busy: { book.isBusy(at: $0) },
            judge: { book.standing(of: $0, at: $1) }
        ))
    }

    func handle(_ intent: MissionIntent, mission: Mission.Model) {
        switch intent {
        case .select(let key): workbenchSelectKey = key
        case .choose(let candidateID): managedChoose(mission, candidateID: candidateID)
        case .leave(let externalID): leaveMission(mission, externalID: externalID)
        case .runChecks: managedRunMissionChecks(mission)
        case .stopChecks: managedCancelMissionChecks(mission)
        }
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
