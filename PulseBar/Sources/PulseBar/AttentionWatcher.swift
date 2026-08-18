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
            PrivateFile.write(Data(AttentionIO.header.utf8), to: file)
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

    /// Whether each watch currently holds a live source. Two answers, not one:
    /// the defect being fixed was precisely that one of them could go dark
    /// while the other looked healthy.
    var isWatchingFile: Bool {
        lock.lock()
        defer { lock.unlock() }
        return source != nil
    }

    var isWatchingInbox: Bool {
        lock.lock()
        defer { lock.unlock() }
        return inboxSource != nil
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

    /// Arms the inbox directory only. Symmetric with `arm()` — neither may
    /// touch the other's source.
    func armInbox() {
        lock.lock()
        inboxSource?.setEventHandler {}
        inboxSource?.cancel()
        inboxSource = nil
        let watchPath = inboxPath
        lock.unlock()

        guard !watchPath.isEmpty else { return }
        // A directory that was moved or deleted cannot be reopened, and the
        // watch would stay dead for the life of the process. Recreating it is
        // what `start()` does, and the inbox is Pulse's own directory.
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: watchPath, isDirectory: &isDirectory)
            || !isDirectory.boolValue {
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: watchPath, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
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

    /// Arms the attention.tsv watch only.
    ///
    /// This used to call `teardownLocked()`, which cancels the inbox source as
    /// well. Deleting or atomically replacing attention.tsv — what every hook
    /// write does — therefore re-armed the file and silently killed the
    /// `attention.d/` watch until the next relaunch, so a remote raise fell
    /// back to the polling tick instead of waking the app (U-4). The inbox
    /// source belongs to `armInbox()`; only `stop()` tears both down.
    func arm() {
        lock.lock()
        source?.setEventHandler {}
        source?.cancel()
        source = nil
        let watchPath = path
        lock.unlock()

        guard !watchPath.isEmpty else { return }
        // Re-arming after a delete only works if something is there to open.
        // Without this the watcher died permanently the first time the file
        // was removed rather than replaced.
        let fileURL = URL(fileURLWithPath: watchPath)
        if !FileManager.default.fileExists(atPath: watchPath) {
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            PrivateFile.write(Data(AttentionIO.header.utf8), to: fileURL)
        }
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
