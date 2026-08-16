import Foundation

/// Near-realtime refresh when attention.tsv changes.
final class AttentionWatcher: @unchecked Sendable {
    private var source: DispatchSourceFileSystemObject?
    /// 1.0: the inbox is a directory, and a host appears by a file appearing.
    ///
    /// A directory source fires on add / remove / rename — which is what every
    /// file-moving tool does. An in-place append to an existing inbox file does
    /// not fire it; that arrives on the next scan tick instead of instantly.
    private var inboxSource: DispatchSourceFileSystemObject?
    private var onChange: (() -> Void)?
    private var lastFire: TimeInterval = 0
    private var path: String = ""
    private var inboxPath: String = ""
    private let lock = NSLock()

    func start(onChange: @escaping () -> Void) {
        stop()
        lock.lock()
        self.onChange = onChange
        lock.unlock()
        let file = AttentionIO.path
        let dir = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) {
            try? AttentionIO.header.write(to: file, atomically: true, encoding: .utf8)
        }
        let inbox = AttentionIO.inboxDirectory
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        path = file.path
        inboxPath = inbox.path
        arm()
        armInbox()
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
        inboxSource?.setEventHandler {}
        inboxSource?.cancel()
        inboxSource = nil
    }

    private func armInbox() {
        lock.lock()
        inboxSource?.setEventHandler {}
        inboxSource?.cancel()
        inboxSource = nil
        let watchPath = inboxPath
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
                    self?.armInbox()
                }
            }
        }
        src.setCancelHandler { close(fd) }
        lock.lock()
        inboxSource = src
        lock.unlock()
        src.resume()
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
