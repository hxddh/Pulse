import Foundation
import PulseCore
import SQLite3

// Claude: project-directory decoding and subagent counts.
//
// 12.3 γ: one vendor per file. Moved verbatim out of HarvestFacts.swift; the
// dispatch that picks a dialect for a transcript lives in
// TranscriptDialect.swift.

extension NativeActivityHarvest {
    /// `-Users-me-code-Pulse` → the workspace it was made from (Claude's
    /// projects directory). Empty `path` means the name is not one.
    package static func decodeClaudeProjectDir(_ name: String) -> (path: String, verified: Bool) {
        let s = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("-"), !s.contains("/") else { return ("", false) }
        let parts = s.split(separator: "-", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return ("", false) }
        let resolved = resolveDashEncodedPath(parts)
        if resolved.verified { return resolved }
        // Nothing on disk vouched for it, so the old shape check still stands
        // guard: an unconfirmed decode is only worth showing when it at least
        // looks like a home directory.
        let head = parts[0].lowercased()
        guard head == "users" || head == "home" else { return ("", false) }
        return resolved
    }

    /// How many `-` separated pieces a project directory name may have before
    /// resolving it stops being worth the stat calls.
    package static let maxDashPathSegments = 32

    /// Hard ceiling on directory probes for one name. The search backtracks,
    /// so a pathological name (`-a-a-a-a-…`) could otherwise walk a large
    /// tree; past this the answer is "could not confirm", which is a fine
    /// answer.
    package static let maxDashPathProbes = 256

    /// Resolved project directories, for the duration of one scan.
    ///
    /// One project directory holds every session file for that workspace, and
    /// the answer cannot change mid-pass, so without this the same name is
    /// re-probed once per transcript. `scan()` clears it, so a resolution
    /// never outlives the pass that made it.
    /// Lives in `ScanEngine.memory` since 12.3.
    package static var dashPathCache: [String: (path: String, verified: Bool)] {
        get { ScanEngine.memory.withValue { $0.dashPaths } }
        set { ScanEngine.memory.withValue { $0.dashPaths = newValue } }
    }

    /// Turn `["Users", "me", "my", "project"]` back into a real directory.
    ///
    /// Claude (`~/.claude/projects/-Users-me-my-project`) and Pi
    /// (`--Users-me-my-project--`) both write a workspace path with every `/`
    /// replaced by `-`, and neither escapes a `-` that was already in the
    /// path. `-Users-me-my-project` is therefore `/Users/me/my-project` and
    /// `/Users/me/my/project` at the same time, and expanding every `-`
    /// silently chose the second — for a hyphenated project name, which is
    /// most of them. That wrong path is not cosmetic: it is what Focus opens
    /// a terminal or an IDE on.
    ///
    /// The workspace the name was made from exists, so the filesystem can
    /// settle what the encoding threw away. Walk the pieces left to right and
    /// keep the first combination that exists as a directory, trying the
    /// plain piece before any `-`-joined merge so every name that already
    /// resolved correctly still resolves to exactly the same place.
    /// Backtrack when a prefix leads nowhere. When nothing matches — the
    /// workspace was deleted, the volume is not mounted — hand back the naive
    /// decode marked unverified: worth showing, never worth landing on.
    package static func resolveDashEncodedPath(_ segments: [String]) -> (path: String, verified: Bool) {
        let naive = "/" + segments.joined(separator: "/")
        guard !segments.isEmpty, segments.count <= maxDashPathSegments else {
            return (naive, false)
        }
        let key = segments.joined(separator: "-")
        if let cached = dashPathCache[key] { return cached }

        let fm = FileManager.default
        var probes = 0
        func isDirectory(_ path: String) -> Bool {
            probes += 1
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
        func resolve(prefix: String, from index: Int) -> String? {
            if index == segments.count { return prefix }
            var end = index + 1
            while end <= segments.count {
                if probes >= maxDashPathProbes { return nil }
                let candidate = prefix + "/" + segments[index..<end].joined(separator: "-")
                if isDirectory(candidate), let whole = resolve(prefix: candidate, from: end) {
                    return whole
                }
                end += 1
            }
            return nil
        }
        let result: (path: String, verified: Bool)
        if let resolved = resolve(prefix: "", from: 0) {
            result = (path: resolved, verified: true)
        } else {
            result = (path: naive, verified: false)
        }
        if dashPathCache.count < 512 { dashPathCache[key] = result }
        return result
    }

    /// Layout: `~/.claude/projects/<proj>/<sessionId>/subagents/agent-*.jsonl`
    /// Running ≈ mtime within 2 minutes.
    package static func claudeSubagentCounts(for sessionFile: URL) -> (running: Int, total: Int) {
        let subDir = sessionFile
            .deletingLastPathComponent()
            .appendingPathComponent(sessionFile.deletingPathExtension().lastPathComponent, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: subDir.path) else { return (0, 0) }
        guard let files = try? fm.contentsOfDirectory(
            at: subDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return (0, 0) }
        let now = Date().timeIntervalSince1970
        var running = 0
        var total = 0
        for file in files {
            let name = file.lastPathComponent.lowercased()
            guard name.hasPrefix("agent-"), name.hasSuffix(".jsonl") else { continue }
            total += 1
            let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?
                .timeIntervalSince1970 ?? 0
            if mtime > 0, now - mtime <= 120 { running += 1 }
        }
        return (running, total)
    }
}
