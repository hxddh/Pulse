import Foundation

/// 24.0 · The two hook modules Pulse owns whole: an OpenCode plugin and a Pi
/// extension. Each observes its vendor's documented lifecycle events and
/// hands each one to `pulse-hook`, detached, with a small JSON payload as its
/// last argument (the receiver reads a payload there and then skips stdin):
/// the event is complete the moment the child is spawned, so the last event
/// before the agent exits — its shutdown — is not lost with an unflushed
/// pipe. Neither may throw, block, await the child, or return anything the
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

    /// Shared by both modules: spawn `pulse-hook <agent> <event> <payload>`
    /// detached, never wait. The payload rides in argv, not on a pipe.
    private static func sendFunction(launcher: String, agent: String) -> String {
        """
        const PULSE_HOOK = \(literal(launcher))

        function send(event, payload) {
          try {
            const child = spawn(PULSE_HOOK, [\(literal(agent)), event, JSON.stringify(payload)], {
              detached: true,
              stdio: "ignore",
            })
            child.on("error", () => {})
            child.unref()
          } catch {}
        }
        """
    }

    /// `~/.config/opencode/plugins/pulse.js` — a plugin whose only hook is
    /// `event` (anomalyco/opencode packages/plugin `Hooks.event`). Every
    /// named export of a legacy plugin module must be a plugin function, so
    /// this module exports exactly one.
    ///
    /// A subagent runs in a child session (`session.created` with
    /// `info.parentID`). Its lifecycle is not the person's session — its
    /// `session.idle` is not "your turn", and it must not become a row — so
    /// it is dropped; its permission and question events block the parent's
    /// work, so they are sent under the root session's id.
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
        const ASKS = new Set(["permission.asked", "permission.replied", "question.asked", "question.replied", "question.rejected"])
        // Child session id → parent id (subagents), bounded.
        const PARENTS = new Map()

        function rootOf(id) {
          let current = id
          for (let i = 0; i < 8 && PARENTS.has(current); i++) current = PARENTS.get(current)
          return current
        }

        export const PulsePlugin = async ({ directory }) => ({
          event: async ({ event }) => {
            try {
              if (!event || !EVENTS.has(event.type)) return
              const p = event.properties || {}
              const info = p.info || {}
              if (event.type === "session.created" && info.parentID && info.id) {
                PARENTS.set(info.id, info.parentID)
                if (PARENTS.size > 512) PARENTS.delete(PARENTS.keys().next().value)
                return
              }
              const own = p.sessionID || info.id || ""
              const child = PARENTS.has(own)
              if (child && !ASKS.has(event.type)) {
                if (event.type === "session.deleted") PARENTS.delete(own)
                return
              }
              const payload = {
                sessionID: child ? rootOf(own) : own,
                directory: info.directory || directory || "",
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
