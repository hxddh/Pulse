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
        if previous.cleanShutdown {
            return previous.intendedExit == .updateReplace ? .updateReplace : .clean
        }
        if previous.intendedExit == .updateReplace {
            return .updateReplace
        }
        if !previous.bootID.isEmpty, !bootID.isEmpty, previous.bootID != bootID {
            return .systemRestart
        }
        // Force-quit and crash both leave cleanShutdown=false with the same
        // boot. Prefer crash as the actionable recovery label; force-quit is
        // reserved when an intentional marker was written (future hook).
        if previous.intendedExit == .forceQuit {
            return .forceQuit
        }
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

    func markCleanShutdown(at url: URL = fileURL) {
        var clean = self
        clean.cleanShutdown = true
        clean.intendedExit = .clean
        clean.save(to: url)
    }

    func markIntendedExit(_ kind: ExitKind, at url: URL = fileURL) {
        var next = self
        next.intendedExit = kind
        if kind == .updateReplace || kind == .forceQuit || kind == .clean {
            next.cleanShutdown = true
        }
        next.save(to: url)
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
