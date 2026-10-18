import Foundation

extension AgentSpec {
    /// Pi (earendil-works/pi, packages/coding-agent `extensions/types.ts`):
    /// an extension Pulse owns whole. Its handlers return nothing, so no
    /// event's result changes; it forwards a small payload in the last
    /// argument.
    package static let pi = AgentSpec(
        id: .pi,
        displayName: "Pi",
        aliases: [],
        // `ui_prompt_start` / `ui_prompt_end`: Pi reports when it waits on a
        // blocking user-facing prompt (a confirm, a select, an input, an
        // editor — a `custom` view is not one).
        waiting: .hooks,
        // Pi's deny list is the program's own name (`pip`, `pihole`…): an
        // argument such as `./pipeline.ts` does not make Pi not Pi. Pi sets
        // `process.title` to `pi` (`src/cli/setup.ts`) or `pi-rpc`
        // (`src/rpc-entry.ts`), which on macOS overwrites its argv: the
        // kernel then reports `node` with argv `["pi", "", …]`, read as
        // `node pi` (`AgentProcesses.commandLine`).
        process: AgentProcessRule(
            basenames: ["pi", "pi-rpc"],
            pathNeedles: ["pi-coding-agent", "/opt/homebrew/bin/pi", "/usr/local/bin/pi", "/.local/bin/pi"],
            denyNeedles: ["pip", "pip3", "pihole", "pickle", "pypi", "pixel", "piano"],
            allowBareBasename: true
        ),
        hooks: HookContract(
            format: .module(render: { Pi.module(launcher: $0, events: $1) }),
            path: ".pi/agent/extensions/pulse.js",
            home: ".pi",
            events: [
                // Neither is sent for a reload: the same session goes on.
                // A start carries the session's name, when it has one.
                HookEvent("session_start", .start),
                HookEvent("session_shutdown", .end),
                // The person (or `/name`) named the session: its title.
                HookEvent("session_info_changed", .title),
                // A run began; it carries no prompt.
                HookEvent("agent_start", .prompt),
                // Sent for the person's own message only: its text is the
                // prompt (the title, unless the session has a name).
                HookEvent("message_start", .prompt),
                // A tool started: what runs now — never a step, never an
                // answer, and a long tool is not a stall.
                HookEvent("tool_execution_start", .status),
                HookEvent("tool_execution_end", .activity),
                HookEvent("ui_prompt_start", .blocked(.question)),
                HookEvent("ui_prompt_end", .resolved),
                // Pi will not continue on its own: the turn is over — or,
                // `aborted`, the person stopped it.
                HookEvent("agent_settled", .turn),
            ],
            // `getAgentDir()` (src/config.ts): `PI_CODING_AGENT_DIR` moves
            // the folder the extension is loaded from; a GUI app cannot see
            // it, so Pulse installs to the default and says so.
            relocation: HookContract.Relocation(dir: ".pi/agent", variable: "PI_CODING_AGENT_DIR")
        ),
        // Pi runs subagents as separate `pi --mode json` processes, which
        // the extension silences; a tool's nested calls are folded into it.
        // No event names a subagent.
        subagentKeys: [],
        // The extension spawns pulse-hook itself, with `process.pid`.
        reportsOwnPID: true,
        read: { Pi.read($0, $1) }
    )
}

/// Pi's events whose meaning is in the payload, and its extension.
package enum Pi {
    package static func read(_ event: String, _ payload: [String: Any]) -> HookReading? {
        let kind = PulseHookReceiver.string(payload, keys: ["kind"])
        switch event {
        case "ui_prompt_start":
            // As Pi's own interactive reporter says it
            // (`interactive-mode.ts`, `setBlocked`): a confirm is an
            // approval; a select, an input or an editor is a question; a
            // `custom` view blocks nothing. The ask is the prompt's title —
            // never the event's `reason` (`ui_prompt`).
            if kind == "custom" { return HookReading(action: .skip(.notABlock)) }
            let blocked: AttentionKind = kind == "confirm" ? .permission : .question
            return HookReading(action: .blocked(blocked), ask: PulseHookReceiver.string(payload, keys: ["title", "message"]))
        case "ui_prompt_end":
            // The end of a view that was never a block answers nothing.
            return kind == "custom" ? HookReading(action: .skip(.notABlock)) : nil
        case "tool_execution_end":
            // `isError` and `durationMs`, forwarded as `is_error` /
            // `duration_ms`: a step marked failed, and how long it ran.
            let failed = payload["is_error"] as? Bool ?? false
            let took = (payload["duration_ms"] as? NSNumber)?.int64Value ?? 0
            return HookReading(action: .activity, failed: failed, tookMs: max(0, took))
        case "agent_settled":
            // The person stopped the run (Escape): nothing is owed, and its
            // partial words are not the turn's last words.
            if payload["aborted"] as? Bool == true { return HookReading(action: .stopped) }
            // The run's last assistant message stopped on an error (the
            // extension forwards its `errorMessage` as `error`).
            return PulseHookReceiver.string(payload, keys: ["error"]).isEmpty ? nil : HookReading(action: .failedTurn)
        default:
            return nil
        }
    }

    /// `~/.pi/agent/extensions/pulse.js` (docs/extensions.md). Starts
    /// nothing in the factory; every handler is wrapped in `try`, returns
    /// `undefined` and never awaits.
    ///
    /// - **Only an interactive Pi speaks.** Nothing is sent when
    ///   `ctx.mode` is `json` or `print`: a subagent is a `pi --mode json -p
    ///   --no-session` process, and a script's one-shot run is nobody's
    ///   session.
    /// - **In order.** Each event is one `pulse-hook` child, and the log
    ///   numbers lines in the order the children take its lock — not the
    ///   order Pi emitted them — so the extension spawns a child only after
    ///   the one before it exited (or `GUARD_MS` passed): a prompt's end is
    ///   never written before its start. The queue is bounded (`QUEUE_MAX`;
    ///   a block, its answer and the turn's end are dropped last). On
    ///   `session_shutdown` whatever is still queued is dropped and the
    ///   shutdown is sent at once: children spawned together take the lock
    ///   in any order, and a step numbered after the session's end would
    ///   revive it.
    /// - **Steps.** `tool_execution_start` is sent (what runs now) and its
    ///   one short argument kept by `toolCallId` for the end, which carries
    ///   none: the command for a shell, the path for a file tool, the
    ///   pattern for a search, else the first of a fallback list. The end
    ///   says whether the tool failed and how long it ran. A call another
    ///   tool made (`parentToolCallId`) is folded into its caller: not sent.
    /// - **Titles.** A skill invocation (`<skill name="N" …>…</skill>` and
    ///   its arguments) is sent as `/skill:N ARGS` — never the skill file's
    ///   path or body; the session's own name rides on `session_start` and
    ///   `session_info_changed`.
    /// - **Last words.** `agent_end` (observed, never sent) keeps the run's
    ///   last assistant words or its error for `agent_settled`; an aborted
    ///   run sends neither.
    ///
    /// Every text is sliced only to bound the argv, well past what a row
    /// shows: the receiver redacts credentials from the whole value it gets
    /// before it shortens it. No transcript path is sent.
    package static func module(launcher: String, events: [String]) -> String {
        let list = events.map(HookModules.literal).joined(separator: ", ")
        return #"""
        // Pulse — Pi extension (pulse-hook). Installed by Pulse; remove it from
        // Pulse Settings → Hooks. It observes lifecycle events and hands each to
        // pulse-hook, one at a time and in order. It never throws, never awaits
        // a child, and returns nothing to Pi.
        import { spawn } from "node:child_process"

        const PULSE_HOOK = \#(HookModules.literal(launcher))
        const EVENTS = [\#(list)]

        // One child at a time: the next is spawned after the one before it
        // exited, or GUARD_MS passed.
        const GUARD_MS = 1500
        const QUEUE_MAX = 64
        // Dropped from a full queue last: a block, its answer, the turn's end.
        const KEEP = new Set(["ui_prompt_start", "ui_prompt_end", "agent_settled"])
        const QUEUE = []
        let busy = false

        function spawnHook(event, payload, onDone) {
          let finished = false
          let timer = undefined
          const finish = () => {
            if (finished) return
            finished = true
            if (timer !== undefined) clearTimeout(timer)
            if (onDone) onDone()
          }
          try {
            const child = spawn(PULSE_HOOK, ["pi", event, JSON.stringify(payload)], {
              detached: true,
              stdio: "ignore",
            })
            child.on("error", finish)
            child.on("exit", finish)
            child.unref()
          } catch {
            queueMicrotask(finish)
          }
          if (onDone) {
            timer = setTimeout(finish, GUARD_MS)
            if (timer && typeof timer.unref === "function") timer.unref()
          }
        }

        function pump() {
          if (busy) return
          const next = QUEUE.shift()
          if (!next) return
          busy = true
          spawnHook(next[0], next[1], () => {
            busy = false
            pump()
          })
        }

        function send(event, payload) {
          try {
            QUEUE.push([event, payload])
            while (QUEUE.length > QUEUE_MAX) {
              let drop = QUEUE.findIndex((item) => !KEEP.has(item[0]))
              if (drop < 0) drop = 0
              QUEUE.splice(drop, 1)
            }
            pump()
          } catch {}
        }

        // Pi is going away: whatever is still queued is dropped — children
        // spawned together take the log's lock in any order, and a line
        // numbered after the session's end would revive it — and the
        // shutdown goes now, without waiting on the child before it.
        function shutdown(event, payload) {
          try {
            QUEUE.length = 0
            spawnHook(event, payload)
          } catch {}
        }

        // A subagent (`pi --mode json -p`) or a one-shot print run is nobody's
        // session: it sends nothing.
        function quiet(ctx) {
          try {
            return !!ctx && (ctx.mode === "json" || ctx.mode === "print")
          } catch {
            return false
          }
        }

        // The argument that says what a tool works on, by tool.
        const TARGET_KEYS = new Map([
          ["bash", ["command"]],
          ["powershell", ["command"]],
          ["read", ["path", "file_path"]],
          ["edit", ["path", "file_path"]],
          ["write", ["path", "file_path"]],
          ["ls", ["path"]],
          ["grep", ["pattern"]],
          ["find", ["pattern"]],
        ])
        const FALLBACK_KEYS = ["command", "path", "file_path", "pattern", "url", "query"]
        // Tool call id → its one short argument (tool_execution_end has none).
        const ARGS = new Map()
        // The run's last assistant words or error, from agent_end.
        let lastRun = {}

        function oneArgument(toolName, args) {
          if (!args || typeof args !== "object") return undefined
          const keys = TARGET_KEYS.get(String(toolName || "").toLowerCase()) || FALLBACK_KEYS
          for (const key of keys) {
            if (typeof args[key] === "string" && args[key]) return { [key]: args[key].slice(0, 2000) }
          }
          return undefined
        }

        function text(content) {
          if (typeof content === "string") return content
          if (!Array.isArray(content)) return ""
          return content
            .filter((part) => part && part.type === "text" && typeof part.text === "string")
            .map((part) => part.text)
            .join("\n")
        }

        // A skill invocation is said as the person typed it: /skill:name args.
        const SKILL = /^<skill name="([^"]+)" location="[^"]*">\n[\s\S]*?\n<\/skill>(?:\n\n([\s\S]+))?$/
        function promptText(raw) {
          const m = SKILL.exec(raw)
          if (!m) return raw
          const args = m[2] ? m[2].trim() : ""
          return args ? "/skill:" + m[1] + " " + args : "/skill:" + m[1]
        }

        function sessionName(ctx) {
          try {
            const name = ctx.sessionManager.getSessionName()
            return typeof name === "string" ? name.slice(0, 2000) : ""
          } catch {
            return ""
          }
        }

        function context(ctx) {
          const out = { session_id: "", cwd: "", pid: process.pid }
          try { out.session_id = ctx.sessionManager.getSessionId() || "" } catch {}
          try { out.cwd = ctx.cwd || "" } catch {}
          return out
        }

        export default function (pi) {
          pi.on("agent_end", (event, ctx) => {
            try {
              if (quiet(ctx)) return
              lastRun = {}
              const messages = event && Array.isArray(event.messages) ? event.messages : []
              for (let i = messages.length - 1; i >= 0; i--) {
                const m = messages[i]
                if (!m || m.role !== "assistant") continue
                if (m.stopReason === "error" && typeof m.errorMessage === "string" && m.errorMessage) {
                  lastRun.error = m.errorMessage.slice(0, 2000)
                } else {
                  const words = text(m.content).trim()
                  if (words) lastRun.last_assistant_message = words.slice(0, 2000)
                }
                break
              }
            } catch {}
          })
          for (const name of EVENTS) {
            pi.on(name, (event, ctx) => {
              try {
                if (quiet(ctx)) return
                // A reload keeps the same session running.
                if ((name === "session_start" || name === "session_shutdown") && event && event.reason === "reload") return
                // Only the person's own message is a prompt.
                if (name === "message_start" && !(event && event.message && event.message.role === "user")) return
                // A call another tool made is folded into its caller.
                if ((name === "tool_execution_start" || name === "tool_execution_end") && event && event.parentToolCallId) return
                const payload = context(ctx)
                if (name === "ui_prompt_start" || name === "ui_prompt_end") {
                  if (event && typeof event.kind === "string") payload.kind = event.kind
                  if (event && typeof event.title === "string") payload.title = event.title
                }
                if (name === "session_start") payload.session_name = sessionName(ctx)
                if (name === "session_info_changed") {
                  payload.session_name = event && typeof event.name === "string" ? event.name.slice(0, 2000) : ""
                }
                if (name === "message_start") {
                  const prompt = promptText(text(event.message.content).trim())
                  if (prompt) payload.prompt = prompt.slice(0, 2000)
                }
                if (name === "tool_execution_start" && event) {
                  if (typeof event.toolName === "string") payload.tool_name = event.toolName.slice(0, 64)
                  const input = oneArgument(event.toolName, event.args)
                  if (input) {
                    payload.tool_input = input
                    if (typeof event.toolCallId === "string") {
                      ARGS.set(event.toolCallId, input)
                      if (ARGS.size > 256) ARGS.delete(ARGS.keys().next().value)
                    }
                  }
                }
                if (name === "tool_execution_end" && event) {
                  if (typeof event.toolName === "string") payload.tool_name = event.toolName.slice(0, 64)
                  const input = ARGS.get(event.toolCallId)
                  if (input) payload.tool_input = input
                  ARGS.delete(event.toolCallId)
                  payload.is_error = event.isError === true
                  if (typeof event.durationMs === "number" && event.durationMs >= 0) payload.duration_ms = Math.round(event.durationMs)
                }
                if (name === "agent_start") lastRun = {}
                if (name === "agent_settled") {
                  if (event && event.aborted === true) payload.aborted = true
                  else Object.assign(payload, lastRun)
                  lastRun = {}
                }
                // A reason is a shutdown's why; on a prompt it is not the ask.
                if (name === "session_shutdown" && event && typeof event.reason === "string") payload.reason = event.reason
                if (name === "session_shutdown") shutdown(name, payload)
                else send(name, payload)
              } catch {}
            })
          }
        }

        """#
    }
}
