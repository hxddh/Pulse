import Foundation

/// 24.0 · a session ends when its process exits — told by the kernel, not
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

    var watchedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sources.count
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
