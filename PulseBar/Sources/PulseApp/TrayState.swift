import Foundation

/// The tray, as one pure value: the session book, the process table and the
/// transcript summaries in; every row, the lamp, the menu-bar title, the
/// counts, the Waiting edges and what was left out for age out.
///
/// `SessionBook` holds what the events said. `project` turns it into rows
/// (`sessionRows`: one per session worth showing, plus a process-only row for
/// each agent process no session has claimed) and then into the tray
/// (`assemble`: sort, window, lamp, title, census, edges). It never reads a
/// clock, a file or a setting — the `Context` carries all of them — so the
/// same world always projects the same way.
///
/// Time rules, said by `Explain`:
///
/// - a session whose pid is known stays in its state while the process
///   lives (an exit ends it); with no pid, a session quiet for `idleBoundMs`
///   is shown as recent — Pulse cannot tell it is still there;
/// - a turn is owed for `idleBoundMs`, then it is recent;
/// - a recent session (idle, ended, or past the bound) stays listed for
///   `recentWindowMs` after its last event, or while its process lives; then
///   it is counted as "older, not shown" for a day.
struct TrayState: Equatable {
    /// Rows shown before the "and N more" fold.
    static let maxVisibleRows = 12
    static let idleBoundMs: Int64 = 30 * 60 * 1000
    static let recentWindowMs: Int64 = 45 * 60 * 1000
    /// Hidden sessions are counted only within this window.
    static let staleHiddenWindowMs: Int64 = 24 * 60 * 60 * 1000
    /// A raise closer than this to the previous one on the same row is the
    /// same ask said twice — Claude raises one approval as both a
    /// `PermissionRequest` and a `Notification`, in an order that is not
    /// ours — unless the session did something in between.
    static let reraiseSlackMs: Int64 = 20_000

    /// Outside-world facts, captured once per projection.
    struct Context {
        var nowMs: Int64
        var lang: ResolvedLanguage = .en
        /// The terminal-automation setting: AppleScript landing steps allowed.
        var allowAutomation = false
        /// Seconds of silence that make a working session stalled; 0 off.
        var stalledSeconds: Double = AgentRow.stalledSeconds
        var maxVisibleRows: Int = TrayState.maxVisibleRows
        var showAllAgents = false
        /// The previous projection's open waits (`waitingSince`): a row not
        /// in it, or one whose wait is a new raise, is a Waiting edge.
        var previousWaits: [String: Int64] = [:]
    }

    /// Every row, in the tray's order (the visible window is
    /// `snapshot.rows`).
    var rows: [AgentRow] = []
    /// The glance, the menu-bar title and tooltip, the census, the window.
    var snapshot = PulseSnapshot()
    /// The tick's tier.
    var activity: ProbeSchedule.Activity = .empty
    /// When each open wait was raised, by row — the next projection's
    /// `previousWaits`.
    var waitingSince: [String: Int64] = [:]
    /// Rows that became blocked since the previous projection — reported,
    /// not acted on: `WaitNotifier` owns notification policy.
    var newlyBlocked: [AgentRow] = []
    /// `showAllAgents` after collapsing it when the list got short again.
    var showAllAgents = false

    /// The book, the processes and the transcripts, as the tray.
    static func project(
        book: SessionBook,
        processes: [AgentProcesses.Hit],
        summaries: [String: TranscriptSummary],
        context: Context
    ) -> TrayState {
        let found = sessionRows(book: book, processes: processes, summaries: summaries, context: context)
        return assemble(rows: found.rows, staleHidden: found.staleHidden, context: context)
    }

    // MARK: - Rows

    struct SessionRows: Equatable {
        var rows: [AgentRow] = []
        /// Sessions left out for age, per agent (last 24 h only).
        var staleHidden: [AgentID: Int] = [:]
    }

    /// One row per session worth showing, then one per agent process no
    /// session has claimed. Unsorted.
    static func sessionRows(
        book: SessionBook,
        processes: [AgentProcesses.Hit],
        summaries: [String: TranscriptSummary],
        context: Context
    ) -> SessionRows {
        let nowMs = context.nowMs
        var out = SessionRows()
        var claimed: [AgentID: [SessionBook.Session]] = [:]
        let byPid = Dictionary(processes.flatMap { hit in hit.family.map { ($0, hit) } }, uniquingKeysWith: { first, _ in first })

        for session in book.sessions.values.sorted(by: { $0.key < $1.key }) {
            let live = session.pid > 0 && !session.isEnded
            if !session.isEnded { claimed[session.agent, default: []].append(session) }
            var row = AgentRow(rowKey: session.key, agent: session.agent)
            row.sessionID = session.session
            row.attentionSession = session.session
            row.cwd = session.cwd
            row.project = AgentRow.shortProject(session.cwd)
            row.pid = Int(session.pid)
            row.liveProcess = live
            row.startedMs = session.startedMs
            row.lastEventMs = session.lastEventMs
            row.activityMs = session.activityMs
            row.source = .hooks
            row.state = state(of: session, nowMs: nowMs)
            row.stateSinceMs = stateSince(of: session, nowMs: nowMs)
            row.recentReason = recentReason(of: session)

            let visible = live || nowMs - session.lastEventMs <= recentWindowMs || !row.isRecent
            guard visible else {
                if nowMs - session.lastEventMs <= staleHiddenWindowMs {
                    out.staleHidden[session.agent, default: 0] += 1
                }
                continue
            }

            if let summary = summaries[session.transcript], !session.transcript.isEmpty {
                row.task = summary.title
                row.model = summary.model
                row.lastWord = summary.lastMessage
                row.lastErrorText = summary.lastError
            }
            if row.lastWord.isEmpty { row.lastWord = TranscriptSummaryReader.firstLine(session.message) }

            // How to reach it: the hook's landing handle first; the process
            // table fills only what the hook did not say.
            var landing = LandingHandle(session.landing)
            let hit = live ? byPid[session.pid] : nil
            if let hit {
                if landing.tty.isEmpty { landing.tty = LandingHandle.normalizeTTY(hit.tty) }
                if landing.term.isEmpty, hit.viaWarp { landing.term = "WarpTerminal" }
            }
            row.landing = landing
            row.landingPlan = LandingPlan.make(
                handle: landing, cwd: row.cwd, allowAutomation: context.allowAutomation,
                pid: live ? session.pid : 0, hostApp: hit?.hostApp
            )

            // Silence is evidence only from an agent whose hook reports
            // every tool call; the others are silent through every long turn.
            row.isStalled = row.state == .running
                && session.agent.reportsToolActivity
                && session.activityMs > 0
                && AgentRow.stalled(lastActivityMs: session.lastEventMs, nowMs: nowMs, threshold: context.stalledSeconds)
            out.rows.append(row)
        }

        for hit in processes {
            let sessions = claimed[hit.agent] ?? []
            let owned = sessions.contains { session in
                (session.pid > 0 && hit.family.contains(session.pid))
                    || (session.pid == 0 && !session.cwd.isEmpty && session.cwd == hit.cwd)
            }
            guard !owned else { continue }
            var row = AgentRow(rowKey: RowIdentity.process(agent: hit.agent, pid: Int(hit.pid)), agent: hit.agent)
            row.cwd = hit.cwd
            row.project = AgentRow.shortProject(hit.cwd)
            row.pid = Int(hit.pid)
            row.liveProcess = true
            row.landing = LandingHandle(
                tty: LandingHandle.normalizeTTY(hit.tty),
                term: hit.viaWarp ? "WarpTerminal" : ""
            )
            row.landingPlan = LandingPlan.make(
                handle: row.landing, cwd: row.cwd, allowAutomation: context.allowAutomation,
                pid: hit.pid, hostApp: hit.hostApp
            )
            row.startedMs = hit.startedMs
            row.stateSinceMs = hit.startedMs
            row.source = .process
            row.state = .processOnly
            out.rows.append(row)
        }
        return out
    }

    /// The row state for a session at `nowMs`.
    static func state(of session: SessionBook.Session, nowMs: Int64) -> RowState {
        let quiet = nowMs - session.lastEventMs > idleBoundMs
        let unknownPid = session.pid <= 0
        switch session.state {
        case .blocked(let block):
            if unknownPid, quiet { return .recent }
            return .blocked(RowWait(kind: waitKind(block.kind), ask: block.ask, sinceMs: block.sinceMs, inFront: block.inFront))
        case .working:
            if unknownPid, quiet { return .recent }
            return .running
        case .yourTurn(let since):
            if nowMs - since > idleBoundMs { return .recent }
            return .yourTurn(sinceMs: since)
        case .idle, .ended:
            return .recent
        }
    }

    /// Why a session projected as recent is: ended, at its prompt, or
    /// quiet past the idle bound with no process Pulse can see.
    static func recentReason(of session: SessionBook.Session) -> RecentReason {
        switch session.state {
        case .ended: return .ended
        case .idle, .yourTurn: return .atPrompt
        case .working, .blocked: return .quiet
        }
    }

    /// When the row entered the state `state(of:nowMs:)` gives: the
    /// session's own state clock, or — when a time rule moved it to recent —
    /// the moment the rule did.
    static func stateSince(of session: SessionBook.Session, nowMs: Int64) -> Int64 {
        switch (session.state, state(of: session, nowMs: nowMs)) {
        case (.yourTurn(let since), .recent): return since + idleBoundMs
        case (.blocked, .recent), (.working, .recent): return session.lastEventMs + idleBoundMs
        default: return session.stateSinceMs
        }
    }

    /// The protocol kind as the token `RowWait` carries (`L10n.waitKind`).
    static func waitKind(_ kind: AttentionKind) -> String {
        switch kind {
        case .permission: return "Permission"
        case .question: return "Input"
        default: return "Waiting"
        }
    }

    // MARK: - The tray

    /// Rows in, the tray out: sorted, windowed, the lamp, the title, the
    /// census and the Waiting edges.
    static func assemble(
        rows input: [AgentRow],
        staleHidden: [AgentID: Int] = [:],
        context: Context
    ) -> TrayState {
        var state = TrayState()
        // Waiting → active → stalled → recent; within Waiting the oldest
        // first (unknown last); a real title, a live process and agent
        // priority break ties; the key makes the order total, so the same
        // world always lists the same way.
        let all = input.sorted { a, b in
            if a.isBlocked != b.isBlocked { return a.isBlocked }
            let wa = a.wait?.sinceMs ?? 0, wb = b.wait?.sinceMs ?? 0
            if a.isBlocked, wa != wb {
                if wa == 0 { return false }
                if wb == 0 { return true }
                return wa < wb
            }
            if a.section != b.section { return a.section.rawValue < b.section.rawValue }
            let ta = a.usefulTask != nil, tb = b.usefulTask != nil
            if ta != tb { return ta }
            if a.liveProcess != b.liveProcess { return a.liveProcess }
            let ra = AgentID.priority.firstIndex(of: a.agent) ?? 999
            let rb = AgentID.priority.firstIndex(of: b.agent) ?? 999
            if ra != rb { return ra < rb }
            return a.rowKey < b.rowKey
        }

        state.rows = all
        state.showAllAgents = context.showAllAgents && all.count > context.maxVisibleRows
        state.snapshot = snapshot(rows: all, showAll: state.showAllAgents, staleHiddenByAgent: staleHidden, context: context)
        state.activity = activity(rows: all)
        for row in all {
            guard let wait = row.wait, state.waitingSince[row.rowKey] == nil else { continue }
            state.waitingSince[row.rowKey] = wait.sinceMs
        }
        // Edges — a key that was not waiting, or one whose wait is a new
        // raise (a second ask on the same row). Keys never change
        // (`RowIdentity`), so nothing has to follow one.
        state.newlyBlocked = all.filter { row in
            guard row.isBlocked else { return false }
            guard let previous = context.previousWaits[row.rowKey] else { return true }
            return isNewRaise(row, previousSinceMs: previous)
        }
        return state
    }

    /// Whether the row's wait is a *new* raise on a row that was already
    /// waiting since `previousSinceMs`: a second permission, a new question.
    /// A later raise counts when the session moved after the old one (its
    /// next tool call is how a second ask begins) or when it is past the
    /// slack.
    static func isNewRaise(_ row: AgentRow, previousSinceMs: Int64) -> Bool {
        guard let wait = row.wait else { return false }
        let since = wait.sinceMs
        guard since > 0, previousSinceMs > 0, since > previousSinceMs else { return false }
        return row.activityMs > previousSinceMs || since - previousSinceMs > reraiseSlackMs
    }

    /// The tick's tier. By row state, like the lamp and the header — a
    /// process with no session, or a finished turn, is not work in progress.
    static func activity(rows: [AgentRow]) -> ProbeSchedule.Activity {
        if rows.contains(where: \.isBlocked) { return .waiting }
        if rows.contains(where: { $0.state == .running }) { return .running }
        return rows.isEmpty ? .empty : .recent
    }

    /// The glance, the census, the tooltip and the lamp for a row list.
    private static func snapshot(
        rows all: [AgentRow],
        showAll: Bool,
        staleHiddenByAgent: [AgentID: Int],
        context: Context
    ) -> PulseSnapshot {
        let lang = context.lang
        let waitingRows = all.filter(\.isBlocked)
        let waitingCount = waitingRows.count
        let census = Census(rows: all)

        var snap = PulseSnapshot()
        snap.sectionTotals = [
            .needsYou: waitingCount,
            .running: all.filter { $0.section == .running }.count,
            .stalled: all.filter { $0.section == .stalled }.count,
            .recent: all.filter { $0.section == .recent }.count,
        ]
        window(rows: all, showAll: showAll, maxVisible: context.maxVisibleRows, into: &snap)

        // The lamp. Red when anything is blocked; orange only for a stalled
        // session; green for a running session; grey otherwise — a finished
        // turn is grey even while its process lives, and a process with no
        // session is grey, never orange and never green.
        if waitingCount > 0 {
            snap.glance = .waiting
        } else if census.stalled > 0 {
            snap.glance = .stalled
        } else if census.running > 0 {
            snap.glance = .running
        } else {
            snap.glance = .idle
        }

        // The menu bar carries a title only when something is blocked: how
        // many, and how long the oldest has waited. A wait younger than five
        // seconds says nothing the lamp has not.
        if waitingCount > 0 {
            let oldestStamp = waitingRows.compactMap { $0.wait?.sinceMs }.filter { $0 > 0 }.min()
            let oldest = oldestStamp.map { max(0, Double(context.nowMs - $0) / 1000.0) } ?? 0
            let raw = oldest > 0 ? DurationFormat.label(seconds: oldest, lang: lang) : ""
            let dur = raw == L10n.t(.durNow, lang) ? "" : raw
            snap.title = dur.isEmpty
                ? "\(waitingCount)"
                : GlanceTitle.fit("\(waitingCount) · \(dur)", "\(waitingCount)")
        }

        snap.headerTitle = census.summary(lang)

        // One sentence for the tooltip and VoiceOver: the rule that set the
        // lamp. The tray names the sessions.
        let rule = Explain.lampRule(rows: all, glance: snap.glance)
        snap.tooltip = Explain.lampSentence(rule, lang: lang)
        snap.lamp = LampFace.glance(snap.glance, processOnly: rule == .processOnly)
        snap.accessibilityLabel = snap.glance == .idle
            ? L10n.t(snap.glance.accessibilityKey, lang)
            : snap.tooltip
        snap.staleHidden = staleHiddenByAgent.values.reduce(0, +)
        snap.staleHiddenAgents = staleHiddenByAgent.keys.sorted {
            (AgentID.priority.firstIndex(of: $0) ?? 999) < (AgentID.priority.firstIndex(of: $1) ?? 999)
        }
        return snap
    }

    /// Every row counted once, by its state — the census VoiceOver announces.
    struct Census: Equatable {
        var blocked = 0
        var running = 0
        var stalled = 0
        var yourTurn = 0
        var processOnly = 0
        var recent = 0

        init(rows: [AgentRow]) {
            for row in rows {
                switch row.state {
                case .blocked: blocked += 1
                case .running: if row.isStalled { stalled += 1 } else { running += 1 }
                case .yourTurn: yourTurn += 1
                case .processOnly: processOnly += 1
                case .recent: recent += 1
                }
            }
        }

        /// "1 needs you · 2 running · 1 recent", or "No coding agents".
        func summary(_ lang: ResolvedLanguage) -> String {
            func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
            var bits: [String] = []
            if blocked > 0 { bits.append("\(blocked) \(t(blocked == 1 ? .waiting1 : .waitingN))") }
            if running > 0 { bits.append("\(running) \(t(.runningN))") }
            if stalled > 0 { bits.append("\(stalled) \(t(.stalledN))") }
            if yourTurn > 0 { bits.append("\(yourTurn) \(t(.yourTurnN))") }
            if processOnly > 0 { bits.append("\(processOnly) \(t(.processOnlyN))") }
            if recent > 0 { bits.append(recent == 1 ? t(.recent1) : "\(recent) \(t(.recentN))") }
            return bits.isEmpty ? t(.noAgents) : bits.joined(separator: " · ")
        }
    }

    /// Fold the row list down to what the tray shows.
    static func window(
        rows: [AgentRow],
        showAll: Bool,
        maxVisible: Int,
        into snap: inout PulseSnapshot
    ) {
        if showAll || rows.count <= maxVisible {
            snap.rows = rows
            snap.hiddenCount = 0
        } else {
            snap.rows = Array(rows.prefix(maxVisible))
            snap.hiddenCount = rows.count - maxVisible
        }
        snap.totalCount = rows.count
    }
}

/// Menu-bar title budget (EXPERIENCE: ≤ 8 display cells; CJK = 2).
enum GlanceTitle {
    static let maxCells = 8

    static func cells(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + (isWide($1) ? 2 : 1) }
    }

    static func fit(_ candidates: String...) -> String {
        for text in candidates where cells(text) <= maxCells {
            return text
        }
        return candidates.last ?? ""
    }

    private static func isWide(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F, 0x2329...0x232A, 0x2E80...0xA4CF,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE10...0xFE19,
             0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1F64F, 0x1F900...0x1F9FF:
            return true
        default:
            return false
        }
    }
}
