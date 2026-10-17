import Foundation
@testable import PulseApp
@testable import PulseKit

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
        "detail-blocked", "detail-your-turn", "detail-timeline", "detail-stalled", "detail-app-only",
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
            // The timeline a replay rebuilt — a raise, its echo, the answer,
            // an ignored line, steps — and this turn's duration, the page's
            // one clock.
            Fixture(name: "detail-timeline", width: 448, value: .detail(detailTimeline(lang: lang))),
            // A stalled row: its why is the row's own second line, so the
            // page does not say it twice.
            Fixture(name: "detail-stalled", width: 448, value: .detail(detailStalled(lang: lang))),
            // The same landing notice on the detail page.
            Fixture(name: "detail-app-only", width: 448, value: .detail(detailAppOnly(lang: lang))),
            // Install all / Remove all, and one connection line per agent in
            // every state: installed, needs update (events, launcher),
            // failed, not installed — and the agent not on this Mac.
            Fixture(name: "settings", width: 500, value: .settings(settings(lang: lang))),
            // Open at login registered, and macOS waiting for approval.
            Fixture(name: "settings-login-approval", width: 500, value: .settings(settingsLoginApproval(lang: lang))),
        ]
    }

    // MARK: - Tray rows

    /// Tray rows are drawn against now, so their world is built around it.
    static var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    static let minute: Int64 = 60_000

    /// The agent's own name for the event that means `action` — read from
    /// its contract, never spelled here (`catalog_check`: a vendor event is
    /// spelled only in its adapter).
    static func event(_ agent: AgentID, _ action: HookAction) -> String {
        agent.spec.hooks.events.first { $0.action == action }?.name ?? ""
    }

    /// A row and what its session said lately — what the store hands a row
    /// face (`StatusStore.facts`).
    struct Sample {
        var row: AgentRow
        var facts = SessionFacts()
    }

    static func rowModel(_ sample: Sample, lang: ResolvedLanguage, appOnly: Bool = false) -> TrayRowModel {
        let notice = appOnly ? RowNotice.appOnly(row: sample.row, lang: lang) : nil
        return TrayRowModel.make(TrayRowModel.Input(row: sample.row, facts: sample.facts, lang: lang, nowMs: nowMs, notice: notice))
    }

    static func detail(_ sample: Sample, lang: ResolvedLanguage, notice: RowNotice? = nil) -> DetailModel {
        DetailModel.make(row: sample.row, facts: sample.facts, lang: lang, nowMs: nowMs, notice: notice)
    }

    static func base(_ agent: AgentID, id: String, task: String = "Fix the flaky login test") -> Sample {
        var row = AgentRow(key: SessionKey(agent, id), status: .running(stalled: false))
        row.session = id
        row.task = task
        row.cwd = "/Users/me/code/app"
        row.liveProcess = true
        row.pid = 4312
        row.landing = LandingHandle(tmuxPane: "%3", term: "tmux")
        row.landingPlan = LandingPlan(steps: [.tmuxPane(pane: "%3", socket: "", hostBundleIDs: [])])
        return Sample(row: row, facts: SessionFacts(lastEventMs: nowMs - 1 * minute))
    }

    static func rowPermission() -> Sample {
        var sample = base(.claude, id: "fx-perm")
        sample.row.status = .needsYou(Block(kind: .permission, ask: "Bash: npm run build", sinceMs: nowMs - 8 * minute, tool: "Bash"))
        sample.facts.stateEvent = event(.claude, .blocked(.permission))
        return sample
    }

    static func rowQuestionFront() -> Sample {
        var sample = base(.claude, id: "fx-question")
        sample.row.status = .needsYou(Block(
            kind: .question, ask: "Which database should the migration target?",
            sinceMs: nowMs - 30_000, inFront: true
        ))
        sample.facts.stateEvent = event(.claude, .blocked(.permission))
        return sample
    }

    static func rowTurn() -> Sample {
        var sample = base(.codex, id: "fx-turn", task: "Add an offline queue for login")
        sample.row.status = .yourTurn(sinceMs: nowMs - 3 * minute)
        sample.facts.lastWords = "All 42 tests pass; the queue drains on reconnect."
        sample.facts.stateEvent = event(.codex, .turn)
        return sample
    }

    static func rowStalled() -> Sample {
        var sample = base(.copilot, id: "fx-stalled", task: "Port the parser to Swift")
        sample.row.status = .running(stalled: true)
        sample.facts.lastEventMs = nowMs - 25 * minute
        sample.facts.activityMs = nowMs - 25 * minute
        return sample
    }

    static func rowRunning() -> Sample {
        var sample = base(.codex, id: "fx-running", task: "Add retry with jitter to the upload queue")
        sample.facts.lastEvent = event(.codex, .activity)
        return sample
    }

    /// A session in a Terminal.app tab whose tab script did not land (macOS
    /// Automation denied): a Go brings Terminal forward, not the tab.
    static func rowTerminalTab() -> Sample {
        var sample = base(.claude, id: "fx-terminal-tab", task: "Rename the settings keys")
        sample.row.landing = LandingHandle("tty:/dev/ttys004;term:Apple_Terminal")
        sample.row.landingPlan = LandingPlan.make(handle: sample.row.landing, cwd: sample.row.cwd, pid: 4312)
        return sample
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

    static func rowRunningStep() -> Sample {
        var sample = base(.claude, id: "fx-running-step", task: "Add retry with jitter to the upload queue")
        sample.facts = SessionFacts(
            steps: steps(endingAt: nowMs - 2 * minute),
            turnStartMs: nowMs - 14 * minute,
            lastEventMs: nowMs - 2 * minute,
            activityMs: nowMs - 2 * minute,
            lastEvent: event(.claude, .activity)
        )
        return sample
    }

    /// A Claude session as its hook told it, replayed through the real
    /// book: a prompt, two steps, a permission and its echo six seconds
    /// later, the answer, an event Pulse does not install, two more steps.
    static func rowTimeline() -> Sample {
        var sample = base(.claude, id: "fx-timeline", task: "Add retry with jitter to the upload queue")
        func line(_ kind: AttentionKind, _ ago: Int64, _ event: String, tool: String = "", message: String = "") -> AttentionRecord {
            AttentionRecord(
                agent: .claude, kind: kind, ms: nowMs - ago, message: message,
                session: "fx-timeline", cwd: "/Users/me/code/app", pid: 4312, tool: tool, event: event
            )
        }
        let prompt = event(.claude, .prompt)
        let tool = event(.claude, .activity)
        let asked = event(.claude, .blocked(.permission))
        // Claude's `Notification`, which its adapter reads from the payload.
        let notified = event(.claude, .ignore)
        let lines = [
            line(.working, 14 * minute, prompt, message: "Add retry with jitter to the upload queue"),
            line(.tool, 12 * minute, tool, tool: "Read", message: "Sources/Upload/Queue.swift"),
            line(.tool, 10 * minute, tool, tool: "Edit", message: "Sources/Upload/Queue.swift"),
            line(.permission, 8 * minute, asked, tool: "Bash", message: "Bash: swift test"),
            line(.permission, 8 * minute - 6_000, notified, message: "Claude needs your permission to use Bash"),
            line(.tool, 6 * minute, tool, tool: "Bash", message: "swift test"),
            // An event Pulse does not install for Claude.
            line(.ignored, 5 * minute, "PreCompact", message: PulseHookReceiver.Ignored.notInstalled.rawValue),
            line(.tool, 3 * minute, tool, tool: "Edit", message: "Sources/Upload/Backoff.swift"),
            line(.tool, 2 * minute, tool, tool: "Bash", message: "swift test"),
        ]
        var book = SessionBook()
        for record in lines { book.apply(record, nowMs: nowMs) }
        sample.facts = book.facts(for: sample.row.key)
        return sample
    }

    static func rowStalledStep() -> Sample {
        var sample = rowStalled()
        sample.facts.steps = steps(endingAt: nowMs - 25 * minute)
        sample.facts.turnStartMs = nowMs - 40 * minute
        return sample
    }

    static func rowProcessOnly() -> Sample {
        var row = AgentRow(key: .process(.cursor, pid: 4242), status: .processOnly)
        row.liveProcess = true
        row.pid = 4242
        return Sample(row: row)
    }

    // MARK: - The tray's header and notice

    static func header(lang: ResolvedLanguage) -> TrayHeaderModel {
        TrayHeaderModel.make(
            counts: TrayState.Counts(rows: [rowPermission(), rowQuestionFront(), rowRunning(), rowStalled(), rowTurn(), rowProcessOnly()].map(\.row)),
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
            installFailure: HooksSupport.Status.failureText([.cursor: .invalidJSON], lang: lang)
        )) ?? TrayNoticeModel(
            kind: .setupFailed, text: "", actionTitle: "", action: .openHooksSettings,
            systemImage: "exclamationmark.triangle", tone: .stalled
        )
    }

    // MARK: - The detail page

    static func detailPermission(lang: ResolvedLanguage) -> DetailModel {
        detail(rowPermission(), lang: lang)
    }

    static func detailTurn(lang: ResolvedLanguage) -> DetailModel {
        detail(rowTurn(), lang: lang)
    }

    static func detailTimeline(lang: ResolvedLanguage) -> DetailModel {
        detail(rowTimeline(), lang: lang)
    }

    static func detailStalled(lang: ResolvedLanguage) -> DetailModel {
        detail(rowStalledStep(), lang: lang)
    }

    static func detailAppOnly(lang: ResolvedLanguage) -> DetailModel {
        let sample = rowTerminalTab()
        return detail(sample, lang: lang, notice: RowNotice.appOnly(row: sample.row, lang: lang))
    }

    // MARK: - Settings

    /// Every connection state at once: Claude whole, heard a moment ago,
    /// with an event it did not use; Codex missing two events; Cursor's
    /// install failed; Copilot's hook runs an old copy of Pulse; OpenCode is
    /// here without its hook; Pi is not on this Mac.
    static func connections() -> [Connection] {
        let codexEvents = Set(AgentID.codex.spec.hooks.events.map(\.name)).count
        return [
            Connection(
                agent: .claude, install: .complete,
                lastHeard: Connection.Heard(event: event(.claude, .activity), ms: nowMs - 12_000),
                lastIgnored: Connection.Ignored(event: "PreCompact", reason: PulseHookReceiver.Ignored.notInstalled.rawValue, ms: nowMs - 4 * minute)
            ),
            Connection(
                agent: .codex, install: .partial(found: max(0, codexEvents - 2), of: codexEvents),
                lastHeard: Connection.Heard(event: event(.codex, .turn), ms: nowMs - 3 * minute)
            ),
            Connection(agent: .cursor, install: .failed(.invalidJSON)),
            Connection(agent: .copilot, install: .staleLauncher, lastHeard: Connection.Heard(event: event(.copilot, .activity), ms: nowMs - 2 * 60 * minute)),
            Connection(agent: .opencode, install: .notInstalled),
            Connection(agent: .pi, install: .notInstalled),
        ]
    }

    static func settings(lang: ResolvedLanguage) -> SettingsModel {
        let present: Set<AgentID> = [.claude, .codex, .cursor, .copilot, .opencode]
        return SettingsModel(
            lang: lang,
            launchAtLogin: true,
            notifications: .allowed,
            hooksStatus: HooksSupport.Status.installed([.claude, .codex, .copilot], failed: [.cursor: .invalidJSON]).label(lang: lang),
            hooksInstalled: true,
            hookAgents: SettingsModel.hookAgents(connections: connections(), present: present, nowMs: nowMs, lang: lang),
            absentAgents: SettingsModel.absentAgents(connections: connections(), present: present),
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
