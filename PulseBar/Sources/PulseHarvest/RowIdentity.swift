import Foundation
import PulseCore

/// 23.0 · the one place a tray row's key is decided — and it never changes.
///
/// Each kind of row has its own key, fixed when the row is born, and a row
/// never "upgrades" into another:
///
/// - a **session** row (24.0: a hook named the session) is
///   `agent|<vendor session id>`; an event that names no session is
///   `agent|hook:<hash of its cwd>`;
/// - a **process-only** row (an agent process no session has claimed —
///   typically one started before Pulse was running) is `agent|pid:<pid>`.
///   It is ephemeral: once a session claims that process, the process-only
///   row simply is not built.
///
/// Keys never carry a path: a path would land in `session-log.json`, which
/// promises it holds none. FNV-1a keeps the hash stable across launches.
package enum RowIdentity {
    /// A session the hooks named, or — with no session id — the folder the
    /// event came from.
    package static func session(agent: AgentID, session: String, cwd: String = "") -> String {
        let sid = session.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sid.isEmpty { return "\(agent.rawValue)|\(sid)" }
        return "\(agent.rawValue)|hook:\(cwd.isEmpty ? "-" : stableHash(cwd))"
    }

    /// A process seen with no session to attach to.
    package static func process(agent: AgentID, pid: Int) -> String {
        "\(agent.rawValue)|pid:\(pid)"
    }

    /// Whether a key names a process-only row.
    package static func isProcessKey(_ key: String) -> Bool {
        key.contains("|pid:")
    }

    /// Whether a key names a session-less (folder-keyed) session.
    package static func isFolderKey(_ key: String) -> Bool {
        key.contains("|hook:")
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
