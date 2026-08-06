import Foundation

/// Tiny crash/relaunch marker. It records no session content; only whether
/// the previous Pulse process reached its clean shutdown hook, and the best
/// available classification of an unclean exit.
struct LaunchRecovery: Codable, Equatable {
    static let schema = 2

    enum ExitKind: String, Codable, Equatable {
        case clean
        case crash
        case forceQuit
        case systemRestart
        case updateReplace
        case unknown
    }

    var schemaVersion: Int = schema
    var runID: String
    var startedAtMs: Int64
    var cleanShutdown: Bool
    /// Intent recorded before exit when known (update replace). Unclean exits
    /// without an intent are classified at the next launch.
    var intendedExit: ExitKind = .unknown
    /// Boot-time cookie so a system restart can be distinguished from a crash.
    var bootID: String = ""

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pulse/launch-state.json")
    }

    static func currentBootID() -> String {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        let ok = sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0
        guard ok else { return "" }
        return "\(boot.tv_sec).\(boot.tv_usec)"
    }

    static func begin(
        nowMs: Int64,
        runID: String = UUID().uuidString,
        at url: URL = fileURL,
        bootID: String = currentBootID()
    ) -> (state: LaunchRecovery, wasUnclean: Bool, kind: ExitKind) {
        let previous = loadPrevious(at: url)
        let kind = classify(previous: previous, bootID: bootID)
        let wasUnclean = kind != .clean && kind != .updateReplace
        let state = LaunchRecovery(
            runID: runID,
            startedAtMs: nowMs,
            cleanShutdown: false,
            intendedExit: .unknown,
            bootID: bootID
        )
        state.save(to: url)
        return (state, wasUnclean, kind)
    }

    static func classify(previous: LaunchRecovery?, bootID: String) -> ExitKind {
        guard let previous else { return .clean }
        // Schema 1 only had cleanShutdown; treat as unknown unclean.
        if previous.schemaVersion < schema {
            return previous.cleanShutdown ? .clean : .unknown
        }
        // Intentional markers win over the cleanShutdown bit. updateReplace is
        // a quiet relaunch; forceQuit still surfaces a recovery notice.
        if previous.intendedExit == .updateReplace {
            return .updateReplace
        }
        if previous.intendedExit == .forceQuit {
            return .forceQuit
        }
        if previous.cleanShutdown {
            return .clean
        }
        if !previous.bootID.isEmpty, !bootID.isEmpty, previous.bootID != bootID {
            return .systemRestart
        }
        // Force-quit (SIGKILL) and crash both leave no marker on the same boot.
        // Without an intent bit we can only report crash.
        return .crash
    }

    private static func loadPrevious(at url: URL) -> LaunchRecovery? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let v2 = try? JSONDecoder().decode(LaunchRecovery.self, from: data),
           v2.schemaVersion == schema || v2.schemaVersion == 1 {
            return v2
        }
        return nil
    }

    mutating func markCleanShutdown(at url: URL = fileURL) {
        // Do not clobber an intentional exit marker written just before
        // terminate (update replace / SIGTERM force-quit path).
        if intendedExit == .updateReplace {
            cleanShutdown = true
            save(to: url)
            return
        }
        if intendedExit == .forceQuit {
            save(to: url)
            return
        }
        cleanShutdown = true
        intendedExit = .clean
        save(to: url)
    }

    mutating func markIntendedExit(_ kind: ExitKind, at url: URL = fileURL) {
        intendedExit = kind
        switch kind {
        case .updateReplace, .clean:
            cleanShutdown = true
        case .forceQuit:
            // Keep unclean so the next launch can show the force-quit notice.
            cleanShutdown = false
        case .crash, .systemRestart, .unknown:
            break
        }
        save(to: url)
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
