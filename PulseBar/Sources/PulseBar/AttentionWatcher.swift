import Foundation

/// Near-realtime refresh when attention.tsv changes.
final class AttentionWatcher: @unchecked Sendable {
    private var source: DispatchSourceFileSystemObject?
    private var onChange: (() -> Void)?
    private var lastFire: TimeInterval = 0
    private var path: String = ""
    private let lock = NSLock()

    func start(onChange: @escaping () -> Void) {
        stop()
        lock.lock()
        self.onChange = onChange
        lock.unlock()
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pulse")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("attention.tsv")
        if !FileManager.default.fileExists(atPath: file.path) {
            try? "# Pulse attention log\n".write(to: file, atomically: true, encoding: .utf8)
        }
        path = file.path
        arm()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        teardownLocked()
    }

    /// The fd is owned by the source's cancel handler — closing it here would
    /// race cancellation and could close a descriptor GCD still holds.
    private func teardownLocked() {
        source?.setEventHandler {}
        source?.cancel()
        source = nil
    }

    private func arm() {
        lock.lock()
        teardownLocked()
        let watchPath = path
        lock.unlock()

        guard !watchPath.isEmpty else { return }
        let fd = open(watchPath, O_EVTONLY)
        guard fd >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date().timeIntervalSince1970
            self.lock.lock()
            let due = now - self.lastFire > 0.35
            if due { self.lastFire = now }
            let cb = self.onChange
            let flags = src.data
            self.lock.unlock()
            if due { cb?() }
            if flags.contains(.delete) || flags.contains(.rename) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.arm()
                }
            }
        }
        src.setCancelHandler {
            close(fd)
        }
        lock.lock()
        source = src
        lock.unlock()
        src.resume()
    }
}
