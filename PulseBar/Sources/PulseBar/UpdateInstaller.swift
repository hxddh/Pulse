import Foundation
import Darwin

/// Transactional app replacement used only after a DMG has passed HTTP,
/// content-type, size and SHA-256 checks. The old app is moved to a private
/// rollback directory before the new app is moved into place; it is never
/// deleted as part of an update.
struct UpdateInstaller {
    struct InstallTransaction: Codable, Equatable {
        var schema = 1
        var target: String
        var backup: String
        var version: String
        var phase: String
    }

    enum InstallError: LocalizedError {
        case invalidBundle(String)
        case targetUnavailable
        case replacementFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidBundle(let value): return "invalid update bundle: \(value)"
            case .targetUnavailable: return "Pulse installation target is unavailable"
            case .replacementFailed(let value): return "update replacement failed: \(value)"
            }
        }
    }

    static var rollbackRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pulse/rollback")
    }

    /// Install-time preflight. It verifies the disk image can be mounted, the
    /// contained app is Pulse, the executable contains arm64 code, and the
    /// current installation directory is writable before any replacement is
    /// attempted.
    static func preflight(dmgURL: URL, targetApp: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dmgURL.path),
              (try? dmgURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else { throw InstallError.targetUnavailable }
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 14 else {
            throw InstallError.invalidBundle("macOS 14 or newer required")
        }
        #if !arch(arm64)
        throw InstallError.invalidBundle("Apple silicon required")
        #endif
        let mount = try mountDMG(dmgURL)
        defer { _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"]) }
        guard let app = try fmEnumerateApps(at: mount).first(where: { (try? validate(app: $0)) != nil }) else {
            throw InstallError.invalidBundle("Pulse.app not found")
        }
        let validated = try validate(app: app)
        let arch = run("/usr/bin/lipo", ["-info", validated.executable.path])
        guard arch.status == 0, arch.output.localizedCaseInsensitiveContains("arm64") else {
            throw InstallError.invalidBundle("arm64 executable missing")
        }
        guard fm.isWritableFile(atPath: targetApp.deletingLastPathComponent().path) else {
            throw InstallError.targetUnavailable
        }
    }

    static func replace(
        stagedApp: URL,
        targetApp: URL,
        backupRoot: URL = rollbackRoot
    ) throws {
        let fm = FileManager.default
        let info = try validate(app: stagedApp)
        guard fm.fileExists(atPath: targetApp.deletingLastPathComponent().path) else {
            throw InstallError.targetUnavailable
        }
        try fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let backup = backupRoot.appendingPathComponent("Pulse-\(id).app")
        let stateURL = backupRoot.appendingPathComponent("current.json")
        var state = InstallTransaction(
            target: targetApp.path,
            backup: backup.path,
            version: info.version,
            phase: "prepared"
        )
        try write(state, to: stateURL)

        do {
            if fm.fileExists(atPath: targetApp.path) {
                state.phase = "backedUp"
                try fm.moveItem(at: targetApp, to: backup)
                try write(state, to: stateURL)
            }
            state.phase = "replacing"
            try fm.moveItem(at: stagedApp, to: targetApp)
            state.phase = "committed"
            try write(state, to: stateURL)
        } catch {
            state.phase = "rollingBack"
            try? write(state, to: stateURL)
            if fm.fileExists(atPath: targetApp.path) { try? fm.removeItem(at: targetApp) }
            if fm.fileExists(atPath: backup.path) { try? fm.moveItem(at: backup, to: targetApp) }
            state.phase = "rolledBack"
            try? write(state, to: stateURL)
            throw InstallError.replacementFailed(error.localizedDescription)
        }
    }

    @discardableResult
    static func recoverIfNeeded(at targetApp: URL, backupRoot: URL = rollbackRoot) -> Bool {
        let stateURL = backupRoot.appendingPathComponent("current.json")
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(InstallTransaction.self, from: data),
              state.target == targetApp.path,
              state.phase != "committed"
        else { return false }
        let fm = FileManager.default
        let backup = URL(fileURLWithPath: state.backup)
        if fm.fileExists(atPath: targetApp.path), (try? validate(app: targetApp)) != nil {
            return false
        }
        guard fm.fileExists(atPath: backup.path) else { return false }
        do {
            if fm.fileExists(atPath: targetApp.path) { try fm.removeItem(at: targetApp) }
            try fm.moveItem(at: backup, to: targetApp)
            var recovered = state
            recovered.phase = "recovered"
            try write(recovered, to: stateURL)
            return true
        } catch {
            DebugLog.write("update recovery failed \(error.localizedDescription)")
            return false
        }
    }

    static func runHelper(dmgURL: URL, targetApp: URL, parentPID: pid_t) throws {
        while kill(parentPID, 0) == 0 { usleep(100_000) }
        let mount = try mountDMG(dmgURL)
        defer { _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"]) }
        let candidates = try fmEnumerateApps(at: mount)
        guard let source = candidates.first(where: { (try? validate(app: $0)) != nil }) else {
            throw InstallError.invalidBundle("Pulse.app not found on disk image")
        }
        let stagingRoot = rollbackRoot.appendingPathComponent("staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let staged = stagingRoot.appendingPathComponent("Pulse.app")
        try FileManager.default.copyItem(at: source, to: staged)
        try replace(stagedApp: staged, targetApp: targetApp)
        _ = run(targetApp.appendingPathComponent("Contents/MacOS/PulseBar").path, [])
    }

    private static func validate(app: URL) throws -> (version: String, executable: URL) {
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL) as? [String: Any] else {
            throw InstallError.invalidBundle("Info.plist")
        }
        guard info["CFBundleIdentifier"] as? String == "com.pulse.app" else {
            throw InstallError.invalidBundle("bundle identifier")
        }
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        guard !version.isEmpty else { throw InstallError.invalidBundle("version") }
        let executableName = info["CFBundleExecutable"] as? String ?? "PulseBar"
        let executable = app.appendingPathComponent("Contents/MacOS/\(executableName)")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw InstallError.invalidBundle("executable")
        }
        return (version, executable)
    }

    private static func write(_ value: InstallTransaction, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        let temp = url.appendingPathExtension("tmp")
        try data.write(to: temp, options: .atomic)
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: temp) }
        else { try fm.moveItem(at: temp, to: url) }
    }

    private static func mountDMG(_ dmg: URL) throws -> URL {
        let result = run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", dmg.path])
        guard result.status == 0 else { throw InstallError.replacementFailed("hdiutil attach") }
        guard let path = mountPoint(fromAttachOutput: result.output) else {
            throw InstallError.replacementFailed("mount point")
        }
        return URL(fileURLWithPath: path)
    }

    /// `hdiutil attach` prints `/dev/diskNsM<TAB>hint<TAB>/Volumes/Name` — the
    /// mount point is a tab-separated column, never the start of the line.
    /// The old whole-line `hasPrefix("/Volumes/")` matched nothing, ever, so
    /// every in-app download ended at "mount point". Volume names keep their
    /// spaces ("Pulse 1.2.0"), so split on tabs, then fall back to the last
    /// `/Volumes/` substring for any hdiutil that pads with spaces instead.
    static func mountPoint(fromAttachOutput output: String) -> String? {
        var candidates: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let columns = line.split(separator: "\t")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if let column = columns.last(where: { $0.hasPrefix("/Volumes/") }) {
                candidates.append(column)
            } else if let range = line.range(of: "/Volumes/") {
                let tail = line[range.lowerBound...].trimmingCharacters(in: .whitespaces)
                if !tail.isEmpty { candidates.append(tail) }
            }
        }
        return candidates.last
    }

    private static func fmEnumerateApps(at root: URL) throws -> [URL] {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        return names.filter { $0.pathExtension == "app" } + names.flatMap { url in
            (try? fmEnumerateApps(at: url)) ?? []
        }
    }

    private static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do { try task.run() } catch { return (-1, error.localizedDescription) }
        task.waitUntilExit()
        return (task.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }
}
