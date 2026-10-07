// The OS sources the engine wakes on: the event log's file (one
// `DispatchSource`), each session's process exit (one source per pid), and
// power and display state. Each says that something changed; `ScanEngine`
// decides what to read.

import AppKit
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

/// A session ends when its process exits — told by the kernel, not
/// found by polling.
///
/// One `DispatchSource` process source (kqueue `NOTE_EXIT`) per pid a live
/// session runs. `follow` keeps the set in step with the book: new pids get
/// a source, pids no live session runs lose theirs. A pid that is already
/// gone when it is first followed is reported at once — kqueue will not
/// report an exit that happened before the watch began.
final class ProcessExitWatch: @unchecked Sendable {
    // Every field is touched under `lock`; sources deliver on the main queue.
    private let lock = NSLock()
    private var sources: [Int32: any DispatchSourceProcess] = [:]
    private var onExit: (@Sendable (Int32) -> Void)?

    /// Where exits are reported (on the main queue).
    func start(onExit: @escaping @Sendable (Int32) -> Void) {
        lock.lock()
        self.onExit = onExit
        lock.unlock()
    }

    /// Watch exactly `pids`.
    func follow(_ pids: Set<Int32>) {
        lock.lock()
        let gone = Set(sources.keys).subtracting(pids)
        for pid in gone {
            sources[pid]?.cancel()
            sources[pid] = nil
        }
        let added = pids.subtracting(sources.keys).filter { $0 > 1 }
        var dead: [Int32] = []
        for pid in added {
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            source.setEventHandler { [weak self] in
                self?.exited(pid)
            }
            sources[pid] = source
            source.resume()
            if !AgentProcesses.isAlive(pid) { dead.append(pid) }
        }
        let report = onExit
        lock.unlock()
        for pid in dead {
            DispatchQueue.main.async { self.exited(pid, report: report) }
        }
    }

    func stop() {
        lock.lock()
        for source in sources.values { source.cancel() }
        sources.removeAll()
        onExit = nil
        lock.unlock()
    }

    private func exited(_ pid: Int32, report: (@Sendable (Int32) -> Void)? = nil) {
        lock.lock()
        guard let source = sources.removeValue(forKey: pid) else {
            lock.unlock()
            return
        }
        source.cancel()
        let callback = report ?? onExit
        lock.unlock()
        callback?(pid)
    }
}

/// Watches the machine conditions that let Pulse stop working so hard:
/// display asleep, screen locked, Low Power Mode.
@MainActor
final class PowerMonitor {
    private(set) var state = ProbeSchedule.Power.current
    private var onChange: (() -> Void)?
    /// Keep each token with the center that issued it — `DistributedNotificationCenter`
    /// tokens must be removed from that center, not from `.default`.
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    func start(onChange: @escaping () -> Void) {
        stop()
        self.onChange = onChange
        state = ProbeSchedule.Power.current

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.displayAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.displayAsleep = false }
        observe(workspace, NSWorkspace.willSleepNotification) { $0.displayAsleep = true }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.displayAsleep = false }

        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.screenLocked = true }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.screenLocked = false }

        observe(NotificationCenter.default, .NSProcessInfoPowerStateDidChange) {
            $0.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    func stop() {
        for entry in observers {
            entry.center.removeObserver(entry.token)
        }
        observers.removeAll()
        onChange = nil
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        _ apply: @escaping (inout ProbeSchedule.Power) -> Void
    ) {
        // A pure edit of a value, applied on the main queue.
        let change = Unchecked(apply)
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.mutate(change.value)
            }
        }
        observers.append((center, token))
    }

    private func mutate(_ apply: (inout ProbeSchedule.Power) -> Void) {
        var next = state
        apply(&next)
        guard next != state else { return }
        state = next
        DebugLog.write(
            "power asleep=\(next.displayAsleep) locked=\(next.screenLocked) lowPower=\(next.lowPowerMode)"
        )
        onChange?()
    }
}
