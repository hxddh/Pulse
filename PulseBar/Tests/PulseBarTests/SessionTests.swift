import Foundation
import Testing
import XCTest
@testable import PulseApp
@testable import PulseKit

// Sessions: the event reducer (SessionBook), its projection into the tray
// (TrayState), row identity, and what a row carries.

/// In tests a key may be written as its description — `"claude|s1"`,
/// `"codex|pid:7"`, `"claude|hook:<hash>"` — or as a bare id, a Claude
/// session (`"a"`).
extension SessionKey: ExpressibleByStringLiteral {
    public init(stringLiteral text: String) {
        let parts = text.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let agent = AgentID(rawValue: parts[0]) else {
            self.init(.claude, text)
            return
        }
        let id = parts[1]
        if id.hasPrefix("pid:"), let pid = Int32(id.dropFirst(4)) {
            self.init(agent: agent, scope: .process(pid))
        } else if id.hasPrefix("hook:") {
            self.init(agent: agent, scope: .folder(String(id.dropFirst(5))))
        } else {
            self.init(agent, id)
        }
    }
}

/// One vendor hook event as `pulse-hook` writes it — one v8 line, or none
/// when the receiver would write an `ignored` one (the book skips those) —
/// by the receiver's own reading of the vendor's event name and payload
/// (`PulseHookReceiver.record`). The truth tables below replay recorded
/// sequences through it.
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
        var full = payload
        full["session_id"] = session
        full["cwd"] = cwd
        var record = PulseHookReceiver.record(agent: agent, event: event, payload: full, nowMs: ms)
        guard record.kind != .ignored else { return Written() }
        record.pid = pid
        if record.kind.isOpen { record.front = front }
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
            states.append(HookFeed.word(book.sessions[SessionKey(agent, "s1")]?.state))
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
        guard case .blocked(let block) = book.sessions[SessionKey(.claude, "s1")]?.state else {
            Issue.record("not blocked")
            return
        }
        #expect(block.ask == "Bash: npm test")
        #expect(block.sinceMs == t0)
    }

    /// Codex never says it waits: a PermissionRequest is not installed and
    /// is not read.
    @Test func codex() {
        let run = play(.codex, [
            ("SessionStart", [:]),
            ("UserPromptSubmit", ["prompt": "Add a queue"]),
            ("PermissionRequest", ["tool_name": "shell"]),
            ("Stop", [:]),
            ("SessionEnd", [:]),
        ])
        #expect(run.states == ["idle", "working", "working", "turn", "ended"])
    }

    /// Cursor never says it waits: its `before*` hooks gate, and are not
    /// installed.
    @Test func cursor() {
        let run = play(.cursor, [
            ("sessionStart", [:]),
            ("afterAgentResponse", [:]),
            ("beforeShellExecution", ["command": "rm -rf build"]),
            ("stop", [:]),
            ("sessionEnd", [:]),
        ])
        #expect(run.states == ["idle", "working", "working", "turn", "ended"])
    }

    /// Pi, with payloads shaped like the current extension API
    /// (earendil-works/pi `extensions/types.ts`) as Pulse's extension
    /// forwards them: the person's message is the prompt, a tool's one
    /// argument came from its `tool_execution_start`, `agent_settled`
    /// carries the run's last words, and a run that stopped on an error is
    /// a failed turn.
    @Test func pi() {
        let run = play(.pi, [
            ("session_start", [:]),
            ("agent_start", [:]),
            ("message_start", ["prompt": "Clean the build folder"]),
            ("tool_execution_end", ["tool_name": "bash", "tool_input": ["command": "ls build"]]),
            ("ui_prompt_start", ["kind": "confirm", "title": "Delete build/?", "reason": "ui_prompt"]),
            ("ui_prompt_end", ["kind": "confirm", "title": "Delete build/?", "reason": "ui_prompt"]),
            ("tool_execution_end", ["tool_name": "bash"]),
            ("ui_prompt_start", ["kind": "select", "title": "Which branch?", "reason": "ui_prompt"]),
            ("ui_prompt_end", ["kind": "select", "title": "Which branch?", "reason": "ui_prompt"]),
            ("agent_settled", ["last_assistant_message": "Removed build/."]),
            ("agent_start", [:]),
            ("agent_settled", ["error": "429 rate limited"]),
            ("session_shutdown", ["reason": "quit"]),
        ])
        #expect(run.states == [
            "idle", "working", "working", "working", "blocked:permission", "working", "working",
            "blocked:question", "working", "turn", "working", "turn", "ended",
        ])
        let session = run.book.sessions[SessionKey(.pi, "s1")]
        #expect(session?.title == "Clean the build folder")
        let listed = session?.timeline.contains { $0.effect == .step(tool: "bash", target: "ls build") }
        #expect(listed == true)
        #expect(session?.lastError == "429 rate limited")
        let ask = HookFeed.write(.pi, "ui_prompt_start", ["kind": "confirm", "title": "Delete build/?", "reason": "ui_prompt"], at: t0).lines.first?.message
        #expect(ask == "Delete build/?", "the title, never the reason")
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

    /// OpenCode 1.x: the prompt starts the turn (busy only says work goes
    /// on), a tool's start and end are what runs and a step, two asks
    /// open at once need both answers, an abort is a stop and an idle the
    /// turn's end.
    @Test func openCode() {
        let run = play(.opencode, [
            ("session.created", [:]),
            ("session.status", ["status": ["type": "busy"]]),
            ("message.part.updated", ["phase": "prompt", "prompt": "Fix the login test"]),
            ("message.part.updated", ["phase": "running", "tool_name": "bash", "target": "npm test"]),
            ("permission.asked", ["permission": "bash", "patterns": ["npm test"], "tool_name": "bash"]),
            ("permission.asked", ["permission": "edit", "patterns": ["src/a.ts"], "tool_name": "write"]),
            ("permission.replied", ["pending": 1]),
            ("permission.replied", ["pending": 0]),
            ("message.part.updated", ["phase": "done", "tool_name": "bash", "target": "npm test"]),
            ("question.asked", ["questions": [["question": "Which DB?"]]]),
            ("question.rejected", [:]),
            ("session.idle", [:]),
            ("session.updated", ["session_name": "Login test"]),
            ("message.part.updated", ["phase": "prompt", "prompt": "Now the signup test"]),
            ("session.error", ["sessionID": "s1", "error": "aborted", "error_name": "MessageAbortedError"]),
            ("session.deleted", [:]),
        ])
        #expect(run.states == [
            "idle", "idle", "working", "working", "blocked:permission", "blocked:permission", "blocked:permission",
            "working", "working", "blocked:question", "working", "turn", "turn", "working", "idle", "ended",
        ])
        let session = run.book.sessions[SessionKey(.opencode, "s1")]
        #expect(session?.shownTitle == "Login test", "the vendor's name over the first prompt")
        #expect(session?.title == "Fix the login test")
        #expect(session?.lastStep?.tool == "bash")
        #expect(session?.lastStep?.target == "npm test")
        let npmSteps = session?.timeline.filter { $0.effect == .step(tool: "bash", target: "npm test") }.count
        #expect(npmSteps == 1, "one step")
        let ask = HookFeed.write(.opencode, "permission.asked", ["permission": "bash", "patterns": ["npm test"]], at: t0).lines.first?.message
        #expect(ask == "bash: npm test")
    }

    /// OpenCode 2.x: the run's start and its prompt, a tool call and its
    /// success, a form (the question tool) and its reply, and the run's end.
    @Test func openCodeCurrent() {
        let run = play(.opencode, [
            ("session.created", ["session_name": "Port the cache"]),
            ("session.execution.started", [:]),
            ("session.inbox.enqueued", ["prompt": "Move the cache to Redis"]),
            ("session.tool.called", ["tool_name": "bash", "target": "redis-cli ping"]),
            ("session.tool.success", ["tool_name": "bash", "target": "redis-cli ping", "duration_ms": 800]),
            ("form.created", ["questions": [["question": "Which host?"]]]),
            ("form.cancelled", ["pending": 0]),
            ("session.retry.scheduled", [:]),
            ("session.execution.succeeded", [:]),
            ("session.compaction.ended", [:]),
            ("session.execution.started", [:]),
            ("session.execution.interrupted", ["reason": "user"]),
        ])
        #expect(run.states == [
            "idle", "working", "working", "working", "working", "blocked:question", "working", "working", "turn",
            "turn", "working", "idle",
        ])
        let session = run.book.sessions[SessionKey(.opencode, "s1")]
        #expect(session?.lastStep == SessionBook.Step(tool: "bash", target: "redis-cli ping", ms: t0 + 4 * minute, tookMs: 800))
        #expect(session?.name == "Port the cache")
    }

    /// Each agent's own tool event becomes a step with its tool and target —
    /// Copilot's `toolArgs` as a JSON string, Pi's and OpenCode's forwarded
    /// summary, Cursor's command — and its own prompt event becomes the
    /// title. Cursor's reply and OpenCode's busy name no tool: no step.
    @Test func everyAgentsStepsComeFromItsOwnHook() {
        let cases: [(AgentID, String, [String: Any], String, String)] = [
            (.claude, "PostToolUse", ["tool_name": "Bash", "tool_input": ["command": "swift test"]], "Bash", "swift test"),
            (.codex, "PostToolUse", ["tool_name": "shell", "tool_input": ["command": "cargo build"]], "shell", "cargo build"),
            (.copilot, "postToolUse", ["toolName": "bash", "toolArgs": #"{"command":"npm test"}"#], "bash", "npm test"),
            (.pi, "tool_execution_end", ["tool_name": "edit", "tool_input": ["path": "src/x.ts"]], "edit", "src/x.ts"),
            (.opencode, "message.part.updated", ["phase": "done", "tool_name": "read", "target": "src/x.ts"], "read", "src/x.ts"),
            (.opencode, "session.tool.success", ["tool_name": "grep", "target": "TODO"], "grep", "TODO"),
            (.cursor, "afterShellExecution", ["command": "make test"], "Shell", "make test"),
        ]
        for (agent, event, payload, tool, target) in cases {
            var book = SessionBook()
            for line in HookFeed.write(agent, event, payload, at: t0).lines { book.apply(line, nowMs: t0) }
            let step = book.sessions[SessionKey(agent, "s1")]?.lastStep
            #expect(step == SessionBook.Step(tool: tool, target: target, ms: t0), "\(agent.rawValue)")
        }
        let quiet: [(AgentID, String, [String: Any])] = [(.cursor, "afterAgentResponse", [:]), (.opencode, "session.status", ["status": "busy"])]
        for (agent, event, payload) in quiet {
            var book = SessionBook()
            for line in HookFeed.write(agent, event, payload, at: t0).lines { book.apply(line, nowMs: t0) }
            let step = book.sessions[SessionKey(agent, "s1")]?.lastStep
            #expect(step == nil, "\(agent.rawValue)")
        }
        let prompts: [(AgentID, String)] = [
            (.claude, "UserPromptSubmit"), (.codex, "UserPromptSubmit"), (.copilot, "userPromptSubmitted"), (.pi, "message_start"),
            (.opencode, "message.part.updated"), (.opencode, "session.inbox.enqueued"),
        ]
        for (agent, event) in prompts {
            var book = SessionBook()
            for line in HookFeed.write(agent, event, ["prompt": "Fix the flaky login test", "phase": "prompt"], at: t0).lines { book.apply(line, nowMs: t0) }
            let title = book.sessions[SessionKey(agent, "s1")]?.title
            #expect(title == "Fix the flaky login test", "\(agent.rawValue)")
        }
    }

    // MARK: - Answers, denials and held turns (realistic spacing)

    /// Copilot asks, the person denies: no tool runs, the turn ends 3 s
    /// later — inside the grace. The turn is held, never dropped: the lamp
    /// goes out when the grace ends.
    @Test func copilotDeniedTurnLandsAfterTheGrace() {
        let run = playAt(.copilot, [
            (0, "userPromptSubmitted", [:]),
            (4 * second, "notification", ["notification_type": "permission_prompt", "message": "Allow bash?"]),
            (7 * second, "agentStop", [:]),
            (15 * second, "tick", [:]),
            (25 * second, "tick", [:]),
        ])
        #expect(run.states == ["working", "blocked:permission", "blocked:permission", "blocked:permission", "turn"])
        guard case .yourTurn(let since) = run.book.sessions[SessionKey(.copilot, "s1")]?.state else {
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

    /// Copilot: a subagent's tool (its `agentId`) is not the person
    /// answering the main agent's prompt, even the same tool; only the main
    /// agent's own tool is. A subagent's start is its own status, and a
    /// recoverable error is work going on only while the turn is — after
    /// the turn ended it revives nothing.
    @Test func copilotSubagentToolsNeverAnswerTheRootAndARecoverableErrorRevivesNothing() throws {
        let run = playAt(.copilot, [
            (0, "userPromptSubmitted", ["prompt": "Audit the repo"]),
            (2 * second, "subagentStart", ["agentName": "explore"]),
            (4 * second, "notification", ["notification_type": "permission_prompt", "message": "Allow bash: rm -rf build?"]),
            (6 * second, "postToolUse", ["toolName": "bash", "agentId": "sub-1"]),
            (8 * second, "postToolUseFailure", ["toolName": "view", "agentId": "sub-1"]),
            (9 * second, "errorOccurred", ["recoverable": true, "error": ["message": "Rate limited"]]),
            (30 * second, "postToolUse", ["toolName": "bash"]),
            (40 * second, "agentStop", [:]),
            (50 * second, "errorOccurred", ["recoverable": true, "error": ["message": "Rate limited"]]),
            (55 * second, "postToolUse", ["toolName": "bash", "agentId": "sub-1"]),
            (minute, "preCompact", ["trigger": "auto"]),
        ])
        #expect(run.states == [
            "working", "working", "blocked:permission", "blocked:permission", "blocked:permission", "blocked:permission",
            "working", "turn", "turn", "turn", "turn",
        ])
        let session = try #require(run.book.sessions[SessionKey(.copilot, "s1")])
        #expect(session.lastStep?.sub == "", "the subagent's step after the turn ended is not taken")
        #expect(session.turnSteps == 3 && session.turnFailedSteps == 1, "its steps count in the turn")
        let marked = session.timeline.contains { $0.sub == "sub-1" }
        #expect(marked, "the subagent's steps are marked as its own")
        #expect(session.timeline.contains { $0.sub == "explore" && $0.effect == .status }, "a subagent began, on the timeline")
    }

    /// Cursor: the reply's words are the turn's last words — its `stop`
    /// carries none; an error ends the turn as failed, an abort stops it.
    @Test func cursorRepliesAreTheLastWords() throws {
        let run = playAt(.cursor, [
            (0, "sessionStart", [:]),
            (second, "afterShellExecution", ["command": "npm test"]),
            (2 * second, "afterAgentResponse", ["text": "All 42 tests pass."]),
            (3 * second, "stop", ["status": "completed"]),
            (minute, "afterFileEdit", ["file_path": "/Users/me/app/src/a.ts", "workspace_roots": ["/Users/me/app"]]),
            (minute + second, "stop", ["status": "aborted"]),
            (2 * minute, "afterShellExecution", ["command": "make"]),
            (2 * minute + second, "stop", ["status": "error"]),
        ])
        #expect(run.states == ["idle", "working", "working", "turn", "working", "idle", "working", "turn"])
        let session = try #require(run.book.sessions[SessionKey(.cursor, "s1")])
        #expect(session.lastWords == "All 42 tests pass.")
        let steps = session.timeline.compactMap { heard -> String? in
            if case .steps = heard.effect { return heard.effect.text(.en) }
            return nil
        }
        #expect(steps == ["Shell · npm test", "Edit · src/a.ts", "Shell · make"])
        #expect(AgentID.cursor.reportsToolActivity, "its steps")
        #expect(!AgentID.cursor.silenceCanStall, "no tool start: its silence is never a stall")
        #expect(AgentID.cursor.waitingSource == .none, "still never red")
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
        #expect(HookFeed.word(book.sessions[SessionKey(.claude, "s1")]?.state) == "blocked:permission")
        for line in tool.lines { book.apply(line, nowMs: t0 + 9 * second) }
        #expect(book.sessions[SessionKey(.claude, "s1")]?.state == .yourTurn(sinceMs: t0 + 8 * second))
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
        book.apply(AttentionRecord(agent: .copilot, kind: .permission, ms: t0, message: "Allow bash?", session: "s1"), nowMs: t0)
        book.apply(AttentionRecord(agent: .copilot, kind: .tool, ms: t0 + second, session: "s1", tool: "bash"), nowMs: t0 + second)
        #expect(HookFeed.word(book.sessions[SessionKey(.copilot, "s1")]?.state) == "working")
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
        guard case .blocked(let block) = run.book.sessions[SessionKey(.claude, "s1")]?.state else {
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
        book.apply(AttentionRecord(agent: .claude, kind: .done, ms: t0 + 10 * second, session: "s1"), nowMs: t0 + 10 * second)
        #expect(HookFeed.word(book.sessions[SessionKey(.claude, "s1")]?.state) == "idle")
        let idle = HookFeed.write(.claude, "Notification", ["notification_type": "idle_prompt", "message": "Claude is waiting for your input"], at: t0 + 60 * second)
        let idleKinds = idle.lines.map(\.kind)
        #expect(idleKinds == [.idle])
        for line in idle.lines { book.apply(line, nowMs: t0 + 60 * second) }
        #expect(HookFeed.word(book.sessions[SessionKey(.claude, "s1")]?.state) == "idle", "the seen turn stays seen")
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
        book.apply(AttentionRecord(agent: .claude, kind: .permission, ms: t0 + 2 * second, message: "Bash: ls", session: "s1"), nowMs: t0 + 3 * second)
        book.apply(AttentionRecord(agent: .claude, kind: .done, ms: t0 + second, session: "s1"), nowMs: t0 + 3 * second)
        #expect(HookFeed.word(book.sessions[SessionKey(.claude, "s1")]?.state) == "blocked:permission")
    }

    // MARK: - Invariants

    @Test func aBlockedLineForAnAgentThatCannotBlockIsRefused() {
        for agent in AgentID.waitingNoneAgents {
            var book = SessionBook()
            let changed = book.apply(AttentionRecord(agent: agent, kind: .permission, ms: t0, session: "s1"), nowMs: t0)
            #expect(!changed, "\(agent.rawValue)")
            #expect(book.sessions.isEmpty)
        }
    }

    @Test func aProcessExitEndsItsSessions() {
        var book = SessionBook()
        book.apply(AttentionRecord(agent: .claude, kind: .working, ms: t0, session: "a", pid: 77), nowMs: t0)
        book.apply(AttentionRecord(agent: .claude, kind: .working, ms: t0, session: "b", pid: 88), nowMs: t0)
        #expect(book.livePids == [77, 88])
        let changed1 = book.processExited(pid: 77, atMs: t0 + minute)
        #expect(changed1)
        #expect(HookFeed.word(book.sessions[SessionKey(.claude, "a")]?.state) == "ended")
        #expect(HookFeed.word(book.sessions[SessionKey(.claude, "b")]?.state) == "working")
        #expect(book.livePids == [88])
    }

    @Test func aPidFoundDeadEndsWhenItWasLastHeard() {
        var book = SessionBook()
        book.apply(AttentionRecord(agent: .codex, kind: .turn, ms: t0, session: "c", pid: 55), nowMs: t0)
        book.endSessions(whosePidIsDead: { _ in false })
        #expect(book.sessions[SessionKey(.codex, "c")]?.state == .ended(atMs: t0))
    }

    @Test func aDismissClearsExactlyTheSessionItNames() {
        var book = SessionBook()
        for session in ["a", "b"] {
            book.apply(AttentionRecord(agent: .claude, kind: .permission, ms: t0, session: session), nowMs: t0)
        }
        book.apply(AttentionRecord(agent: .claude, kind: .done, ms: t0 + 1_000, session: "a"), nowMs: t0 + 1_000)
        #expect(HookFeed.word(book.sessions[SessionKey(.claude, "a")]?.state) == "working")
        #expect(HookFeed.word(book.sessions[SessionKey(.claude, "b")]?.state) == "blocked:permission")
    }

    @Test func anEmptyDoneClearsOnlyTheSessionlessEntries() {
        var book = SessionBook()
        book.apply(AttentionRecord(agent: .copilot, kind: .permission, ms: t0, session: "", cwd: "/w/a"), nowMs: t0)
        book.apply(AttentionRecord(agent: .copilot, kind: .permission, ms: t0, session: "g1", cwd: "/w/a"), nowMs: t0)
        book.apply(AttentionRecord(agent: .copilot, kind: .done, ms: t0 + 1_000, session: ""), nowMs: t0 + 1_000)
        let folder = SessionKey(.copilot, "", cwd: "/w/a")
        #expect(HookFeed.word(book.sessions[folder]?.state) == "working")
        #expect(HookFeed.word(book.sessions[SessionKey(.copilot, "g1")]?.state) == "blocked:permission", "a session with an id is never cleared by an empty done")
    }

    @Test func aDoneAfterATurnMeansItWasSeen() {
        var book = SessionBook()
        book.apply(AttentionRecord(agent: .claude, kind: .turn, ms: t0, session: "s1"), nowMs: t0)
        book.apply(AttentionRecord(agent: .claude, kind: .done, ms: t0 + 1_000, session: "s1"), nowMs: t0 + 1_000)
        #expect(HookFeed.word(book.sessions[SessionKey(.claude, "s1")]?.state) == "idle")
    }

    @Test func aTurnRightAfterABlockDoesNotClearIt() {
        var book = SessionBook()
        book.apply(AttentionRecord(agent: .claude, kind: .permission, ms: t0, session: "s1"), nowMs: t0)
        book.apply(AttentionRecord(agent: .claude, kind: .turn, ms: t0 + 5_000, session: "s1"), nowMs: t0 + 5_000)
        #expect(HookFeed.word(book.sessions[SessionKey(.claude, "s1")]?.state) == "blocked:permission", "inside the grace")
        book.apply(AttentionRecord(agent: .claude, kind: .turn, ms: t0 + 25_000, session: "s1"), nowMs: t0 + 25_000)
        #expect(HookFeed.word(book.sessions[SessionKey(.claude, "s1")]?.state) == "turn")
    }

    @Test func aTurnWatchedFinishIsOwedToNobody() {
        var book = SessionBook()
        book.apply(AttentionRecord(agent: .claude, kind: .turn, ms: t0, session: "s1", front: true), nowMs: t0)
        #expect(HookFeed.word(book.sessions[SessionKey(.claude, "s1")]?.state) == "idle")
    }

    @Test func aSecondAskIsItsOwnRaiseAndKeepsTheWords() {
        var book = SessionBook()
        book.apply(AttentionRecord(agent: .claude, kind: .permission, ms: t0, message: "Bash: npm test", session: "s1"), nowMs: t0)
        book.apply(AttentionRecord(agent: .claude, kind: .permission, ms: t0 + minute, message: "", session: "s1"), nowMs: t0 + minute)
        guard case .blocked(let block) = book.sessions[SessionKey(.claude, "s1")]?.state else {
            Issue.record("not blocked")
            return
        }
        #expect(block.sinceMs == t0 + minute)
        #expect(block.ask == "Bash: npm test")
    }

    @Test func activityBeforeTheRaiseOrInAnotherSessionDoesNotAnswerIt() {
        var book = SessionBook()
        book.apply(AttentionRecord(agent: .claude, kind: .permission, ms: t0, session: "s1"), nowMs: t0)
        func event(_ session: String, _ ms: Int64) -> AttentionRecord {
            AttentionRecord(agent: .claude, kind: .tool, ms: ms, session: session, tool: "Bash")
        }
        book.apply(event("s1", t0 - 1_000), nowMs: t0)
        #expect(HookFeed.word(book.sessions[SessionKey(.claude, "s1")]?.state) == "blocked:permission", "a tool line stamped before the raise")
        book.apply(event("s2", t0 + 1_000), nowMs: t0 + 1_000)
        #expect(HookFeed.word(book.sessions[SessionKey(.claude, "s1")]?.state) == "blocked:permission", "another session's tool")
        book.apply(event("s1", t0 + 2_000), nowMs: t0 + 2_000)
        #expect(HookFeed.word(book.sessions[SessionKey(.claude, "s1")]?.state) == "working", "answered in the vendor's prompt")
    }

    @Test func anEventWithNothingToSayMakesNoSession() {
        var book = SessionBook()
        let changed2 = book.apply(AttentionRecord(agent: .claude, kind: .done, ms: t0, session: "x"), nowMs: t0)
        #expect(!changed2)
        let changed3 = book.apply(AttentionRecord(agent: .claude, kind: .end, ms: t0, session: "x"), nowMs: t0)
        #expect(!changed3)
        let changed4 = book.apply(AttentionRecord(agent: .claude, kind: .turn, ms: t0, session: ""), nowMs: t0)
        #expect(!changed4)
        #expect(book.sessions.isEmpty)
    }

    /// A tool line is an event like any other — it introduces a
    /// working session; one that names no session makes nothing.
    @Test func aToolLineIsWorkAndASessionlessOneIsNothing() {
        var book = SessionBook()
        let changed5 = book.apply(AttentionRecord(agent: .pi, kind: .tool, ms: t0, session: "p", cwd: "/w"), nowMs: t0)
        #expect(changed5)
        #expect(HookFeed.word(book.sessions[SessionKey(.pi, "p")]?.state) == "working")
        #expect(book.sessions[SessionKey(.pi, "p")]?.activityMs == t0)
        let changed6 = book.apply(AttentionRecord(agent: .pi, kind: .tool, ms: t0, session: "", cwd: "/w"), nowMs: t0)
        #expect(!changed6, "a tool with no session has no row to belong to")
        #expect(book.sessions.count == 1)
    }

    // MARK: - Audit fixes

    /// Every line is applied. Parallel tools written around the
    /// answering one — before it and after it — no longer hide it (the spool
    /// kept only the newest event per session).
    @Test func parallelToolsAroundTheAnswerDoNotHideIt() {
        var book = SessionBook()
        let lines = [
            AttentionRecord(agent: .claude, kind: .permission, ms: t0, message: "Bash: npm test", session: "s1", tool: "Bash"),
            AttentionRecord(agent: .claude, kind: .tool, ms: t0 + 1 * second, message: "/w/a.swift", session: "s1", tool: "Read"),
            AttentionRecord(agent: .claude, kind: .tool, ms: t0 + 2 * second, message: "/w/b.swift", session: "s1", tool: "Grep"),
            AttentionRecord(agent: .claude, kind: .tool, ms: t0 + 3 * second, message: "npm test", session: "s1", tool: "Bash"),
            AttentionRecord(agent: .claude, kind: .tool, ms: t0 + 3 * second + 200, message: "/w/c.swift", session: "s1", tool: "Read"),
        ]
        for (index, line) in lines.enumerated() {
            book.apply(line, nowMs: t0 + 4 * second)
            if index == 2 {
                #expect(HookFeed.word(book.sessions[SessionKey(.claude, "s1")]?.state) == "blocked:permission", "parallel tools are not the answer")
            }
        }
        #expect(HookFeed.word(book.sessions[SessionKey(.claude, "s1")]?.state) == "working")
    }

    /// Claude's PostToolUseFailure (a tool that ran and failed) is
    /// activity for that tool, and answers the block raised for it.
    @Test func aFailedToolAnswersItsPermission() {
        let run = playAt(.claude, [
            (0, "PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "npm test"]]),
            (4 * second, "PostToolUseFailure", ["tool_name": "Bash", "tool_input": ["command": "npm test"], "error": "exit 1"]),
        ])
        #expect(run.states == ["blocked:permission", "working"])
        let installed = AgentID.claude.spec.hooks.events.map(\.name)
        #expect(installed.contains("PostToolUseFailure"))
        #expect(installed.contains("PermissionDenied"), "installed async: its retry is a decision Claude never reads from an async hook")
    }

    /// Claude's AskUserQuestion says the question, ExitPlanMode the
    /// plan — not the tool's name.
    @Test func claudeAsksSayWhatIsAsked() {
        let question = HookFeed.write(.claude, "PermissionRequest", [
            "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [["question": "Which database should the cache use?", "header": "DB"]]],
        ], at: t0).lines.first
        #expect(question?.kind == .question)
        #expect(question?.message == "Which database should the cache use?")
        #expect(question?.tool == "AskUserQuestion")
        let plan = HookFeed.write(.claude, "PermissionRequest", [
            "tool_name": "ExitPlanMode",
            "tool_input": ["plan": "## Move the cache to Redis\n\n1. Add the client\n2. Swap the store"],
        ], at: t0).lines.first
        #expect(plan?.kind == .permission)
        #expect(plan?.message == "Move the cache to Redis")
    }

    /// A generic ask first (Claude's Notification can land before
    /// its PermissionRequest), the specific one after: the specific one
    /// wins, the first clock stays. The other way round keeps the first.
    @Test func aMoreSpecificReRaiseReplacesAGenericAsk() {
        let run = playAt(.claude, [
            (0, "Notification", ["notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash"]),
            (2 * second, "PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "npm test"]]),
        ])
        guard case .blocked(let block) = run.book.sessions[SessionKey(.claude, "s1")]?.state else {
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

    /// The first event that names a pid is the clock a reused pid is
    /// judged against.
    @Test func theBookRemembersWhenItFirstHeardAPid() {
        var book = SessionBook()
        book.apply(AttentionRecord(agent: .claude, kind: .start, ms: t0, session: "s1", pid: 500), nowMs: t0)
        book.apply(AttentionRecord(agent: .claude, kind: .tool, ms: t0 + minute, session: "s1", pid: 500, tool: "Read"), nowMs: t0 + minute)
        #expect(book.sessions[SessionKey(.claude, "s1")]?.pidSinceMs == t0)
        // A resume in a new process: the new pid's clock starts again.
        book.apply(AttentionRecord(agent: .claude, kind: .start, ms: t0 + 2 * minute, session: "s1", pid: 600), nowMs: t0 + 2 * minute)
        #expect(book.sessions[SessionKey(.claude, "s1")]?.pid == 600)
        #expect(book.sessions[SessionKey(.claude, "s1")]?.pidSinceMs == t0 + 2 * minute)
        // A reused pid ends the session like a dead one.
        book.endSessions(whoseProcessIsGone: { session in
            !AgentProcesses.stillRuns(
                agent: session.agent, since: session.pidSinceMs,
                identity: AgentProcesses.Identity(args: "/usr/bin/vim notes.md", startedMs: t0 + 10 * minute)
            )
        })
        #expect(book.sessions[SessionKey(.claude, "s1")]?.state == .ended(atMs: t0 + 2 * minute))
        #expect(book.livePids.isEmpty)
    }

    /// A pid of 1 (the hook's parent had exited) is never a
    /// session's process.
    @Test func pidOneIsUnknown() {
        var book = SessionBook()
        book.apply(AttentionRecord(agent: .claude, kind: .working, ms: t0, session: "s1", pid: 1), nowMs: t0)
        #expect(book.sessions[SessionKey(.claude, "s1")]?.pid == 0)
        #expect(book.livePids.isEmpty)
        #expect(AttentionRecord(agent: .claude, kind: .working, ms: t0, pid: 1).line.split(separator: "\t", omittingEmptySubsequences: false)[8] == "", "the pid column")
        #expect(AttentionProtocol.parsePid("1") == 0)
        #expect(AttentionProtocol.parsePid("4242") == 4242)
    }

    @Test func aStampFromTheFutureIsRefused() {
        var book = SessionBook()
        let changed8 = book.apply(AttentionRecord(agent: .claude, kind: .permission, ms: t0 + 60 * minute, session: "s1"), nowMs: t0)
        #expect(!changed8)
    }

    @Test func aStartMidWorkKeepsItWorking() {
        var book = SessionBook()
        book.apply(AttentionRecord(agent: .claude, kind: .working, ms: t0, session: "s1"), nowMs: t0)
        book.apply(AttentionRecord(agent: .claude, kind: .start, ms: t0 + 1_000, session: "s1"), nowMs: t0 + 1_000)
        #expect(HookFeed.word(book.sessions[SessionKey(.claude, "s1")]?.state) == "working")
    }

    @Test func aDayOfSilenceIsForgotten() {
        var book = SessionBook()
        book.apply(AttentionRecord(agent: .claude, kind: .turn, ms: t0, session: "s1"), nowMs: t0)
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
        #expect(HookFeed.word(book.sessions[SessionKey(.claude, "s1")]?.state) == "blocked:permission")
        // The person dismisses it in Pulse: the app's own `dismiss` for the
        // session.
        let dismissal = AttentionRecord.dismissal(agent: .claude, session: "s1", cwd: "/Users/me/app", ms: t0 + 3 * second)
        #expect(dismissal.kind == .dismiss)
        #expect(dismissal.event == AttentionRecord.dismissEvent)
        feed([dismissal], at: t0 + 3 * second)
        let echo = HookFeed.write(.claude, "Notification", [
            "notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash",
        ], at: t0 + 6 * second).lines
        feed(echo, at: t0 + 6 * second)
        #expect(HookFeed.word(book.sessions[SessionKey(.claude, "s1")]?.state) == "working", "the echo of a dismissed ask is not a new wait")
        // Work goes on, then a new ask: red again.
        feed(HookFeed.write(.claude, "PostToolUse", ["tool_name": "Read"], at: t0 + 9 * second).lines, at: t0 + 9 * second)
        feed(HookFeed.write(.claude, "PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "rm -rf build"]], at: t0 + 11 * second).lines, at: t0 + 11 * second)
        #expect(HookFeed.word(book.sessions[SessionKey(.claude, "s1")]?.state) == "blocked:permission")
    }

    /// Only Pulse's own dismissal is echoed. After the vendor's own
    /// "resolved" — OpenCode `permission.replied` / `question.replied`, Pi
    /// `ui_prompt_end`, Claude `elicitation_complete` — the same ask again
    /// inside the grace is a real second ask: red again, never swallowed.
    @Test func theSameAskAgainAfterTheVendorsResolvedIsRaised() {
        let openCode = playAt(.opencode, [
            (0, "permission.asked", ["permission": "bash", "patterns": ["npm test"]]),
            (2 * second, "permission.replied", [:]),
            (5 * second, "permission.asked", ["permission": "bash", "patterns": ["npm test"]]),
        ])
        #expect(openCode.states == ["blocked:permission", "working", "blocked:permission"])
        let openCodeQuestion = playAt(.opencode, [
            (0, "question.asked", ["questions": [["question": "Which branch?"]]]),
            (2 * second, "question.replied", [:]),
            (4 * second, "question.asked", ["questions": [["question": "Which branch?"]]]),
        ])
        #expect(openCodeQuestion.states == ["blocked:question", "working", "blocked:question"])
        let pi = playAt(.pi, [
            (0, "ui_prompt_start", ["kind": "confirm", "title": "Delete build/?"]),
            (2 * second, "ui_prompt_end", [:]),
            (4 * second, "ui_prompt_start", ["kind": "confirm", "title": "Delete build/?"]),
        ])
        #expect(pi.states == ["blocked:permission", "working", "blocked:permission"])
        let claude = playAt(.claude, [
            (0, "Notification", ["notification_type": "elicitation_dialog", "message": "Pick a database"]),
            (2 * second, "Notification", ["notification_type": "elicitation_complete"]),
            (4 * second, "Notification", ["notification_type": "elicitation_dialog", "message": "Pick a database"]),
        ])
        #expect(claude.states == ["blocked:question", "working", "blocked:question"])
        let resolved = HookFeed.write(.opencode, "permission.replied", [:], at: t0).lines.first
        #expect(resolved?.kind == .done, "a vendor's resolved is not Pulse's dismissal")
        #expect(resolved?.event == "permission.replied")
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
    /// starts — here its next prompt; a `session.status` busy says work
    /// goes on and starts no turn. It never outlives the turn it belongs to.
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
        let error = book.sessions[SessionKey(.opencode, "s1")]?.lastError
        #expect(error == "Model unavailable")
        #expect(HookFeed.word(book.sessions[SessionKey(.opencode, "s1")]?.state) == "turn")
        let next = t0 + 5 * minute
        for line in HookFeed.write(.opencode, "session.status", ["status": ["type": "busy"]], at: next).lines { book.apply(line, nowMs: next) }
        #expect(HookFeed.word(book.sessions[SessionKey(.opencode, "s1")]?.state) == "turn", "busy starts no turn")
        #expect(book.sessions[SessionKey(.opencode, "s1")]?.lastError == "Model unavailable")
        let prompt = next + second
        for line in HookFeed.write(.opencode, "message.part.updated", ["phase": "prompt", "prompt": "Try again"], at: prompt).lines { book.apply(line, nowMs: prompt) }
        #expect(HookFeed.word(book.sessions[SessionKey(.opencode, "s1")]?.state) == "working")
        let cleared = book.sessions[SessionKey(.opencode, "s1")]?.lastError
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
        #expect(status?.kind == .status)
        #expect(status?.event == "errorOccurred")
        #expect(openCode.book.sessions[SessionKey(.opencode, "s1")]?.lastStep == nil, "a status is not a step")
    }

    /// Work going on is its own kind: no tool column can spell it. A real
    /// tool named `status` (or `:status`) is a tool — a step that answers
    /// its own block.
    @Test func aToolNamedStatusIsATool() {
        let written = HookFeed.write(.opencode, "session.status", ["status": ["type": "busy"]], at: t0).lines.first
        #expect(written?.kind == .status)
        #expect(written?.tool == "")
        let claude = playAt(.claude, [
            (0, "PermissionRequest", ["tool_name": "status", "tool_input": ["command": "git status"]]),
            (2 * second, "PostToolUse", ["tool_name": "status"]),
        ])
        #expect(claude.states == ["blocked:permission", "working"], "a tool named status answers its own block")
        let step = claude.book.sessions[SessionKey(.claude, "s1")]?.lastStep?.tool
        #expect(step == "status")
        let colon = HookFeed.write(.claude, "PostToolUse", ["tool_name": ":status"], at: t0).lines.first
        #expect(colon?.kind == .tool)
        #expect(colon?.tool == ":status")
    }

    /// A failed turn is its own kind: your turn, never red, and its words
    /// are the session's last error.
    @Test func aFailedTurnIsItsOwnKind() {
        let failed = HookFeed.write(.claude, "StopFailure", ["last_assistant_message": "API Error: Rate limit reached"], at: t0).lines.first
        #expect(failed?.kind == .failed)
        #expect(failed?.message == "API Error: Rate limit reached")
        let run = playAt(.claude, [
            (0, "UserPromptSubmit", ["prompt": "Ship it"]),
            (5 * second, "StopFailure", ["last_assistant_message": "API Error: Rate limit reached"]),
        ])
        #expect(run.states == ["working", "turn"])
        #expect(run.book.sessions[SessionKey(.claude, "s1")]?.lastError == "API Error: Rate limit reached")
    }

    // MARK: - Timeline: what each heard line did

    /// The effect of each line of a raise answered, as the reducer decided
    /// it — rebuilt by a replay, never kept anywhere else.
    @Test func theTimelineSaysWhatEachLineDid() {
        var book = SessionBook()
        let key = SessionKey(.claude, "s1")
        let lines = [
            AttentionRecord(agent: .claude, kind: .start, ms: t0, session: "s1", event: "SessionStart"),
            AttentionRecord(agent: .claude, kind: .working, ms: t0 + second, message: "Fix it", session: "s1", event: "UserPromptSubmit"),
            AttentionRecord(agent: .claude, kind: .tool, ms: t0 + 2 * second, message: "swift test", session: "s1", tool: "Bash", event: "PostToolUse"),
            AttentionRecord(agent: .claude, kind: .permission, ms: t0 + 3 * second, message: "Bash: rm -rf build", session: "s1", tool: "Bash", event: "PermissionRequest"),
            AttentionRecord(agent: .claude, kind: .permission, ms: t0 + 9 * second, message: "Claude needs your permission to use Bash", session: "s1", event: "Notification"),
            AttentionRecord(agent: .claude, kind: .tool, ms: t0 + 12 * second, message: "rm -rf build", session: "s1", tool: "Bash", event: "PostToolUse"),
            AttentionRecord(agent: .claude, kind: .ignored, ms: t0 + 13 * second, message: PulseHookReceiver.Ignored.notInstalled.rawValue, session: "s1", event: "PreCompact"),
            AttentionRecord(agent: .claude, kind: .turn, ms: t0 + 14 * second, session: "s1", event: "Stop"),
            AttentionRecord(agent: .claude, kind: .dismiss, ms: t0 + 15 * second, session: "s1", event: AttentionRecord.seenEvent),
            AttentionRecord(agent: .claude, kind: .end, ms: t0 + 16 * second, session: "s1", event: "SessionEnd"),
        ]
        for line in lines { book.apply(line, nowMs: t0 + minute) }
        let timeline = book.facts(for: key).timeline
        let events = timeline.map { $0.event }
        let written = lines.map { $0.event }
        #expect(events == written)
        let effects = timeline.map { $0.effect }
        #expect(effects == [
            .started, .prompt, .step(tool: "Bash", target: "swift test"), .raised(.permission), .again, .answered,
            .skipped(reason: PulseHookReceiver.Ignored.notInstalled.rawValue), .yourTurn, .seen, .ended,
        ])
        var replayed = SessionBook()
        for line in lines { replayed.apply(line, nowMs: t0 + minute) }
        #expect(replayed.facts(for: key) == book.facts(for: key), "a replay rebuilds the same timeline")
    }

    /// A turn inside a block's grace is held, then lands; a dismissal in
    /// Pulse and the vendor's own close say so; a turn the person watched
    /// is not "your turn".
    @Test func theTimelineSaysHeldDismissedAndWatched() {
        var book = SessionBook()
        let key = SessionKey(.claude, "s1")
        book.apply(AttentionRecord(agent: .claude, kind: .permission, ms: t0, message: "Bash: ls", session: "s1", tool: "Bash", event: "PermissionRequest"), nowMs: t0)
        book.apply(AttentionRecord(agent: .claude, kind: .turn, ms: t0 + 2 * second, session: "s1", event: "Stop"), nowMs: t0)
        book.apply(AttentionRecord(agent: .claude, kind: .dismiss, ms: t0 + 3 * second, session: "s1", event: AttentionRecord.dismissEvent), nowMs: t0)
        book.apply(AttentionRecord(agent: .claude, kind: .working, ms: t0 + minute, session: "s1", event: "UserPromptSubmit"), nowMs: t0 + minute)
        book.apply(AttentionRecord(agent: .claude, kind: .turn, ms: t0 + 2 * minute, session: "s1", front: true, event: "Stop"), nowMs: t0 + 2 * minute)
        book.apply(AttentionRecord(agent: .claude, kind: .idle, ms: t0 + 3 * minute, session: "s1", event: "Notification"), nowMs: t0 + 3 * minute)
        let effects = book.facts(for: key).timeline.map { $0.effect }
        #expect(effects == [.raised(.permission), .held, .dismissed, .prompt, .turnEnded, .atPrompt])
    }

    /// The ring keeps the newest `maxTimeline` entries.
    @Test func theTimelineKeepsTheNewestLines() {
        var book = SessionBook()
        for i in 0..<(SessionBook.maxTimeline + 5) {
            book.apply(AttentionRecord(
                agent: .claude, kind: .working, ms: t0 + Int64(i) * second, message: "p\(i)",
                session: "s1", event: "UserPromptSubmit"
            ), nowMs: t0 + minute)
        }
        let timeline = book.facts(for: SessionKey(.claude, "s1")).timeline
        #expect(timeline.count == SessionBook.maxTimeline)
        #expect(timeline.last?.effect == .prompt)
        #expect(timeline.first?.ms == t0 + 5 * second)
    }

    /// Consecutive steps of one speaker are one entry — each tool once,
    /// with its count, and how many failed — at the newest step's clock and
    /// event; a raise, an answer or another speaker starts a new entry. So
    /// a long turn still fits the timeline. A single step keeps its target
    /// and how long it ran.
    @Test func consecutiveStepsAreOneTimelineEntry() throws {
        var book = SessionBook()
        func tool(_ name: String, _ at: Int64, sub: String = "", failed: Bool = false, took: Int64 = 0) {
            book.apply(AttentionRecord(
                agent: .claude, kind: .tool, ms: t0 + at, message: "x", session: "s1", tool: name,
                event: failed ? "PostToolUseFailure" : "PostToolUse", sub: sub, failed: failed, tookMs: took
            ), nowMs: t0 + 10 * minute)
        }
        book.apply(AttentionRecord(agent: .claude, kind: .working, ms: t0, message: "Go", session: "s1", event: "UserPromptSubmit"), nowMs: t0)
        tool("Edit", second)
        tool("Edit", 2 * second)
        tool("Bash", 3 * second, failed: true)
        tool("Edit", 4 * second)
        tool("Bash", 5 * second)
        tool("Edit", 6 * second)
        tool("Grep", 7 * second, sub: "a1")
        tool("Grep", 8 * second, sub: "a1")
        tool("Read", 9 * second, took: 2_300)
        let timeline = book.facts(for: SessionKey(.claude, "s1")).timeline
        #expect(timeline.count == 4, "prompt, the main agent's run, the subagent's run, one step")
        let run = SessionBook.StepRun(
            tools: [.init(tool: "Edit", count: 4), .init(tool: "Bash", count: 2)], count: 6, failed: 1
        )
        let main = try #require(timeline.dropFirst().first)
        #expect(main.effect == .steps(run))
        #expect(main.ms == t0 + 6 * second, "the newest step's clock")
        #expect(main.event == "PostToolUse")
        #expect(main.effect.text(.en) == "Edit ×4 · Bash ×2 · 1 failed")
        #expect(main.effect.text(.zh) == "Edit ×4 · Bash ×2 · 1 步失败")
        #expect(main.effect.tone == .failure)
        let sub = try #require(timeline.dropFirst(2).first)
        #expect(sub.sub == "a1")
        #expect(TrayRowModel.heardText(sub, lang: .en) == "Subagent · Grep ×2")
        let single = try #require(timeline.last)
        #expect(single.effect == .step(tool: "Read", target: "x"))
        #expect(TrayRowModel.heardText(single, lang: .en) == "Read · x · 2.3s")
        #expect(TrayRowModel.heardText(single, lang: .zh) == "Read · x · 2.3秒")
        #expect(main.effect.reportWord == "steps Edit×4 Bash×2 (1 failed)")
        let facts = book.facts(for: SessionKey(.claude, "s1"))
        #expect(facts.turnSteps == 9, "every step of the turn, the subagent's among them")
        #expect(facts.turnFailedSteps == 1)
    }

    /// A turn's step count starts over with its prompt — or with the step
    /// that starts a turn whose prompt Pulse did not see.
    @Test func theTurnsStepCountStartsWithTheTurn() {
        let run = playAt(.claude, [
            (0, "UserPromptSubmit", ["prompt": "One"]),
            (second, "PostToolUse", ["tool_name": "Read", "tool_input": ["file_path": "/w/a.swift"]]),
            (2 * second, "PostToolUseFailure", ["tool_name": "Bash", "tool_input": ["command": "swift test"]]),
            (3 * second, "Stop", [:]),
            (minute, "PostToolUse", ["tool_name": "Read", "tool_input": ["file_path": "/w/b.swift"]]),
        ])
        let after = run.book.facts(for: SessionKey(.claude, "s1"))
        #expect(after.turnSteps == 1, "a new turn, started by its first step")
        #expect(after.turnFailedSteps == 0)
        let prompted = playAt(.claude, [
            (0, "UserPromptSubmit", ["prompt": "One"]),
            (second, "PostToolUseFailure", ["tool_name": "Bash", "tool_input": ["command": "swift test"]]),
            (2 * second, "UserPromptSubmit", ["prompt": "Two"]),
        ])
        let fresh = prompted.book.facts(for: SessionKey(.claude, "s1"))
        #expect(fresh.turnSteps == 0)
        #expect(fresh.turnFailedSteps == 0)
    }

    /// A turn that ended on an error says so until the next turn; a stop by
    /// the person says so until anything moves the session.
    @Test func aFailedTurnAndAStopAreFacts() throws {
        let failed = playAt(.claude, [
            (0, "UserPromptSubmit", ["prompt": "Ship it"]),
            (5 * second, "StopFailure", ["last_assistant_message": "API Error: Rate limit reached"]),
        ])
        let turn = failed.book.facts(for: SessionKey(.claude, "s1"))
        #expect(turn.failedTurn)
        let again = playAt(.claude, [
            (0, "UserPromptSubmit", ["prompt": "Ship it"]),
            (5 * second, "StopFailure", ["last_assistant_message": "API Error: Rate limit reached"]),
            (minute, "UserPromptSubmit", ["prompt": "Again"]),
            (2 * minute, "Stop", [:]),
        ])
        #expect(!again.book.facts(for: SessionKey(.claude, "s1")).failedTurn)
        let stopped = playAt(.pi, [
            (0, "message_start", ["prompt": "Refactor the queue"]),
            (second, "agent_settled", ["aborted": true]),
        ])
        #expect(stopped.book.facts(for: SessionKey(.pi, "s1")).stopped)
        let resumed = playAt(.pi, [
            (0, "message_start", ["prompt": "Refactor the queue"]),
            (second, "agent_settled", ["aborted": true]),
            (minute, "message_start", ["prompt": "Go on"]),
        ])
        #expect(!resumed.book.facts(for: SessionKey(.pi, "s1")).stopped)
    }

    /// An `ignored` line goes on the timeline of a session the book holds —
    /// and changes nothing else: not its clock, not its state.
    @Test func anIgnoredLineIsHeardNotApplied() {
        var book = SessionBook()
        let key = SessionKey(.claude, "s1")
        book.apply(AttentionRecord(agent: .claude, kind: .working, ms: t0, session: "s1", event: "UserPromptSubmit"), nowMs: t0)
        let before = book.sessions[key]
        let ignored = AttentionRecord(agent: .claude, kind: .ignored, ms: t0 + second, message: PulseHookReceiver.Ignored.silent.rawValue, session: "s1", event: "PreCompact")
        let changed = book.apply(ignored, nowMs: t0 + second)
        #expect(!changed)
        let after = book.sessions[key]
        #expect(after?.lastEventMs == before?.lastEventMs)
        #expect(after?.lastEvent == "UserPromptSubmit")
        #expect(after?.state == before?.state)
        #expect(after?.timeline.last == SessionBook.Heard(ms: t0 + second, event: "PreCompact", effect: .skipped(reason: PulseHookReceiver.Ignored.silent.rawValue)))
    }

    /// An `ignored` line records what the receiver heard; it is no state —
    /// it makes no session and moves none.
    @Test func anIgnoredLineIsNoState() {
        var book = SessionBook()
        let heard = AttentionRecord(agent: .claude, kind: .ignored, ms: t0, message: PulseHookReceiver.Ignored.notInstalled.rawValue, session: "s1", event: "PreCompact")
        let made = book.apply(heard, nowMs: t0)
        #expect(!made)
        #expect(book.sessions.isEmpty)
        book.apply(AttentionRecord(agent: .claude, kind: .permission, ms: t0, message: "Bash: ls", session: "s1"), nowMs: t0)
        let moved = book.apply(AttentionRecord(agent: .claude, kind: .ignored, ms: t0 + second, session: "s1"), nowMs: t0 + second)
        #expect(!moved)
        #expect(HookFeed.word(book.sessions[SessionKey(.claude, "s1")]?.state) == "blocked:permission")
    }

    // MARK: - Subagents (the `sub` column)

    /// Each vendor's own subagent key is the line's `sub`: Claude's and
    /// Codex's `agent_id`, Copilot's `agentId`; the main agent's lines have
    /// none.
    @Test func eachAgentsSubagentKeyIsTheSubColumn() {
        let cases: [(AgentID, String, [String: Any])] = [
            (.claude, "PostToolUse", ["tool_name": "Read", "agent_id": "a1"]),
            (.codex, "PostToolUse", ["tool_name": "shell", "agent_id": "a1"]),
            (.copilot, "postToolUse", ["toolName": "bash", "agentId": "a1"]),
        ]
        for (agent, event, payload) in cases {
            let line = HookFeed.write(agent, event, payload, at: t0).lines.first
            #expect(line?.sub == "a1", "\(agent.rawValue)")
            var main = payload
            main["agent_id"] = nil
            main["agentId"] = nil
            let own = HookFeed.write(agent, event, main, at: t0).lines.first
            #expect(own?.sub == "", "\(agent.rawValue)")
        }
        let pi = HookFeed.write(.pi, "tool_execution_end", ["tool_name": "bash", "agent_id": "a1"], at: t0).lines.first
        #expect(pi?.sub == "", "Pi names no subagent: its subagents are silenced processes")
    }

    /// A subagent's tool never answers a block the main agent raised; the
    /// main agent's own tool does.
    @Test func aSubagentNeverAnswersTheMainAgentsBlock() {
        let run = playAt(.claude, [
            (0, "UserPromptSubmit", ["prompt": "Ship it"]),
            (2 * second, "PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "npm publish"]]),
            (4 * second, "PostToolUse", ["tool_name": "Bash", "agent_id": "a1"]),
            (6 * second, "PostToolUseFailure", ["tool_name": "Bash", "agent_id": "a1"]),
            (40 * second, "tick", [:]),
            (60 * second, "PostToolUse", ["tool_name": "Bash"]),
        ])
        #expect(run.states == ["working", "blocked:permission", "blocked:permission", "blocked:permission", "blocked:permission", "working"])
    }

    /// A subagent's block is answered by its own lines only — never by
    /// another subagent's.
    @Test func aSubagentsBlockIsAnsweredOnlyByItsOwnLines() {
        let run = playAt(.claude, [
            (0, "UserPromptSubmit", ["prompt": "Audit the repo"]),
            (2 * second, "PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "rm -rf build"], "agent_id": "a1"]),
            (4 * second, "PostToolUse", ["tool_name": "Bash", "agent_id": "a2"]),
            (6 * second, "PostToolUse", ["tool_name": "Bash", "agent_id": "a1"]),
        ])
        #expect(run.states == ["working", "blocked:permission", "blocked:permission", "working"])
        let raised = playAt(.claude, [(0, "PermissionRequest", ["tool_name": "Bash", "agent_id": "a1"])])
        if case .blocked(let open) = raised.book.sessions[SessionKey(.claude, "s1")]?.state {
            #expect(open.sub == "a1")
        } else {
            Issue.record("not blocked")
        }
        // Its own end of turn (Copilot's agentStop inside a subagent) ends
        // its ask; another's does not.
        let copilotDone = playAt(.copilot, [
            (0, "userPromptSubmitted", ["prompt": "Go"]),
            (2 * second, "notification", ["notification_type": "permission_prompt", "message": "Allow bash?", "agentId": "a1"]),
            (4 * second, "agentStop", ["agentId": "a2"]),
            (6 * second, "agentStop", ["agentId": "a1"]),
        ])
        #expect(copilotDone.states == ["working", "blocked:permission", "blocked:permission", "working"])
    }

    /// Subagent activity never revives a turn that has ended: your turn and
    /// idle stay.
    @Test func aSubagentNeverRevivesAnEndedTurn() {
        let run = playAt(.codex, [
            (0, "UserPromptSubmit", ["prompt": "Explore"]),
            (minute, "Stop", ["last_assistant_message": "Done."]),
            (2 * minute, "PostToolUse", ["tool_name": "shell", "agent_id": "a1"]),
            (3 * minute, "UserPromptSubmit", ["prompt": "sub task", "agent_id": "a1"]),
            (4 * minute, "Stop", ["agent_id": "a1"]),
        ])
        #expect(run.states == ["working", "turn", "turn", "turn", "turn"])
        var book = run.book
        let seen = AttentionRecord.dismissal(agent: .codex, session: "s1", cwd: "", ms: t0 + 5 * minute, event: AttentionRecord.seenEvent)
        book.apply(seen, nowMs: t0 + 5 * minute)
        for line in HookFeed.write(.codex, "PostToolUse", ["tool_name": "shell", "agent_id": "a1"], at: t0 + 6 * minute).lines {
            book.apply(line, nowMs: t0 + 6 * minute)
        }
        #expect(HookFeed.word(book.sessions[SessionKey(.codex, "s1")]?.state) == "idle")
        // Inside a live turn its work is work: a subagent's end of turn is
        // not the person's.
        let live = playAt(.codex, [
            (0, "UserPromptSubmit", ["prompt": "Explore"]),
            (minute, "Stop", ["agent_id": "a1"]),
        ])
        #expect(live.states == ["working", "working"])
    }

    /// A subagent's prompt is its task, not the person's prompt: no title,
    /// no latest prompt, no new turn clock.
    @Test func aSubagentsPromptIsNotThePersonsPrompt() {
        let run = playAt(.codex, [
            (0, "UserPromptSubmit", ["prompt": "Fix the login redirect"]),
            (minute, "UserPromptSubmit", ["prompt": "Search the repo for redirect handlers", "agent_id": "a1"]),
        ])
        let session = run.book.sessions[SessionKey(.codex, "s1")]
        #expect(session?.title == "Fix the login redirect")
        #expect(session?.lastPrompt == "Fix the login redirect")
        #expect(session?.turnStartMs == t0)
        let fresh = playAt(.claude, [(0, "UserPromptSubmit", ["prompt": "Explore the codebase", "agent_id": "a1"])])
        #expect(fresh.book.sessions[SessionKey(.claude, "s1")]?.title == "")
    }

    /// A subagent's steps go on the timeline marked as its own.
    @Test func aSubagentsStepsAreMarkedOnTheTimeline() throws {
        let run = playAt(.claude, [
            (0, "UserPromptSubmit", ["prompt": "Review"]),
            (second, "PostToolUse", ["tool_name": "Grep", "tool_input": ["pattern": "TODO"], "agent_id": "a1"]),
            (2 * second, "PostToolUse", ["tool_name": "Read", "tool_input": ["file_path": "/w/a.swift"]]),
        ])
        let session = try #require(run.book.sessions[SessionKey(.claude, "s1")])
        let heard = session.timeline.suffix(2).map { ($0.effect, $0.sub) }
        #expect(heard.first?.0 == .step(tool: "Grep", target: "TODO"))
        #expect(heard.first?.1 == "a1")
        #expect(heard.last?.1 == "")
        #expect(session.lastStep?.sub == "")
        let marked = try #require(session.timeline.first { !$0.sub.isEmpty })
        #expect(TrayRowModel.heardText(marked, lang: .en) == "Subagent · Grep · TODO")
        #expect(SessionBook.Effect.subagent.reportWord == "subagent lifecycle")
    }

    /// Claude's subagent lifecycle (SubagentStart / SubagentStop, each with
    /// its `agent_id`) is timeline only: it never ends the person's turn,
    /// and after the turn ended (a background subagent finishing, its
    /// last tools, the parent's `background_tasks` on Stop) nothing revives
    /// it.
    @Test func claudeSubagentsNeverEndOrReviveTheTurn() throws {
        let run = playAt(.claude, [
            (0, "UserPromptSubmit", ["prompt": "Map the API"]),
            (second, "SubagentStart", ["agent_id": "a1", "agent_type": "Explore"]),
            (2 * second, "PostToolUse", ["tool_name": "Grep", "tool_input": ["pattern": "route"], "agent_id": "a1"]),
            (3 * second, "SubagentStop", ["agent_id": "a1", "agent_type": "Explore", "last_assistant_message": "Found 12"]),
            (4 * second, "PostToolUse", ["tool_name": "Read", "tool_input": ["file_path": "/w/api.ts"]]),
            (5 * second, "Stop", ["last_assistant_message": "Here is the map.", "background_tasks": [["id": "t1", "type": "subagent", "status": "running", "agent_type": "Explore"]]]),
            (minute, "SubagentStart", ["agent_id": "a2", "agent_type": "Explore"]),
            (2 * minute, "PostToolUse", ["tool_name": "Grep", "agent_id": "a2"]),
            (3 * minute, "SubagentStop", ["agent_id": "a2", "agent_type": "Explore"]),
        ])
        #expect(run.states == ["working", "working", "working", "working", "working", "turn", "turn", "turn", "turn"])
        let session = try #require(run.book.sessions[SessionKey(.claude, "s1")])
        #expect(session.lastWords == "Here is the map.", "a subagent's last words are not the turn's")
        #expect(session.title == "Map the API")
        let lifecycle = session.timeline.filter { $0.event == "SubagentStart" || $0.event == "SubagentStop" }
        #expect(lifecycle.map(\.effect) == [.subagent, .subagent, .subagent, .subagent])
        #expect(lifecycle.map(\.sub) == ["a1", "a1", "a2", "a2"])
    }

    /// A subagent's own block is answered by its SubagentStop; the main
    /// agent's is not.
    @Test func claudeSubagentStopAnswersOnlyItsOwnBlock() {
        let own = playAt(.claude, [
            (0, "UserPromptSubmit", ["prompt": "Audit"]),
            (2 * second, "PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "rm -rf build"], "agent_id": "a1"]),
            (4 * second, "SubagentStop", ["agent_id": "a1"]),
        ])
        #expect(own.states == ["working", "blocked:permission", "working"])
        let main = playAt(.claude, [
            (0, "UserPromptSubmit", ["prompt": "Audit"]),
            (2 * second, "PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "npm publish"]]),
            (4 * second, "SubagentStop", ["agent_id": "a1"]),
        ])
        #expect(main.states == ["working", "blocked:permission", "blocked:permission"])
    }

    /// Requests nobody sees and notices that may be another session's are
    /// never red: `dontAsk`'s PermissionRequest, `agent_needs_input`. The
    /// person interrupting a tool (`is_interrupt`) stops the run.
    @Test func claudeNeverRedForWhatNobodyIsAsked() {
        let run = playAt(.claude, [
            (0, "UserPromptSubmit", ["prompt": "Clean up"]),
            (second, "PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "rm -rf build"], "permission_mode": "dontAsk"]),
            (2 * second, "Notification", ["notification_type": "agent_needs_input", "message": "A background session needs your input"]),
            (3 * second, "PostToolUseFailure", ["tool_name": "Bash", "tool_input": ["command": "sleep 100"], "is_interrupt": true]),
        ])
        #expect(run.states == ["working", "working", "working", "idle"])
        let blocked = playAt(.claude, [
            (0, "PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "npm publish"]]),
            (2 * second, "PostToolUseFailure", ["tool_name": "Bash", "is_interrupt": true]),
        ])
        #expect(blocked.states == ["blocked:permission", "idle"], "the person was at the prompt: nothing owed")
    }

    /// An automatic compaction and auto mode's denial are work going on;
    /// a manual `/compact` at the prompt moves nothing.
    @Test func claudeCompactionAndAutoDenialAreWork() throws {
        let run = playAt(.claude, [
            (0, "UserPromptSubmit", ["prompt": "Refactor"]),
            (minute, "tick", [:]),
            (2 * minute, "PostCompact", ["trigger": "auto"]),
            (3 * minute, "PermissionDenied", ["tool_name": "Bash", "tool_input": ["command": "rm -rf /"], "reason": "[Irreversible Local Destruction]"]),
            (4 * minute, "Stop", [:]),
            (5 * minute, "PostCompact", ["trigger": "manual"]),
        ])
        #expect(run.states == ["working", "working", "working", "working", "turn", "turn"])
        let session = try #require(run.book.sessions[SessionKey(.claude, "s1")])
        #expect(session.lastStep == nil, "neither is a step")
        #expect(session.running == nil, "nor a tool that runs now")
        #expect(session.toolMs == t0 + 3 * minute, "work: a silence after it is not a stall")
    }

    /// Codex: Interrupt is the person stopping the turn — at its prompt,
    /// nothing owed; a subagent's prompt and SubagentStop (each with its
    /// `agent_id`) are its own task and end, never the person's; after the
    /// turn ended nothing of a subagent revives it.
    @Test func codexInterruptAndSubagentStop() throws {
        let run = playAt(.codex, [
            (0, "SessionStart", [:]),
            (second, "UserPromptSubmit", ["prompt": "Index the repo"]),
            (2 * second, "UserPromptSubmit", ["prompt": "List the modules", "agent_id": "th-9", "agent_type": "worker"]),
            (3 * second, "PostToolUse", ["tool_name": "shell", "agent_id": "th-9"]),
            (4 * second, "SubagentStop", ["agent_id": "th-9", "agent_type": "worker", "last_assistant_message": "12 modules"]),
            (5 * second, "Interrupt", [:]),
            (minute, "UserPromptSubmit", ["prompt": "Go on"]),
            (2 * minute, "Stop", ["last_assistant_message": "Indexed."]),
            (3 * minute, "SubagentStop", ["agent_id": "th-10", "agent_type": "worker"]),
        ])
        #expect(run.states == ["idle", "working", "working", "working", "working", "idle", "working", "turn", "turn"])
        let session = try #require(run.book.sessions[SessionKey(.codex, "s1")])
        #expect(session.title == "Index the repo")
        #expect(session.lastPrompt == "Go on")
        #expect(session.lastWords == "Indexed.")
        let stop = session.timeline.first { $0.event == "SubagentStop" }
        #expect(stop?.effect == .subagent)
        #expect(stop?.sub == "th-9")
    }

    // MARK: - Failed steps, stops, names, running tools

    /// A tool that failed is a step marked failed (Claude's
    /// `PostToolUseFailure`, Copilot's `postToolUseFailure`, Pi's
    /// `isError`), with how long it ran when the vendor said.
    @Test func aFailedToolIsAStepMarkedFailed() throws {
        let cases: [(AgentID, String, [String: Any])] = [
            (.claude, "PostToolUseFailure", ["tool_name": "Bash", "tool_input": ["command": "swift test"]]),
            (.copilot, "postToolUseFailure", ["toolName": "bash", "toolArgs": #"{"command":"swift test"}"#]),
            (.pi, "tool_execution_end", ["tool_name": "bash", "tool_input": ["command": "swift test"], "is_error": true, "duration_ms": 4200]),
        ]
        for (agent, event, payload) in cases {
            var book = SessionBook()
            for line in HookFeed.write(agent, event, payload, at: t0).lines { book.apply(line, nowMs: t0) }
            let session = try #require(book.sessions[SessionKey(agent, "s1")])
            #expect(session.lastStep?.failed == true, "\(agent.rawValue)")
            #expect(session.timeline.last?.effect == .step(tool: session.lastStep?.tool ?? "", target: "swift test", failed: true), "\(agent.rawValue)")
        }
        let pi = HookFeed.write(.pi, "tool_execution_end", ["tool_name": "bash", "is_error": false, "duration_ms": 4200], at: t0).lines.first
        #expect(pi?.failed == false)
        #expect(pi?.tookMs == 4200)
        var book = SessionBook()
        for line in HookFeed.write(.pi, "tool_execution_end", ["tool_name": "bash", "duration_ms": 4200], at: t0).lines { book.apply(line, nowMs: t0) }
        #expect(book.sessions[SessionKey(.pi, "s1")]?.lastStep?.tookMs == 4200)
        #expect(SessionBook.Effect.step(tool: "Bash", target: "swift test", failed: true).text(.en) == "Bash · swift test — failed")
    }

    /// The person stopped the run (Pi's aborted `agent_settled`): at its
    /// prompt, nothing owed, no last words — from working or blocked.
    @Test func aStoppedRunIsAtItsPromptWithNothingOwed() throws {
        let run = playAt(.pi, [
            (0, "message_start", ["prompt": "Refactor the queue"]),
            (second, "agent_settled", ["aborted": true, "last_assistant_message": "I will now"]),
            (2 * second, "message_start", ["prompt": "Again"]),
            (3 * second, "ui_prompt_start", ["kind": "confirm", "title": "Delete?"]),
            (4 * second, "agent_settled", ["aborted": true]),
        ])
        #expect(run.states == ["working", "idle", "working", "blocked:permission", "idle"])
        let session = try #require(run.book.sessions[SessionKey(.pi, "s1")])
        #expect(session.lastWords == "", "an aborted run's partial words are not its last words")
        #expect(session.heldTurn == nil)
        #expect(session.timeline.last?.effect == .stopped)
        // A stop stamped before the block it would end is about an earlier one.
        var book = SessionBook()
        book.apply(AttentionRecord(agent: .pi, kind: .question, ms: t0 + 10 * second, message: "Which?", session: "p"), nowMs: t0 + 10 * second)
        book.apply(AttentionRecord(agent: .pi, kind: .stopped, ms: t0 + 5 * second, session: "p"), nowMs: t0 + 10 * second)
        #expect(HookFeed.word(book.sessions[SessionKey(.pi, "p")]?.state) == "blocked:question")
    }

    /// The vendor's own name for the session is its title; when it is
    /// cleared the first prompt is again. A `title` line moves no state and
    /// makes no session.
    @Test func theVendorsNameIsTheTitle() throws {
        let run = playAt(.pi, [
            (0, "session_start", ["session_name": "Release prep"]),
            (second, "message_start", ["prompt": "Bump the version"]),
            (2 * second, "agent_settled", [:]),
            (3 * second, "session_info_changed", ["session_name": "Release 31"]),
        ])
        #expect(run.states == ["idle", "working", "turn", "turn"])
        var session = try #require(run.book.sessions[SessionKey(.pi, "s1")])
        #expect(session.title == "Bump the version")
        #expect(session.shownTitle == "Release 31")
        session.name = ""
        #expect(session.shownTitle == "Bump the version")
        let row = try #require(TrayState.sessionRows(book: run.book, processes: [], context: TrayState.Context(nowMs: t0 + 3 * second)).first)
        #expect(row.task == "Release 31")
        var empty = SessionBook()
        let made = empty.apply(AttentionRecord(agent: .pi, kind: .title, ms: t0, message: "Orphan", session: "p0"), nowMs: t0)
        #expect(!made)
        #expect(empty.sessions.isEmpty)
    }

    /// A tool that started (Pi's `tool_execution_start`) runs now: a long
    /// one is not a stall, and its end makes the step and clears it.
    @Test func aRunningToolIsNotAStall() throws {
        var book = SessionBook()
        let feed: [(Int64, String, [String: Any])] = [
            (0, "message_start", ["prompt": "Build it"]),
            (second, "tool_execution_start", ["tool_name": "bash", "tool_input": ["command": "swift build"]]),
        ]
        for (offset, event, payload) in feed {
            for line in HookFeed.write(.pi, event, payload, at: t0 + offset).lines { book.apply(line, nowMs: t0 + offset) }
        }
        let key = SessionKey(.pi, "s1")
        let running = try #require(book.sessions[key]?.running)
        #expect(running.tool == "bash")
        #expect(running.target == "swift build")
        #expect(book.sessions[key]?.lastStep == nil, "a start is not a step")
        #expect(book.facts(for: key).running == running)
        let later = t0 + 25 * minute
        let session = try #require(book.sessions[key])
        #expect(TrayState.status(of: session, nowMs: later) == .running(stalled: false))
        for line in HookFeed.write(.pi, "tool_execution_end", ["tool_name": "bash", "tool_input": ["command": "swift build"]], at: later).lines {
            book.apply(line, nowMs: later)
        }
        let ended = try #require(book.sessions[key])
        #expect(ended.running == nil)
        #expect(ended.lastStep?.target == "swift build")
        #expect(TrayState.status(of: ended, nowMs: later + 25 * minute) == .running(stalled: true))
        // The turn's end clears it too.
        var turned = SessionBook()
        for (offset, event, payload) in feed + [(2 * second, "agent_settled", [:] as [String: Any])] {
            for line in HookFeed.write(.pi, event, payload, at: t0 + offset).lines { turned.apply(line, nowMs: t0 + offset) }
        }
        #expect(turned.sessions[key]?.running == nil)
    }

    /// Parallel tools: each start runs until its own end. A short lint
    /// ending leaves the long build running — no stall — and the row says
    /// the build runs now; its own end, or the turn's, clears it.
    @Test func aShortParallelToolEndingLeavesTheLongOneRunning() throws {
        var book = SessionBook()
        let key = SessionKey(.pi, "s1")
        func feed(_ event: String, _ payload: [String: Any], at ms: Int64) {
            for line in HookFeed.write(.pi, event, payload, at: ms).lines { book.apply(line, nowMs: ms) }
        }
        feed("message_start", ["prompt": "Build and lint"], at: t0)
        feed("tool_execution_start", ["tool_name": "bash", "tool_input": ["command": "swift build"]], at: t0 + second)
        feed("tool_execution_start", ["tool_name": "bash", "tool_input": ["command": "swiftlint"]], at: t0 + 2 * second)
        feed("tool_execution_end", ["tool_name": "bash", "tool_input": ["command": "swiftlint"]], at: t0 + 3 * second)
        let session = try #require(book.sessions[key])
        #expect(session.runningSteps.map(\.target) == ["swift build"])
        #expect(book.facts(for: key).running?.target == "swift build", "what runs now is the build")
        #expect(TrayState.status(of: session, nowMs: t0 + 25 * minute) == .running(stalled: false), "the build still runs")
        feed("tool_execution_end", ["tool_name": "bash", "tool_input": ["command": "swift build"]], at: t0 + 26 * minute)
        #expect(book.sessions[key]?.runningSteps.isEmpty == true)
        #expect(book.sessions[key]?.lastStep?.target == "swift build")
        #expect(book.sessions[key]?.turnSteps == 2)
        // The turn's end clears every tool still said to run.
        feed("tool_execution_start", ["tool_name": "bash", "tool_input": ["command": "sleep 1"]], at: t0 + 27 * minute)
        feed("tool_execution_start", ["tool_name": "read", "tool_input": ["path": "a.txt"]], at: t0 + 27 * minute)
        #expect(book.sessions[key]?.runningSteps.count == 2)
        feed("agent_settled", [:], at: t0 + 28 * minute)
        #expect(book.sessions[key]?.runningSteps.isEmpty == true)
    }

    /// Claude's main UI says a subagent's ask again (a `Notification`
    /// `permission_prompt`, which names no subagent) seconds after the
    /// subagent's `PermissionRequest`: the same ask, still the subagent's,
    /// on its clock — and its own step answers it.
    @Test func theMainUIsNoticeOfASubagentsAskStaysTheSubagents() throws {
        let run = playAt(.claude, [
            (0, "UserPromptSubmit", ["prompt": "Audit"]),
            (2 * second, "PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "rm -rf build"], "agent_id": "a1"]),
            (8 * second, "Notification", ["notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash"]),
        ])
        #expect(run.states == ["working", "blocked:permission", "blocked:permission"])
        guard case .blocked(let block) = run.book.sessions[SessionKey(.claude, "s1")]?.state else {
            Issue.record("not blocked")
            return
        }
        #expect(block.sub == "a1")
        #expect(block.sinceMs == t0 + 2 * second)
        #expect(block.ask == "Bash: rm -rf build")
        let answered = playAt(.claude, [
            (0, "UserPromptSubmit", ["prompt": "Audit"]),
            (2 * second, "PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "rm -rf build"], "agent_id": "a1"]),
            (8 * second, "Notification", ["notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash"]),
            (12 * second, "PostToolUse", ["tool_name": "Bash", "agent_id": "a1"]),
        ])
        #expect(answered.states.last == "working", "the lamp goes out with the subagent's own step")
    }

    /// A subagent's block is answered by no other speaker's step — the
    /// main agent's tool finishing is not the person answering the
    /// subagent's ask; a prompt, a `done`, a stop or the end are.
    @Test func theMainAgentsStepNeverAnswersASubagentsBlock() {
        let run = playAt(.claude, [
            (0, "UserPromptSubmit", ["prompt": "Audit"]),
            (2 * second, "PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "rm -rf build"], "agent_id": "a1"]),
            (4 * second, "PostToolUse", ["tool_name": "Bash", "tool_input": ["command": "ls"]]),
            (6 * second, "PostToolUse", ["tool_name": "Read"]),
            (8 * second, "UserPromptSubmit", ["prompt": "Skip that, do the docs"]),
        ])
        #expect(run.states == ["working", "blocked:permission", "blocked:permission", "blocked:permission", "working"])
    }

    /// The turn ended (your turn); a background subagent asks, and its own
    /// line answers: the session goes back to your turn, on the turn's own
    /// clock — never into a turn nobody started.
    @Test func aBackgroundSubagentsAskAfterTheTurnGoesBackToYourTurn() {
        let run = playAt(.claude, [
            (0, "UserPromptSubmit", ["prompt": "Map the API"]),
            (minute, "Stop", ["last_assistant_message": "An explorer runs in the background."]),
            (2 * minute, "PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "curl localhost:8080"], "agent_id": "a1"]),
            (3 * minute, "PostToolUse", ["tool_name": "Bash", "agent_id": "a1"]),
            (4 * minute, "PostToolUse", ["tool_name": "Grep", "agent_id": "a1"]),
        ])
        #expect(run.states == ["working", "turn", "blocked:permission", "turn", "turn"])
        let session = run.book.sessions[SessionKey(.claude, "s1")]
        #expect(session?.state == .yourTurn(sinceMs: t0 + minute))
        #expect(session?.stateEvent == "Stop", "the why is the turn's again")
        // Its end of turn answers it the same way; so does the vendor's
        // own "resolved" for a block raised at the prompt.
        let stopped = playAt(.claude, [
            (0, "UserPromptSubmit", ["prompt": "Map the API"]),
            (minute, "Stop", [:]),
            (2 * minute, "PermissionRequest", ["tool_name": "Bash", "agent_id": "a1"]),
            (3 * minute, "SubagentStop", ["agent_id": "a1"]),
        ])
        #expect(stopped.states == ["working", "turn", "blocked:permission", "turn"])
        let pi = playAt(.pi, [
            (0, "message_start", ["prompt": "Tidy up"]),
            (minute, "agent_settled", [:]),
            (2 * minute, "ui_prompt_start", ["kind": "confirm", "title": "Reload extensions?"]),
            (3 * minute, "ui_prompt_end", ["kind": "confirm", "title": "Reload extensions?"]),
        ])
        #expect(pi.states == ["working", "turn", "blocked:permission", "turn"])
        // A block raised during a turn is answered into the turn.
        let live = playAt(.claude, [
            (0, "UserPromptSubmit", ["prompt": "Map the API"]),
            (minute, "PermissionRequest", ["tool_name": "Bash", "agent_id": "a1"]),
            (2 * minute, "PostToolUse", ["tool_name": "Bash", "agent_id": "a1"]),
        ])
        #expect(live.states == ["working", "blocked:permission", "working"])
    }

    /// OpenCode's plugin sends every ask's reply, with how many of the
    /// root's asks are still open: two parallel asks of one tool need both
    /// replies — the first one's step is not the second one's answer.
    @Test func openCodeParallelAsksOfOneToolNeedEveryReply() {
        let run = playAt(.opencode, [
            (0, "message.part.updated", ["phase": "prompt", "prompt": "Run both suites"]),
            (second, "permission.asked", ["permission": "bash", "patterns": ["npm test"], "tool_name": "bash"]),
            (2 * second, "permission.asked", ["permission": "bash", "patterns": ["npm run e2e"], "tool_name": "bash"]),
            (4 * second, "permission.replied", ["pending": 1]),
            (30 * second, "message.part.updated", ["phase": "done", "tool_name": "bash", "target": "npm test"]),
            (40 * second, "permission.replied", ["pending": 0]),
        ])
        #expect(run.states == [
            "working", "blocked:permission", "blocked:permission", "blocked:permission", "blocked:permission", "working",
        ])
        #expect(!AgentID.opencode.stepsAnswerBlocks)
        let others = AgentID.allCases.filter { $0 != .opencode }
        let othersAnswer = others.allSatisfy { $0.stepsAnswerBlocks }
        #expect(othersAnswer, "every other agent's step answers its own tool's ask")
    }

    /// Pi spawns one child per event; at shutdown children spawned
    /// together take the log's lock in any order. Nothing stamped no later
    /// than the session's end — a turn, a prompt, a tool said to start —
    /// revives it; a prompt after it (a resume) does.
    @Test func nothingStampedBeforeTheEndRevivesTheSession() {
        var book = SessionBook()
        let key = SessionKey(.pi, "s1")
        func feed(_ event: String, _ payload: [String: Any] = [:], at ms: Int64) {
            for line in HookFeed.write(.pi, event, payload, at: ms).lines { book.apply(line, nowMs: t0 + minute) }
        }
        feed("message_start", ["prompt": "Clean up"], at: t0)
        feed("session_shutdown", ["reason": "quit"], at: t0 + 10 * second)
        feed("agent_settled", ["last_assistant_message": "Done."], at: t0 + 9 * second)
        feed("tool_execution_start", ["tool_name": "bash", "tool_input": ["command": "ls"]], at: t0 + 9 * second)
        feed("tool_execution_end", ["tool_name": "bash", "tool_input": ["command": "ls"]], at: t0 + 10 * second)
        feed("agent_start", at: t0 + 10 * second)
        #expect(HookFeed.word(book.sessions[key]?.state) == "ended")
        #expect(book.sessions[key]?.runningSteps.isEmpty == true)
        feed("message_start", ["prompt": "Again"], at: t0 + 20 * second)
        #expect(HookFeed.word(book.sessions[key]?.state) == "working")
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
    ) -> [AgentRow] {
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

    /// From line to banner: a permission whose prompt was already in front
    /// lights the lamp with no banner; one whose presence is unknown is
    /// bannered as usual.
    @Test func aBlockAlreadyInFrontLightsTheLampWithoutABanner() throws {
        func bannered(front: Bool?) throws -> (inFront: Bool, red: Bool, banner: Bool) {
            let b = book([AttentionRecord(agent: .claude, kind: .permission, ms: t0, message: "Bash: ls", session: "s1", front: front)])
            let world = TrayState.project(book: b, processes: [], context: TrayState.Context(nowMs: t0 + 2_000, lang: .en))
            let row = try #require(world.rows.first)
            let plan = WaitingDelivery(
                acknowledged: [], inFlight: [], canDeliverNow: true, msSinceLastNotification: 60_000, minimumIntervalMs: 0
            ).plan(world.rows)
            var banner = false
            if case .post(let first, let later) = plan { banner = ([first] + later).contains { $0.key == row.key } }
            return (row.wait?.inFront ?? false, world.snapshot.lamp == .waiting, banner)
        }
        let front = try bannered(front: true)
        #expect(front.inFront && front.red && !front.banner)
        let unknown = try bannered(front: nil)
        #expect(!unknown.inFront && unknown.red && unknown.banner)
    }

    /// A finished turn is grey even while its CLI stays open — the green
    /// ring is for a session that is working; and an `idle` from a session
    /// met only now is a turn.
    @Test func aFinishedTurnWithALiveProcessIsAGreyLamp() throws {
        let b = book([
            AttentionRecord(agent: .claude, kind: .turn, ms: t0, session: "s1", cwd: "/p", pid: 42),
            AttentionRecord(agent: .claude, kind: .idle, ms: t0, session: "s2", cwd: "/p"),
        ])
        let world = TrayState.project(book: b, processes: [], context: TrayState.Context(nowMs: t0 + 2_000, lang: .en))
        let turn = try #require(world.rows.first { $0.key == SessionKey(.claude, "s1") })
        #expect(turn.isYourTurn)
        #expect(turn.liveProcess)
        let idle = world.rows.first { $0.key == SessionKey(.claude, "s2") }
        #expect(idle?.isYourTurn == true)
        #expect(world.snapshot.lamp == .idle)
        #expect(world.snapshot.title == "")
        #expect(world.snapshot.tooltip == L10n.t(.lampRuleTurn, .en))
    }

    @Test func aProcessNoSessionClaimedIsAProcessOnlyRow() throws {
        let hit = AgentProcesses.Hit(agent: .claude, pid: 10, cwd: "/Users/me/app", tty: "ttys004", startedMs: t0 - minute)
        let row = try #require(rows(SessionBook(), processes: [hit]).first)
        #expect(row.key == .process(.claude, pid: 10))
        #expect(row.key.description == "claude|pid:10")
        #expect(row.status == .processOnly)
        #expect(row.project == "app")
        #expect(row.landing.tty == "ttys004")
    }

    @Test func aSessionClaimsItsProcessFamily() {
        let b = book([AttentionRecord(agent: .codex, kind: .working, ms: t0, session: "c1", pid: 11)])
        let hit = AgentProcesses.Hit(agent: .codex, pid: 10, family: [10, 11])
        let listed = rows(b, processes: [hit]).map { $0.key.description }
        #expect(listed == ["codex|c1"], "the wrapper and its child are one process")
    }

    @Test func aSessionWithNoPidClaimsTheProcessInItsFolder() {
        let b = book([AttentionRecord(agent: .copilot, kind: .working, ms: t0, session: "g1", cwd: "/w/app")])
        let same = AgentProcesses.Hit(agent: .copilot, pid: 20, cwd: "/w/app")
        let other = AgentProcesses.Hit(agent: .copilot, pid: 21, cwd: "/w/other")
        let listed = rows(b, processes: [same, other]).map { $0.key.description }.sorted()
        #expect(listed == ["copilot|g1", "copilot|pid:21"])
    }

    @Test func anEndedSessionClaimsNothing() {
        let b = book([
            AttentionRecord(agent: .claude, kind: .working, ms: t0, session: "s1", pid: 30),
            AttentionRecord(agent: .claude, kind: .end, ms: t0 + 1_000, session: "s1", pid: 30),
        ])
        let hit = AgentProcesses.Hit(agent: .claude, pid: 30)
        let listed = rows(b, processes: [hit]).map { $0.key.description }.sorted()
        #expect(listed == ["claude|pid:30", "claude|s1"])
    }

    @Test func aKnownPidStaysRunningWhileTheProcessLives() throws {
        let b = book([AttentionRecord(agent: .claude, kind: .working, ms: t0, session: "s1", pid: 40)])
        let row = try #require(rows(b, at: t0 + 100 * minute).first)
        #expect(row.status == .running(stalled: false))
        #expect(row.liveProcess)
    }

    @Test func anUnknownPidIsRecentAfterTheIdleBoundAndSaysWhy() throws {
        let b = book([AttentionRecord(agent: .claude, kind: .working, ms: t0, session: "s1")])
        #expect(rows(b, at: t0 + 29 * minute).first?.status == .running(stalled: false))
        let row = try #require(rows(b, at: t0 + 31 * minute).first)
        #expect(row.status == .recent(.quiet))
        let why = TrayRowModel.why(row, facts: b.facts(for: row.key), lang: .en, nowMs: t0 + 31 * minute)
        #expect(why.contains("no process to watch"), "\(why)")
    }

    @Test func aTurnIsOwedForHalfAnHour() throws {
        let b = book([AttentionRecord(agent: .codex, kind: .turn, ms: t0, session: "c1", pid: 50)])
        #expect(rows(b, at: t0 + 10 * minute).first?.isYourTurn == true)
        let row = try #require(rows(b, at: t0 + 31 * minute).first)
        #expect(row.status == .recent(.atPrompt))
    }

    @Test func aRecentSessionLeavesTheListAfterTheWindow() {
        let b = book([
            AttentionRecord(agent: .claude, kind: .working, ms: t0, session: "s1"),
            AttentionRecord(agent: .claude, kind: .end, ms: t0 + minute, session: "s1"),
        ])
        #expect(rows(b, at: t0 + 30 * minute).count == 1)
        #expect(rows(b, at: t0 + 60 * minute).isEmpty)
    }

    /// One Cursor IDE or OpenCode server process runs many
    /// sessions all day. Its live pid keeps a working or blocked session
    /// listed — never one that is idle, whose turn aged out, or that is
    /// recent: those leave after the recent window like any other.
    @Test func aLiveProcessKeepsOnlyWorkOrAWaitListed() throws {
        let b = book([
            AttentionRecord(agent: .opencode, kind: .start, ms: t0, session: "o1", pid: 60),
            AttentionRecord(agent: .opencode, kind: .turn, ms: t0, session: "o2", pid: 60),
            AttentionRecord(agent: .opencode, kind: .working, ms: t0, session: "o3", pid: 60),
            AttentionRecord(agent: .opencode, kind: .permission, ms: t0, message: "bash: ls", session: "o4", pid: 60),
        ])
        let early = rows(b, at: t0 + 40 * minute)
        #expect(early.count == 4, "inside the recent window every one is listed")
        let later = rows(b, at: t0 + 100 * minute)
        let keys = later.map(\.key.description).sorted()
        #expect(keys == ["opencode|o3", "opencode|o4"])
        let live = later.filter { $0.liveProcess }.count
        #expect(live == 2)
    }

    /// A service (`codex app-server` inside ChatGPT.app) serves many
    /// sessions and outlives each: the scan lists no row for it and the
    /// hook records no pid for a session it serves, so a live service keeps
    /// none listed — even a working one leaves by the quiet bound. Its
    /// session has no terminal: it lands on the app.
    @Test func aServiceKeepsNoSessionListed() throws {
        let table = [
            AgentProcesses.Proc(pid: 10, ppid: 1, args: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"),
            AgentProcesses.Proc(pid: 11, ppid: 10, args: "/Applications/ChatGPT.app/Contents/Resources/codex app-server"),
        ]
        let service: (AgentID) -> [String] = { $0 == .codex ? ["app-server"] : [] }
        let hits = AgentProcesses.hits(in: table, cwd: { _ in "" }, serviceArguments: service)
        #expect(hits.isEmpty, "a service is no process-only row")
        let unnamed = AgentProcesses.hits(in: table, cwd: { _ in "" }, serviceArguments: { _ in [] })
        let pids = unnamed.map { $0.pid }
        #expect(pids == [11], "until the catalog names it, as before")

        let landing = "detached:1;app:com.openai.codex;host:codexApp"
        let b = book([
            AttentionRecord(agent: .codex, kind: .working, ms: t0, session: "c1", cwd: "/w/app", landing: landing),
            AttentionRecord(agent: .codex, kind: .turn, ms: t0, session: "c2", cwd: "/w/app", landing: landing),
        ])
        let now = try #require(rows(b, processes: hits, at: t0 + minute).first { $0.key == SessionKey(.codex, "c1") })
        #expect(!now.liveProcess)
        #expect(now.landingPlan.steps == [.activateApp(bundleIDs: HostAppKind.codexApp.bundleIDs)])
        let quiet = try #require(rows(b, processes: hits, at: t0 + 31 * minute).first { $0.key == SessionKey(.codex, "c1") })
        #expect(quiet.status == .recent(.quiet))
        #expect(rows(b, processes: hits, at: t0 + 100 * minute).isEmpty)
    }

    /// An interrupted turn sends no Stop. From an agent that reports
    /// each tool's start and end, silence is a stall for a while — then,
    /// past `silentBoundMs`, the session is recent and says why: never an
    /// endless orange.
    @Test func anInterruptedTurnStallsThenGoesQuiet() throws {
        let b = book([
            AttentionRecord(agent: .pi, kind: .working, ms: t0, session: "s1", pid: 41),
            AttentionRecord(agent: .pi, kind: .tool, ms: t0 + minute, session: "s1", pid: 41, tool: "bash"),
        ])
        let stalled = try #require(rows(b, at: t0 + 30 * minute).first)
        #expect(stalled.status == .running(stalled: true))
        let silent = t0 + minute + TrayState.silentBoundMs + minute
        let row = try #require(rows(b, at: silent).first)
        #expect(row.status == .recent(.silent))
        let why = TrayRowModel.why(row, facts: b.facts(for: row.key), lang: .en, nowMs: silent)
        #expect(why.hasPrefix("Nothing heard for"), "\(why)")
        #expect(rows(b, at: silent + TrayState.recentWindowMs).isEmpty, "and it leaves the list, process or not")
    }

    /// Everything a row says about its session comes from the events: the
    /// title (the first prompt) on the row; the last words (the turn), the
    /// error (a failed turn), the steps and the turn's clock in the book's
    /// facts, read when the row is drawn. No file is read.
    @Test func theEventsFillTheRowAndItsFacts() throws {
        let b = book([
            AttentionRecord(agent: .claude, kind: .working, ms: t0, message: "Fix the login test", session: "s1", pid: 70),
            AttentionRecord(agent: .claude, kind: .tool, ms: t0 + minute, message: "Tests/LoginTests.swift", session: "s1", pid: 70, tool: "Read"),
            AttentionRecord(agent: .claude, kind: .tool, ms: t0 + 2 * minute, message: "swift test", session: "s1", pid: 70, tool: "Bash"),
            AttentionRecord(agent: .claude, kind: .turn, ms: t0 + 3 * minute, message: "All green.", session: "s1", pid: 70),
            AttentionRecord(agent: .claude, kind: .working, ms: t0 + 4 * minute, message: "Ship it", session: "s1", pid: 70),
            AttentionRecord(agent: .claude, kind: .tool, ms: t0 + 5 * minute, message: "git push", session: "s1", pid: 70, tool: "Bash"),
        ])
        let row = try #require(rows(b, at: t0 + 6 * minute).first)
        #expect(row.task == "Fix the login test")
        let facts = b.facts(for: row.key)
        #expect(facts.lastWords == "All green.")
        #expect(facts.lastStep == SessionBook.Step(tool: "Bash", target: "git push", ms: t0 + 5 * minute))
        #expect(facts.turnSteps == 1, "this turn took one step")
        #expect(facts.turnStartMs == t0 + 4 * minute)
        #expect(facts.lastError == "")
        #expect(b.facts(for: .process(.claude, pid: 70)) == SessionFacts(), "a key the book does not hold has no facts")
    }

    /// Cursor and OpenCode activity names no tool: their rows have no steps.
    @Test func anAgentWhoseHookNamesNoToolHasNoSteps() throws {
        let b = book([
            AttentionRecord(agent: .cursor, kind: .working, ms: t0, session: "cu1", pid: 72),
            AttentionRecord(agent: .cursor, kind: .tool, ms: t0 + minute, session: "cu1", pid: 72),
        ])
        let row = try #require(rows(b, at: t0 + 2 * minute).first)
        #expect(b.facts(for: row.key).lastStep == nil)
    }

    @Test func withoutATranscriptTheTurnSaysTheLastWords() throws {
        let b = book([AttentionRecord(agent: .opencode, kind: .turn, ms: t0, message: "Queue drains on reconnect", session: "o1", pid: 71)])
        #expect(b.facts(for: SessionKey(.opencode, "o1")).lastWords == "Queue drains on reconnect")
    }

    @Test func theLandingNamesTheTerminal() throws {
        let b = book([AttentionRecord(agent: .claude, kind: .working, ms: t0, session: "s1", pid: 0, landing: "tmux:%3;tty:/dev/ttys009;term:WarpTerminal")])
        let row = try #require(rows(b).first)
        #expect(row.landing.tmuxPane == "%3")
        #expect(row.landing.tty == "ttys009")
        #expect(row.landing.term == "WarpTerminal")
        #expect(row.landingPlan.steps.first == LandingStep.tmuxPane(pane: "%3", socket: "", hostBundleIDs: ["dev.warp.Warp-Stable", "dev.warp.Warp"]))
        #expect(row.landingPlan.precision == .exact)
    }

    /// A stall needs an agent that reports each tool's start and its end
    /// (`AgentID.silenceCanStall`, from its contract) and has sent a step.
    /// From any other a long tool is silent until it ends, so its row
    /// states facts only: never orange, whatever the silence.
    @Test func aStallNeedsAnAgentThatReportsEachToolsStartAndEnd() throws {
        let canStall = AgentID.allCases.filter(\.silenceCanStall)
        #expect(canStall == [.pi, .opencode])
        for agent in AgentID.allCases {
            var b = book([AttentionRecord(agent: agent, kind: .working, ms: t0, session: "c1", pid: 80)])
            #expect(try #require(rows(b, at: t0 + 40 * minute).first).isStalled == false, "no step yet: \(agent.rawValue)")
            b.apply(AttentionRecord(agent: agent, kind: .tool, ms: t0 + minute, session: "c1", tool: "bash"), nowMs: t0 + minute)
            let row = try #require(rows(b, at: t0 + 40 * minute).first)
            #expect(row.isStalled == agent.silenceCanStall, "\(agent.rawValue)")
            #expect(row.isRunning, "\(agent.rawValue)")
        }
    }

    /// Every agent's hook reports its tool calls (its steps); a tool said to
    /// have started (OpenCode's, Pi's) is what runs now, and its silence is
    /// not a stall.
    @Test func everyAgentReportsItsWorkAndARunningToolIsNotAStall() throws {
        for agent in AgentID.allCases {
            #expect(agent.reportsToolActivity, "\(agent.rawValue)")
        }
        var running = book([AttentionRecord(agent: .opencode, kind: .working, ms: t0, session: "x2", pid: 82)])
        running.apply(AttentionRecord(agent: .opencode, kind: .status, ms: t0 + minute, message: "swift build", session: "x2", tool: "bash"), nowMs: t0 + minute)
        let row = try #require(rows(running, at: t0 + 40 * minute).first)
        #expect(row.status == .running(stalled: false), "a 25-minute build says nothing until it ends")
    }

    @Test func aBlockedRowCarriesItsBlock() throws {
        let b = book([AttentionRecord(agent: .pi, kind: .question, ms: t0, message: "Which branch?", session: "p1", pid: 90)])
        let wait = try #require(rows(b).first?.wait)
        #expect(wait.kind == .question)
        #expect(wait.ask == "Which branch?")
        #expect(wait.sinceMs == t0)
    }
}

/// Rows in, the tray out: the order, the lamp, the title and the Waiting
/// edges.
final class TrayAssembleTests: XCTestCase {
    private let now: Int64 = 1_700_000_000_000

    private func row(_ id: String, _ agent: AgentID = .claude, status: AgentRow.Status = .running(stalled: false), task: String = "") -> AgentRow {
        var r = AgentRow(key: SessionKey(agent, id), status: status)
        r.session = id
        r.task = task
        return r
    }

    private func blocked(_ id: String, sinceAgoMs: Int64 = 10 * 60_000) -> AgentRow {
        row(id, status: .needsYou(Block(kind: .permission, ask: "Bash: make", sinceMs: now - sinceAgoMs)))
    }

    private func build(
        _ rows: [AgentRow],
        previousWaits: [SessionKey: Int64] = [:]
    ) -> TrayState {
        TrayState.assemble(
            rows: rows,
            context: TrayState.Context(nowMs: now, lang: .en, previousWaits: previousWaits)
        )
    }

    func testNothingAtAllIsIdleNotError() {
        let r = build([])
        XCTAssertTrue(r.rows.isEmpty)
        XCTAssertEqual(r.snapshot.lamp, .idle)
        XCTAssertEqual(r.activity, .empty)
    }

    func testWaitingSortsAboveEverythingElse() {
        let r = build([row("a", task: "Titled"), blocked("b")])
        XCTAssertEqual(r.rows.map(\.session), ["b", "a"])
        XCTAssertEqual(r.snapshot.lamp, .waiting)
        XCTAssertEqual(r.activity, .waiting)
    }

    func testWaitingRowsAreOrderedOldestFirst() {
        let r = build([blocked("new", sinceAgoMs: 60_000), blocked("old", sinceAgoMs: 600_000)])
        XCTAssertEqual(r.rows.map(\.session), ["old", "new"])
    }

    func testMenuBarTitleCarriesCountAndAge() {
        XCTAssertEqual(build([blocked("a")]).snapshot.title, "1 · 10m")
        XCTAssertEqual(build([blocked("a", sinceAgoMs: 1_000)]).snapshot.title, "1", "a fresh wait does not spend space on now")
        XCTAssertEqual(build([blocked("a", sinceAgoMs: 59_000)]).snapshot.title, "1", "nor does one under a minute")
    }

    func testNothingBlockedMeansNoTitle() {
        XCTAssertEqual(build([row("a")]).snapshot.title, "")
        XCTAssertEqual(build([row("a")]).snapshot.lamp, .running)
    }

    func testProcessOnlyRunningIsAGreyDottedGlance() {
        let r = build([AgentRow(key: .process(.claude, pid: 1), status: .processOnly)])
        XCTAssertEqual(r.snapshot.lamp, .processOnly)
        XCTAssertEqual(r.activity, .recent, "a bare process does not hold the running tick")
    }

    func testAFinishedTurnIsNotRunning() {
        let r = build([row("a", status: .yourTurn(sinceMs: now - 60_000))])
        XCTAssertEqual(r.snapshot.lamp, .idle)
        XCTAssertEqual(r.activity, .recent)
    }

    /// No fold: the tray lists every session and scrolls inside the
    /// tray's height — there is no "and N more" to click.
    func testEveryRowIsListedWithoutAFold() {
        let r = build((0..<30).map { row("k\($0)") })
        XCTAssertEqual(r.rows.count, 30)
        XCTAssertEqual(r.snapshot.counts.running, 30)
    }

    func testCountsCoverTheWholeList() {
        let r = build([blocked("w")] + (0..<4).map { row("k\($0)") })
        XCTAssertEqual(r.snapshot.counts.blocked, 1)
        XCTAssertEqual(r.snapshot.counts.running, 4)
    }

    func testFirstSightOfAWaitIsReportedAsNew() {
        XCTAssertEqual(build([blocked("a")]).newlyBlocked.map(\.session), ["a"])
    }

    func testAWaitAlreadyKnownIsNotReportedAgain() {
        let wait = blocked("a")
        XCTAssertTrue(build([wait], previousWaits: [wait.key: wait.wait?.sinceMs ?? 0]).newlyBlocked.isEmpty)
    }

    func testASecondAskOnAWaitingRowIsANewEdge() {
        let wait = blocked("a", sinceAgoMs: 30_000)
        let second = build([wait], previousWaits: [wait.key: now - 120_000])
        XCTAssertEqual(second.newlyBlocked.map(\.session), ["a"])
    }

    /// A later raise inside the slack is news only when the session moved
    /// in between — its activity, from the book.
    func testALaterRaiseInsideTheSlackIsNewOnlyAfterWork() {
        XCTAssertFalse(TrayState.isNewRaise(sinceMs: now, previousSinceMs: now - 5_000, activityMs: now - 6_000))
        XCTAssertTrue(TrayState.isNewRaise(sinceMs: now, previousSinceMs: now - 5_000, activityMs: now - 1_000))
        XCTAssertTrue(TrayState.isNewRaise(sinceMs: now, previousSinceMs: now - 30_000, activityMs: 0), "past the slack")
        XCTAssertFalse(TrayState.isNewRaise(sinceMs: now - 5_000, previousSinceMs: now - 5_000, activityMs: now), "the same raise")
        let wait = blocked("a", sinceAgoMs: 1_000)
        let quiet = TrayState.assemble(rows: [wait], context: .init(nowMs: now, previousWaits: [wait.key: now - 6_000]))
        XCTAssertTrue(quiet.newlyBlocked.isEmpty)
        let moved = TrayState.assemble(
            rows: [wait], context: .init(nowMs: now, previousWaits: [wait.key: now - 6_000]),
            activityMs: [wait.key: now - 3_000]
        )
        XCTAssertEqual(moved.newlyBlocked.map(\.key), [wait.key])
    }

    /// The next projection's `previousWaits`: when each open wait was raised.
    func testTheOpenWaitsAreHandedOn() {
        let r = build([blocked("a", sinceAgoMs: 60_000), row("b")])
        XCTAssertEqual(r.waitingSince, [SessionKey(.claude, "a"): now - 60_000])
        XCTAssertTrue(build([row("a")], previousWaits: [SessionKey(.claude, "a"): now - 60_000]).waitingSince.isEmpty, "a resolved wait is gone")
    }

    func testTheGlanceTooltipIsInTheResolvedLanguage() {
        let en = TrayState.assemble(rows: [blocked("a")], context: .init(nowMs: now, lang: .en)).snapshot.tooltip
        let zh = TrayState.assemble(rows: [blocked("a")], context: .init(nowMs: now, lang: .zh)).snapshot.tooltip
        XCTAssertNotEqual(en, zh)
    }

    /// The same world projects the same value: two ticks of an unchanged
    /// book are equal, so nothing lands — a tool line in a running session
    /// moves the book's facts, not the projection.
    func testTheSameWorldProjectsTheSameValue() {
        var book = SessionBook()
        book.apply(AttentionRecord(agent: .claude, kind: .working, ms: now - 60_000, session: "s1", pid: 0), nowMs: now)
        book.apply(AttentionRecord(agent: .claude, kind: .permission, ms: now - 50_000, message: "Bash: make", session: "s2"), nowMs: now)
        let first = TrayState.project(book: book, processes: [], context: .init(nowMs: now))
        let later = TrayState.project(book: book, processes: [], context: .init(nowMs: now + 2_000, previousWaits: first.waitingSince))
        XCTAssertEqual(first.rows, later.rows)
        XCTAssertEqual(first.snapshot, later.snapshot)
        book.apply(AttentionRecord(agent: .claude, kind: .tool, ms: now + 1_000, message: "a.swift", session: "s1", tool: "Read"), nowMs: now + 1_000)
        let afterTool = TrayState.project(book: book, processes: [], context: .init(nowMs: now + 2_000, previousWaits: first.waitingSince))
        XCTAssertEqual(afterTool.rows, later.rows, "a step is a fact, not state")
        XCTAssertEqual(book.facts(for: SessionKey(.claude, "s1")).lastStep?.target, "a.swift")
    }
}

/// A row's key is decided once and never changes.
@Suite("Session key")
struct SessionKeyTests {
    @Test func eachKindOfRowHasItsOwnKey() {
        #expect(SessionKey(.claude, "abc").description == "claude|abc")
        #expect(SessionKey.process(.codex, pid: 7).description == "codex|pid:7")
        #expect(SessionKey(.claude, "", cwd: "/w").description.hasPrefix("claude|hook:"))
        #expect(SessionKey(.claude, "", cwd: "/w").isSessionless)
        #expect(SessionKey(.claude, "  abc ") == SessionKey(.claude, "abc"), "the id is trimmed")
    }

    @Test func theHashIsStableAcrossLaunches() {
        #expect(SessionKey.stableHash("/Users/me/app") == SessionKey.stableHash("/Users/me/app"))
        #expect(SessionKey.stableHash("/Users/me/app") != SessionKey.stableHash("/Users/me/other"))
        #expect(!SessionKey(.claude, "", cwd: "/Users/me/app").description.contains("/Users"), "a key never carries a path")
    }

    /// The session's key comes from its first event and every later event
    /// finds the same session — a start, a prompt, a turn.
    @Test func everyEventOfASessionFindsTheSameKey() {
        var book = SessionBook()
        let t0: Int64 = 1_800_000_000_000
        let kinds: [AttentionKind] = [.start, .working, .permission, .turn]
        for (index, kind) in kinds.enumerated() {
            book.apply(AttentionRecord(agent: .claude, kind: kind, ms: t0 + Int64(index) * 60_000, session: "abc", cwd: "/w/\(index)"), nowMs: t0 + 600_000)
        }
        #expect(Array(book.sessions.keys) == [SessionKey(.claude, "abc")])
        #expect(book.sessions[SessionKey(.claude, "abc")]?.cwd == "/w/3", "facts move; the key does not")
    }

    /// A process-only row simply is not built once a hook names the
    /// session that process runs.
    @Test func whenTheSessionSpeaksTheProcessRowSimplyGoes() {
        let t0: Int64 = 1_800_000_000_000
        let hit = AgentProcesses.Hit(agent: .claude, pid: 4242, cwd: "/w/app")
        let context = TrayState.Context(nowMs: t0)
        var book = SessionBook()
        let before = TrayState.project(book: book, processes: [hit], context: context).rows.map(\.key)
        #expect(before == [.process(.claude, pid: 4242)])
        book.apply(AttentionRecord(agent: .claude, kind: .working, ms: t0, session: "abc", pid: 4242), nowMs: t0)
        let after = TrayState.project(book: book, processes: [hit], context: context).rows.map(\.key)
        #expect(after == [SessionKey(.claude, "abc")])
    }
}

/// What a row may show as its title: a person's goal, never chrome.
final class AgentRowTests: XCTestCase {
    private func row(_ agent: AgentID = .claude, _ mutate: (inout AgentRow) -> Void) -> AgentRow {
        var r = AgentRow(key: SessionKey(agent, "s1"))
        mutate(&r)
        return r
    }

    /// Placeholders, a vendor's generic "<Agent> session" and its bare name
    /// are chrome in any case; a real goal that merely contains "session" is not.
    func testPlaceholderTitlesAreNotTitles() {
        for junk in [
            "-", "—", "Running", "running", "Active", "none", "Agent session", "Chat",
            "New Session", "Untitled", "  Untitled  ", "New Chat", "new chat",
            "COPILOT SESSION", "Cursor session", "OpenCode session", "Pi session",
        ] {
            XCTAssertNil(row { $0.task = junk }.usefulTask, "\(junk) is not a real session title")
        }
        for title in TitleHeuristics.chromeTitles {
            XCTAssertNil(row { $0.task = title.uppercased() }.usefulTask, "\(title) must be chrome in either case")
        }
        for agent in AgentID.allCases {
            XCTAssertNil(row(agent) { $0.task = "\(agent.displayName) session"; $0.session = "real-id" }.usefulTask)
            XCTAssertNil(row(agent) { $0.task = agent.displayName; $0.session = "real-id" }.usefulTask)
        }
        XCTAssertFalse(TitleHeuristics.isChromeTitle("Auth session"))
        XCTAssertFalse(TitleHeuristics.isChromeTitle("Fix the tray hero"))
    }

    func testBarePathIsNotASessionTitle() {
        XCTAssertNil(row { $0.task = "/Users/me/code" }.usefulTask)
        XCTAssertNotNil(row { $0.task = "/Users/me fix the parser" }.usefulTask)
    }

    func testMarkdownBecomesAReadablePlainTitle() {
        let raw = "[hxddh/Pulse](https://github.com/hxddh/Pulse) 本地有安装最新版"
        let r = row { $0.task = raw }
        XCTAssertEqual(r.usefulTask, "hxddh/Pulse 本地有安装最新版")
        XCTAssertEqual(r.task, raw, "presentation cleanup must not rewrite evidence")
        XCTAssertEqual(row { $0.task = "Inspect ![failure](file:///tmp/failure.png)" }.usefulTask, "Inspect failure")
    }

    func testInternalToolIdentifiersAreNotSessionTitles() {
        XCTAssertNil(row { $0.task = "update_plan" }.usefulTask)
        XCTAssertEqual(row { $0.task = "update_auth" }.usefulTask, "update_auth")
        XCTAssertNil(row { $0.task = "Read Models.swift" }.usefulTask)
        XCTAssertNil(row { $0.task = "Models.swift" }.usefulTask)
        XCTAssertNotNil(row { $0.task = "Improve tray density" }.usefulTask)
    }

    /// A process-only row has no title, and its headline is never the
    /// agent's product name (the icon already says who).
    func testProcessOnlyRowHasNoSessionTitleToShow() {
        let r = row(.codex) { $0.status = .processOnly; $0.liveProcess = true }
        XCTAssertNil(r.usefulTask)
        XCTAssertNotEqual(TrayRowModel.headline(r, lang: .en, nowMs: 1_700_000_000_000), r.agent.displayName)
    }

    func testShortProjectDropsHashesAndIsBounded() {
        XCTAssertEqual(TitleHeuristics.shortProject("/Users/me/code/Pulse"), "Pulse")
        XCTAssertEqual(TitleHeuristics.shortProject("a1b2c3d4e5f60718"), "", "hash is not a project name")
        XCTAssertEqual(TitleHeuristics.shortProject(""), "")
        let short = TitleHeuristics.shortProject(String(repeating: "x", count: 40))
        XCTAssertLessThanOrEqual(short.count, 24)
        XCTAssertTrue(short.hasSuffix("…"))
    }
}

/// Where a row is, and how long it has been quiet.
final class RowContextTests: XCTestCase {
    private let home = FileManager.default.homeDirectoryForCurrentUser.path
    private let now: Int64 = 1_700_000_000_000

    private func row(cwd: String = "") -> AgentRow {
        var r = AgentRow(key: SessionKey(.claude, "k"))
        r.cwd = cwd
        return r
    }

    /// Home — or its encoded form — is not a project; anything under it is,
    /// written with a tilde.
    func testHomeIsNotAProject() {
        let user = (home as NSString).lastPathComponent
        XCTAssertEqual(row(cwd: home).displayPath, "")
        XCTAssertTrue(TitleHeuristics.isHomeLike("users-\(user)", home: home))
        XCTAssertTrue(TitleHeuristics.isHomeLike(user, home: home))
        XCTAssertEqual(row(cwd: home + "/Documents/Cursor").displayPath, "~/Documents/Cursor")
        XCTAssertFalse(TitleHeuristics.isHomeLike("/tmp/alpha", home: home))
    }

    /// A deep path keeps its tail; a shallow one is left alone; no location
    /// is no path; the project is the folder's short name.
    func testPathsKeepWhatIdentifiesThem() {
        let deep = row(cwd: "/a/b/c/d/e/Pulse").displayPath
        XCTAssertTrue(deep.hasSuffix("e/Pulse"), deep)
        XCTAssertTrue(deep.contains("…"), deep)
        XCTAssertEqual(row(cwd: "/tmp/alpha").displayPath, "/tmp/alpha")
        XCTAssertEqual(row().displayPath, "")
        XCTAssertEqual(row(cwd: "/Users/me/code/Pulse").project, "Pulse")
    }

    func testActivityAgeCountsFromTheLastEventAndUnknownIsZero() {
        XCTAssertEqual(SessionFacts().lastActivitySeconds(at: now), 0)
        XCTAssertEqual(SessionFacts(lastEventMs: now - 600_000).lastActivitySeconds(at: now), 600, accuracy: 0.001)
    }

    /// Twenty minutes without an event is a stall; an unknown clock is not
    /// evidence of silence.
    func testTwentyMinutesOfSilenceIsAStall() {
        func stalled(_ agoSeconds: Double) -> Bool {
            AgentRow.stalled(lastActivityMs: now - Int64(agoSeconds * 1000), nowMs: now)
        }
        XCTAssertEqual(AgentRow.stalledSeconds, 20 * 60)
        XCTAssertTrue(stalled(21 * 60))
        XCTAssertFalse(stalled(19 * 60))
        XCTAssertFalse(AgentRow.stalled(lastActivityMs: 0, nowMs: now))
    }

    /// A stalled row is an orange ring with its why on the second line.
    func testStalledRowsSayWhy() {
        var r = row()
        r.liveProcess = true
        r.status = .running(stalled: true)
        let face = TrayRowModel.make(TrayRowModel.Input(row: r, facts: SessionFacts(lastEventMs: now - 25 * 60 * 1000), lang: .en, nowMs: now))
        XCTAssertEqual(face.lamp, .stalled)
        XCTAssertEqual(face.secondLine?.kind, .warning)
        XCTAssertEqual(face.secondLine?.text, face.why)
    }
}
