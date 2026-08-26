import Foundation

/// 5.0-β — the workspace a managed session runs in (scene BG).
///
/// Isolation is what makes dispatch safe to use: the agent works on a branch
/// in its own checkout, and the user's own working copy never moves under
/// their hands. Worktrees live in Pulse's Application Support namespace, not
/// inside the repository, and every destructive verb here refuses paths
/// outside that namespace — Pulse deletes only what Pulse created.
enum ManagedWorktree {

    static let branchPrefix = "pulse/"

    /// `~/Library/Application Support/Pulse/worktrees` — overridable so
    /// tests never touch the real one.
    static var baseOverride: URL?
    static func baseDirectory() -> URL {
        if let baseOverride { return baseOverride }
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Pulse/worktrees", isDirectory: true)
    }

    /// A short, filesystem- and branch-safe name from the task's first
    /// words, made unique by the dispatch time. Pure for tests.
    static func slug(task: String, nowMs: Int64) -> String {
        let words = task.lowercased()
            .map { ch -> Character in
                (ch.isLetter && ch.isASCII) || ch.isNumber ? ch : " "
            }
        let compact = String(words)
            .split(separator: " ")
            .prefix(4)
            .joined(separator: "-")
        let stem = compact.isEmpty ? "task" : String(compact.prefix(32))
        return "\(stem)-\(nowMs / 1000 % 1_000_000)"
    }

    /// Only paths inside the namespace are Pulse's to touch.
    static func isPulseWorktree(_ path: String) -> Bool {
        let base = baseDirectory().standardizedFileURL.path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        return candidate.hasPrefix(base + "/") && candidate.count > base.count + 1
    }

    enum CreateError: Error, Equatable {
        case notARepository
        case gitFailed(String)
    }

    /// `git -C <repoRoot> worktree add <dir> -b pulse/<slug>` — the one
    /// write verb dispatch needs, run against the repository the user chose,
    /// creating a directory only inside Pulse's namespace.
    static func create(repoRoot: String, slug: String) -> Result<String, CreateError> {
        guard WorkspaceEffect.repositoryRoot(of: repoRoot) != nil else {
            return .failure(.notARepository)
        }
        let repoLeaf = URL(fileURLWithPath: repoRoot).lastPathComponent
        let dir = baseDirectory()
            .appendingPathComponent(repoLeaf, isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let result = ProcessIO.run(
            executable: WorkspaceEffect.executable,
            arguments: [
                "-C", repoRoot,
                "worktree", "add", dir.path,
                "-b", branchPrefix + slug,
            ],
            timeout: 30
        ) else { return .failure(.gitFailed("git did not run")) }
        guard !result.timedOut, result.status == 0 else {
            let stderr = String(decoding: result.stderr.prefix(300), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.gitFailed(stderr.isEmpty ? "exit \(result.status)" : stderr))
        }
        return .success(dir.path)
    }
}
