import Foundation

/// 15.0 · Witness — named worlds for the surfaces that are values.
///
/// Every fixture goes through the real `make` of its model: a fixture fakes
/// the world (sessions, history, a held request), never the surface.
/// `SurfaceCapture` renders each one; `SurfaceModelTests` asserts the
/// product's rules over them.
enum SurfaceFixtures {
    enum Value {
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
        "row-permission", "row-question-front", "row-turn", "row-pending",
        "row-stalled", "row-snoozed", "row-process-only",
        "row-running", "row-running-hover",
        "why-permission", "why-turn",
        "card-respond", "card-respond-truncated", "card-respond-decided",
        "card-expanded",
        "doctor-report",
    ]

    static func all(lang: ResolvedLanguage) -> [Fixture] {
        [
            Fixture(name: "row-permission", width: 420, value: .row(rowModel(rowPermission(), lang: lang), expanded: true)),
            Fixture(name: "row-question-front", width: 420, value: .row(rowModel(rowQuestionFront(), lang: lang), expanded: true)),
            Fixture(name: "row-turn", width: 420, value: .row(rowModel(rowTurn(), lang: lang), expanded: true)),
            Fixture(name: "row-pending", width: 420, value: .row(rowModel(rowPending(), lang: lang), expanded: true)),
            Fixture(name: "row-stalled", width: 420, value: .row(rowModel(rowStalled(), lang: lang), expanded: false)),
            Fixture(name: "row-snoozed", width: 420, value: .row(rowModel(rowSnoozed(), lang: lang, snoozeLabel: "Later · 12m"), expanded: false)),
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
            Fixture(name: "card-expanded", width: 380, value: .expanded(cardExpanded(lang: lang))),
            Fixture(name: "doctor-report", width: 520, value: .doctor(doctorReport(lang: lang))),
        ]
    }

    // MARK: - The world

    static let t0: Int64 = 1_800_000_000_000

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
            toolName: "Bash", expiresAtMs: nowMs + 10 * minute
        )
        let narrator = RowNarrator(lang: lang, nowMs: nowMs)
        return RowCardModel.make(RowCardModel.Input(
            row: row, narrator: narrator, inbound: inbound,
            fateNote: decided ? narrator.tr(.respondTakenNote) : nil
        ))
    }

    static func cardExpanded(lang: ResolvedLanguage) -> RowCardModel {
        var row = baseRow(.claude, key: "fx-expanded", task: "Add an offline queue for login")
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
            row: row, narrator: RowNarrator(lang: lang, nowMs: nowMs)
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
