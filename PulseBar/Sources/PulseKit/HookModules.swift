import Foundation

/// What the two hook modules Pulse owns whole share — the OpenCode plugin
/// (`OpenCode.plugin`) and the Pi extension (`Pi.module`). Each observes its
/// vendor's documented lifecycle events and hands each one to `pulse-hook`,
/// detached, with a small JSON payload as its last argument (the receiver reads a payload there and then skips stdin):
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

    /// Shared by both modules: spawn `pulse-hook <agent> <event> <payload>`
    /// detached, never wait. The payload rides in argv, not on a pipe.
    package static func sendFunction(launcher: String, agent: String) -> String {
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
}
