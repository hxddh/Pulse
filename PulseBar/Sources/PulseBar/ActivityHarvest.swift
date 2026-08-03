import Foundation

enum ActivityHarvest {
    /// Versioned row wire retained for the explicit legacy collector and
    /// fixture parser. Normal harvest constructs typed rows in Swift, so a
    /// new field cannot silently shift a positional column in the app.
    static let wireSchemaVersion = 2

    private struct RowEnvelope: Decodable {
        var schema: Int
        var type: String
        var agent: String
        var task: String = ""
        var tokensIn: Int = 0
        var tokensOut: Int = 0
        var tool: String = ""
        var skill: String = ""
        var project: String = ""
        var cwd: String = ""
        var harvestMs: Int64 = 0
        var subRunning: Int = 0
        var subTotal: Int = 0
        var sessionID: String = ""
        var records: Int = 0
        var startedMs: Int64 = 0
        var evidence: String = "cache"
        var phase: String = ""
        var outcome: String = ""
        var model: String = ""
        var mode: String = ""
        var errors: Int = 0
        var files: Int = 0
        var contextPercent: Int = 0
        var progressDone: Int = 0
        var progressTotal: Int = 0
    }

    private struct HealthEnvelope: Decodable {
        var schema: Int
        var type: String
        var agent: String
        var state: String
        var durationMs: Int = 0
        var rowCount: Int = 0
        var sourcePresent: Bool = false
        var errorKind: String = ""
    }

    enum CollectorState: String, Equatable {
        case observed
        /// Fixture-only state kept so an isolated legacy fixture can still be
        /// diagnosed instead of discarded. Packaged scans emit schema 2.
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

    struct CollectorHealth: Equatable {
        var id: AgentID
        var state: CollectorState
        var durationMs: Int
        var rowCount: Int
        var sourcePresent: Bool
        /// Exception type only; vendor paths and exception messages never
        /// leave the diagnostic log.
        var errorKind: String

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
    /// Kill a hung legacy activity_scan.py so an explicit diagnostic cannot
    /// stick Refresh forever. Native harvest is bounded in-process.
    ///
    /// A cold legacy runtime/SQLite start under App Nap can take just over 2.5 s even
    /// though warm scans finish below one second. The old deadline therefore
    /// guaranteed a process-only first snapshot and hid useful activity until
    /// the next 15-second harvest cadence. Keep the bound tight, but allow the
    /// first honest result to land.
    static let harvestTimeoutSec: Double = 6.0

    /// Native and legacy scans report one health result for every user-facing
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
            // public collector. A legacy stream may append an alias health
            // line after the real Cursor result; it must not make an otherwise
            // complete surface scan look partial.
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

    /// A collector launch/preflight failure must be visible as an actionable
    /// health result, not as thirty-one silent “unscanned” adapters. The
    /// synthetic rows carry only a stable reason class; the prior good rows
    /// remain available to SnapshotBuilder and are never replaced by emptiness.
    static func unavailableHealth(_ errorKind: String) -> [CollectorHealth] {
        expectedCollectorIDs.sorted { $0.rawValue < $1.rawValue }.map {
            CollectorHealth(
                id: $0,
                state: .failed,
                durationMs: 0,
                rowCount: 0,
                sourcePresent: false,
                errorKind: errorKind
            )
        }
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
        // A legacy or third-party script may emit a row before its health line.
        // Treat that row's adapter as reached rather than retaining a stale
        // duplicate beside the fresh evidence.
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

    /// Thread-safe sink for a child process pipe.
    private final class PipeSink {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    /// Drain a pipe on its own thread so the child never blocks on a full
    /// buffer. Reading only after `waitUntilExit` deadlocks once the child
    /// writes more than the 64 KB pipe capacity — which is exactly what a
    /// many-agent scan does.
    private static func drain(_ handle: FileHandle, into sink: PipeSink, done: DispatchSemaphore) {
        Thread.detachNewThread {
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                sink.append(chunk)
            }
            done.signal()
        }
    }

    /// `unreliable` → caller must keep lastGoodHarvest (hard fail or empty timeout).
    ///
    /// A timeout no longer throws away what already arrived: harvest streams one
    /// complete line per agent, so partial output is still honest data.
    static func scan(
        allowAppData: Bool = false,
        appDataAgents: Set<AgentID> = []
    ) -> (
        rows: [Row],
        health: [CollectorHealth],
        unreliable: Bool,
        complete: Bool
    ) {
        // Swift is the product path. It has no external runtime, no child
        // process deadline, and no Python/TCC prompt side effect. The legacy
        // adapter can still be requested explicitly for vendor-specific
        // diagnostics, but a missing interpreter can never affect the normal
        // tray scan.
        let native = NativeActivityHarvest.scan(
            allowAppData: allowAppData,
            appDataAgents: appDataAgents
        )
        DebugLog.write(
            "native harvest rows=\(native.rows.count) adapters=\(native.health.count) "
                + "complete=\(native.complete) appData=\(allowAppData)"
        )
        guard legacyPythonRequested else {
            return (native.rows, native.health, false, native.complete)
        }
        let legacy = legacyPythonScan(
            allowAppData: allowAppData,
            appDataAgents: appDataAgents
        )
        // A compatibility parser is allowed to enrich a diagnostic run, but
        // it must not replace a healthy native result with an empty/partial
        // scan. Normal users never enter this branch.
        if !legacy.rows.isEmpty && legacy.complete {
            return legacy
        }
        return (native.rows, native.health, false, native.complete)
    }

    private static var legacyPythonRequested: Bool {
        ProcessInfo.processInfo.environment["PULSE_LEGACY_PYTHON_HARVEST"] == "1"
            || CommandLine.arguments.contains("--legacy-python-harvest")
    }

    private static func legacyPythonScan(
        allowAppData: Bool,
        appDataAgents: Set<AgentID>
    ) -> (
        rows: [Row],
        health: [CollectorHealth],
        unreliable: Bool,
        complete: Bool
    ) {
        DebugLog.write("legacy Python harvest requested appData=\(allowAppData)")
        // LSUIElement apps with no visible window are prime App Nap targets.
        // The optional child can finish in ~300 ms when scheduled yet scrape
        // the deadline when the parent is napped. Keep only this bounded scan
        // responsive; allow system sleep and end the activity immediately.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Read coding-agent session activity"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }

        guard let script = scriptURL() else {
            DebugLog.write("harvest scriptURL=nil")
            return ([], unavailableHealth("script_unavailable"), true, false)
        }
        let task = Process()
        guard let python = RuntimeResolver.python3() else {
            DebugLog.write("legacy harvest runtime unavailable — native result kept")
            return ([], unavailableHealth("legacy_runtime_unavailable"), true, false)
        }
        DebugLog.write("legacy harvest runtime=\(python.path) protocol=\(wireSchemaVersion)")
        task.executableURL = python
        // `scan()` promises that a timeout keeps every complete row already
        // emitted. Python buffers stdout when it is a pipe, so without `-u`
        // the parent saw partial=0 even after early collectors had finished;
        // one slow late adapter blinded every agent before it.
        task.arguments = ["-u", script.path]
        var environment = ProcessInfo.processInfo.environment
        // Keep the privacy policy explicit for every child. In particular, do
        // not inherit a developer shell's opt-in into the packaged tray app.
        environment["PULSE_ALLOW_APP_DATA"] = allowAppData ? "1" : "0"
        environment["PULSE_ALLOW_APP_DATA_AGENTS"] = appDataAgents
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
        // The typed protocol is opt-in at the process boundary so a user can
        // still run the source script manually and inspect its legacy TSV.
        environment["PULSE_HARVEST_PROTOCOL"] = "2"
        if CommandLine.arguments.contains("--trace-harvest") {
            environment["PULSE_HARVEST_TRACE"] = "1"
        }
        task.environment = environment
        let out = Pipe()
        let err = Pipe()
        task.standardOutput = out
        task.standardError = err

        let outSink = PipeSink()
        let errSink = PipeSink()
        let outDone = DispatchSemaphore(value: 0)
        let errDone = DispatchSemaphore(value: 0)

        do {
            try task.run()
        } catch {
            DebugLog.write("harvest throw=\(error.localizedDescription) — keep prior")
            return ([], unavailableHealth("process_launch_failed"), true, false)
        }

        drain(out.fileHandleForReading, into: outSink, done: outDone)
        drain(err.fileHandleForReading, into: errSink, done: errDone)

        // `Process.isRunning` can remain stale for a child launched from an
        // LSUIElement app whose owning queue has no run loop. The child had
        // already emitted both rows and exited, yet the polling loop waited the
        // whole deadline and logged a timeout every cadence. Wait for the real
        // process exit on a dedicated thread instead.
        let exitDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            task.waitUntilExit()
            exitDone.signal()
        }
        let timedOut = exitDone.wait(timeout: .now() + harvestTimeoutSec) == .timedOut
        if timedOut {
            task.terminate()
            _ = exitDone.wait(timeout: .now() + 1.0)
        }
        // Pipes close on child exit; these return promptly now that the child is gone.
        _ = outDone.wait(timeout: .now() + 1.0)
        _ = errDone.wait(timeout: .now() + 1.0)

        let rows = parse(outSink.text)
        let health = parseHealth(outSink.text)
        let errText = errSink.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !errText.isEmpty {
            // Per-agent harvest failures arrive here as `# pulse: <agent> …` lines.
            let limit = CommandLine.arguments.contains("--trace-harvest") ? 80 : 8
            for line in errText.split(whereSeparator: \.isNewline).prefix(limit) {
                DebugLog.write("harvest stderr \(line.prefix(180))")
            }
        }

        if timedOut {
            DebugLog.write("harvest TIMEOUT \(harvestTimeoutSec)s partial=\(rows.count)")
            // Partial rows beat a frozen snapshot; only a truly empty run is unreliable.
            return (rows, health, rows.isEmpty, false)
        }
        if task.terminationStatus != 0 {
            DebugLog.write("harvest exit=\(task.terminationStatus) partial=\(rows.count)")
            return (rows, health, rows.isEmpty, false)
        }
        DebugLog.write("harvest parsed=\(rows.count)")
        return (rows, health, false, isCompleteHealth(health))
    }

    static func parse(_ text: String) -> [Row] {
        var out: [Row] = []
        // `emit` always terminates a row with a newline, so anything after the
        // last one is a line we killed mid-write on timeout — never parse it.
        let complete: Substring
        if let lastNewline = text.lastIndex(where: \.isNewline) {
            complete = text[text.startIndex...lastNewline]
        } else {
            complete = ""
        }
        for line in complete.split(whereSeparator: \.isNewline) {
            if line.first == "{" {
                if let data = line.data(using: .utf8),
                   let envelope = try? JSONDecoder().decode(RowEnvelope.self, from: data),
                   envelope.schema == wireSchemaVersion,
                   envelope.type == "row",
                   let id = mapAgent(envelope.agent) {
                    out.append(Row(
                        id: id,
                        task: ContentSanitizer.redact(envelope.task),
                        project: ContentSanitizer.redact(envelope.project),
                        cwd: ContentSanitizer.redact(envelope.cwd),
                        skill: ContentSanitizer.redact(envelope.skill),
                        tokensIn: max(0, envelope.tokensIn),
                        tokensOut: max(0, envelope.tokensOut),
                        tool: ContentSanitizer.redact(envelope.tool),
                        harvestMs: envelope.harvestMs,
                        subRunning: max(0, envelope.subRunning),
                        subTotal: max(0, envelope.subTotal),
                        sessionID: envelope.sessionID,
                        records: max(0, envelope.records),
                        startedMs: envelope.startedMs,
                        evidence: ObservationSource(rawValue: envelope.evidence) ?? .cache,
                        phase: ContentSanitizer.redact(envelope.phase),
                        outcome: ContentSanitizer.redact(envelope.outcome),
                        model: ContentSanitizer.redact(envelope.model),
                        mode: ContentSanitizer.redact(envelope.mode),
                        errors: max(0, envelope.errors),
                        files: max(0, envelope.files),
                        contextPercent: max(0, min(100, envelope.contextPercent)),
                        progressDone: max(0, envelope.progressDone),
                        progressTotal: max(0, envelope.progressTotal)
                    ))
                }
                continue
            }
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 2, let id = mapAgent(cols[0]) else { continue }
            out.append(Row(
                id: id,
                task: ContentSanitizer.redact(cols[1]),
                project: cols.count > 6 ? ContentSanitizer.redact(cols[6]) : "",
                cwd: cols.count > 7 ? ContentSanitizer.redact(cols[7]) : "",
                skill: cols.count > 5 ? ContentSanitizer.redact(cols[5]) : "",
                tokensIn: cols.count > 2 ? Int(cols[2]) ?? 0 : 0,
                tokensOut: cols.count > 3 ? Int(cols[3]) ?? 0 : 0,
                tool: cols.count > 4 ? ContentSanitizer.redact(cols[4]) : "",
                harvestMs: cols.count > 8 ? Int64(cols[8]) ?? 0 : 0,
                subRunning: cols.count > 9 ? Int(cols[9]) ?? 0 : 0,
                subTotal: cols.count > 10 ? Int(cols[10]) ?? 0 : 0,
                sessionID: cols.count > 11 ? cols[11] : "",
                // Appended in 0.28; a harvest from an older bundled script
                // simply has no columns here and reads as unknown.
                records: cols.count > 12 ? Int(cols[12]) ?? 0 : 0,
                startedMs: cols.count > 13 ? Int64(cols[13]) ?? 0 : 0,
                evidence: cols.count > 14
                    ? ObservationSource(rawValue: cols[14]) ?? .cache
                    : .cache,
                phase: cols.count > 15 ? ContentSanitizer.redact(cols[15]) : "",
                outcome: cols.count > 16 ? ContentSanitizer.redact(cols[16]) : "",
                model: cols.count > 17 ? ContentSanitizer.redact(cols[17]) : "",
                mode: cols.count > 18 ? ContentSanitizer.redact(cols[18]) : "",
                errors: cols.count > 19 ? Int(cols[19]) ?? 0 : 0,
                files: cols.count > 20 ? Int(cols[20]) ?? 0 : 0,
                contextPercent: cols.count > 21 ? Int(cols[21]) ?? 0 : 0,
                progressDone: cols.count > 22 ? Int(cols[22]) ?? 0 : 0,
                progressTotal: cols.count > 23 ? Int(cols[23]) ?? 0 : 0
            ))
        }
        return out
    }

    static func parseHealth(_ text: String) -> [CollectorHealth] {
        var out: [CollectorHealth] = []
        let complete: Substring
        if let lastNewline = text.lastIndex(where: \.isNewline) {
            complete = text[text.startIndex...lastNewline]
        } else {
            complete = ""
        }
        for line in complete.split(whereSeparator: \.isNewline) {
            if line.first == "{" {
                if let data = line.data(using: .utf8),
                   let envelope = try? JSONDecoder().decode(HealthEnvelope.self, from: data),
                   envelope.schema == wireSchemaVersion,
                   envelope.type == "health",
                   let id = mapAgent(envelope.agent),
                   let state = CollectorState(rawValue: envelope.state) {
                    out.append(CollectorHealth(
                        id: id,
                        state: state,
                        durationMs: max(0, envelope.durationMs),
                        rowCount: max(0, envelope.rowCount),
                        sourcePresent: envelope.sourcePresent,
                        errorKind: ContentSanitizer.redact(envelope.errorKind)
                    ))
                }
                continue
            }
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 5,
                  cols[0] == "#health",
                  let id = mapAgent(cols[1]),
                  let state = CollectorState(rawValue: cols[2])
            else { continue }
            out.append(CollectorHealth(
                id: id,
                state: state,
                durationMs: max(0, Int(cols[3]) ?? 0),
                rowCount: max(0, Int(cols[4]) ?? 0),
                sourcePresent: cols.count > 6
                    ? cols[6] == "1"
                    : ![CollectorState.sourceAbsent, .unscanned].contains(state),
                errorKind: cols.count > 5 ? cols[5] : ""
            ))
        }
        return out
    }

    /// Exposed for `--selftest`, which must check the same resolution the app
    /// actually uses rather than a re-implementation of it.
    static func selfTestScriptPath() -> String? { scriptURL()?.path }

    /// Optional compatibility runtime. The native collector never calls this;
    /// it exists only for an explicitly requested legacy diagnostic scan.
    static func pythonURL() -> URL? {
        RuntimeResolver.python3()
    }

    private static func scriptURL() -> URL? {
        let fm = FileManager.default
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        // Dev: prefer repo src/ (same as HooksSupport) so swift run isn't stuck on stale Bundle.
        let repo = here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("src/activity_scan.py")
        // `#filePath` is compiled as an absolute source path. A packaged app
        // built inside a checkout therefore kept reading that checkout on the
        // developer's Mac, making package self-test and runtime behaviour
        // disagree with every user's machine. Only an unbundled SwiftPM run
        // may prefer source; a real .app must prove and use its own resources.
        if Bundle.main.bundleURL.pathExtension != "app",
           fm.fileExists(atPath: repo.path) {
            return repo
        }
        if let res = Bundle.main.resourceURL?.appendingPathComponent("activity_scan.py"),
           fm.fileExists(atPath: res.path) {
            return res
        }
        if let url = PulseResources.url(forResource: "activity_scan", withExtension: "py") {
            return url
        }
        if let exe = Bundle.main.executableURL?.deletingLastPathComponent() {
            // The SwiftPM bundle is flat — resources sit at its root. These used
            // to point at Contents/Resources/, which only ever existed because
            // package.sh wrongly created it (and that is what broke launch).
            let candidates = [
                exe.appendingPathComponent("PulseBar_PulseBar.bundle/activity_scan.py"),
                exe.appendingPathComponent("../Resources/activity_scan.py"),
                exe.appendingPathComponent("../Resources/PulseBar_PulseBar.bundle/activity_scan.py"),
            ]
            for c in candidates where fm.fileExists(atPath: c.path) { return c }
        }
        let bundled = here.appendingPathComponent("Resources/activity_scan.py")
        if fm.fileExists(atPath: bundled.path) { return bundled }
        return nil
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
            switch raw {
            case "permission", "permission_prompt", "PermissionRequest":
                return .permission
            case "idle_prompt", "idle", "agent_needs_input":
                return .idlePrompt
            case "waiting", "needs_input":
                return .waiting
            case "stop", "Stop":
                return .stop
            case "done", "agent-turn-complete", "agent_completed":
                return .done
            case "subagent", "subagent_start", "subagent_stop", "SubagentStart", "SubagentStop":
                return .ignore
            default:
                // Codex-normalized kinds already mapped in hook; treat unknown clears carefully.
                let low = raw.lowercased()
                if low.contains("approval") && !low.contains("response") { return .permission }
                if low.contains("user_input") && !low.contains("response") { return .idlePrompt }
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
                    (existing.kind == "Permission" || existing.kind == "Input")
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
