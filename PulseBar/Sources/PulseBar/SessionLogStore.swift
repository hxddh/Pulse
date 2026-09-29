import Foundation

/// 23.0 · where `SessionLog` lives on disk, and the store's side of keeping it.
///
/// One file, `session-log.json`, next to `attention.tsv` (so `PULSE_HOME`
/// moves both), written 0600 through `PrivateFile` — it holds session titles
/// and the words an agent asked with. A change is written after a short
/// debounce; a change the next launch must not lose (a banner owed before it
/// is posted, a dismissal) is written at once. An unchanged log is never
/// written: a scan that finds the same world touches no disk.
///
/// 23.0 carries nothing over from the files it replaced: `start()` deletes
/// them, unread.
enum SessionLogFile {
    static var fileURL: URL {
        AttentionIO.path.deletingLastPathComponent().appendingPathComponent("session-log.json")
    }

    /// What the log replaced (22.x). Removed at launch; never migrated.
    static let retiredFileNames = [
        "attention-ledger.json", "attention-history.json", "session-timeline.json", "dismissed-pending.json",
    ]

    static let readLimit = 8 * 1024 * 1024

    static func load(
        from url: URL = fileURL,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> SessionLog {
        guard let data = SafeRead.regularFile(atPath: url.path, limit: readLimit),
              var log = try? JSONDecoder().decode(SessionLog.self, from: data),
              log.schema == SessionLog.schemaVersion
        else { return SessionLog() }
        log.prune(nowMs: nowMs)
        return log
    }

    /// Stamps `savedAtMs` on the copy it writes.
    @discardableResult
    static func save(
        _ log: SessionLog,
        to url: URL = fileURL,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> Bool {
        var stamped = log
        stamped.savedAtMs = nowMs
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(stamped) else {
            DebugLog.write("session log encode failed")
            return false
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard PrivateFile.write(data, to: url) else {
            DebugLog.write("session log write failed")
            return false
        }
        return true
    }

    /// Deletes the 22.x files the log replaced, beside `url` and in the
    /// default Application Support folder (the ledger and the dismiss list
    /// always lived there, whatever `PULSE_HOME` said).
    static func removeRetiredFiles(besides url: URL) {
        let defaultDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pulse", isDirectory: true)
        var dirs = [url.deletingLastPathComponent()]
        if dirs[0].standardizedFileURL != defaultDir.standardizedFileURL { dirs.append(defaultDir) }
        for dir in dirs {
            for name in retiredFileNames {
                let file = dir.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: file.path) {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }
}

/// The debounced writer the store owns.
@MainActor
final class SessionLogStore {
    static let debounceNanos: UInt64 = 1_500_000_000

    /// Off until `StatusStore.start()` loads the log: a store a test builds
    /// never writes the developer's own file.
    var enabled = false
    private var pending: SessionLog?
    private var task: Task<Void, Never>?

    /// Queue `log` for writing; `immediately` writes it now.
    func write(_ log: SessionLog, immediately: Bool) {
        guard enabled else { return }
        pending = log
        if immediately {
            flush()
            return
        }
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanos)
            guard !Task.isCancelled, let self else { return }
            self.task = nil
            self.flush()
        }
    }

    /// Write whatever is queued, now (also on quit).
    func flush() {
        task?.cancel()
        task = nil
        guard enabled, let log = pending else { return }
        pending = nil
        SessionLogFile.save(log)
    }
}

@MainActor
extension StatusStore {
    /// Loads the log and turns persistence on. `start()` only.
    func loadSessionLog() {
        SessionLogFile.removeRetiredFiles(besides: SessionLogFile.fileURL)
        sessionLog = SessionLogFile.load()
        sessionLogStore.enabled = true
        logAwaitsFirstScan = true
        logRevision &+= 1
    }

    /// Every change to the log goes through here: `logRevision` moves and the
    /// file is written only when the durable content actually changed — a
    /// scan, a banner callback or a click that changed nothing publishes and
    /// writes nothing.
    func updateLog(immediately: Bool = false, _ change: (inout SessionLog) -> Void) {
        var next = sessionLog
        change(&next)
        guard !next.hasSameDurableState(as: sessionLog) else { return }
        sessionLog = next
        logRevision &+= 1
        sessionLogStore.write(next, immediately: immediately)
    }

    /// One scan's worth of history: identity moves, state edges, the waits.
    func recordScan(previous: [AgentRow], result: SnapshotBuilder.Result, nowMs: Int64) {
        // The first scan after launch closes what the last run left open, at
        // the moment that run last wrote — not now, which would claim the
        // hours Pulse was not running.
        var closeAt = nowMs
        if logAwaitsFirstScan {
            logAwaitsFirstScan = false
            let saved = sessionLog.savedAtMs
            if saved > 0, saved < nowMs { closeAt = saved }
        }
        let transitions = SessionTimeline.transitions(
            previous: previous, current: result.rows, remapped: result.remappedRowKeys, nowMs: nowMs
        )
        let live = Set(result.rows.map(\.rowKey))
        updateLog { log in
            for (old, new) in result.remappedRowKeys { log.remap(from: old, to: new) }
            log.applyTimeline(transitions)
            log.closeAbsent(liveKeys: live, atMs: closeAt)
            log.reconcileWaits(rows: result.rows, released: result.clearedPendingKeys, nowMs: nowMs)
            log.markBaseline()
            log.prune(nowMs: nowMs)
        }
    }

    /// The last hour of a session, when anything is known about it.
    func timelineStrip(for row: AgentRow) -> TimelineStripModel? {
        _ = logRevision
        let spans = sessionLog.spans(row.rowKey)
        guard !spans.isEmpty else { return nil }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        // Quantized to the minute so the strip does not redraw every second.
        let minute = (nowMs / 60_000) * 60_000
        return TimelineStripModel.make(spans: spans, nowMs: minute)
    }

    /// What happened to the banner for this row's latest wait. Reads
    /// `logRevision`, so a delivery outcome or a click that lands while the
    /// detail view is open redraws it.
    func notificationAudit(for row: AgentRow) -> NotificationAuditModel? {
        _ = logRevision
        guard let wait = sessionLog.latestWait(row.rowKey) else { return nil }
        return NotificationAuditModel.make(
            wait: wait, nowMs: Int64(Date().timeIntervalSince1970 * 1000), lang: lang
        )
    }

    /// The Activity log for the Health window.
    func activityLog(agent: AgentID?) -> ActivityLogModel {
        _ = logRevision
        return ActivityLogModel.make(
            log: sessionLog, rows: cachedAll, lang: lang,
            nowMs: Int64(Date().timeIntervalSince1970 * 1000), agentFilter: agent
        )
    }

    /// Agents that appear in the log, for its filter.
    var activityAgents: [AgentID] {
        _ = logRevision
        let agents = sessionLog.sessions.keys.compactMap(ActivityLogModel.agent(forKey:))
        return Array(Set(agents)).sorted { $0.displayName < $1.displayName }
    }
}
