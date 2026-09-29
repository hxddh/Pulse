import Foundation

/// 23.0 · the one record Pulse keeps of what each session did.
///
/// Until 23.0 four files overlapped: `attention-ledger.json` (each wait and
/// what became of its banner), `attention-history.json` (every hook line,
/// again), `session-timeline.json` (state spans) and `dismissed-pending.json`
/// (soft-dismissed waits) — plus in-memory copies of the same facts on the
/// store (`knownWaitingKeys`, a queue of frozen rows). Each could disagree
/// with the others, and several did: a queued banner for a wait that had
/// already resolved, spans left open across a restart forever, a click
/// credited to the wrong wait.
///
/// `SessionLog` is the single value. Per session key it holds:
///
/// - **spans** — the state the lamp would show, with the evidence that put
///   the session there;
/// - **waits** — one record per wait: when it was raised, what happened to
///   its banner (queued, the outcome, clicked), whether the person dismissed
///   it, when it resolved.
///
/// **What it stores, exactly.** Row keys, timestamps, states, wait kinds,
/// banner outcomes — and one bounded piece of text: the wait's `title`
/// (`AgentRow.usefulTask`, often the opening line of the user's prompt, at
/// most 160 characters), passed through `ContentSanitizer` on the way in.
/// No transcript bodies, no tool arguments, no paths (row keys hash any
/// path they are built from — `RowIdentity`).
///
/// Pure: every mutation returns whether anything durable changed, so the
/// store writes `session-log.json` (via `SessionLogStore`) only when it did.
struct SessionLog: Codable, Equatable, Sendable {
    /// 2 since row keys became stable (`RowIdentity`): a version-1 file's
    /// keys name rows that no longer exist, so it is not read.
    static let schemaVersion = 2
    static let maxSessions = 128
    static let maxSpansPerSession = 48
    /// Resolved waits kept per session (open waits are never evicted).
    static let maxWaitsPerSession = 16
    /// Closed spans and resolved waits are kept this long.
    static let retentionMs: Int64 = 24 * 60 * 60 * 1000
    static let titleLimit = 160

    struct Wait: Codable, Equatable, Sendable, Identifiable {
        /// `rowKey|scanMs` — what a banner carries, so a click lands on the
        /// wait it was posted for, not on whatever the row waits for now.
        var id: String
        var kind: String
        var title: String
        /// The evidence's own clock when there was one, else the scan's.
        var raisedMs: Int64
        /// The wait's own `sinceMs` as the evidence reported it (0 unknown),
        /// unclamped — what a later raise on the same key is compared with
        /// (`isNewRaise`). Absent in a log written before 23.0.
        var sinceMs: Int64?
        /// A banner was owed but not yet accepted (rate limit, authorization).
        var queuedMs: Int64?
        /// Notification Center accepted the banner.
        var notifiedMs: Int64?
        /// `posted`, `summary`, or a `WaitingDelivery.SkipReason` raw value.
        var outcome: String?
        var outcomeMs: Int64?
        var clickedMs: Int64?
        var dismissedMs: Int64?
        /// A soft dismissal: a harvest `pending` or vendor-reported wait the
        /// source keeps reporting. It stays suppressed until the source stops
        /// (the builder releases it) or a different wait takes the key.
        var holdsDismissal: Bool
        var resolvedMs: Int64?

        var isOpen: Bool { resolvedMs == nil }
        /// What a later raise on the same key is compared with: the
        /// evidence's own clock when it had one, else `raisedMs`.
        var raiseClockMs: Int64 {
            if let sinceMs, sinceMs > 0 { return sinceMs }
            return raisedMs
        }
        var suppresses: Bool { isOpen && dismissedMs != nil && holdsDismissal }
        var isQueued: Bool { isOpen && queuedMs != nil && notifiedMs == nil && dismissedMs == nil }
    }

    struct Session: Codable, Equatable, Sendable {
        var spans: [TimelineSpan] = []
        var waits: [Wait] = []

        var isEmpty: Bool { spans.isEmpty && waits.isEmpty }
        /// Present state, not history: an open span or an open wait.
        var isLive: Bool { spans.last.map { $0.endMs == nil } == true || waits.contains(where: \.isOpen) }

        func lastActivityMs(nowMs: Int64) -> Int64 {
            var newest: Int64 = 0
            for span in spans { newest = max(newest, span.endMs ?? nowMs) }
            for wait in waits { newest = max(newest, wait.resolvedMs ?? nowMs, wait.raisedMs) }
            return newest
        }

        func openWaitIndex() -> Int? { waits.lastIndex(where: \.isOpen) }
    }

    var schema = SessionLog.schemaVersion
    /// The first scan after a fresh install seeds without notifying.
    var baselineEstablished = false
    /// The global rate-limit anchor across every wait.
    var lastNotificationMs: Int64 = 0
    /// When this value was last written — stamped by `SessionLogStore`, used
    /// to close spans a quit left open. Not part of the durable compare.
    var savedAtMs: Int64 = 0
    var sessions: [String: Session] = [:]

    // MARK: - Queries

    func spans(_ key: String) -> [TimelineSpan] { sessions[key]?.spans ?? [] }

    func openWait(_ key: String) -> Wait? {
        guard let session = sessions[key], let index = session.openWaitIndex() else { return nil }
        return session.waits[index]
    }

    /// The newest wait for a key, open or resolved — its audit outlives it.
    func latestWait(_ key: String) -> Wait? { sessions[key]?.waits.last }

    private func keys(where predicate: (Wait) -> Bool) -> Set<String> {
        var out = Set<String>()
        for (key, session) in sessions where session.waits.contains(where: predicate) {
            out.insert(key)
        }
        return out
    }

    /// Keys waiting as of the last reconcile — the previous scan's edge set.
    var waitingKeys: Set<String> { keys { $0.isOpen && !$0.suppresses } }
    /// For each key in `waitingKeys`, when its open wait was raised
    /// (`Wait.raiseClockMs`) — the edge identity the builder compares a new
    /// raise with.
    var waitingSince: [String: Int64] {
        var out: [String: Int64] = [:]
        for (key, session) in sessions {
            guard let index = session.openWaitIndex() else { continue }
            let wait = session.waits[index]
            guard !wait.suppresses else { continue }
            out[key] = wait.raiseClockMs
        }
        return out
    }
    /// Soft-dismissed keys the builder must keep quiet.
    var suppressedKeys: Set<String> { keys { $0.suppresses } }
    /// Open waits whose banner is still owed.
    var queuedKeys: Set<String> { keys { $0.isQueued } }
    /// Open waits the person already dismissed.
    var dismissedKeys: Set<String> { keys { $0.isOpen && $0.dismissedMs != nil } }

    var waitCount: Int { sessions.values.reduce(0) { $0 + $1.waits.count } }

    func canDeliver(nowMs: Int64, minimumIntervalMs: Int64) -> Bool {
        lastNotificationMs == 0 || nowMs - lastNotificationMs >= minimumIntervalMs
    }

    /// Whether saving `self` would write anything `other` does not hold.
    func hasSameDurableState(as other: SessionLog) -> Bool {
        var mine = self
        mine.savedAtMs = other.savedAtMs
        return mine == other
    }

    static func title(for row: AgentRow) -> String {
        let title = row.usefulTask ?? AgentRow.shortProject(row.project.isEmpty ? row.cwd : row.project)
        return String(ContentSanitizer.redact(title).prefix(titleLimit))
    }

    /// The wait's own clock when it has a sane one, else the scan's.
    static func raisedMs(_ row: AgentRow, nowMs: Int64) -> Int64 {
        let since = row.wait?.sinceMs ?? 0
        return since > 0 && since <= nowMs ? since : nowMs
    }

    /// A raise closer than this to the previous one on the same key is the
    /// same ask said twice — Claude raises one approval as both a
    /// `Notification` and a `PermissionRequest`, in an order that is not
    /// ours — unless the session did something in between.
    static let reraiseSlackMs: Int64 = 20_000

    /// Whether the row's wait is a *new* raise on a key that was already
    /// waiting since `previousSinceMs`: a second permission, a new question.
    /// Only a hook or vendor raise carries a raise time; a harvest `pending`
    /// stamps the file's clock, which moves while the same ask stands. A
    /// later raise counts when the session moved after the old one (its
    /// next tool call is how a second ask begins) or when it is past the
    /// slack.
    static func isNewRaise(_ row: AgentRow, previousSinceMs: Int64) -> Bool {
        guard let wait = row.wait, wait.signal != .pending else { return false }
        let since = wait.sinceMs
        guard since > 0, previousSinceMs > 0, since > previousSinceMs else { return false }
        return row.activityMs > previousSinceMs || since - previousSinceMs > reraiseSlackMs
    }


    // MARK: - Spans

    /// Applies timeline transitions; returns whether anything changed.
    @discardableResult
    mutating func applyTimeline(_ transitions: [TimelineTransition]) -> Bool {
        var changed = false
        for t in transitions {
            var session = sessions[t.rowKey] ?? Session()
            var list = session.spans
            if let last = list.last, last.endMs == nil {
                // Restarting Pulse re-sees every row; an open span in the same
                // state is the same fact, not a new edge.
                if let state = t.state, last.state == state, last.evidence == t.evidence, last.kind == t.kind {
                    continue
                }
                list[list.count - 1].endMs = max(last.startMs, t.atMs)
            } else if t.state == nil {
                continue
            }
            if let state = t.state {
                let start = max(t.atMs, list.last?.endMs ?? t.atMs)
                list.append(TimelineSpan(
                    state: state, evidence: t.evidence, kind: t.kind,
                    startMs: start, endMs: nil, exact: t.exact
                ))
            }
            if list.count > Self.maxSpansPerSession {
                list.removeFirst(list.count - Self.maxSpansPerSession)
            }
            session.spans = list
            sessions[t.rowKey] = session
            changed = true
        }
        return changed
    }

    /// Closes the open span of every session not in `liveKeys`. A quit or a
    /// crash leaves spans open that no departure edge will ever close — the
    /// first scan after launch closes them at `atMs` (the last save), and
    /// every later scan keeps the invariant: only a present session is open.
    @discardableResult
    mutating func closeAbsent(liveKeys: Set<String>, atMs: Int64) -> Bool {
        var changed = false
        for (key, session) in sessions where !liveKeys.contains(key) {
            guard let last = session.spans.last, last.endMs == nil else { continue }
            var copy = session
            copy.spans[copy.spans.count - 1].endMs = max(last.startMs, atMs)
            sessions[key] = copy
            changed = true
        }
        return changed
    }

    /// 23.0 · the first scan after a launch. Every span the last run left
    /// open — present sessions included — closes at that run's last save
    /// (`savedAtMs`, stamped on every write and at quit), so the hours Pulse
    /// was not running are claimed by no state. Returns the scan's
    /// transitions with any that the evidence dates at or before that save
    /// moved to now: Pulse saw nothing in between.
    mutating func resumeAfterLaunch(
        _ transitions: [TimelineTransition], nowMs: Int64
    ) -> [TimelineTransition] {
        let saved = savedAtMs
        guard saved > 0, saved < nowMs else { return transitions }
        closeAbsent(liveKeys: [], atMs: saved)
        return transitions.map { t in
            guard t.state != nil, t.atMs <= saved else { return t }
            var moved = t
            moved.atMs = nowMs
            moved.exact = false
            return moved
        }
    }

    // MARK: - Waits

    /// Brings the wait records in line with this scan's rows. A key that is
    /// waiting has exactly one open wait; one that is not has none — except
    /// a soft dismissal, which stays open (and suppressing) until the builder
    /// reports it `released` or a new wait takes the key.
    @discardableResult
    mutating func reconcileWaits(rows: [AgentRow], released: Set<String>, nowMs: Int64) -> Bool {
        var waiting: [String: AgentRow] = [:]
        for row in rows where row.isBlocked && waiting[row.rowKey] == nil { waiting[row.rowKey] = row }
        var changed = false
        for (key, session) in sessions {
            var copy = session
            for index in copy.waits.indices where copy.waits[index].isOpen {
                let wait = copy.waits[index]
                let ends = wait.suppresses
                    ? released.contains(key) || waiting[key] != nil
                    : waiting[key] == nil
                if ends {
                    copy.waits[index].resolvedMs = max(wait.raisedMs, nowMs)
                }
            }
            if copy != session {
                sessions[key] = copy
                changed = true
            }
        }
        for (key, row) in waiting {
            var session = sessions[key] ?? Session()
            let title = Self.title(for: row)
            let kind = row.wait?.kind ?? ""
            if let index = session.openWaitIndex() {
                let open = session.waits[index]
                if Self.isNewRaise(row, previousSinceMs: open.raiseClockMs) {
                    // 23.0: a second ask on the same row is its own wait —
                    // its own banner, and no dismissal inherited from the
                    // first.
                    session.waits[index].resolvedMs = max(open.raisedMs, nowMs)
                    session.waits.append(Self.newWait(key: key, row: row, title: title, nowMs: nowMs))
                } else {
                    if open.title == title, open.kind == kind { continue }
                    session.waits[index].title = title
                    session.waits[index].kind = kind
                }
            } else {
                session.waits.append(Self.newWait(key: key, row: row, title: title, nowMs: nowMs))
            }
            sessions[key] = session
            changed = true
        }
        return changed
    }

    private static func newWait(key: String, row: AgentRow, title: String, nowMs: Int64) -> Wait {
        Wait(
            id: "\(key)|\(nowMs)", kind: row.wait?.kind ?? "", title: title,
            raisedMs: raisedMs(row, nowMs: nowMs), sinceMs: row.wait?.sinceMs,
            holdsDismissal: false
        )
    }

    private mutating func withOpenWait(_ key: String, _ body: (inout Wait) -> Bool) -> Bool {
        guard var session = sessions[key], let index = session.openWaitIndex() else { return false }
        guard body(&session.waits[index]) else { return false }
        sessions[key] = session
        return true
    }

    @discardableResult
    mutating func markQueued(_ key: String, nowMs: Int64) -> Bool {
        withOpenWait(key) { wait in
            guard wait.queuedMs == nil, wait.notifiedMs == nil else { return false }
            wait.queuedMs = nowMs
            return true
        }
    }

    @discardableResult
    mutating func markNotified(_ key: String, nowMs: Int64) -> Bool {
        let marked = withOpenWait(key) { wait in
            guard wait.notifiedMs == nil else { return false }
            wait.notifiedMs = nowMs
            return true
        }
        // The banner was shown even if its wait resolved meanwhile: the
        // rate-limit anchor moves either way.
        let anchored = nowMs > lastNotificationMs
        if anchored { lastNotificationMs = nowMs }
        return marked || anchored
    }

    /// The banner outcome for the key's open wait; the same outcome twice is
    /// not a change.
    @discardableResult
    mutating func markDelivery(_ key: String, outcome: String, nowMs: Int64) -> Bool {
        withOpenWait(key) { wait in
            guard wait.outcome != outcome else { return false }
            wait.outcome = outcome
            wait.outcomeMs = nowMs
            return true
        }
    }

    /// The person clicked the banner that carried `waitID` — that wait, open
    /// or resolved, and no other.
    @discardableResult
    mutating func markClicked(waitID: String, nowMs: Int64) -> Bool {
        for (key, session) in sessions {
            guard let index = session.waits.firstIndex(where: { $0.id == waitID }) else { continue }
            guard session.waits[index].clickedMs == nil else { return false }
            var copy = session
            copy.waits[index].clickedMs = nowMs
            sessions[key] = copy
            return true
        }
        return false
    }

    /// The person dismissed the row's wait. `soft` keeps it suppressed while
    /// its source keeps reporting it (harvest `pending`, `claude agents`).
    @discardableResult
    mutating func dismiss(_ row: AgentRow, soft: Bool, nowMs: Int64) -> Bool {
        let key = row.rowKey
        var session = sessions[key] ?? Session()
        let index: Int
        if let open = session.openWaitIndex() {
            index = open
        } else {
            guard row.isBlocked else { return false }
            session.waits.append(Self.newWait(key: key, row: row, title: Self.title(for: row), nowMs: nowMs))
            index = session.waits.count - 1
        }
        let before = session.waits[index]
        if session.waits[index].dismissedMs == nil { session.waits[index].dismissedMs = nowMs }
        if soft { session.waits[index].holdsDismissal = true }
        guard session.waits[index] != before else { return false }
        sessions[key] = session
        return true
    }

    @discardableResult
    mutating func markBaseline() -> Bool {
        guard !baselineEstablished else { return false }
        baselineEstablished = true
        return true
    }

    // MARK: - Bounds

    /// Drops closed spans and resolved waits older than the retention window,
    /// caps each session, and keeps at most `maxSessions` — never evicting a
    /// live one (an open span or wait is the present, not history).
    @discardableResult
    mutating func prune(nowMs: Int64) -> Bool {
        let before = sessions
        let cutoff = nowMs - Self.retentionMs
        for (key, session) in sessions {
            var copy = session
            copy.spans = copy.spans.filter { ($0.endMs ?? nowMs) >= cutoff }
            if copy.spans.count > Self.maxSpansPerSession {
                copy.spans.removeFirst(copy.spans.count - Self.maxSpansPerSession)
            }
            copy.waits = copy.waits.filter { ($0.resolvedMs ?? nowMs) >= cutoff }
            let resolved = copy.waits.filter { !$0.isOpen }
            if resolved.count > Self.maxWaitsPerSession {
                let drop = Set(resolved.prefix(resolved.count - Self.maxWaitsPerSession).map(\.id))
                copy.waits.removeAll { !$0.isOpen && drop.contains($0.id) }
            }
            sessions[key] = copy.isEmpty ? nil : copy
        }
        if sessions.count > Self.maxSessions {
            let live = sessions.filter { $0.value.isLive }.map { $0.key }
            let rest = sessions
                .filter { !$0.value.isLive }
                .sorted { ($0.value.lastActivityMs(nowMs: nowMs), $0.key) > ($1.value.lastActivityMs(nowMs: nowMs), $1.key) }
                .prefix(max(0, Self.maxSessions - live.count))
                .map { $0.key }
            let keep = Set(live + rest)
            sessions = sessions.filter { keep.contains($0.key) }
        }
        return sessions != before
    }
}
