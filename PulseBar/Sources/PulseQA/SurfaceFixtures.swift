import Foundation
@testable import PulseApp

/// Named worlds for the surfaces that are values.
///
/// Every fixture goes through the real `make` of its model: a fixture fakes
/// the world (sessions, history, a held request), never the surface.
/// `SurfaceCapture` renders each one; `SurfaceModelTests` asserts the
/// product's rules over them.
enum SurfaceFixtures {
    enum Value {
        /// The tray row's face, at rest or selected (under the pointer or
        /// the keyboard — one highlight).
        case row(TrayRowModel, selected: Bool = false)
        /// The tray header — the why, in counts.
        case header(TrayHeaderModel)
        /// The tray's one notice.
        case notice(TrayNoticeModel)
        /// One session in full.
        case detail(DetailModel)
        /// The Settings page (its Hooks section is the diagnostics).
        case settings(SettingsModel)
    }

    struct Fixture {
        var name: String
        /// Render width in points.
        var width: Double
        var value: Value
    }

    static let names = [
        "row-blocked", "row-blocked-front", "row-running", "row-running-selected",
        "row-stalled", "row-your-turn", "row-process-only",
        "row-running-step", "row-stalled-step",
        "header", "notice-setup", "notice-setup-done", "notice-setup-failed", "row-app-only",
        "detail-blocked", "detail-your-turn", "detail-steps", "detail-stalled", "detail-app-only",
        "settings", "settings-login-approval",
    ]

    static func all(lang: ResolvedLanguage) -> [Fixture] {
        [
            Fixture(name: "row-blocked", width: 448, value: .row(rowModel(rowPermission(), lang: lang))),
            Fixture(name: "row-blocked-front", width: 448, value: .row(rowModel(rowQuestionFront(), lang: lang))),
            Fixture(name: "row-running", width: 448, value: .row(rowModel(rowRunning(), lang: lang))),
            // The common row, selected (the pointer entered it): the one
            // highlight, and its "›" column — always there, clearer now —
            // beside the time, never on it.
            Fixture(name: "row-running-selected", width: 448, value: .row(rowModel(rowRunning(), lang: lang), selected: true)),
            Fixture(name: "row-stalled", width: 448, value: .row(rowModel(rowStalled(), lang: lang))),
            Fixture(name: "row-your-turn", width: 448, value: .row(rowModel(rowTurn(), lang: lang))),
            Fixture(name: "row-process-only", width: 448, value: .row(rowModel(rowProcessOnly(), lang: lang))),
            // A running row's quiet last step, and its turn's duration in
            // the time slot.
            Fixture(name: "row-running-step", width: 448, value: .row(rowModel(rowRunningStep(), lang: lang))),
            // A stalled row whose why names the last step.
            Fixture(name: "row-stalled-step", width: 448, value: .row(rowModel(rowStalledStep(), lang: lang))),
            Fixture(name: "header", width: 448, value: .header(header(lang: lang))),
            Fixture(name: "notice-setup", width: 432, value: .notice(noticeSetup(lang: lang))),
            Fixture(name: "notice-setup-done", width: 432, value: .notice(noticeSetupDone(lang: lang))),
            Fixture(name: "notice-setup-failed", width: 432, value: .notice(noticeSetupFailed(lang: lang))),
            // A Go that reached the app only, where a Terminal tab script
            // was tried: the notice says where macOS's Automation
            // permission is.
            Fixture(name: "row-app-only", width: 448, value: .row(rowModel(rowTerminalTab(), lang: lang, appOnly: true))),
            Fixture(name: "detail-blocked", width: 448, value: .detail(detailPermission(lang: lang))),
            Fixture(name: "detail-your-turn", width: 448, value: .detail(detailTurn(lang: lang))),
            // Up to five recent steps and this turn's duration — the page's
            // one clock.
            Fixture(name: "detail-steps", width: 448, value: .detail(detailSteps(lang: lang))),
            // A stalled row: its why is the row's own second line, so the
            // page does not say it twice.
            Fixture(name: "detail-stalled", width: 448, value: .detail(detailStalled(lang: lang))),
            // The same landing notice on the detail page.
            Fixture(name: "detail-app-only", width: 448, value: .detail(detailAppOnly(lang: lang))),
            // Install all / Remove all, and one status line per agent.
            Fixture(name: "settings", width: 500, value: .settings(settings(lang: lang))),
            // Open at login registered, and macOS waiting for approval.
            Fixture(name: "settings-login-approval", width: 500, value: .settings(settingsLoginApproval(lang: lang))),
        ]
    }

    // MARK: - Tray rows

    /// Tray rows are drawn against now, so their world is built around it.
    static var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    static let minute: Int64 = 60_000

    static func rowModel(_ row: AgentRow, lang: ResolvedLanguage, appOnly: Bool = false) -> TrayRowModel {
        let notice = appOnly ? RowNotice.appOnly(row: row, lang: lang) : nil
        return TrayRowModel.make(TrayRowModel.Input(row: row, lang: lang, nowMs: nowMs, notice: notice))
    }

    static func baseRow(_ agent: AgentID, key: String, task: String = "Fix the flaky login test") -> AgentRow {
        var row = AgentRow(rowKey: key, agent: agent)
        row.sessionID = key
        row.task = task
        row.cwd = "/Users/me/code/app"
        row.project = "app"
        row.source = .hooks
        row.liveProcess = true
        row.pid = 4312
        row.state = .running
        row.lastEventMs = nowMs - 1 * minute
        row.startedMs = nowMs - 40 * minute
        row.landing = LandingHandle(tmuxPane: "%3", term: "tmux")
        row.landingPlan = LandingPlan(steps: [.tmuxPane(pane: "%3", socket: "", hostBundleIDs: [])])
        return row
    }

    static func rowPermission() -> AgentRow {
        var row = baseRow(.claude, key: "fx-perm")
        row.state = .blocked(RowWait(
            kind: "Permission", ask: "Bash: npm run build", sinceMs: nowMs - 8 * minute
        ))
        return row
    }

    static func rowQuestionFront() -> AgentRow {
        var row = baseRow(.claude, key: "fx-question")
        row.state = .blocked(RowWait(
            kind: "Input", ask: "Which database should the migration target?",
            sinceMs: nowMs - 30_000, inFront: true
        ))
        return row
    }

    static func rowTurn() -> AgentRow {
        var row = baseRow(.codex, key: "fx-turn", task: "Add an offline queue for login")
        row.state = .yourTurn(sinceMs: nowMs - 3 * minute)
        row.lastWord = "All 42 tests pass; the queue drains on reconnect."
        return row
    }

    static func rowStalled() -> AgentRow {
        var row = baseRow(.gemini, key: "fx-stalled", task: "Port the parser to Swift")
        row.isStalled = true
        row.lastEventMs = nowMs - 25 * minute
        row.activityMs = nowMs - 25 * minute
        return row
    }

    static func rowRunning() -> AgentRow {
        baseRow(.codex, key: "fx-running", task: "Add retry with jitter to the upload queue")
    }

    /// A session in a Terminal.app tab whose tab script did not land (macOS
    /// Automation denied): a Go brings Terminal forward, not the tab.
    static func rowTerminalTab() -> AgentRow {
        var row = baseRow(.claude, key: "fx-terminal-tab", task: "Rename the settings keys")
        row.landing = LandingHandle("tty:/dev/ttys004;term:Apple_Terminal")
        row.landingPlan = LandingPlan.make(handle: row.landing, cwd: row.cwd, pid: 4312)
        return row
    }

    /// Five steps, as a hook reports them: the tool, its target, when.
    static func steps(endingAt last: Int64) -> [SessionBook.Step] {
        [
            SessionBook.Step(tool: "Read", target: "Sources/Upload/Queue.swift", ms: last - 9 * minute),
            SessionBook.Step(tool: "Edit", target: "Sources/Upload/Queue.swift", ms: last - 7 * minute),
            SessionBook.Step(tool: "Grep", target: "retryDelay", ms: last - 5 * minute),
            SessionBook.Step(tool: "Edit", target: "Sources/Upload/Backoff.swift", ms: last - 3 * minute),
            SessionBook.Step(tool: "Bash", target: "swift test", ms: last),
        ]
    }

    static func rowRunningStep() -> AgentRow {
        var row = baseRow(.claude, key: "fx-running-step", task: "Add retry with jitter to the upload queue")
        row.recentSteps = steps(endingAt: nowMs - 2 * minute)
        row.lastStep = row.recentSteps.last
        row.turnStartMs = nowMs - 14 * minute
        row.lastEventMs = nowMs - 2 * minute
        row.activityMs = nowMs - 2 * minute
        return row
    }

    static func rowStalledStep() -> AgentRow {
        var row = rowStalled()
        row.recentSteps = steps(endingAt: nowMs - 25 * minute)
        row.lastStep = row.recentSteps.last
        row.turnStartMs = nowMs - 40 * minute
        return row
    }

    static func rowProcessOnly() -> AgentRow {
        var row = AgentRow(rowKey: "cursor|pid:4242", agent: .cursor)
        row.source = .process
        row.liveProcess = true
        row.pid = 4242
        row.state = .processOnly
        return row
    }

    // MARK: - The tray's header and notice

    static func header(lang: ResolvedLanguage) -> TrayHeaderModel {
        TrayHeaderModel.make(
            counts: TrayState.Counts(rows: [rowPermission(), rowQuestionFront(), rowRunning(), rowStalled(), rowTurn(), rowProcessOnly()]),
            lang: lang
        )
    }

    /// The first-run card: agents on this Mac, not connected.
    static func noticeSetup(lang: ResolvedLanguage) -> TrayNoticeModel {
        TrayNoticeModel.pick(TrayNoticeModel.Input(
            lang: lang, notifyAuthorized: nil,
            bannerFailed: false, unconnected: [.claude, .codex]
        )) ?? TrayNoticeModel(
            kind: .setup, text: "", actionTitle: "", action: .connect, systemImage: "link", tone: .idle
        )
    }

    /// The card right after "Connect": what is left to do.
    static func noticeSetupDone(lang: ResolvedLanguage) -> TrayNoticeModel {
        TrayNoticeModel.pick(TrayNoticeModel.Input(
            lang: lang, notifyAuthorized: true,
            bannerFailed: false, justConnected: [.claude, .codex]
        )) ?? TrayNoticeModel(
            kind: .setupDone, text: "", actionTitle: "", action: .dismissSetup, systemImage: "checkmark.circle", tone: .idle
        )
    }

    /// The card after an install that failed for one agent: why, and where
    /// to fix it — never "Connect" again.
    static func noticeSetupFailed(lang: ResolvedLanguage) -> TrayNoticeModel {
        TrayNoticeModel.pick(TrayNoticeModel.Input(
            lang: lang, notifyAuthorized: true, bannerFailed: false,
            installFailure: HooksSupport.Status.failureText([.gemini: .invalidJSON], lang: lang)
        )) ?? TrayNoticeModel(
            kind: .setupFailed, text: "", actionTitle: "", action: .openHooksSettings,
            systemImage: "exclamationmark.triangle", tone: .attention
        )
    }

    // MARK: - The detail page

    static func detailPermission(lang: ResolvedLanguage) -> DetailModel {
        DetailModel.make(row: rowPermission(), lang: lang, nowMs: nowMs)
    }

    static func detailTurn(lang: ResolvedLanguage) -> DetailModel {
        DetailModel.make(row: rowTurn(), lang: lang, nowMs: nowMs)
    }

    static func detailSteps(lang: ResolvedLanguage) -> DetailModel {
        DetailModel.make(row: rowRunningStep(), lang: lang, nowMs: nowMs)
    }

    static func detailStalled(lang: ResolvedLanguage) -> DetailModel {
        DetailModel.make(row: rowStalledStep(), lang: lang, nowMs: nowMs)
    }

    static func detailAppOnly(lang: ResolvedLanguage) -> DetailModel {
        let row = rowTerminalTab()
        return DetailModel.make(
            row: row, lang: lang, nowMs: nowMs,
            notice: RowNotice.appOnly(row: row, lang: lang)
        )
    }

    // MARK: - Settings

    static func settings(lang: ResolvedLanguage) -> SettingsModel {
        SettingsModel(
            lang: lang,
            launchAtLogin: true,
            notifications: .allowed,
            hooksStatus: HooksSupport.Status.installed([.claude, .codex, .gemini]).label(lang: lang),
            hooksInstalled: true,
            hookAgents: SettingsModel.hookAgents(
                installed: [.claude, .codex, .gemini],
                present: [.claude, .codex, .cursor, .gemini],
                lastEventMs: [.claude: nowMs - 12_000, .codex: nowMs - 3 * minute],
                nowMs: nowMs,
                lang: lang
            ),
            absentAgents: SettingsModel.absentAgents(
                installed: [.claude, .codex, .gemini],
                present: [.claude, .codex, .cursor, .gemini]
            ),
            version: "Pulse \(PulseVersion.semver) · a1b2c3d · 2026-09-29",
            buildWarning: L10n.t(.buildPreview, lang),
            focus: nil
        )
    }

    /// Open at login asked for; macOS holds it until the person approves
    /// it in Login Items.
    static func settingsLoginApproval(lang: ResolvedLanguage) -> SettingsModel {
        var model = settings(lang: lang)
        let login = SettingsModel.loginLine(asked: true, state: .requiresApproval)
        model.launchAtLogin = login.isOn
        model.loginNote = login.note
        return model
    }
}
