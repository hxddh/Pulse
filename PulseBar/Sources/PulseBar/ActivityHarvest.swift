import Foundation

enum ActivityHarvest {
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
    }

    /// Harvest-only rows older than this are dropped unless a live process exists.
    static let freshWindowMs: Int64 = 45 * 60 * 1000
    /// Kill hung activity_scan.py so Refresh cannot stick forever.
    static let harvestTimeoutSec: Double = 2.5

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
        return nowMs - row.harvestMs <= freshWindowMs
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
    static func scan() -> (rows: [Row], unreliable: Bool) {
        guard let script = scriptURL() else {
            DebugLog.write("harvest scriptURL=nil")
            return ([], true)
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = [script.path]
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
            return ([], true)
        }

        drain(out.fileHandleForReading, into: outSink, done: outDone)
        drain(err.fileHandleForReading, into: errSink, done: errDone)

        let deadline = Date().addingTimeInterval(harvestTimeoutSec)
        var timedOut = false
        while task.isRunning {
            if Date() >= deadline {
                timedOut = true
                task.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        task.waitUntilExit()
        // Pipes close on child exit; these return promptly now that the child is gone.
        _ = outDone.wait(timeout: .now() + 1.0)
        _ = errDone.wait(timeout: .now() + 1.0)

        let rows = parse(outSink.text)
        let errText = errSink.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !errText.isEmpty {
            // Per-agent harvest failures arrive here as `# pulse: <agent> …` lines.
            for line in errText.split(whereSeparator: \.isNewline).prefix(8) {
                DebugLog.write("harvest stderr \(line.prefix(180))")
            }
        }

        if timedOut {
            DebugLog.write("harvest TIMEOUT \(harvestTimeoutSec)s partial=\(rows.count)")
            // Partial rows beat a frozen snapshot; only a truly empty run is unreliable.
            return (rows, rows.isEmpty)
        }
        if task.terminationStatus != 0 {
            DebugLog.write("harvest exit=\(task.terminationStatus) partial=\(rows.count)")
            return (rows, rows.isEmpty)
        }
        DebugLog.write("harvest parsed=\(rows.count)")
        return (rows, false)
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
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 2, let id = mapAgent(cols[0]) else { continue }
            out.append(Row(
                id: id,
                task: cols[1],
                project: cols.count > 6 ? cols[6] : "",
                cwd: cols.count > 7 ? cols[7] : "",
                skill: cols.count > 5 ? cols[5] : "",
                tokensIn: cols.count > 2 ? Int(cols[2]) ?? 0 : 0,
                tokensOut: cols.count > 3 ? Int(cols[3]) ?? 0 : 0,
                tool: cols.count > 4 ? cols[4] : "",
                harvestMs: cols.count > 8 ? Int64(cols[8]) ?? 0 : 0,
                subRunning: cols.count > 9 ? Int(cols[9]) ?? 0 : 0,
                subTotal: cols.count > 10 ? Int(cols[10]) ?? 0 : 0,
                sessionID: cols.count > 11 ? cols[11] : ""
            ))
        }
        return out
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
        if fm.fileExists(atPath: repo.path) { return repo }
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
            session.isEmpty ? id.rawValue : "\(id.rawValue)|\(session)"
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
            guard cols.count >= 3, let id = ActivityHarvest.mapAgent(cols[0]) else { continue }
            let kind = Kind.parse(cols[1])
            let tsMs = Int64(cols[2]) ?? 0
            let message = cols.count > 3 ? cols[3] : ""
            let session = cols.count > 4 ? cols[4] : ""
            let cwd = cols.count > 5 ? cols[5] : ""
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

            if tsMs <= 0 { continue }
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
