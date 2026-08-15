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

        var isCompleted: Bool {
            let state = "\(phase) \(outcome)"
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return state.contains("turn_complete")
                || state.contains("completed")
                || state.contains("complete")
                || state.contains("cancelled")
                || state.contains("canceled")
                || state.contains("failed")
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
        return current + retained
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
    /// Claude often emits idle_prompt then Stop; don't wipe Input/Permission for this long.
    static let stopGraceMs: Int64 = 20_000

    struct Entry {
        var id: AgentID
        var kind: String
        var message: String
        var tsMs: Int64
        var session: String = ""
        var cwd: String = ""

        /// Stable key for last-event-wins map.
        var mapKey: String {
            let surfaceID = id.surfaceID
            return session.isEmpty ? surfaceID.rawValue : "\(surfaceID.rawValue)|\(session)"
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

    static func load(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> [Entry] {
        parse(AttentionIO.readText(), nowMs: nowMs)
    }

    /// Pure TSV → entries. Split out from `load` so the last-event-wins,
    /// stop-grace and TTL rules are testable without touching the filesystem.
    static func parse(_ text: String, nowMs: Int64) -> [Entry] {
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
            let mapKey = session.isEmpty ? id.rawValue : "\(id.rawValue)|\(session)"

            if kind == .ignore { continue }

            if kind == .done {
                if session.isEmpty {
                    // Agent-level done clears all sessions for this agent.
                    for k in byKey.keys where k == id.rawValue || k.hasPrefix("\(id.rawValue)|") {
                        byKey[k] = nil
                    }
                } else {
                    byKey[mapKey] = nil
                }
                continue
            }
            if kind == .stop {
                func shouldKeep(_ existing: Entry) -> Bool {
                    (existing.kind == "Permission" || existing.kind == "Input" || existing.kind == "Waiting")
                        && existing.tsMs > 0
                        && nowMs - existing.tsMs < stopGraceMs
                }
                if session.isEmpty {
                    let keys = byKey.keys.filter { $0 == id.rawValue || $0.hasPrefix("\(id.rawValue)|") }
                    for k in keys {
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
            if tsMs <= 0 || tsMs > nowMs + 5 * 60 * 1000 { continue }
            if nowMs - tsMs > ttlMs { continue }
            byKey[mapKey] = Entry(
                id: id,
                kind: kind.label,
                message: message,
                tsMs: tsMs,
                session: session,
                cwd: cwd
            )
        }
        return Array(byKey.values)
    }
}
