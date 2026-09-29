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
        /// 22.0: a session's last hour.
        case timeline(TimelineStripModel, ResolvedLanguage)
        /// 23.0: one session in full.
        case detail(DetailModel)
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
        "row-stalled", "row-process-only",
        "row-running", "row-running-hover", "timeline-strip",
        "detail-permission", "detail-turn",
        "doctor-report",
    ]

    static func all(lang: ResolvedLanguage) -> [Fixture] {
        [
            Fixture(name: "row-permission", width: 420, value: .row(rowModel(rowPermission(), lang: lang), expanded: true)),
            Fixture(name: "row-question-front", width: 420, value: .row(rowModel(rowQuestionFront(), lang: lang), expanded: true)),
            Fixture(name: "row-turn", width: 420, value: .row(rowModel(rowTurn(), lang: lang), expanded: true)),
            Fixture(name: "row-pending", width: 420, value: .row(rowModel(rowPending(), lang: lang), expanded: true)),
            Fixture(name: "row-stalled", width: 420, value: .row(rowModel(rowStalled(), lang: lang), expanded: false)),
            Fixture(name: "row-process-only", width: 420, value: .row(rowModel(rowProcessOnly(), lang: lang), expanded: false)),
            // 21.0: the common row, at rest and under the pointer — the
            // trailing controls must sit beside the time, never on it.
            Fixture(name: "row-running", width: 420, value: .row(rowModel(rowRunning(), lang: lang), expanded: false)),
            Fixture(name: "row-running-hover", width: 420, value: .row(rowModel(rowRunning(), lang: lang), expanded: false, hovering: true)),
            Fixture(name: "timeline-strip", width: 400, value: .timeline(timelineStrip(), lang)),
            Fixture(name: "detail-permission", width: 448, value: .detail(detailPermission(lang: lang))),
            Fixture(name: "detail-turn", width: 448, value: .detail(detailTurn(lang: lang))),
            Fixture(name: "doctor-report", width: 520, value: .doctor(doctorReport(lang: lang))),
        ]
    }

    // MARK: - The world

    static let t0: Int64 = 1_800_000_000_000

    // MARK: - 17.0 · Tray rows

    /// Tray rows are drawn against now, so their world is built around it.
    static var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    static let minute: Int64 = 60_000

    static func rowModel(_ row: AgentRow, lang: ResolvedLanguage) -> TrayRowModel {
        TrayRowModel.make(TrayRowModel.Input(row: row, lang: lang, nowMs: nowMs, stallMinutes: 20))
    }

    static func baseRow(_ agent: AgentID, key: String, task: String = "Fix the flaky login test") -> AgentRow {
        var row = AgentRow(rowKey: key, agent: agent)
        row.sessionID = key
        row.task = task
        row.cwd = "/Users/me/code/app"
        row.project = "app"
        row.source = .session
        row.liveProcess = true
        row.state = .running
        row.harvestMs = nowMs - 1 * minute
        row.startedMs = nowMs - 40 * minute
        row.focusTier = .tty
        return row
    }

    static func rowPermission() -> AgentRow {
        var row = baseRow(.claude, key: "fx-perm")
        row.model = "claude-sonnet-4"
        row.state = .blocked(RowWait(
            kind: "Permission", ask: "Bash: npm run build", sinceMs: nowMs - 8 * minute, signal: .hooks
        ))
        return row
    }

    static func rowQuestionFront() -> AgentRow {
        var row = baseRow(.claude, key: "fx-question")
        row.state = .blocked(RowWait(
            kind: "Input", ask: "Which database should the migration target?",
            sinceMs: nowMs - 30_000, signal: .hooks, inFront: true
        ))
        return row
    }

    static func rowTurn() -> AgentRow {
        var row = baseRow(.codex, key: "fx-turn", task: "Add an offline queue for login")
        row.state = .yourTurn(sinceMs: nowMs - 3 * minute)
        row.lastWord = "All 42 tests pass; the queue drains on reconnect."
        row.model = "gpt-5"
        row.planSteps = [
            ActivityHarvest.PlanStep(text: "Queue writes while offline", state: .done),
            ActivityHarvest.PlanStep(text: "Drain on reconnect", state: .done),
            ActivityHarvest.PlanStep(text: "Cover it with tests", state: .done),
        ]
        return row
    }

    static func rowPending() -> AgentRow {
        var row = baseRow(.cline, key: "fx-pending", task: "Refactor the settings screen")
        row.state = .blocked(RowWait(kind: "Permission", sinceMs: nowMs - 2 * minute, signal: .pending))
        return row
    }

    static func rowStalled() -> AgentRow {
        var row = baseRow(.gemini, key: "fx-stalled", task: "Port the parser to Swift")
        row.isStalled = true
        row.harvestMs = nowMs - 25 * minute
        return row
    }

    /// Forty minutes of work, a four-minute permission wait, then working
    /// again — the shape a person should read without the numbers.
    static func timelineStrip() -> TimelineStripModel {
        TimelineStripModel.make(spans: [
            TimelineSpan(state: .running, evidence: .harvest, startMs: nowMs - 48 * minute, endMs: nowMs - 12 * minute),
            TimelineSpan(state: .blocked, evidence: .hook, kind: "Permission", startMs: nowMs - 12 * minute, endMs: nowMs - 8 * minute),
            TimelineSpan(state: .running, evidence: .harvest, startMs: nowMs - 8 * minute, endMs: nil),
        ], nowMs: nowMs)
    }

    static func rowRunning() -> AgentRow {
        var row = baseRow(.codex, key: "fx-running", task: "Add retry with jitter to the upload queue")
        row.model = "gpt-5"
        return row
    }

    static func rowProcessOnly() -> AgentRow {
        var row = AgentRow(rowKey: "amp|pid:4242", agent: .amp)
        row.source = .process
        row.liveProcess = true
        row.pid = 4242
        row.state = .processOnly
        return row
    }

    // MARK: - 23.0 · The detail page

    static func detail(_ row: AgentRow, lang: ResolvedLanguage, audit: [String] = []) -> DetailModel {
        var model = DetailModel.make(
            row: row,
            face: rowModel(row, lang: lang),
            lang: lang,
            nowMs: nowMs,
            stallMinutes: 20,
            timeline: timelineStrip()
        )
        model.audit = audit
        return model
    }

    static func detailPermission(lang: ResolvedLanguage) -> DetailModel {
        var wait = SessionLog.Wait(
            id: "fx-perm|1", kind: "Permission", title: "Fix the flaky login test",
            raisedMs: nowMs - 8 * minute, holdsDismissal: false
        )
        wait.outcome = "posted"
        wait.outcomeMs = nowMs - 8 * minute
        let audit = NotificationAuditModel.make(wait: wait, nowMs: nowMs, lang: lang).lines
        return detail(rowPermission(), lang: lang, audit: audit)
    }

    static func detailTurn(lang: ResolvedLanguage) -> DetailModel {
        detail(rowTurn(), lang: lang)
    }

    // MARK: - 19.0 · The self-check

    /// A Mac with a realistic mix: Claude proven, an old Claude without
    /// `agents`, Codex installed but not yet trusted.
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
        return DoctorModel.evaluate(f, lang: lang)
    }
}
