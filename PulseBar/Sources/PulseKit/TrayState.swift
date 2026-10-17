import Foundation

/// The tray, as one pure value: the session book and the process table in;
/// every row, the lamp, the menu-bar title, the counts and the Waiting edges
/// out.
///
/// `SessionBook` holds what the events said. `project` turns it into rows
/// (`sessionRows`: one per session worth showing, plus a process-only row for
/// each agent process no session has claimed) and then into the tray
/// (`assemble`: sort, lamp, title, counts, edges). It never reads a clock, a
/// file or a setting — the `Context` carries all of them — so the same world
/// always projects the same value, and plain equality says "nothing moved":
/// a row carries its status, never a step or a clock that moves with every
/// tool line (those are `SessionFacts`, read at render time).
///
/// Time rules, said by the row's why (`TrayRowModel.why`):
///
/// - a session whose pid is known stays in its state while the process
///   lives (an exit ends it); with no pid, a session quiet for `idleBoundMs`
///   is shown as recent — Pulse cannot tell it is still there;
/// - a working session that has said nothing for `silentBoundMs` is recent
///   even while its process lives (an interrupted turn sends no Stop —
///   it is stalled for a while, never orange for ever);
/// - a turn is owed for `idleBoundMs`, then it is recent;
/// - a recent session (idle, ended, or past a bound) stays listed for
///   `recentWindowMs` after its last event, then it leaves the list. A live
///   process does not keep it listed:
///   one Cursor or OpenCode process runs many sessions all day.
package struct TrayState: Equatable {
    package static let idleBoundMs: Int64 = 30 * 60 * 1000
    package static let recentWindowMs: Int64 = 45 * 60 * 1000
    /// A working session with no event for this long is recent, whatever
    /// its process: past the stall, Pulse has no word from it at all.
    package static let silentBoundMs: Int64 = 2 * 60 * 60 * 1000
    /// A raise closer than this to the previous one on the same row is the
    /// same ask said twice — Claude raises one approval as both a
    /// `PermissionRequest` and a `Notification`, in an order that is not
    /// ours — unless the session did something in between.
    package static let reraiseSlackMs: Int64 = 20_000

    /// Outside-world facts, captured once per projection.
    package struct Context {
        package var nowMs: Int64
        package var lang: ResolvedLanguage = .en
        /// Seconds of silence that make a working session stalled; 0 off.
        package var stalledSeconds: Double = AgentRow.stalledSeconds
        /// The previous projection's open waits (`waitingSince`): a row not
        /// in it, or one whose wait is a new raise, is a Waiting edge.
        package var previousWaits: [SessionKey: Int64] = [:]

        package init(
            nowMs: Int64,
            lang: ResolvedLanguage = .en,
            stalledSeconds: Double = AgentRow.stalledSeconds,
            previousWaits: [SessionKey: Int64] = [:]
        ) {
            self.nowMs = nowMs
            self.lang = lang
            self.stalledSeconds = stalledSeconds
            self.previousWaits = previousWaits
        }
    }

    /// Every row, in the tray's order: the tray lists every session and
    /// scrolls.
    package var rows: [AgentRow] = []
    /// The lamp, the menu-bar title and tooltip, the counts.
    package var snapshot = PulseSnapshot()
    /// The tick's tier.
    package var activity: ProbeSchedule.Activity = .empty
    /// When each open wait was raised, by row — the next projection's
    /// `previousWaits`.
    package var waitingSince: [SessionKey: Int64] = [:]
    /// Rows that became blocked since the previous projection — reported,
    /// not acted on: `WaitNotifier` owns notification policy.
    package var newlyBlocked: [AgentRow] = []

    /// The book and the processes, as the tray.
    package static func project(
        book: SessionBook,
        processes: [AgentProcesses.Hit],
        context: Context
    ) -> TrayState {
        assemble(
            rows: sessionRows(book: book, processes: processes, context: context),
            context: context,
            activityMs: book.sessions.mapValues(\.activityMs)
        )
    }

    // MARK: - Rows

    /// One row per session worth showing, then one per agent process no
    /// session has claimed. Unsorted.
    package static func sessionRows(
        book: SessionBook,
        processes: [AgentProcesses.Hit],
        context: Context
    ) -> [AgentRow] {
        let nowMs = context.nowMs
        var out: [AgentRow] = []
        var claimed: [AgentID: [SessionBook.Session]] = [:]
        let byPid = Dictionary(processes.flatMap { hit in hit.family.map { ($0, hit) } }, uniquingKeysWith: { first, _ in first })

        for session in book.sessions.values.sorted(by: { $0.key < $1.key }) {
            let live = session.pid > 0 && !session.isEnded
            if !session.isEnded { claimed[session.agent, default: []].append(session) }
            let status = Self.status(of: session, nowMs: nowMs, stalledSeconds: context.stalledSeconds)

            // Only a session still working or blocked is kept by its
            // process; a recent one leaves after the window, live or not. A
            // silent one's window starts when it went silent — its last
            // event is already past the window by then.
            if case .recent(let reason) = status {
                let from = reason == .silent ? session.lastEventMs + silentBoundMs : session.lastEventMs
                guard nowMs - from <= recentWindowMs else { continue }
            }

            var row = AgentRow(key: session.key, status: status)
            row.session = session.session
            row.cwd = session.cwd
            row.pid = session.pid
            row.liveProcess = live
            row.task = session.shownTitle

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
                handle: landing, cwd: row.cwd,
                pid: live ? session.pid : 0, hostApp: hit?.hostApp
            )
            out.append(row)
        }

        for hit in processes {
            let sessions = claimed[hit.agent] ?? []
            let owned = sessions.contains { session in
                (session.pid > 0 && hit.family.contains(session.pid))
                    || (session.pid == 0 && !session.cwd.isEmpty && session.cwd == hit.cwd)
            }
            guard !owned else { continue }
            var row = AgentRow(key: .process(hit.agent, pid: hit.pid), status: .processOnly)
            row.cwd = hit.cwd
            row.pid = hit.pid
            row.liveProcess = true
            row.landing = LandingHandle(
                tty: LandingHandle.normalizeTTY(hit.tty),
                term: hit.viaWarp ? "WarpTerminal" : ""
            )
            row.landingPlan = LandingPlan.make(
                handle: row.landing, cwd: row.cwd,
                pid: hit.pid, hostApp: hit.hostApp
            )
            out.append(row)
        }
        return out
    }

    /// A session's status at `nowMs`: the book's state, moved by the time
    /// rules and the stall rule.
    package static func status(
        of session: SessionBook.Session,
        nowMs: Int64,
        stalledSeconds: Double = AgentRow.stalledSeconds
    ) -> AgentRow.Status {
        let quiet = nowMs - session.lastEventMs > idleBoundMs
        let unknownPid = session.pid <= 0
        switch session.state {
        case .blocked(let block):
            if unknownPid, quiet { return .recent(.quiet) }
            return .needsYou(block)
        case .working:
            if unknownPid, quiet { return .recent(.quiet) }
            if nowMs - session.lastEventMs > silentBoundMs { return .recent(.silent) }
            // Silence is evidence only from an agent whose hook reports
            // every tool call; the others are silent through every long turn.
            // A tool said to be running is silent until it ends.
            let stalled = session.agent.reportsToolActivity
                && session.toolMs > 0
                && session.running == nil
                && AgentRow.stalled(lastActivityMs: session.lastEventMs, nowMs: nowMs, threshold: stalledSeconds)
            return .running(stalled: stalled)
        case .yourTurn(let since):
            if nowMs - since > idleBoundMs { return .recent(.atPrompt) }
            return .yourTurn(sinceMs: since)
        case .idle:
            return .recent(.atPrompt)
        case .ended(let at):
            return .recent(.ended(atMs: at))
        }
    }

    // MARK: - The tray

    /// Rows in, the tray out: sorted, the lamp, the title, the counts and
    /// the Waiting edges. `activityMs`: each session's newest activity — a
    /// later raise on a row that was waiting is news when the session moved
    /// in between (`isNewRaise`).
    package static func assemble(
        rows input: [AgentRow],
        context: Context,
        activityMs: [SessionKey: Int64] = [:]
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
            if a.rank != b.rank { return a.rank < b.rank }
            let ta = a.usefulTask != nil, tb = b.usefulTask != nil
            if ta != tb { return ta }
            if a.liveProcess != b.liveProcess { return a.liveProcess }
            let ra = AgentID.priority.firstIndex(of: a.agent) ?? 999
            let rb = AgentID.priority.firstIndex(of: b.agent) ?? 999
            if ra != rb { return ra < rb }
            return a.key < b.key
        }

        state.rows = all
        state.snapshot = snapshot(rows: all, context: context)
        state.activity = activity(rows: all)
        for row in all {
            guard let wait = row.wait, state.waitingSince[row.key] == nil else { continue }
            state.waitingSince[row.key] = wait.sinceMs
        }
        // Edges — a key that was not waiting, or one whose wait is a new
        // raise (a second ask on the same row). Keys never change
        // (`SessionKey`), so nothing has to follow one.
        state.newlyBlocked = all.filter { row in
            guard let wait = row.wait else { return false }
            guard let previous = context.previousWaits[row.key] else { return true }
            return isNewRaise(sinceMs: wait.sinceMs, previousSinceMs: previous, activityMs: activityMs[row.key] ?? 0)
        }
        return state
    }

    /// Whether a wait raised at `sinceMs` is a *new* raise on a row that was
    /// already waiting since `previousSinceMs`: a second permission, a new
    /// question. A later raise counts when the session moved after the old
    /// one (its next tool call is how a second ask begins) or when it is
    /// past the slack.
    package static func isNewRaise(sinceMs: Int64, previousSinceMs: Int64, activityMs: Int64) -> Bool {
        guard sinceMs > 0, previousSinceMs > 0, sinceMs > previousSinceMs else { return false }
        return activityMs > previousSinceMs || sinceMs - previousSinceMs > reraiseSlackMs
    }

    /// The tick's tier. By row state, like the lamp and the header — a
    /// process with no session, or a finished turn, is not work in progress.
    package static func activity(rows: [AgentRow]) -> ProbeSchedule.Activity {
        if rows.contains(where: \.isBlocked) { return .waiting }
        if rows.contains(where: \.isRunning) { return .running }
        return rows.isEmpty ? .empty : .recent
    }

    /// The lamp, the menu-bar title, the tooltip and the counts for a row
    /// list.
    private static func snapshot(
        rows all: [AgentRow],
        context: Context
    ) -> PulseSnapshot {
        let lang = context.lang
        let counts = Counts(rows: all)

        var snap = PulseSnapshot(counts: counts, projected: true)

        // The menu bar carries a title only when something is blocked: how
        // many, and how long the oldest has waited ("2 · 4m"; "2·4分钟" when
        // the spaced form does not fit). A wait younger than a minute says
        // nothing the lamp has not.
        if counts.blocked > 0 {
            let count = "\(counts.blocked)"
            let oldest = all.compactMap { $0.wait?.sinceMs }.filter { $0 > 0 }.min()
            let seconds = oldest.map { Double(context.nowMs - $0) / 1000 } ?? 0
            let age = L10n.duration(seconds, lang)
            snap.title = seconds < 60 ? count : GlanceTitle.fit("\(count) · \(age)", "\(count)·\(age)", count)
        }

        // The lamp, and one sentence for the tooltip: the rule that set it —
        // red names who has waited longest. VoiceOver says the same for a
        // coloured lamp and the state in a word for a grey one.
        let rule = lampRule(counts: counts)
        snap.lamp = Lamp(rule)
        snap.tooltip = tooltip(rule, rows: all, counts: counts, nowMs: context.nowMs, lang: lang)
        snap.accessibilityLabel = snap.lamp.isGrey ? L10n.t(rule.accessibilityKey, lang) : snap.tooltip
        return snap
    }

    /// The status item's tooltip. Red names the wait that has gone on
    /// longest — "Red: Claude needs you — app · 8m. 1 more waiting. 2
    /// running." — the agent, its project and how long; every other rule is
    /// its sentence (`lampSentence`). A wait with no clock sorts last, as
    /// in the tray. Pure.
    package static func tooltip(_ rule: LampRule, rows: [AgentRow], counts: Counts, nowMs: Int64, lang: ResolvedLanguage) -> String {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        guard rule == .blocked else { return lampSentence(rule, lang: lang) }
        let waits = rows.filter(\.isBlocked)
        guard let longest = waits.min(by: { a, b in
            let x = a.wait?.sinceMs ?? 0, y = b.wait?.sinceMs ?? 0
            if x <= 0 { return false }
            if y <= 0 { return true }
            return x < y
        }) else { return lampSentence(rule, lang: lang) }
        var place: [String] = []
        if !longest.project.isEmpty { place.append(longest.project) }
        // Like the title: a wait younger than a minute says no time.
        if let since = longest.wait?.sinceMs, since > 0, nowMs - since >= 60_000 {
            place.append(L10n.duration(Double(nowMs - since) / 1000, lang))
        }
        let name = longest.agent.displayName
        var sentences = [place.isEmpty
            ? String(format: t(.lampTipBlockedBare), name)
            : String(format: t(.lampTipBlocked), name, place.joined(separator: " · "))]
        if counts.blocked > 1 { sentences.append(String(format: t(.lampTipMoreWaiting), counts.blocked - 1)) }
        if counts.running > 0 { sentences.append(String(format: t(.lampTipRunning), counts.running)) }
        return sentences.joined(separator: lang == .zh ? "" : " ")
    }

    // MARK: - The lamp's rule

    /// The rule that set the menu-bar lamp. The sentence names the rule;
    /// the tray names the sessions.
    package enum LampRule: String, Equatable, Sendable {
        case blocked, stalled, running, processOnly, yourTurn, recent, idle

        /// The state in a word, as VoiceOver says a grey lamp — your
        /// turn, process only, idle — and a coloured one.
        package var accessibilityKey: L10n.Key {
            switch self {
            case .blocked: return .a11yWaiting
            case .stalled: return .a11yStalled
            case .running: return .a11yRunning
            case .yourTurn: return .a11yYourTurn
            case .processOnly: return .a11yProcessOnly
            case .recent, .idle: return .a11yIdle
            }
        }
    }

    /// Red when anything is blocked; orange only for a stalled session;
    /// green for a running one; grey otherwise — and a grey lamp says the
    /// most useful thing that is true: a finished turn (grey even while its
    /// process lives), then a live process Pulse can only see from outside
    /// (never orange, never green), then recent sessions.
    package static func lampRule(counts: Counts) -> LampRule {
        if counts.blocked > 0 { return .blocked }
        if counts.stalled > 0 { return .stalled }
        if counts.running > 0 { return .running }
        if counts.yourTurn > 0 { return .yourTurn }
        if counts.processOnly > 0 { return .processOnly }
        if counts.recent > 0 { return .recent }
        return .idle
    }

    /// The one line the tooltip and VoiceOver say — the status item's whole
    /// tooltip.
    package static func lampSentence(_ rule: LampRule, lang: ResolvedLanguage) -> String {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        switch rule {
        case .blocked: return t(.lampRuleBlocked)
        case .stalled: return t(.lampRuleStalled)
        case .running: return t(.lampRuleRunning)
        case .processOnly: return t(.lampRuleProcessOnly)
        case .yourTurn: return t(.lampRuleTurn)
        case .recent: return t(.lampRuleRecent)
        case .idle: return t(.lampRuleIdle)
        }
    }

    /// Every row counted once, by its state — counted once per projection
    /// (`PulseSnapshot.counts`): the lamp, the menu-bar title, the header
    /// VoiceOver announces and the status item's flash all read it.
    package struct Counts: Equatable {
        package var blocked = 0
        package var running = 0
        package var stalled = 0
        package var yourTurn = 0
        package var processOnly = 0
        package var recent = 0

        package init(rows: [AgentRow] = []) {
            for row in rows {
                switch row.status {
                case .needsYou: blocked += 1
                case .running(let isStalled): if isStalled { stalled += 1 } else { running += 1 }
                case .yourTurn: yourTurn += 1
                case .processOnly: processOnly += 1
                case .recent: recent += 1
                }
            }
        }
    }
}

/// Menu-bar title budget (EXPERIENCE: ≤ 8 display cells; CJK = 2).
package enum GlanceTitle {
    package static let maxCells = 8

    package static func cells(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + (isWide($1) ? 2 : 1) }
    }

    package static func fit(_ candidates: String...) -> String {
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
