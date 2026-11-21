import Foundation

/// Detects concurrent file edits across live coding-agent sessions purely from
/// the tool-activity facts already held in `SessionBook`.
///
/// Zero subprocesses, zero network, zero disk reads: two active sessions
/// (`running`, `needsYou`, or an unseen `yourTurn`) that modified the same
/// resolved path in their current turn are flagged so the user can prevent
/// silent merge/overwrite clobbering across parallel agents.
package struct FileConflict: Equatable, Hashable, Sendable {
    /// Canonical absolute path of the overlapping file.
    package var path: String
    /// Short human-friendly label (typically the file's basename or trailing components).
    package var displayName: String
    /// Other active sessions that also modified `path` in their current turn.
    package var otherKeys: [SessionKey]

    package init(path: String, displayName: String, otherKeys: [SessionKey]) {
        self.path = path
        self.displayName = displayName
        self.otherKeys = otherKeys
    }
}

package enum SessionConflicts {
    /// Normalize a turn-digest file entry against its session's working
    /// directory. Returns `""` when the path cannot be anchored to an absolute
    /// path (Pulse never guesses whether two bare names refer to the same file).
    package static func normalizePath(_ rawFile: String, cwd: String) -> String {
        let file = rawFile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !file.isEmpty else { return "" }
        if file.hasPrefix("/") {
            return URL(fileURLWithPath: file).standardizedFileURL.path
        }
        let base = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard base.hasPrefix("/") else { return "" }
        return URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent(file)
            .standardizedFileURL
            .path
    }

    /// Detect files touched by at least two distinct active sessions in `book`
    /// at `nowMs`. Pure.
    package static func detect(in book: SessionBook, nowMs: Int64) -> [SessionKey: [FileConflict]] {
        var sessionsByPath: [String: Set<SessionKey>] = [:]
        for session in book.sessions.values {
            guard isActive(session, nowMs: nowMs) else { continue }
            var paths = Set<String>()
            for file in session.digest.files {
                let normalized = normalizePath(file, cwd: session.cwd)
                if !normalized.isEmpty { paths.insert(normalized) }
            }
            for file in session.changedFiles {
                let normalized = normalizePath(file, cwd: session.cwd)
                if !normalized.isEmpty { paths.insert(normalized) }
            }
            for path in paths {
                sessionsByPath[path, default: []].insert(session.key)
            }
        }

        var result: [SessionKey: [FileConflict]] = [:]
        for (path, keys) in sessionsByPath where keys.count >= 2 {
            let sortedKeys = keys.sorted()
            let name = shortName(for: path)
            for key in sortedKeys {
                let others = sortedKeys.filter { $0 != key }
                result[key, default: []].append(FileConflict(path: path, displayName: name, otherKeys: others))
            }
        }
        for key in result.keys {
            result[key]?.sort { ($0.displayName, $0.path) < ($1.displayName, $1.path) }
        }
        return result
    }

    /// Active sessions whose current turn edits are still relevant for conflict
    /// detection: running, blocked, or an unseen finished turn.
    private static func isActive(_ session: SessionBook.Session, nowMs: Int64) -> Bool {
        switch TrayState.status(of: session, nowMs: nowMs) {
        case .needsYou, .running, .yourTurn: return true
        case .recent, .processOnly: return false
        }
    }

    /// Short display label for a path (`Auth.swift`, or `Folder/index.ts` for generic names).
    package static func shortName(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let base = url.lastPathComponent
        let generic: Set<String> = ["index.ts", "index.tsx", "index.js", "main.swift", "mod.rs", "init.py", "__init__.py", "package.json"]
        if generic.contains(base.lowercased()) {
            let parent = url.deletingLastPathComponent().lastPathComponent
            if !parent.isEmpty, parent != "/" { return "\(parent)/\(base)" }
        }
        return base
    }

    /// Compact inline badge for a tray row (`Auth.swift` or `Auth.swift +2`).
    package static func badgeText(_ files: [String]) -> String? {
        guard let first = files.first, !first.isEmpty else { return nil }
        return files.count > 1 ? "\(first) +\(files.count - 1)" : first
    }

    /// Human-readable warning sentence for the session detail view.
    package static func detailWarning(_ files: [String], lang: ResolvedLanguage) -> String? {
        guard !files.isEmpty else { return nil }
        let shown = files.prefix(3).joined(separator: ", ")
        let list = files.count > 3 ? "\(shown) +\(files.count - 3)" : shown
        return String(format: L10n.t(.conflictDetailWarning, lang), list)
    }
}
