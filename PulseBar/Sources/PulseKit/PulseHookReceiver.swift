import Foundation

/// Native receiver for every supported agent's hook, plugin or extension
/// (`pulse-hook` / `PulseBar --hook`).
///
/// `pulse-hook <agent> <event>` with the vendor's JSON payload on stdin (or,
/// for the two modules, as the last argument). Each agent's adapter
/// (`Agents/`) maps its own event names and payload onto a `HookAction`;
/// nothing else is read — not the protocol's kind words, not plain text.
/// Every event it hears is one v7 line in the event log (`EventLog` — the
/// only file it writes), and it exits 0 at once. An event it does not turn
/// into state — one Pulse does not install, a payload that is not a JSON
/// object, a blocked event from an agent whose hooks cannot report one
/// (`waiting: .none`, no fake Waiting) — is an `ignored` line that says why.
/// Nothing is ever held: the vendor's own prompt is always in charge.
package enum PulseHookReceiver {
    /// Why a heard event became an `ignored` line — its `message`.
    package enum Ignored: String, Sendable {
        /// The installed command named no event.
        case noEvent = "no event named"
        /// An event Pulse does not install for this agent.
        case notInstalled = "not an installed event"
        /// The payload is not a JSON object: cut off at `stdinLimit`, a
        /// writer that died mid-write, plain text.
        case unparsable = "payload is not a JSON object"
        /// A blocked event from an agent whose hooks cannot report a wait.
        case cannotWait = "blocked event from an agent that does not report waits"
        /// Activity or a prompt that names no session: no row to belong to.
        case noSession = "no session"
        /// A known event that says nothing Pulse shows.
        case silent = "says nothing Pulse shows"
    }

    /// Always returns 0 — vendor hooks must never be broken by Pulse.
    ///
    /// `logURL` nil writes the real event log; a test passes a temporary one
    /// (never a global override — suites run in parallel). `locate` finds
    /// the agent's pid and the landing handles; tests pass a fixed answer,
    /// and `front` whether the prompt's window is frontmost — an AppKit
    /// question, so the app passes it (`PromptVisibility.promptIsFrontmost`);
    /// unknown otherwise.
    @discardableResult
    package static func run(
        arguments: [String],
        stdin: String = "",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logURL: URL? = nil,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        locate: (AgentID, [String: String]) -> (pid: Int32, landing: String) = HookLanding.current,
        front: () -> Bool? = { nil }
    ) -> Int32 {
        let args = Array(arguments.drop(while: { $0 != "--hook" }).dropFirst())
        let agentRaw = (args.first ?? "claude").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Not one of the six — or another tool running this agent's hooks
        // as its own: there is no agent to write a line for.
        guard let agent = attributedAgent(agentRaw, environment: environment) else {
            DebugLog.write("attention reject agent=\(agentRaw)")
            return 0
        }
        let event = args.count > 1 && !args[1].hasPrefix("{") ? args[1] : ""
        var written: AttentionRecord
        if var payload = parsePayload(stdin: stdin, trailingArg: args.count > 1 ? args.last : nil) {
            if let msg = payload["msg"] as? [String: Any], payload["type"] == nil {
                payload.merge(msg) { current, _ in current }
            }
            written = record(agent: agent, event: event, payload: payload, nowMs: nowMs)
        } else {
            // Its raw text would become a ghost wait whose ask is broken
            // JSON: it is heard, and said to be unreadable — nothing else.
            written = ignored(.unparsable, agent: agent, event: event, context: HookContext(payload: [:]), nowMs: nowMs)
        }
        // Was the prompt's own window in front as this was raised? A turn
        // the user watched finish is not owed to them, and a blocked prompt
        // already on screen needs no banner.
        if written.kind.isOpen { written.front = front() }
        let located = locate(agent, environment)
        written.pid = located.pid > 1 ? located.pid : 0
        written.landing = cleanField(located.landing, limit: 240)
        EventLog.append(written, at: logURL, nowMs: nowMs)
        return 0
    }

    /// The v7 line one vendor event becomes, before the hook's own facts
    /// (front, pid, landing) and its `seq` are added — a state, or an
    /// `ignored` line saying why not. Pure.
    package static func record(agent: AgentID, event rawEvent: String, payload: [String: Any], nowMs: Int64) -> AttentionRecord {
        let context = HookContext(payload: payload)
        let event = rawEvent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let reading = interpret(agent: agent, event: event, payload: payload) else {
            return ignored(event.isEmpty ? .noEvent : .notInstalled, agent: agent, event: event, context: context, nowMs: nowMs)
        }
        // No fake Waiting: an agent whose hooks cannot say it is blocked is
        // never shown blocked.
        if case .blocked = reading.action, agent.waitingSource == .none {
            return ignored(.cannotWait, agent: agent, event: event, context: context, nowMs: nowMs)
        }
        let tool = cleanField(string(payload, keys: ["tool_name", "toolName"]), limit: 64)
        let kind: AttentionKind
        var message = ""
        var toolColumn = ""
        switch reading.action {
        case .ignore:
            return ignored(.silent, agent: agent, event: event, context: context, nowMs: nowMs)
        case .activity:
            // A tool with no session cannot be matched to anything, and
            // would make a row of its own.
            guard !context.session.isEmpty else {
                return ignored(.noSession, agent: agent, event: event, context: context, nowMs: nowMs)
            }
            kind = .tool
            toolColumn = tool
            let descriptor = toolDescriptor(from: payload)
            if !tool.isEmpty, descriptor.hasPrefix(tool + ": ") {
                message = String(descriptor.dropFirst(tool.count + 2))
            }
        case .status:
            guard !context.session.isEmpty else {
                return ignored(.noSession, agent: agent, event: event, context: context, nowMs: nowMs)
            }
            kind = .status
        case .prompt:
            // Session-scoped only: an agent-wide clear from one terminal
            // must not clear another's.
            guard !context.session.isEmpty else {
                return ignored(.noSession, agent: agent, event: event, context: context, nowMs: nowMs)
            }
            kind = .working
            // What the person typed: the session's title and latest prompt.
            message = TitleHeuristics.promptTitle(string(payload, keys: ["prompt"]), limit: 200)
        case .start:
            kind = .start
        case .blocked(let blocked):
            kind = blocked.isBlocking ? blocked : .waiting
            message = reading.ask.isEmpty ? genericMessage(from: payload, blocked: true) : reading.ask
            toolColumn = tool
        case .turn:
            kind = .turn
            message = genericMessage(from: payload)
        case .failedTurn:
            kind = .failed
            message = errorMessage(from: payload)
        case .idle:
            kind = .idle
        case .resolved:
            kind = .done
        case .end:
            kind = .end
        }
        return AttentionRecord(
            agent: agent,
            kind: kind,
            ms: nowMs,
            message: cleanField(message, limit: 200),
            session: cleanField(context.session, limit: 80),
            cwd: cleanField(context.cwd, limit: 240),
            tool: toolColumn,
            event: cleanField(event, limit: 64)
        )
    }

    /// An `ignored` line: who, which event, where — and why, never the
    /// payload's words.
    package static func ignored(
        _ reason: Ignored, agent: AgentID, event: String, context: HookContext, nowMs: Int64
    ) -> AttentionRecord {
        AttentionRecord(
            agent: agent,
            kind: .ignored,
            ms: nowMs,
            message: reason.rawValue,
            session: cleanField(context.session, limit: 80),
            cwd: cleanField(context.cwd, limit: 240),
            event: cleanField(event, limit: 64)
        )
    }

    // MARK: - Reading

    /// One agent's event — the argument the installed command carries —
    /// read by its own adapter (`AgentSpec.reading`); nil for an event Pulse
    /// does not install (or none at all): it writes nothing.
    package static func interpret(agent: AgentID, event: String, payload: [String: Any]) -> HookReading? {
        agent.spec.reading(event.trimmingCharacters(in: .whitespacesAndNewlines), payload: payload)
    }

    // MARK: - stdin

    /// Whether the payload already came in argv (the OpenCode plugin and the
    /// Pi extension pass their JSON as the last argument) — then stdin is not
    /// read at all.
    package static func payloadInArguments(_ arguments: [String]) -> Bool {
        arguments.drop(while: { $0 != "--hook" }).dropFirst().dropFirst().contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("{")
        }
    }

    /// The most a hook payload may be; anything past it is not read.
    package static let stdinLimit = 1 << 20

    /// Vendors pipe JSON on stdin, but a caller that leaves stdin open (a
    /// terminal, a wrapper that never closes the pipe) must not keep the hook
    /// — and the agent waiting on it — alive. Read on a background thread,
    /// wait at most `timeout`, keep at most `limit` bytes; whatever arrived
    /// by then is the payload. The reader thread is abandoned on a timeout:
    /// the process exits right after.
    package static func readStdin(timeout: TimeInterval = 1, limit: Int = stdinLimit) -> String {
        let box = Guarded(Data())
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let got = buffer.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
                if got < 0, errno == EINTR { continue }
                if got <= 0 { break }
                let full = box.withValue { (data: inout Data) -> Bool in
                    data.append(contentsOf: buffer[0..<got])
                    if data.count > limit { data = data.prefix(limit) }
                    return data.count >= limit
                }
                if full { break }
            }
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + timeout)
        // Lossy: one invalid byte never loses the whole payload.
        return String(decoding: box.snapshot, as: UTF8.self)
    }

    // MARK: - Attribution

    /// The agent an invocation speaks for, or nil when it is none of the
    /// supported six — or another tool running this agent's hooks as its
    /// own (`AgentSpec.foreignCallers`: Grok Build marks its calls to
    /// Claude's hooks), whose events must never land on this agent's row.
    package static func attributedAgent(_ raw: String, environment: [String: String]) -> AgentID? {
        guard let agent = Agents.agent(named: raw) else { return nil }
        if agent.spec.foreignCallers.contains(where: { !(environment[$0] ?? "").isEmpty }) {
            return nil
        }
        return agent
    }

    // MARK: - Parse

    /// The payload on stdin, else the one in the last argument, else none
    /// (`[:]` — an event that carries no payload). Nil when what arrived is
    /// not a JSON object — cut off at `stdinLimit`, broken, or plain text:
    /// it writes nothing.
    package static func parsePayload(stdin: String, trailingArg: String?) -> [String: Any]? {
        let trimmed = stdin.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return object(trimmed) }
        if let trailingArg, trailingArg.trimmingCharacters(in: .whitespaces).hasPrefix("{") {
            return object(trailingArg)
        }
        return [:]
    }

    private static func object(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// What a turn or a block says, when its adapter found no specific ask.
    /// A block never takes `reason`: it is an event's why (Pi's
    /// `ui_prompt`, a shutdown's `exit`), not what is asked.
    package static func genericMessage(from payload: [String: Any], blocked: Bool = false) -> String {
        let keys = ["last_assistant_message", "message", "body"]
            + (blocked ? [] : ["reason"]) + ["title"]
        for key in keys {
            if let value = payload[key] as? String {
                let folded = condenseOneLine(value, limit: 200)
                if !folded.isEmpty { return folded }
            }
        }
        return toolDescriptor(from: payload)
    }

    /// What a failed turn said went wrong: Claude StopFailure's rendered
    /// error (`last_assistant_message`, else `error_details`, else its
    /// `error` type), Copilot's `error.message`, the OpenCode plugin's
    /// `error` — the hook's own words only.
    package static func errorMessage(from payload: [String: Any]) -> String {
        var text = string(payload, keys: ["last_assistant_message", "error_details", "error", "message"])
        if text.isEmpty, let error = payload["error"] as? [String: Any] {
            text = string(error, keys: ["message", "name"])
            if text.isEmpty, let data = error["data"] as? [String: Any] { text = string(data, keys: ["message"]) }
        }
        return condenseOneLine(text, limit: 200)
    }

    /// What is actually being asked, when the vendor sends no prose.
    ///
    /// Claude's `PermissionRequest` payload has **no** `message` field — the
    /// ask *is* the tool call (`tool_name` + `tool_input`). Field priority
    /// mirrors the vendor's own permission label (`command` → `file_path` →
    /// `url`). Copilot sends `toolArgs` as a JSON string; it is read as the
    /// object it encodes. Everything here still passes through `cleanField`,
    /// which redacts credentials and bounds the field.
    package static func toolDescriptor(from payload: [String: Any]) -> String {
        let tool = string(payload, keys: ["tool_name", "toolName"])
        guard !tool.isEmpty else { return "" }
        guard let input = toolInput(payload) else { return tool }
        for key in ["command", "file_path", "url", "path", "notebook_path", "pattern", "query"] {
            guard let raw = input[key] as? String else { continue }
            let target = condenseOneLine(raw)
            guard !target.isEmpty else { continue }
            return "\(tool): \(target)"
        }
        return tool
    }

    /// A tool call's arguments: `tool_input` / `toolArgs` as an object, or
    /// `toolArgs` as a JSON string holding one (Copilot).
    package static func toolInput(_ payload: [String: Any]) -> [String: Any]? {
        if let input = payload["tool_input"] as? [String: Any] { return input }
        if let input = payload["toolArgs"] as? [String: Any] { return input }
        guard let raw = payload["toolArgs"] as? String,
              raw.trimmingCharacters(in: .whitespaces).hasPrefix("{"),
              let data = raw.data(using: .utf8)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A banner, a tray row and a TSV field are all single-line: fold every
    /// run of whitespace and bound the result before it ever reaches them.
    /// Credentials are redacted from the whole value first: a cut made
    /// before redaction could leave a token's head too short to match.
    package static func condenseOneLine(_ raw: String, limit: Int = 140) -> String {
        let folded = ContentSanitizer.redact(raw).split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard folded.count > limit else { return folded }
        return String(folded.prefix(limit - 1)) + "…"
    }

    package static func string(_ payload: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = payload[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return ""
    }

    /// One field of a v7 line: credentials redacted, every tab and line
    /// break — `\n`, `\r`, VT, FF, NEL, U+2028, U+2029 — a space
    /// (`AttentionProtocol.flatten`), bounded.
    package static func cleanField(_ value: String, limit: Int) -> String {
        let flat = AttentionProtocol.flatten(ContentSanitizer.redact(value))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(flat.prefix(limit))
    }
}

/// The identity fields every vendor's payload spells its own way.
package struct HookContext: Equatable {
    package var session: String
    package var cwd: String
    /// The vendor's transcript path, when its payload names one — used only
    /// to name a session that has no id; never written, never read.
    package var transcript: String

    package init(payload: [String: Any]) {
        session = String(PulseHookReceiver.string(payload, keys: [
            "session_id", "sessionId", "sessionID", "thread_id", "threadId",
            "conversation_id", "conversationId",
        ]).prefix(80))
        transcript = PulseHookReceiver.string(payload, keys: [
            "transcript_path", "transcriptPath", "session_file", "sessionFile", "rollout_path",
        ])
        var dir = PulseHookReceiver.string(payload, keys: ["cwd", "directory", "workdir", "working_directory", "workspace_root"])
        if dir.isEmpty, let roots = payload["workspace_roots"] as? [Any],
           let first = roots.compactMap({ $0 as? String }).first {
            dir = first
        }
        cwd = dir.hasPrefix("/") ? String(dir.prefix(240)) : ""
        // A session named only by its transcript file (a vendor that sends
        // no id): the file's own name. The file itself is never read.
        if session.isEmpty, !transcript.isEmpty {
            var name = URL(fileURLWithPath: transcript).lastPathComponent
            if name.hasSuffix(".jsonl") { name = String(name.dropLast(".jsonl".count)) }
            session = String(name.prefix(80))
        }
    }
}
