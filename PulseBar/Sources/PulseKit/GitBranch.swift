import Foundation

/// Reads the current Git branch for a session's working directory directly
/// from `.git/HEAD` — supporting both standard repositories and linked
/// `git worktree` checkouts (where `.git` is a `gitdir:` pointer file).
///
/// Zero subprocesses, zero network, bounded reads (512 bytes) and walk depth
/// (8 parent folders). Detached HEADs return "" rather than a raw commit hash
/// so rows stay quiet unless there is a real branch name. Pure IO helper.
package enum GitBranch {
    package static let maxDepth = 8
    package static let readLimit = 512
    package static let maxBranchLength = 60

    /// Resolve the branch name for `cwd`, or "" when not in a Git worktree or
    /// on a detached HEAD.
    package static func resolve(cwd: String) -> String {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return "" }
        let fm = FileManager.default
        var current = URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
        for _ in 0..<maxDepth {
            let dotGit = current.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                let headURL: URL
                if isDir.boolValue {
                    headURL = dotGit.appendingPathComponent("HEAD")
                } else if let pointer = readSmallText(dotGit.path),
                          let gitDir = parseGitDir(pointer, relativeTo: current) {
                    headURL = gitDir.appendingPathComponent("HEAD")
                } else {
                    return ""
                }
                guard let head = readSmallText(headURL.path) else { return "" }
                return parseHead(head)
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return ""
    }

    /// Resolve the enclosing Git repository or linked worktree root folder for
    /// `cwd` (walks up at most `maxDepth` parents for `.git`), or return `cwd`
    /// unchanged when not inside a Git checkout. Zero subprocesses.
    package static func worktreeRoot(cwd: String) -> String {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return cwd }
        let fm = FileManager.default
        var current = URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
        for _ in 0..<maxDepth {
            let dotGit = current.appendingPathComponent(".git")
            if fm.fileExists(atPath: dotGit.path) {
                return current.path
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return trimmed
    }

    /// Parse a `.git` file's `gitdir: <path>` line (used by `git worktree` and
    /// submodules), resolving relative paths against the folder containing `.git`.
    package static func parseGitDir(_ content: String, relativeTo baseDir: URL) -> URL? {
        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.lowercased().hasPrefix("gitdir:") else { continue }
            let rawPath = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawPath.isEmpty else { return nil }
            if rawPath.hasPrefix("/") {
                return URL(fileURLWithPath: rawPath, isDirectory: true).standardizedFileURL
            }
            return baseDir.appendingPathComponent(rawPath, isDirectory: true).standardizedFileURL
        }
        return nil
    }

    /// Parse `.git/HEAD` contents (`ref: refs/heads/<branch>`) into a clean,
    /// bounded branch name; returns "" for detached HEADs or unrecognized text.
    package static func parseHead(_ content: String) -> String {
        guard let firstLine = content.split(whereSeparator: \.isNewline).first else { return "" }
        let line = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        guard line.hasPrefix(prefix) else { return "" }
        let raw = String(line.dropFirst(prefix.count))
        let clean = LineMeta.clean(ContentSanitizer.redact(raw), limit: maxBranchLength)
        return clean
    }

    private static func readSmallText(_ path: String) -> String? {
        guard let data = SafeRead.regularFile(atPath: path, limit: readLimit) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
