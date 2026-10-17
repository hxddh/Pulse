import Foundation

/// What the two hook modules Pulse owns whole share — the OpenCode plugin
/// (`OpenCode.plugin`) and the Pi extension (`Pi.module`). Each observes its
/// vendor's documented lifecycle events and hands each one to `pulse-hook`,
/// detached and one child at a time, with a small JSON payload as its last
/// argument (the receiver reads a payload there and then skips stdin):
/// the event is complete the moment the child is spawned, so the last event
/// before the agent exits — its shutdown — is not lost with an unflushed
/// pipe. Neither may throw, block, await the child, or return anything the
/// vendor would act on: every handler is wrapped in `try`, returns
/// `undefined`, and the child is `unref`'d.
package enum HookModules {
    /// The launcher path as a JavaScript string literal.
    package static func literal(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(text) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The OpenCode plugin's ordered sender: one `pulse-hook <agent> <event>
    /// <payload>` child at a time — the next spawned when the one before it
    /// exited, or after `GUARD_MS` — since the log numbers lines in the
    /// order the children take its lock, and a tool's step must never be
    /// numbered after the turn's end. The queue is bounded (`QUEUE_MAX`);
    /// the events in `keep` (a block, its answer, the turn's end) are
    /// dropped from a full queue last. Never awaited, never throws. (The Pi
    /// extension keeps its own copy of this pattern, `Pi.module`.)
    package static func orderedSendFunction(launcher: String, agent: String, keep: [String]) -> String {
        let kept = keep.map(literal).joined(separator: ", ")
        return """
        const PULSE_HOOK = \(literal(launcher))
        const GUARD_MS = 1500
        const QUEUE_MAX = 64
        const KEEP = new Set([\(kept)])
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
            const child = spawn(PULSE_HOOK, [\(literal(agent)), event, JSON.stringify(payload)], {
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
        """
    }
}
