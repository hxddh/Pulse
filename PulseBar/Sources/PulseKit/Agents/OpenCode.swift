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
            pathNeedles: ["/bin/opencode", "opencode@", "@opencode"]
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
        read: { OpenCode.read($0, $1) }
    )
}

/// OpenCode's events whose meaning is in the payload, and its plugin.
package enum OpenCode {
    package static func read(_ event: String, _ payload: [String: Any]) -> HookReading? {
        func field(_ key: String) -> String { PulseHookReceiver.string(payload, keys: [key]) }
        switch event {
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
    ///   event that carries one) is not the person's: its lifecycle, prompts
    ///   and steps are dropped (the root's `task` tool runs meanwhile); its
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
        return #"""
        // Pulse — OpenCode plugin (pulse-hook). Installed by Pulse; remove it from
        // Pulse Settings → Hooks. It observes OpenCode's event bus — 1.x through
        // the plugin event hook, 2.x through ctx.event.subscribe — and hands each
        // event it reads to pulse-hook, one at a time and in order. It never
        // throws, never awaits a child, and changes nothing OpenCode does.
        import { spawn } from "node:child_process"

        \#(HookModules.orderedSendFunction(launcher: launcher, agent: "opencode", keep: kept))

        const EVENTS = new Set([\#(list)])
        // Child session id → parent id (subagents).
        const PARENTS = new Map()
        // Root session id → the ids of its open asks.
        const OPEN = new Map()
        // 1.x: tool call id → tool name; 2.x: tool call id → { name, target, at }.
        const NAMES = new Map()
        const CALLS = new Map()
        // 1.x: tool call id → the phase last sent ("running", then "done").
        const PHASES = new Map()
        // 1.x: user message ids, and those whose prompt was sent; a text part
        // seen before its message.
        const USERS = new Set()
        const PROMPTED = new Set()
        const EARLY = new Map()
        // Root session id → the title last sent, the status last sent.
        const TITLES = new Map()
        const STATUS = new Map()
        // 1.x: roots whose run the person stopped: the idle after it is not a turn.
        const ABORTED = new Set()
        const TARGET_KEYS = ["command", "filePath", "file_path", "path", "pattern", "url", "query", "description"]
        const DEFAULT_TITLE = /^(New session|Child session) - \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/

        function remember(map, key, value, max) {
          map.set(key, value)
          if (map.size > max) map.delete(map.keys().next().value)
        }

        function mark(set, key, max) {
          set.add(key)
          if (set.size > max) set.delete(set.values().next().value)
        }

        function text(value, max) {
          return typeof value === "string" ? value.slice(0, max || 2000) : ""
        }

        function list(value) {
          return Array.isArray(value) ? value.filter((item) => typeof item === "string").slice(0, 4).map((item) => item.slice(0, 500)) : []
        }

        function title(value) {
          const name = text(value).trim()
          return name && !DEFAULT_TITLE.test(name) ? name : ""
        }

        function target(input) {
          if (!input || typeof input !== "object") return ""
          for (const key of TARGET_KEYS) {
            if (typeof input[key] === "string" && input[key]) return input[key].slice(0, 2000)
          }
          return ""
        }

        function learn(id, parent) {
          if (id && parent && id !== parent) remember(PARENTS, id, parent, 512)
        }

        function child(id) {
          return !!id && PARENTS.has(id)
        }

        function rootOf(id) {
          let current = id
          for (let i = 0; i < 8 && PARENTS.has(current); i++) current = PARENTS.get(current)
          return current
        }

        function opened(root, id) {
          if (!root || !id) return
          let open = OPEN.get(root)
          if (!open) {
            open = new Set()
            remember(OPEN, root, open, 256)
          }
          open.add(id)
        }

        // How many of the root's asks are still open once this one closed.
        function closed(root, id) {
          const open = OPEN.get(root)
          if (!open) return 0
          if (id) open.delete(id)
          else open.clear()
          if (open.size === 0) OPEN.delete(root)
          return open.size
        }

        function deliver(type, own, directory, extra) {
          if (!EVENTS.has(type)) return
          const payload = { sessionID: own ? rootOf(own) : "", directory: directory || "" }
          send(type, Object.assign(payload, extra || {}))
        }

        function forget(id) {
          TITLES.delete(id)
          STATUS.delete(id)
          OPEN.delete(id)
          ABORTED.delete(id)
        }

        function prompt(own, id, directory, words) {
          if (PROMPTED.has(id)) return
          mark(PROMPTED, id, 512)
          ABORTED.delete(own)
          deliver("message.part.updated", own, directory, { phase: "prompt", prompt: words })
        }

        // 1.x: { type, properties }.
        function legacy(event, base) {
          const type = event.type
          const p = event.properties || {}
          const info = p.info || {}
          const directory = info.directory || base
          if (type === "session.created" || type === "session.updated" || type === "session.deleted") {
            const id = info.id || p.sessionID || ""
            if (info.parentID) learn(id, info.parentID)
            if (child(id)) {
              if (type === "session.deleted") PARENTS.delete(id)
              return
            }
            if (type === "session.deleted") {
              forget(id)
              return deliver(type, id, directory)
            }
            const name = title(info.title)
            if (type === "session.updated" && (!name || TITLES.get(id) === name)) return
            if (name) remember(TITLES, id, name, 256)
            return deliver(type, id, directory, { session_name: name })
          }
          if (type === "message.updated") {
            if (!info.id) return
            const early = EARLY.get(info.id)
            EARLY.delete(info.id)
            if (info.role !== "user") return
            mark(USERS, info.id, 512)
            const own = info.sessionID || p.sessionID || ""
            if (early !== undefined && !child(own)) prompt(own, info.id, directory, early)
            return
          }
          if (type === "message.part.updated") {
            const part = p.part || {}
            const own = part.sessionID || p.sessionID || ""
            if (child(own)) return
            if (part.type === "text") {
              if (part.synthetic || part.ignored || !part.messageID || PROMPTED.has(part.messageID)) return
              const words = text(part.text).trim()
              if (!words) return
              if (USERS.has(part.messageID)) return prompt(own, part.messageID, directory, words)
              if (!EARLY.has(part.messageID)) remember(EARLY, part.messageID, words, 64)
              return
            }
            if (part.type !== "tool" || !part.callID) return
            const state = part.state || {}
            const name = text(part.tool, 64)
            if (state.status === "pending" || state.status === "running") {
              remember(NAMES, part.callID, name, 256)
              if (state.status !== "running" || PHASES.has(part.callID)) return
              remember(PHASES, part.callID, "running", 512)
              return deliver(type, own, directory, { phase: "running", tool_name: name, target: target(state.input) })
            }
            if (state.status !== "completed" && state.status !== "error") return
            if (PHASES.get(part.callID) === "done") return
            remember(PHASES, part.callID, "done", 512)
            NAMES.delete(part.callID)
            // A call an abort cut short is no step: the stop says it.
            if (state.status === "error" && state.metadata && state.metadata.interrupted === true) return
            const time = state.time || {}
            const took = typeof time.start === "number" && typeof time.end === "number" && time.end >= time.start ? Math.round(time.end - time.start) : 0
            return deliver(type, own, directory, {
              phase: "done",
              tool_name: name,
              target: target(state.input),
              is_error: state.status === "error",
              duration_ms: took,
            })
          }
          const own = p.sessionID || ""
          if (type === "permission.asked" || type === "question.asked") {
            opened(rootOf(own), p.id)
            if (type === "question.asked") {
              const questions = (Array.isArray(p.questions) ? p.questions : [])
                .slice(0, 1)
                .map((q) => ({ question: text(q && q.question), header: text(q && q.header, 200) }))
              return deliver(type, own, directory, { questions })
            }
            const call = p.tool && p.tool.callID
            const permission = text(p.permission || p.type, 64)
            return deliver(type, own, directory, {
              permission,
              patterns: list(p.patterns),
              title: text(p.title),
              tool_name: (call && NAMES.get(call)) || permission,
            })
          }
          if (type === "permission.replied" || type === "question.replied" || type === "question.rejected") {
            return deliver(type, own, directory, { pending: closed(rootOf(own), p.requestID) })
          }
          if (child(own)) return
          if (type === "session.status") {
            const kind = text(p.status && p.status.type, 16)
            if (kind === "busy") ABORTED.delete(own)
            if (kind !== "busy" && kind !== "retry") {
              STATUS.delete(own)
              return
            }
            if (kind === "busy" && STATUS.get(own) === "busy") return
            remember(STATUS, own, kind, 256)
            return deliver(type, own, directory, { status: kind })
          }
          if (type === "session.idle") {
            STATUS.delete(own)
            // The run is over: no ask of it is still open.
            OPEN.delete(own)
            if (ABORTED.has(own)) {
              ABORTED.delete(own)
              return
            }
            return deliver(type, own, directory)
          }
          if (type === "session.error") {
            const e = p.error || {}
            const name = text(e.name, 64)
            const words = (e.data && typeof e.data.message === "string" && e.data.message) || (typeof e.message === "string" && e.message) || name
            if (name === "MessageAbortedError" && own) {
              mark(ABORTED, own, 256)
              OPEN.delete(own)
            }
            return deliver(type, own, directory, { error: text(words), error_name: name })
          }
          if (type === "session.compacted") return deliver(type, own, directory)
        }

        // 2.x: { type, data, location }.
        function current(event, base) {
          const type = event.type
          const d = event.data || {}
          const directory = (event.location && event.location.directory) || base
          const own = d.sessionID || ""
          if (type === "session.created") {
            if (d.parentID) learn(own, d.parentID)
            if (child(own)) return
            const name = title(d.title)
            if (name) remember(TITLES, own, name, 256)
            return deliver(type, own, (d.location && d.location.directory) || directory, { session_name: name })
          }
          if (type === "session.deleted") {
            if (child(own)) {
              PARENTS.delete(own)
              return
            }
            forget(own)
            return deliver(type, own, directory)
          }
          if (type === "session.tool.input.started") {
            if (d.id) remember(CALLS, d.id, { name: text(d.name, 64), target: "", at: 0 }, 256)
            return
          }
          if (type === "permission.asked") {
            opened(rootOf(own), d.id)
            const call = d.source && d.source.id && CALLS.get(d.source.id)
            const permission = text(d.action, 64)
            return deliver(type, own, directory, {
              permission,
              patterns: list(d.resources),
              title: text(d.message),
              tool_name: (call && call.name) || permission,
            })
          }
          if (type === "permission.replied") {
            return deliver(type, own, directory, { pending: closed(rootOf(own), d.requestID) })
          }
          if (type === "form.created") {
            const form = d.form || {}
            const asker = form.sessionID || ""
            opened(rootOf(asker), form.id)
            const field = (Array.isArray(form.fields) && form.fields[0]) || {}
            const question = text(field.description) || text(field.title) || text(form.title)
            return deliver(type, asker, directory, { questions: [{ question, header: text(field.title, 200) }] })
          }
          if (type === "form.replied" || type === "form.cancelled") {
            return deliver(type, own, directory, { pending: closed(rootOf(own), d.id) })
          }
          if (child(own)) return
          if (type === "session.renamed") {
            const name = title(d.title)
            if (!name || TITLES.get(own) === name) return
            remember(TITLES, own, name, 256)
            return deliver(type, own, directory, { session_name: name })
          }
          if (type === "session.inbox.enqueued") {
            const item = d.item || {}
            if (item.type !== "user") return
            return deliver(type, own, directory, { prompt: text(item.payload && item.payload.text).trim() })
          }
          if (type === "session.tool.called") {
            const call = CALLS.get(d.id) || { name: "", target: "", at: 0 }
            call.target = target(d.input)
            call.at = typeof event.created === "number" ? event.created : Date.now()
            if (d.id) remember(CALLS, d.id, call, 256)
            return deliver(type, own, directory, { tool_name: call.name || "tool", target: call.target })
          }
          if (type === "session.tool.success" || type === "session.tool.failed") {
            const call = CALLS.get(d.id) || { name: "", target: "", at: 0 }
            CALLS.delete(d.id)
            const now = typeof event.created === "number" ? event.created : Date.now()
            return deliver(type, own, directory, {
              tool_name: call.name || "tool",
              target: call.target,
              is_error: type === "session.tool.failed",
              duration_ms: call.at > 0 && now >= call.at ? Math.round(now - call.at) : 0,
            })
          }
          // The run is over: no ask of it is still open.
          if (type === "session.execution.succeeded" || type === "session.execution.failed" || type === "session.execution.interrupted") {
            OPEN.delete(own)
          }
          if (type === "session.execution.failed") {
            const e = d.error || {}
            return deliver(type, own, directory, { error: text(e.message), error_name: text(e.type, 64) })
          }
          if (type === "session.execution.interrupted") return deliver(type, own, directory, { reason: text(d.reason, 32) })
          if (
            type === "session.execution.started" ||
            type === "session.execution.succeeded" ||
            type === "session.retry.scheduled" ||
            type === "session.compaction.ended"
          ) {
            return deliver(type, own, directory)
          }
        }

        export default {
          id: "pulse",
          // 1.x: the plugin's hooks; only `event`, which returns nothing.
          server: async ({ directory }) => ({
            event: async ({ event }) => {
              try {
                if (event && typeof event.type === "string") legacy(event, directory || "")
              } catch {}
            },
          }),
          // 2.x: read the bus until OpenCode unloads the plugin. Not awaited.
          setup: (ctx) => {
            const controller = new AbortController()
            let base = ""
            try {
              base = (ctx && ctx.location && ctx.location.directory) || ""
            } catch {}
            ;(async () => {
              try {
                if (!ctx || !ctx.event || typeof ctx.event.subscribe !== "function") return
                for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
                  try {
                    if (!event || typeof event.type !== "string") continue
                    const where = event.location && event.location.directory
                    if (base && where && where !== base) continue
                    current(event, base)
                  } catch {}
                }
              } catch {}
            })()
            return () => {
              try {
                controller.abort()
              } catch {}
            }
          },
        }

        """#
    }
}
