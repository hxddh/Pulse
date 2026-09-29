import Foundation
import PulseCore

/// 23.0 · the one place a tray row's key is decided — and it never changes.
///
/// Until 23.0 a row's key could move over its life: a process-only row
/// (`claude`) became a cwd-matched row, which became the vendor's session
/// (`claude|<id>`), and every surface that remembered a key — the session
/// log, the banner in flight, the timeline, a soft dismissal — needed a remap
/// to follow it. Now each kind of row has its own key, fixed when the row is
/// born, and a row never "upgrades" into another:
///
/// - a **session** row (the harvest found the vendor's session) is
///   `agent|<vendor session id>`; with no id, `agent|file:<hash of the
///   transcript path>`; with neither, `agent|at:<hash of cwd and start>`;
/// - a **hook-only** row (a hook raised a wait for a session the harvest has
///   not found) is keyed like the session it names — `agent|<session id>` —
///   so when the transcript appears the row is the same row; a hook that
///   names no session is `agent|hook:<hash of its cwd>`;
/// - a **process-only** row (a process and nothing else) is
///   `agent|pid:<pid>`. It is ephemeral: when a session row for the agent
///   exists, the process is attached to that row and the process-only row
///   simply is not built.
///
/// Keys never carry a path: a path would land in `session-log.json`, which
/// promises it holds none. FNV-1a keeps the hash stable across launches.
package enum RowIdentity {
    /// A harvested (or hook-named) vendor session.
    package static func session(
        agent: AgentID,
        sessionID: String,
        transcriptPath: String = "",
        cwd: String = "",
        startedMs: Int64 = 0,
        task: String = ""
    ) -> String {
        let prefix = agent.rawValue
        let sid = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sid.isEmpty { return "\(prefix)|\(sid)" }
        if !transcriptPath.isEmpty { return "\(prefix)|file:\(stableHash(transcriptPath))" }
        // Only facts that cannot change while the session lives: where it
        // started and when. The task is the last resort — a vendor may rename
        // a session once, which is still steadier than array order.
        var seed: [String] = []
        if !cwd.isEmpty { seed.append("c:\(cwd)") }
        if startedMs > 0 { seed.append("s:\(startedMs)") }
        if seed.isEmpty, !task.isEmpty { seed.append("t:\(task)") }
        guard !seed.isEmpty else { return "\(prefix)|anon" }
        return "\(prefix)|at:\(stableHash(seed.joined(separator: "\u{1}")))"
    }

    /// A process seen with no session to attach to.
    package static func process(agent: AgentID, pid: Int) -> String {
        "\(agent.rawValue)|pid:\(pid)"
    }

    /// A hook wait with no session row to attach to.
    package static func hook(agent: AgentID, session: String, cwd: String) -> String {
        if !session.isEmpty { return self.session(agent: agent, sessionID: session) }
        return "\(agent.rawValue)|hook:\(cwd.isEmpty ? "-" : stableHash(cwd))"
    }

    /// Whether a key names a process-only row.
    package static func isProcessKey(_ key: String) -> Bool {
        key.contains("|pid:")
    }

    /// Short, process-independent digest. `Hasher` is seeded per launch and
    /// would give the same session a new key after every restart.
    package static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%08x", UInt32(truncatingIfNeeded: hash ^ (hash >> 32)))
    }
}

extension ActivityHarvest.Row {
    /// This session's row key (`RowIdentity.session`).
    package var rowKey: String {
        RowIdentity.session(
            agent: id,
            sessionID: sessionID,
            transcriptPath: transcriptPath,
            cwd: cwd,
            startedMs: startedMs,
            task: task
        )
    }
}

extension AttentionReader.Entry {
    /// The row a hook wait makes when no session row takes it.
    package var hookRowKey: String {
        RowIdentity.hook(agent: id, session: session, cwd: cwd)
    }
}
