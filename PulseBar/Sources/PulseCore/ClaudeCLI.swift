import Foundation

/// Where the user's `claude` command lives. One resolver for everything that
/// runs it: the agents probe (18.0) and the self-check.
public enum ClaudeCLI {
    public static func executable(
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            home + "/.local/bin/claude",
            home + "/.claude/local/claude",
        ]
        return candidates.first(where: fileExists)
    }
}
