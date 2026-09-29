import Foundation
import PulseCore

package enum ActivityHarvest {
    package enum CollectorState: String, Equatable {
        case observed
        /// Fixture-only state kept so an isolated fixture can still be
        /// diagnosed instead of discarded.
        case noRecentData = "no_recent_data"
        case sourceAbsent = "source_absent"
        case noSessions = "no_sessions"
        case permissionDenied = "permission_denied"
        case schemaMismatch = "schema_mismatch"
        case failed
        /// The process ended before this adapter reported a result.
        case unscanned

        package var isIssue: Bool {
            switch self {
            case .permissionDenied, .schemaMismatch, .failed:
                return true
            case .observed, .noRecentData, .sourceAbsent, .noSessions, .unscanned:
                return false
            }
        }
    }

    /// One adapter explaining its own bounded pass.
    ///
    /// Counts and fixed tags only. It exists so "the hero is empty" stops
    /// being a mystery that costs a release to diagnose: it says how much the
    /// adapter actually read, whether the window was truncated, how many facts
    /// the parsers produced, what kind of record the hero came from, and — when
    /// there is no hero — which layer lost it. It is diagnostic output, never
    /// a tray fact, and it carries no titles, prompts or vendor paths.
    package struct CollectorExplain: Equatable {
        /// Files the bounded walk actually opened.
        package var filesRead = 0
        /// Bytes reserved from the scan budget for this adapter.
        package var bytesRead = 0
        /// At least one file was larger than its window and was read head+tail,
        /// so counts derived from the text are floors, not totals.
        package var truncated = false
        /// Facts the parsers produced before merge.
        package var factsParsed = 0
        /// What kind of record produced the best row's hero title.
        package var heroOrigin = ""
        /// Which layer lost the hero, when there is none.
        package var emptyReason = ""

        package init(
            filesRead: Int = 0,
            bytesRead: Int = 0,
            truncated: Bool = false,
            factsParsed: Int = 0,
            heroOrigin: String = "",
            emptyReason: String = ""
        ) {
            self.filesRead = filesRead
            self.bytesRead = bytesRead
            self.truncated = truncated
            self.factsParsed = factsParsed
            self.heroOrigin = heroOrigin
            self.emptyReason = emptyReason
        }

        package var isEmpty: Bool { self == CollectorExplain() }

        /// `files=3 bytes=41k facts=7 hero=user_prompt` — support-report line.
        package var summary: String {
            var bits: [String] = []
            if filesRead > 0 { bits.append("files=\(filesRead)") }
            if bytesRead > 0 { bits.append("bytes=\(bytesRead / 1024)k") }
            if truncated { bits.append("truncated") }
            if factsParsed > 0 { bits.append("facts=\(factsParsed)") }
            if !heroOrigin.isEmpty { bits.append("hero=\(heroOrigin)") }
            if !emptyReason.isEmpty { bits.append("empty=\(emptyReason)") }
            return bits.isEmpty ? "-" : bits.joined(separator: " ")
        }
    }

    package struct CollectorHealth: Equatable {
        package var id: AgentID
        package var state: CollectorState
        package var durationMs: Int
        package var rowCount: Int
        package var sourcePresent: Bool
        /// Exception type only; vendor paths and exception messages never
        /// leave the diagnostic log.
        package var errorKind: String
        /// How this adapter reached the result above. Diagnostic only.
        package var explain: CollectorExplain = CollectorExplain()
        /// 2.9 · which fact classes this adapter actually produced this
        /// scan. The declared tier (`harvestSource`) is a promise; this is
        /// the measurement, and Support Health shows both so "the agent is
        /// idle" and "Pulse stopped seeing" stop wearing the same clothes.
        package var factClasses: Set<String> = []

        package init(
            id: AgentID,
            state: CollectorState,
            durationMs: Int,
            rowCount: Int,
            sourcePresent: Bool,
            errorKind: String,
            explain: CollectorExplain = CollectorExplain(),
            factClasses: Set<String> = []
        ) {
            self.id = id
            self.state = state
            self.durationMs = durationMs
            self.rowCount = rowCount
            self.sourcePresent = sourcePresent
            self.errorKind = errorKind
            self.explain = explain
            self.factClasses = factClasses
        }

        /// Declared structured, produced rows — and none of the core classes
        /// came out. The honest reading is drift (a vendor format change),
        /// not idleness: an idle structured session still yields its task.
        package var looksDrifted: Bool {
            state == .observed
                && id.harvestSource == .structuredSession
                && factClasses.intersection(["task", "tool", "tokens"]).isEmpty
        }

        package static func unscanned(_ id: AgentID) -> CollectorHealth {
            CollectorHealth(
                id: id,
                state: .unscanned,
                durationMs: 0,
                rowCount: 0,
                sourcePresent: false,
                errorKind: ""
            )
        }
    }

    /// 2.9 · the measurement measuring itself: which classes of fact a set
    /// of rows actually carries. Names only, never values — this feeds the
    /// support surface, not telemetry.
    package static func factClasses(of rows: [Row]) -> Set<String> {
        var classes: Set<String> = []
        for row in rows {
            if !row.task.isEmpty { classes.insert("task") }
            if !row.tool.isEmpty { classes.insert("tool") }
            if row.tokensIn > 0 || row.tokensOut > 0 {
                classes.insert("tokens")
            }
            if row.progressTotal > 0 { classes.insert("progress") }
            if !row.planStep.isEmpty || !row.planSteps.isEmpty { classes.insert("plan") }
            if !row.lastWord.isEmpty { classes.insert("word") }
            if !row.lastErrorText.isEmpty || row.errors > 0 {
                classes.insert("error")
            }
            if !row.model.isEmpty { classes.insert("model") }
            if !row.cwd.isEmpty { classes.insert("workspace") }
        }
        return classes
    }

    /// One item of the agent's own plan (2.8). `text` is sanitized and
    /// bounded at parse time; `state` is the vendor's word, mapped — never
    /// inferred from position or from anything else on the row.
    package struct PlanStep: Equatable, Hashable {
        package enum State: Int, Equatable, Hashable {
            case pending
            case current
            case done
        }

        package var text: String
        package var state: State

        package init(text: String, state: State) {
            self.text = text
            self.state = state
        }
    }

    package struct Row {
        package var id: AgentID
        package var task: String
        package var project: String
        package var cwd: String
        package var skill: String
        package var tokensIn: Int = 0
        package var tokensOut: Int = 0
        package var tool: String = ""
        package var harvestMs: Int64 = 0
        package var subRunning: Int = 0
        package var subTotal: Int = 0
        package var sessionID: String = ""
        /// Records in the session file — how much has actually happened.
        ///
        /// Records, not conversational turns: a transcript interleaves user
        /// messages, assistant messages, tool calls, tool results and token
        /// events. 0.28.0 labelled this "turns", which overclaimed.
        package var records: Int = 0
        /// When the session started, so a row can say how long it has been going.
        package var startedMs: Int64 = 0
        /// Runtime evidence tier emitted by the collector.
        package var evidence: ObservationSource = .cache
        /// Structured workflow and capability facts. Empty/0 always means
        /// unknown; the UI never invents them for process-only detection.
        package var phase: String = ""
        package var outcome: String = ""
        package var model: String = ""
        package var mode: String = ""
        package var errors: Int = 0
        package var progressDone: Int = 0
        package var progressTotal: Int = 0
        /// 2.8 · the agent's own plan, read from the structure it writes for
        /// itself (Claude's TodoWrite, Codex's update_plan) — the latest one
        /// in the window, because a plan is a state, not an event. All of it
        /// is self-report: the same epistemic tier as `task` and `tool`,
        /// sanitized the same way, and never a source of Waiting.
        ///
        /// The current step's text (`activeForm` when the vendor provides
        /// one, else the in-progress item's content). Empty when every item
        /// is done — a finished list has no "current" and we do not invent
        /// one.
        package var planStep: String = ""
        /// The whole checklist, bounded — Details only, never the tray line.
        package var planSteps: [PlanStep] = []
        /// The first line of the latest assistant message: what the agent
        /// just said, which is the cheapest honest answer to "is it going
        /// well". Empty when the window holds no assistant text.
        package var lastWord: String = ""
        /// The first line of the latest failed tool result. An error count
        /// without the error's text tells the user "something broke, go
        /// guess".
        package var lastErrorText: String = ""
        /// The `cwd` above was reconstructed from a vendor directory name
        /// that encodes `/` as `-`, and the filesystem could not confirm it.
        ///
        /// Claude and Pi both name a project directory `-Users-me-my-project`,
        /// which is `/Users/me/my-project` and `/Users/me/my/project` at the
        /// same time — the encoding does not escape a literal `-`. The
        /// decoder now settles the ambiguity against the disk; when nothing
        /// it tries exists, the naive decode is kept for display only and
        /// this flag says so. **Never land Focus on a best-effort cwd**: the
        /// wrong workspace opening under someone's hands is the failure this
        /// exists to prevent.
        package var cwdBestEffort: Bool = false
        /// 4.0-α · the transcript file this row's facts were read from —
        /// a local read handle for showing the session itself.
        ///
        /// Set only for structured JSONL session sources. Deliberately NOT
        /// sanitized (it is a filesystem path used to open the file, never
        /// rendered), and it never travels: not onto the tray, not out of
        /// the machine in any channel.
        package var transcriptPath: String = ""

        /// Whether the vendor said this run reached a terminal state.
        ///
        /// Whole tokens, never substrings. `state.contains("complete")` read
        /// **`incomplete`** as completed — the exact inversion of the fact,
        /// and the one direction that matters: a row that says "done" about a
        /// run still going is worse than saying nothing. Splitting on every
        /// non-alphanumeric keeps the shapes vendors actually write
        /// (`turn_complete`, `task_complete`, `completed`, `cancelled`,
        /// `failed`) matching, while `incomplete` stays a single token that
        /// matches none of them. An explicit negation anywhere in the pair
        /// vetoes the whole thing, so `not_completed` cannot slip through the
        /// same door from the other side.
        package var isCompleted: Bool {
            let tokens = "\(phase) \(outcome)"
                .lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
            let negations: Set<String> = ["not", "never"]
            guard !tokens.contains(where: { negations.contains($0) }) else { return false }
            let terminal: Set<String> = [
                "complete", "completed", "cancelled", "canceled", "failed",
            ]
            return tokens.contains(where: { terminal.contains($0) })
        }
    }

    /// Harvest-only rows older than this are dropped unless a live process exists.
    package static let freshWindowMs: Int64 = 45 * 60 * 1000
    /// Cursor's local composer store is authoritative session history, but it
    /// is not updated continuously while the persistent GUI process is alive.
    /// Keep named, non-draft local sessions visible for a bounded work window
    /// without treating the Cursor application itself as running evidence.
    package static let cursorLocalWindowMs: Int64 = 6 * 60 * 60 * 1000
    /// The native scan reports one health result for every user-facing
    /// adapter. Cursor Agent is intentionally merged into Cursor, so it has no
    /// separate collector line. This set lets the app distinguish a complete
    /// scan from a partial result without relying on row count (which may
    /// legitimately be zero for an installed but idle Agent).
    package static let expectedCollectorIDs: Set<AgentID> = Set(
        AgentID.allCases.filter { $0 != .cursorAgent }
    )

    package static func isCompleteHealth(_ health: [CollectorHealth]) -> Bool {
        let reported = Set(health.map { $0.id.surfaceID })
        // A full list of IDs is not enough: the native scanner intentionally
        // emits an explicit `.unscanned` line when its global budget/deadline
        // expires. Treat that result as partial so SnapshotBuilder can retain
        // the previous evidence for the adapters it never reached.
        let hasIncomplete = health.contains { item in
            // Cursor Agent is a transport alias of Cursor, not an additional
            // public collector. An alias health line appended after the real
            // Cursor result must not make an otherwise complete surface scan
            // look partial.
            guard item.id.surfaceID == item.id else { return false }
            switch item.state {
            case .failed, .schemaMismatch, .unscanned:
                return true
            case .observed, .noRecentData, .sourceAbsent, .noSessions, .permissionDenied:
                return false
            }
        }
        return expectedCollectorIDs.isSubset(of: reported) && !hasIncomplete
    }

    /// Keep the last known rows for adapters that a timed-out harvest never
    /// reached. A partial stream is useful evidence, but treating it as a
    /// complete snapshot makes every late adapter disappear for one or more
    /// probe cycles (and can make an active session look process-only). Health
    /// lines are the adapter boundary: a reported `no_sessions` result clears
    /// that adapter's old rows, while an unreported adapter retains them until
    /// the next complete scan.
    package static func mergePartialRows(
        current: [Row],
        health: [CollectorHealth],
        previous: [Row]
    ) -> [Row] {
        let normalize: (AgentID) -> AgentID = { $0.surfaceID }
        // An adapter that explicitly failed without yielding a row did not
        // produce a trustworthy replacement. Keep its last good rows until
        // the next successful/empty result, while still replacing an adapter
        // when it returned a partial row set alongside the failure.
        var reported = Set(health.compactMap { item -> AgentID? in
            // An empty issue result is not a trustworthy replacement. This
            // covers a per-agent timeout/lock/corrupt source, an explicit
            // permission or schema failure, and adapters the global deadline
            // never reached. Keeping the last good rows is what makes a
            // partial scan non-destructive; only a valid empty result such as
            // source_absent/no_sessions is allowed to clear that adapter.
            switch item.state {
            case .failed, .permissionDenied, .schemaMismatch, .unscanned:
                return item.rowCount > 0 ? normalize(item.id) : nil
            case .observed, .noRecentData, .sourceAbsent, .noSessions:
                return normalize(item.id)
            }
        })
        // An adapter may emit a row before its health line. Treat that row's
        // adapter as reached rather than retaining a stale duplicate beside
        // the fresh evidence.
        reported.formUnion(current.map { normalize($0.id) })
        guard !reported.isEmpty else { return previous }

        // An adapter that failed *after* yielding some rows — Codex timing
        // out after 3 of 10 sessions — reached only part of its sessions.
        // Replacing its whole set with that part made the other 7 vanish for
        // a tick. Its fresh rows win; its unreached sessions keep their last
        // good row. Only a session id can say "the same session", so rows
        // without one are not carried.
        let partial = Set(health.compactMap { item -> AgentID? in
            switch item.state {
            case .failed, .permissionDenied, .schemaMismatch, .unscanned:
                return item.rowCount > 0 ? normalize(item.id) : nil
            case .observed, .noRecentData, .sourceAbsent, .noSessions:
                return nil
            }
        })
        let fresh = Set(current.map { "\(normalize($0.id).rawValue)|\($0.sessionID)" })
        let retained = previous.filter { row in
            let agent = normalize(row.id)
            if !reported.contains(agent) { return true }
            guard partial.contains(agent), !row.sessionID.isEmpty else { return false }
            return !fresh.contains("\(agent.rawValue)|\(row.sessionID)")
        }
        return dedupeSharedRoots(current + retained)
    }

    /// Cascade and Windsurf read the same `~/.windsurf` tree — one session,
    /// never two lamps (0.95 "Extinguish Honesty").
    ///
    /// That rule used to live inside one complete scan, which is the one case
    /// where it was never needed. Three ordinary paths walk around it: the
    /// adapter cursor rotates and only one of the pair gets a turn, the
    /// supervisor trips a collector, or the store asks for a scoped rescan.
    /// In all three, this pass's fresh Windsurf rows meet the *retained*
    /// Cascade rows — after the in-scan check has already run — and the same
    /// pending session lights twice. The check therefore belongs here, on the
    /// union the tray actually receives, and the collector keeps its own copy
    /// only so its health lines stay consistent with the rows it reports.
    package static func dedupeSharedRoots(_ rows: [Row]) -> [Row] {
        guard rows.contains(where: { $0.id.surfaceID == .cascade }) else { return rows }
        return rows.filter { $0.id.surfaceID != .windsurf }
    }

    package static func mapAgent(_ raw: String) -> AgentID? {
        AgentCatalog.agent(named: raw)
    }

    /// Whether a harvest row may appear without a matching live process.
    package static func isFresh(_ row: Row, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> Bool {
        if row.subRunning > 0 { return true }
        // Missing mtime is not trustworthy as a standalone running signal.
        guard row.harvestMs > 0 else { return false }
        let window = row.id.surfaceID == .cursor && row.mode == "local"
            ? cursorLocalWindowMs
            : freshWindowMs
        let age = nowMs - row.harvestMs
        // A vendor clock can be a little ahead of the host, but an arbitrarily
        // future timestamp is not evidence of a live session. Without the
        // lower bound, a corrupted/future mtime stayed fresh forever.
        return age >= -5 * 60 * 1000 && age <= window
    }

    /// The native collector reports partial results through
    /// `complete`/`CollectorHealth` rather than by failing the whole scan.
    package static func scan(
        allowAppData: Bool = false,
        appDataAgents: Set<AgentID> = [],
        agentFilter: Set<AgentID>? = nil,
        startCursor: Int = 0
    ) -> (
        rows: [Row],
        health: [CollectorHealth],
        complete: Bool,
        nextCursor: Int
    ) {
        // The only collector. Until 0.99 a second, Python implementation sat
        // behind `PULSE_LEGACY_PYTHON_HARVEST`; it never ran for a user, could
        // not catch a native regression, and its gate was documented as if it
        // did — which is how four consecutive releases shipped a wrong tray
        // hero with CI green. It is gone; there is one path to be honest about.
        let native = NativeActivityHarvest.scan(
            allowAppData: allowAppData,
            appDataAgents: appDataAgents,
            agentFilter: agentFilter,
            startCursor: startCursor
        )
        DebugLog.write(
            "native harvest rows=\(native.rows.count) adapters=\(native.health.count) "
                + "complete=\(native.complete) appData=\(allowAppData) "
                + "cursor=\(startCursor)->\(native.nextCursor)"
        )
        // One line per adapter that read something or explained an empty
        // result. This is the record that turns "the tray hero is blank" into
        // a one-paste bug report instead of a guess and another release.
        for item in native.health where !item.explain.isEmpty {
            DebugLog.write("harvest explain \(item.id.rawValue) \(item.explain.summary)")
        }
        return (native.rows, native.health, native.complete, native.nextCursor)
    }
}

/// Attention TSV reader — last event wins per (agent, session); `done` clears;
/// `turn` ends a blocked wait (after a short grace) and leaves "your turn".
///
/// `attention.tsv` is this Mac's own file: every line in it was raised here.
/// 22.0 removed the remote inbox (`attention.d/<host>.tsv`) and with it the
/// per-host keys, arrival clocks and "lost contact" rows. The protocol's
/// `host` column is ignored. Since 23.0 only complete v3 records (eight
/// columns) are read.
package enum AttentionReader {
    package static let ttlMs: Int64 = 30 * 60 * 1000
    /// A turn ending right after a blocked raise must not wipe it: the order
    /// of Claude's Notification, PermissionRequest and Stop is not ours.
    package static let stopGraceMs: Int64 = 20_000
    /// How far an event stamp may run ahead of now before it is refused —
    /// a skewed or malformed stamp must not become a permanent Waiting row.
    package static let clockFutureToleranceMs: Int64 = 5 * 60 * 1000

    package struct Entry {
        package var id: AgentID
        package var kind: String
        package var message: String
        package var tsMs: Int64
        package var session: String = ""
        package var cwd: String = ""
        /// v3 column 8: the prompt's window was frontmost when this was
        /// raised (`true`), was not (`false`), or nobody could tell (`nil`).
        package var front: Bool? = nil

        /// 16.0: "your turn" — the agent finished and is idle at its prompt.
        /// Never the red lamp.
        package var isTurn: Bool { kind == Kind.turn.label }
        /// Blocked on the user: permission, question, or unknown reason.
        package var isBlocking: Bool { !kind.isEmpty && !isTurn }

        /// Stable key for last-event-wins map.
        package var mapKey: String {
            let surfaceID = id.surfaceID
            return session.isEmpty ? surfaceID.rawValue : "\(surfaceID.rawValue)|\(session)"
        }
    }

    fileprivate enum Kind {
        case permission, question, waiting, turn, done, ignore

        static func parse(_ raw: String) -> Kind {
            // Only the protocol's own kinds light, clear or mark anything.
            // Unknown free text never becomes a red lamp.
            switch AttentionProtocol.kind(raw) {
            case .permission: return .permission
            case .question: return .question
            case .waiting: return .waiting
            case .turn: return .turn
            case .done: return .done
            case .subagentStart, .subagentStop, .none: return .ignore
            }
        }

        var label: String {
            switch self {
            case .permission: return "Permission"
            case .question: return "Input"
            case .waiting: return "Waiting"
            case .turn: return "Turn"
            case .done, .ignore: return ""
            }
        }
    }

    package static func load(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> [Entry] {
        AttentionIO.readSources().flatMap { parse($0.text, nowMs: nowMs) }
    }

    /// Pure TSV → entries. Split out from `load` so the last-event-wins,
    /// stop-grace and TTL rules are testable without touching the filesystem.
    package static func parse(_ text: String, nowMs: Int64) -> [Entry] {
        guard !text.isEmpty else { return [] }

        var byKey: [String: Entry] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let cols = AttentionProtocol.columns(of: line),
                  let parsedID = ActivityHarvest.mapAgent(cols[0]) else { continue }
            let id = parsedID.surfaceID
            let kind = Kind.parse(cols[1])
            let tsMs = Int64(cols[2]) ?? 0
            let message = ContentSanitizer.redact(cols[3])
            let session = cols[4]
            let cwd = ContentSanitizer.redact(cols[5])
            let mapKey = session.isEmpty ? id.rawValue : "\(id.rawValue)|\(session)"

            if kind == .ignore { continue }

            func siblingKeys() -> [String] {
                byKey.compactMap { key, entry in entry.id.surfaceID == id ? key : nil }
            }

            if kind == .done {
                if session.isEmpty {
                    for k in siblingKeys() { byKey[k] = nil }
                } else {
                    byKey[mapKey] = nil
                }
                continue
            }

            // A turn ending clears a blocked wait — unless that wait was
            // raised moments ago (see `stopGraceMs`) — and then says "your
            // turn" below, like any other raise. A session-less turn only
            // clears: with no session there is no row it could belong to.
            if kind == .turn {
                func shouldKeep(_ existing: Entry) -> Bool {
                    // Measured from the raise to *this turn line*, never to
                    // `nowMs`: the verdict is a function of the two lines, so
                    // re-reading the same file a minute later cannot flip a
                    // kept permission into a cleared one.
                    existing.isBlocking
                        && existing.tsMs > 0
                        && tsMs > 0
                        && tsMs - existing.tsMs < stopGraceMs
                }
                if session.isEmpty {
                    for k in siblingKeys() {
                        if let existing = byKey[k], shouldKeep(existing) { continue }
                        byKey[k] = nil
                    }
                    continue
                }
                if let existing = byKey[mapKey], shouldKeep(existing) { continue }
                byKey[mapKey] = nil
                // The user watched it finish: nothing is owed.
                if AttentionProtocol.parseFront(cols[7]) == true { continue }
            }

            // No stamp, a stamp from the future, or one past the TTL: a local
            // wait that expires is covered by the process probe, so it can
            // simply go.
            guard tsMs > 0 else { continue }
            if tsMs > nowMs + clockFutureToleranceMs { continue }
            if nowMs - tsMs > ttlMs { continue }
            var entry = Entry(
                id: id,
                kind: kind.label,
                message: message,
                tsMs: tsMs,
                session: session,
                cwd: cwd
            )
            entry.front = AttentionProtocol.parseFront(cols[7])
            // A later event with nothing to say must not erase what an earlier
            // one said. One approval makes Claude raise both `Notification`
            // and `PermissionRequest`, only one of them carries text, and
            // their order is not ours to control — last-write-wins alone
            // turned "Bash: npm run build" back into a bare "Permission".
            // Carrying the text forward can leave it attached to a newer kind
            // for the same waiting session; that is strictly more information
            // than the blank it replaces, and `done`/`stop` still clear it.
            if entry.message.isEmpty, let previous = byKey[mapKey], !previous.message.isEmpty {
                entry.message = previous.message
            }
            byKey[mapKey] = entry
        }
        return Array(byKey.values)
    }
}
