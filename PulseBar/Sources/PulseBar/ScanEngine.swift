import Foundation
import AppKit

/// The engine (24.0): events in, rows out. Not observed — no view reads it.
///
/// Nothing here polls a vendor. What moves a session:
///
/// - the **attention file** (`attention.tsv`): a hook appends a v4 line; the
///   watcher wakes the engine, which reads the file off the main thread and
///   applies only the lines it has not seen to the `SessionBook`;
/// - the **activity spool** (`activity.d/`): a hook's tool or prompt event;
/// - a **process exit**: kqueue (`ProcessExitWatch`) ends the sessions that
///   process ran;
/// - the **process scan** (libproc, every 30 s, at launch and on wake): agent
///   processes no session has claimed become process-only rows;
/// - the **tick** (`ProbeSchedule.tick`): a re-projection with no IO, so a
///   wait's age and the time rules move on screen.
///
/// Each change re-projects the book (`SessionProjection`, then the thin
/// `SnapshotBuilder`) and hands the result to `StatusStore.land`, which
/// assigns an observed property only when its value changed. A transcript is
/// read only when its session reaches your turn or a wait, or its detail
/// opens — bounded, off the main thread, cached per (path, size, mtime).
/// A failed read — attention, spool, process table, transcript — keeps what
/// the engine had: a source failure never blanks the tray.
@MainActor
final class ScanEngine {
    /// The model this engine feeds. Weak: the model owns the engine.
    weak var model: StatusStore?

    /// Tests exercising store behaviour must not start real reads: a read
    /// is not free (the attention file is locked, the session log written
    /// once `start()` loaded it). Same shape as `AttentionIO.pathOverride`.
    static var suppressBackgroundScansForTesting = false

    let powerMonitor = PowerMonitor()
    let attentionWatcher = AttentionWatcher()
    let exitWatch = ProcessExitWatch()
    private let ioQueue = DispatchQueue(label: "com.pulse.events", qos: .userInitiated)

    // MARK: The world, as the events said it

    private(set) var book = SessionBook()
    /// The attention lines already applied — the file is re-read whole (it
    /// is small and compacted), and only lines not seen before are new.
    private var seenLines: Set<String> = []
    /// Agent processes the last process scan found.
    private(set) var processes: [AgentProcesses.Hit] = []
    /// Transcript summaries by path, and the file stamp each was read at.
    private(set) var transcripts: [String: TranscriptSummary] = [:]
    private var transcriptStamps: [String: FileStamp] = [:]
    private var transcriptReads: Set<String> = []
    /// The newest attention line per agent — Settings' and Diagnostics'
    /// "last event". Kept here so a redraw never reads the file.
    private(set) var latestHookEventMs: [AgentID: Int64] = [:]

    // MARK: Cadence

    private var tickTimer: Timer?
    private var processTimer: Timer?
    /// The tray panel is on screen.
    private(set) var trayOpen = false
    private(set) var activity: ProbeSchedule.Activity = .empty
    /// A wait younger than a minute is on screen (drawn in seconds).
    private var freshWait = false
    /// The tick in force; nil while it is stopped.
    private(set) var currentInterval: TimeInterval?
    /// The display is asleep or the screen is locked — nothing is being read.
    var powerParked: Bool { powerMonitor.state.parked }
    /// When the last projection landed. Read by the header and Diagnostics.
    private(set) var lastScanAt: Date?
    /// The expected gap that scheduled the last projection.
    private(set) var lastScanInterval: TimeInterval?
    /// The longest a person should wait for the next projection with no
    /// event: the sooner of the tick and the process scan (each projects).
    /// nil when both are stopped. The header judges freshness against it.
    var expectedInterval: TimeInterval? {
        let scan = ProbeSchedule.processScan(power: powerMonitor.state)
        switch (currentInterval, scan) {
        case let (tick?, scan?): return min(tick, scan)
        case let (tick?, nil): return tick
        case let (nil, scan?): return scan
        case (nil, nil): return nil
        }
    }
    private var lastApplyLogSignature = ""

    /// Reads in flight, and reads asked for while one was.
    private enum Source: Hashable { case attention, activity, processes }
    private var reading: Set<Source> = []
    private var rereadWanted: Set<Source> = []

    struct FileStamp: Equatable, Sendable {
        var size: Int64
        var mtimeMs: Int64
    }

    // MARK: - Lifecycle

    /// Arm everything: the first reads, the watchers, the exit watch, the
    /// timers and the power monitor. `StatusStore.start()` calls it once
    /// settings and the session log are loaded.
    func start() {
        exitWatch.start { [weak self] pid in
            // Bind before the Task: the exit callback is @Sendable.
            guard let engine = self else { return }
            Task { @MainActor in engine.processExited(pid) }
        }
        attentionWatcher.start(
            onChange: { [weak self] in
                Task { @MainActor in self?.read(.attention) }
            },
            onActivity: { [weak self] in
                Task { @MainActor in self?.read(.activity) }
            }
        )
        powerMonitor.start { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.rescheduleTimer()
                self.rescheduleProcessScan()
                // Back from sleep or lock: catch up at once.
                if !self.powerMonitor.state.parked {
                    self.read(.processes)
                    self.project()
                    if let model = self.model { UpdateCheck.shared.startIfEnabled(store: model) }
                }
            }
        }
        read(.attention)
        read(.activity)
        read(.processes)
        rescheduleTimer()
        rescheduleProcessScan()
    }

    func stop() {
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

    /// Re-read everything and re-project: the attention file, the spool and
    /// the process table. Cheap — two small files and one pass over the
    /// process table, no vendor file — and only on a person's action (the
    /// tray opening, ⌘R, a dismissal, a setting).
    func refresh(reason: String) {
        if Self.suppressBackgroundScansForTesting { return }
        DebugLog.write("refresh reason=\(reason)")
        read(.attention)
        read(.activity)
        read(.processes)
    }

    // MARK: - Cadence

    /// For Diagnostics and the report.
    func probeIntervalDescription(lang: ResolvedLanguage) -> String {
        guard let seconds = ProbeSchedule.processScan(power: powerMonitor.state) else {
            return L10n.t(.probeParked, lang)
        }
        return String(format: L10n.t(.probeEvery, lang), Int(seconds.rounded()))
    }

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

    private func rescheduleProcessScan() {
        processTimer?.invalidate()
        processTimer = nil
        guard let interval = ProbeSchedule.processScan(power: powerMonitor.state),
              !Self.suppressBackgroundScansForTesting
        else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
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
        case .attention:
            ioQueue.async { [weak self] in
                let text = AttentionIO.readText()
                DispatchQueue.main.async { [weak self] in
                    self?.finishRead(.attention)
                    self?.landAttention(text)
                }
            }
        case .activity:
            let nowMs = Self.nowMs()
            ioQueue.async { [weak self] in
                let events = ActivitySpool.readEvents(nowMs: nowMs)
                DispatchQueue.main.async { [weak self] in
                    self?.finishRead(.activity)
                    self?.apply(activity: events, nowMs: Self.nowMs())
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

    /// The attention file's text: apply the lines not seen before, in file
    /// order.
    func landAttention(_ text: String, nowMs: Int64 = ScanEngine.nowMs()) {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        let fresh = lines.filter { !seenLines.contains($0) }
        seenLines = Set(lines)
        for (agent, ms) in AttentionIO.latestEventTimes(in: text) {
            latestHookEventMs[agent] = max(latestHookEventMs[agent] ?? 0, ms)
        }
        apply(records: fresh.compactMap { AttentionRecord(line: $0) }, nowMs: nowMs)
    }

    /// Attention records, in order. Tests call this directly.
    func apply(records: [AttentionRecord], nowMs: Int64) {
        for record in records { book.apply(record, nowMs: nowMs) }
        // A pid the file names that is gone ended while nobody watched.
        book.endSessions(whosePidIsDead: AgentProcesses.isAlive)
        project(nowMs: nowMs)
    }

    /// Activity events (the spool is re-read whole; the book ignores what it
    /// has already seen).
    func apply(activity events: [ActivitySpool.Event], nowMs: Int64) {
        for event in events { book.apply(activity: event, nowMs: nowMs) }
        project(nowMs: nowMs)
    }

    /// A process scan. `nil` — the table could not be read — keeps the last
    /// good list.
    func apply(processes hits: [AgentProcesses.Hit]?, nowMs: Int64) {
        if let hits {
            processes = hits
        } else {
            DebugLog.write("process scan failed; keeping \(processes.count)")
        }
        book.endSessions(whosePidIsDead: AgentProcesses.isAlive)
        project(nowMs: nowMs)
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

    /// The book as rows, landed on the model. Pure but for the landing.
    func project(nowMs: Int64 = ScanEngine.nowMs()) {
        guard let model else { return }
        book.prune(nowMs: nowMs)
        let output = SessionProjection.rows(
            book: book,
            processes: processes,
            transcripts: transcripts,
            context: SessionProjection.Context(
                nowMs: nowMs,
                allowAutomation: model.settings.allowTerminalAutomation
            )
        )
        let result = SnapshotBuilder.build(
            rows: output.rows,
            staleHidden: output.staleHidden,
            previous: SnapshotBuilder.Previous(
                rows: model.cachedAll,
                waitingKeys: model.sessionLog.waitingKeys,
                waitingSince: model.sessionLog.waitingSince
            ),
            context: SnapshotBuilder.Context(
                nowMs: nowMs,
                lang: model.lang,
                showAllAgents: model.showAllAgents
            )
        )
        let now = Date(timeIntervalSince1970: Double(nowMs) / 1000)
        var snap = result.snapshot
        snap.updatedAt = now
        model.land(result, snapshot: snap, nowMs: nowMs)
        lastScanAt = now
        lastScanInterval = expectedInterval

        exitWatch.follow(book.livePids)
        for session in book.sessions.values where Self.wantsTranscript(session, nowMs: nowMs) {
            requestTranscript(session)
        }
        transcripts = transcripts.filter { path, _ in book.sessions.values.contains { $0.transcript == path } }

        // Re-arm the tick only when its tier moved.
        let nextFreshWait = result.rows.contains { row in
            guard let since = row.wait?.sinceMs, since > 0 else { return false }
            return nowMs - since < PulseSnapshot.secondsLabelWindowMs
        }
        if result.activity != activity || nextFreshWait != freshWait || (tickTimer == nil && currentInterval == nil) {
            activity = result.activity
            freshWait = nextFreshWait
            rescheduleTimer()
        }

        // One line when the lamp or the counts move — not one per tick.
        let signature = "rows=\(snap.rows.count)/\(snap.totalCount) glance=\(snap.glance) " +
            "activity=\(activity) wait=\(result.waitingKeys.count) procs=\(processes.count)"
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
        switch SessionProjection.state(of: session, nowMs: nowMs) {
        case .yourTurn, .blocked: return true
        case .running, .recent, .processOnly: return false
        }
    }

    private func requestTranscript(_ session: SessionBook.Session) {
        let path = session.transcript
        guard !path.isEmpty, !transcriptReads.contains(path), !Self.suppressBackgroundScansForTesting else { return }
        transcriptReads.insert(path)
        let known = transcriptStamps[path]
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
