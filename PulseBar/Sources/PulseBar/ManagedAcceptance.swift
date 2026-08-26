import AppKit

/// 5.0-γ — acceptance verbs on managed worktrees (scene BH).
///
/// The principle, re-scoped the way 3.0-β re-scoped "counts only": **"Pulse
/// never touches the repository" is the law for observed sessions' repos.**
/// A managed worktree is a workspace Pulse created in its own namespace, on
/// its own branch — and every verb here runs on the user's explicit click,
/// with the diff one card above it. The user is the actor; Pulse is the
/// hands. The user's own checkout remains untouchable: every verb refuses a
/// path outside the worktree namespace before git ever runs.
enum ManagedAcceptance {

    enum VerbError: Error, Equatable {
        case outsideNamespace
        case gitFailed(String)
    }

    /// Commit everything the session changed, with the user's message.
    /// An empty message refuses — a commit's words are the user's judgment.
    static func commit(worktree: String, message: String) -> VerbError? {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .gitFailed("empty message") }
        guard ManagedWorktree.isPulseWorktree(worktree) else { return .outsideNamespace }
        if case .failure(let error) = run(worktree, ["add", "-A"]) { return error }
        if case .failure(let error) = run(worktree, ["commit", "-m", text]) { return error }
        return nil
    }

    /// Publish the session's branch. Uses the user's own git auth — a
    /// failure (no remote, no credentials) comes back verbatim.
    static func push(worktree: String, branch: String) -> VerbError? {
        guard ManagedWorktree.isPulseWorktree(worktree) else { return .outsideNamespace }
        guard branch.hasPrefix(ManagedWorktree.branchPrefix) else {
            return .gitFailed("not a pulse branch")
        }
        if case .failure(let error) = run(worktree, ["push", "-u", "origin", branch]) { return error }
        return nil
    }

    /// The current branch of a worktree, so the verbs never guess.
    static func branch(worktree: String) -> String? {
        guard case .success(let out) = run(worktree, ["rev-parse", "--abbrev-ref", "HEAD"]) else {
            return nil
        }
        let name = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// GitHub compare URL for the pushed branch, when origin is GitHub.
    /// Pure, so tests pin every remote shape; nil for non-GitHub remotes —
    /// no button is honest, a guessed URL is not.
    static func compareURL(originURL: String, branch: String) -> URL? {
        var raw = originURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if raw.hasSuffix(".git") { raw = String(raw.dropLast(4)) }
        var path: String?
        if raw.hasPrefix("git@github.com:") {
            path = String(raw.dropFirst("git@github.com:".count))
        } else if raw.hasPrefix("ssh://git@github.com/") {
            path = String(raw.dropFirst("ssh://git@github.com/".count))
        } else if raw.hasPrefix("https://github.com/") {
            path = String(raw.dropFirst("https://github.com/".count))
        }
        // The branch's own slash must encode (pulse%2Fslug): unencoded it
        // reads as base...head compare segments and lands on a 404.
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        guard let path, path.split(separator: "/").count == 2,
              let encoded = branch.addingPercentEncoding(withAllowedCharacters: allowed)
        else { return nil }
        return URL(string: "https://github.com/\(path)/compare/\(encoded)?expand=1")
    }

    static func originURL(worktree: String) -> String? {
        guard case .success(let out) = run(worktree, ["remote", "get-url", "origin"]) else {
            return nil
        }
        let url = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : url
    }

    // MARK: - The one git runner acceptance uses

    private static func run(_ worktree: String, _ arguments: [String]) -> Result<String, VerbError> {
        guard let result = ProcessIO.run(
            executable: WorkspaceEffect.executable,
            arguments: ["-C", worktree] + arguments,
            timeout: 60
        ) else { return .failure(.gitFailed("git did not run")) }
        guard !result.timedOut, result.status == 0 else {
            let stderr = String(decoding: result.stderr.suffix(300), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.gitFailed(stderr.isEmpty ? "exit \(result.status)" : stderr))
        }
        return .success(String(decoding: result.stdout, as: UTF8.self))
    }
}
