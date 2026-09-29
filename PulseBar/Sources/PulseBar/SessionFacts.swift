import Foundation

// 4.0-γ — the session's facts become value types.
//
// AgentRow grew ~70 flat fields across nine 2.x versions; the fact families
// were real all along but existed only as comment headers. Each family is
// now a value its producer can build and its consumer can pass whole —
// `AgentRow` composes them and keeps forwarding accessors so every existing
// reader, writer and test compiles unchanged (the compiler and the full
// suite are the proof that nothing moved semantically). Producers and new
// surfaces can address a family as one value.

/// 2.8 Progress · the agent's own plan and words — self-report tier:
/// sanitized, aged out when stale, never a source of Waiting.
struct SessionSelfReport: Hashable {
    var planStep: String = ""
    var planSteps: [ActivityHarvest.PlanStep] = []
    var lastWord: String = ""
    var lastErrorText: String = ""
}

/// 2.9 · the push-fresh action from the hook's activity spool. Present
/// tense is allowed only inside the live window.
struct SessionLiveAction: Hashable {
    var tool: String = ""
    var target: String = ""
    var atMs: Int64 = 0
}
