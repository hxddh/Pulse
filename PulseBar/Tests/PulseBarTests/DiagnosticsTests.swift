import Foundation
import Testing
import XCTest
@testable import PulseApp
@testable import PulseQA
@testable import PulseKit

// Diagnostics: Settings → Hooks (one line per agent, "Copy report"), the
// tray's one notice, the version.

/// The report "Copy report" puts on the clipboard: plain text, the facts a
/// person would be asked for, and nothing that names them, a project or a
/// session.
@Suite("Report")
struct ReportTests {
    let now: Int64 = 1_800_000_000_000

    func connections() -> [Connection] {
        [
            Connection(agent: .claude, install: .complete, lastHeard: Connection.Heard(event: "Stop", ms: now - 42_000)),
            Connection(agent: .codex, install: .notInstalled),
            Connection(agent: .cursor, install: .partial(found: 3, of: 5), lastHeard: Connection.Heard(event: "stop", ms: now - 9_000)),
            Connection(agent: .copilot, install: .failed(.unwritable)),
            Connection(agent: .opencode, install: .complete),
            Connection(agent: .pi, install: .notInstalled),
        ]
    }

    func input() -> SettingsModel.ReportInput {
        SettingsModel.ReportInput(
            version: "Pulse 25.0.0 · preview",
            macOS: "26.0.0",
            connections: connections(),
            present: [.claude, .codex, .cursor, .opencode],
            nowMs: now,
            notifyAuthorized: false,
            launchAtLogin: true,
            loginItem: .off
        )
    }

    @Test func theReportSaysEachAgentsConnection() {
        let text = SettingsModel.report(input())
        #expect(text.hasPrefix("Pulse report"))
        #expect(text.contains("Pulse 25.0.0 · preview"))
        #expect(text.contains("  claude: installed, heard Stop 42s ago, capabilities: waits steps words titles"), "\(text)")
        #expect(text.contains("  opencode: installed, nothing heard yet, capabilities: waits steps titles"), "\(text)")
        #expect(text.contains("  codex: not installed, capabilities: steps words titles"), "\(text)")
        #expect(text.contains("  cursor: needs update (3 of 5 events), heard stop 9s ago, capabilities: steps words"), "\(text)")
        #expect(text.contains("  copilot: install failed (unwritable)\n"), "\(text)")
        #expect(text.contains("  pi: not on this Mac\n"), "\(text)")
        for agent in AgentID.allCases {
            #expect(text.contains("  \(agent.rawValue): "), "\(agent.rawValue)")
        }
    }

    @Test func aStaleLauncherIsSaid() {
        var stale = input()
        stale.connections = [Connection(agent: .claude, install: .staleLauncher)]
        let text = SettingsModel.report(stale)
        #expect(text.contains("  claude: needs update (stale launcher), nothing heard yet, capabilities: waits steps words titles"), "\(text)")
        #expect(text.contains("  pi: not on this Mac"), "an agent with no connection given is not installed: \(text)")
    }

    @Test func theReportSaysNotificationsAndTheLoginItem() {
        let text = SettingsModel.report(input())
        #expect(text.contains("notifications: denied\n"), "\(text)")
        #expect(text.contains("open at login: on, macOS: not registered"),
                "a toggle whose result is never checked is how this project keeps shipping bugs")
        #expect(!text.contains("shortcut"), "\(text)")
        #expect(!text.contains("automation"), "\(text)")
        var unasked = input()
        unasked.notifyAuthorized = nil
        unasked.loginItem = nil
        let other = SettingsModel.report(unasked)
        #expect(other.contains("notifications: not asked"))
        #expect(other.contains("macOS: not read"))
        var pending = input()
        pending.loginItem = .requiresApproval
        let waiting = SettingsModel.report(pending)
        #expect(waiting.contains("open at login: on, macOS: requires approval"), "\(waiting)")
    }

    /// A session as the book heard it: a prompt with a private text, a step
    /// whose target is a private path, a raise whose ask names a secret,
    /// an ignored line, all under a secret session id in a secret folder.
    func secretFacts() -> (AgentRow, SessionFacts) {
        let key = SessionKey(.claude, "secret-session")
        func line(_ kind: AttentionKind, _ ms: Int64, _ event: String, tool: String = "", message: String = "", failed: Bool = false) -> AttentionRecord {
            AttentionRecord(
                agent: .claude, kind: kind, ms: ms, message: message,
                session: "secret-session", cwd: "/Users/me/secret-project", tool: tool, event: event,
                failed: failed
            )
        }
        var book = SessionBook()
        for record in [
            line(.working, now - 60_000, "UserPromptSubmit", message: "a private prompt"),
            line(.tool, now - 50_000, "PostToolUse", tool: "Read", message: "/Users/me/secret-project/private.swift"),
            line(.tool, now - 45_000, "PostToolUseFailure", tool: "Edit", message: "/Users/me/secret-project/token.swift", failed: true),
            line(.permission, now - 40_000, "PermissionRequest", tool: "Bash", message: "Bash: cat /Users/me/secret-token"),
            line(.ignored, now - 30_000, "/Users/me/secret", message: "a private reason"),
            line(.tool, now - 20_000, "PostToolUse", tool: "Bash", message: "cat /Users/me/secret-token"),
        ] {
            book.apply(record, nowMs: now)
        }
        var row = AgentRow(key: key, status: .running(stalled: false))
        row.session = "secret-session"
        row.cwd = "/Users/me/secret-project"
        row.task = "a private prompt"
        return (row, book.facts(for: key))
    }

    /// The input has no field for a path, a prompt, a session or a
    /// project; the text says only states, event names, counts and ages —
    /// a step by its tool alone, an ignored line by a reason the receiver
    /// writes.
    @Test func theReportCarriesNoPathSessionOrProject() {
        let (row, facts) = secretFacts()
        var withSession = input()
        withSession.sessions = [SettingsModel.ReportSession(row, facts: facts)]
        withSession.connections = [Connection(
            agent: .claude, install: .complete,
            lastHeard: Connection.Heard(event: "/Users/me/secret", ms: now - 1_000),
            lastIgnored: Connection.Ignored(event: "/Users/me/secret", reason: "a private reason", ms: now - 1_000)
        )]
        let text = SettingsModel.report(withSession)
        #expect(text.contains("steps 3 (1 failed)"), "counts, never targets: \(text)")
        #expect(text.contains("capabilities: waits steps words titles"), "\(text)")
        #expect(!text.contains("/"), "not even a folder: \(text)")
        #expect(!text.contains(".swift"), "no file name from a step's target: \(text)")
        #expect(!text.contains("cat "), "no command from a step's target: \(text)")
        #expect(!text.contains("secret"), "\(text)")
        #expect(!text.contains("private"), "\(text)")
        #expect(!text.contains("token"), "\(text)")
    }

    /// Each session's last three heard lines, newest first.
    @Test func theReportCarriesEachSessionsLastThreeLines() {
        let (row, facts) = secretFacts()
        var chosen = input()
        chosen.sessions = [SettingsModel.ReportSession(row, facts: facts)]
        let text = SettingsModel.report(chosen)
        let expected = [
            "    20s ago · PostToolUse · answered",
            "    30s ago · ? · not used (other)",
            "    40s ago · PermissionRequest · raised permission",
        ].joined(separator: "\n")
        #expect(text.contains(expected), "\(text)")
        #expect(!text.contains("UserPromptSubmit"), "three lines, no more: \(text)")
    }

    /// How Pulse reads each listed session — once on the detail page — is
    /// in the report: its state, where its facts come from, how a click
    /// lands, whether its process is watched and when it last spoke.
    @Test func theReportSaysHowPulseReadsEachSession() {
        var hooked = AgentRow(key: SessionKey(.claude, "s1"), status: .running(stalled: false))
        hooked.liveProcess = true
        hooked.pid = 42
        hooked.landingPlan = LandingPlan(steps: [.ttyTab(tty: "ttys003")])
        var process = AgentRow(key: .process(.cursor, pid: 9), status: .processOnly)
        process.liveProcess = true
        var chosen = input()
        chosen.sessions = [
            SettingsModel.ReportSession(hooked, facts: SessionFacts(lastEventMs: now - 7_000)),
            SettingsModel.ReportSession(process),
        ]
        let text = SettingsModel.report(chosen)
        #expect(text.contains("\nsessions:\n"), "\(text)")
        #expect(text.contains("  claude: running, from hooks, go exact, process watched, last event 7s ago"), "\(text)")
        #expect(text.contains("  cursor: process only, from process only, go none, process watched, no event"), "\(text)")
        #expect(SettingsModel.report(input()).hasSuffix("sessions: none listed"))
    }

    /// The report names each agent's last ignored event and why — never a
    /// path, even when the event argument was one.
    @Test func theReportSaysWhatWasIgnored() {
        var heard = input()
        heard.connections = [
            Connection(
                agent: .claude, install: .complete,
                lastIgnored: Connection.Ignored(event: "PreCompact", reason: PulseHookReceiver.Ignored.notInstalled.rawValue, ms: now - 3_000)
            ),
            Connection(
                agent: .cursor, install: .complete,
                lastIgnored: Connection.Ignored(event: "/Users/me/secret", reason: PulseHookReceiver.Ignored.unparsable.rawValue, ms: now - 5_000)
            ),
        ]
        let text = SettingsModel.report(heard)
        #expect(text.contains("last not used PreCompact (not an installed event) 3s ago"), "\(text)")
        #expect(text.contains("last not used ? (payload is not a JSON object) 5s ago"), "\(text)")
        #expect(!text.contains("secret"), "\(text)")
    }

    /// The store's report reads the engine's last events, never the file.
    @MainActor
    @Test func theStoresReportReadsTheEngine() {
        let store = StatusStore()
        let fired: Int64 = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        let turn = AttentionRecord(agent: .claude, kind: .turn, ms: fired, session: "s1", event: "Stop", seq: 1)
        store.engine.landLog(EventLog.Chunk(header: AttentionProtocol.Header(next: 2, gen: "g"), records: [turn], end: 200))
        #expect(store.engine.latestHeard[.claude] == Connection.Heard(event: "Stop", ms: fired))
        let claude = store.connections.first { $0.agent == .claude }
        #expect(claude?.lastHeard?.event == "Stop")
        let report = store.reportText
        #expect(report.contains("  claude: "))
        #expect(report.contains("heard Stop "), "\(report)")
        #expect(report.contains("open at login: "))
    }
}

/// One agent's connection: what its config carries, said as a state.
@Suite("Connection")
struct ConnectionTests {
    let now: Int64 = 1_800_000_000_000
    let launcher = "/Users/me/Library/Application Support/Pulse/pulse-hook"
    let contract: Set<String> = ["SessionStart", "Stop", "PermissionRequest"]

    func classify(
        _ installed: Set<String>?, launchers: Set<String>? = nil, launcherRuns: Bool = true, runnerRuns: Bool = true
    ) -> Connection.Install {
        Connection.Install.classify(
            contract: contract, installed: installed, launchers: launchers ?? [launcher],
            expected: launcher, launcherRuns: launcherRuns, runnerRuns: runnerRuns
        )
    }

    @Test func everyEventThroughThisLauncherIsComplete() {
        #expect(classify(contract) == .complete)
    }

    @Test func noEventIsNotInstalled() {
        #expect(classify([]) == .notInstalled)
        #expect(classify(nil) == .notInstalled, "a file that is not its format carries no hook")
    }

    /// Any non-empty set used to read as installed. Missing events — or one
    /// the contract no longer has — need Install all.
    @Test func someEventsArePartial() {
        #expect(classify(["Stop"]) == .partial(found: 1, of: 3))
        #expect(classify(contract.union(["SubagentStop"])) == .partial(found: 3, of: 3))
        #expect(Connection.Install.partial(found: 1, of: 3).needsUpdate)
        #expect(Connection.Install.partial(found: 1, of: 3).carriesHook)
    }

    /// A hook that runs another launcher, or a launcher (or the app it
    /// starts) that cannot run, is stale — whatever its events.
    @Test func anotherOrAMissingLauncherIsStale() {
        #expect(classify(contract, launchers: ["/Users/old/Library/Application Support/Pulse/pulse-hook"]) == .staleLauncher)
        #expect(classify(contract, launchers: [launcher, "/opt/pulse-hook"]) == .staleLauncher)
        #expect(classify(["Stop"], launcherRuns: false) == .staleLauncher)
        #expect(classify(contract, runnerRuns: false) == .staleLauncher)
        #expect(classify([], launcherRuns: false) == .notInstalled, "no hook, nothing stale")
        #expect(Connection.Install.staleLauncher.needsUpdate)
    }

    /// The paths a config names, as JSON writes them (quoted, escaped
    /// slashes) and as a module does.
    @Test func theLauncherPathsAreReadFromTheText() {
        let nested = #"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": ""/Users/me/Library/Application Support/Pulse/pulse-hook" claude Stop"}]}]}}"#
        #expect(HooksInstaller.launcherPaths(in: nested) == [launcher])
        let escaped = #"{"command": "\/opt\/pulse\/pulse-hook codex Stop"}"#
        #expect(HooksInstaller.launcherPaths(in: escaped) == ["/opt/pulse/pulse-hook"])
        let module = "// Pulse — Pi extension (pulse-hook). Installed by Pulse\n// pulse-hook, detached.\nconst PULSE_HOOK = \"\(launcher)\"\n"
        #expect(HooksInstaller.launcherPaths(in: module) == [launcher])
        #expect(HooksInstaller.launcherPaths(in: #"{"command": "~/bin/impulse-hook.sh"}"#).isEmpty)
    }

    /// The last install's failure wins over what the config says; before
    /// anything was read, there is no install.
    @Test func aFailureWins() {
        let failed = Connection.make(agent: .cursor, probed: .complete, failure: .invalidJSON, heard: nil, ignored: nil)
        #expect(failed.install == .failed(.invalidJSON))
        let unread = Connection.make(agent: .cursor, probed: nil, failure: nil, heard: nil, ignored: nil)
        #expect(unread.install == .notInstalled)
    }

    /// The words, in both languages: the state, what was heard and when,
    /// the last event not used and why, whether it reports a wait.
    @Test func theLineSaysTheConnection() {
        let claude = Connection(
            agent: .claude, install: .complete,
            lastHeard: Connection.Heard(event: "PermissionRequest", ms: now - 4 * 60_000),
            lastIgnored: Connection.Ignored(event: "PreCompact", reason: PulseHookReceiver.Ignored.notInstalled.rawValue, ms: now - 2 * 60_000)
        )
        let line = SettingsModel.HookAgent(claude, nowMs: now, lang: .en)
        #expect(line.state == "Installed")
        #expect(line.tone == .ok)
        #expect(line.capability == "Reports waits, steps, last words, titles")
        #expect(line.detail == "Heard PermissionRequest · 4m ago")
        #expect(line.notUsed == "Last not used PreCompact — not an installed event · 2m ago")
        let zh = SettingsModel.HookAgent(claude, nowMs: now, lang: .zh)
        #expect(zh.capability == "报告等待、步骤、最后一句话和标题")
        #expect(zh.detail == "最近听到 PermissionRequest · " + L10n.ago(now - 4 * 60_000, nowMs: now, .zh))
        #expect(zh.notUsed == "最近未采用 PreCompact——不是已安装的事件 · " + L10n.ago(now - 2 * 60_000, nowMs: now, .zh))

        let codex = SettingsModel.HookAgent(Connection(agent: .codex, install: .partial(found: 9, of: 11)), nowMs: now, lang: .en)
        #expect(codex.state == "Needs update — 9 of 11 events")
        #expect(codex.tone == .warning)
        #expect(codex.detail == "Nothing heard yet")
        #expect(codex.capability == "Reports turns, steps, last words, titles — not waits")
        #expect(SettingsModel.HookAgent(Connection(agent: .codex, install: .partial(found: 9, of: 11)), nowMs: now, lang: .zh).state == "需要更新——9 / 11 个事件")

        let stale = SettingsModel.HookAgent(Connection(agent: .pi, install: .staleLauncher), nowMs: now, lang: .en)
        #expect(stale.state == L10n.t(.settingsHookStale, .en))
        #expect(stale.tone == .warning)

        let missing = SettingsModel.HookAgent(Connection(agent: .opencode, install: .notInstalled), nowMs: now, lang: .en)
        #expect(missing.state == L10n.t(.hooksMissing, .en))
        #expect(missing.tone == .quiet)
        #expect(missing.detail == "", "nothing to hear without a hook")
        #expect(missing.capability == "Reports waits, steps, titles", "what it reports, whatever the install")
        #expect(missing.notUsed == nil)
    }

    /// A reason the receiver never writes is not repeated: its words could
    /// be anything.
    @Test func anUnknownReasonIsNotRepeated() {
        #expect(Connection.reasonText("a private reason", lang: .en) == L10n.t(.ignoredOther, .en))
        #expect(Connection.reportReason("a private reason") == "other")
        for reason in [PulseHookReceiver.Ignored.noEvent, .notInstalled, .unparsable, .cannotWait, .noSession, .silent] {
            #expect(Connection.reasonText(reason.rawValue, lang: .zh) != L10n.t(.ignoredOther, .zh), "\(reason)")
            #expect(Connection.reportReason(reason.rawValue) == reason.rawValue)
        }
    }

    /// An install read from disk: a contract installed through this Pulse's
    /// launcher is whole; one event removed by hand makes it partial.
    @Test func anAgentsInstallIsReadFromItsConfig() throws {
        let contract = AgentID.claude.spec.hooks
        guard case .nested(let flavor) = contract.format else {
            Issue.record("Claude's hooks are nested")
            return
        }
        let events = Set(contract.events.map(\.name))
        let full = try HooksInstaller.renderNested(.claude, contract, flavor: flavor, existing: nil)
        let installed = HooksInstaller.installedEvents(.claude, text: full)
        #expect(installed == events)
        // The one launcher the render named — this test reads no global path.
        let paths = HooksInstaller.launcherPaths(in: full)
        #expect(paths.count == 1)
        let expected = try #require(paths.first)
        let classified = Connection.Install.classify(
            contract: events, installed: installed, launchers: paths,
            expected: expected, launcherRuns: true, runnerRuns: true
        )
        #expect(classified == .complete)
        let first = try #require(contract.events.first?.name)
        let fewer = Connection.Install.classify(
            contract: events, installed: events.subtracting([first]), launchers: paths,
            expected: expected, launcherRuns: true, runnerRuns: true
        )
        #expect(fewer == .partial(found: events.count - 1, of: events.count))
    }

    /// The Settings capture shows every connection state at once.
    @Test func theSettingsFixtureShowsEveryState() {
        let model = SurfaceFixtures.settings(lang: .en)
        let installs = model.hookAgents.map { $0.connection.install }
        let partial = installs.contains { install in
            if case .partial = install { return true }
            return false
        }
        let ignored = model.hookAgents.contains { $0.notUsed != nil }
        #expect(installs.contains(.complete))
        #expect(partial)
        #expect(installs.contains(.staleLauncher))
        #expect(installs.contains(.failed(.invalidJSON)))
        #expect(installs.contains(.notInstalled))
        #expect(model.absentAgents == [.pi])
        #expect(model.hooksNeedUpdate)
        #expect(ignored)
    }

    /// The caveats capture: every line says what its agent reports, then
    /// its state — turned off, nothing heard yet, a missing config folder —
    /// in calm tones: only a silenced install is a warning.
    @Test func theCaveatsFixtureSaysEachCaveatUnderItsCapability() {
        let model = SurfaceFixtures.settingsCaveats(lang: .en)
        let said = model.hookAgents.allSatisfy { $0.capability.hasPrefix("Reports ") }
        #expect(said)
        let tones = Dictionary(uniqueKeysWithValues: model.hookAgents.map { ($0.agent, $0.tone) })
        #expect(tones[.claude] == .warning)
        #expect(tones[.codex] == .ok)
        #expect(tones[.copilot] == .ok, "nothing heard yet is not a fault")
        #expect(tones[.cursor] == .ok)
        let pi = model.hookAgents.first { $0.agent == .pi }
        #expect(pi?.detail.contains("PI_CODING_AGENT_DIR") == true)
        let cursor = model.hookAgents.first { $0.agent == .cursor }
        #expect(cursor?.notUsed?.hasPrefix("Last not used ") == true)
        #expect(cursor?.capability == "Reports turns, steps, last words — not waits")
    }

    /// A module carries the events its list names.
    @Test func aModulesEventsAreItsList() throws {
        for agent in AgentID.allCases {
            guard case .module(let render) = agent.spec.hooks.format else { continue }
            let names = agent.spec.hooks.events.map(\.name)
            let text = render(launcher, names)
            #expect(HooksInstaller.installedEvents(agent, text: text) == Set(names), "\(agent.rawValue)")
            #expect(HooksInstaller.launcherPaths(in: text) == [launcher], "\(agent.rawValue)")
            let fewer = render(launcher, Array(names.dropLast()))
            #expect(HooksInstaller.installedEvents(agent, text: fewer)?.count == names.count - 1, "\(agent.rawValue)")
        }
    }

    /// Pi on this Mac without `~/.pi/agent` may read another folder
    /// (`PI_CODING_AGENT_DIR`), which a GUI app cannot see: Settings says
    /// where Pulse installs, and Pi gets its line even with no vendor
    /// folder. Only an agent whose folder can move says it.
    @Test func aMissingMovableConfigFolderIsSaid() throws {
        let now: Int64 = 1_800_000_000_000
        #expect(Connection.configDirMissing(agent: .pi, present: true, exists: { _ in false }))
        #expect(!Connection.configDirMissing(agent: .pi, present: true, exists: { $0 == ".pi/agent" }))
        #expect(!Connection.configDirMissing(agent: .pi, present: false, exists: { _ in false }), "not on this Mac: nothing to say")
        #expect(!Connection.configDirMissing(agent: .claude, present: true, exists: { _ in false }), "Claude's folder does not move")
        let pi = Connection.make(agent: .pi, probed: .notInstalled, failure: nil, heard: nil, ignored: nil, configDirMissing: true)
        #expect(pi.configDirMissing)
        let claude = Connection.make(agent: .claude, probed: .notInstalled, failure: nil, heard: nil, ignored: nil, configDirMissing: true)
        #expect(!claude.configDirMissing, "an agent without a movable folder never carries it")
        let line = SettingsModel.HookAgent(pi, nowMs: now, lang: .en)
        #expect(line.detail.contains("Pulse installs to ~/.pi/agent, which isn't there yet — a Pi set to another folder (PI_CODING_AGENT_DIR) won't load it"))
        let zh = SettingsModel.HookAgent(pi, nowMs: now, lang: .zh)
        #expect(zh.detail.contains("PI_CODING_AGENT_DIR"))
        let lines = SettingsModel.hookAgents(connections: [pi], present: [], nowMs: now, lang: .en)
        let agents = lines.map(\.agent)
        #expect(agents == [.pi], "said even with no ~/.pi")
        #expect(SettingsModel.absentAgents(connections: [pi], present: []).contains(.pi) == false)
        #expect(pi.reportLine(present: true, nowMs: now).contains("installs to ~/.pi/agent, not there"))
        #expect(Connection(agent: .pi, install: .complete).configDirText(lang: .en) == nil)
    }

    /// A vendor setting that silences every hook is read, never written:
    /// a managed policy first, then the person's own `disableAllHooks`. A
    /// key that is not JSON `true`, or a file that is not a JSON object,
    /// says nothing.
    @Test func aSettingThatSilencesHooksIsRead() {
        let switches = AgentID.claude.spec.hooks.offSwitches
        let managedFolder = Claude.managedSettingsFolder
        func off(_ files: [String: String]) -> Connection.Caveat? {
            Connection.offBy(
                switches,
                read: { files[$0] },
                list: { folder in files.keys.filter { $0.hasPrefix(folder + "/") }.map { String($0.dropFirst(folder.count + 1)) } }
            )
        }
        #expect(off([:]) == nil)
        #expect(off([".claude/settings.json": #"{"disableAllHooks": true}"#]) == .turnedOff)
        #expect(off([".claude/settings.json": #"{"disableAllHooks": false}"#]) == nil)
        #expect(off([".claude/settings.json": #"{"disableAllHooks": "true"}"#]) == nil, "only JSON true")
        #expect(off([".claude/settings.json": "// not JSON"]) == nil)
        #expect(off([Claude.managedSettings: #"{"allowManagedHooksOnly": true}"#]) == .managedOnly)
        #expect(off([managedFolder + "/10-hooks.json": #"{"allowManagedHooksOnly": true}"#]) == .managedOnly)
        #expect(off([managedFolder + "/10-hooks.txt": #"{"allowManagedHooksOnly": true}"#]) == nil, "only *.json drop-ins")
        #expect(off([
            ".claude/settings.json": #"{"disableAllHooks": true}"#,
            Claude.managedSettings: #"{"disableAllHooks": true}"#,
        ]) == .managedOnly, "the policy is the more specific reason")
        #expect(AgentID.codex.spec.hooks.offSwitches.isEmpty, "config.toml is never read")
    }

    /// A setting that silences hooks is said whatever was heard; nothing
    /// else is guessed — Codex's trust (`/hooks`) is the install report's
    /// note, never a caveat: a Codex that ran since its file changed and
    /// said nothing is "nothing heard yet", or nothing at all once heard.
    @Test func onlyASilencingSettingOrSilenceIsACaveat() {
        let changed: Int64 = 1_800_000_000_000
        let config = Connection.Config(changedMs: changed)
        #expect(Connection.caveat(agent: .codex, install: .complete, config: config, heardMs: nil, logWhole: true) == .neverHeard)
        #expect(Connection.caveat(agent: .codex, install: .complete, config: config, heardMs: changed - 60_000, logWhole: true) == nil, "heard before; its own file is the person's too")
        #expect(Connection.caveat(agent: .codex, install: .partial(found: 5, of: 7), config: config, heardMs: nil, logWhole: true) == nil, "Install all says that")
        let silenced = Connection.caveat(
            agent: .claude, install: .complete, config: Connection.Config(offBy: .turnedOff), heardMs: nil, logWhole: false
        )
        #expect(silenced == .turnedOff, "a setting is read from the config, not the log")
        #expect(Connection.caveat(agent: .claude, install: .notInstalled, config: Connection.Config(offBy: .turnedOff), heardMs: nil, logWhole: true) == nil)
    }

    /// "Nothing heard" is said only while the event log holds every line
    /// it was given: a compaction drops old lines, and an agent heard only
    /// in them was heard all the same. The engine knows from the launch
    /// replay's numbering (`EventLog.keepsEveryLine`).
    @MainActor
    @Test func aCompactedLogCannotSayNothingWasHeard() {
        let changed: Int64 = 1_800_000_000_000
        let config = Connection.Config(changedMs: changed)
        for agent in AgentID.allCases {
            #expect(Connection.caveat(agent: agent, install: .complete, config: config, heardMs: nil, logWhole: false) == nil, "\(agent.rawValue)")
        }
        #expect(Connection.caveat(agent: .copilot, install: .complete, config: config, heardMs: changed - 1, logWhole: false) == nil)
        #expect(Connection.caveat(agent: .copilot, install: .complete, config: config, heardMs: changed - 1, logWhole: true) == .neverHeard)

        func line(_ seq: Int64) -> AttentionRecord {
            AttentionRecord(agent: .claude, kind: .tool, ms: changed + seq, session: "s1", tool: "Read", seq: seq)
        }
        #expect(EventLog.keepsEveryLine([]))
        #expect(EventLog.keepsEveryLine([line(1), line(2), line(3)]))
        #expect(!EventLog.keepsEveryLine([line(1), line(3)]), "a compaction dropped the second")
        #expect(!EventLog.keepsEveryLine([line(2), line(3)]), "the first is gone")

        let header = AttentionProtocol.Header(next: 7, gen: "g1")
        let compacted = StatusStore()
        #expect(!compacted.engine.logWhole, "not read yet: nothing proves silence")
        compacted.engine.landLog(EventLog.Chunk(header: header, records: [line(5), line(6)], end: 300))
        #expect(!compacted.engine.logWhole)
        let whole = StatusStore()
        whole.engine.landLog(EventLog.Chunk(header: header, records: [line(1), line(2)], end: 300))
        #expect(whole.engine.logWhole)
        // A later read of the same log (a compaction since) keeps it: this
        // launch applied every line it dropped.
        whole.engine.landLog(EventLog.Chunk(header: AttentionProtocol.Header(next: 9, gen: "g1"), records: [line(2), line(8)], end: 200))
        #expect(whole.engine.logWhole)
        let none = StatusStore()
        none.engine.landLog(.empty)
        #expect(none.engine.logWhole, "no log yet: nothing was dropped")
    }

    /// A whole install nothing was heard through says so — for any agent:
    /// no line from it at all, or, in a file Pulse owns whole (its last
    /// change is Pulse's install), none since it was written. A file the
    /// person edits too (Claude's settings) changes for reasons of its own,
    /// so a line heard before its change still counts. Said on the state
    /// line, not as a warning, and in the report.
    @Test func anInstallNothingWasHeardThroughIsSaid() {
        let changed: Int64 = 1_800_000_000_000
        let config = Connection.Config(changedMs: changed)
        func caveat(_ agent: AgentID, heard: Int64?) -> Connection.Caveat? {
            Connection.caveat(agent: agent, install: .complete, config: config, heardMs: heard, logWhole: true)
        }
        for agent in AgentID.allCases {
            #expect(caveat(agent, heard: nil) == .neverHeard, "\(agent.rawValue)")
            #expect(caveat(agent, heard: changed + 1) == nil, "\(agent.rawValue)")
        }
        #expect(caveat(.copilot, heard: changed - 1) == .neverHeard, "Pulse's own file: nothing since the install")
        #expect(caveat(.opencode, heard: changed - 1) == .neverHeard)
        #expect(caveat(.claude, heard: changed - 1) == nil, "the person's settings change for reasons of their own")
        #expect(Connection.caveat(agent: .copilot, install: .partial(found: 8, of: 10), config: config, heardMs: nil, logWhole: true) == nil)
        let now = changed + 60_000
        let copilot = Connection.make(agent: .copilot, probed: .complete, failure: nil, heard: nil, ignored: nil, config: config)
        #expect(copilot.caveat == .neverHeard)
        let line = SettingsModel.HookAgent(copilot, nowMs: now, lang: .en)
        #expect(line.state == "Installed — nothing heard yet")
        #expect(line.tone == .ok, "not a fault: it may not have run yet")
        #expect(line.detail == "", "said once — on the state line")
        #expect(SettingsModel.HookAgent(copilot, nowMs: now, lang: .zh).state == "已安装——还没有听到事件")
        let report = copilot.reportLine(present: true, nowMs: now)
        #expect(report.contains("nothing heard through it since it was installed"))
        #expect(!report.contains("nothing heard yet"), "said once")
    }

    /// The words: an installed hook that may not run says why on its state
    /// line, as a warning, in both languages and in the report.
    @Test func aCaveatIsSaidOnTheLine() {
        let now: Int64 = 1_800_000_000_000
        let claude = Connection(agent: .claude, install: .complete, caveat: .turnedOff)
        #expect(SettingsModel.HookAgent(claude, nowMs: now, lang: .en).state == "Installed — but hooks are turned off in Claude's settings (disableAllHooks)")
        #expect(claude.reportLine(present: true, nowMs: now).contains("disableAllHooks"))
        let policy = Connection(agent: .claude, install: .partial(found: 9, of: 13), caveat: .managedOnly)
        let partial = SettingsModel.HookAgent(policy, nowMs: now, lang: .en)
        #expect(partial.state == "Needs update — 9 of 13 events")
        #expect(partial.detail.contains("a managed policy keeps Claude from running it"))
    }
}

/// The hooks section is where an agent's missing hook is fixed, one deep
/// link away from the tray.
@Suite("Hooks section")
struct HooksSectionTests {
    /// No setting makes Codex or Cursor report a wait, so their line offers
    /// no "connect" action — its capability line says what they report, and
    /// that waits are not among it.
    @Test func aWaitingNoneAgentSaysWhatItDoesNotReport() {
        for lang in [ResolvedLanguage.en, .zh] {
            let copy = L10n.t(.capReportsNoWaits, lang)
            #expect(!copy.localizedCaseInsensitiveContains("bridge"))
            #expect(!copy.contains("桥"))
        }
        let lines = SettingsModel.hookAgents(
            connections: AgentID.allCases.map { Connection(agent: $0, install: .complete) },
            present: Set(AgentID.allCases), nowMs: 0, lang: .en
        )
        #expect(lines.count == AgentID.allCases.count)
        for line in lines {
            let none = AgentID.waitingNoneAgents.contains(line.agent)
            #expect(line.capability.hasSuffix("— not waits") == none, "\(line.agent.rawValue): \(line.capability)")
            #expect(line.capability.hasPrefix("Reports waits") == !none, "\(line.agent.rawValue): \(line.capability)")
        }
        let cursor = lines.first { $0.agent == .cursor }
        #expect(cursor?.capability == "Reports turns, steps, last words — not waits")
        let zh = SettingsModel.HookAgent(Connection(agent: .cursor, install: .complete), nowMs: 0, lang: .zh)
        #expect(zh.capability == "报告回合、步骤和最后一句话——不报告等待")
    }

    /// What each agent reports is read from its adapter, not written per
    /// agent here: waits from its waiting source, steps from a per-tool
    /// event, titles from a prompt or name event, last words declared.
    @Test func eachAgentsCapabilitiesComeFromItsAdapter() {
        let table: [AgentID: AgentCapabilities] = [
            .claude: AgentCapabilities(waits: true, steps: true, lastWords: true, titles: true),
            .codex: AgentCapabilities(waits: false, steps: true, lastWords: true, titles: true),
            .cursor: AgentCapabilities(waits: false, steps: true, lastWords: true, titles: false),
            .copilot: AgentCapabilities(waits: true, steps: true, lastWords: false, titles: true),
            .opencode: AgentCapabilities(waits: true, steps: true, lastWords: false, titles: true),
            .pi: AgentCapabilities(waits: true, steps: true, lastWords: true, titles: true),
        ]
        for agent in AgentID.allCases {
            let can = agent.spec.capabilities
            #expect(can == table[agent], "\(agent.rawValue)")
            #expect(can.waits == (agent.waitingSource == .hooks))
            #expect(can.steps == agent.reportsToolActivity)
        }
        #expect(AgentID.claude.spec.capabilities.reportWords == ["waits", "steps", "words", "titles"])
    }

    @Test func waitingNoneAgentsCoverEveryWaitingNoneContract() {
        let none = Set(AgentID.allCases.filter { $0.waitingSource == .none })
        let listed = Set(AgentID.waitingNoneAgents)
        #expect(listed == none)
        #expect(!listed.contains(.claude))
        #expect(listed == [.codex, .cursor])
    }

    @MainActor
    @Test func waitingSignalsAreOneDeepLinkAway() {
        let store = StatusStore(lang: .en)
        store.openSettings(focus: .waitingSignals)
        #expect(store.settingsFocus.target == .waitingSignals)
        #expect(store.settingsModel.focus == .hooks)
    }
}

/// The tray's one notice, and the fixtures the tray captures are made of.
final class TrayNoticeTests: XCTestCase {
    /// The setup card comes first — without a hook there is nothing
    /// to notify. It names the agents on this Mac unconnected.
    @MainActor
    func testTheSetupCardOutranksNotificationSetup() {
        let store = StatusStore()
        store.installPreviewFixture("waiting")
        store.presentAgents = [.claude, .codex]

        XCTAssertFalse(store.trayNoticeInput.unconnected.isEmpty)
        XCTAssertEqual(store.trayNotice?.kind, .setup)
        XCTAssertEqual(store.trayNotice?.action, .connect)
        XCTAssertFalse(store.tr(.emptyHint).localizedCaseInsensitiveContains("install hooks"))
        XCTAssertFalse(store.tr(.emptyHint).contains("45"), "the empty state says what is true now")
    }

    /// An agent on this Mac with nothing running is offered too — the empty
    /// tray's first run.
    @MainActor
    func testAnAgentOnThisMacWithNothingRunningIsOfferedTheSetup() {
        let store = StatusStore()
        store.notifyAuthorized = true
        store.presentAgents = [.codex, .claude]
        XCTAssertEqual(store.trayNoticeInput.unconnected, [.claude, .codex], "roster order")
        XCTAssertEqual(store.trayNotice?.text, String(format: store.tr(.setupFound), "Claude, Codex"))
        store.hooksStatus = .installed([.claude, .codex])
        XCTAssertNil(store.trayNotice, "connected: nothing to set up")
    }

    /// A live agent process whose vendor folder is not on this Mac is not
    /// offered: "Connect" installs only where the folder is, so offering it
    /// would ask again after every click.
    @MainActor
    func testOnlyAgentsWhoseFolderIsHereAreOffered() {
        let store = StatusStore()
        store.installPreviewFixture("waiting")
        store.notifyAuthorized = true
        store.presentAgents = []
        XCTAssertTrue(store.rows.contains { $0.liveProcess })
        XCTAssertTrue(store.trayNoticeInput.unconnected.isEmpty, "running is not being on this Mac")
        store.presentAgents = [.opencode]
        XCTAssertEqual(store.trayNoticeInput.unconnected, [.opencode])
    }

    /// An agent whose install failed is never offered "Connect" again —
    /// it would fail the same way, card after card. The card says why,
    /// in the failure's own words, and opens Settings.
    @MainActor
    func testAFailedInstallIsSaidNotOfferedAgain() {
        let store = StatusStore()
        store.notifyAuthorized = true
        store.presentAgents = [.claude, .codex, .opencode]
        store.hooksStatus = .installed([.claude], failed: [.opencode: .invalidJSON])
        XCTAssertEqual(store.trayNoticeInput.unconnected, [.codex], "OpenCode failed: not offered again")
        XCTAssertEqual(store.trayNotice?.kind, .setup)
        store.hooksStatus = .installed([.claude, .codex], failed: [.opencode: .invalidJSON])
        XCTAssertTrue(store.trayNoticeInput.unconnected.isEmpty)
        let card = store.trayNotice
        XCTAssertEqual(card?.kind, .setupFailed)
        XCTAssertEqual(card?.action, .openHooksSettings)
        XCTAssertEqual(card?.text, HooksSupport.Status.failureText([.opencode: .invalidJSON], lang: store.lang))
        store.settings.hooksNudgeOff = true
        XCTAssertNil(store.trayNotice, "hooks removed on purpose: nothing to say")
    }

    /// After "Connect" the card shows what is left, until "Got it".
    @MainActor
    func testTheCardShowsTheRemainingStepsUntilDismissed() {
        let store = StatusStore()
        store.notifyAuthorized = true
        store.hooksStatus = .installed([.claude, .codex])
        store.setupConnected = [.codex, .claude]
        let card = store.trayNotice
        XCTAssertEqual(card?.kind, .setupDone)
        XCTAssertEqual(card?.steps, [store.tr(.setupStepCodex), store.tr(.setupStepRestart)])
        store.performTrayNotice(.dismissSetup)
        XCTAssertNil(store.setupConnected)
        XCTAssertNil(store.trayNotice)
    }

    /// An agent with no Waiting path is not a tray notice, and nothing
    /// offers it a connection it cannot have.
    @MainActor
    func testAnOpaqueLiveAgentIsNotATrayNotice() {
        let store = StatusStore()
        store.installPreviewFixture("waiting")
        store.hooksStatus = .all
        store.notifyAuthorized = true

        XCTAssertTrue(store.trayNoticeInput.unconnected.isEmpty)
        XCTAssertNil(store.trayNotice)
    }
}

/// The version a build reports is the one it is.
final class PulseVersionTests: XCTestCase {
    func testSemverIsWellFormed() {
        let parts = PulseVersion.semver.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "semver must be MAJOR.MINOR.PATCH")
        for part in parts {
            XCTAssertNotNil(Int(part), "non-numeric component in \(PulseVersion.semver)")
        }
    }

    func testUnpackagedBuildReportsDevNotAFakeRelease() {
        // Tests run without an app bundle, so this exercises the honest path.
        guard PulseVersion.bundleVersion == nil else { return }
        XCTAssertTrue(PulseVersion.short.hasSuffix("-dev"))
        XCTAssertEqual(PulseVersion.commit, "dev")
        XCTAssertTrue(PulseVersion.buildLine.isEmpty)
        XCTAssertEqual(PulseVersion.fingerprint, "Pulse \(PulseVersion.short)")
    }

    func testAnUnpackagedBuildIsNeitherPreviewNorStable() {
        guard PulseVersion.bundleVersion == nil else { return }
        XCTAssertEqual(PulseVersion.distributionChannel, "dev")
        XCTAssertFalse(PulseVersion.isNotarized)
    }

    /// A preview build is said to be ad-hoc signed, never "unsigned".
    func testThePreviewBuildIsSaidAsAdHocSigned() {
        XCTAssertTrue(L10n.t(.buildPreview, .en).contains("ad-hoc"))
        XCTAssertFalse(L10n.t(.buildPreview, .en).localizedCaseInsensitiveContains("unsigned"))
        XCTAssertFalse(L10n.t(.buildPreview, .zh).contains("未签名"))
    }

    func testHookStatusIsPerAgentNotGlobal() {
        XCTAssertTrue(HooksSupport.Status.all.isInstalled(for: .claude))
        XCTAssertTrue(HooksSupport.Status.all.isInstalled(for: .pi))
        XCTAssertTrue(HooksSupport.Status.installed([.claude]).isInstalled(for: .claude))
        XCTAssertFalse(HooksSupport.Status.installed([.claude]).isInstalled(for: .codex))
        XCTAssertFalse(HooksSupport.Status.missing.isInstalled(for: .claude))
        XCTAssertEqual(
            HooksSupport.Status.installed([.claude, .opencode]).label(lang: .en),
            String(format: L10n.t(.hooksInstalledCount, .en), 2, AgentID.allCases.count)
        )
    }
}
