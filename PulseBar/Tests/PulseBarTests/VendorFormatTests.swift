import Foundation
import Testing
@testable import PulseApp
@testable import PulseKit

// Vendor formats: each agent's hook contract, read from the vendor's own
// source (docs/vendor-formats.json). Pulse reads no vendor file, so there
// are no session-file fixtures: the events are the contract.

/// Drift — what a vendor's hook says, read the way its source says it.
/// The ones marked "invariant" were fake Waiting once.
@Suite("Vendor drift", .serialized)
struct VendorDriftTests {
    // MARK: - Hooks (invariant)

    /// Grok runs Claude's hooks by default and marks its calls; Grok
    /// is not supported, and its events never land on a Claude row.
    @Test func grokCallingClaudesHooksIsRefused() {
        #expect(PulseHookReceiver.attributedAgent("claude", environment: ["GROK_HOOK_EVENT": "Notification"]) == nil)
        #expect(PulseHookReceiver.attributedAgent("claude", environment: [:]) == .claude)
        #expect(PulseHookReceiver.attributedAgent("codex", environment: ["GROK_SESSION_ID": "x"]) == .codex)
        #expect(PulseHookReceiver.attributedAgent("goose", environment: [:]) == nil)
    }

    @Test(arguments: ["agentStop", "preToolUse", "beforeShellExecution", "tool.execute.before", ""])
    func anUnknownVendorEventIsNeverRed(event: String) {
        for agent in AgentID.allCases {
            let reading = PulseHookReceiver.interpret(agent: agent, event: event, payload: [:])
            let blocked: Bool
            if case .blocked = reading?.action { blocked = true } else { blocked = false }
            #expect(!blocked, "\(agent.rawValue) \(event)")
        }
    }

    @Test func anUntypedNotificationIsNotAWait() {
        let untyped = PulseHookReceiver.interpret(agent: .claude, event: "Notification", payload: ["message": "idle for 60s"])
        #expect(untyped?.action == .ignore)
        let typed = PulseHookReceiver.interpret(agent: .claude, event: "Notification", payload: ["notification_type": "permission_prompt"])
        #expect(typed?.action == .blocked(.permission))
    }

    /// A red lamp has a way to go out — every agent that can block
    /// installs an event that answers it — and each per-tool event reads as
    /// activity: never a decision, never a block.
    @Test func everyAgentThatCanBlockInstallsItsAnswer() {
        for agent in AgentID.allCases where agent.waitingSource == .hooks {
            let names = Set(agent.spec.hooks.events.map(\.name))
            #expect(!names.isDisjoint(with: HookContract.answerEvents), "\(agent.rawValue)")
        }
        for agent in AgentID.allCases {
            for event in agent.spec.hooks.events where HookContract.toolActivityEvents.contains(event.name) {
                // OpenCode's 1.x part event says its phase; a finished tool's
                // is `done`. Every other adapter ignores the key.
                let reading = PulseHookReceiver.interpret(agent: agent, event: event.name, payload: ["phase": "done"])
                #expect(reading?.action == .activity, "\(agent.rawValue) \(event.name)")
            }
        }
        #expect(HookContract.toolActivityEvents.isDisjoint(with: HookContract.gatingEvents))
    }

    /// Pi (pinned at 8efd314): a tool's start says what runs now and is
    /// never an answer; the events that can cancel a session switch, fork,
    /// compaction or tree move are gating and never installed; the folder
    /// Pi's extensions load from can be moved by `PI_CODING_AGENT_DIR`,
    /// which Pulse does not follow.
    @Test func piTellsWhatRunsAndNeverGates() {
        let names = Set(AgentID.pi.spec.hooks.events.map(\.name))
        #expect(names.isDisjoint(with: HookContract.gatingEvents))
        let start = PulseHookReceiver.interpret(agent: .pi, event: "tool_execution_start", payload: [:])
        #expect(start?.action == .status)
        #expect(!HookContract.answerEvents.contains("tool_execution_start"))
        for event in ["session_before_switch", "session_before_fork", "session_before_compact", "session_before_tree"] {
            #expect(HookContract.gatingEvents.contains(event), "\(event)")
        }
        let relocation = AgentID.pi.spec.hooks.relocation
        #expect(relocation == HookContract.Relocation(dir: ".pi/agent", variable: "PI_CODING_AGENT_DIR"))
        #expect(AgentID.pi.spec.hooks.path.hasPrefix(".pi/agent/"))
        #expect(AgentID.pi.spec.reportsOwnPID)
        #expect(!AgentID.claude.spec.reportsOwnPID)
    }

    /// Claude (docs checked 2026-10-17) and Codex (pinned at ce0323f): the
    /// observe-only events step 2 installs, each async; never an event whose
    /// hook takes Claude's place; Codex's Interrupt at its 3 s cap; Codex's
    /// hook trust is bound to the entry's text.
    @Test func claudeAndCodexInstallOnlyObserveOnlyEvents() {
        let claude = Set(AgentID.claude.spec.hooks.events.map(\.name))
        #expect(claude.isSuperset(of: ["SubagentStart", "SubagentStop", "PostCompact", "PermissionDenied"]))
        for never in ["PreToolUse", "MessageDisplay", "Elicitation", "WorktreeCreate"] {
            #expect(!claude.contains(never), "\(never)")
            #expect(HookContract.gatingEvents.contains(never), "\(never)")
        }
        let codex = Set(AgentID.codex.spec.hooks.events.map(\.name))
        #expect(codex.isSuperset(of: ["Interrupt", "SubagentStart", "SubagentStop", "PostCompact"]))
        #expect(!codex.contains("PermissionRequest"))
        #expect(!codex.contains("PreCompact"), "its continue: false stops the compaction")
        guard case .nested(let flavor) = AgentID.codex.spec.hooks.format else {
            Issue.record("Codex is nested")
            return
        }
        #expect(flavor.async)
        #expect(flavor.timeoutCaps["Interrupt"] == 3)
        #expect(flavor.synchronous["Interrupt"] == nil, "Interrupt honours async")
        #expect(flavor.installNote?.contains("/hooks") == true, "trust is the install report's note")
        #expect(PulseHookReceiver.interpret(agent: .codex, event: "Interrupt", payload: [:])?.action == .stopped)
    }

    /// OpenCode (pinned at v1.19.3 and v2.0.32): one plugin for both
    /// lines, reading the bus only — never a hook that can change a tool, a
    /// message or a permission. Its per-tool events make silence mean
    /// something; its asks are answered by the vendor's replies; the folder
    /// it loads from can be moved by the environment, which Pulse does not
    /// follow.
    @Test func openCodeServesBothLinesFromTheBusOnly() {
        let names = Set(AgentID.opencode.spec.hooks.events.map(\.name))
        #expect(names.isDisjoint(with: HookContract.gatingEvents))
        for never in ["tool.execute.before", "tool.execute.after", "chat.message", "chat.params", "permission.ask"] {
            #expect(HookContract.gatingEvents.contains(never), "\(never)")
        }
        #expect(names.isSuperset(of: ["message.part.updated", "session.updated", "session.compacted"]), "1.x")
        #expect(names.isSuperset(of: [
            "session.execution.started", "session.execution.succeeded", "session.execution.failed",
            "session.execution.interrupted", "session.tool.success", "session.tool.failed",
            "form.created", "form.replied", "form.cancelled",
        ]), "2.x")
        #expect(AgentID.opencode.reportsToolActivity)
        #expect(HookContract.answerEvents.isSuperset(of: ["form.replied", "form.cancelled", "permission.replied"]))
        #expect(AgentID.opencode.spec.hooks.relocation == HookContract.Relocation(dir: ".config/opencode", variable: "OPENCODE_CONFIG_DIR"))
        let start = PulseHookReceiver.interpret(agent: .opencode, event: "session.tool.called", payload: ["tool_name": "bash"])
        #expect(start?.action == .status, "a tool that started is what runs now, never an answer")
        let busy = PulseHookReceiver.interpret(agent: .opencode, event: "session.status", payload: ["status": "busy"])
        #expect(busy?.action == .status)
    }

    /// Copilot (docs at dae83f7): the launcher runs without a shell, the
    /// notification and compaction hooks are filtered by the vendor's own
    /// matcher, and `subagentStart` / `preCompact` cannot block.
    /// `agentStop` / `postToolUse` are synchronous — an owner-approved
    /// exception, harmless because the hook prints nothing.
    @Test func copilotRunsWithoutAShellAndFiltersAtTheSource() {
        guard case .ownedJSON(let command, let timeoutKey) = AgentID.copilot.spec.hooks.format else {
            Issue.record("Copilot is ownedJSON")
            return
        }
        #expect(command == .exec)
        #expect(timeoutKey == "timeoutSec")
        let events = AgentID.copilot.spec.hooks.events
        let notification = events.first { $0.name == "notification" }
        #expect(notification?.matcher == "permission_prompt|elicitation_dialog|agent_idle")
        let compact = events.first { $0.name == "preCompact" }
        #expect(compact?.matcher == "auto")
        let names = Set(events.map(\.name))
        #expect(names.isSuperset(of: ["subagentStart", "preCompact", "agentStop", "postToolUse"]))
        #expect(!names.contains("subagentStop"), "it can block and force a continuation")
        #expect(!names.contains("userPromptTransformed"))
        #expect(HookContract.gatingEvents.contains("userPromptTransformed"))
        #expect(names.isDisjoint(with: HookContract.gatingEvents))
    }

    /// Cursor (docs unreachable; third-party bindings and forum reports):
    /// only `after*` and lifecycle events, never a `before*` one; still
    /// never blocked; its conversation is its session.
    @Test func cursorInstallsOnlyAfterEvents() {
        let names = Set(AgentID.cursor.spec.hooks.events.map(\.name))
        #expect(names == [
            "sessionStart", "sessionEnd", "afterShellExecution", "afterFileEdit", "afterMCPExecution",
            "postToolUseFailure", "afterAgentResponse", "stop",
        ])
        let gated = names.filter { $0.hasPrefix("before") }
        #expect(gated.isEmpty)
        #expect(AgentID.cursor.waitingSource == .none)
        #expect(AgentID.cursor.spec.sessionKeys.first == "conversation_id")
        #expect(AgentID.claude.spec.sessionKeys == HookContext.sessionKeys)
    }

    /// Every contract event Pulse installs is one the receiver knows —
    /// an installed event it could not read would be a hook that says
    /// nothing.
    @Test func everyInstalledEventIsRead() {
        for agent in AgentID.allCases {
            for event in agent.spec.hooks.events {
                #expect(PulseHookReceiver.interpret(agent: agent, event: event.name, payload: [:]) != nil, "\(agent.rawValue) \(event.name)")
            }
        }
    }
}

/// Every recorded payload (`PulseBar/Tests/Fixtures/hooks`, one per
/// installed event at least — `catalog_check` holds the folder to the
/// contracts) through the receiver, in process, the way its installed hook
/// hands it over: each becomes the line `expected.json` says — a state, or
/// the ignored line that says why — and never an unreadable payload.
/// `scripts/e2e.sh` sends the same files through the packaged app.
@Suite("Recorded payloads")
struct RecordedPayloadTests {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/hooks", isDirectory: true)

    @Test func everyRecordedPayloadBecomesItsLine() throws {
        let data = try Data(contentsOf: Self.folder.appendingPathComponent("expected.json"))
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let expected = try #require(root?["expected"] as? [String: String])
        let fields = root?["fields"] as? [String: [String: String]] ?? [:]
        for agent in AgentID.allCases {
            for event in agent.spec.hooks.events {
                #expect(expected["\(agent.rawValue)/\(event.name)"] != nil, "\(agent.rawValue) \(event.name) has no fixture")
            }
        }
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-fixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        for (name, want) in expected.sorted(by: { $0.key < $1.key }) {
            let parts = name.split(separator: "/", maxSplits: 1).map(String.init)
            let agent = try #require(AgentID(rawValue: parts.first ?? ""), "\(name)")
            let file = parts.count > 1 ? parts[1] : ""
            let event = String(file.split(separator: "@", maxSplits: 1).first ?? "")
            let payload = try String(contentsOf: Self.folder.appendingPathComponent("\(name).json"), encoding: .utf8)
            // The two modules pass their payload as the last argument; every
            // other hook pipes it on stdin.
            var module = false
            if case .module = agent.spec.hooks.format { module = true }
            var arguments = ["PulseBar", "--hook", agent.rawValue, event]
            if module { arguments.append(payload) }
            let log = home.appendingPathComponent("\(agent.rawValue)-\(file).tsv")
            PulseHookReceiver.run(
                arguments: arguments, stdin: module ? "" : payload, environment: [:], logURL: log,
                nowMs: 1_800_000_000_000, locate: { _, _ in (0, "") }, parent: 0, argumentsOf: { _, _ in nil }
            )
            let lines = EventLog.read(at: log, after: nil)?.records ?? []
            #expect(lines.count == 1, "\(name): one heard event is one line")
            guard let line = lines.first else { continue }
            let got = line.kind == .ignored ? "ignored:\(line.message)" : line.kind.rawValue
            #expect(got == want, "\(name)")
            #expect(line.message != PulseHookReceiver.Ignored.unparsable.rawValue, "\(name)")
            #expect(line.event == event, "\(name)")
            // The columns `fields` pins, each exactly as written.
            for (column, value) in (fields[name] ?? [:]).sorted(by: { $0.key < $1.key }) {
                let written = Self.column(column, of: line)
                #expect(written == value, "\(name) \(column)")
            }
        }
        for name in fields.keys.sorted() {
            #expect(expected[name] != nil, "\(name): fields for a fixture expected.json does not name")
        }
    }

    /// One column of a written line, as `expected.json`'s `fields` names it.
    static func column(_ name: String, of line: AttentionRecord) -> String? {
        switch name {
        case "tool": return line.tool
        case "cat": return line.category?.rawValue ?? ""
        case "err": return line.failed ? "1" : ""
        case "took": return line.tookMs > 0 ? String(line.tookMs) : ""
        case "meta": return line.meta.field
        case "sub": return line.sub
        case "message": return line.message
        default: return nil
        }
    }
}
