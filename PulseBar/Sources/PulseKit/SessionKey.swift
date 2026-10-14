import Foundation

/// The one identity of a tray row — decided when the row is born, and it
/// never changes.
///
/// - a **session** the hooks named: the agent and the vendor's session id;
/// - a session-less hook event: the agent and the **folder** it came from
///   (a stable hash of the path — a key never carries a path: its
///   `description` reaches `debug.log` and banners, which promise they hold
///   none);
/// - an agent **process** no session has claimed (typically one started
///   before Pulse was running): the agent and its pid. Ephemeral — once a
///   session claims that process, the process-only row simply is not built.
///
/// Everything inside Pulse keys by this value. A string is made only where
/// one must leave the process (a banner's id and user info): `description`,
/// `agent|<id>`, `agent|hook:<hash>`, `agent|pid:<pid>`.
package struct SessionKey: Hashable, Comparable, Sendable, CustomStringConvertible {
    package enum Scope: Hashable, Sendable {
        /// The vendor's session id.
        case session(String)
        /// A session-less event's folder, as `SessionKey.stableHash` of its
        /// path ("-" for none).
        case folder(String)
        /// A process no session has claimed.
        case process(Int32)
    }

    package let agent: AgentID
    package let scope: Scope

    package init(agent: AgentID, scope: Scope) {
        self.agent = agent
        self.scope = scope
    }

    /// The session an event names — or, naming none, the folder it came
    /// from.
    package init(_ agent: AgentID, _ session: String, cwd: String = "") {
        let id = session.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(agent: agent, scope: id.isEmpty ? .folder(cwd.isEmpty ? "-" : Self.stableHash(cwd)) : .session(id))
    }

    /// A process seen with no session to attach to.
    package static func process(_ agent: AgentID, pid: Int32) -> SessionKey {
        SessionKey(agent: agent, scope: .process(pid))
    }

    /// The key is a folder's: its events named no session.
    package var isSessionless: Bool {
        if case .folder = scope { return true }
        return false
    }

    package var description: String {
        switch scope {
        case .session(let id): return "\(agent.rawValue)|\(id)"
        case .folder(let hash): return "\(agent.rawValue)|hook:\(hash)"
        case .process(let pid): return "\(agent.rawValue)|pid:\(pid)"
        }
    }

    /// A total order, so the same world always lists the same way.
    package static func < (a: SessionKey, b: SessionKey) -> Bool {
        a.description < b.description
    }

    /// Short, process-independent digest (FNV-1a). `Hasher` is seeded per
    /// launch and would give the same folder a new key after every restart.
    package static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%08x", UInt32(truncatingIfNeeded: hash ^ (hash >> 32)))
    }
}
