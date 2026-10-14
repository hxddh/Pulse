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
extension SessionKey: @retroactive ExpressibleByStringLiteral {
    package init(stringLiteral text: String) {
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

/// One vendor hook event as `pulse-hook` writes it — one v7 line, or none
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
        #expect(session?.steps.first == SessionBook.Step(tool: "bash", target: "ls build", ms: t0 + 3 * minute))
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
            (.copilot, "postToolUse", ["toolName": "bash", "toolArgs": #"{"command":"npm test"}"#], "bash", "npm test"),
            (.pi, "tool_execution_end", ["tool_name": "edit", "tool_input": ["path": "src/x.ts"]], "edit", "src/x.ts"),
        ]
        for (agent, event, payload, tool, target) in cases {
            var book = SessionBook()
            for line in HookFeed.write(agent, event, payload, at: t0).lines { book.apply(line, nowMs: t0) }
            let step = book.sessions[SessionKey(agent, "s1")]?.steps.last
            #expect(step == SessionBook.Step(tool: tool, target: target, ms: t0), "\(agent.rawValue)")
        }
        let quiet: [(AgentID, String, [String: Any])] = [(.cursor, "afterAgentResponse", [:]), (.opencode, "session.status", ["status": "busy"])]
        for (agent, event, payload) in quiet {
            var book = SessionBook()
            for line in HookFeed.write(agent, event, payload, at: t0).lines { book.apply(line, nowMs: t0) }
            let steps = book.sessions[SessionKey(agent, "s1")]?.steps ?? []
            #expect(steps.isEmpty, "\(agent.rawValue)")
        }
        let prompts: [(AgentID, String)] = [(.claude, "UserPromptSubmit"), (.codex, "UserPromptSubmit"), (.copilot, "userPromptSubmitted"), (.pi, "message_start")]
        for (agent, event) in prompts {
            var book = SessionBook()
            for line in HookFeed.write(agent, event, ["prompt": "Fix the flaky login test"], at: t0).lines { book.apply(line, nowMs: t0) }
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
        #expect(!installed.contains("PermissionDenied"), "its output can ask for a retry")
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
        #expect(AttentionRecord(agent: .claude, kind: .working, ms: t0, pid: 1).line.split(separator: "\t", omittingEmptySubsequences: false)[7] == "", "the pid column")
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
        let error = book.sessions[SessionKey(.opencode, "s1")]?.lastError
        #expect(error == "Model unavailable")
        #expect(HookFeed.word(book.sessions[SessionKey(.opencode, "s1")]?.state) == "turn")
        let next = t0 + 5 * minute
        for line in HookFeed.write(.opencode, "session.status", ["status": ["type": "busy"]], at: next).lines { book.apply(line, nowMs: next) }
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
        #expect(openCode.book.sessions[SessionKey(.opencode, "s1")]?.steps.isEmpty == true, "a status is not a step")
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
        let steps = claude.book.sessions[SessionKey(.claude, "s1")]?.steps.map(\.tool)
        #expect(steps == ["status"])
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

    /// An `ignored` line records what the receiver heard; it is no state —
    /// it makes no session and moves none.
    @Test func anIgnoredLineIsNoState() {
        var book = SessionBook()
        let heard = AttentionRecord(agent: .claude, kind: .ignored, ms: t0, message: PulseHookReceiver.Ignored.notInstalled.rawValue, session: "s1", event: "SubagentStop")
        let made = book.apply(heard, nowMs: t0)
        #expect(!made)
        #expect(book.sessions.isEmpty)
        book.apply(AttentionRecord(agent: .claude, kind: .permission, ms: t0, message: "Bash: ls", session: "s1"), nowMs: t0)
        let moved = book.apply(AttentionRecord(agent: .claude, kind: .ignored, ms: t0 + second, session: "s1"), nowMs: t0 + second)
        #expect(!moved)
        #expect(HookFeed.word(book.sessions[SessionKey(.claude, "s1")]?.state) == "blocked:permission")
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

    /// An interrupted turn sends no Stop. From an agent that reports
    /// its tools, silence is a stall for a while — then, past
    /// `silentBoundMs`, the session is recent and says why: never an
    /// endless orange.
    @Test func anInterruptedTurnStallsThenGoesQuiet() throws {
        let b = book([
            AttentionRecord(agent: .claude, kind: .working, ms: t0, session: "s1", pid: 41),
            AttentionRecord(agent: .claude, kind: .tool, ms: t0 + minute, session: "s1", pid: 41, tool: "Bash"),
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
        #expect(facts.steps.count == 3)
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
        #expect(b.facts(for: row.key).steps.isEmpty)
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

    @Test func aStallNeedsAnAgentThatReportsItsWork() throws {
        var b = book([AttentionRecord(agent: .codex, kind: .working, ms: t0, session: "c1", pid: 80)])
        #expect(try #require(rows(b, at: t0 + 40 * minute).first).isStalled == false, "no activity events: silence is not evidence")
        b.apply(AttentionRecord(agent: .codex, kind: .tool, ms: t0 + minute, session: "c1"), nowMs: t0 + minute)
        #expect(try #require(rows(b, at: t0 + 40 * minute).first).isStalled)
    }

    /// Only an agent whose hook reports every tool call can be
    /// stalled. Cursor and OpenCode speak at a prompt and at the end of a
    /// reply; a long turn is silent, and silence from them is not evidence.
    @Test func aLongTurnIsNotAStallForAnAgentWithoutToolEvents() throws {
        #expect(AgentID.claude.reportsToolActivity)
        #expect(AgentID.codex.reportsToolActivity)
        #expect(AgentID.copilot.reportsToolActivity)
        #expect(AgentID.pi.reportsToolActivity)
        #expect(!AgentID.cursor.reportsToolActivity)
        #expect(!AgentID.opencode.reportsToolActivity)
        for agent in [AgentID.cursor, .opencode] {
            var b = book([AttentionRecord(agent: agent, kind: .working, ms: t0, session: "x1", pid: 81)])
            b.apply(AttentionRecord(agent: agent, kind: .tool, ms: t0 + minute, session: "x1"), nowMs: t0 + minute)
            let row = try #require(rows(b, at: t0 + 40 * minute).first)
            #expect(row.status == .running(stalled: false), "\(agent.rawValue)")
        }
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
