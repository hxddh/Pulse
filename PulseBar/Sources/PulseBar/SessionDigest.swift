import CryptoKit
import Foundation

/// What Pulse has learned by reading a session transcript all the way through.
///
/// Until 1.1 the collector read a bounded window of every transcript — head
/// 64 KB plus a tail — on every single scan, from scratch. For a session under
/// a megabyte that is the whole file. For a long one it means **the middle is
/// never read at all**, not on this tick but ever: the tool calls, errors and
/// token usage in it are permanently invisible, and `records` is reported as
/// unknown because a truncated window cannot count.
///
/// The consequence was that observation quality was worst exactly where it
/// mattered most — the long, complex sessions someone actually needs to keep
/// an eye on.
///
/// A digest is the other approach: remember how far into the file Pulse has
/// read, fold only the new bytes into a running summary, and keep that summary
/// on disk. The middle is not skipped; it is read once, as it goes past.
///
/// **What is stored** (see `docs/architecture.md`): counts, vendor tool names,
/// and file bookkeeping. No prompts, no tool arguments, no paths from inside
/// the transcript. The file identity fields are the transcript's own path and
/// a hash — the same class of thing the tray already shows.
struct SessionDigest: Codable, Equatable {
    /// Transcript path. Identity is this plus `fileID` plus `headHash`.
    var path: String
    /// Filesystem identity, so a recycled path is not mistaken for the same file.
    var fileID: String = ""
    /// Hash of the first bytes — catches a file rewritten in place at the same
    /// size, which no offset or identity check would notice.
    var headHash: String = ""
    /// Bytes already folded in.
    var offset: Int = 0
    /// File size when it was last looked at.
    var size: Int = 0

    /// Records seen across the whole file, not a window. 0 means nothing has
    /// been folded yet — never an estimate.
    var records: Int = 0
    /// Vendor tool names only (`Bash`, `Edit`, …), with how often each ran.
    var toolCounts: [String: Int] = [:]
    /// The last few tool names in order, oldest first.
    var recentTools: [String] = []
    var errors: Int = 0
    var tokensIn: Int = 0
    var tokensOut: Int = 0

    var firstFoldedMs: Int64 = 0
    var lastFoldedMs: Int64 = 0

    /// The most tool names kept in order. A window on the recent past, not a
    /// log: enough to notice a loop, far too little to reconstruct a session.
    static let maxRecentTools = 12
    /// Distinct tool names kept per session.
    static let maxToolNames = 32

    /// Everything before `size` has been folded.
    var caughtUp: Bool { offset >= size }

    /// How much of the file has been read, for an honest "still catching up".
    var progressPercent: Int {
        guard size > 0 else { return 100 }
        return min(100, Int((Double(min(offset, size)) / Double(size)) * 100))
    }

    /// The same tool, over and over, at the tail of the run.
    ///
    /// This is the fact a window can never produce and a person always wants:
    /// an agent that has called the same tool six times in a row is not making
    /// progress, however healthy its lamp looks.
    var repeatedTool: (name: String, count: Int)? {
        guard let last = recentTools.last else { return nil }
        var run = 0
        for name in recentTools.reversed() {
            if name == last { run += 1 } else { break }
        }
        return run >= 3 ? (last, run) : nil
    }
}

/// Whether a file can be read from where Pulse left off.
enum SessionDigestContinuity: Equatable {
    /// Nothing new since last time.
    case unchanged
    /// The file grew; fold from `offset`.
    case appended
    /// Compacted, truncated or rewritten — the old offset means nothing now.
    /// Claude compacts transcripts and Pi keeps a retained tail, so this is a
    /// normal event, not an error. Start again from zero.
    case rewritten
}

enum SessionDigestFold {
    /// Bytes folded per file per scan while catching up.
    ///
    /// A first encounter with a large backlog must not become a stall. Reading
    /// a bounded slice per pass means a big file takes several scans to become
    /// complete — which is why `caughtUp` exists and why the counts are not
    /// presented as totals until it is true.
    static let maxCatchUpBytes = 2_000_000

    static func headHash(_ data: Data) -> String {
        SHA256.hash(data: data.prefix(4096))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Can the stored digest be continued against what is on disk now?
    static func continuity(
        _ digest: SessionDigest,
        size: Int,
        headHash: String,
        fileID: String
    ) -> SessionDigestContinuity {
        if digest.offset == 0 && digest.records == 0 { return size > 0 ? .rewritten : .unchanged }
        // Shrunk: compaction, truncation, or a different file at the same path.
        if size < digest.offset { return .rewritten }
        if !digest.fileID.isEmpty, !fileID.isEmpty, digest.fileID != fileID { return .rewritten }
        // Same length, different beginning — an in-place rewrite that neither
        // the size nor the identity would catch.
        if !digest.headHash.isEmpty, !headHash.isEmpty, digest.headHash != headHash {
            return .rewritten
        }
        return size > digest.offset ? .appended : .unchanged
    }

    /// Fold transcript lines into the digest. Pure, so the counting rules can
    /// be held to fixtures without touching a filesystem.
    static func fold(_ digest: inout SessionDigest, lines: [Substring], nowMs: Int64) {
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            digest.records += 1
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            absorb(object, into: &digest)
        }
        if digest.firstFoldedMs == 0 { digest.firstFoldedMs = nowMs }
        digest.lastFoldedMs = nowMs
    }

    /// Walk a record for the few facts worth keeping. Deliberately narrow:
    /// anything not recognised is skipped rather than guessed at, and no value
    /// that could carry the user's own words is ever stored.
    private static func absorb(_ object: [String: Any], into digest: inout SessionDigest, depth: Int = 0) {
        guard depth < 6 else { return }

        if let flag = object["is_error"] as? Bool, flag { digest.errors += 1 }
        if let type = object["type"] as? String, type == "error" { digest.errors += 1 }

        if let name = toolName(in: object) { note(tool: name, in: &digest) }

        for key in ["input_tokens", "prompt_tokens"] {
            if let value = object[key] as? Int { digest.tokensIn += max(0, value) }
        }
        for key in ["output_tokens", "completion_tokens"] {
            if let value = object[key] as? Int { digest.tokensOut += max(0, value) }
        }

        for value in object.values {
            if let child = value as? [String: Any] {
                absorb(child, into: &digest, depth: depth + 1)
            } else if let list = value as? [[String: Any]] {
                for child in list { absorb(child, into: &digest, depth: depth + 1) }
            }
        }
    }

    /// A tool *name*, never its input. `Bash` is a vendor token; the command it
    /// was going to run is the user's business and is not stored.
    private static func toolName(in object: [String: Any]) -> String? {
        let isToolRecord = (object["type"] as? String).map {
            $0 == "tool_use" || $0 == "tool_call" || $0 == "function_call"
        } ?? false
        let candidates = ["tool_name", "toolName"] + (isToolRecord ? ["name"] : [])
        for key in candidates {
            if let raw = object[key] as? String, let clean = sanitizedToolName(raw) {
                return clean
            }
        }
        return nil
    }

    /// Short, identifier-shaped names only. Anything else could be free text.
    static func sanitizedToolName(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 32 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        guard value.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return value
    }

    private static func note(tool name: String, in digest: inout SessionDigest) {
        if digest.toolCounts[name] != nil || digest.toolCounts.count < SessionDigest.maxToolNames {
            digest.toolCounts[name, default: 0] += 1
        }
        digest.recentTools.append(name)
        if digest.recentTools.count > SessionDigest.maxRecentTools {
            digest.recentTools.removeFirst(digest.recentTools.count - SessionDigest.maxRecentTools)
        }
    }
}

/// Rendering a digest's tool counts as one short, bounded line.
enum SessionDigestSummary {
    /// Most-used first: `Edit 12 · Bash 5 · Read 3`.
    ///
    /// Bounded because this reaches the Details window, and a session with
    /// thirty distinct tools would otherwise produce a paragraph.
    static let maxEntries = 4

    static func line(_ counts: [String: Int], limit: Int = maxEntries) -> String {
        counts
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(limit)
            .map { "\($0.key) \($0.value)" }
            .joined(separator: " · ")
    }
}

/// The collector's digests, held between scans.
///
/// Scans run on one serial queue (`StatusStore.scanQueue`) and the CLI paths
/// are single-threaded, so this needs no lock of its own — stated here because
/// static mutable state that is safe only by convention should say so.
enum HarvestDigests {
    private static var store = SessionDigestStore.load()
    private static var dirty = false

    /// Test seam: the fixture wall and unit tests must not read or write the
    /// real user's digest file.
    static var isEnabled = true

    static func advance(url: URL, size: Int, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> SessionDigest? {
        guard isEnabled else { return nil }
        let key = url.path
        guard let updated = SessionDigestEngine.advance(
            store.entries[key], url: url, size: size, nowMs: nowMs
        ) else { return store.entries[key] }
        store.entries[key] = updated
        dirty = true
        return updated
    }

    /// Write the store out.
    ///
    /// `persist` is false for a scan of a fixture home. Those scans still fold
    /// — the tests need real behaviour — but they must not leave fixture paths
    /// in the user's own digest file, and a unit test must never write to
    /// `~/Library/Application Support` as a side effect.
    static func flush(persist: Bool, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        guard isEnabled, dirty else { return }
        guard persist else {
            store.prune(nowMs: nowMs)
            dirty = false
            return
        }
        store.prune(nowMs: nowMs)
        store.save()
        dirty = false
    }

    /// Support-report line. Says how many transcripts are fully read and how
    /// many are still being caught up on — the state that used to be invisible
    /// because it did not exist.
    static var summary: String {
        let all = store.entries.values
        guard !all.isEmpty else { return "none" }
        let caught = all.filter(\.caughtUp).count
        let records = all.reduce(0) { $0 + $1.records }
        return "sessions=\(all.count) caughtUp=\(caught) records=\(records)"
    }

    /// Tests reset between cases.
    static func resetForTesting() {
        store = SessionDigestStore()
        dirty = false
    }
}

/// Reads the part of a transcript Pulse has not read yet.
enum SessionDigestEngine {
    /// Fold whatever is new in `url` into `digest`.
    ///
    /// Returns `nil` when there is nothing to do, so a caller can tell "no
    /// change" from "changed but still catching up".
    static func advance(
        _ existing: SessionDigest?,
        url: URL,
        size: Int,
        nowMs: Int64,
        maxBytes: Int = SessionDigestFold.maxCatchUpBytes
    ) -> SessionDigest? {
        guard size > 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let head = (try? handle.read(upToCount: 4096)) ?? Data()
        let headHash = SessionDigestFold.headHash(head)
        let fileID = identity(of: url)

        var digest = existing ?? SessionDigest(path: url.path)
        switch SessionDigestFold.continuity(digest, size: size, headHash: headHash, fileID: fileID) {
        case .unchanged:
            return nil
        case .rewritten:
            // Compaction is routine, so this is a fresh start rather than a
            // failure — but the counts must start over too. A digest carried
            // across a rewrite would report a total for a file that no longer
            // contains those records.
            digest = SessionDigest(path: url.path)
        case .appended:
            break
        }
        digest.fileID = fileID
        digest.headHash = headHash
        digest.size = size

        guard digest.offset < size else {
            digest.lastFoldedMs = nowMs
            return digest
        }
        try? handle.seek(toOffset: UInt64(digest.offset))
        let want = min(maxBytes, size - digest.offset)
        guard let chunk = try? handle.read(upToCount: want), !chunk.isEmpty else { return nil }

        // Never fold a half-written record: an append-only transcript is being
        // extended while this runs, and counting a partial line would put a
        // wrong number on a row and never correct itself.
        let complete: Data
        if digest.offset + chunk.count >= size {
            complete = chunk
        } else if let lastNewline = chunk.lastIndex(of: UInt8(ascii: "\n")) {
            complete = chunk[..<chunk.index(after: lastNewline)]
        } else {
            // One record longer than the whole slice. Wait for more rather
            // than guess where it ends.
            return nil
        }
        guard !complete.isEmpty else { return nil }

        let text = String(decoding: complete, as: UTF8.self)
        SessionDigestFold.fold(&digest, lines: text.split(separator: "\n", omittingEmptySubsequences: false), nowMs: nowMs)
        digest.offset += complete.count
        return digest
    }

    /// `<device>.<inode>` — stable across renames, different after a recreate.
    static func identity(of url: URL) -> String {
        guard let values = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]),
              let identifier = values.fileResourceIdentifier
        else { return "" }
        return String(describing: identifier)
    }
}

/// Digests on disk.
///
/// Same discipline as 0.99's attention ledger: bounded, pruned, and documented
/// so the comment and the file agree. Nothing here outlives its usefulness.
struct SessionDigestStore: Codable, Equatable {
    static let retentionDays = 14
    static let maxEntries = 256

    var entries: [String: SessionDigest] = [:]

    /// Fixtures and tests redirect the store so a self-test never folds into
    /// (or prunes) the real user's digests.
    static var pathOverride: URL?

    static var fileURL: URL {
        if let pathOverride { return pathOverride }
        if let home = ProcessInfo.processInfo.environment["PULSE_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent("session-digests.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pulse/session-digests.json")
    }

    static func load() -> SessionDigestStore {
        guard let data = try? Data(contentsOf: fileURL),
              let store = try? JSONDecoder().decode(SessionDigestStore.self, from: data)
        else { return SessionDigestStore() }
        return store
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        let url = Self.fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: [.atomic])
        // Counts and tool names only, but it is still a record of when someone
        // was working. Keep it to this user.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
    }

    mutating func prune(nowMs: Int64) {
        let cutoff = nowMs - Int64(Self.retentionDays) * 24 * 60 * 60 * 1000
        entries = entries.filter { $0.value.lastFoldedMs >= cutoff }
        guard entries.count > Self.maxEntries else { return }
        let keep = entries
            .sorted { $0.value.lastFoldedMs > $1.value.lastFoldedMs }
            .prefix(Self.maxEntries)
        entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }
}
