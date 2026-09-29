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

/// 1.2/2.1 · facts only a full read of the transcript can produce.
/// Carried, never recomputed — the read window could only contradict them.
struct SessionDigestFacts: Hashable {
    var loopTool: String = ""
    var loopCount: Int = 0
    var sessionErrors: Int = 0
    var toolSummary: String = ""
    var tokensIn: Int = 0
    var tokensOut: Int = 0
    var recentTools: [String] = []
    var progressPercent: Int = 0
    var caughtUp: Bool = false
    var bytesPerMinute: Int = 0
    var startedMs: Int64 = 0
}
