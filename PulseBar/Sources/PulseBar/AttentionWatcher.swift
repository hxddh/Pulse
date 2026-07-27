import Foundation

/// Near-realtime refresh when attention.tsv changes.
final class AttentionWatcher: @unchecked Sendable {
    private var source: DispatchSourceFileSystemObject?
    private var fileFD: CInt = -1
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
        source?.setEventHandler {}
        source?.cancel()
        source = nil
        if fileFD >= 0 {
            close(fileFD)
            fileFD = -1
        }
    }

    private func arm() {
        lock.lock()
        if fileFD >= 0 {
            close(fileFD)
            fileFD = -1
        }
        source?.setEventHandler {}
        source?.cancel()
        source = nil
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
            // fd owned by watcher.stop / re-arm — do not double-close here
        }
        lock.lock()
        fileFD = fd
        source = src
        lock.unlock()
        src.resume()
    }
}
