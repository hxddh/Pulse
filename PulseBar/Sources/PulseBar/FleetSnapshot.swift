import Foundation

/// The rest of the fleet, not just its doorbell.
///
/// Since 1.0 a remote agent has existed in Pulse only while it was asking for
/// something: a row is conjured by an attention raise and cleared by `done`.
/// "Three agents still running on devbox" and "devbox is switched off" looked
/// identical — in a product whose scene is called *Remote Fleet*.
///
/// A fleet snapshot is one bounded JSON file per machine, carried by the same
/// user-owned sync tooling as `attention.d/` and `respond.d/`. Pulse writes
/// its own under `fleet.d/<host>.json` (opt-in, off by default — content
/// leaving the machine is the user's call) and reads every other host's file
/// from the same directory. No network, no server, no daemon.
///
/// Honesty rules, in order of how expensive they were to learn:
/// - **Every remote fact is past tense.** The snapshot's age rides with it,
///   and past `staleAfterMs` the row goes lost-contact rather than quoting
///   numbers nobody is refreshing (2.4's rule).
/// - **Waiting never comes from a snapshot.** The attention protocol is the
///   only source of Waiting; a snapshot claiming otherwise would be inferred
///   Waiting wearing a costume.
/// - **Counts and short names only.** Task titles are capped and sanitized
///   like the attention ledger's; the project is a leaf name, never a path;
///   no branch, no diff text, no argv.
enum FleetSnapshot {
    static let version = 1
    /// Bounds mirror the attention inbox: a hostile or broken writer must not
    /// be able to make this Mac read without limit.
    static let maxRows = 16
    static let maxHosts = 16
    static let maxBytesPerFile = 256 * 1024
    static let maxTaskLength = 160
    static let maxFieldLength = 64
    /// Older than this and the row stops quoting facts: lost contact, in so
    /// many words. Matches the attention row's shape from scene AO.
    static let staleAfterMs: Int64 = 10 * 60 * 1000
    /// Older than this and the row is gone entirely.
    static let dropAfterMs: Int64 = 60 * 60 * 1000
    /// A sender clock this far ahead of our receipt time is suspect — same
    /// tolerance direction as the attention reader.
    static let clockSkewMs: Int64 = 5 * 60 * 1000
    /// How often the local snapshot is rewritten. Well above the probe tick:
    /// the file is for another machine's glance, not a live wire.
    static let writeIntervalMs: Int64 = 30_000

    struct Row: Codable, Equatable {
        var agent: String
        var session: String = ""
        var task: String = ""
        /// Leaf directory name only — never a path.
        var project: String = ""
        var tool: String = ""
        var model: String = ""
        var phase: String = ""
        /// The session's own activity clock, sender's wall time.
        var activityAtMs: Int64 = 0
        /// -1 for not known, exactly as at home.
        var cpuPercent: Double = -1
        var changedPaths: Int = -1
        var insertions: Int = -1
        var deletions: Int = -1

        enum CodingKeys: String, CodingKey {
            case agent, session, task, project, tool, model, phase
            case activityAtMs = "activity_at_ms"
            case cpuPercent = "cpu_percent"
            case changedPaths = "changed_paths"
            case insertions, deletions
        }
    }

    struct File: Codable, Equatable {
        var v: Int = FleetSnapshot.version
        var host: String
        var sentAtMs: Int64
        var rows: [Row]

        enum CodingKeys: String, CodingKey {
            case v, host, rows
            case sentAtMs = "sent_at_ms"
        }
    }

    /// One remote machine's report, as read back: the file's rows plus the
    /// only clock that is both local and durable — when its bytes landed on
    /// *this* disk (`AttentionIO.Source.receivedAtMs` reasoning).
    struct Report: Equatable {
        var host: String
        var sentAtMs: Int64
        var receivedAtMs: Int64
        var rows: [Row]
    }

    static var directoryOverride: URL?

    static var directory: URL {
        if let directoryOverride { return directoryOverride }
        return AttentionIO.path.deletingLastPathComponent()
            .appendingPathComponent("fleet.d", isDirectory: true)
    }

    // MARK: - Building this machine's snapshot

    /// Local rows only, tray order, bounded and sanitized. A remote row must
    /// never round-trip: relaying devbox's rows under this Mac's name would
    /// double every agent the moment two machines sync with each other.
    static func build(host: String, rows: [AgentRow], sentAtMs: Int64) -> File {
        let outgoing = rows
            .filter { !$0.isRemote }
            .prefix(maxRows)
            .map { row -> Row in
                Row(
                    agent: row.agent.rawValue,
                    session: clip(row.sessionID, to: maxFieldLength),
                    task: clip(ContentSanitizer.redact(row.usefulTask ?? ""), to: maxTaskLength),
                    project: clip(leaf(of: row.project.isEmpty ? row.cwd : row.project), to: maxFieldLength),
                    tool: clip(row.tool, to: maxFieldLength),
                    model: clip(row.model, to: maxFieldLength),
                    phase: clip(row.phase, to: maxFieldLength),
                    activityAtMs: max(row.harvestMs, row.activityChangedMs),
                    cpuPercent: row.cpuPercent,
                    changedPaths: row.changedPaths,
                    insertions: row.insertions,
                    deletions: row.deletions
                )
            }
        return File(host: host, sentAtMs: sentAtMs, rows: Array(outgoing))
    }

    /// Nothing in a snapshot may be a path. A project that arrives as one —
    /// ours or a remote writer's — is reduced to its leaf.
    static func leaf(of value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("/") else { return trimmed }
        return String(trimmed.split(separator: "/").last ?? "")
    }

    private static func clip(_ value: String, to limit: Int) -> String {
        String(value.prefix(limit))
    }

    /// 0600 from the first byte, like everything else that leaves this app.
    @discardableResult
    static func write(_ file: File) -> Bool {
        guard !file.host.isEmpty else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(file) else { return false }
        let destination = directory.appendingPathComponent(sanitize(file.host) + ".json")
        return PrivateFile.write(data, to: destination)
    }

    // MARK: - Reading everyone else's

    /// Bounded read of every other host's snapshot. Ancient files are skipped
    /// here (they are gone, not lost-contact — the builder draws that line);
    /// a file whose body claims a different host than its name is skipped
    /// entirely, the same rule the respond spool uses: the name decides which
    /// machine this is, and a mismatch is somebody being clever.
    static func readReports(selfHost: String, nowMs: Int64) -> [Report] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var reports: [Report] = []
        for name in names.sorted().prefix(maxHosts) where name.hasSuffix(".json") {
            let hostName = String(name.dropLast(".json".count))
            guard !hostName.isEmpty, hostName != sanitize(selfHost) else { continue }
            let url = directory.appendingPathComponent(name)
            guard let data = boundedRead(url),
                  let file = try? JSONDecoder().decode(File.self, from: data),
                  file.v == version,
                  sanitize(file.host) == hostName
            else { continue }
            let receivedAtMs = modificationMs(of: url)
            guard receivedAtMs > 0, nowMs - receivedAtMs <= dropAfterMs else { continue }
            reports.append(Report(
                host: hostName,
                sentAtMs: file.sentAtMs,
                receivedAtMs: receivedAtMs,
                rows: Array(file.rows.prefix(maxRows))
            ))
        }
        return reports
    }

    static func sanitize(_ host: String) -> String {
        String(host.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
            .prefix(32))
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
