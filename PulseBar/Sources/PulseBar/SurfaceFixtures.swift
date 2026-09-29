import Foundation

/// 15.0 · Witness — named worlds for the surfaces that are values.
///
/// Every fixture goes through the real `make` of its model: a fixture fakes
/// the world (sessions, history, a held request), never the surface.
/// `SurfaceCapture` renders each one; `SurfaceModelTests` asserts the
/// product's rules over them.
enum SurfaceFixtures {
    enum Value {
        /// 17.0: the tray row's face (23.0: at rest, or under the pointer).
        case row(TrayRowModel, hovering: Bool = false)
        /// 23.0: the tray header — the why and its freshness.
        case header(TrayHeaderModel)
        /// 23.0: the tray's one notice.
        case notice(TrayNoticeModel)
        /// 23.0: the visible type-to-filter field.
        case filter(query: String, matches: Int, lang: ResolvedLanguage)
        /// 22.0: a session's last hour.
        case timeline(TimelineStripModel, ResolvedLanguage)
        /// 23.0: one session in full.
        case detail(DetailModel)
        /// 23.0: the Settings page.
        case settings(SettingsModel)
        /// 23.0: the Diagnostics window.
        case diagnostics(DiagnosticsModel)
        /// 19.0: the self-check's report.
        case doctor(DoctorModel.Report)
    }

    struct Fixture {
        var name: String
        /// Render width in points.
        var width: Double
        var value: Value
    }

    static let names = [
        "row-blocked", "row-blocked-front", "row-pending", "row-running", "row-running-hover",
        "row-stalled", "row-your-turn", "row-process-only", "row-muted",
        "header-fresh", "header-stale", "notice-hooks", "filter",
        "timeline-strip", "detail-blocked", "detail-your-turn",
        "settings", "diagnostics", "doctor-report",
    ]

    static func all(lang: ResolvedLanguage) -> [Fixture] {
        [
            Fixture(name: "row-blocked", width: 448, value: .row(rowModel(rowPermission(), lang: lang))),
            Fixture(name: "row-blocked-front", width: 448, value: .row(rowModel(rowQuestionFront(), lang: lang))),
            Fixture(name: "row-pending", width: 448, value: .row(rowModel(rowPending(), lang: lang))),
            Fixture(name: "row-running", width: 448, value: .row(rowModel(rowRunning(), lang: lang))),
            // The common row under the pointer — the chevron sits beside the
            // time, never on it.
            Fixture(name: "row-running-hover", width: 448, value: .row(rowModel(rowRunning(), lang: lang), hovering: true)),
            Fixture(name: "row-stalled", width: 448, value: .row(rowModel(rowStalled(), lang: lang))),
            Fixture(name: "row-your-turn", width: 448, value: .row(rowModel(rowTurn(), lang: lang))),
            Fixture(name: "row-process-only", width: 448, value: .row(rowModel(rowProcessOnly(), lang: lang))),
            Fixture(name: "row-muted", width: 448, value: .row(rowModel(rowRunning(), lang: lang, muted: true))),
            Fixture(name: "header-fresh", width: 448, value: .header(header(lang: lang, scanAgoMs: 3_000))),
            Fixture(name: "header-stale", width: 448, value: .header(header(lang: lang, scanAgoMs: 4 * minute))),
            Fixture(name: "notice-hooks", width: 432, value: .notice(noticeHooks(lang: lang))),
            Fixture(name: "filter", width: 432, value: .filter(query: "login", matches: 2, lang: lang)),
            Fixture(name: "timeline-strip", width: 400, value: .timeline(timelineStrip(), lang)),
            Fixture(name: "detail-blocked", width: 448, value: .detail(detailPermission(lang: lang))),
            Fixture(name: "detail-your-turn", width: 448, value: .detail(detailTurn(lang: lang))),
            Fixture(name: "settings", width: 500, value: .settings(settings(lang: lang))),
            Fixture(name: "diagnostics", width: 620, value: .diagnostics(diagnostics(lang: lang))),
            Fixture(name: "doctor-report", width: 520, value: .doctor(doctorReport(lang: lang))),
        ]
    }

    // MARK: - The world

    static let t0: Int64 = 1_800_000_000_000

    // MARK: - 17.0 · Tray rows

    /// Tray rows are drawn against now, so their world is built around it.
    static var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    static let minute: Int64 = 60_000

    static func rowModel(_ row: AgentRow, lang: ResolvedLanguage, muted: Bool = false) -> TrayRowModel {
        TrayRowModel.make(TrayRowModel.Input(row: row, lang: lang, nowMs: nowMs, muted: muted))
    }

    static func baseRow(_ agent: AgentID, key: String, task: String = "Fix the flaky login test") -> AgentRow {
        var row = AgentRow(rowKey: key, agent: agent)
        row.sessionID = key
        row.task = task
        row.cwd = "/Users/me/code/app"
        row.project = "app"
        row.source = .session
        row.liveProcess = true
        row.pid = 4312
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

    /// Forty minutes of work, a four-minute permission wait, then working
    /// again — the shape a person should read without the numbers.
    static func timelineStrip() -> TimelineStripModel {
        TimelineStripModel.make(spans: [
            TimelineSpan(state: .running, evidence: .harvest, startMs: nowMs - 48 * minute, endMs: nowMs - 12 * minute),
            TimelineSpan(state: .blocked, evidence: .hook, kind: "Permission", startMs: nowMs - 12 * minute, endMs: nowMs - 8 * minute),
            TimelineSpan(state: .running, evidence: .harvest, startMs: nowMs - 8 * minute, endMs: nil),
        ], nowMs: nowMs)
    }

    // MARK: - 23.0 · The tray's header, notice and filter

    static func header(lang: ResolvedLanguage, scanAgoMs: Int64) -> TrayHeaderModel {
        TrayHeaderModel.make(TrayHeaderModel.Input(
            rows: [rowPermission(), rowPending(), rowRunning(), rowStalled(), rowTurn(), rowProcessOnly()],
            lang: lang,
            nowMs: nowMs,
            lastScanMs: nowMs - scanAgoMs,
            intervalSeconds: 2
        ))
    }

    static func noticeHooks(lang: ResolvedLanguage) -> TrayNoticeModel {
        TrayNoticeModel.pick(TrayNoticeModel.Input(
            lang: lang, notifyOnWaiting: true, notifyAuthorized: true,
            bannerFailed: false, hooksMissing: true, scanIncomplete: false
        )) ?? TrayNoticeModel(
            kind: .hooksMissing, text: "", actionTitle: "", action: .installHooks, systemImage: "link", tone: .idle
        )
    }

    // MARK: - 23.0 · The detail page

    static func detail(_ row: AgentRow, lang: ResolvedLanguage, audit: NotificationAuditModel? = nil) -> DetailModel {
        DetailModel.make(row: row, lang: lang, nowMs: nowMs, audit: audit, timeline: timelineStrip())
    }

    static func detailPermission(lang: ResolvedLanguage) -> DetailModel {
        var wait = SessionLog.Wait(
            id: "fx-perm|1", kind: "Permission", title: "Fix the flaky login test",
            raisedMs: nowMs - 8 * minute, holdsDismissal: false
        )
        wait.outcome = "posted"
        wait.outcomeMs = nowMs - 8 * minute
        return detail(rowPermission(), lang: lang, audit: NotificationAuditModel.make(wait: wait, nowMs: nowMs, lang: lang))
    }

    static func detailTurn(lang: ResolvedLanguage) -> DetailModel {
        detail(rowTurn(), lang: lang)
    }

    // MARK: - 23.0 · Settings

    static func settings(lang: ResolvedLanguage) -> SettingsModel {
        SettingsModel(
            lang: lang,
            launchAtLogin: true,
            language: .auto,
            hotkey: .commandShiftP,
            hotkeyTaken: false,
            notifications: .allowed,
            notifyOnWaiting: true,
            mutedAgents: SettingsModel.sortedMuted([.gemini, .aider]),
            hooksStatus: HooksSupport.Status.installedBoth.label(lang: lang),
            hooksInstalled: true,
            hookTest: L10n.t(.hookTestPassed, lang),
            hookTestTone: .running,
            hookTestRunning: false,
            allowTerminalAutomation: false,
            readProtectedAppData: false,
            updateCheckEnabled: true,
            updateStatus: String(format: L10n.t(.updateAvailable, lang), "23.1.0"),
            updateAvailable: true,
            version: "Pulse \(PulseVersion.semver) · a1b2c3d · 2026-09-29",
            buildWarning: L10n.t(.updatePreview, lang),
            focus: nil
        )
    }

    // MARK: - 23.0 · Diagnostics

    static func diagnostics(lang: ResolvedLanguage) -> DiagnosticsModel {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        let agents: [DiagnosticsModel.Agent] = [
            .init(
                agent: .claude, name: AgentID.claude.displayName,
                state: DiagnosticsModel.stateWord(.available, lang: lang),
                tone: DiagnosticsModel.tone(.available), severity: DiagnosticsModel.severity(.available),
                details: [t(.supportStructured), t(.supportFocusTTY), t(.supportDepthSession)]
            ),
            .init(
                agent: .codex, name: AgentID.codex.displayName,
                state: DiagnosticsModel.stateWord(.needsAction, lang: lang),
                tone: DiagnosticsModel.tone(.needsAction), severity: DiagnosticsModel.severity(.needsAction),
                fix: .installHooks, fixTitle: DiagnosticsModel.fixTitle(.installHooks, lang: lang),
                details: [t(.supportStructured), t(.supportMissingWaiting)]
            ),
            .init(
                agent: .gemini, name: AgentID.gemini.displayName,
                state: DiagnosticsModel.stateWord(.limited, lang: lang),
                tone: DiagnosticsModel.tone(.limited), severity: DiagnosticsModel.severity(.limited),
                warning: t(.supportYieldDrifted),
                details: [t(.supportStructured)]
            ),
            .init(
                agent: .aider, name: AgentID.aider.displayName,
                state: DiagnosticsModel.stateWord(.notInstalled, lang: lang),
                tone: DiagnosticsModel.tone(.notInstalled), severity: DiagnosticsModel.severity(.notInstalled),
                details: [t(.supportCollectorSourceAbsentDetail)]
            ),
        ]
        let activity = ActivityLogModel(entries: [
            .init(
                id: "a", atMs: t0 - 4 * minute, clock: "14:02", agent: .claude, place: "app · Fix the flaky login test",
                text: t(.needsYou) + " · " + L10n.waitKind("Permission", lang) + " · " + t(.signalHooks), tone: .waiting
            ),
            .init(
                id: "b", atMs: t0 - 12 * minute, clock: "13:54", agent: .codex, place: "app",
                text: t(.running) + " · " + t(.activityFromSession), tone: .running
            ),
        ])
        return DiagnosticsModel.make(DiagnosticsModel.Input(
            lang: lang,
            scanLine: t(.lastReadJustNow) + " · " + String(format: t(.probeEvery), 2),
            banners: [
                .init(
                    id: "scan", text: t(.supportScanIncomplete),
                    fix: .retryScan, fixTitle: DiagnosticsModel.fixTitle(.retryScan, lang: lang)
                ),
            ],
            doctor: doctorReport(lang: lang),
            doctorRunning: false,
            agents: agents,
            activity: activity,
            activityAgents: [.claude, .codex],
            copied: false
        ))
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
