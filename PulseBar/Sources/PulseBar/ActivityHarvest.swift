import Foundation

enum ActivityHarvest {
    enum CollectorState: String, Equatable {
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

        var isIssue: Bool {
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
    struct CollectorExplain: Equatable {
        /// Files the bounded walk actually opened.
        var filesRead = 0
        /// Bytes reserved from the scan budget for this adapter.
        var bytesRead = 0
        /// At least one file was larger than its window and was read head+tail,
        /// so counts derived from the text are floors, not totals.
        var truncated = false
        /// Facts the parsers produced before merge.
        var factsParsed = 0
        /// What kind of record produced the best row's hero title.
        var heroOrigin = ""
        /// Which layer lost the hero, when there is none.
        var emptyReason = ""

        var isEmpty: Bool { self == CollectorExplain() }

        /// `files=3 bytes=41k facts=7 hero=user_prompt` — support-report line.
        var summary: String {
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

    struct CollectorHealth: Equatable {
        var id: AgentID
        var state: CollectorState
        var durationMs: Int
        var rowCount: Int
        var sourcePresent: Bool
        /// Exception type only; vendor paths and exception messages never
        /// leave the diagnostic log.
        var errorKind: String
        /// How this adapter reached the result above. Diagnostic only.
        var explain: CollectorExplain = CollectorExplain()

        static func unscanned(_ id: AgentID) -> CollectorHealth {
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

    struct Row {
        var id: AgentID
        var task: String
        var project: String
        var cwd: String
        var skill: String
        var tokensIn: Int = 0
        var tokensOut: Int = 0
        var tool: String = ""
        var harvestMs: Int64 = 0
        var subRunning: Int = 0
        var subTotal: Int = 0
        var sessionID: String = ""
        /// Records in the session file — how much has actually happened.
        ///
        /// Records, not conversational turns: a transcript interleaves user
        /// messages, assistant messages, tool calls, tool results and token
        /// events. 0.28.0 labelled this "turns", which overclaimed.
        var records: Int = 0
        /// When the session started, so a row can say how long it has been going.
        var startedMs: Int64 = 0
        /// Runtime evidence tier emitted by the collector.
        var evidence: ObservationSource = .cache
        /// Structured workflow and capability facts. Empty/0 always means
        /// unknown; the UI never invents them for process-only detection.
        var phase: String = ""
        var outcome: String = ""
        var model: String = ""
        var mode: String = ""
        var errors: Int = 0
        var files: Int = 0
        var contextPercent: Int = 0
        var progressDone: Int = 0
        var progressTotal: Int = 0
        /// 1.2 · from the session digest, which read the whole transcript.
        /// The same tool run back to back at the tail of the session.
        var loopTool: String = ""
        var loopCount: Int = 0
        /// Errors across the whole session, not just the read window.
        var sessionErrors: Int = 0
        /// `Edit 12 · Bash 5` — bounded, Details only.
        var toolSummary: String = ""
        /// 2.1 · the rest of what the digest already knew.
        ///
        /// 1.2 computed all of this and published three of them. The others
        /// were held behind the same `caughtUp` gate as `records`, so a long
        /// session still catching up — the one most worth watching — showed
        /// nothing at all. They travel now; `digestProgressPercent` and
        /// `digestCaughtUp` are how a row states its own completeness.
        ///
        /// Tokens for the **whole session**, summed as the digest read past
        /// them. Deliberately not the same thing as `tokensIn`/`tokensOut`
        /// above, which are the latest message's usage, and both are kept:
        /// "this turn cost 8k" and "this session has spent 900k" are two
        /// different questions.
        var sessionTokensIn: Int = 0
        var sessionTokensOut: Int = 0
        /// The last few vendor tool names in order, oldest first, ≤ 12.
        /// Names only — never an argument, a path, or a command.
        var recentTools: [String] = []
        /// How much of the transcript the digest has read, 0–100. 100 means
        /// the facts above cover the whole file.
        var digestProgressPercent: Int = 0
        /// Whether the digest has reached the end of the file.
        var digestCaughtUp: Bool = false
        /// Recent growth of the transcript in bytes per minute; 0 = unknown.
        var bytesPerMinute: Int = 0
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
        var cwdBestEffort: Bool = false
        /// When Pulse first folded this transcript (`digest.firstFoldedMs`).
        ///
        /// Separate from `startedMs`, which is the file's birth date: most
        /// adapters cannot get one (vendors rewrite, copy or compact their
        /// transcripts, and APFS birth times survive none of that), so this
        /// is the more reliable answer to "how long has this been going".
        var sessionStartedMs: Int64 = 0

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
        var isCompleted: Bool {
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
    static let freshWindowMs: Int64 = 45 * 60 * 1000
    /// Cursor's local composer store is authoritative session history, but it
    /// is not updated continuously while the persistent GUI process is alive.
    /// Keep named, non-draft local sessions visible for a bounded work window
    /// without treating the Cursor application itself as running evidence.
    static let cursorLocalWindowMs: Int64 = 6 * 60 * 60 * 1000
    /// The native scan reports one health result for every user-facing
    /// adapter. Cursor Agent is intentionally merged into Cursor, so it has no
    /// separate collector line. This set lets the app distinguish a complete
    /// scan from a partial result without relying on row count (which may
    /// legitimately be zero for an installed but idle Agent).
    static let expectedCollectorIDs: Set<AgentID> = Set(
        AgentID.allCases.filter { $0 != .cursorAgent }
    )

    static func isCompleteHealth(_ health: [CollectorHealth]) -> Bool {
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
    static func mergePartialRows(
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

        let retained = previous.filter { !reported.contains(normalize($0.id)) }
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
    static func dedupeSharedRoots(_ rows: [Row]) -> [Row] {
        guard rows.contains(where: { $0.id.surfaceID == .cascade }) else { return rows }
        return rows.filter { $0.id.surfaceID != .windsurf }
    }

    static func mapAgent(_ raw: String) -> AgentID? {
        if let id = AgentID(rawValue: raw) { return id }
        switch raw {
        case "cursor_agent": return .cursorAgent
        case "amazon_q", "amazon-q", "q": return .amazonQ
        case "continue": return .continue_
        case "zed_agent", "zed-agent": return .zedAgent
        case "warp_agent", "warp-agent": return .warpAgent
        case "auggie": return .augment
        case "windsurf-cascade": return .cascade
        case "kilo-code", "kilocode": return .kilo
        case "kiro-cli", "kiro-agent": return .kiro
        case "junie-cli": return .junie
        case "devin-cli": return .devin
        case "replit-agent": return .replit
        case "command-code", "commandcode", "cmd": return .commandCode
        case "factory", "factory-droid": return .droid
        case "kimi-code", "kimi_code": return .kimi
        case "antigravity-ide", "antigravity_ide": return .antigravity
        case "agy": return .antigravity
        case "z-code", "ZCode", "zcode-agent": return .zcode
        default: return nil
        }
    }

    static func sessionKey(id: AgentID, sessionID: String, project: String, cwd: String) -> String {
        let sid = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sid.isEmpty {
            let short = sid.count > 24 ? String(sid.prefix(12)) + "…" + String(sid.suffix(6)) : sid
            return "\(id.rawValue)|\(short)"
        }
        let short = AgentRow.shortProject(project)
        if !short.isEmpty { return "\(id.rawValue)|\(short)" }
        let leaf = (cwd as NSString).lastPathComponent
        if !leaf.isEmpty, leaf != "/" { return "\(id.rawValue)|\(leaf)" }
        return id.rawValue
    }

    /// Whether a harvest row may appear without a matching live process.
    static func isFresh(_ row: Row, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> Bool {
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

    /// `unreliable` → caller must keep lastGoodHarvest.
    ///
    /// Kept in the signature because a future adapter may need it; the native
    /// collector reports partial results through `complete`/`CollectorHealth`
    /// rather than by failing the whole scan.
    static func scan(
        allowAppData: Bool = false,
        appDataAgents: Set<AgentID> = [],
        agentFilter: Set<AgentID>? = nil,
        startCursor: Int = 0
    ) -> (
        rows: [Row],
        health: [CollectorHealth],
        unreliable: Bool,
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
        return (native.rows, native.health, false, native.complete, native.nextCursor)
    }
}

/// Attention TSV reader — last event wins per (agent, session); done clears; stop has short grace.
enum AttentionReader {
    static let ttlMs: Int64 = 30 * 60 * 1000
    /// How long a remote row stays visible after it went quiet.
    static let lostContactRetentionMs: Int64 = 2 * 30 * 60 * 1000
    /// Claude often emits idle_prompt then Stop; don't wipe Input/Permission for this long.
    static let stopGraceMs: Int64 = 20_000

    struct Entry {
        var id: AgentID
        var kind: String
        var message: String
        var tsMs: Int64
        var session: String = ""
        var cwd: String = ""
        /// Empty means this Mac. A named host is a machine Pulse cannot probe,
        /// cannot focus, and cannot ask whether the agent is still alive.
        var host: String = ""
        /// When the bytes reached this disk. Equal to `tsMs` for local events.
        var receivedAtMs: Int64 = 0
        /// The event's own clock disagreed with arrival badly enough that
        /// `tsMs` is not being used for age or ordering.
        var clockSuspect: Bool = false
        /// A remote wait nothing has refreshed inside the TTL. The lamp comes
        /// down — Pulse has no evidence it is still open — but the row stays,
        /// because "I stopped hearing from it" is not "it finished".
        var lostContact: Bool = false

        var isRemote: Bool { !host.isEmpty }

        /// The clock Pulse is willing to stand behind.
        var effectiveMs: Int64 { clockSuspect ? receivedAtMs : tsMs }

        /// Stable key for last-event-wins map. Two machines running the same
        /// agent are two different waits; merging them would let one host's
        /// `done` clear the other host's open permission.
        var mapKey: String {
            let surfaceID = id.surfaceID
            let base = session.isEmpty ? surfaceID.rawValue : "\(surfaceID.rawValue)|\(session)"
            return host.isEmpty ? base : "\(base)@\(host)"
        }
    }

    private enum Kind {
        case permission, idlePrompt, waiting, stop, done, ignore

        static func parse(_ raw: String) -> Kind {
            // Protocol v1: only canonical / aliased waiting+clear kinds light
            // or clear Waiting. Unknown free-text never becomes a red lamp.
            let normalized = AttentionProtocol.normalizeKind(raw)
            switch normalized {
            case "permission":
                return .permission
            case "idle_prompt":
                return .idlePrompt
            case "waiting":
                return .waiting
            case "stop":
                return .stop
            case "done":
                return .done
            case "subagent_start", "subagent_stop":
                return .ignore
            default:
                return .ignore
            }
        }

        var label: String {
            switch self {
            case .permission: return "Permission"
            case .idlePrompt: return "Input"
            case .waiting: return "Waiting"
            case .stop, .done, .ignore: return ""
            }
        }
    }

    /// Which clock an event's age may be measured against.
    enum ClockVerdict: Equatable {
        /// The event stamp is usable.
        case trustEvent
        /// The event stamp disagrees with arrival past the point of belief;
        /// measure from arrival instead and say so.
        case trustArrival
        /// Neither clock says anything — there is nothing to measure.
        case unusable
    }

    /// How far a remote stamp may run ahead of its own arrival before the
    /// machine's clock, rather than the event, is the thing in question.
    static let clockFutureToleranceMs: Int64 = 5 * 60 * 1000

    /// A remote machine's clock is not ours.
    ///
    /// Before 1.0 an event outside the tolerance was dropped, which was right
    /// for a local hook and wrong for a remote host: a box running 20 minutes
    /// off had *every* wait silently disappear, with nothing anywhere saying
    /// why. Arrival time is local and durable, so it can carry the event that
    /// the sender's clock cannot.
    static func clockVerdict(eventMs: Int64, arrivalMs: Int64, isRemote: Bool) -> ClockVerdict {
        if eventMs > 0, !isRemote {
            // Local: the old rule, unchanged. The caller still applies the
            // future tolerance and TTL.
            return .trustEvent
        }
        guard isRemote else { return .unusable }
        guard arrivalMs > 0 else {
            // No arrival stamp to fall back on.
            return eventMs > 0 ? .trustEvent : .unusable
        }
        guard eventMs > 0 else { return .trustArrival }
        if eventMs - arrivalMs > clockFutureToleranceMs { return .trustArrival }
        if arrivalMs - eventMs > ttlMs { return .trustArrival }
        return .trustEvent
    }

    static func load(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> [Entry] {
        // Each source is parsed on its own: one host's `done` must never clear
        // another host's open permission, and per-file parsing is what keeps
        // that true without a single rule anywhere saying so.
        AttentionIO.readSources().flatMap { source in
            parse(
                source.text,
                nowMs: nowMs,
                defaultHost: source.host,
                receivedAtMs: source.isLocal ? 0 : source.receivedAtMs
            )
        }
    }

    /// Pure TSV → entries. Split out from `load` so the last-event-wins,
    /// stop-grace and TTL rules are testable without touching the filesystem.
    ///
    /// `defaultHost` names the machine when a line does not (a remote box still
    /// running a v1 hook); `receivedAtMs` is when the bytes reached this disk,
    /// and is zero for events raised here.
    static func parse(
        _ text: String,
        nowMs: Int64,
        defaultHost: String = "",
        receivedAtMs: Int64 = 0
    ) -> [Entry] {
        guard !text.isEmpty else { return [] }

        var byKey: [String: Entry] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty || raw.hasPrefix("#") { continue }
            let cols = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 3,
                  let parsedID = ActivityHarvest.mapAgent(cols[0]) else { continue }
            let id = parsedID.surfaceID
            let kind = Kind.parse(cols[1])
            let tsMs = Int64(cols[2]) ?? 0
            let message = cols.count > 3 ? ContentSanitizer.redact(cols[3]) : ""
            let session = cols.count > 4 ? cols[4] : ""
            let cwd = cols.count > 5 ? ContentSanitizer.redact(cols[5]) : ""
            let named = cols.count > 6 ? AttentionProtocol.normalizeHost(cols[6]) : ""
            let host = named.isEmpty ? defaultHost : named
            let base = session.isEmpty ? id.rawValue : "\(id.rawValue)|\(session)"
            let mapKey = host.isEmpty ? base : "\(base)@\(host)"

            if kind == .ignore { continue }

            // Agent-level clears are scoped to the machine that sent them.
            // Matching by key prefix would let one host's `done` wipe another
            // host's open permission the moment both appear in one file.
            func siblingKeys() -> [String] {
                byKey.compactMap { key, entry in
                    entry.id.surfaceID == id && entry.host == host ? key : nil
                }
            }

            if kind == .done {
                if session.isEmpty {
                    for k in siblingKeys() { byKey[k] = nil }
                } else {
                    byKey[mapKey] = nil
                }
                continue
            }
            if kind == .stop {
                func shouldKeep(_ existing: Entry) -> Bool {
                    // `effectiveMs`, not the raw stamp: this is the same
                    // choice `clockVerdict` already made a few lines below,
                    // and the two must agree. A remote box whose clock runs
                    // half an hour behind produced a Permission the reader
                    // deliberately measured from arrival — and then the Stop
                    // that Claude emits right after it wiped that Permission
                    // instantly, because the grace window alone was still
                    // measured against the stamp everything else had refused
                    // to trust.
                    (existing.kind == "Permission" || existing.kind == "Input" || existing.kind == "Waiting")
                        && existing.effectiveMs > 0
                        && nowMs - existing.effectiveMs < stopGraceMs
                }
                if session.isEmpty {
                    for k in siblingKeys() {
                        if let existing = byKey[k], shouldKeep(existing) { continue }
                        byKey[k] = nil
                    }
                } else if let existing = byKey[mapKey], shouldKeep(existing) {
                    // keep
                } else {
                    byKey[mapKey] = nil
                }
                continue
            }

            // A clock-skewed or malformed hook event must not become a
            // permanent Waiting row. Activity rows use the same small future
            // tolerance; keep it consistent here.
            let arrival = receivedAtMs > 0 ? receivedAtMs : tsMs
            let clock = clockVerdict(
                eventMs: tsMs, arrivalMs: arrival, isRemote: !host.isEmpty
            )
            switch clock {
            case .unusable:
                continue
            case .trustEvent, .trustArrival:
                break
            }
            let suspect = clock == .trustArrival
            let effective = suspect ? arrival : tsMs
            if effective > nowMs + 5 * 60 * 1000 { continue }
            let expired = nowMs - effective > ttlMs
            // A local wait that expires is covered by the process probe, so it
            // can simply go. A remote one has no such witness: dropping it
            // silently would show "finished" when the only true statement is
            // "nothing has been heard since". Keep it and mark it lost.
            if expired && host.isEmpty { continue }
            // Lost contact is a statement worth showing, not a permanent one.
            // Past this window "nothing heard in over an hour" stops being news
            // and the row goes; the ledger keeps the history.
            if nowMs - effective > lostContactRetentionMs { continue }
            var entry = Entry(
                id: id,
                kind: kind.label,
                message: message,
                tsMs: tsMs,
                session: session,
                cwd: cwd
            )
            entry.host = host
            entry.receivedAtMs = arrival
            entry.clockSuspect = suspect
            entry.lostContact = expired
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
