import CryptoKit
import Darwin
import Foundation

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

    /// The in-place install helper.
    ///
    /// F-4 (review-11.0), closed in 12.3. The SHA-256 the download was checked
    /// against comes from the same release body as the DMG, so on its own it
    /// only proves the bytes were not damaged in transit. Before anything is
    /// replaced the helper now also requires:
    ///
    /// 1. the DMG on disk still has that digest — it sat in Downloads between
    ///    the check and the click, and is re-hashed right before mounting;
    /// 2. the app inside passes `codesign --verify --deep --strict`;
    /// 3. it is signed by the **same Team ID** as the app being replaced, and
    ///    that Team ID exists. An ad-hoc build has none, so it can never
    ///    replace itself in place — which is also why this path stays behind
    ///    `isGatekeeperReady`;
    /// 4. the staged copy still verifies after it was copied off the image.
    ///
    /// Any failure leaves the installed app untouched; the user still has the
    /// DMG and the vendor-neutral manual install.
    static func runHelper(dmgURL: URL, targetApp: URL, parentPID: pid_t, expectedSHA256: String) throws {
        while kill(parentPID, 0) == 0 { usleep(100_000) }
        try verifyDigest(of: dmgURL, expected: expectedSHA256)
        let mount = try mountDMG(dmgURL)
        defer { _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"]) }
        let candidates = try fmEnumerateApps(at: mount)
        guard let source = candidates.first(where: { (try? validate(app: $0)) != nil }) else {
            throw InstallError.invalidBundle("Pulse.app not found on disk image")
        }
        try verifySignature(candidate: source, replacing: targetApp)
        let stagingRoot = rollbackRoot.appendingPathComponent("staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let staged = stagingRoot.appendingPathComponent("Pulse.app")
        try FileManager.default.copyItem(at: source, to: staged)
        try verifySignature(candidate: staged, replacing: targetApp)
        try replace(stagedApp: staged, targetApp: targetApp)
        _ = run(targetApp.appendingPathComponent("Contents/MacOS/PulseBar").path, [])
    }

    /// Re-hash the image right before it is mounted. An empty or malformed
    /// expectation is a refusal, never a skip.
    static func verifyDigest(of dmg: URL, expected: String) throws {
        let want = expected.lowercased()
        guard want.count == 64, want.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) else {
            throw InstallError.invalidBundle("missing expected SHA-256")
        }
        guard let data = try? Data(contentsOf: dmg, options: .mappedIfSafe) else {
            throw InstallError.targetUnavailable
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == want else {
            throw InstallError.invalidBundle("disk image changed since it was verified")
        }
    }

    /// Strict signature on the candidate, and the same non-empty Team ID as
    /// the app it would replace.
    static func verifySignature(candidate: URL, replacing current: URL) throws {
        let strict = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", candidate.path])
        guard strict.status == 0 else {
            throw InstallError.invalidBundle("code signature does not verify")
        }
        let candidateTeam = teamIdentifier(
            fromCodesignOutput: run("/usr/bin/codesign", ["-dv", "--verbose=2", candidate.path]).output
        )
        let currentTeam = teamIdentifier(
            fromCodesignOutput: run("/usr/bin/codesign", ["-dv", "--verbose=2", current.path]).output
        )
        try requireSameTeam(candidate: candidateTeam, current: currentTeam)
    }

    /// The rule on its own, so it can be held to a test without a signed app.
    static func requireSameTeam(candidate: String?, current: String?) throws {
        guard let current, !current.isEmpty else {
            throw InstallError.invalidBundle("installed app has no Team ID; install the DMG manually")
        }
        guard let candidate, candidate == current else {
            throw InstallError.invalidBundle("update is signed by a different team")
        }
    }

    /// `TeamIdentifier=ABCDE12345` from `codesign -dv` output. `not set` (an
    /// ad-hoc signature) and anything that is not a Team ID shape are nil.
    static func teamIdentifier(fromCodesignOutput output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("TeamIdentifier=") else { continue }
            let value = String(text.dropFirst("TeamIdentifier=".count))
                .trimmingCharacters(in: .whitespaces)
            guard value.count == 10,
                  value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII })
            else { return nil }
            return value
        }
        return nil
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
