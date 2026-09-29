import Foundation

/// 22.0 · Lamp — one sweep of what the removed features left on disk.
///
/// 22.0 removed the orchestrator (managed sessions, Missions, working-copy
/// checks), remote Respond and fleet broadcast. Their state sat in Pulse's
/// Application Support directory and nothing reads it any more, so it is
/// deleted once, on the first launch of 22.x, and the debug log says what
/// went. A marker file makes the sweep run once.
///
/// What it never touches: `respond-local.key`, `respond.d/requests/` and
/// `respond.d/verdicts/` (local Respond), `attention.tsv` and its history,
/// `attention.d/`, `settings.txt`, and `worktrees/` — a worktree Pulse
/// created may hold the user's uncommitted work, so it is theirs to remove.
enum LegacyCleanup {
    static let markerName = ".cleanup-22.0"

    /// Directories relative to Pulse's own directory (`AttentionIO.path`'s
    /// parent — Application Support/Pulse, or `PULSE_HOME`).
    static let pulseRelative = [
        "evidence",   // EvidenceBook: per-working-copy checks and results
        "managed",    // managed session state, and its permissions/ spool
        "missions",   // Mission contracts and Candidates
        "fleet.d",    // fleet snapshots, this Mac's and synced ones
    ]

    /// Directories relative to `respond.d` — the remote Respond trees.
    static let respondRelative = [
        "requests.d", // requests synced from partner Macs
        "verdicts.d", // verdicts written for partner Macs
        "secrets",    // per-host shared keys
    ]

    /// Returns the paths it removed. Runs at most once per Pulse directory.
    @discardableResult
    static func run(
        pulseDirectory: URL = AttentionIO.path.deletingLastPathComponent(),
        respondRoot: URL = RespondSpool.root,
        fileManager fm: FileManager = .default
    ) -> [String] {
        let marker = pulseDirectory.appendingPathComponent(markerName)
        guard !fm.fileExists(atPath: marker.path) else { return [] }
        let targets = pulseRelative.map { pulseDirectory.appendingPathComponent($0, isDirectory: true) }
            + respondRelative.map { respondRoot.appendingPathComponent($0, isDirectory: true) }
        var removed: [String] = []
        for target in targets where fm.fileExists(atPath: target.path) {
            do {
                try fm.removeItem(at: target)
                removed.append(target.path)
            } catch {
                DebugLog.write("legacy cleanup failed \(target.lastPathComponent): \(error.localizedDescription)")
            }
        }
        try? fm.createDirectory(at: pulseDirectory, withIntermediateDirectories: true)
        _ = PrivateFile.write(Data("22.0\n".utf8), to: marker)
        let names = removed.map { ($0 as NSString).lastPathComponent }
        DebugLog.write("legacy cleanup 22.0 removed=\(names.isEmpty ? "-" : names.joined(separator: ","))")
        return removed
    }
}
