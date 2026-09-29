import Foundation
import Testing
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

// Vendor formats: each agent's hook contract, read from the vendor's own
// source (docs/vendor-formats.json). 24.0: the session-file fixtures went
// with the harvest; the transcript lines Pulse still reads lazily are
// pinned in TranscriptTests (`TranscriptSummaryTests`).

/// 20.0 Drift — what a vendor's hook says, read the way its source says it.
/// The ones marked "invariant" were fake Waiting once.
@Suite("Vendor drift", .serialized)
struct VendorDriftTests {
    // MARK: - Hooks (invariant)

    /// 24.0: Grok runs Claude's hooks by default and marks its calls; Grok
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
        #expect(AttentionProtocol.normalizeKind("stop") == AttentionKind.turn.rawValue, "a known alias still normalises")
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
