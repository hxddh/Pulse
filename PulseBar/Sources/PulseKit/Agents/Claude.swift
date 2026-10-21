import Foundation

extension AgentSpec {
    /// Claude Code (code.claude.com/docs/en/hooks). Every entry runs
    /// `async: true`: an async hook cannot block or decide anything ("Run
    /// hooks in the background").
    package static let claude = AgentSpec(
        id: .claude,
        displayName: "Claude",
        aliases: [],
        // PermissionRequest (at once) and Notification permission_prompt,
        // elicitation_dialog (about six seconds later) — not when nobody can be
        // shown it, and never agent_needs_input (it may be another session's).
        waiting: .hooks,
        // The native install's `~/.local/bin/claude` links into
        // `~/.local/share/claude/versions/<version>`, the path the kernel
        // reports for the running binary.
        // `claude -p` runs with nobody at a prompt: a PermissionRequest
        // there is auto-denied unless a permission host
        // (`--permission-prompt-tool`, the Agent SDK's) answers it.
        process: AgentProcessRule(
            basenames: ["claude"],
            pathNeedles: ["/.local/bin/claude", "/bin/claude", "/.local/share/claude/versions/"],
            argvDenyNeedles: ["Claude.app", "chrome-native-host"],
            promptlessFlags: ["-p", "--print"],
            promptHostFlags: ["--permission-prompt-tool"]
        ),
        // PostToolUse, not PreToolUse, marks activity; PostToolUseFailure
        // is the same for a tool that failed — a denied or failed call still
        // answers the block raised for it. PermissionDenied (auto mode
        // denied a call) is installed async: its one control, `retry`, is a
        // decision output, which Claude never reads from an async hook —
        // and Pulse prints nothing. SubagentStart / SubagentStop carry the
        // subagent's `agent_id` (its own lifecycle, never the person's
        // turn); PostCompact says the context was compacted. Never
        // PreToolUse, MessageDisplay, Elicitation or WorktreeCreate.
        hooks: HookContract(
            format: .nested(NestedFlavor(async: true)),
            path: ".claude/settings.json",
            home: ".claude",
            events: [
                HookEvent("SessionStart", .start),
                HookEvent("SessionEnd", .end),
                HookEvent("UserPromptSubmit", .prompt),
                HookEvent("PostToolUse", .activity),
                HookEvent("PostToolUseFailure", .activity),
                HookEvent("PermissionRequest", .blocked(.permission)),
                HookEvent("Notification", .ignore, matcher: "permission_prompt|idle_prompt|agent_needs_input|elicitation_dialog|elicitation_url_dialog|elicitation_complete|elicitation_response"),
                HookEvent("Stop", .turn),
                // The turn ended on an API error (rate limit, auth, overload).
                HookEvent("StopFailure", .failedTurn),
                // After the main agent's: the first event of an action is
                // the one that names it.
                HookEvent("PermissionDenied", .status),
                HookEvent("SubagentStart", .start),
                HookEvent("SubagentStop", .turn),
                HookEvent("PostCompact", .status),
            ],
            // A managed policy that runs only managed hooks, or turns every
            // hook off, before the person's own `disableAllHooks`.
            offSwitches: [
                HookSwitch(path: Claude.managedSettings, key: "allowManagedHooksOnly", caveat: .managedOnly),
                HookSwitch(path: Claude.managedSettingsFolder, folder: true, key: "allowManagedHooksOnly", caveat: .managedOnly),
                HookSwitch(path: Claude.managedSettings, key: "disableAllHooks", caveat: .managedOnly),
                HookSwitch(path: Claude.managedSettingsFolder, folder: true, key: "disableAllHooks", caveat: .managedOnly),
                HookSwitch(path: ".claude/settings.json", key: "disableAllHooks", caveat: .turnedOff),
            ]
        ),
        // Grok Build runs these hooks by default and marks its calls; Pulse
        // does not support Grok, and its events never land on a Claude row.
        foreignCallers: ["GROK_HOOK_EVENT", "GROK_SESSION_ID"],
        // Inside a subagent (the Task tool) every event carries the
        // subagent's `agent_id`; the main agent's carry none.
        subagentKeys: ["agent_id"],
        // Claude's tool names (tools-reference, the Agent SDK's
        // `ToolInputSchemas`); an MCP tool is `mcp__<server>__<tool>`.
        toolCategories: Claude.toolCategories,
        mcpToolPrefixes: ["mcp__"],
        read: { Claude.read($0, $1) }
    )
}

/// Claude's events whose meaning is in the payload.
package enum Claude {
    /// Where an administrator's managed settings live on macOS.
    package static let managedSettings = "/Library/Application Support/ClaudeCode/managed-settings.json"
    package static let managedSettingsFolder = "/Library/Application Support/ClaudeCode/managed-settings.d"

    /// Claude's tools by category, lowercased.
    package static let toolCategories: [String: StepCategory] = [
        "bash": .shell, "powershell": .shell, "monitor": .shell, "bashoutput": .shell, "killshell": .shell,
        "read": .read, "notebookread": .read,
        "edit": .edit, "multiedit": .edit, "write": .edit, "notebookedit": .edit,
        "glob": .search, "grep": .search, "ls": .search, "toolsearch": .search,
        "webfetch": .web, "websearch": .web,
        "agent": .agent, "task": .agent, "taskoutput": .agent, "taskstop": .agent, "sendmessage": .agent,
        "skill": .skill,
        "todowrite": .plan, "taskcreate": .plan, "taskupdate": .plan, "tasklist": .plan, "taskget": .plan,
        "listmcpresourcestool": .mcp, "readmcpresourcetool": .mcp, "readmcpresourcedirtool": .mcp,
    ]

    package static func read(_ event: String, _ payload: [String: Any]) -> HookReading? {
        // Cursor (and its CLI, which imports `~/.claude/settings.json`) and
        // VS Code (`chat.useClaudeHooks`) run Claude's hooks with payloads
        // of their own: not Claude speaking, and never a Claude row.
        if foreignHost(event, payload) { return HookReading(action: .skip(.otherHost)) }
        switch event {
        case "SessionStart":
            // A session the person named (`--name`, `/rename`): its title
            // over the first prompt. A generated title is not sent.
            let title = PulseHookReceiver.string(payload, keys: ["session_title"])
            return title.isEmpty ? nil : HookReading(action: .start, name: title)
        case "UserPromptSubmit":
            // The prompt is the line's words; a custom title rides along.
            let title = PulseHookReceiver.string(payload, keys: ["session_title"])
            return title.isEmpty ? nil : HookReading(action: .prompt, meta: LineMeta(name: title))
        case "PostToolUse":
            return HookReading(action: .activity, tookMs: took(payload), target: target(payload), meta: plan(payload))
        case "PostToolUseFailure":
            // The call reached Claude as an abort, not as the tool's own
            // error: the person interrupted the run.
            if payload["is_interrupt"] as? Bool == true { return HookReading(action: .stopped) }
            // The tool ran and failed: still the answer to a block raised
            // for it, and a step marked failed — with its error's first
            // line (`Exit code 1`).
            let error = LineMeta.firstLine(PulseHookReceiver.string(payload, keys: ["error"]), limit: LineMeta.errLimit)
            return HookReading(action: .activity, failed: true, tookMs: took(payload), target: target(payload), meta: LineMeta(err: error))
        case "PermissionRequest":
            // `dontAsk` denies whatever is not pre-approved: nobody is shown
            // this request (`-p` without a permission host is read from the
            // process, `AgentProcessRule.promptlessFlags`).
            if PulseHookReceiver.string(payload, keys: ["permission_mode"]) == "dontAsk" {
                return HookReading(action: .skip(.noPrompt))
            }
            // AskUserQuestion comes through PermissionRequest; it is a
            // question — no allow/deny answers it.
            let tool = PulseHookReceiver.string(payload, keys: ["tool_name", "toolName"])
            let kind: AttentionKind = tool == "AskUserQuestion" ? .question : .permission
            return HookReading(action: .blocked(kind), ask: ask(payload))
        case "PermissionDenied":
            // Auto mode denied a call: work goes on, nothing is asked. The
            // tool is named in the words, never the tool column (a `status`
            // that names a tool says it runs now). The `reason` is not read.
            let tool = PulseHookReceiver.toolLabel(PulseHookReceiver.string(payload, keys: ["tool_name"]))
            return HookReading(action: .status, note: tool.isEmpty ? "auto mode denied a tool" : "auto mode denied \(tool)")
        case "PostCompact":
            // A manual `/compact` is the person at the prompt and fires no
            // Stop: it is not work. An automatic one runs inside a turn.
            // The summary is never read.
            guard PulseHookReceiver.string(payload, keys: ["trigger"]) == "auto" else {
                return HookReading(action: .ignore)
            }
            return HookReading(action: .status, note: "compacted")
        case "SubagentStart", "SubagentStop":
            // The subagent's own start and end: always its line (`sub`),
            // never the main agent's — one that names no subagent says
            // nothing Pulse shows.
            let sub = PulseHookReceiver.string(payload, keys: ["agent_id"])
            guard !sub.isEmpty else { return HookReading(action: .ignore) }
            let agentType = PulseHookReceiver.string(payload, keys: ["agent_type"])
            return HookReading(action: event == "SubagentStart" ? .start : .turn, sub: sub, meta: LineMeta(agentType: agentType))
        case "Notification":
            let words = PulseHookReceiver.string(payload, keys: ["message", "title"])
            switch PulseHookReceiver.string(payload, keys: ["notification_type", "notificationType"]) {
            case "permission_prompt": return HookReading(action: .blocked(.permission), ask: words)
            case "elicitation_dialog", "elicitation_url_dialog":
                return HookReading(action: .blocked(.question), ask: words)
            // A background session waiting while agent view is open, a
            // teammate's terminal setup question, or auto mode's billing
            // notice: the payload does not name the session that waits, so
            // it may be another one's.
            case "agent_needs_input": return HookReading(action: .skip(.otherSession))
            // About a minute after a turn, and again after the person saw
            // it: never a turn of its own (`AttentionKind.idle`).
            case "idle_prompt": return HookReading(action: .idle)
            case "elicitation_complete", "elicitation_response": return HookReading(action: .resolved)
            // A Notification that does not say it is a block is not one.
            default: return HookReading(action: .ignore)
            }
        default:
            return nil
        }
    }

    /// Whether another tool ran Claude's hook with a payload of its own:
    /// Cursor's carries `cursor_version`, or its `conversation_id` with a
    /// `generation_id`; VS Code's (and Copilot's VS Code-compatible one) an
    /// ISO `timestamp` string — Claude's payload has neither; and any other
    /// host may name the event in its own spelling (`hook_event_name` is
    /// Claude's event exactly). Pure.
    package static func foreignHost(_ event: String, _ payload: [String: Any]) -> Bool {
        if payload["cursor_version"] != nil { return true }
        if payload["conversation_id"] != nil, payload["generation_id"] != nil { return true }
        if payload["timestamp"] is String { return true }
        if let named = payload["hook_event_name"] as? String, !named.isEmpty, named != event { return true }
        return false
    }

    /// How long the tool ran (`duration_ms`, excluding permission prompts),
    /// in ms; 0 unknown.
    package static func took(_ payload: [String: Any]) -> Int64 {
        guard let number = payload["duration_ms"] as? NSNumber, number.doubleValue.isFinite, number.doubleValue > 0 else { return 0 }
        return Int64(min(number.doubleValue, 86_400_000).rounded())
    }

    /// A `TodoWrite` call's checklist (`tool_input.todos[{content, status}]`,
    /// the Agent SDK's `TodoWriteInput`): how many items are done, of how
    /// many, and the one in progress. Empty for any other tool. Pure.
    package static func plan(_ payload: [String: Any]) -> LineMeta {
        guard PulseHookReceiver.string(payload, keys: ["tool_name"]) == "TodoWrite",
              let input = payload["tool_input"] as? [String: Any],
              let todos = input["todos"] as? [[String: Any]]
        else { return LineMeta() }
        let items = todos.map { (status: PulseHookReceiver.string($0, keys: ["status"]), text: PulseHookReceiver.string($0, keys: ["content"])) }
        let progress = LineMeta.progress(items)
        return LineMeta(plan: progress.plan, planNow: progress.now)
    }

    /// A tool's target where the generic reading misses it: an `Agent`
    /// (formerly `Task`) call's `description`, else its `subagent_type`; a
    /// `Skill` call's `skill`; a `TaskCreate` / `TaskUpdate` call's
    /// `subject`. Nil for any other tool. Pure.
    package static func target(_ payload: [String: Any]) -> String? {
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        let keys: [String]
        switch PulseHookReceiver.string(payload, keys: ["tool_name"]) {
        case "Agent", "Task": keys = ["description", "subagent_type"]
        case "Skill": keys = ["skill"]
        case "TaskCreate", "TaskUpdate": keys = ["subject"]
        default: return nil
        }
        let text = PulseHookReceiver.string(input, keys: keys)
        return text.isEmpty ? nil : PulseHookReceiver.condenseOneLine(text)
    }

    /// What a `PermissionRequest` asks: the question itself for
    /// `AskUserQuestion` (`tool_input.questions[0].question`), the plan's
    /// first line for `ExitPlanMode` (`tool_input.plan`), an `Agent` or
    /// `Skill` call by its target (`target`), else the tool call
    /// (`PulseHookReceiver.toolDescriptor`).
    package static func ask(_ payload: [String: Any]) -> String {
        let tool = PulseHookReceiver.string(payload, keys: ["tool_name", "toolName"])
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        switch tool {
        case "AskUserQuestion":
            if let questions = input["questions"] as? [[String: Any]], let first = questions.first {
                let text = PulseHookReceiver.string(first, keys: ["question", "header"])
                if !text.isEmpty { return PulseHookReceiver.condenseOneLine(text) }
            }
            let single = PulseHookReceiver.string(input, keys: ["question"])
            if !single.isEmpty { return PulseHookReceiver.condenseOneLine(single) }
        case "ExitPlanMode":
            let summary = planSummary(PulseHookReceiver.string(input, keys: ["plan"]))
            if !summary.isEmpty { return summary }
        default:
            if let target = target(payload) { return "\(tool): \(target)" }
        }
        return PulseHookReceiver.toolDescriptor(from: payload)
    }

    /// A plan's first line with words, without its Markdown marks.
    package static func planSummary(_ plan: String) -> String {
        let marks = CharacterSet(charactersIn: "#*->`_ \t")
        for line in plan.split(whereSeparator: \.isNewline) {
            let text = String(line).trimmingCharacters(in: marks)
            if !text.isEmpty { return PulseHookReceiver.condenseOneLine(text) }
        }
        return ""
    }
}
