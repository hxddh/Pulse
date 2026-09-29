import Foundation
import PulseCore

/// 18.0 · Claude says, in its own words, which sessions are waiting.
///
/// `claude agents --json` (code.claude.com/docs/en/agent-view) lists the live
/// sessions with `status` (busy | waiting | idle) and, for a waiting one,
/// `waitingFor` ("permission prompt", "input needed", "sandbox request",
/// "worker request", "dialog open"). That is a vendor-reported blocked state,
/// so it passes the No-fake-Waiting rule the same way a hook does — and it
/// needs no hooks, which most people never install.
///
/// Running it is a process spawn, so it is rationed: only when a Claude
/// process is live and Claude's hooks are not installed (the hooks already
/// say the same thing, sooner), at most every `minIntervalMs`, bounded by a
/// timeout, and switched off for a while after repeated failures (an older
/// `claude` without the subcommand). Anything unreadable is "no answer",
/// never "not waiting" and never "waiting".
package enum ClaudeAgentsProbe {
    package struct Agent: Equatable, Sendable {
        package var sessionID: String
        package var pid: Int
        package var cwd: String
        package var status: String
        package var waitingFor: String
    }

    package struct Wait: Equatable, Sendable {
        package var sessionID: String
        package var pid: Int
        package var cwd: String
        package var kind: AttentionKind
        /// Claude's own words for what it is waiting on.
        package var reason: String
        /// When Pulse first saw this session waiting (the vendor gives no
        /// stamp); carried across samples so the wait's age is honest.
        package var sinceMs: Int64
    }

    package static let minIntervalMs: Int64 = 15_000
    package static let timeoutSeconds: TimeInterval = 3
    package static let failuresBeforeBackoff = 3
    package static let backoffMs: Int64 = 30 * 60 * 1000
    package static let outputLimit = 256 * 1024

    // MARK: - Parse (pure)

    /// Accepts a top-level array or an object wrapping one (`agents`,
    /// `sessions`). Nil when the bytes are not that shape at all.
    package static func parse(_ data: Data) -> [Agent]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let list: [Any]
        if let array = json as? [Any] {
            list = array
        } else if let object = json as? [String: Any],
                  let array = (object["agents"] ?? object["sessions"]) as? [Any] {
            list = array
        } else {
            return nil
        }
        return list.compactMap { item in
            guard let dict = item as? [String: Any] else { return nil }
            func text(_ keys: [String]) -> String {
                for key in keys {
                    if let value = dict[key] as? String {
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { return trimmed }
                    }
                }
                return ""
            }
            let pid = (dict["pid"] as? Int) ?? Int(text(["pid"])) ?? 0
            return Agent(
                sessionID: text(["sessionId", "session_id", "id"]),
                pid: pid,
                cwd: text(["cwd"]),
                // Background sessions carry `state` (working | blocked | …).
                status: text(["status", "state"]).lowercased(),
                waitingFor: text(["waitingFor", "waiting_for"])
            )
        }
    }

    /// What each waiting session is blocked on. `status` must say waiting
    /// (or `blocked` for a background session) — `waitingFor` alone is not
    /// enough.
    package static func kind(status: String, waitingFor: String) -> AttentionKind? {
        guard status == "waiting" || status == "blocked" else { return nil }
        let reason = waitingFor.lowercased()
        if reason.contains("permission") || reason.contains("sandbox") { return .permission }
        if reason.contains("input") { return .question }
        return .waiting
    }

    package static func waits(_ agents: [Agent], previous: [Wait], nowMs: Int64) -> [Wait] {
        agents.compactMap { agent in
            guard let kind = kind(status: agent.status, waitingFor: agent.waitingFor),
                  !agent.sessionID.isEmpty || agent.pid > 0
            else { return nil }
            let earlier = previous.first {
                (!agent.sessionID.isEmpty && $0.sessionID == agent.sessionID)
                    || (agent.sessionID.isEmpty && $0.pid == agent.pid)
            }
            return Wait(
                sessionID: agent.sessionID,
                pid: agent.pid,
                cwd: agent.cwd,
                kind: kind,
                reason: agent.waitingFor,
                sinceMs: earlier?.kind == kind ? earlier?.sinceMs ?? nowMs : nowMs
            )
        }
    }

    // MARK: - The ration

    package struct State: Equatable, Sendable {
        package var lastRunMs: Int64 = 0
        package var waits: [Wait] = []
        package var failures = 0
        package var disabledUntilMs: Int64 = 0

        package init() {}
    }

    package static func shouldRun(state: State, nowMs: Int64, claudeLive: Bool, hooksInstalled: Bool) -> Bool {
        guard claudeLive, !hooksInstalled else { return false }
        guard nowMs >= state.disabledUntilMs else { return false }
        return nowMs - state.lastRunMs >= minIntervalMs
    }

    /// Fold one run's outcome into the state. `output` nil = the run failed
    /// (no binary, timeout, non-zero exit, unparseable).
    package static func record(_ agents: [Agent]?, into state: inout State, nowMs: Int64) {
        state.lastRunMs = nowMs
        guard let agents else {
            // A failed run (timeout, non-zero exit, unparseable) is no answer:
            // it neither raises nor clears. The previous sample's waits stay
            // until a successful answer replaces them — a single slow run
            // must not blink a real wait off and back on. Only when the probe
            // gives up for `backoffMs` do they go, since nothing would
            // refresh them for that long.
            state.failures += 1
            if state.failures >= failuresBeforeBackoff {
                state.waits = []
                state.disabledUntilMs = nowMs + backoffMs
                state.failures = 0
            }
            return
        }
        state.failures = 0
        state.waits = waits(agents, previous: state.waits, nowMs: nowMs)
    }

    private static let state = Guarded(State())

    /// Called on the scan queue. Returns the waits to show this scan — the
    /// last sample's between runs, none when not allowed to run.
    package static func sample(nowMs: Int64, claudeLive: Bool, hooksInstalled: Bool) -> [Wait] {
        let run = state.withValue { current -> Bool in
            guard shouldRun(state: current, nowMs: nowMs, claudeLive: claudeLive, hooksInstalled: hooksInstalled) else {
                if !claudeLive || hooksInstalled { current.waits = [] }
                return false
            }
            current.lastRunMs = nowMs
            return true
        }
        if run {
            var agents: [Agent]?
            if let executable = ClaudeCLI.executable() {
                if let result = ProcessIO.run(
                    executable: executable,
                    arguments: ["agents", "--json"],
                    timeout: timeoutSeconds,
                    outputLimit: outputLimit
                ), result.status == 0, !result.timedOut {
                    agents = parse(result.stdout)
                }
            }
            state.withValue { record(agents, into: &$0, nowMs: nowMs) }
            if agents == nil { DebugLog.write("claude agents probe: no answer") }
        }
        return state.withValue { $0.waits }
    }
}
