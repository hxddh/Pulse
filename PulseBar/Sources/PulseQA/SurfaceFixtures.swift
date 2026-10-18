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
        "row-live-tool", "row-failed-step", "row-failed-turn", "row-stopped", "row-process-unconnected",
        "header", "notice-setup", "notice-setup-done", "notice-setup-failed", "row-app-only",
        "detail-blocked", "detail-your-turn", "detail-timeline", "detail-stalled", "detail-app-only",
        "detail-subagent", "detail-failed-turn",
        "settings", "settings-caveats", "settings-login-approval",
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
            // The tool the agent said started and has not finished: "Now:
            // Bash · npm test · 3m" — never a finished step's words.
            Fixture(name: "row-live-tool", width: 448, value: .row(rowModel(rowLiveTool(), lang: lang))),
            // A last step that failed, taken by a subagent.
            Fixture(name: "row-failed-step", width: 448, value: .row(rowModel(rowFailedStep(), lang: lang))),
            // A turn that ended on an error: "Turn failed · 2m ago", and its
            // first line, quietly — the lamp stays grey.
            Fixture(name: "row-failed-turn", width: 448, value: .row(rowModel(rowFailedTurn(), lang: lang))),
            // The person stopped the run at the agent's prompt.
            Fixture(name: "row-stopped", width: 448, value: .row(rowModel(rowStopped(), lang: lang))),
            // A process of an agent Pulse is not connected to.
            Fixture(name: "row-process-unconnected", width: 448, value: .row(rowModel(rowProcessOnly(), lang: lang, connected: false))),
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
            // A subagent's start, its steps (grouped, marked as its own)
            // and its finish, beside the main agent's.
            Fixture(name: "detail-subagent", width: 448, value: .detail(detailSubagent(lang: lang))),
            // A Codex turn that failed: the why, the error, and that Codex
            // does not report waits.
            Fixture(name: "detail-failed-turn", width: 448, value: .detail(detail(rowFailedTurn(), lang: lang))),
            // Install all / Remove all, and one connection line per agent in
            // every state: installed, needs update (events, launcher),
            // failed, not installed — and the agent not on this Mac.
            Fixture(name: "settings", width: 500, value: .settings(settings(lang: lang))),
            // Whole installs that may not run: turned off,
            // nothing heard yet, a config folder that is missing — and
            // that Codex and Cursor do not report waits.
            Fixture(name: "settings-caveats", width: 500, value: .settings(settingsCaveats(lang: lang))),
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

    /// The last of the agent's events that means `action` — Claude lists
    /// its subagent's own start and stop after the main agent's.
    static func lastEvent(_ agent: AgentID, _ action: HookAction) -> String {
        agent.spec.hooks.events.last { $0.action == action }?.name ?? ""
    }

    /// A row and what its session said lately — what the store hands a row
    /// face (`StatusStore.facts`).
    struct Sample {
        var row: AgentRow
        var facts = SessionFacts()
    }

    static func rowModel(_ sample: Sample, lang: ResolvedLanguage, appOnly: Bool = false, connected: Bool = true) -> TrayRowModel {
        let notice = appOnly ? RowNotice.appOnly(row: sample.row, lang: lang) : nil
        return TrayRowModel.make(TrayRowModel.Input(
            row: sample.row, facts: sample.facts, lang: lang, nowMs: nowMs, notice: notice, connected: connected
        ))
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
        var sample = base(.opencode, id: "fx-stalled", task: "Port the parser to Swift")
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

    /// The last step, as a hook reports it: the tool, its target, when.
    static func step(at ms: Int64) -> SessionBook.Step {
        SessionBook.Step(tool: "Bash", target: "swift test", ms: ms)
    }

    static func rowRunningStep() -> Sample {
        var sample = base(.claude, id: "fx-running-step", task: "Add retry with jitter to the upload queue")
        sample.facts = SessionFacts(
            lastStep: step(at: nowMs - 2 * minute),
            turnStartMs: nowMs - 14 * minute,
            lastEventMs: nowMs - 2 * minute,
            activityMs: nowMs - 2 * minute,
            lastEvent: event(.claude, .activity)
        )
        return sample
    }

    /// A Claude session as its hook told it, replayed through the real
    /// book: a prompt, a run of steps (one entry), a permission and its
    /// echo six seconds later, the answer, an event Pulse does not install,
    /// a run with a failed step, and a last step with its duration.
    static func rowTimeline() -> Sample {
        var sample = base(.claude, id: "fx-timeline", task: "Add retry with jitter to the upload queue")
        func line(
            _ kind: AttentionKind, _ ago: Int64, _ event: String, tool: String = "", message: String = "",
            failed: Bool = false, tookMs: Int64 = 0
        ) -> AttentionRecord {
            AttentionRecord(
                agent: .claude, kind: kind, ms: nowMs - ago, message: message,
                session: "fx-timeline", cwd: "/Users/me/code/app", pid: 4312, tool: tool, event: event,
                failed: failed, tookMs: tookMs
            )
        }
        let prompt = event(.claude, .prompt)
        let tool = event(.claude, .activity)
        let asked = event(.claude, .blocked(.permission))
        // Claude's `Notification`, which its adapter reads from the payload.
        let notified = event(.claude, .ignore)
        let lines = [
            line(.working, 14 * minute, prompt, message: "Add retry with jitter to the upload queue"),
            line(.tool, 13 * minute, tool, tool: "Read", message: "Sources/Upload/Queue.swift"),
            line(.tool, 12 * minute, tool, tool: "Edit", message: "Sources/Upload/Queue.swift"),
            line(.tool, 11 * minute, tool, tool: "Edit", message: "Sources/Upload/Queue.swift"),
            line(.tool, 10 * minute, tool, tool: "Edit", message: "Sources/Upload/Queue.swift"),
            line(.permission, 8 * minute, asked, tool: "Bash", message: "Bash: swift test"),
            line(.permission, 8 * minute - 6_000, notified, message: "Claude needs your permission to use Bash"),
            line(.tool, 6 * minute, tool, tool: "Bash", message: "swift test", tookMs: 41_000),
            line(.tool, 4 * minute, tool, tool: "Edit", message: "Sources/Upload/Backoff.swift"),
            line(.tool, 3 * minute, tool, tool: "Bash", message: "swift test", failed: true, tookMs: 2_300),
            // An event Pulse does not install for Claude.
            line(.ignored, 2 * minute + 30_000, "PreCompact", message: PulseHookReceiver.Ignored.notInstalled.rawValue),
            line(.tool, 2 * minute, tool, tool: "Bash", message: "swift test", tookMs: 2_300),
        ]
        var book = SessionBook()
        for record in lines { book.apply(record, nowMs: nowMs) }
        sample.facts = book.facts(for: sample.row.key)
        return sample
    }

    static func rowStalledStep() -> Sample {
        var sample = rowStalled()
        sample.facts.lastStep = step(at: nowMs - 25 * minute)
        sample.facts.turnStartMs = nowMs - 40 * minute
        return sample
    }

    /// A Pi session whose agent said `npm test` started three minutes ago
    /// and has not said it finished.
    static func rowLiveTool() -> Sample {
        var sample = base(.pi, id: "fx-live", task: "Make the test suite pass on CI")
        sample.facts = SessionFacts(
            lastStep: step(at: nowMs - 4 * minute),
            runningSteps: [SessionBook.Step(tool: "bash", target: "npm test", ms: nowMs - 3 * minute)],
            turnStartMs: nowMs - 9 * minute,
            lastEventMs: nowMs - 3 * minute,
            activityMs: nowMs - 3 * minute,
            turnSteps: 6
        )
        return sample
    }

    /// A running Claude session whose last step — a subagent's — failed.
    static func rowFailedStep() -> Sample {
        var sample = base(.claude, id: "fx-failed-step", task: "Audit the auth flows")
        let last = SessionBook.Step(tool: "Bash", target: "swift test", ms: nowMs - minute, failed: true, tookMs: 2_300, sub: "a1")
        sample.facts = SessionFacts(
            lastStep: last,
            turnStartMs: nowMs - 11 * minute,
            lastEventMs: nowMs - minute,
            activityMs: nowMs - minute,
            turnSteps: 9,
            turnFailedSteps: 1
        )
        return sample
    }

    /// A Codex turn that ended on an error, two minutes ago.
    static func rowFailedTurn() -> Sample {
        var sample = base(.codex, id: "fx-failed-turn", task: "Upgrade the date library")
        sample.row.status = .yourTurn(sinceMs: nowMs - 2 * minute)
        sample.facts = SessionFacts(
            lastError: "stream disconnected before completion: rate limit reached",
            lastEventMs: nowMs - 2 * minute,
            stateEvent: event(.codex, .turn),
            failedTurn: true
        )
        return sample
    }

    /// A Pi session the person stopped at its prompt a minute ago.
    static func rowStopped() -> Sample {
        var sample = base(.pi, id: "fx-stopped", task: "Rename the queue types")
        sample.row.status = .recent(.atPrompt)
        sample.facts = SessionFacts(lastEventMs: nowMs - minute, stateEvent: event(.pi, .turn), stopped: true)
        return sample
    }

    /// A Claude session where a subagent explored while the main agent
    /// read: its start, its steps (one entry, marked as its own), its
    /// finish — replayed through the real book.
    static func rowSubagent() -> Sample {
        var sample = base(.claude, id: "fx-subagent", task: "Map the upload API")
        func line(_ kind: AttentionKind, _ ago: Int64, _ event: String, tool: String = "", message: String = "", sub: String = "") -> AttentionRecord {
            AttentionRecord(
                agent: .claude, kind: kind, ms: nowMs - ago, message: message,
                session: "fx-subagent", cwd: "/Users/me/code/app", pid: 4312, tool: tool, event: event, sub: sub
            )
        }
        let prompt = event(.claude, .prompt)
        let tool = event(.claude, .activity)
        let start = lastEvent(.claude, .start)
        let turn = lastEvent(.claude, .turn)
        let lines = [
            line(.working, 9 * minute, prompt, message: "Map the upload API"),
            line(.start, 8 * minute, start, sub: "a1"),
            line(.tool, 7 * minute, tool, tool: "Grep", message: "upload", sub: "a1"),
            line(.tool, 7 * minute - 20_000, tool, tool: "Read", message: "Sources/Upload/API.swift", sub: "a1"),
            line(.tool, 6 * minute, tool, tool: "Read", message: "Sources/Upload/Client.swift", sub: "a1"),
            line(.turn, 5 * minute, turn, message: "Found 12 endpoints", sub: "a1"),
            line(.tool, 4 * minute, tool, tool: "Read", message: "Sources/Upload/Queue.swift"),
            line(.tool, 3 * minute, tool, tool: "Edit", message: "docs/upload.md"),
        ]
        var book = SessionBook()
        for record in lines { book.apply(record, nowMs: nowMs) }
        sample.facts = book.facts(for: sample.row.key)
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

    static func detailSubagent(lang: ResolvedLanguage) -> DetailModel {
        detail(rowSubagent(), lang: lang)
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

    /// Whole installs that may not run: Claude's hooks turned off in its settings, Copilot nothing heard
    /// yet, Pi's config folder missing; Codex and Cursor whole and heard,
    /// and saying they do not report waits.
    static func settingsCaveats(lang: ResolvedLanguage) -> SettingsModel {
        let present: Set<AgentID> = [.claude, .codex, .cursor, .copilot, .pi]
        let caveats = [
            Connection(agent: .claude, install: .complete, lastHeard: Connection.Heard(event: event(.claude, .turn), ms: nowMs - 26 * 60 * minute), caveat: .turnedOff),
            Connection(agent: .codex, install: .complete, lastHeard: Connection.Heard(event: event(.codex, .turn), ms: nowMs - 12 * minute)),
            Connection(
                agent: .cursor, install: .complete,
                lastHeard: Connection.Heard(event: event(.cursor, .turn), ms: nowMs - 5 * minute),
                lastIgnored: Connection.Ignored(event: event(.cursor, .turn), reason: PulseHookReceiver.Ignored.unparsable.rawValue, ms: nowMs - 40 * minute)
            ),
            Connection(agent: .copilot, install: .complete, caveat: .neverHeard),
            Connection(agent: .opencode, install: .notInstalled),
            Connection(agent: .pi, install: .notInstalled, configDirMissing: true),
        ]
        var model = settings(lang: lang)
        model.hooksStatus = HooksSupport.Status.installed([.claude, .codex, .cursor, .copilot]).label(lang: lang)
        model.hookAgents = SettingsModel.hookAgents(connections: caveats, present: present, nowMs: nowMs, lang: lang)
        model.absentAgents = SettingsModel.absentAgents(connections: caveats, present: present)
        return model
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
