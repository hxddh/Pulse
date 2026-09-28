import Foundation

/// 15.0 · Witness — named worlds for the Workbench's judgement surfaces.
///
/// Every fixture goes through the real `MissionBoard.make` /
/// `ProofCardModel.make` and the real `EvidenceStanding.of`: a fixture fakes
/// the world (sessions, evidence, the code's current fingerprint), never the
/// surface. `SurfaceCapture` renders each one; `SurfaceModelTests` asserts the
/// product's rules over all of them.
enum SurfaceFixtures {
    enum Value {
        case mission(MissionBoard)
        case proof(ProofCardModel)
    }

    struct Fixture {
        var name: String
        /// Render width in points — the inspector column is about this wide.
        var width: Double
        var value: Value
    }

    static let names = [
        "mission-compare", "mission-no-checks", "mission-legacy-crowded",
        "proof-empty", "proof-results", "proof-running",
    ]

    static func all(lang: ResolvedLanguage) -> [Fixture] {
        [
            Fixture(name: "mission-compare", width: 760, value: .mission(missionCompare(lang: lang))),
            Fixture(name: "mission-no-checks", width: 760, value: .mission(missionNoChecks(lang: lang))),
            Fixture(name: "mission-legacy-crowded", width: 760, value: .mission(missionLegacyCrowded(lang: lang))),
            Fixture(name: "proof-empty", width: 620, value: .proof(proofEmpty(lang: lang))),
            Fixture(name: "proof-results", width: 620, value: .proof(proofResults(lang: lang))),
            Fixture(name: "proof-running", width: 620, value: .proof(proofRunning(lang: lang))),
        ]
    }

    // MARK: - The world

    static let t0: Int64 = 1_800_000_000_000
    static let fingerprint = CodeFingerprint(sha256: "code-as-checked")
    static let changed = CodeFingerprint(sha256: "code-edited-since")

    static func evidence(
        _ outcome: AcceptanceEvidence.Outcome,
        _ checkID: String?,
        root: String,
        exit: Int32? = 0,
        at offset: Int64 = 0
    ) -> AcceptanceEvidence {
        var e = AcceptanceEvidence.make(
            command: "fixture", cwd: root,
            startedAtMs: t0 + offset, finishedAtMs: t0 + offset + 1_000,
            stdout: Data(), stderr: Data(), exitCode: exit,
            preFingerprint: fingerprint, postFingerprint: fingerprint,
            checkID: checkID
        )
        e.outcome = outcome
        return e
    }

    /// The real judgement against the code as it is "now" in each root.
    static func judge(current: [String: CodeFingerprint]) -> (AcceptanceEvidence, String) -> EvidenceStanding {
        { evidence, root in
            EvidenceStanding.of(evidence, current: current[root], measured: current[root] != nil)
        }
    }

    static func candidate(
        _ id: String,
        mission: Mission.Model,
        revision: Int,
        status: ManagedSession.Status,
        modelName: String = "claude-fable-5",
        answer: String = "",
        effect: (Int, Int)? = nil,
        errors: Int = 0,
        unknown: Int = 0
    ) -> ManagedSession.Model {
        var m = ManagedSession.Model(
            id: id, task: mission.contract.goal,
            root: "/Users/me/.pulse-worktrees/app/\(id)", isWorktree: true, nowMs: t0
        )
        m.missionID = mission.id
        m.contractRevision = revision
        m.modelName = modelName
        m.status = status
        m.lastResultText = answer
        m.lastTurnEffect = effect.map { (insertions: $0.0, deletions: $0.1) }
        m.errorResults = errors
        m.unknownEvents = unknown
        return m
    }

    // MARK: - Missions

    /// Two Candidates Pulse launched (one on an older contract) and one
    /// working copy the user joined; every kind of cell.
    static func missionCompare(lang: ResolvedLanguage) -> MissionBoard {
        let test = Mission.Check(id: "c-test", command: "swift test")
        let lint = Mission.Check(id: "c-lint", command: "make lint")
        var mission = Mission.Model(
            id: "m-login", repoRoot: "/Users/me/code/app",
            goal: "Make the login flow survive a dropped network without losing the typed password",
            constraints: "No schema changes. Keep the public API.",
            checks: [test], createdMs: t0
        )
        mission.revise(goal: mission.contract.goal, constraints: mission.contract.constraints,
                       checks: [test, lint], frozen: true)
        let first = candidate(
            "a1", mission: mission, revision: 1, status: .idle,
            answer: "Retries the request with backoff and keeps the form state.",
            effect: (42, 7)
        )
        let second = candidate(
            "a2", mission: mission, revision: 2, status: .idle,
            answer: "Moves the password into a keychain-backed draft.",
            effect: (118, 36), errors: 1
        )
        mission.candidateIDs = ["a1", "a2"]
        mission.addExternal(root: "/Users/me/code/app-codex", label: "Codex", id: "x-codex", nowMs: t0)
        mission.chosenCandidateID = "a2"

        var external = AgentRow(rowKey: "codex|s-9", agent: .codex)
        external.workspaceRoot = "/Users/me/code/app-codex"
        external.model = "gpt-5.2-codex"
        external.liveProcess = true
        external.lastWord = "Added an offline queue for the login request."
        external.changedPaths = 3
        external.insertions = 64
        external.deletions = 12

        let byRoot: [String: [AcceptanceEvidence]] = [
            first.root: [evidence(.passed, "c-test", root: first.root)],
            second.root: [
                evidence(.passed, "c-test", root: second.root),
                evidence(.failed, "c-lint", root: second.root, exit: 2, at: 2_000),
            ],
            external.workspaceRoot: [evidence(.interrupted, "c-lint", root: external.workspaceRoot, exit: nil)],
        ]
        return MissionBoard.make(MissionBoard.Input(
            mission: mission,
            candidates: [first, second],
            currentCandidateID: "a2",
            lifecycle: .ready,
            lang: lang,
            observed: { $0 == external.workspaceRoot ? external : nil },
            evidence: { byRoot[$0] ?? [] },
            // The second Candidate's code changed after its pass.
            judge: judge(current: [first.root: fingerprint, second.root: changed, external.workspaceRoot: fingerprint])
        ))
    }

    /// A Mission with no ruler: nothing may ever read as verified.
    static func missionNoChecks(lang: ResolvedLanguage) -> MissionBoard {
        var mission = Mission.Model(
            id: "m-draft", repoRoot: "/Users/me/code/app",
            goal: "Tidy the settings screen", createdMs: t0
        )
        let only = candidate("b1", mission: mission, revision: 1, status: .queued)
        mission.candidateIDs = ["b1"]
        return MissionBoard.make(MissionBoard.Input(
            mission: mission, candidates: [only], currentCandidateID: "b1",
            lifecycle: .running, lang: lang
        ))
    }

    /// A migrated Mission with four Candidates, a long goal and a long
    /// command: the widths and truncation of the real card.
    static func missionLegacyCrowded(lang: ResolvedLanguage) -> MissionBoard {
        let check = Mission.Check(
            id: "c-long",
            command: "xcodebuild -scheme App -destination 'platform=macOS' test-without-building -only-testing:AppTests/LoginFlowTests"
        )
        var mission = Mission.Model(
            id: "legacy-g-1", repoRoot: "/Users/me/code/app",
            goal: String(repeating: "Rewrite the synchronisation layer so conflicts surface to the user instead of silently winning. ", count: 3),
            checks: [check], createdMs: t0
        )
        mission.legacy = true
        let statuses: [ManagedSession.Status] = [.idle, .failed("error_max_turns"), .interrupted, .running]
        let candidates = statuses.enumerated().map { index, status in
            candidate("c\(index + 1)", mission: mission, revision: 1, status: status,
                      answer: index == 0 ? String(repeating: "A long final answer. ", count: 12) : "")
        }
        mission.candidateIDs = candidates.map(\.id)
        let first = candidates[0].root
        let running = candidates[3].root
        return MissionBoard.make(MissionBoard.Input(
            mission: mission,
            candidates: candidates,
            runningCandidateIDs: [candidates[3].id],
            currentCandidateID: "c1",
            lifecycle: .running,
            lang: lang,
            evidence: { $0 == first ? [evidence(.timedOut, "c-long", root: first, exit: nil)] : [] },
            judge: judge(current: [first: fingerprint, running: fingerprint])
        ))
    }

    // MARK: - Working copies

    static let workingCopy = "/Users/me/code/app"

    static func joinableMissions() -> [Mission.Model] {
        var older = Mission.Model(id: "m-old", repoRoot: workingCopy, goal: "Speed up cold launch", createdMs: t0)
        older.candidateIDs = ["x"]
        var newer = Mission.Model(id: "m-new", repoRoot: workingCopy, goal: "Fix the flaky login test", createdMs: t0 + 1)
        newer.candidateIDs = ["y"]
        var archived = Mission.Model(id: "m-archived", repoRoot: workingCopy, goal: "Old experiment", createdMs: t0 - 1)
        archived.archived = true
        return [archived, older, newer]
    }

    /// No ruler yet: the opt-in state.
    static func proofEmpty(lang: ResolvedLanguage) -> ProofCardModel {
        ProofCardModel.make(ProofCardModel.Input(
            root: workingCopy, checks: [], missions: joinableMissions(), lang: lang
        ))
    }

    /// Pass, fail, stale and not-yet-run, joined to a Mission.
    static func proofResults(lang: ResolvedLanguage) -> ProofCardModel {
        let checks = [
            Mission.Check(id: "p1", command: "swift test"),
            Mission.Check(id: "p2", command: "make lint"),
            Mission.Check(id: "p3", command: "./scripts/e2e.sh --headless"),
            Mission.Check(id: "p4", command: "npm run typecheck"),
        ]
        var joined = joinableMissions()
        joined[2].addExternal(root: workingCopy, label: "Claude Code", id: "x-here", nowMs: t0)
        var stale = evidence(.passed, "p3", root: workingCopy, at: 3_000)
        stale.postFingerprint = changed
        return ProofCardModel.make(ProofCardModel.Input(
            root: workingCopy,
            checks: checks,
            evidence: [
                evidence(.passed, "p1", root: workingCopy),
                evidence(.failed, "p2", root: workingCopy, exit: 1, at: 1_000),
                stale,
            ],
            missions: joined,
            lang: lang,
            judge: { EvidenceStanding.of($0, current: fingerprint, measured: true) }
        ))
    }

    /// A check running, one whose pass has not been measured against the
    /// code yet, and one that timed out.
    static func proofRunning(lang: ResolvedLanguage) -> ProofCardModel {
        let checks = [
            Mission.Check(id: "r1", command: "swift test"),
            Mission.Check(id: "r2", command: "make lint"),
            Mission.Check(id: "r3", command: "make e2e"),
        ]
        return ProofCardModel.make(ProofCardModel.Input(
            root: workingCopy,
            checks: checks,
            evidence: [
                evidence(.passed, "r2", root: workingCopy),
                evidence(.timedOut, "r3", root: workingCopy, exit: nil, at: 1_000),
            ],
            running: RunningCheck(command: "swift test", cwd: workingCopy, startedAtMs: t0 + 5_000, checkID: "r1"),
            busy: true,
            missions: [],
            lang: lang,
            judge: { EvidenceStanding.of($0, current: nil, measured: false) }
        ))
    }
}
