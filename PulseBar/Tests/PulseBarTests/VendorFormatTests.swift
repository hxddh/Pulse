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
                let reading = PulseHookReceiver.interpret(agent: agent, event: event.name, payload: [:])
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
        #expect(codex.isSuperset(of: ["Interrupt", "SubagentStop"]))
        #expect(!codex.contains("PermissionRequest"))
        guard case .nested(let flavor) = AgentID.codex.spec.hooks.format else {
            Issue.record("Codex is nested")
            return
        }
        #expect(flavor.async)
        #expect(flavor.timeoutCaps["Interrupt"] == 3)
        #expect(flavor.synchronous["Interrupt"] == nil, "Interrupt honours async")
        #expect(flavor.trustBound)
        #expect(PulseHookReceiver.interpret(agent: .codex, event: "Interrupt", payload: [:])?.action == .stopped)
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
