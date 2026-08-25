import Foundation

/// 2.9 Quality — the push half of "what is it doing right now".
///
/// Pulse's hook has stood in the vendor's event stream since 1.0, but only
/// for waits. Every activity fact — current tool, current file — was polled
/// off the disk: scan cadence + power backoff + mtime gates + read windows,
/// stacked into minute-grade staleness. This spool is the hook finally
/// speaking about work, not just waits: one small state file per session
/// under `activity.d/`, overwritten on every `PreToolUse` /
/// `UserPromptSubmit`, watched by the same DispatchSource machinery as the
/// attention inbox.
///
/// Rules, all inherited from older scars:
/// - **An activity event is not a wait and must never become one.** Nothing
///   here touches attention.tsv, and the builder never derives Waiting from
///   a spool entry.
/// - **Present tense only for second-grade evidence**: display gates on
///   `liveWindowMs`; past it, the row falls back to the polled story.
/// - **The filename decides identity** (agent + sanitized session); a body
///   that disagrees is refused — the respond spool's rule.
/// - Bounded everything: file count, bytes per file, age; unknown agents are
///   skipped, never guessed.
enum ActivitySpool {
    static let version = 1
    static let maxFiles = 64
    static let maxBytesPerFile = 4 * 1024
    static let maxAgeMs: Int64 = 24 * 60 * 60 * 1000
    /// How long an event may be spoken about in the present tense.
    static let liveWindowMs: Int64 = 120_000

    struct Event: Equatable {
        var agent: String
        var session: String
        /// "tool" (PreToolUse) or "prompt" (UserPromptSubmit).
        var event: String
        var tool: String
        var target: String
        var prompt: String
        var cwd: String
        var tsMs: Int64
    }

    static var directoryOverride: URL?

    static var directory: URL {
        if let directoryOverride { return directoryOverride }
        return AttentionIO.path.deletingLastPathComponent()
            .appendingPathComponent("activity.d", isDirectory: true)
    }

    /// Filename-safe identity token — mirrors `pulse_hook.sanitize_session_token`.
    static func sanitizeToken(_ value: String) -> String {
        String(value.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
            .prefix(80))
    }

    static func fileName(agent: String, session: String) -> String {
        agent + "-" + sanitizeToken(session) + ".json"
    }

    /// Receiver-side write, key-for-key with the Python hook's record so the
    /// two ends of the contract stay interchangeable.
    @discardableResult
    static func write(_ event: Event) -> Bool {
        guard !event.agent.isEmpty, !event.session.isEmpty else { return false }
        let record: [String: Any] = [
            "v": version,
            "agent": event.agent,
            "session": event.session,
            "event": event.event,
            "tool": event.tool,
            "target": event.target,
            "prompt": event.prompt,
            "cwd": event.cwd,
            "ts_ms": event.tsMs,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        else { return false }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let ok = PrivateFile.write(
            data,
            to: directory.appendingPathComponent(fileName(agent: event.agent, session: event.session))
        )
        housekeep(nowMs: event.tsMs)
        return ok
    }

    /// Age out and cap, cheapest-first — parity with the Python hook.
    static func housekeep(nowMs: Int64) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        var dated: [(String, Int64)] = []
        for name in names where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            let ms = modificationMs(of: url)
            if ms > 0, nowMs - ms > maxAgeMs {
                try? fm.removeItem(at: url)
            } else {
                dated.append((name, ms))
            }
        }
        guard dated.count > maxFiles else { return }
        dated.sort { $0.1 < $1.1 }
        for (name, _) in dated.prefix(dated.count - maxFiles) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Bounded read of every live-enough state file. The filename decides
    /// which agent+session this is; a body that disagrees is skipped.
    static func readEvents(nowMs: Int64) -> [Event] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var events: [Event] = []
        for name in names.sorted().prefix(maxFiles) where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            guard let data = boundedRead(url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (object["v"] as? Int) == version
            else { continue }
            let agent = (object["agent"] as? String) ?? ""
            let session = (object["session"] as? String) ?? ""
            guard !agent.isEmpty, !session.isEmpty,
                  fileName(agent: agent, session: session) == name
            else { continue }
            let rawTs = (object["ts_ms"] as? NSNumber)?.int64Value ?? 0
            // The writer is this machine, so a future stamp is a broken
            // clock, not a fast remote one — clamp rather than trust.
            let tsMs = min(rawTs, nowMs)
            guard tsMs > 0, nowMs - tsMs <= maxAgeMs else { continue }
            events.append(Event(
                agent: agent,
                session: session,
                event: (object["event"] as? String) ?? "",
                tool: string(object, "tool"),
                target: string(object, "target"),
                prompt: string(object, "prompt"),
                cwd: string(object, "cwd"),
                tsMs: tsMs
            ))
        }
        return events
    }

    private static func string(_ object: [String: Any], _ key: String) -> String {
        ((object[key] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func boundedRead(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: maxBytesPerFile)
    }

    private static func modificationMs(of url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let date = attrs?[.modificationDate] as? Date else { return 0 }
        return Int64(date.timeIntervalSince1970 * 1000)
    }
}
