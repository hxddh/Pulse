import Foundation

/// 24.0 · The two hook modules Pulse owns whole: an OpenCode plugin and a Pi
/// extension. Each observes its vendor's documented lifecycle events and
/// hands each one to `pulse-hook`, detached, with a small JSON payload on
/// stdin. Neither may throw, block, await the child, or return anything the
/// vendor would act on: every handler is wrapped in `try`, returns
/// `undefined`, and the child is `unref`'d.
enum HookModules {
    /// The launcher path as a JavaScript string literal.
    static func literal(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(text) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Shared by both modules: spawn `pulse-hook <agent> <event>` detached,
    /// write the payload, never wait.
    private static func sendFunction(launcher: String, agent: String) -> String {
        """
        const PULSE_HOOK = \(literal(launcher))

        function send(event, payload) {
          try {
            const child = spawn(PULSE_HOOK, [\(literal(agent)), event], {
              detached: true,
              stdio: ["pipe", "ignore", "ignore"],
            })
            child.on("error", () => {})
            if (child.stdin) {
              child.stdin.on("error", () => {})
              child.stdin.end(JSON.stringify(payload))
            }
            child.unref()
          } catch {}
        }
        """
    }

    /// `~/.config/opencode/plugins/pulse.js` — a plugin whose only hook is
    /// `event` (anomalyco/opencode packages/plugin `Hooks.event`). Every
    /// named export of a legacy plugin module must be a plugin function, so
    /// this module exports exactly one.
    static func openCodePlugin(launcher: String, events: [String]) -> String {
        let list = events.map(literal).joined(separator: ", ")
        return """
        // Pulse — OpenCode plugin (pulse-hook). Installed by Pulse; remove it from
        // Pulse Settings → Hooks. It observes session and permission events and
        // hands each to pulse-hook, detached. It never throws, never awaits the
        // child, and changes nothing OpenCode does.
        import { spawn } from "node:child_process"

        \(sendFunction(launcher: launcher, agent: "opencode"))

        const EVENTS = new Set([\(list)])

        export const PulsePlugin = async ({ directory }) => ({
          event: async ({ event }) => {
            try {
              if (!event || !EVENTS.has(event.type)) return
              const p = event.properties || {}
              const payload = {
                sessionID: p.sessionID || (p.info && p.info.id) || "",
                directory: (p.info && p.info.directory) || directory || "",
              }
              if (event.type === "session.status") payload.status = p.status && p.status.type
              if (event.type === "permission.asked") {
                payload.permission = p.permission || p.type || ""
                payload.patterns = Array.isArray(p.patterns) ? p.patterns.slice(0, 4) : []
                if (typeof p.title === "string") payload.title = p.title
              }
              if (event.type === "question.asked") {
                payload.questions = (Array.isArray(p.questions) ? p.questions : [])
                  .slice(0, 1)
                  .map((q) => ({ question: q.question || "", header: q.header || "" }))
              }
              send(event.type, payload)
            } catch {}
          },
        })

        """
    }

    /// `~/.pi/agent/extensions/pulse.js` — a Pi extension (badlogic/pi-mono
    /// coding-agent docs/extensions.md). Starts nothing in the factory; each
    /// handler returns `undefined`, so no event's result is changed.
    static func piExtension(launcher: String, events: [String]) -> String {
        let list = events.map(literal).joined(separator: ", ")
        return """
        // Pulse — Pi extension (pulse-hook). Installed by Pulse; remove it from
        // Pulse Settings → Hooks. It observes lifecycle events and hands each to
        // pulse-hook, detached. It never throws, never awaits the child, and
        // returns nothing to Pi.
        import { spawn } from "node:child_process"

        \(sendFunction(launcher: launcher, agent: "pi"))

        const EVENTS = [\(list)]

        function context(ctx) {
          const out = { session_id: "", transcript_path: "", cwd: "" }
          try { out.session_id = ctx.sessionManager.getSessionId() || "" } catch {}
          try { out.transcript_path = ctx.sessionManager.getSessionFile() || "" } catch {}
          try { out.cwd = ctx.cwd || "" } catch {}
          return out
        }

        export default function (pi) {
          for (const name of EVENTS) {
            pi.on(name, (event, ctx) => {
              try {
                // A reload keeps the same session running.
                if (name === "session_shutdown" && event && event.reason === "reload") return
                const payload = context(ctx)
                if (event && typeof event.kind === "string") payload.kind = event.kind
                if (event && typeof event.title === "string") payload.title = event.title
                if (event && typeof event.reason === "string") payload.reason = event.reason
                send(name, payload)
              } catch {}
            })
          }
        }

        """
    }
}
