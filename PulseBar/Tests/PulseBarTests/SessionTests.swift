import Foundation
import Testing
import XCTest
@testable import PulseApp
@testable import PulseCore
@testable import PulseHarvest

// Sessions: the event reducer (SessionBook), its projection into the tray
// (TrayState), row identity, and what a row carries.

/// One vendor hook event as `pulse-hook` writes it — one v5 line, or
/// nothing — by the receiver's own reading of the vendor's event name and
/// payload (`PulseHookReceiver.interpret`, then `.record`). The truth tables
/// below replay recorded sequences through it.
enum HookFeed {
    struct Written {
        var lines: [AttentionRecord] = []
    }

    static func write(
        _ agent: AgentID,
        _ event: String,
        _ payload: [String: Any] = [:],
        at ms: Int64,
        session: String = "s1",
        cwd: String = "/Users/me/app",
        pid: Int32 = 4242,
        front: Bool? = nil
    ) -> Written {
        guard let reading = PulseHookReceiver.interpret(agent: agent, event: event, payload: payload) else { return Written() }
        if case .blocked = reading.action, agent.waitingSource == .none { return Written() }
        var full = payload
        full["session_id"] = session
        full["cwd"] = cwd
        guard var record = PulseHookReceiver.record(agent: agent, reading: reading, payload: full, nowMs: ms) else {
            return Written()
        }
        record.pid = pid
        if let kind = AttentionProtocol.kind(record.kind), kind.isOpen { record.front = front }
        return Written(lines: [record])
    }

    static func word(_ state: SessionBook.State?) -> String {
        switch state {
        case .none: return "none"
        case .idle: return "idle"
        case .working: return "working"
        case .blocked(let block): return "blocked:\(block.kind.rawValue)"
        case .yourTurn: return "turn"
        case .ended: return "ended"
        }
    }
}

/// The truth tables: each supported agent's own event sequence,
/// replayed through the receiver's reading into the book, and the state the
/// session is in after every step.
@Suite("Session book")
struct SessionBookTests {
    let t0: Int64 = 1_800_000_000_000
    let minute: Int64 = 60_000

    let second: Int64 = 1_000

    /// Plays `steps` `every` ms apart (a minute by default); returns the
    /// session's state after each.
    private func play(_ agent: AgentID, _ steps: [(String, [String: Any])], every spacing: Int64 = 60_000) -> (states: [String], book: SessionBook) {
        playAt(agent, steps.enumerated().map { (Int64($0.offset) * spacing, $0.element.0, $0.element.1) })
    }

    /// Plays each step at its own offset from `t0` — the seconds a real
    /// session spends between events, well inside `stopGraceMs` — and ticks
    /// the book after each as the engine's projection does. A step named
    /// "tick" is the clock alone.
    private func playAt(_ agent: AgentID, _ steps: [(Int64, String, [String: Any])]) -> (states: [String], book: SessionBook) {
        var book = SessionBook()
        var states: [String] = []
        for (offset, event, payload) in steps {
            let ms = t0 + offset
            if event != "tick" {
                let written = HookFeed.write(agent, event, payload, at: ms)
                for line in written.lines { book.apply(line, nowMs: ms) }
            }
            book.settleHeldTurns(nowMs: ms)
            states.append(HookFeed.word(book.sessions["\(agent.rawValue)|s1"]?.state))
        }
        return (states, book)
    }

    @Test func claude() {
        let run = play(.claude, [
            ("SessionStart", [:]),
            ("UserPromptSubmit", ["prompt": "Fix the login test"]),
            ("PostToolUse", ["tool_name": "Read"]),
            ("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "npm test"]]),
            ("PostToolUse", ["tool_name": "Bash"]),
            ("Notification", ["notification_type": "elicitation_dialog", "message": "Pick a database"]),
            ("Notification", ["notification_type": "elicitation_complete"]),
            ("Stop", [:]),
            ("SessionEnd", [:]),
        ])
        #expect(run.states == [
            "idle", "working", "working", "blocked:permission", "working",
            "blocked:question", "working", "turn", "ended",
        ])
    }

    @Test func claudeSaysWhatItAsks() {
        var book = SessionBook()
        let written = HookFeed.write(.claude, "PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "npm test"]], at: t0)
        for line in written.lines { book.apply(line, nowMs: t0) }
        guard case .blocked(let block) = book.sessions["claude|s1"]?.state else {
            Issue.record("not blocked")
            return
        }
        #expect(block.ask == "Bash: npm test")
        #expect(block.sinceMs == t0)
    }

    @Test func codexIsNeverBlocked() {
        let run = play(.codex, [
            ("SessionStart", [:]),
            ("UserPromptSubmit", ["prompt": "Add a queue"]),
            ("PermissionRequest", ["tool_name": "shell"]),
            ("permission", [:]),
            ("Stop", [:]),
            ("SessionEnd", [:]),
        ])
        #expect(run.states == ["idle", "working", "working", "working", "turn", "ended"])
    }

    @Test func cursorIsNeverBlocked() {
        let run = play(.cursor, [
            ("sessionStart", [:]),
            ("afterAgentResponse", [:]),
            ("question", [:]),
            ("stop", [:]),
            ("sessionEnd", [:]),
        ])
        #expect(run.states == ["idle", "working", "working", "turn", "ended"])
    }

    @Test func pi() {
        let run = play(.pi, [
            ("session_start", [:]),
            ("agent_start", [:]),
            ("ui_prompt_start", ["kind": "confirm", "title": "Delete build/?"]),
            ("ui_prompt_end", [:]),
            ("tool_execution_end", [:]),
            ("ui_prompt_start", ["kind": "select", "title": "Which branch?"]),
            ("ui_prompt_end", [:]),
            ("agent_settled", [:]),
            ("session_shutdown", [:]),
        ])
        #expect(run.states == [
            "idle", "working", "blocked:permission", "working", "working",
            "blocked:question", "working", "turn", "ended",
        ])
    }

    @Test func gemini() {
        let run = play(.gemini, [
            ("SessionStart", [:]),
            ("BeforeAgent", [:]),
            ("Notification", ["notification_type": "ToolPermission", "message": "Run npm test"]),
            ("AfterAgent", [:]),
            ("BeforeAgent", [:]),
            ("SessionEnd", [:]),
        ])
        #expect(run.states == ["idle", "working", "blocked:permission", "turn", "working", "ended"])
    }

    @Test func copilot() {
        let run = play(.copilot, [
            ("sessionStart", [:]),
            ("userPromptSubmitted", [:]),
            ("notification", ["notification_type": "permission_prompt", "message": "Allow bash?"]),
            ("postToolUse", [:]),
            ("notification", ["notification_type": "elicitation_dialog", "message": "Which file?"]),
            ("agentStop", [:]),
            ("sessionEnd", [:]),
        ])
        #expect(run.states == [
            "idle", "working", "blocked:permission", "working", "blocked:question", "turn", "ended",
        ])
    }

    @Test func openCode() {
        let run = play(.opencode, [
            ("session.created", [:]),
            ("session.status", ["status": ["type": "busy"]]),
            ("permission.asked", ["permission": "bash", "patterns": ["npm test"]]),
            ("permission.replied", [:]),
            ("question.asked", ["questions": [["question": "Which DB?"]]]),
            ("question.rejected", [:]),
            ("session.idle", [:]),
            ("session.deleted", [:]),
        ])
        #expect(run.states == [
            "idle", "working", "blocked:permission", "working", "blocked:question", "working", "turn", "ended",
        ])
        let ask = HookFeed.write(.opencode, "permission.asked", ["permission": "bash", "patterns": ["npm test"]], at: t0).lines.first?.message
        #expect(ask == "bash: npm test")
    }

    /// Each agent's own tool event becomes a step with its tool and target —
    /// Copilot's `toolArgs` as a JSON string, Pi's forwarded summary — and
    /// its own prompt event becomes the title. Cursor and OpenCode activity
    /// names no tool: no step.
    @Test func everyAgentsStepsComeFromItsOwnHook() {
        let cases: [(AgentID, String, [String: Any], String, String)] = [
            (.claude, "PostToolUse", ["tool_name": "Bash", "tool_input": ["command": "swift test"]], "Bash", "swift test"),
            (.codex, "PostToolUse", ["tool_name": "shell", "tool_input": ["command": "cargo build"]], "shell", "cargo build"),
            (.gemini, "AfterTool", ["tool_name": "read_file", "tool_input": ["file_path": "/w/a.ts"]], "read_file", "/w/a.ts"),
            (.copilot, "postToolUse", ["toolName": "bash", "toolArgs": #"{"command":"npm test"}"#], "bash", "npm test"),
            (.pi, "tool_execution_end", ["tool_name": "edit", "tool_input": ["path": "src/x.ts"]], "edit", "src/x.ts"),
        ]
        for (agent, event, payload, tool, target) in cases {
            var book = SessionBook()
            for line in HookFeed.write(agent, event, payload, at: t0).lines { book.apply(line, nowMs: t0) }
            let step = book.sessions["\(agent.rawValue)|s1"]?.steps.last
            #expect(step == SessionBook.Step(tool: tool, target: target, ms: t0), "\(agent.rawValue)")
        }
        let quiet: [(AgentID, String, [String: Any])] = [(.cursor, "afterAgentResponse", [:]), (.opencode, "session.status", ["status": "busy"])]
        for (agent, event, payload) in quiet {
            var book = SessionBook()
            for line in HookFeed.write(agent, event, payload, at: t0).lines { book.apply(line, nowMs: t0) }
            let steps = book.sessions["\(agent.rawValue)|s1"]?.steps ?? []
            #expect(steps.isEmpty, "\(agent.rawValue)")
        }
        let prompts: [(AgentID, String)] = [(.claude, "UserPromptSubmit"), (.codex, "UserPromptSubmit"), (.gemini, "BeforeAgent"), (.copilot, "userPromptSubmitted")]
        for (agent, event) in prompts {
            var book = SessionBook()
            for line in HookFeed.write(agent, event, ["prompt": "Fix the flaky login test"], at: t0).lines { book.apply(line, nowMs: t0) }
            let title = book.sessions["\(agent.rawValue)|s1"]?.title
            #expect(title == "Fix the flaky login test", "\(agent.rawValue)")
        }
    }

    // MARK: - Answers, denials and held turns (realistic spacing)

    /// Gemini asks, the tool runs (AfterTool): the answer is the tool.
    @Test func geminiAnsweredByItsTool() {
        let run = playAt(.gemini, [
            (0, "BeforeAgent", [:]),
            (4 * second, "Notification", ["notification_type": "ToolPermission", "message": "Allow run_shell_command?"]),
            (7 * second, "AfterTool", ["tool_name": "run_shell_command"]),
            (12 * second, "AfterAgent", [:]),
        ])
        #expect(run.states == ["working", "blocked:permission", "working", "turn"])
    }

    /// Gemini asks, the person denies: no tool runs, the turn ends 3 s
    /// later — inside the grace. The turn is held, never dropped: the lamp
    /// goes out when the grace ends.
    @Test func geminiDeniedTurnLandsAfterTheGrace() {
        let run = playAt(.gemini, [
            (0, "BeforeAgent", [:]),
            (4 * second, "Notification", ["notification_type": "ToolPermission", "message": "Allow run_shell_command?"]),
            (7 * second, "AfterAgent", [:]),
            (15 * second, "tick", [:]),
            (25 * second, "tick", [:]),
        ])
        #expect(run.states == ["working", "blocked:permission", "blocked:permission", "blocked:permission", "turn"])
        guard case .yourTurn(let since) = run.book.sessions["gemini|s1"]?.state else {
            Issue.record("not your turn")
            return
        }
        #expect(since == t0 + 7 * second, "the turn keeps its own clock")
    }

    @Test func copilotAnsweredByItsTool() {
        let run = playAt(.copilot, [
            (0, "userPromptSubmitted", [:]),
            (3 * second, "notification", ["notification_type": "permission_prompt", "message": "Allow bash?"]),
            (9 * second, "postToolUse", ["toolName": "bash"]),
            (14 * second, "agentStop", [:]),
        ])
        #expect(run.states == ["working", "blocked:permission", "working", "turn"])
    }

    /// Claude: a denied permission fires no tool event and Stop follows
    /// within seconds.
    @Test func claudeDeniedTurnLandsAfterTheGrace() {
        let run = playAt(.claude, [
            (0, "UserPromptSubmit", ["prompt": "Clean up"]),
            (5 * second, "PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "rm -rf build"]]),
            (9 * second, "Stop", [:]),
            (26 * second, "tick", [:]),
        ])
        #expect(run.states == ["working", "blocked:permission", "blocked:permission", "turn"])
    }

    /// The Stop line lands before the answering tool's line (two hooks
    /// racing for the log's lock): the held turn still ends the session's
    /// turn once the answer lands.
    @Test func aHeldTurnLandsWhenTheAnswerArrivesAfterIt() {
        var book = SessionBook()
        let raise = HookFeed.write(.claude, "PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "npm test"]], at: t0)
        let stop = HookFeed.write(.claude, "Stop", [:], at: t0 + 8 * second)
        let tool = HookFeed.write(.claude, "PostToolUse", ["tool_name": "Bash"], at: t0 + 4 * second)
        for line in raise.lines + stop.lines { book.apply(line, nowMs: t0 + 9 * second) }
        #expect(HookFeed.word(book.sessions["claude|s1"]?.state) == "blocked:permission")
        for line in tool.lines { book.apply(line, nowMs: t0 + 9 * second) }
        #expect(book.sessions["claude|s1"]?.state == .yourTurn(sinceMs: t0 + 8 * second))
    }

    /// Claude runs tools in parallel: a Read finishing while Bash waits for
    /// permission is not the person saying yes. Bash's own PostToolUse is.
    @Test func aParallelToolDoesNotAnswerAnotherToolsPermission() {
        let run = playAt(.claude, [
            (0, "UserPromptSubmit", [:]),
            (2 * second, "PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "npm test"]]),
            (3 * second, "PostToolUse", ["tool_name": "Read", "tool_input": ["file_path": "/w/a.swift"]]),
            (8 * second, "Notification", ["notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash"]),
            (12 * second, "PostToolUse", ["tool_name": "Bash"]),
        ])
        #expect(run.states == ["working", "blocked:permission", "blocked:permission", "blocked:permission", "working"])
    }

    /// A question with no tool named is answered by any tool that runs.
    @Test func aBlockThatNamesNoToolIsAnsweredByAnyTool() {
        var book = SessionBook()
        book.apply(AttentionRecord(agent: "copilot", kind: "permission", ms: t0, message: "Allow bash?", session: "s1"), nowMs: t0)
        book.apply(AttentionRecord(agent: "copilot", kind: "tool", ms: t0 + second, session: "s1", tool: "bash"), nowMs: t0 + second)
        #expect(HookFeed.word(book.sessions["copilot|s1"]?.state) == "working")
        #expect(SessionBook.blockedTool("Bash: npm test") == "Bash")
        #expect(SessionBook.blockedTool("AskUserQuestion") == "AskUserQuestion")
        #expect(SessionBook.blockedTool("Allow bash?") == "")
        #expect(SessionBook.blockedTool("Claude needs your permission to use Bash") == "")
    }

    /// Claude raises one approval twice (PermissionRequest, then its
    /// Notification ~6 s later): the second keeps the first's words and
    /// clock.
    @Test func aReRaiseKeepsTheFirstAsk() {
        let run = playAt(.claude, [
            (0, "PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "npm test"]]),
            (6 * second, "Notification", ["notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash"]),
        ])
        guard case .blocked(let block) = run.book.sessions["claude|s1"]?.state else {
            Issue.record("not blocked")
            return
        }
        #expect(block.ask == "Bash: npm test")
        #expect(block.sinceMs == t0)
        #expect(block.tool == "Bash")
    }

    /// `idle_prompt` comes about a minute after a turn — and again after the
    /// person has seen it. It never revives a turn already seen.
    @Test func idlePromptDoesNotReviveASeenTurn() {
        var book = SessionBook()
        for line in HookFeed.write(.claude, "Stop", [:], at: t0).lines { book.apply(line, nowMs: t0) }
        book.apply(AttentionRecord(agent: "claude", kind: "done", ms: t0 + 10 * second, session: "s1"), nowMs: t0 + 10 * second)
        #expect(HookFeed.word(book.sessions["claude|s1"]?.state) == "idle")
        let idle = HookFeed.write(.claude, "Notification", ["notification_type": "idle_prompt", "message": "Claude is waiting for your input"], at: t0 + 60 * second)
        let idleKinds = idle.lines.map(\.kind)
        #expect(idleKinds == ["idle"])
        for line in idle.lines { book.apply(line, nowMs: t0 + 60 * second) }
        #expect(HookFeed.word(book.sessions["claude|s1"]?.state) == "idle", "the seen turn stays seen")
    }

    /// Esc on a Claude permission prompt fires no Stop; `idle_prompt` a
    /// minute later is the evidence the session is back at its prompt.
    @Test func idlePromptEndsAWorkingOrBlockedSession() {
        let run = playAt(.claude, [
            (0, "PermissionRequest", ["tool_name": "Bash"]),
            (70 * second, "Notification", ["notification_type": "idle_prompt"]),
        ])
        #expect(run.states == ["blocked:permission", "turn"])
    }

    /// A dismissal's `done` written while a new ask was being raised is
    /// about the old one.
    @Test func aDoneStampedBeforeTheRaiseDoesNotClearIt() {
        var book = SessionBook()
        book.apply(AttentionRecord(agent: "claude", kind: "permission", ms: t0 + 2 * second, message: "Bash: ls", session: "s1"), nowMs: t0 + 3 * second)
        book.apply(AttentionRecord(agent: "claude", kind: "done", ms: t0 + second, session: "s1"), nowMs: t0 + 3 * second)
        #expect(HookFeed.word(book.sessions["claude|s1"]?.state) == "blocked:permission")
    }

    // MARK: - Invariants

    @Test func aBlockedLineForAnAgentThatCannotBlockIsRefused() {
        for agent in AgentID.waitingNoneAgents {
            var book = SessionBook()
            let changed = book.apply(AttentionRecord(agent: agent.rawValue, kind: "permission", ms: t0, session: "s1"), nowMs: t0)
            #expect(!changed, "\(agent.rawValue)")
            #expect(book.sessions.isEmpty)
        }
    }

    @Test func aProcessExitEndsItsSessions() {
        var book = SessionBook()
        book.apply(AttentionRecord(agent: "claude", kind: "working", ms: t0, session: "a", pid: 77), nowMs: t0)
        book.apply(AttentionRecord(agent: "claude", kind: "working", ms: t0, session: "b", pid: 88), nowMs: t0)
        #expect(book.livePids == [77, 88])
        let changed1 = book.processExited(pid: 77, atMs: t0 + minute)
        #expect(changed1)
        #expect(HookFeed.word(book.sessions["claude|a"]?.state) == "ended")
        #expect(HookFeed.word(book.sessions["claude|b"]?.state) == "working")
        #expect(book.livePids == [88])
    }

    @Test func aPidFoundDeadEndsWhenItWasLastHeard() {
        var book = SessionBook()
        book.apply(AttentionRecord(agent: "codex", kind: "turn", ms: t0, session: "c", pid: 55), nowMs: t0)
        book.endSessions(whosePidIsDead: { _ in false })
        #expect(book.sessions["codex|c"]?.state == .ended(atMs: t0))
    }

    @Test func aDismissClearsExactlyTheSessionItNames() {
        var book = SessionBook()
        for session in ["a", "b"] {
            book.apply(AttentionRecord(agent: "claude", kind: "permission", ms: t0, session: session), nowMs: t0)
        }
        book.apply(AttentionRecord(agent: "claude", kind: "done", ms: t0 + 1_000, session: "a"), nowMs: t0 + 1_000)
        #expect(HookFeed.word(book.sessions["claude|a"]?.state) == "working")
        #expect(HookFeed.word(book.sessions["claude|b"]?.state) == "blocked:permission")
    }

    @Test func anEmptyDoneClearsOnlyTheSessionlessEntries() {
        var book = SessionBook()
        book.apply(AttentionRecord(agent: "gemini", kind: "permission", ms: t0, session: "", cwd: "/w/a"), nowMs: t0)
        book.apply(AttentionRecord(agent: "gemini", kind: "permission", ms: t0, session: "g1", cwd: "/w/a"), nowMs: t0)
        book.apply(AttentionRecord(agent: "gemini", kind: "done", ms: t0 + 1_000, session: ""), nowMs: t0 + 1_000)
        let folder = RowIdentity.session(agent: .gemini, session: "", cwd: "/w/a")
        #expect(HookFeed.word(book.sessions[folder]?.state) == "working")
        #expect(HookFeed.word(book.sessions["gemini|g1"]?.state) == "blocked:permission", "a session with an id is never cleared by an empty done")
    }

    @Test func aDoneAfterATurnMeansItWasSeen() {
        var book = SessionBook()
        book.apply(AttentionRecord(agent: "claude", kind: "turn", ms: t0, session: "s1"), nowMs: t0)
        book.apply(AttentionRecord(agent: "claude", kind: "done", ms: t0 + 1_000, session: "s1"), nowMs: t0 + 1_000)
        #expect(HookFeed.word(book.sessions["claude|s1"]?.state) == "idle")
    }

    @Test func aTurnRightAfterABlockDoesNotClearIt() {
        var book = SessionBook()
        book.apply(AttentionRecord(agent: "claude", kind: "permission", ms: t0, session: "s1"), nowMs: t0)
        book.apply(AttentionRecord(agent: "claude", kind: "turn", ms: t0 + 5_000, session: "s1"), nowMs: t0 + 5_000)
        #expect(HookFeed.word(book.sessions["claude|s1"]?.state) == "blocked:permission", "inside the grace")
        book.apply(AttentionRecord(agent: "claude", kind: "turn", ms: t0 + 25_000, session: "s1"), nowMs: t0 + 25_000)
        #expect(HookFeed.word(book.sessions["claude|s1"]?.state) == "turn")
    }

    @Test func aTurnWatchedFinishIsOwedToNobody() {
        var book = SessionBook()
        book.apply(AttentionRecord(agent: "claude", kind: "turn", ms: t0, session: "s1", front: true), nowMs: t0)
        #expect(HookFeed.word(book.sessions["claude|s1"]?.state) == "idle")
    }

    @Test func aSecondAskIsItsOwnRaiseAndKeepsTheWords() {
        var book = SessionBook()
        book.apply(AttentionRecord(agent: "claude", kind: "permission", ms: t0, message: "Bash: npm test", session: "s1"), nowMs: t0)
        book.apply(AttentionRecord(agent: "claude", kind: "permission", ms: t0 + minute, message: "", session: "s1"), nowMs: t0 + minute)
        guard case .blocked(let block) = book.sessions["claude|s1"]?.state else {
            Issue.record("not blocked")
            return
        }
        #expect(block.sinceMs == t0 + minute)
        #expect(block.ask == "Bash: npm test")
    }

    @Test func activityBeforeTheRaiseOrInAnotherSessionDoesNotAnswerIt() {
        var book = SessionBook()
        book.apply(AttentionRecord(agent: "claude", kind: "permission", ms: t0, session: "s1"), nowMs: t0)
        func event(_ session: String, _ ms: Int64) -> AttentionRecord {
            AttentionRecord(agent: "claude", kind: "tool", ms: ms, session: session, tool: "Bash")
        }
        book.apply(event("s1", t0 - 1_000), nowMs: t0)
        #expect(HookFeed.word(book.sessions["claude|s1"]?.state) == "blocked:permission", "a tool line stamped before the raise")
        book.apply(event("s2", t0 + 1_000), nowMs: t0 + 1_000)
        #expect(HookFeed.word(book.sessions["claude|s1"]?.state) == "blocked:permission", "another session's tool")
        book.apply(event("s1", t0 + 2_000), nowMs: t0 + 2_000)
        #expect(HookFeed.word(book.sessions["claude|s1"]?.state) == "working", "answered in the vendor's prompt")
    }

    @Test func anEventWithNothingToSayMakesNoSession() {
        var book = SessionBook()
        let changed2 = book.apply(AttentionRecord(agent: "claude", kind: "done", ms: t0, session: "x"), nowMs: t0)
        #expect(!changed2)
        let changed3 = book.apply(AttentionRecord(agent: "claude", kind: "end", ms: t0, session: "x"), nowMs: t0)
        #expect(!changed3)
        let changed4 = book.apply(AttentionRecord(agent: "claude", kind: "turn", ms: t0, session: ""), nowMs: t0)
        #expect(!changed4)
        #expect(book.sessions.isEmpty)
    }

    /// A tool line is an event like any other — it introduces a
    /// working session; one that names no session makes nothing.
    @Test func aToolLineIsWorkAndASessionlessOneIsNothing() {
        var book = SessionBook()
        let changed5 = book.apply(AttentionRecord(agent: "pi", kind: "tool", ms: t0, session: "p", cwd: "/w"), nowMs: t0)
        #expect(changed5)
        #expect(HookFeed.word(book.sessions["pi|p"]?.state) == "working")
        #expect(book.sessions["pi|p"]?.activityMs == t0)
        let changed6 = book.apply(AttentionRecord(agent: "pi", kind: "tool", ms: t0, session: "", cwd: "/w"), nowMs: t0)
        #expect(!changed6, "a tool with no session has no row to belong to")
        #expect(book.sessions.count == 1)
    }

    // MARK: - Audit fixes

    /// Fix 3: every line is applied. Parallel tools written around the
    /// answering one — before it and after it — no longer hide it (the spool
    /// kept only the newest event per session).
    @Test func parallelToolsAroundTheAnswerDoNotHideIt() {
        var book = SessionBook()
        let lines = [
            AttentionRecord(agent: "claude", kind: "permission", ms: t0, message: "Bash: npm test", session: "s1", tool: "Bash"),
            AttentionRecord(agent: "claude", kind: "tool", ms: t0 + 1 * second, message: "/w/a.swift", session: "s1", tool: "Read"),
            AttentionRecord(agent: "claude", kind: "tool", ms: t0 + 2 * second, message: "/w/b.swift", session: "s1", tool: "Grep"),
            AttentionRecord(agent: "claude", kind: "tool", ms: t0 + 3 * second, message: "npm test", session: "s1", tool: "Bash"),
            AttentionRecord(agent: "claude", kind: "tool", ms: t0 + 3 * second + 200, message: "/w/c.swift", session: "s1", tool: "Read"),
        ]
        for (index, line) in lines.enumerated() {
            book.apply(line, nowMs: t0 + 4 * second)
            if index == 2 {
                #expect(HookFeed.word(book.sessions["claude|s1"]?.state) == "blocked:permission", "parallel tools are not the answer")
            }
        }
        #expect(HookFeed.word(book.sessions["claude|s1"]?.state) == "working")
    }

    /// Fix 1: Claude's PostToolUseFailure (a tool that ran and failed) is
    /// activity for that tool, and answers the block raised for it.
    @Test func aFailedToolAnswersItsPermission() {
        let run = playAt(.claude, [
            (0, "PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "npm test"]]),
            (4 * second, "PostToolUseFailure", ["tool_name": "Bash", "tool_input": ["command": "npm test"], "error": "exit 1"]),
        ])
        #expect(run.states == ["blocked:permission", "working"])
        let installed = AgentID.claude.spec.hooks.events.map(\.name)
        #expect(installed.contains("PostToolUseFailure"))
        #expect(!installed.contains("PermissionDenied"), "its output can ask for a retry")
    }

    /// Fix 9: Claude's AskUserQuestion says the question, ExitPlanMode the
    /// plan — not the tool's name.
    @Test func claudeAsksSayWhatIsAsked() {
        let question = HookFeed.write(.claude, "PermissionRequest", [
            "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [["question": "Which database should the cache use?", "header": "DB"]]],
        ], at: t0).lines.first
        #expect(question?.kind == "question")
        #expect(question?.message == "Which database should the cache use?")
        #expect(question?.tool == "AskUserQuestion")
        let plan = HookFeed.write(.claude, "PermissionRequest", [
            "tool_name": "ExitPlanMode",
            "tool_input": ["plan": "## Move the cache to Redis\n\n1. Add the client\n2. Swap the store"],
        ], at: t0).lines.first
        #expect(plan?.kind == "permission")
        #expect(plan?.message == "Move the cache to Redis")
    }

    /// Fix 9: a generic ask first (Claude's Notification can land before
    /// its PermissionRequest), the specific one after: the specific one
    /// wins, the first clock stays. The other way round keeps the first.
    @Test func aMoreSpecificReRaiseReplacesAGenericAsk() {
        let run = playAt(.claude, [
            (0, "Notification", ["notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash"]),
            (2 * second, "PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "npm test"]]),
        ])
        guard case .blocked(let block) = run.book.sessions["claude|s1"]?.state else {
            Issue.record("not blocked")
            return
        }
        #expect(block.ask == "Bash: npm test")
        #expect(block.tool == "Bash")
        #expect(block.sinceMs == t0)
        #expect(SessionBook.askSpecificity("", tool: "") == 0)
        #expect(SessionBook.askSpecificity("Bash", tool: "Bash") == 1)
        #expect(SessionBook.askSpecificity("Claude needs your input", tool: "") == 1)
        #expect(SessionBook.askSpecificity("Which database?", tool: "AskUserQuestion") == 2)
    }

    /// Fix 5: the first event that names a pid is the clock a reused pid is
    /// judged against.
    @Test func theBookRemembersWhenItFirstHeardAPid() {
        var book = SessionBook()
        book.apply(AttentionRecord(agent: "claude", kind: "start", ms: t0, session: "s1", pid: 500), nowMs: t0)
        book.apply(AttentionRecord(agent: "claude", kind: "tool", ms: t0 + minute, session: "s1", pid: 500, tool: "Read"), nowMs: t0 + minute)
        #expect(book.sessions["claude|s1"]?.pidSinceMs == t0)
        // A resume in a new process: the new pid's clock starts again.
        book.apply(AttentionRecord(agent: "claude", kind: "start", ms: t0 + 2 * minute, session: "s1", pid: 600), nowMs: t0 + 2 * minute)
        #expect(book.sessions["claude|s1"]?.pid == 600)
        #expect(book.sessions["claude|s1"]?.pidSinceMs == t0 + 2 * minute)
        // A reused pid ends the session like a dead one.
        book.endSessions(whoseProcessIsGone: { session in
            !AgentProcesses.stillRuns(
                agent: session.agent, since: session.pidSinceMs,
                identity: AgentProcesses.Identity(args: "/usr/bin/vim notes.md", startedMs: t0 + 10 * minute)
            )
        })
        #expect(book.sessions["claude|s1"]?.state == .ended(atMs: t0 + 2 * minute))
        #expect(book.livePids.isEmpty)
    }

    /// Fix 10: a pid of 1 (the hook's parent had exited) is never a
    /// session's process.
    @Test func pidOneIsUnknown() {
        var book = SessionBook()
        book.apply(AttentionRecord(agent: "claude", kind: "working", ms: t0, session: "s1", pid: 1), nowMs: t0)
        #expect(book.sessions["claude|s1"]?.pid == 0)
        #expect(book.livePids.isEmpty)
        #expect(AttentionRecord(agent: "claude", kind: "working", ms: t0, pid: 1).line.split(separator: "\t", omittingEmptySubsequences: false)[7] == "")
        #expect(AttentionProtocol.parsePid("1") == 0)
        #expect(AttentionProtocol.parsePid("4242") == 4242)
    }

    @Test func aStampFromTheFutureIsRefused() {
        var book = SessionBook()
        let changed8 = book.apply(AttentionRecord(agent: "claude", kind: "permission", ms: t0 + 60 * minute, session: "s1"), nowMs: t0)
        #expect(!changed8)
    }

    @Test func aStartMidWorkKeepsItWorking() {
        var book = SessionBook()
        book.apply(AttentionRecord(agent: "claude", kind: "working", ms: t0, session: "s1"), nowMs: t0)
        book.apply(AttentionRecord(agent: "claude", kind: "start", ms: t0 + 1_000, session: "s1"), nowMs: t0 + 1_000)
        #expect(HookFeed.word(book.sessions["claude|s1"]?.state) == "working")
    }

    @Test func aDayOfSilenceIsForgotten() {
        var book = SessionBook()
        book.apply(AttentionRecord(agent: "claude", kind: "turn", ms: t0, session: "s1"), nowMs: t0)
        let changed9 = book.prune(nowMs: t0 + 60 * minute)
        #expect(!changed9)
        let changed10 = book.prune(nowMs: t0 + SessionBook.retentionMs + 1)
        #expect(changed10)
        #expect(book.sessions.isEmpty)
    }

    // MARK: - Dismissals, errors and status lines

    /// Claude says one approval twice: its PermissionRequest, then its
    /// Notification about six seconds later. A dismissal between the two
    /// stays a dismissal — the echo does not raise the block (or its banner)
    /// again. Work after the dismissal, then a new ask, is a new block.
    @Test func aDismissedAskIsNotRaisedAgainByItsEcho() {
        var book = SessionBook()
        func feed(_ lines: [AttentionRecord], at ms: Int64) {
            for line in lines { book.apply(line, nowMs: ms) }
        }
        feed(HookFeed.write(.claude, "PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "npm test"]], at: t0).lines, at: t0)
        #expect(HookFeed.word(book.sessions["claude|s1"]?.state) == "blocked:permission")
        // The person dismisses it in Pulse: a `done` for the session.
        feed([AttentionRecord(agent: "claude", kind: "done", ms: t0 + 3 * second, session: "s1", cwd: "/Users/me/app")], at: t0 + 3 * second)
        let echo = HookFeed.write(.claude, "Notification", [
            "notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash",
        ], at: t0 + 6 * second).lines
        feed(echo, at: t0 + 6 * second)
        #expect(HookFeed.word(book.sessions["claude|s1"]?.state) == "working", "the echo of a dismissed ask is not a new wait")
        // Work goes on, then a new ask: red again.
        feed(HookFeed.write(.claude, "PostToolUse", ["tool_name": "Read"], at: t0 + 9 * second).lines, at: t0 + 9 * second)
        feed(HookFeed.write(.claude, "PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "rm -rf build"]], at: t0 + 11 * second).lines, at: t0 + 11 * second)
        #expect(HookFeed.word(book.sessions["claude|s1"]?.state) == "blocked:permission")
    }

    /// A vendor's own "resolved" followed at once by a different ask (no
    /// event between: OpenCode asks for the next command) is a new block.
    @Test func aNewAskRightAfterAnAnsweredOneIsRaised() {
        let run = playAt(.opencode, [
            (0, "permission.asked", ["permission": "bash", "patterns": ["ls"]]),
            (2 * second, "permission.replied", [:]),
            (4 * second, "permission.asked", ["permission": "bash", "patterns": ["rm -rf build"]]),
        ])
        #expect(run.states == ["blocked:permission", "working", "blocked:permission"])
    }

    /// OpenCode's error is the session's last error until the next turn
    /// starts — here its next `session.status` busy, since its plugin sends
    /// no prompt. It never outlives the turn it belongs to.
    @Test func aNewTurnClearsTheLastError() {
        var book = SessionBook()
        let steps: [(Int64, String, [String: Any])] = [
            (0, "session.created", [:]),
            (1 * second, "session.status", ["status": ["type": "busy"]]),
            (2 * second, "session.error", ["error": "Model unavailable"]),
            (3 * second, "session.idle", [:]),
        ]
        for (offset, event, payload) in steps {
            for line in HookFeed.write(.opencode, event, payload, at: t0 + offset).lines { book.apply(line, nowMs: t0 + offset) }
        }
        let error = book.sessions["opencode|s1"]?.lastError
        #expect(error == "Model unavailable")
        #expect(HookFeed.word(book.sessions["opencode|s1"]?.state) == "turn")
        let next = t0 + 5 * minute
        for line in HookFeed.write(.opencode, "session.status", ["status": ["type": "busy"]], at: next).lines { book.apply(line, nowMs: next) }
        #expect(HookFeed.word(book.sessions["opencode|s1"]?.state) == "working")
        let cleared = book.sessions["opencode|s1"]?.lastError
        #expect(cleared == "", "the error belonged to the turn before")
    }

    /// A status line — Copilot's recoverable `errorOccurred`, OpenCode's
    /// `session.status` busy or retry — says work goes on, not that the
    /// person answered: the red lamp stays until the vendor's own answer.
    @Test func aStatusLineNeverAnswersABlock() {
        let copilot = playAt(.copilot, [
            (0, "userPromptSubmitted", ["prompt": "Run the tests"]),
            (2 * second, "notification", ["notification_type": "permission_prompt", "message": "Allow bash?"]),
            (4 * second, "errorOccurred", ["recoverable": true, "error": ["message": "Rate limited, retrying"]]),
            (6 * second, "postToolUse", ["toolName": "bash"]),
        ])
        #expect(copilot.states == ["working", "blocked:permission", "blocked:permission", "working"])
        let openCode = playAt(.opencode, [
            (0, "session.status", ["status": ["type": "busy"]]),
            (2 * second, "permission.asked", ["permission": "bash", "patterns": ["npm test"]]),
            (4 * second, "session.status", ["status": ["type": "busy"]]),
            (5 * second, "session.status", ["status": ["type": "retry"]]),
            (7 * second, "permission.replied", [:]),
        ])
        #expect(openCode.states == ["working", "blocked:permission", "blocked:permission", "blocked:permission", "working"])
        let status = HookFeed.write(.copilot, "errorOccurred", ["recoverable": true], at: t0).lines.first
        #expect(status?.kind == "tool")
        #expect(status?.tool == AttentionRecord.statusTool)
        #expect(openCode.book.sessions["opencode|s1"]?.steps.isEmpty == true, "a status is not a step")
    }
}

/// The book as rows: process-only discovery, the time rules, and what the
/// events and a landing add.
@Suite("Tray projection")
struct TrayStateTests {
    let t0: Int64 = 1_800_000_000_000
    let minute: Int64 = 60_000

    private func rows(
        _ book: SessionBook,
        processes: [AgentProcesses.Hit] = [],
        at nowMs: Int64? = nil
    ) -> TrayState.SessionRows {
        TrayState.sessionRows(
            book: book, processes: processes,
            context: TrayState.Context(nowMs: nowMs ?? t0)
        )
    }

    private func book(_ records: [AttentionRecord]) -> SessionBook {
        var book = SessionBook()
        for record in records { book.apply(record, nowMs: record.ms) }
        return book
    }

    @Test func aProcessNoSessionClaimedIsAProcessOnlyRow() throws {
        let hit = AgentProcesses.Hit(agent: .claude, pid: 10, cwd: "/Users/me/app", tty: "ttys004", startedMs: t0 - minute)
        let row = try #require(rows(SessionBook(), processes: [hit]).rows.first)
        #expect(row.rowKey == "claude|pid:10")
        #expect(row.state == .processOnly)
        #expect(row.source == .process)
        #expect(row.project == "app")
        #expect(row.landing.tty == "ttys004")
    }

    @Test func aSessionClaimsItsProcessFamily() {
        let b = book([AttentionRecord(agent: "codex", kind: "working", ms: t0, session: "c1", pid: 11)])
        let hit = AgentProcesses.Hit(agent: .codex, pid: 10, family: [10, 11])
        #expect(rows(b, processes: [hit]).rows.map(\.rowKey) == ["codex|c1"], "the wrapper and its child are one process")
    }

    @Test func aSessionWithNoPidClaimsTheProcessInItsFolder() {
        let b = book([AttentionRecord(agent: "gemini", kind: "working", ms: t0, session: "g1", cwd: "/w/app")])
        let same = AgentProcesses.Hit(agent: .gemini, pid: 20, cwd: "/w/app")
        let other = AgentProcesses.Hit(agent: .gemini, pid: 21, cwd: "/w/other")
        #expect(rows(b, processes: [same, other]).rows.map(\.rowKey).sorted() == ["gemini|g1", "gemini|pid:21"])
    }

    @Test func anEndedSessionClaimsNothing() {
        let b = book([
            AttentionRecord(agent: "claude", kind: "working", ms: t0, session: "s1", pid: 30),
            AttentionRecord(agent: "claude", kind: "end", ms: t0 + 1_000, session: "s1", pid: 30),
        ])
        let hit = AgentProcesses.Hit(agent: .claude, pid: 30)
        #expect(rows(b, processes: [hit]).rows.map(\.rowKey).sorted() == ["claude|pid:30", "claude|s1"])
    }

    @Test func aKnownPidStaysRunningWhileTheProcessLives() throws {
        let b = book([AttentionRecord(agent: "claude", kind: "working", ms: t0, session: "s1", pid: 40)])
        let row = try #require(rows(b, at: t0 + 100 * minute).rows.first)
        #expect(row.state == .running)
        #expect(row.liveProcess)
    }

    @Test func anUnknownPidIsRecentAfterTheIdleBoundAndSaysWhy() throws {
        let b = book([AttentionRecord(agent: "claude", kind: "working", ms: t0, session: "s1")])
        #expect(rows(b, at: t0 + 29 * minute).rows.first?.state == .running)
        let row = try #require(rows(b, at: t0 + 31 * minute).rows.first)
        #expect(row.state == .recent)
        #expect(row.recentReason == .quiet)
        #expect(row.stateSinceMs == t0 + TrayState.idleBoundMs)
        let why = TrayRowModel.why(row, lang: .en, nowMs: t0 + 31 * minute)
        #expect(why.contains("no process to watch"), "\(why)")
    }

    @Test func aTurnIsOwedForHalfAnHour() throws {
        let b = book([AttentionRecord(agent: "codex", kind: "turn", ms: t0, session: "c1", pid: 50)])
        #expect(rows(b, at: t0 + 10 * minute).rows.first?.isYourTurn == true)
        let row = try #require(rows(b, at: t0 + 31 * minute).rows.first)
        #expect(row.state == .recent)
        #expect(row.recentReason == .atPrompt)
    }

    @Test func aRecentSessionLeavesTheListAndIsCountedForADay() {
        let b = book([
            AttentionRecord(agent: "claude", kind: "working", ms: t0, session: "s1"),
            AttentionRecord(agent: "claude", kind: "end", ms: t0 + minute, session: "s1"),
        ])
        #expect(rows(b, at: t0 + 30 * minute).rows.count == 1)
        let later = rows(b, at: t0 + 60 * minute)
        #expect(later.rows.isEmpty)
        #expect(later.staleHidden == [.claude: 1])
        #expect(rows(b, at: t0 + 25 * 60 * minute).staleHidden.isEmpty, "a session that went quiet yesterday is not news")
    }

    /// Fix 6: one Cursor IDE or OpenCode server process runs many
    /// sessions all day. Its live pid keeps a working or blocked session
    /// listed — never one that is idle, whose turn aged out, or that is
    /// recent: those leave after the recent window like any other.
    @Test func aLiveProcessKeepsOnlyWorkOrAWaitListed() throws {
        let b = book([
            AttentionRecord(agent: "opencode", kind: "start", ms: t0, session: "o1", pid: 60),
            AttentionRecord(agent: "opencode", kind: "turn", ms: t0, session: "o2", pid: 60),
            AttentionRecord(agent: "opencode", kind: "working", ms: t0, session: "o3", pid: 60),
            AttentionRecord(agent: "opencode", kind: "permission", ms: t0, message: "bash: ls", session: "o4", pid: 60),
        ])
        let early = rows(b, at: t0 + 40 * minute)
        #expect(early.rows.count == 4, "inside the recent window every one is listed")
        let later = rows(b, at: t0 + 100 * minute)
        let keys = later.rows.map(\.rowKey).sorted()
        #expect(keys == ["opencode|o3", "opencode|o4"])
        #expect(later.staleHidden == [.opencode: 2])
        let live = later.rows.filter { $0.liveProcess }.count
        #expect(live == 2)
    }

    /// Fix 7: an interrupted turn sends no Stop. From an agent that reports
    /// its tools, silence is a stall for a while — then, past
    /// `silentBoundMs`, the session is recent and says why: never an
    /// endless orange.
    @Test func anInterruptedTurnStallsThenGoesQuiet() throws {
        let b = book([
            AttentionRecord(agent: "claude", kind: "working", ms: t0, session: "s1", pid: 41),
            AttentionRecord(agent: "claude", kind: "tool", ms: t0 + minute, session: "s1", pid: 41, tool: "Bash"),
        ])
        let stalled = try #require(rows(b, at: t0 + 30 * minute).rows.first)
        #expect(stalled.state == .running)
        #expect(stalled.isStalled)
        let silent = t0 + minute + TrayState.silentBoundMs + minute
        let row = try #require(rows(b, at: silent).rows.first)
        #expect(row.state == .recent)
        #expect(!row.isStalled)
        #expect(row.recentReason == .silent)
        #expect(row.stateSinceMs == t0 + minute + TrayState.silentBoundMs)
        let why = TrayRowModel.why(row, lang: .en, nowMs: silent)
        #expect(why.hasPrefix("Nothing heard for"), "\(why)")
        #expect(rows(b, at: silent + TrayState.recentWindowMs).rows.isEmpty, "and it leaves the list, process or not")
    }

    /// Everything a row says about its session comes from the events: the
    /// title (the first prompt), the last words (the turn), the error (a
    /// failed turn), the steps and the turn's clock. No file is read.
    @Test func theEventsFillTheRow() throws {
        let b = book([
            AttentionRecord(agent: "claude", kind: "working", ms: t0, message: "Fix the login test", session: "s1", pid: 70),
            AttentionRecord(agent: "claude", kind: "tool", ms: t0 + minute, message: "Tests/LoginTests.swift", session: "s1", pid: 70, tool: "Read"),
            AttentionRecord(agent: "claude", kind: "tool", ms: t0 + 2 * minute, message: "swift test", session: "s1", pid: 70, tool: "Bash"),
            AttentionRecord(agent: "claude", kind: "turn", ms: t0 + 3 * minute, message: "All green.", session: "s1", pid: 70),
            AttentionRecord(agent: "claude", kind: "working", ms: t0 + 4 * minute, message: "Ship it", session: "s1", pid: 70),
            AttentionRecord(agent: "claude", kind: "tool", ms: t0 + 5 * minute, message: "git push", session: "s1", pid: 70, tool: "Bash"),
        ])
        let row = try #require(rows(b, at: t0 + 6 * minute).rows.first)
        #expect(row.task == "Fix the login test")
        #expect(row.lastWord == "All green.")
        #expect(row.lastStep == SessionBook.Step(tool: "Bash", target: "git push", ms: t0 + 5 * minute))
        #expect(row.recentSteps.count == 3)
        #expect(row.turnStartMs == t0 + 4 * minute)
        #expect(row.lastErrorText == "")
    }

    /// Cursor and OpenCode activity names no tool: their rows have no steps.
    @Test func anAgentWhoseHookNamesNoToolHasNoSteps() throws {
        let b = book([
            AttentionRecord(agent: "cursor", kind: "working", ms: t0, session: "cu1", pid: 72),
            AttentionRecord(agent: "cursor", kind: "tool", ms: t0 + minute, session: "cu1", pid: 72),
        ])
        let row = try #require(rows(b, at: t0 + 2 * minute).rows.first)
        #expect(row.lastStep == nil)
        #expect(row.recentSteps.isEmpty)
    }

    @Test func withoutATranscriptTheTurnSaysTheLastWords() throws {
        let b = book([AttentionRecord(agent: "opencode", kind: "turn", ms: t0, message: "Queue drains on reconnect", session: "o1", pid: 71)])
        #expect(try #require(rows(b).rows.first).lastWord == "Queue drains on reconnect")
    }

    @Test func theLandingNamesTheTerminal() throws {
        let b = book([AttentionRecord(agent: "claude", kind: "working", ms: t0, session: "s1", pid: 0, landing: "tmux:%3;tty:/dev/ttys009;term:WarpTerminal")])
        let row = try #require(rows(b).rows.first)
        #expect(row.landing.tmuxPane == "%3")
        #expect(row.landing.tty == "ttys009")
        #expect(row.landing.term == "WarpTerminal")
        #expect(row.landingPlan.steps.first == LandingStep.tmuxPane(pane: "%3", socket: "", hostBundleIDs: ["dev.warp.Warp-Stable", "dev.warp.Warp"]))
        #expect(row.landingPlan.precision == .exact)
    }

    @Test func aStallNeedsAnAgentThatReportsItsWork() throws {
        var b = book([AttentionRecord(agent: "codex", kind: "working", ms: t0, session: "c1", pid: 80)])
        #expect(try #require(rows(b, at: t0 + 40 * minute).rows.first).isStalled == false, "no activity events: silence is not evidence")
        b.apply(AttentionRecord(agent: "codex", kind: "tool", ms: t0 + minute, session: "c1"), nowMs: t0 + minute)
        #expect(try #require(rows(b, at: t0 + 40 * minute).rows.first).isStalled)
    }

    /// Only an agent whose hook reports every tool call can be
    /// stalled. Cursor and OpenCode speak at a prompt and at the end of a
    /// reply; a long turn is silent, and silence from them is not evidence.
    @Test func aLongTurnIsNotAStallForAnAgentWithoutToolEvents() throws {
        #expect(AgentID.claude.reportsToolActivity)
        #expect(AgentID.codex.reportsToolActivity)
        #expect(AgentID.gemini.reportsToolActivity)
        #expect(AgentID.copilot.reportsToolActivity)
        #expect(AgentID.pi.reportsToolActivity)
        #expect(!AgentID.cursor.reportsToolActivity)
        #expect(!AgentID.opencode.reportsToolActivity)
        for agent in [AgentID.cursor, .opencode] {
            var b = book([AttentionRecord(agent: agent.rawValue, kind: "working", ms: t0, session: "x1", pid: 81)])
            b.apply(AttentionRecord(agent: agent.rawValue, kind: "tool", ms: t0 + minute, session: "x1"), nowMs: t0 + minute)
            let row = try #require(rows(b, at: t0 + 40 * minute).rows.first)
            #expect(row.state == .running)
            #expect(!row.isStalled, "\(agent.rawValue)")
        }
    }

    @Test func aBlockedRowCarriesTheProtocolToken() throws {
        let b = book([AttentionRecord(agent: "pi", kind: "question", ms: t0, message: "Which branch?", session: "p1", pid: 90)])
        let wait = try #require(rows(b).rows.first?.wait)
        #expect(wait.kind == "Input")
        #expect(wait.ask == "Which branch?")
        #expect(wait.sinceMs == t0)
    }
}

/// Rows in, the tray out: the order, the window, the lamp, the title and
/// the Waiting edges.
final class TrayAssembleTests: XCTestCase {
    private let now: Int64 = 1_700_000_000_000

    private func row(_ key: String, _ agent: AgentID = .claude, state: RowState = .running, task: String = "") -> AgentRow {
        var r = AgentRow(rowKey: key, agent: agent)
        r.sessionID = key
        r.task = task
        r.state = state
        r.lastEventMs = now - 1_000
        return r
    }

    private func blocked(_ key: String, sinceAgoMs: Int64 = 10 * 60_000) -> AgentRow {
        row(key, state: .blocked(RowWait(kind: "Permission", ask: "Bash: make", sinceMs: now - sinceAgoMs)))
    }

    private func build(
        _ rows: [AgentRow],
        staleHidden: [AgentID: Int] = [:],
        previousWaits: [String: Int64] = [:],
        showAll: Bool = false,
        maxRows: Int = TrayState.maxVisibleRows
    ) -> TrayState {
        TrayState.assemble(
            rows: rows, staleHidden: staleHidden,
            context: TrayState.Context(
                nowMs: now, lang: .en, maxVisibleRows: maxRows, showAllAgents: showAll, previousWaits: previousWaits
            )
        )
    }

    func testNothingAtAllIsIdleNotError() {
        let r = build([])
        XCTAssertTrue(r.rows.isEmpty)
        XCTAssertEqual(r.snapshot.glance, .idle)
        XCTAssertEqual(r.activity, .empty)
    }

    func testWaitingSortsAboveEverythingElse() {
        let r = build([row("a", task: "Titled"), blocked("b")])
        XCTAssertEqual(r.rows.map(\.rowKey), ["b", "a"])
        XCTAssertEqual(r.snapshot.glance, .waiting)
        XCTAssertEqual(r.activity, .waiting)
    }

    func testWaitingRowsAreOrderedOldestFirst() {
        let r = build([blocked("new", sinceAgoMs: 60_000), blocked("old", sinceAgoMs: 600_000)])
        XCTAssertEqual(r.rows.map(\.rowKey), ["old", "new"])
    }

    func testMenuBarTitleCarriesCountAndAge() {
        XCTAssertEqual(build([blocked("a")]).snapshot.title, "1 · 10m")
        XCTAssertEqual(build([blocked("a", sinceAgoMs: 1_000)]).snapshot.title, "1", "a fresh wait does not spend space on now")
    }

    func testNothingBlockedMeansNoTitle() {
        XCTAssertEqual(build([row("a")]).snapshot.title, "")
        XCTAssertEqual(build([row("a")]).snapshot.glance, .running)
    }

    func testProcessOnlyRunningIsAGreyDottedGlance() {
        let r = build([row("claude|pid:1", state: .processOnly)])
        XCTAssertEqual(r.snapshot.glance, .idle)
        XCTAssertEqual(r.snapshot.lamp, LampFace(shape: .dotted, tone: .idle))
        XCTAssertEqual(r.activity, .recent, "a bare process does not hold the running tick")
    }

    func testAFinishedTurnIsNotRunning() {
        let r = build([row("a", state: .yourTurn(sinceMs: now - 60_000))])
        XCTAssertEqual(r.snapshot.glance, .idle)
        XCTAssertEqual(r.activity, .recent)
    }

    func testRowsFoldAtTheVisibleLimit() {
        let r = build((0..<5).map { row("k\($0)") }, maxRows: 3)
        XCTAssertEqual(r.snapshot.rows.count, 3)
        XCTAssertEqual(r.snapshot.hiddenCount, 2)
        XCTAssertEqual(r.snapshot.totalCount, 5)
    }

    func testShowAllCollapsesOnceTheListIsShortAgain() {
        XCTAssertTrue(build((0..<5).map { row("k\($0)") }, showAll: true, maxRows: 3).showAllAgents)
        XCTAssertFalse(build((0..<2).map { row("k\($0)") }, showAll: true, maxRows: 3).showAllAgents)
    }

    func testCountsCoverTheWholeListNotTheWindow() {
        let r = build([blocked("w")] + (0..<4).map { row("k\($0)") }, maxRows: 2)
        XCTAssertEqual(r.snapshot.counts.blocked, 1)
        XCTAssertEqual(r.snapshot.counts.running, 4)
        XCTAssertEqual(r.snapshot.headerTitle, r.snapshot.counts.summary(.en))
    }

    func testFirstSightOfAWaitIsReportedAsNew() {
        XCTAssertEqual(build([blocked("a")]).newlyBlocked.map(\.rowKey), ["a"])
    }

    func testAWaitAlreadyKnownIsNotReportedAgain() {
        let wait = blocked("a")
        XCTAssertTrue(build([wait], previousWaits: ["a": wait.wait?.sinceMs ?? 0]).newlyBlocked.isEmpty)
    }

    func testASecondAskOnAWaitingRowIsANewEdge() {
        let second = build([blocked("a", sinceAgoMs: 30_000)], previousWaits: ["a": now - 120_000])
        XCTAssertEqual(second.newlyBlocked.map(\.rowKey), ["a"])
    }

    /// The next projection's `previousWaits`: when each open wait was raised.
    func testTheOpenWaitsAreHandedOn() {
        let r = build([blocked("a", sinceAgoMs: 60_000), row("b")])
        XCTAssertEqual(r.waitingSince, ["a": now - 60_000])
        XCTAssertTrue(build([row("a")], previousWaits: ["a": now - 60_000]).waitingSince.isEmpty, "a resolved wait is gone")
    }

    /// "N older not shown" counts only sessions that went quiet
    /// within the last day — the projection's count, carried to the snapshot.
    func testStaleHiddenCountsOnlyTheLastDay() {
        var book = SessionBook()
        let minute: Int64 = 60_000
        book.apply(AttentionRecord(agent: "claude", kind: "end", ms: now - 2 * 60 * minute, session: "x"), nowMs: now)
        book.apply(AttentionRecord(agent: "claude", kind: "working", ms: now - 3 * 60 * minute, session: "y"), nowMs: now)
        book.apply(AttentionRecord(agent: "codex", kind: "working", ms: now - 30 * 60 * minute, session: "z"), nowMs: now)
        let r = TrayState.project(
            book: book, processes: [],
            context: TrayState.Context(nowMs: now, lang: .en)
        )
        XCTAssertEqual(r.snapshot.staleHidden, 1, "the end line made no session; y went quiet today; z yesterday")
        XCTAssertEqual(r.snapshot.staleHiddenAgents, [.claude])
    }

    func testTheGlanceTooltipIsInTheResolvedLanguage() {
        let en = TrayState.assemble(rows: [blocked("a")], context: .init(nowMs: now, lang: .en)).snapshot.tooltip
        let zh = TrayState.assemble(rows: [blocked("a")], context: .init(nowMs: now, lang: .zh)).snapshot.tooltip
        XCTAssertNotEqual(en, zh)
    }
}

/// A row's key is decided once and never changes.
@Suite("Row identity")
struct RowIdentityTests {
    @Test func eachKindOfRowHasItsOwnKey() {
        #expect(RowIdentity.session(agent: .claude, session: "abc") == "claude|abc")
        #expect(RowIdentity.process(agent: .codex, pid: 7) == "codex|pid:7")
        #expect(RowIdentity.session(agent: .claude, session: "", cwd: "/w").hasPrefix("claude|hook:"))
    }

    @Test func theHashIsStableAcrossLaunches() {
        #expect(RowIdentity.stableHash("/Users/me/app") == RowIdentity.stableHash("/Users/me/app"))
        #expect(RowIdentity.stableHash("/Users/me/app") != RowIdentity.stableHash("/Users/me/other"))
        #expect(!RowIdentity.session(agent: .claude, session: "", cwd: "/Users/me/app").contains("/Users"), "a key never carries a path")
    }

    /// The session's key comes from its first event and every later event
    /// finds the same session — a start, a prompt, a turn.
    @Test func everyEventOfASessionFindsTheSameKey() {
        var book = SessionBook()
        let t0: Int64 = 1_800_000_000_000
        for (index, kind) in ["start", "working", "permission", "turn"].enumerated() {
            book.apply(AttentionRecord(agent: "claude", kind: kind, ms: t0 + Int64(index) * 60_000, session: "abc", cwd: "/w/\(index)"), nowMs: t0 + 600_000)
        }
        #expect(Array(book.sessions.keys) == ["claude|abc"])
        #expect(book.sessions["claude|abc"]?.cwd == "/w/3", "facts move; the key does not")
    }

    /// A process-only row simply is not built once a hook names the
    /// session that process runs.
    @Test func whenTheSessionSpeaksTheProcessRowSimplyGoes() {
        let t0: Int64 = 1_800_000_000_000
        let hit = AgentProcesses.Hit(agent: .claude, pid: 4242, cwd: "/w/app")
        let context = TrayState.Context(nowMs: t0)
        var book = SessionBook()
        let before = TrayState.project(book: book, processes: [hit], context: context).rows.map(\.rowKey)
        #expect(before == ["claude|pid:4242"])
        book.apply(AttentionRecord(agent: "claude", kind: "working", ms: t0, session: "abc", pid: 4242), nowMs: t0)
        let after = TrayState.project(book: book, processes: [hit], context: context).rows.map(\.rowKey)
        #expect(after == ["claude|abc"])
    }
}

/// Row presentation rules from EXPERIENCE.md.
final class AgentRowTests: XCTestCase {
    private func row(_ mutate: (inout AgentRow) -> Void) -> AgentRow {
        var r = AgentRow(rowKey: "claude|s1", agent: .claude)
        mutate(&r)
        return r
    }

    func testPlaceholderTitlesAreNotTreatedAsSessions() {
        for junk in [
            "-", "—", "Running", "Active", "none", "Agent session", "Chat",
            "Cursor session", "OpenCode session", "Gemini session", "Pi session",
        ] {
            let r = row { $0.task = junk }
            XCTAssertNil(r.usefulTask, "\(junk) is not a real session title")
        }
    }

    func testBarePathIsNotASessionTitle() {
        XCTAssertNil(row { $0.task = "/Users/me/code" }.usefulTask)
        XCTAssertNotNil(row { $0.task = "/Users/me fix the parser" }.usefulTask)
    }

    func testMarkdownLinksBecomeReadablePlainTitles() {
        let raw = "[hxddh/Pulse](https://github.com/hxddh/Pulse) 本地有安装最新版"
        let r = row { $0.task = raw }
        XCTAssertEqual(r.usefulTask, "hxddh/Pulse 本地有安装最新版")
        XCTAssertEqual(r.task, raw, "presentation cleanup must not rewrite evidence")
    }

    func testMarkdownImageSyntaxDoesNotLeakIntoTheTray() {
        XCTAssertEqual(
            row { $0.task = "Inspect ![failure](file:///tmp/failure.png)" }.usefulTask,
            "Inspect failure"
        )
    }

    func testInternalToolIdentifiersAreNotSessionTitles() {
        XCTAssertNil(row { $0.task = "update_plan" }.usefulTask)
        XCTAssertEqual(row { $0.task = "update_auth" }.usefulTask, "update_auth")
        XCTAssertNil(row { $0.task = "Read Models.swift" }.usefulTask)
        XCTAssertNil(row { $0.task = "Models.swift" }.usefulTask)
        XCTAssertNotNil(row { $0.task = "Improve tray density" }.usefulTask)
    }

    func testShortProjectDropsOpaqueHashes() {
        XCTAssertEqual(AgentRow.shortProject("/Users/me/code/Pulse"), "Pulse")
        XCTAssertEqual(AgentRow.shortProject("a1b2c3d4e5f60718"), "", "hash is not a project name")
        XCTAssertEqual(AgentRow.shortProject(""), "")
    }

    func testLongProjectNamesAreTruncated() {
        let long = String(repeating: "x", count: 40)
        let short = AgentRow.shortProject(long)
        XCTAssertLessThanOrEqual(short.count, 24)
        XCTAssertTrue(short.hasSuffix("…"))
    }
}

/// One fact is stated once — screenshots once showed it three and four times over.
final class RowRedundancyTests: XCTestCase {
    private func row(agent: AgentID, task: String = "", project: String = "") -> AgentRow {
        var r = AgentRow(rowKey: "k", agent: agent)
        r.task = task
        r.project = project
        r.liveProcess = true
        r.state = .running
        return r
    }

    /// `Cursor · Cursor` — the dedupe compared the project to the hero only.
    func testProjectThatRestatesTheAgentIsDropped() {
        let r = row(agent: .cursor, task: "Pulse installation guide", project: "Cursor")
        XCTAssertEqual(AgentRow.shortProject(r.project), "Cursor")
        XCTAssertEqual(r.agent.displayName, "Cursor")
    }

    /// A bare process row said "Process detected", "process", and the agent's name.
    func testProcessOnlyRowHasNoSessionTitleToShow() {
        var r = row(agent: .codex)
        r.state = .processOnly
        XCTAssertNil(r.usefulTask)
        // Hero must not fall back to the agent product name (already on identity).
        let hero = TrayRowModel.headline(r, lang: .en, nowMs: 1_700_000_000_000)
        XCTAssertNotEqual(hero, r.agent.displayName)
    }

    func testEveryAgentDropsItsOwnGenericSessionPlaceholder() {
        for agent in AgentID.allCases {
            var r = row(agent: agent, task: "\(agent.displayName) session")
            r.sessionID = "real-id"
            XCTAssertNil(r.usefulTask, "\(agent.displayName) placeholder escaped as a task")
        }
    }

    func testEveryAgentDropsItsOwnBareDisplayName() {
        for agent in AgentID.allCases {
            var r = row(agent: agent, task: agent.displayName)
            r.sessionID = "real-id"
            XCTAssertNil(r.usefulTask, "\(agent.displayName) alone is identity, not a goal")
        }
    }
}

/// The two facts a row could never state, both collected from the start.
final class RowContextTests: XCTestCase {
    private func row(cwd: String = "", project: String = "", eventMs: Int64 = 0) -> AgentRow {
        var r = AgentRow(rowKey: "k", agent: .claude)
        r.cwd = cwd
        r.project = project
        r.lastEventMs = eventMs
        return r
    }

    /// Home itself is not a location worth naming; anything under it is.
    func testPathsUnderHomeUseTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(row(cwd: home).displayPath, "", "home is not a project")
        XCTAssertEqual(row(cwd: home + "/code").displayPath, "~/code")
    }

    /// The middle of a deep path carries no identity; the tail does.
    func testDeepPathsKeepTheirTail() {
        let p = row(cwd: "/a/b/c/d/e/Pulse").displayPath
        XCTAssertTrue(p.hasSuffix("e/Pulse"), p)
        XCTAssertTrue(p.contains("…"), p)
    }

    func testShallowPathsAreLeftAlone() {
        XCTAssertEqual(row(cwd: "/tmp/alpha").displayPath, "/tmp/alpha")
    }

    func testNoLocationYieldsNoPathRatherThanAPlaceholder() {
        XCTAssertEqual(row().displayPath, "")
    }

    func testProjectIsUsedWhenThereIsNoCwd() {
        XCTAssertEqual(row(project: "Pulse").displayPath, "Pulse")
    }

    func testUnknownActivityIsZeroNotEpoch() {
        XCTAssertEqual(row().lastActivitySeconds(at: 1_700_000_000_000), 0)
    }

    func testActivityAgeCountsFromTheLastEvent() {
        let now: Int64 = 1_700_000_000_000
        XCTAssertEqual(row(eventMs: now - 600_000).lastActivitySeconds(at: now), 600, accuracy: 0.001)
    }
}

/// Each of these is a defect once visible in a screenshot.
final class RowPresentationTests: XCTestCase {
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    private func row(cwd: String = "", project: String = "", eventMs: Int64 = 0, live: Bool = false) -> AgentRow {
        var r = AgentRow(rowKey: "k", agent: .claude)
        r.cwd = cwd
        r.project = project
        r.lastEventMs = eventMs
        r.liveProcess = live
        r.state = live ? .running : .recent
        return r
    }

    /// The panel grouped two sessions under "~" and a third under
    /// "users-rustjia" — the same directory, twice, and a header claiming
    /// three projects where there were two.
    func testHomeIsNotAProject() {
        XCTAssertEqual(row(cwd: home).displayPath, "")
        XCTAssertEqual(row(project: "~").displayPath, "")
    }

    func testEncodedHomeCollapsesToTheSamePlaceAsHome() {
        let user = (home as NSString).lastPathComponent
        XCTAssertTrue(AgentRow.isHomeLike("users-\(user)", home: home))
        XCTAssertTrue(AgentRow.isHomeLike(user, home: home))
        XCTAssertEqual(row(project: "users-\(user)").displayPath, "")
    }

    func testARealProjectIsStillAProject() {
        XCTAssertEqual(row(cwd: home + "/Documents/Cursor").displayPath, "~/Documents/Cursor")
        XCTAssertFalse(AgentRow.isHomeLike("/tmp/alpha", home: home))
    }

    /// "New Session" was shown as a row title.
    func testPlaceholderTitlesAreNotTitles() {
        for junk in ["New Session", "Untitled", "New Chat", "Agent session"] {
            var r = row()
            r.task = junk
            XCTAssertNil(r.usefulTask, "\(junk) is a placeholder, not a task")
        }
    }

    /// Live for twenty minutes with nothing happening looked like health.
    ///
    /// Evaluated against the scan's clock, so these pass an explicit `nowMs`
    /// rather than depending on when the suite happens to run.
    private let now: Int64 = 1_700_000_000_000

    private func stalled(agoSeconds: Double) -> Bool {
        AgentRow.stalled(lastActivityMs: now - Int64(agoSeconds * 1000), nowMs: now)
    }

    func testLongSilenceWhileLiveIsStalled() {
        XCTAssertTrue(stalled(agoSeconds: 25 * 60))
    }

    func testRecentActivityIsNotStalled() {
        XCTAssertFalse(stalled(agoSeconds: 60))
    }

    func testUnknownActivityIsNotStalled() {
        XCTAssertFalse(
            AgentRow.stalled(lastActivityMs: 0, nowMs: now),
            "no timestamp is not evidence of silence"
        )
    }

    /// A stalled row is one the user should react to: an orange ring, and
    /// its why on a second line (no badge).
    func testStalledRowsSayWhy() {
        var r = row(eventMs: now - 25 * 60 * 1000, live: true)
        r.isStalled = true
        let face = TrayRowModel.make(TrayRowModel.Input(row: r, lang: .en, nowMs: now))
        XCTAssertEqual(face.lamp, LampFace(shape: .ring, tone: .attention))
        XCTAssertEqual(face.secondLine?.kind, .warning)
        XCTAssertEqual(face.secondLine?.text, face.why)
    }
}

/// The stall threshold used to be compiled in at twenty minutes.
final class StallThresholdTests: XCTestCase {
    private let now: Int64 = 1_700_000_000_000

    private func stalled(agoSeconds: Double, threshold: Double) -> Bool {
        AgentRow.stalled(lastActivityMs: now - Int64(agoSeconds * 1000), nowMs: now, threshold: threshold)
    }

    func testAShorterThresholdCatchesAShorterSilence() {
        XCTAssertTrue(stalled(agoSeconds: 6 * 60, threshold: 5 * 60))
        XCTAssertFalse(stalled(agoSeconds: 6 * 60, threshold: 20 * 60))
    }

    /// "Never" must read as never stalled, not as always stalled.
    func testZeroDisablesRatherThanTripping() {
        XCTAssertFalse(stalled(agoSeconds: 10 * 60 * 60, threshold: 0))
        XCTAssertFalse(stalled(agoSeconds: 10 * 60 * 60, threshold: -1))
    }

    func testTheDefaultIsUnchanged() {
        XCTAssertEqual(AgentRow.stalledSeconds, 20 * 60)
        XCTAssertTrue(stalled(agoSeconds: 21 * 60, threshold: AgentRow.stalledSeconds))
    }
}

/// A vendor placeholder title is chrome, whatever its case — one list.
final class ChromeVocabularyTests: XCTestCase {
    // MARK: - One chrome vocabulary, not three

    /// `usefulTask` once had its own case-sensitive copy of the list.
    @MainActor
    func testChromeTitlesAreRejectedWhateverTheirCase() {
        for title in ["Copilot session", "COPILOT SESSION", "copilot session",
                      "New Chat", "new chat", "Running", "running", "  Untitled  "] {
            var row = AgentRow(rowKey: "k", agent: .copilot)
            row.task = title
            XCTAssertNil(row.usefulTask, "\(title) is not a user goal")
        }
    }

    /// One list, case-insensitive: every entry is chrome in either case,
    /// and none reaches a row as a goal.
    @MainActor
    func testCollectorAndRowShareOneVocabulary() {
        for title in TitleHeuristics.chromeTitles {
            XCTAssertTrue(
                AgentRow.isChromeTitle(title.uppercased()),
                "\(title) must be chrome in either case"
            )
            var row = AgentRow(rowKey: "k", agent: .claude)
            row.task = title
            XCTAssertNil(row.usefulTask, "\(title) reached a row as a goal")
        }
    }

    func testARealGoalIsNotMistakenForChrome() {
        XCTAssertFalse(AgentRow.isChromeTitle("Auth session"))
        XCTAssertFalse(AgentRow.isChromeTitle("Fix the tray hero"))
    }
}
