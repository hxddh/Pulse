import Foundation

/// Near-realtime refresh when the event log (`events.tsv`) changes — the
/// one file every hook writes, and the one watch.
final class AttentionWatcher: @unchecked Sendable {
    private var source: DispatchSourceFileSystemObject?
    private var onChange: (() -> Void)?
    /// A trailing fire is armed when an event lands inside the window.
    /// Without it, the second of two events a moment apart was consumed
    /// silently until the next tick — a leading-edge throttle alone drops
    /// exactly the freshest state a watch exists to deliver.
    private var throttle = CoalescingThrottle(window: 0.35)
    private var path: String = ""
    private let lock = NSLock()

    /// Watch `url` (the real log when nil).
    func start(url: URL? = nil, onChange: @escaping () -> Void) {
        stop()
        lock.lock()
        self.onChange = onChange
        lock.unlock()
        let file = url ?? EventLog.path
        EventLog.ensureExists(at: file, nowMs: Int64(Date().timeIntervalSince1970 * 1000))
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

    /// Arm (or re-arm) the watch on the log.
    func arm() {
        lock.lock()
        teardownLocked()
        let watchPath = path
        lock.unlock()

        guard !watchPath.isEmpty else { return }
        // Re-arming after a delete only works if something is there to open.
        // Without this the watcher died permanently the first time the file
        // was removed rather than replaced.
        if !FileManager.default.fileExists(atPath: watchPath) {
            EventLog.ensureExists(at: URL(fileURLWithPath: watchPath), nowMs: Int64(Date().timeIntervalSince1970 * 1000))
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
            let flags = src.data
            self.deliver()
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

    /// Leading edge now, one trailing edge for whatever the window absorbed.
    /// Runs on the main queue (the source's handler queue).
    private func deliver() {
        let now = Date().timeIntervalSince1970
        lock.lock()
        let decision = throttle.event(at: now)
        let delay = throttle.trailingDelay(at: now)
        let callback = onChange
        lock.unlock()
        switch decision {
        case .fire:
            callback?()
        case .absorbed:
            break
        case .armTrailing:
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.throttle.trailingFired(at: Date().timeIntervalSince1970)
                let trailing = self.onChange
                self.lock.unlock()
                trailing?()
            }
        }
    }
}

/// A leading-edge throttle that never drops the last event: the first event
/// fires at once, the next one inside the window arms a single trailing fire
/// at the window's end, and any more before then ride on that one.
struct CoalescingThrottle: Equatable, Sendable {
    enum Decision: Equatable, Sendable { case fire, armTrailing, absorbed }

    let window: TimeInterval
    private(set) var lastFire: TimeInterval = 0
    private(set) var trailingArmed = false

    init(window: TimeInterval) {
        self.window = window
    }

    mutating func event(at now: TimeInterval) -> Decision {
        if !trailingArmed, now - lastFire > window {
            lastFire = now
            return .fire
        }
        if trailingArmed { return .absorbed }
        trailingArmed = true
        return .armTrailing
    }

    mutating func trailingFired(at now: TimeInterval) {
        trailingArmed = false
        lastFire = now
    }

    /// When the armed trailing fire should run: just past the window's end.
    func trailingDelay(at now: TimeInterval) -> TimeInterval {
        max(0, lastFire + window - now) + 0.05
    }
}
