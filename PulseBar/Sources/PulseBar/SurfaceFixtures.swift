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
        /// 17.0: the tray row's face; `expanded` shows the why line.
        case row(TrayRowModel, expanded: Bool, hovering: Bool = false)
        case why(WhyCardModel)
        /// 19.0: the cards under a row — `asks` is the in-list "needs you
        /// now" card, `expanded` the in-place inspector.
        case asks(RowCardModel)
        case expanded(RowCardModel)
        /// 19.0: the self-check's report.
        case doctor(DoctorModel.Report)
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
        "row-permission", "row-question-front", "row-turn", "row-pending",
        "row-stalled", "row-snoozed", "row-remote-lost", "row-process-only",
        "row-running", "row-running-hover",
        "why-permission", "why-turn",
        "card-respond", "card-respond-truncated", "card-respond-decided",
        "card-managed-ask", "card-managed-recovery", "card-expanded-managed",
        "doctor-report",
    ]

    static func all(lang: ResolvedLanguage) -> [Fixture] {
        [
            Fixture(name: "mission-compare", width: 760, value: .mission(missionCompare(lang: lang))),
            Fixture(name: "mission-no-checks", width: 760, value: .mission(missionNoChecks(lang: lang))),
            Fixture(name: "mission-legacy-crowded", width: 760, value: .mission(missionLegacyCrowded(lang: lang))),
            Fixture(name: "proof-empty", width: 620, value: .proof(proofEmpty(lang: lang))),
            Fixture(name: "proof-results", width: 620, value: .proof(proofResults(lang: lang))),
            Fixture(name: "proof-running", width: 620, value: .proof(proofRunning(lang: lang))),
            Fixture(name: "row-permission", width: 420, value: .row(rowModel(rowPermission(), lang: lang), expanded: true)),
            Fixture(name: "row-question-front", width: 420, value: .row(rowModel(rowQuestionFront(), lang: lang), expanded: true)),
            Fixture(name: "row-turn", width: 420, value: .row(rowModel(rowTurn(), lang: lang), expanded: true)),
            Fixture(name: "row-pending", width: 420, value: .row(rowModel(rowPending(), lang: lang), expanded: true)),
            Fixture(name: "row-stalled", width: 420, value: .row(rowModel(rowStalled(), lang: lang), expanded: false)),
            Fixture(name: "row-snoozed", width: 420, value: .row(rowModel(rowSnoozed(), lang: lang, snoozeLabel: "Later · 12m"), expanded: false)),
            Fixture(name: "row-remote-lost", width: 420, value: .row(rowModel(rowRemoteLost(), lang: lang), expanded: false)),
            Fixture(name: "row-process-only", width: 420, value: .row(rowModel(rowProcessOnly(), lang: lang), expanded: false)),
            // 21.0: the common row, at rest and under the pointer — the
            // trailing controls must sit beside the time, never on it.
            Fixture(name: "row-running", width: 420, value: .row(rowModel(rowRunning(), lang: lang), expanded: false)),
            Fixture(name: "row-running-hover", width: 420, value: .row(rowModel(rowRunning(), lang: lang), expanded: false, hovering: true)),
            Fixture(name: "why-permission", width: 520, value: .why(whyPermission(lang: lang))),
            Fixture(name: "why-turn", width: 520, value: .why(whyTurn(lang: lang))),
            Fixture(name: "card-respond", width: 380, value: .asks(cardRespond(lang: lang))),
            Fixture(name: "card-respond-truncated", width: 380, value: .asks(cardRespond(lang: lang, truncated: true))),
            Fixture(name: "card-respond-decided", width: 380, value: .asks(cardRespond(lang: lang, decided: true))),
            Fixture(name: "card-managed-ask", width: 380, value: .asks(cardManagedAsk(lang: lang))),
            Fixture(name: "card-managed-recovery", width: 380, value: .asks(cardManagedRecovery(lang: lang))),
            Fixture(name: "card-expanded-managed", width: 380, value: .expanded(cardExpandedManaged(lang: lang))),
            Fixture(name: "doctor-report", width: 520, value: .doctor(doctorReport(lang: lang))),
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

    // MARK: - 17.0 · Tray rows

    /// Tray rows are measured against the real clock (`waitAgeSeconds`,
    /// `lastActivitySeconds` read it), so their world is built around now.
    static var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    static let minute: Int64 = 60_000

    static func rowModel(_ row: AgentRow, lang: ResolvedLanguage, snoozeLabel: String = "") -> TrayRowModel {
        TrayRowModel.make(TrayRowModel.Input(
            row: row,
            narrator: RowNarrator(lang: lang, nowMs: nowMs),
            snoozeLabel: snoozeLabel
        ))
    }

    static func baseRow(_ agent: AgentID, key: String, task: String = "Fix the flaky login test") -> AgentRow {
        var row = AgentRow(rowKey: key, agent: agent)
        row.sessionID = key
        row.task = task
        row.cwd = "/Users/me/code/app"
        row.project = "app"
        row.observationSource = .session
        row.liveProcess = true
        row.processCount = 1
        row.harvestMs = nowMs - 1 * minute
        row.startedMs = nowMs - 40 * minute
        row.records = 212
        row.focusTier = .tty
        return row
    }

    static func rowPermission() -> AgentRow {
        var row = baseRow(.claude, key: "fx-perm")
        row.waiting = true
        row.waitKind = "Permission"
        row.waitMessage = "Bash: npm run build"
        row.waitSignal = .hooks
        row.waitSinceMs = nowMs - 8 * minute
        return row
    }

    static func rowQuestionFront() -> AgentRow {
        var row = baseRow(.claude, key: "fx-question")
        row.waiting = true
        row.waitKind = "Input"
        row.waitMessage = "Which database should the migration target?"
        row.waitSignal = .hooks
        row.waitSinceMs = nowMs - 30_000
        row.waitRaisedInFront = true
        return row
    }

    static func rowTurn() -> AgentRow {
        var row = baseRow(.codex, key: "fx-turn", task: "Add an offline queue for login")
        row.yourTurn = true
        row.turnSinceMs = nowMs - 3 * minute
        row.lastWord = "All 42 tests pass; the queue drains on reconnect."
        return row
    }

    static func rowPending() -> AgentRow {
        var row = baseRow(.cursor, key: "fx-pending", task: "Refactor the settings screen")
        row.waiting = true
        row.waitKind = "Permission"
        row.waitSignal = .pending
        row.tool = "request_approval"
        row.waitSinceMs = nowMs - 2 * minute
        return row
    }

    static func rowStalled() -> AgentRow {
        var row = baseRow(.gemini, key: "fx-stalled", task: "Port the parser to Swift")
        row.isStalled = true
        row.harvestMs = nowMs - 25 * minute
        return row
    }

    static func rowSnoozed() -> AgentRow {
        var row = rowPermission()
        row.rowKey = "fx-snoozed"
        row.snoozeRemainingSeconds = 12 * 60
        return row
    }

    static func rowRemoteLost() -> AgentRow {
        var row = AgentRow(rowKey: "claude|s-r@devbox", agent: .claude)
        row.sessionID = "s-r"
        row.task = "Nightly dependency bump"
        row.host = "devbox"
        row.observationSource = .remote
        row.lastHeardMs = nowMs - 70 * minute
        row.lostContact = true
        return row
    }

    static func rowRunning() -> AgentRow {
        var row = baseRow(.codex, key: "fx-running", task: "Add retry with jitter to the upload queue")
        row.tokensIn = 48_200
        row.tokensOut = 9_100
        return row
    }

    static func rowProcessOnly() -> AgentRow {
        var row = AgentRow(rowKey: "fx-process", agent: .amp)
        row.observationSource = .process
        row.liveProcess = true
        row.processCount = 2
        return row
    }

    // MARK: - 17.0 · Why

    static func history(_ row: AgentRow, _ kinds: [(String, Int64, String, Bool?)]) -> [AttentionHistory.Event] {
        kinds.map { kind, ago, message, front in
            AttentionHistory.Event(
                agent: row.agent.rawValue, kind: kind, tsMs: nowMs - ago, message: message,
                session: row.sessionID, cwd: row.cwd, front: front
            )
        }
    }

    static func whyPermission(lang: ResolvedLanguage) -> WhyCardModel {
        let row = rowPermission()
        return WhyCardModel.make(
            row: row,
            history: history(row, [
                ("permission", 40 * minute, "Edit: src/Login.swift", false),
                ("done", 39 * minute, "", nil),
                ("turn", 20 * minute, "Refactored the retry loop.", false),
                ("done", 10 * minute, "", nil),
                ("permission", 8 * minute, "Bash: npm run build", false),
            ]),
            narrator: RowNarrator(lang: lang, nowMs: nowMs)
        )
    }

    static func whyTurn(lang: ResolvedLanguage) -> WhyCardModel {
        let row = rowTurn()
        return WhyCardModel.make(
            row: row,
            history: history(row, [
                ("permission", 9 * minute, "git push origin main", false),
                ("turn", 3 * minute, "All 42 tests pass; the queue drains on reconnect.", false),
            ]),
            narrator: RowNarrator(lang: lang, nowMs: nowMs)
        )
    }

    // MARK: - 19.0 · The cards under a row

    static func cardRespond(lang: ResolvedLanguage, truncated: Bool = false, decided: Bool = false) -> RowCardModel {
        let row = rowPermission()
        let full = #"{"tool_name":"Bash","tool_input":{"command":"rm -rf build && npm run build","description":"Clean rebuild"}}"#
        let inbound = RespondSpool.InboundRequest(
            request: PermissionRequest(
                id: "toolu_fx", agent: .claude, session: row.sessionID,
                fullRequest: truncated ? String(full.prefix(48)) : full,
                truncated: truncated, receivedAtMs: nowMs - 8 * minute
            ),
            toolName: "Bash", expiresAtMs: nowMs + 10 * minute, isLocal: true
        )
        let narrator = RowNarrator(lang: lang, nowMs: nowMs)
        return RowCardModel.make(RowCardModel.Input(
            row: row, narrator: narrator, inbound: inbound,
            fateNote: decided ? narrator.tr(.respondTakenNote) : nil
        ))
    }

    static func managedRow(key: String) -> AgentRow {
        var row = baseRow(.claude, key: key, task: "Add an offline queue for login")
        row.managedID = key
        return row
    }

    static func cardManagedAsk(lang: ResolvedLanguage) -> RowCardModel {
        var row = managedRow(key: "fx-managed-ask")
        row.waiting = true
        row.waitKind = "Permission"
        let ask = ManagedPermission.Request(
            id: "ask-1", managedID: row.managedID, toolName: "Bash",
            inputJSON: #"{"command":"git push --force origin main"}"#,
            truncated: true, createdMs: nowMs - 2 * minute
        )
        return RowCardModel.make(RowCardModel.Input(
            row: row, narrator: RowNarrator(lang: lang, nowMs: nowMs),
            permissions: [ask], managedStatus: .running
        ))
    }

    static func cardManagedRecovery(lang: ResolvedLanguage) -> RowCardModel {
        RowCardModel.make(RowCardModel.Input(
            row: managedRow(key: "fx-managed-recovery"),
            narrator: RowNarrator(lang: lang, nowMs: nowMs),
            managedStatus: .interrupted
        ))
    }

    static func cardExpandedManaged(lang: ResolvedLanguage) -> RowCardModel {
        var row = managedRow(key: "fx-managed-expanded")
        row.lastWord = "The queue drains on reconnect; writing the retry test next."
        row.tool = "Edit"
        row.progressDone = 2
        row.progressTotal = 5
        row.planSteps = [
            .init(text: "Read the login flow", state: .done),
            .init(text: "Add the offline queue", state: .done),
            .init(text: "Retry on reconnect", state: .current),
            .init(text: "Tests for the retry", state: .pending),
            .init(text: "Update the changelog", state: .pending),
        ]
        return RowCardModel.make(RowCardModel.Input(
            row: row, narrator: RowNarrator(lang: lang, nowMs: nowMs),
            managedStatus: .running,
            managedEntries: [
                .init(kind: .user, text: "Add an offline queue for login"),
                .init(kind: .agent, text: "Reading the login flow first."),
                .init(kind: .tool, toolName: "Edit", text: "Sources/Login/Queue.swift"),
                .init(kind: .tool, text: "error: missing return", isError: true),
                .init(kind: .agent, text: "The queue drains on reconnect; writing the retry test next."),
            ]
        ))
    }

    // MARK: - 19.0 · The self-check

    /// A Mac with a realistic mix: Claude proven, an old Claude without
    /// `agents`, Codex installed but not yet trusted, Respond never tried.
    static func doctorReport(lang: ResolvedLanguage) -> DoctorModel.Report {
        var f = DoctorModel.Facts()
        f.version = PulseVersion.semver
        f.channel = "preview"
        f.macOS = "26.0.0"
        f.nowMs = t0
        f.claudeInstalled = true
        f.claudeHookEvents = Set(DoctorModel.claudeEvents)
        f.claudeNotificationMatcher = "permission_prompt|idle_prompt|elicitation_dialog"
        f.lastFire = ["claude": .init(kind: "turn", tsMs: t0 - 12 * 60_000)]
        f.claudeAgents = .failed(exitStatus: 1, timedOut: false)
        f.codexInstalled = true
        f.codexHookEvents = Set(DoctorModel.codexEvents)
        f.codexRollout = .paginated
        f.codexCompressedRollouts = 3
        f.respondEnabled = true
        return DoctorModel.evaluate(f, lang: lang)
    }
}
