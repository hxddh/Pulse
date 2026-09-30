import Darwin
import Foundation

/// Cross-path ownership for Pulse.
///
/// Launch Services normally coalesces the same app bundle, but it cannot
/// coalesce `/Applications/Pulse.app` and a packaged development copy. A
/// process-scoped BSD lock gives every copy one shared owner without a daemon,
/// polling, Apple Events, or a permission prompt.
final class SingleInstanceGuard {
    private var descriptor: Int32 = -1
    private let lockURL: URL

    init(lockURL: URL = SingleInstanceGuard.defaultLockURL) {
        self.lockURL = lockURL
    }

    deinit {
        if descriptor >= 0 {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }

    func acquire() -> Bool {
        guard descriptor < 0 else { return true }
        let directory = lockURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            DebugLog.write("single-instance directory failed: \(error.localizedDescription)")
            return false
        }

        let fd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            DebugLog.write("single-instance open failed errno=\(errno)")
            return false
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        descriptor = fd

        // Diagnostic only. The kernel lock, not this text, owns exclusivity.
        let pid = "\(ProcessInfo.processInfo.processIdentifier)\n"
        _ = ftruncate(fd, 0)
        _ = pid.withCString { pointer in
            write(fd, pointer, strlen(pointer))
        }
        return true
    }

    static var defaultLockURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pulse", isDirectory: true)
            .appendingPathComponent("Pulse.instance.lock")
    }

    @MainActor
    static func activateExistingCopy() {
        // The caller already knows another copy owns the lock. Do not inspect
        // or activate another application: NSRunningApplication can trigger a
        // macOS cross-app privacy prompt. The existing owner remains the only
        // visible Pulse instance, which is the safe fallback.
    }
}
