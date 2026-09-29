import Foundation

/// Near-realtime refresh when attention.tsv changes.
final class AttentionWatcher: @unchecked Sendable {
    private var source: DispatchSourceFileSystemObject?
    /// 2.9: the activity spool gets its own source and its own callback —
    /// an event per vendor tool call must wake the cheap spool read, never
    /// the full refresh the attention sources are wired to.
    private var activitySource: DispatchSourceFileSystemObject?
    private var onChange: (() -> Void)?
    private var onActivity: (() -> Void)?
    /// One throttle per source. A trailing fire is armed when an event lands
    /// inside the window. Without it, the second of two tool events one
    /// second apart was consumed silently and the row kept showing the
    /// previous tool until the next probe tick (Codex review on #78) — a
    /// leading-edge throttle alone drops exactly the freshest state a source
    /// exists to deliver. The attention file had only the leading edge: a
    /// `done` landing 0.2 s after a raise was swallowed until the next tick.
    private var throttles: [Channel: CoalescingThrottle] = [
        .file: CoalescingThrottle(window: 0.35),
        .activity: CoalescingThrottle(window: 1.0),
    ]
    private var path: String = ""
    private var activityPath: String = ""
    private let lock = NSLock()

    func start(onChange: @escaping () -> Void, onActivity: (() -> Void)? = nil) {
        stop()
        lock.lock()
        self.onChange = onChange
        self.onActivity = onActivity
        lock.unlock()
        let file = AttentionIO.path
        let dir = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) {
            PrivateFile.write(Data(AttentionIO.header.utf8), to: file)
        }
        path = file.path
        arm()
        if onActivity != nil {
            let activity = ActivitySpool.directory
            try? FileManager.default.createDirectory(at: activity, withIntermediateDirectories: true)
            activityPath = activity.path
            armActivity()
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        teardownLocked()
    }

    /// Whether each watch currently holds a live source — one answer per
    /// watch, so one going dark cannot hide behind another looking healthy.
    var isWatchingFile: Bool {
        lock.lock()
        defer { lock.unlock() }
        return source != nil
    }

    /// The fd is owned by the source's cancel handler — closing it here would
    /// race cancellation and could close a descriptor GCD still holds.
    private func teardownLocked() {
        source?.setEventHandler {}
        source?.cancel()
        source = nil
        activitySource?.setEventHandler {}
        activitySource?.cancel()
        activitySource = nil
    }

    var isWatchingActivity: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activitySource != nil
    }

    /// Arms the activity spool directory only. The throttle is deliberately
    /// looser than the attention sources' (1s vs 0.35s): tool calls arrive
    /// seconds apart and the payoff per wake is one bounded directory read,
    /// so coalescing costs nothing a person could notice.
    func armActivity() {
        lock.lock()
        activitySource?.setEventHandler {}
        activitySource?.cancel()
        activitySource = nil
        let watchPath = activityPath
        lock.unlock()

        guard !watchPath.isEmpty else { return }
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
            let flags = src.data
            self.deliver(.activity)
            if flags.contains(.delete) || flags.contains(.rename) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.armActivity()
                }
            }
        }
        src.setCancelHandler { close(fd) }
        lock.lock()
        activitySource = src
        lock.unlock()
        src.resume()
    }

    /// Arms the attention.tsv watch only — never `teardownLocked()`, which
    /// would cancel the activity watch too each time a hook write replaced
    /// the file (U-4). Only `stop()` tears every watch down.
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
            let flags = src.data
            self.deliver(.file)
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

    fileprivate enum Channel { case file, activity }

    /// Leading edge now, one trailing edge for whatever the window absorbed.
    /// Runs on the main queue (every source's handler queue).
    private func deliver(_ channel: Channel) {
        let now = Date().timeIntervalSince1970
        lock.lock()
        var throttle = throttles[channel] ?? CoalescingThrottle(window: 0.35)
        let decision = throttle.event(at: now)
        let delay = throttle.trailingDelay(at: now)
        throttles[channel] = throttle
        let callback = channel == .activity ? onActivity : onChange
        lock.unlock()
        switch decision {
        case .fire:
            callback?()
        case .absorbed:
            break
        case .armTrailing:
            // Trailing edge: whatever landed inside the window is read once
            // the window closes, so the latest state is never left waiting
            // for the next probe tick.
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.throttles[channel]?.trailingFired(at: Date().timeIntervalSince1970)
                let trailing = channel == .activity ? self.onActivity : self.onChange
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
