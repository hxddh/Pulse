import Foundation
import AppKit

/// The engine: events in, the tray out. Not observed — no view reads it.
///
/// Nothing here polls a vendor. What moves a session:
///
/// - the **event log** (`events.tsv`): a hook appends a numbered v7 line;
///   the watcher wakes the engine, which reads the bytes after its cursor
///   off the main thread and applies the lines numbered past the last it
///   applied, in order, to the `SessionBook`. At launch the whole log is
///   replayed **before the first projection**, and that projection is the
///   baseline (no banner for what was already there). A rewritten log (a
///   compaction) is read whole again and, the same, only lines past the last
///   `seq` are applied; a log started over (another `gen`) is applied whole;
///   a failed or empty read changes nothing;
/// - a **process exit**: kqueue (`ProcessExitWatch`) ends the sessions that
///   process ran;
/// - the **process scan** (libproc — at launch, on wake, when a hook names
///   a pid the last scan did not find, and on a timer that backs off from
///   30 s to 5 min while the scans find the same processes): agent
///   processes no session has claimed become process-only rows;
/// - the **tick** (`ProbeSchedule.tick`): a re-projection with no IO, so a
///   wait's age and the time rules move on screen.
///
/// Each change re-projects the book (`TrayState.project`, pure) and hands
/// the result to `StatusStore.land`, which assigns an observed property only
/// when its value changed. The projection carries state only — a burst of
/// tool lines moves the book's facts (`SessionFacts`), which the views read
/// when they draw, and lands nothing. No vendor file is read: what a row
/// says comes from its events. A failed read — event log, process table —
/// keeps what the engine had: a source failure never blanks the tray, and a
/// failed log read is retried on one timer that backs off from 5 s to 60 s.
@MainActor
final class ScanEngine {
    /// The model this engine feeds. Weak: the model owns the engine.
    weak var model: StatusStore?

    /// Tests exercising store behaviour must not start real reads: a read
    /// is not free (the event log is locked).
    static var suppressBackgroundScansForTesting = false

    let powerMonitor = PowerMonitor()
    let attentionWatcher = AttentionWatcher()
    let exitWatch = ProcessExitWatch()
    private let ioQueue = DispatchQueue(label: PulseVersion.bundleID + ".events", qos: .userInitiated)

    // MARK: The world, as the events said it

    private(set) var book = SessionBook()
    /// Where the engine is in the event log: the header it read, the byte
    /// after the last line read, the log's `gen` and the last `seq` applied.
    private(set) var logCursor: EventLog.Cursor?
    /// Agent processes the last process scan found.
    private(set) var processes: [AgentProcesses.Hit] = []
    /// The newest hook event per agent, for Settings' "last event" and the
    /// report. Kept here so a redraw never reads a file.
    private(set) var latestHookEventMs: [AgentID: Int64] = [:]
    /// The last line each agent's hook sent that was `ignored` — its event
    /// and why — for the report.
    private(set) var latestIgnored: [AgentID: SettingsModel.Ignored] = [:]
    /// The last projection's open waits (`TrayState.waitingSince`) — what
    /// the next one finds its Waiting edges against.
    private var lastWaits: [SessionKey: Int64] = [:]
    /// The event log has been read once: every projection up to and
    /// including the one after that read (the launch replay) is the
    /// baseline — a wait already in the log is not news. Only the launch
    /// replay is: every projection after it can notify.
    private(set) var logRead = false
    /// `start()` holds every projection until the launch replay has landed
    /// (or failed), so the first tray drawn is the replayed one.
    private var holdProjection = false
    /// The one pending retry of a failed log read, and the wait before the
    /// next one (5 s, doubling to 60 s; back to 5 s after a good read).
    private var logRetry: Task<Void, Never>?
    private(set) var logRetryDelay: Duration = ScanEngine.firstLogRetry
    nonisolated static let firstLogRetry: Duration = .seconds(5)
    nonisolated static let maxLogRetry: Duration = .seconds(60)

    // MARK: Cadence

    private var tickTimer: Timer?
    private var processTimer: Timer?
    /// Process scans in a row that found the same processes: the timer
    /// backs off (`ProbeSchedule.processScan(power:quietScans:)`).
    private(set) var quietProcessScans = 0
    /// Pids a hook named that no scan had found — each asks for one scan.
    private var pidsScannedFor: Set<Int32> = []
    /// `start()` armed the watchers and timers. A store a test or a fixture
    /// builds never starts a scan of its own.
    private var armed = false
    /// The tray is on screen.
    private(set) var trayOpen = false
    private(set) var activity: ProbeSchedule.Activity = .empty
    /// A wait younger than `freshWaitMs` is open.
    private var freshWait = false
    /// A wait younger than this keeps the fast tick: the banner for a wait
    /// raised in front of the person is decided 30 s later.
    static let freshWaitMs: Int64 = 60_000
    /// The tick in force; nil while it is stopped.
    private(set) var currentInterval: TimeInterval?
    private var lastApplyLogSignature = ""

    /// The process scan's current period; nil while parked.
    var processScanInterval: TimeInterval? {
        ProbeSchedule.processScan(power: powerMonitor.state, quietScans: quietProcessScans)
    }

    /// Reads in flight, and reads asked for while one was.
    private enum Source: Hashable { case events, processes }
    private var reading: Set<Source> = []
    private var rereadWanted: Set<Source> = []

    /// How the event log is read after a cursor, off the main thread: the
    /// real log. A test reads its own file (never a global override —
    /// suites run in parallel).
    var readLog: @Sendable (EventLog.Cursor?) -> EventLog.Chunk? = { EventLog.read(after: $0) }

    /// Read what is new in the event log — what the watcher does when the
    /// log changes. A read asked for while one is in flight runs once that
    /// one has landed.
    func readEvents() {
        read(.events)
    }

    /// An event read is in flight, or asked for after the one in flight.
    var eventReadPending: Bool {
        reading.contains(.events) || rereadWanted.contains(.events)
    }

    // MARK: - Lifecycle

    /// Arm everything: the first reads, the watchers, the exit watch, the
    /// timers and the power monitor. `StatusStore.start()` calls it once
    /// settings are loaded.
    func start() {
        armed = true
        holdProjection = !Self.suppressBackgroundScansForTesting
        exitWatch.start { [weak self] pid in
            // Bind before the Task: the exit callback is @Sendable.
            guard let engine = self else { return }
            Task { @MainActor in engine.processExited(pid) }
        }
        attentionWatcher.start { [weak self] in
            Task { @MainActor in self?.read(.events) }
        }
        powerMonitor.start { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.rescheduleTimer()
                self.rescheduleProcessScan()
                // Back from sleep or lock: catch up at once.
                if !self.powerMonitor.state.parked {
                    self.quietProcessScans = 0
                    self.read(.processes)
                    self.project()
                }
            }
        }
        // The launch replay first; the process scan lands after it or is
        // held with it.
        read(.events)
        read(.processes)
        rescheduleTimer()
        rescheduleProcessScan()
    }

    func stop() {
        armed = false
        logRetry?.cancel()
        logRetry = nil
        attentionWatcher.stop()
        exitWatch.stop()
        tickTimer?.invalidate()
        tickTimer = nil
        processTimer?.invalidate()
        processTimer = nil
    }

    /// The tray came on screen or left it — tick faster while it is read.
    func setTrayOpen(_ open: Bool) {
        trayOpen = open
        rescheduleTimer()
    }

    /// Read what is new in the event log and re-scan the process table.
    /// Cheap — the bytes after the cursor and one pass over the process
    /// table, no vendor file — and only on a person's action (the tray
    /// opening, ⌘R, a dismissal, a setting).
    func refresh(reason: String) {
        if Self.suppressBackgroundScansForTesting { return }
        DebugLog.write("refresh reason=\(reason)")
        read(.events)
        read(.processes)
    }

    // MARK: - Cadence

    func rescheduleTimer() {
        tickTimer?.invalidate()
        tickTimer = nil
        let interval = ProbeSchedule.tick(
            activity: activity,
            power: powerMonitor.state,
            trayOpen: trayOpen,
            freshWait: freshWait
        )
        currentInterval = interval
        guard let interval, !Self.suppressBackgroundScansForTesting else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            // Bind before the Task: the timer block is @Sendable.
            guard let engine = self else { return }
            Task { @MainActor in engine.tick() }
        }
        timer.tolerance = interval * 0.2
        tickTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// One-shot: each scan that lands re-arms it with the backed-off period.
    private func rescheduleProcessScan() {
        processTimer?.invalidate()
        processTimer = nil
        guard armed, let interval = processScanInterval,
              !Self.suppressBackgroundScansForTesting
        else { return }
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            guard let engine = self else { return }
            Task { @MainActor in engine.read(.processes) }
        }
        timer.tolerance = interval * 0.2
        processTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - Reads (off the main thread)

    private func read(_ source: Source) {
        if Self.suppressBackgroundScansForTesting { return }
        guard !reading.contains(source) else {
            rereadWanted.insert(source)
            return
        }
        reading.insert(source)
        switch source {
        case .events:
            let cursor = logCursor
            let readLog = self.readLog
            ioQueue.async { [weak self] in
                let chunk = readLog(cursor)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    // Land first, then start any read asked for meanwhile:
                    // it must begin at the cursor this one moved, or it
                    // reads — and applies — the same lines again.
                    if let chunk {
                        self.landLog(chunk)
                    } else {
                        self.logReadFailed()
                    }
                    self.finishRead(.events)
                }
            }
        case .processes:
            ioQueue.async { [weak self] in
                let hits = AgentProcesses.scan()
                DispatchQueue.main.async { [weak self] in
                    self?.finishRead(.processes)
                    self?.apply(processes: hits, nowMs: Self.nowMs())
                }
            }
        }
    }

    private func finishRead(_ source: Source) {
        reading.remove(source)
        if rereadWanted.remove(source) != nil { read(source) }
    }

    // MARK: - Applying what was read

    /// One read of the event log. The first is the launch replay: every
    /// line, then the first projection, which is the baseline. After it,
    /// only the lines numbered past the last one applied — from a whole-file
    /// read of a rewritten log too; every line of a log started over
    /// (`EventLog.Chunk.unapplied`). A read that found no log changes
    /// nothing: the cursor and the book stay, so the next read cannot replay
    /// an answered block.
    func landLog(_ chunk: EventLog.Chunk, nowMs: Int64 = ScanEngine.nowMs()) {
        holdProjection = false
        logRetry?.cancel()
        logRetry = nil
        logRetryDelay = Self.firstLogRetry
        let baseline = !logRead
        let records = chunk.unapplied(after: logCursor)
        logCursor = chunk.advancing(logCursor)
        if records.isEmpty {
            // Nothing new (or nothing there): the empty replay is still the
            // baseline.
            if baseline { project(nowMs: nowMs) }
        } else {
            apply(records: records, nowMs: nowMs, verifyPids: baseline)
        }
        // The projection above was the baseline; the next one can notify.
        logRead = true
    }

    /// The log could not be read. Nothing changes; the launch hold is lifted
    /// (the tray draws what it has) and one retry is scheduled — never a
    /// second while one is pending — each waiting twice as long as the last,
    /// up to a minute. The launch replay stays the baseline whenever it lands.
    func logReadFailed() {
        DebugLog.write("event log read failed; keeping \(book.sessions.count) sessions")
        if holdProjection {
            holdProjection = false
            project()
        }
        guard armed, !Self.suppressBackgroundScansForTesting, logRetry == nil else { return }
        let delay = logRetryDelay
        logRetryDelay = Self.nextLogRetry(after: delay)
        logRetry = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.logRetry = nil
            self.read(.events)
        }
    }

    /// The wait after `delay` for the next retry: twice as long, at most
    /// `maxLogRetry`. Pure.
    nonisolated static func nextLogRetry(after delay: Duration) -> Duration {
        min(delay * 2, maxLogRetry)
    }

    private func noteHookEvent(_ agent: AgentID, atMs ms: Int64) {
        if (latestHookEventMs[agent] ?? 0) < ms { latestHookEventMs[agent] = ms }
    }

    /// Event records, in order. Tests call this directly. `verifyPids` (the
    /// launch replay) also ends a session whose pid now belongs to another
    /// process — a pid reused since the log was written.
    func apply(records: [AttentionRecord], nowMs: Int64, verifyPids: Bool = false) {
        for record in records {
            book.apply(record, nowMs: nowMs)
            // A `dismiss` is Pulse's own: not the agent's hook speaking, so
            // not its "last event". An ignored line is — the hook ran.
            if record.kind != .dismiss, record.ms > 0 {
                noteHookEvent(record.agent, atMs: min(record.ms, nowMs))
            }
            if record.kind == .ignored {
                let heard = SettingsModel.Ignored(event: record.event, reason: record.message)
                latestIgnored[record.agent] = heard
                if logRead { DebugLog.write("ignored agent=\(record.agent.rawValue) \(heard.phrase)") }
            }
        }
        // A pid the log names that is gone ended while nobody watched.
        if verifyPids {
            endGoneSessions()
        } else {
            book.endSessions(whosePidIsDead: AgentProcesses.isAlive)
        }
        // A live pid no scan has found: one scan, so its terminal and host
        // are known and a process-only row is not left beside its session.
        if armed {
            let known = Set(processes.flatMap(\.family))
            let unknown = Set(records.map(\.pid).filter { $0 > 1 && !known.contains($0) })
                .subtracting(pidsScannedFor)
                .filter(AgentProcesses.isAlive)
            if !unknown.isEmpty {
                pidsScannedFor.formUnion(unknown)
                if pidsScannedFor.count > 512 { pidsScannedFor = unknown }
                quietProcessScans = 0
                read(.processes)
            }
        }
        project(nowMs: nowMs)
    }

    /// A process scan. `nil` — the table could not be read — keeps the last
    /// good list. A scan that found the same processes as the last one
    /// backs the timer off; one that found a change brings it back to 30 s.
    func apply(processes hits: [AgentProcesses.Hit]?, nowMs: Int64) {
        if let hits {
            quietProcessScans = ProbeSchedule.nextQuietScans(
                quietProcessScans,
                same: Set(hits.map(\.pid)) == Set(processes.map(\.pid))
            )
            processes = hits
        } else {
            DebugLog.write("process scan failed; keeping \(processes.count)")
        }
        // Dead, or its pid reused by another process since.
        endGoneSessions()
        project(nowMs: nowMs)
        rescheduleProcessScan()
    }

    /// kqueue said `pid` exited.
    func processExited(_ pid: Int32, nowMs: Int64 = ScanEngine.nowMs()) {
        processes.removeAll { $0.family.contains(pid) }
        if book.processExited(pid: pid, atMs: nowMs) {
            DebugLog.write("process exit pid=\(pid) ends its session")
        }
        project(nowMs: nowMs)
    }

    // MARK: - Projection

    /// Ends every live session whose process is gone: its pid is dead, or
    /// it now runs another agent or started after the session named it (a
    /// reused pid — `AgentProcesses.stillRuns`). IO: `kill(0)` per session,
    /// and one `proc_pidinfo` + argv read (one shared buffer) per live pid.
    private func endGoneSessions() {
        var buffer: [UInt8] = []
        book.endSessions(whoseProcessIsGone: { session in
            guard AgentProcesses.isAlive(session.pid) else { return true }
            return !AgentProcesses.stillRuns(
                agent: session.agent,
                since: session.pidSinceMs,
                identity: AgentProcesses.identity(of: session.pid, buffer: &buffer)
            )
        })
    }

    /// The tick: time moved, nothing else — the time rules (a stall, a
    /// held turn's grace, the recent bounds) and the menu-bar title's age.
    func tick(nowMs: Int64 = ScanEngine.nowMs()) {
        project(nowMs: nowMs)
    }

    /// The book as rows, landed on the model. Pure but for the landing.
    /// Held while the launch replay is being read.
    func project(nowMs: Int64 = ScanEngine.nowMs()) {
        guard let model, !holdProjection else { return }
        // A turn held for a block lands once its grace has passed, even when
        // no event follows (a denied prompt, then Stop within 20 s).
        book.settleHeldTurns(nowMs: nowMs)
        book.prune(nowMs: nowMs)
        let state = TrayState.project(
            book: book,
            processes: processes,
            context: TrayState.Context(
                nowMs: nowMs,
                lang: model.lang,
                previousWaits: lastWaits
            )
        )
        exitWatch.follow(book.livePids)
        lastWaits = state.waitingSince
        model.land(state, nowMs: nowMs, baseline: !logRead)
        let snap = state.snapshot

        // Re-arm the tick only when its tier moved.
        let nextFreshWait = state.rows.contains { row in
            guard let since = row.wait?.sinceMs, since > 0 else { return false }
            return nowMs - since < Self.freshWaitMs
        }
        if state.activity != activity || nextFreshWait != freshWait || (tickTimer == nil && currentInterval == nil) {
            activity = state.activity
            freshWait = nextFreshWait
            rescheduleTimer()
        }

        // One line when the lamp or the counts move — not one per tick.
        let signature = "rows=\(state.rows.count) lamp=\(snap.lamp.rawValue) " +
            "activity=\(activity) wait=\(state.waitingSince.count) procs=\(processes.count)"
        if signature != lastApplyLogSignature {
            lastApplyLogSignature = signature
            DebugLog.write("apply " + signature)
        }
    }

    nonisolated static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
