import Foundation

extension AgentSpec {
    /// OpenCode (anomalyco/opencode, SDK v2 `Event`): a plugin Pulse owns
    /// whole, whose only hook is `event`; it forwards each event's properties
    /// as the payload, in the last argument.
    package static let opencode = AgentSpec(
        id: .opencode,
        displayName: "OpenCode",
        aliases: [],
        // Plugin events `permission.asked` / `question.asked`, resolved by
        // `permission.replied` / `question.replied` / `question.rejected`.
        waiting: .hooks,
        process: AgentProcessRule(
            basenames: ["opencode", "open-code"],
            pathNeedles: ["/bin/opencode", "opencode@", "@opencode"]
        ),
        hooks: HookContract(
            format: .module(render: { OpenCode.plugin(launcher: $0, events: $1) }),
            path: ".config/opencode/plugins/pulse.js",
            home: ".config/opencode",
            events: [
                HookEvent("session.created", .start),
                // Busy or retrying says work goes on, not that a tool ran: it
                // never answers an ask.
                HookEvent("session.status", .ignore),
                HookEvent("session.idle", .turn),
                HookEvent("session.error", .failedTurn),
                HookEvent("session.deleted", .end),
                HookEvent("permission.asked", .blocked(.permission)),
                HookEvent("permission.replied", .resolved),
                HookEvent("question.asked", .blocked(.question)),
                HookEvent("question.replied", .resolved),
                HookEvent("question.rejected", .resolved),
            ]
        ),
        read: { OpenCode.read($0, $1) }
    )
}

/// OpenCode's events whose meaning is in the payload, and its plugin.
package enum OpenCode {
    package static func read(_ event: String, _ payload: [String: Any]) -> HookReading? {
        switch event {
        case "session.status":
            let status = (payload["status"] as? [String: Any]).map { PulseHookReceiver.string($0, keys: ["type"]) }
                ?? PulseHookReceiver.string(payload, keys: ["status"])
            return HookReading(action: status == "busy" || status == "retry" ? .status : .ignore)
        case "permission.asked":
            return HookReading(action: .blocked(.permission), ask: permissionAsk(payload))
        case "question.asked":
            return HookReading(action: .blocked(.question), ask: questionAsk(payload))
        default:
            return nil
        }
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
    package static func plugin(launcher: String, events: [String]) -> String {
        let list = events.map(HookModules.literal).joined(separator: ", ")
        return """
        // Pulse — OpenCode plugin (pulse-hook). Installed by Pulse; remove it from
        // Pulse Settings → Hooks. It observes session and permission events and
        // hands each to pulse-hook, detached. It never throws, never awaits the
        // child, and changes nothing OpenCode does.
        import { spawn } from "node:child_process"

        \(HookModules.sendFunction(launcher: launcher, agent: "opencode"))

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
              if (event.type === "session.error") {
                const e = p.error || {}
                const text = (e.data && typeof e.data.message === "string" && e.data.message) || (typeof e.message === "string" && e.message) || (typeof e.name === "string" && e.name) || ""
                if (text) payload.error = text.slice(0, 200)
              }
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
}
