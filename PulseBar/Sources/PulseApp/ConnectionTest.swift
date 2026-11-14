import Foundation

/// Settings' "Test connection": run the installed launcher once with
/// `--ping`, on the person's click, and read whether a Pulse answered
/// (`HookPing`). A click's action like a landing — never an observation.
enum ConnectionTest {
    /// Blocking: call it off the main thread. `since` is the click, less
    /// a second of slack.
    static func run(launcher: String, since: Int64) -> HookPing.Result {
        guard FileManager.default.isExecutableFile(atPath: launcher) else { return .noLauncher }
        _ = ProcessIO.run(executable: launcher, arguments: [HookPing.argument], timeout: 10)
        guard let answered = HookPing.answeredMs(), answered >= since else { return .noAnswer }
        return .ok(atMs: answered)
    }
}
