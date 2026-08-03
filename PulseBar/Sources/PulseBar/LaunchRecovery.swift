import Foundation

/// Tiny crash/relaunch marker. It records no session content; only whether
/// the previous Pulse process reached its clean shutdown hook.
struct LaunchRecovery: Codable, Equatable {
    static let schema = 1
    var schemaVersion: Int = schema
    var runID: String
    var startedAtMs: Int64
    var cleanShutdown: Bool

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pulse/launch-state.json")
    }

    static func begin(nowMs: Int64, runID: String = UUID().uuidString, at url: URL = fileURL) -> (state: LaunchRecovery, wasUnclean: Bool) {
        let previous = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(LaunchRecovery.self, from: $0) }
        let wasUnclean = previous?.schemaVersion == schema && previous?.cleanShutdown == false
        let state = LaunchRecovery(runID: runID, startedAtMs: nowMs, cleanShutdown: false)
        state.save(to: url)
        return (state, wasUnclean)
    }

    func markCleanShutdown(at url: URL = fileURL) {
        var clean = self
        clean.cleanShutdown = true
        clean.save(to: url)
    }

    private func save(to url: URL) {
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(self)
            let temp = url.appendingPathExtension("tmp")
            try data.write(to: temp, options: .atomic)
            if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: temp) }
            else { try fm.moveItem(at: temp, to: url) }
        } catch {
            DebugLog.write("launch state save failed \(error.localizedDescription)")
        }
    }
}
