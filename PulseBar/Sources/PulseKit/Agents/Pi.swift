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
        // blocking user-facing prompt (a confirm, a select, an input).
        waiting: .hooks,
        // Pi's deny list is the program's own name (`pip`, `pihole`…): an
        // argument such as `./pipeline.ts` does not make Pi not Pi.
        process: AgentProcessRule(
            basenames: ["pi"],
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
                HookEvent("session_start", .start),
                HookEvent("session_shutdown", .end),
                // A run began; it carries no prompt.
                HookEvent("agent_start", .prompt),
                // Sent for the person's own message only: its text is the
                // prompt (the title).
                HookEvent("message_start", .prompt),
                HookEvent("tool_execution_end", .activity),
                HookEvent("ui_prompt_start", .blocked(.question)),
                HookEvent("ui_prompt_end", .resolved),
                // Pi will not continue on its own: the turn is over.
                HookEvent("agent_settled", .turn),
            ]
        ),
        read: { Pi.read($0, $1) }
    )
}

/// Pi's events whose meaning is in the payload, and its extension.
package enum Pi {
    package static func read(_ event: String, _ payload: [String: Any]) -> HookReading? {
        switch event {
        case "ui_prompt_start":
            // A confirm is an approval; a select, an input or an editor is a
            // question. The ask is the prompt's title — never the event's
            // `reason` (`ui_prompt`).
            let kind: AttentionKind = PulseHookReceiver.string(payload, keys: ["kind"]) == "confirm" ? .permission : .question
            return HookReading(action: .blocked(kind), ask: PulseHookReceiver.string(payload, keys: ["title", "message"]))
        case "agent_settled":
            // The run's last assistant message stopped on an error (the
            // extension forwards its `errorMessage` as `error`).
            return PulseHookReceiver.string(payload, keys: ["error"]).isEmpty ? nil : HookReading(action: .failedTurn)
        default:
            return nil
        }
    }

    /// `~/.pi/agent/extensions/pulse.js` (docs/extensions.md). Starts
    /// nothing in the factory; every handler returns `undefined`.
    ///
    /// Two events are observed only to fill the forwarded ones, never sent:
    /// `tool_execution_start` (the call's arguments — `tool_execution_end`
    /// carries none — kept by `toolCallId`, bounded) and `agent_end` (the
    /// run's last assistant words, or its error, for `agent_settled`). A
    /// tool event carries the tool's name and one short argument — the
    /// command, path, pattern, URL or query — as `tool_name` / `tool_input`,
    /// the receiver's own words for a tool call. Every text is sliced only
    /// to bound the argv, well past what a row shows: the receiver redacts
    /// credentials from the whole value it gets before it shortens it.
    package static func module(launcher: String, events: [String]) -> String {
        let list = events.map(HookModules.literal).joined(separator: ", ")
        return """
        // Pulse — Pi extension (pulse-hook). Installed by Pulse; remove it from
        // Pulse Settings → Hooks. It observes lifecycle events and hands each to
        // pulse-hook, detached. It never throws, never awaits the child, and
        // returns nothing to Pi.
        import { spawn } from "node:child_process"

        \(HookModules.sendFunction(launcher: launcher, agent: "pi"))

        const EVENTS = [\(list)]
        const ARG_KEYS = ["command", "path", "file_path", "pattern", "url", "query"]
        // Tool call id → its one short argument (tool_execution_end has none).
        const ARGS = new Map()
        // The run's last assistant words or error, from agent_end.
        let lastRun = {}

        function oneArgument(args) {
          if (!args || typeof args !== "object") return undefined
          for (const key of ARG_KEYS) {
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
            .join("\\n")
        }

        function context(ctx) {
          const out = { session_id: "", transcript_path: "", cwd: "" }
          try { out.session_id = ctx.sessionManager.getSessionId() || "" } catch {}
          try { out.transcript_path = ctx.sessionManager.getSessionFile() || "" } catch {}
          try { out.cwd = ctx.cwd || "" } catch {}
          return out
        }

        export default function (pi) {
          pi.on("tool_execution_start", (event) => {
            try {
              const input = oneArgument(event && event.args)
              if (!input || typeof event.toolCallId !== "string") return
              ARGS.set(event.toolCallId, input)
              if (ARGS.size > 256) ARGS.delete(ARGS.keys().next().value)
            } catch {}
          })
          pi.on("agent_end", (event) => {
            try {
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
                // A reload keeps the same session running.
                if ((name === "session_start" || name === "session_shutdown") && event && event.reason === "reload") return
                // Only the person's own message is a prompt.
                if (name === "message_start" && !(event && event.message && event.message.role === "user")) return
                const payload = context(ctx)
                if (event && typeof event.kind === "string") payload.kind = event.kind
                if (event && typeof event.title === "string") payload.title = event.title
                if (name === "message_start") {
                  const prompt = text(event.message.content).trim()
                  if (prompt) payload.prompt = prompt.slice(0, 2000)
                }
                if (name === "tool_execution_end" && event) {
                  if (typeof event.toolName === "string") payload.tool_name = event.toolName.slice(0, 64)
                  const input = ARGS.get(event.toolCallId)
                  if (input) payload.tool_input = input
                  ARGS.delete(event.toolCallId)
                }
                if (name === "agent_start") lastRun = {}
                if (name === "agent_settled") Object.assign(payload, lastRun)
                // A reason is a shutdown's why; on a prompt it is not the ask.
                if (name === "session_shutdown" && event && typeof event.reason === "string") payload.reason = event.reason
                send(name, payload)
              } catch {}
            })
          }
        }

        """
    }
}
