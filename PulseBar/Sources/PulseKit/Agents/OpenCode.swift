import Foundation

extension AgentSpec {
    /// OpenCode (anomalyco/opencode): one plugin Pulse owns whole, loaded by
    /// both lines from `~/.config/opencode/plugins/` — 1.x (`opencode-ai`,
    /// branch `v1`) through its `event` hook, 2.x (`@opencode/cli`, branch
    /// `dev`) through `ctx.event.subscribe`. It reads the event bus only —
    /// never a hook that can change a tool's input or output, a message or a
    /// permission — and sends each event it reads under the vendor's own
    /// name, with a small payload of its own in the last argument. The two
    /// lines' event names are distinct but for the session and permission
    /// ones, whose payloads the plugin sends in one shape.
    package static let opencode = AgentSpec(
        id: .opencode,
        displayName: "OpenCode",
        aliases: [],
        // 1.x `permission.asked` / `question.asked`, 2.x `permission.asked`
        // / `form.created`; answered by their `*.replied` / `*.rejected` /
        // `form.cancelled` once the root's last open ask closes (`pending`
        // 0), a prompt, the turn's end, a stop or the session's end.
        waiting: .hooks,
        // The plugin sends every reply: a tool's step is not an answer (two
        // parallel asks of one tool — the first one's step must not clear
        // the second).
        stepsAnswerBlocks: false,
        process: AgentProcessRule(
            basenames: ["opencode", "open-code"],
            pathNeedles: ["/bin/opencode", "opencode@", "@opencode"],
            // `opencode serve` / `web`: one server for every client's session.
            serviceArguments: ["serve", "web"]
        ),
        hooks: HookContract(
            format: .module(render: { OpenCode.plugin(launcher: $0, events: $1) }),
            path: ".config/opencode/plugins/pulse.js",
            home: ".config/opencode",
            events: [
                // Both lines.
                HookEvent("session.created", .start),
                HookEvent("session.deleted", .end),
                HookEvent("permission.asked", .blocked(.permission)),
                // Sent only when the root's last open ask closes.
                HookEvent("permission.replied", .resolved),
                // 1.x: the session's name (`info.title`, not the default
                // "New session - …"), sent when it changes.
                HookEvent("session.updated", .title),
                // Busy or retrying says work goes on, not that a tool ran: it
                // never answers an ask, and never starts a turn.
                HookEvent("session.status", .ignore),
                HookEvent("session.idle", .turn),
                // `error.name` decides: an abort is the person stopping the
                // run, an overflow the auto-compaction going on.
                HookEvent("session.error", .failedTurn),
                HookEvent("session.compacted", .status),
                // The person's prompt (`phase: prompt`), a tool that started
                // (`running`) and one that finished (`done`): a tool part's
                // state, or a user message's first text part.
                HookEvent("message.part.updated", .activity),
                HookEvent("question.asked", .blocked(.question)),
                HookEvent("question.replied", .resolved),
                HookEvent("question.rejected", .resolved),
                // The root's to-do list changed: its progress, on a status
                // line that names no tool.
                HookEvent("todo.updated", .status),
                // The files a turn changed, as one batch.
                HookEvent("session.diff", .status),
                // 2.x.
                HookEvent("session.renamed", .title),
                HookEvent("session.inbox.enqueued", .prompt),
                HookEvent("session.execution.started", .prompt),
                HookEvent("session.execution.succeeded", .turn),
                HookEvent("session.execution.failed", .failedTurn),
                // `reason` decides: `user` stopped, `inactivity` failed.
                HookEvent("session.execution.interrupted", .stopped),
                HookEvent("session.tool.called", .status),
                HookEvent("session.tool.success", .activity),
                HookEvent("session.tool.failed", .activity),
                HookEvent("session.retry.scheduled", .status),
                HookEvent("session.compaction.ended", .status),
                HookEvent("form.created", .blocked(.question)),
                HookEvent("form.replied", .resolved),
                HookEvent("form.cancelled", .resolved),
            ],
            // `OPENCODE_CONFIG_DIR` adds a config folder (2.x: replaces the
            // global one) and `XDG_CONFIG_HOME` moves `~/.config`: a GUI app
            // sees neither, so Pulse installs to the default and says so.
            relocation: HookContract.Relocation(dir: ".config/opencode", variable: "OPENCODE_CONFIG_DIR")
        ),
        // A child session's tool steps carry its id (the plugin's
        // `subagent_id`): the subagent's own, never the person's.
        subagentKeys: ["subagent_id"],
        // OpenCode's built-in tools (packages/opencode/src/tool).
        toolCategories: OpenCode.toolCategories,
        read: { OpenCode.read($0, $1) }
    )
}

/// OpenCode's events whose meaning is in the payload, and its plugin.
package enum OpenCode {
    /// OpenCode's tools by category, lowercased.
    package static let toolCategories: [String: StepCategory] = [
        "bash": .shell,
        "read": .read,
        "edit": .edit, "write": .edit, "patch": .edit, "multiedit": .edit, "apply_patch": .edit,
        "grep": .search, "glob": .search, "list": .search, "codesearch": .search, "lsp": .search,
        "webfetch": .web, "websearch": .web,
        "task": .agent,
        "skill": .skill,
        "todowrite": .plan, "todoread": .plan,
    ]

    package static func read(_ event: String, _ payload: [String: Any]) -> HookReading? {
        func field(_ key: String) -> String { PulseHookReceiver.string(payload, keys: [key]) }
        switch event {
        case "session.updated":
            // 1.x archives a session by its `time.archived` (the plugin
            // sends `archived`): it is over.
            return payload["archived"] as? Bool == true ? HookReading(action: .end, meta: LineMeta(why: EndReason.archived.rawValue)) : nil
        case "todo.updated":
            // `todos[{content, status}]` (SDK `Todo`): how many are done, of
            // how many, and the one in progress.
            let todos = payload["todos"] as? [[String: Any]] ?? []
            let items = todos.map { (status: PulseHookReceiver.string($0, keys: ["status"]), text: PulseHookReceiver.string($0, keys: ["content"])) }
            let progress = LineMeta.progress(items)
            return HookReading(action: .status, note: "plan updated", meta: LineMeta(plan: progress.plan, planNow: progress.now))
        case "session.diff":
            // The files the batch changed (`diff[].file`), at most
            // `LineMeta.maxFiles`; how many in all is the words.
            let files = (payload["files"] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
            let count = max(files.count, (payload["count"] as? NSNumber)?.intValue ?? 0)
            guard count > 0 else { return HookReading(action: .ignore) }
            return HookReading(action: .status, note: count == 1 ? "1 file changed" : "\(count) files changed", meta: LineMeta(files: files))
        case "session.status":
            let status = (payload["status"] as? [String: Any]).map { PulseHookReceiver.string($0, keys: ["type"]) }
                ?? field("status")
            return HookReading(action: status == "busy" || status == "retry" ? .status : .ignore)
        case "session.error":
            // An error that names no session belongs to no row.
            guard !HookContext(payload: payload).session.isEmpty else { return HookReading(action: .skip(.noSession)) }
            switch field("error_name") {
            // Esc: the person stopped the run — nothing owed, no error.
            case "MessageAbortedError": return HookReading(action: .stopped)
            // The context overflowed and OpenCode compacts and goes on (with
            // auto-compaction off its `session.idle` follows and ends the
            // turn).
            case "ContextOverflowError": return HookReading(action: .status, note: "compacting")
            default: return nil
            }
        case "session.compacted", "session.compaction.ended":
            return HookReading(action: .status, note: "compacted")
        case "session.retry.scheduled":
            return HookReading(action: .status, note: "retrying")
        case "message.part.updated":
            switch field("phase") {
            case "prompt": return HookReading(action: .prompt)
            case "running": return HookReading(action: .status, target: target(payload))
            case "done": return step(payload)
            // The plugin sends no other phase; one that says none is no step.
            default: return HookReading(action: .ignore)
            }
        case "session.tool.called":
            return HookReading(action: .status, target: target(payload))
        case "session.tool.success", "session.tool.failed":
            return step(payload)
        case "session.execution.interrupted":
            switch field("reason") {
            case "user": return HookReading(action: .stopped)
            // The run gave up waiting: it is over, on an error of its own.
            case "inactivity": return HookReading(action: .failedTurn)
            // Superseded by the next run, or OpenCode shutting down (its
            // exit ends the session): nothing to say.
            default: return HookReading(action: .ignore)
            }
        case "permission.asked":
            return HookReading(action: .blocked(.permission), ask: permissionAsk(payload))
        case "question.asked", "form.created":
            return HookReading(action: .blocked(.question), ask: questionAsk(payload))
        case "permission.replied", "question.replied", "question.rejected", "form.replied", "form.cancelled":
            // Another ask of the same root session is still open: the lamp
            // stays red until the last one closes.
            if let pending = payload["pending"] as? Int, pending > 0 { return HookReading(action: .ignore) }
            return nil
        default:
            return nil
        }
    }

    /// A tool's step: its one argument, whether it failed, how long it ran.
    private static func step(_ payload: [String: Any]) -> HookReading {
        let failed = payload["is_error"] as? Bool ?? false
        let took = (payload["duration_ms"] as? NSNumber)?.int64Value ?? 0
        return HookReading(action: .activity, failed: failed, tookMs: max(0, took), target: target(payload))
    }

    /// The one argument the plugin kept from the tool's input (the command,
    /// the path, the pattern…).
    private static func target(_ payload: [String: Any]) -> String {
        PulseHookReceiver.condenseOneLine(PulseHookReceiver.string(payload, keys: ["target"]), limit: 200)
    }

    package static func permissionAsk(_ payload: [String: Any]) -> String {
        let title = PulseHookReceiver.string(payload, keys: ["title"])
        if !title.isEmpty { return PulseHookReceiver.condenseOneLine(title) }
        let permission = PulseHookReceiver.string(payload, keys: ["permission", "type"])
        let patterns = (payload["patterns"] as? [Any] ?? payload["pattern"] as? [Any] ?? [])
            .compactMap { $0 as? String }
        let single = PulseHookReceiver.string(payload, keys: ["pattern"])
        let target = patterns.isEmpty ? single : patterns.joined(separator: " ")
        if permission.isEmpty { return PulseHookReceiver.condenseOneLine(target) }
        return PulseHookReceiver.condenseOneLine(target.isEmpty ? permission : "\(permission): \(target)")
    }

    package static func questionAsk(_ payload: [String: Any]) -> String {
        let questions = payload["questions"] as? [[String: Any]] ?? []
        if let first = questions.first {
            return PulseHookReceiver.condenseOneLine(PulseHookReceiver.string(first, keys: ["question", "header"]))
        }
        return PulseHookReceiver.condenseOneLine(PulseHookReceiver.string(payload, keys: ["question", "title"]))
    }

    /// The events dropped from a full queue last: a block, its answer, the
    /// turn's end.
    static let kept = [
        "permission.asked", "permission.replied", "question.asked", "question.replied", "question.rejected",
        "form.created", "form.replied", "form.cancelled",
        "session.idle", "session.error", "session.execution.succeeded", "session.execution.failed",
        "session.execution.interrupted", "session.deleted",
    ]

    /// `~/.config/opencode/plugins/pulse.js`, one module for both lines:
    /// `export default { id, server, setup }` — 1.x reads `server`
    /// (`readV1Plugin`: a default object with an `id` and `server()`), 2.x
    /// reads `setup` (`core/src/plugin/module.ts`: a default with an `id` and
    /// `setup` or `effect`); neither reads the other's member. No named
    /// export: a 1.x loader that walks every export would load the plugin
    /// twice.
    ///
    /// - **The bus only.** 1.x hands every bus event to the `event` hook;
    ///   2.x streams it to `ctx.event.subscribe`. No `tool.execute.*`,
    ///   `chat.*` or permission hook — each can change what OpenCode does.
    /// - **Subagents.** A child session (`parentID`, learned from any session
    ///   event that carries one) is not the person's: its lifecycle, prompts,
    ///   to-dos and diffs are dropped (the root's `task` tool runs
    ///   meanwhile); its steps are sent under the root's id marked with the
    ///   child's (`subagent_id`: the subagent's own, never an answer); its
    ///   asks block the root's work and are sent under the root's id.
    /// - **Asks.** Each root keeps its open asks by id; a `*.replied` /
    ///   `rejected` / `form.cancelled` says how many are still open
    ///   (`pending`), so one answer of two parallel asks keeps the lamp red.
    ///   An ask names the asking tool (by its call id) when it was seen.
    ///   The root's run ending — 1.x `session.idle` or an abort, 2.x
    ///   `session.execution.succeeded` / `failed` / `interrupted` — closes
    ///   every ask it still holds: none outlives its run.
    /// - **Steps.** 1.x: a tool part's first `running` state (what runs now)
    ///   and its `completed` / `error` state, once per call; 2.x:
    ///   `session.tool.called` and `session.tool.success` / `failed`, the
    ///   tool's name from `session.tool.input.started` (observed, never
    ///   sent). One argument of the input (command, path, pattern, URL,
    ///   query, description), whether it failed, how long it ran. A call
    ///   cut short by an abort is no step.
    /// - **Plans, diffs, archives** (1.x). `todo.updated` sends each item's
    ///   status and content (at most 100); `session.diff` the changed files
    ///   (at most 16) and how many; a session whose `time.archived` is set
    ///   sends `session.updated` with `archived`, once. A skill's step
    ///   names the skill.
    /// - **Prompts and titles.** 1.x: a user message's (`message.updated`,
    ///   observed) first text part that is not synthetic; 2.x: a user item
    ///   of `session.inbox.enqueued`. A non-default title rides on
    ///   `session.created`, 1.x `session.updated` and 2.x
    ///   `session.renamed`, each sent when it changes.
    /// - **Stops.** A 1.x abort (`MessageAbortedError`) is sent and the
    ///   `session.idle` after it is not: the person stopped the run, it is
    ///   not their turn.
    /// - **In order**, one child at a time (`HookModules.orderedSendFunction`).
    ///
    /// Every text is sliced only to bound the argv; the receiver redacts
    /// credentials from the whole value before it shortens it. Nothing it
    /// sends carries a token count, a cost or a model.
    package static func plugin(launcher: String, events: [String]) -> String {
        let list = events.map(HookModules.literal).joined(separator: ", ")
        return HookModules.openCodePluginTemplate
            .replacingOccurrences(
                of: "/*__ORDERED_SEND__*/",
                with: HookModules.orderedSendFunction(launcher: launcher, agent: "opencode", keep: kept)
            )
            .replacingOccurrences(of: "/*__EVENTS__*/", with: list)
    }
}
