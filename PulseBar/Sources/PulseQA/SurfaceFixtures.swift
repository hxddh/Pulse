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
        /// The tray row's face, at rest or under the pointer.
        case row(TrayRowModel, hovering: Bool = false)
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
        "row-blocked", "row-blocked-front", "row-running", "row-running-hover",
        "row-stalled", "row-your-turn", "row-process-only", "row-muted",
        "header", "notice-setup", "notice-setup-done", "row-automation-offer", "detail-blocked", "detail-your-turn",
        "settings",
    ]

    static func all(lang: ResolvedLanguage) -> [Fixture] {
        [
            Fixture(name: "row-blocked", width: 448, value: .row(rowModel(rowPermission(), lang: lang))),
            Fixture(name: "row-blocked-front", width: 448, value: .row(rowModel(rowQuestionFront(), lang: lang))),
            Fixture(name: "row-running", width: 448, value: .row(rowModel(rowRunning(), lang: lang))),
            // The common row under the pointer — the chevron sits beside the
            // time, never on it.
            Fixture(name: "row-running-hover", width: 448, value: .row(rowModel(rowRunning(), lang: lang), hovering: true)),
            Fixture(name: "row-stalled", width: 448, value: .row(rowModel(rowStalled(), lang: lang))),
            Fixture(name: "row-your-turn", width: 448, value: .row(rowModel(rowTurn(), lang: lang))),
            Fixture(name: "row-process-only", width: 448, value: .row(rowModel(rowProcessOnly(), lang: lang))),
            Fixture(name: "row-muted", width: 448, value: .row(rowModel(rowRunning(), lang: lang, muted: true))),
            Fixture(name: "header", width: 448, value: .header(header(lang: lang))),
            Fixture(name: "notice-setup", width: 432, value: .notice(noticeSetup(lang: lang))),
            Fixture(name: "notice-setup-done", width: 432, value: .notice(noticeSetupDone(lang: lang))),
            Fixture(name: "row-automation-offer", width: 448, value: .row(rowModel(rowRunning(), lang: lang, offer: true))),
            Fixture(name: "detail-blocked", width: 448, value: .detail(detailPermission(lang: lang))),
            Fixture(name: "detail-your-turn", width: 448, value: .detail(detailTurn(lang: lang))),
            Fixture(name: "settings", width: 500, value: .settings(settings(lang: lang))),
        ]
    }

    // MARK: - Tray rows

    /// Tray rows are drawn against now, so their world is built around it.
    static var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    static let minute: Int64 = 60_000

    static func rowModel(_ row: AgentRow, lang: ResolvedLanguage, muted: Bool = false, offer: Bool = false) -> TrayRowModel {
        let notice = offer ? RowNotice.automationOffer(lang: lang) : nil
        return TrayRowModel.make(TrayRowModel.Input(row: row, lang: lang, nowMs: nowMs, notice: notice, muted: muted))
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
        row.model = "claude-sonnet-4"
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
        row.model = "gpt-5"
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
        var row = baseRow(.codex, key: "fx-running", task: "Add retry with jitter to the upload queue")
        row.model = "gpt-5"
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
            rows: [rowPermission(), rowQuestionFront(), rowRunning(), rowStalled(), rowTurn(), rowProcessOnly()],
            lang: lang
        )
    }

    /// The first-run card: agents on this Mac, not connected.
    static func noticeSetup(lang: ResolvedLanguage) -> TrayNoticeModel {
        TrayNoticeModel.pick(TrayNoticeModel.Input(
            lang: lang, notifyOnWaiting: true, notifyAuthorized: nil,
            bannerFailed: false, unconnected: [.claude, .codex]
        )) ?? TrayNoticeModel(
            kind: .setup, text: "", actionTitle: "", action: .connect, systemImage: "link", tone: .idle
        )
    }

    /// The card right after "Connect": what is left to do.
    static func noticeSetupDone(lang: ResolvedLanguage) -> TrayNoticeModel {
        TrayNoticeModel.pick(TrayNoticeModel.Input(
            lang: lang, notifyOnWaiting: true, notifyAuthorized: true,
            bannerFailed: false, justConnected: [.claude, .codex]
        )) ?? TrayNoticeModel(
            kind: .setupDone, text: "", actionTitle: "", action: .dismissSetup, systemImage: "checkmark.circle", tone: .idle
        )
    }

    // MARK: - The detail page

    static func detailPermission(lang: ResolvedLanguage) -> DetailModel {
        DetailModel.make(row: rowPermission(), lang: lang, nowMs: nowMs)
    }

    static func detailTurn(lang: ResolvedLanguage) -> DetailModel {
        DetailModel.make(row: rowTurn(), lang: lang, nowMs: nowMs)
    }

    // MARK: - Settings

    static func settings(lang: ResolvedLanguage) -> SettingsModel {
        SettingsModel(
            lang: lang,
            launchAtLogin: true,
            language: .auto,
            hotkey: .controlOptionSpace,
            hotkeyTaken: false,
            notifications: .allowed,
            notifyOnWaiting: true,
            mutedAgents: SettingsModel.sortedMuted([.gemini, .pi]),
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
            updateCheckEnabled: true,
            updateStatus: String(format: L10n.t(.updateAvailable, lang), "23.1.0"),
            updateAvailable: true,
            version: "Pulse \(PulseVersion.semver) · a1b2c3d · 2026-09-29",
            buildWarning: L10n.t(.updatePreview, lang),
            focus: nil
        )
    }
}
