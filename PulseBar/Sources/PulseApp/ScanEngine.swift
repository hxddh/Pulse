import Foundation
import AppKit

/// The engine: events in, the tray out. Not observed — no view reads it.
///
/// Nothing here polls a vendor. What moves a session:
///
/// - the **event log** (`events.tsv`): a hook appends a v5 line; the
///   watcher wakes the engine, which reads the bytes after its cursor off
///   the main thread and applies those lines, in order, to the
///   `SessionBook`. At launch the whole log is replayed **before the first
///   projection**, and that projection is the baseline (no banner for what
///   was already there). A rewritten log (compaction: a new generation) is
///   read whole again, and only lines not already applied are applied; a
///   failed or empty read changes nothing;
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
/// when its value changed. A transcript is
/// read only when its session reaches your turn or a wait, or its detail
/// opens — bounded, off the main thread, cached per (path, size, mtime).
/// A failed read — event log, process table, transcript — keeps what the
/// engine had: a source failure never blanks the tray.
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
    private let ioQueue = DispatchQueue(label: "com.pulse.events", qos: .userInitiated)

    // MARK: The world, as the events said it

    private(set) var book = SessionBook()
    /// Where the engine is in the event log: its generation and the byte
    /// after the last line applied.
    private(set) var logCursor: EventLog.Cursor?
    /// Every line of the current generation already applied — consulted
    /// only when the log was rewritten and is read whole again, so a line
    /// the compaction kept is not applied twice. Bounded by the log.
    private var appliedLines: Set<String> = []
    /// Agent processes the last process scan found.
    private(set) var processes: [AgentProcesses.Hit] = []
    /// Transcript summaries by path, and the file stamp each was read at.
    private(set) var transcripts: [String: TranscriptSummary] = [:]
    private var transcriptStamps: [String: FileStamp] = [:]
    private var transcriptReads: Set<String> = []
    /// The newest hook event per agent, for Settings' "last event" and the
    /// report. Kept here so a redraw never reads a file.
    private(set) var latestHookEventMs: [AgentID: Int64] = [:]
    /// The last projection's open waits (`TrayState.waitingSince`) — what
    /// the next one finds its Waiting edges against.
    private var lastWaits: [String: Int64] = [:]
    /// The event log has been read once: every projection up to and
    /// including the one after that read (the launch replay) is the
    /// baseline — a wait already in the log is not news.
    private(set) var logRead = false
    /// `start()` holds every projection until the launch replay has landed
    /// (or failed), so the first tray drawn is the replayed one.
    private var holdProjection = false

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
    /// The tray panel is on screen.
    private(set) var trayOpen = false
    private(set) var activity: ProbeSchedule.Activity = .empty
    /// A wait younger than a minute is on screen (drawn in seconds).
    private var freshWait = false
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

    struct FileStamp: Equatable, Sendable {
        var size: Int64
        var mtimeMs: Int64
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
                    if let model = self.model { UpdateCheck.shared.startIfEnabled(store: model) }
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
            Task { @MainActor in engine.project() }
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
            Task { @MainActor in
                engine.read(.processes)
                // One date comparison unless a day has passed.
                if let model = engine.model { UpdateCheck.shared.startIfEnabled(store: model) }
            }
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
            ioQueue.async { [weak self] in
                let chunk = EventLog.read(after: cursor)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.finishRead(.events)
                    if let chunk {
                        self.landLog(chunk)
                    } else {
                        self.logReadFailed()
                    }
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

    /// One read of the event log, in file order. The first is the launch
    /// replay: every line, then the first projection, which is the
    /// baseline. After it, only the lines after the cursor — unless the log
    /// was rewritten (`chunk.fresh`), when the lines already applied are
    /// skipped. An empty read changes nothing: it never resets what was
    /// applied, so the next read cannot replay an answered block.
    func landLog(_ chunk: EventLog.Chunk, nowMs: Int64 = ScanEngine.nowMs()) {
        holdProjection = false
        let baseline = !logRead
        if chunk.lines.isEmpty, chunk.fresh {
            // Nothing there (a missing header, an empty file): keep the
            // cursor and what was applied.
            if baseline { project(nowMs: nowMs) }
            logRead = true
            return
        }
        var fresh: [String] = []
        if chunk.fresh {
            var next: Set<String> = []
            for line in chunk.lines {
                if !appliedLines.contains(line) { fresh.append(line) }
                next.insert(line)
            }
            appliedLines = next
        } else {
            fresh = chunk.lines
            appliedLines.formUnion(chunk.lines)
        }
        logCursor = chunk.cursor
        let records = fresh.compactMap { AttentionRecord(line: $0) }
        apply(records: records, nowMs: nowMs, verifyPids: baseline)
        // The projection above was the baseline; the next one can notify.
        logRead = true
    }

    /// The log could not be read. Nothing changes; the launch hold is lifted
    /// (the tray draws what it has, baseline) and the read is tried again.
    func logReadFailed() {
        DebugLog.write("event log read failed; keeping \(book.sessions.count) sessions")
        if holdProjection {
            holdProjection = false
            project()
        }
        guard armed, !Self.suppressBackgroundScansForTesting else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.read(.events)
        }
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
            // A `done` may be Pulse's own (a dismissal): not the agent's hook
            // speaking, so not its "last event".
            if let agent = AgentCatalog.agent(named: record.agent), record.ms > 0,
               AttentionProtocol.kind(record.kind) != .done {
                noteHookEvent(agent, atMs: min(record.ms, nowMs))
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

    /// The detail page for this row opened: read its transcript if it has
    /// one and it changed since it was last read.
    func detailOpened(rowKey: String) {
        guard let session = book.sessions[rowKey] else { return }
        requestTranscript(session)
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

    /// The book as rows, landed on the model. Pure but for the landing.
    /// Held while the launch replay is being read.
    func project(nowMs: Int64 = ScanEngine.nowMs()) {
        guard let model, !holdProjection else { return }
        // A turn held for a block lands once its grace has passed, even when
        // no event follows (a denied prompt, then Stop within 20 s).
        book.settleHeldTurns(nowMs: nowMs)
        book.prune(nowMs: nowMs)
        var state = TrayState.project(
            book: book,
            processes: processes,
            summaries: transcripts,
            context: TrayState.Context(
                nowMs: nowMs,
                lang: model.lang,
                allowAutomation: model.settings.allowTerminalAutomation,
                showAllAgents: model.showAllAgents,
                previousWaits: lastWaits
            )
        )
        lastWaits = state.waitingSince
        state.snapshot.updatedAt = Date(timeIntervalSince1970: Double(nowMs) / 1000)
        model.land(state, nowMs: nowMs, baseline: !logRead)
        let snap = state.snapshot

        exitWatch.follow(book.livePids)
        for session in book.sessions.values where Self.wantsTranscript(session, nowMs: nowMs) {
            requestTranscript(session)
        }
        // Summaries and their stamps go together: a stamp without its
        // summary would make a returning session's unchanged file look read.
        let paths = Set(book.sessions.values.map(\.transcript))
        transcripts = transcripts.filter { paths.contains($0.key) }
        transcriptStamps = transcriptStamps.filter { paths.contains($0.key) }

        // Re-arm the tick only when its tier moved.
        let nextFreshWait = state.rows.contains { row in
            guard let since = row.wait?.sinceMs, since > 0 else { return false }
            return nowMs - since < PulseSnapshot.secondsLabelWindowMs
        }
        if state.activity != activity || nextFreshWait != freshWait || (tickTimer == nil && currentInterval == nil) {
            activity = state.activity
            freshWait = nextFreshWait
            rescheduleTimer()
        }

        // One line when the lamp or the counts move — not one per tick.
        let signature = "rows=\(snap.rows.count)/\(snap.totalCount) glance=\(snap.glance) " +
            "activity=\(activity) wait=\(state.waitingSince.count) procs=\(processes.count)"
        if signature != lastApplyLogSignature {
            lastApplyLogSignature = signature
            DebugLog.write("apply " + signature)
        }
    }

    // MARK: - Transcripts (lazy)

    /// A session whose transcript is worth reading now: one that finished
    /// its turn or is waiting — the moments a person looks.
    static func wantsTranscript(_ session: SessionBook.Session, nowMs: Int64) -> Bool {
        guard !session.transcript.isEmpty else { return false }
        switch TrayState.state(of: session, nowMs: nowMs) {
        case .yourTurn, .blocked: return true
        case .running, .recent, .processOnly: return false
        }
    }

    private func requestTranscript(_ session: SessionBook.Session) {
        let path = session.transcript
        guard !path.isEmpty, !transcriptReads.contains(path), !Self.suppressBackgroundScansForTesting else { return }
        transcriptReads.insert(path)
        // Only a stamp whose summary is still held can skip the read.
        let known = transcripts[path] == nil ? nil : transcriptStamps[path]
        let agent = session.agent
        ioQueue.async { [weak self] in
            let stamp = Self.stamp(path)
            let summary: TranscriptSummary? = stamp != nil && stamp != known
                ? TranscriptSummaryReader.read(path: path, agent: agent)
                : nil
            DispatchQueue.main.async { [weak self] in
                self?.landTranscript(path: path, stamp: stamp, summary: summary)
            }
        }
    }

    private func landTranscript(path: String, stamp: FileStamp?, summary: TranscriptSummary?) {
        transcriptReads.remove(path)
        // Unchanged, or unreadable: keep what was read before.
        guard let stamp, let summary else { return }
        transcriptStamps[path] = stamp
        guard transcripts[path] != summary else { return }
        transcripts[path] = summary
        project()
    }

    nonisolated static func stamp(_ path: String) -> FileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber,
              let date = attributes[.modificationDate] as? Date
        else { return nil }
        return FileStamp(size: size.int64Value, mtimeMs: Int64(date.timeIntervalSince1970 * 1000))
    }

    nonisolated static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
