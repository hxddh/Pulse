import Foundation
import PulseCore

/// Port of Zig probe rules for surface coding agents (+ Warp parent + TTY).
package enum ProcessProbe {
    /// `lsof` is only needed when a new agent process appears. Re-running it at
    /// the 2 s Waiting cadence would turn one useful fallback fact into a
    /// permanent energy cost.
    private static var cwdCache: [Int: (path: String, observedAt: TimeInterval)] {
        get { HarvestMemory.memory.withValue { $0.cwd } }
        set { HarvestMemory.memory.withValue { $0.cwd = newValue } }
    }
    /// A denied/empty `lsof` result must not become a prompt loop. macOS can
    /// surface the cross-app privacy dialog from this lookup, and retrying it
    /// on every probe cadence is both noisy and wasteful. Keep the negative
    /// result for a bounded period; a later explicit refresh can try again.
    private static var cwdLookupBackoffUntil: TimeInterval {
        get { HarvestMemory.memory.withValue { $0.cwdLookupBackoffUntil } }
        set { HarvestMemory.memory.withValue { $0.cwdLookupBackoffUntil = newValue } }
    }
    private static let cwdLookupBackoffSeconds: TimeInterval = 5 * 60

    /// 23.0: the probe asks `ps` for what identifies an agent process and
    /// nothing else. CPU and resident memory were sampled per pid for a
    /// compute line nothing renders any more; they are gone with it.
    private static let psFields = "pid=,ppid=,tty=,etime=,args="

    package struct Hit: Hashable {
        package var id: AgentID
        package var count: Int
        package var viaWarp: Bool
        package var pid: Int = 0
        /// Kernel tty name without `/dev/`, e.g. `ttys003`.
        package var tty: String = ""
        /// Age of the matched process, not the agent session.
        package var elapsedSeconds: Double = 0
        /// Current working directory observed from the process. This is useful
        /// context for CLI agents even when they expose no readable session
        /// store; it is not a focus handle and never creates an action.
        package var cwd: String = ""
        /// Rule class only; never retain or show the matched argv.
        package var evidence: ProcessEvidence = .executable
        /// Parent IDE / editor from `ps` argv walk — Focus host without TCC.
        package var hostApp: HostAppKind? = nil
    }

    /// One parsed row of the process table.
    package struct Proc: Equatable {
        package var pid: Int
        package var ppid: Int
        package var tty: String = ""
        /// Age of this process, not of the agent session.
        package var elapsedSeconds: Double = 0
        package var args: String = ""
    }

    /// Process rules in roster order — the first matching rule wins, so
    /// precedence is `AgentCatalog.all` order.
    private static let rules: [(id: AgentID, rule: AgentProcessRule)] =
        AgentCatalog.all.map { ($0.id, $0.process) }

    package static func scan(
        allowAppData: Bool = false,
        appDataAgents: Set<AgentID> = []
    ) -> [Hit] {
        // Field order matters: `args=` is the only column that contains
        // spaces, so it must stay last — everything before it is one token.
        let output = shell("/bin/ps", ["-axo", psFields]) ?? ""
        // Node-based agents are allowed to rewrite argv[0] for a polished
        // terminal title. Command Code, for example, appears in `args` as
        // `⌘ Command Code · <user>` while the executable is still Node. Keep
        // the existing argv scan, but join the process `comm` name as a
        // second evidence source so those sessions cannot disappear merely
        // because their runtime changed the title.
        let commOutput = shell("/bin/ps", ["-axo", "pid=,comm="]) ?? ""
        if output.isEmpty {
            DebugLog.write("probe ps output EMPTY")
        }
        let procs = parseProcessLines(output)

        var commByPid: [Int: String] = [:]
        for line in commOutput.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0.isWhitespace || $0 == "\t" })
            guard parts.count == 2, let pid = Int(parts[0]) else { continue }
            commByPid[pid] = String(parts[1])
        }

        var byPid: [Int: Int] = [:]
        for p in procs { byPid[p.pid] = p.ppid }
        var argsByPid: [Int: String] = [:]
        for p in procs {
            let comm = commByPid[p.pid] ?? ""
            argsByPid[p.pid] = [comm, p.args]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        var ttyByPid: [Int: String] = [:]
        for p in procs { ttyByPid[p.pid] = p.tty }

        func underWarp(_ pid: Int) -> Bool {
            var seen = Set<Int>()
            var cur: Int? = pid
            while let c = cur, seen.insert(c).inserted {
                if let a = argsByPid[c], a.contains("Warp.app") { return true }
                cur = byPid[c]
            }
            return false
        }

        /// Walk parents for a host IDE path needle — `ps` only, no AppKit.
        func resolveHostApp(_ pid: Int) -> HostAppKind? {
            var seen = Set<Int>()
            var cur: Int? = pid
            while let c = cur, seen.insert(c).inserted {
                guard let a = argsByPid[c] else {
                    cur = byPid[c]
                    continue
                }
                for kind in HostAppKind.allCases {
                    if kind.pathNeedles.contains(where: { a.contains($0) }) {
                        return kind
                    }
                }
                cur = byPid[c]
            }
            return nil
        }

        /// Walk parents for a real tty when the process itself is `??`.
        func resolveTTY(_ pid: Int) -> String {
            var seen = Set<Int>()
            var cur: Int? = pid
            while let c = cur, seen.insert(c).inserted {
                if let t = ttyByPid[c], isRealTTY(t) { return normalizeTTY(t) }
                cur = byPid[c]
            }
            return ""
        }

        var acc: [AgentID: Hit] = [:]
        for p in procs {
            if p.args.contains("Warp.app") { continue }
            let evidenceArgs = argsByPid[p.pid] ?? p.args
            guard let match = matchEvidence(args: evidenceArgs) else { continue }
            let id = match.id
            // The Cursor GUI is itself useful liveness evidence when the
            // protected composer store is unavailable. Previously this was
            // dropped unconditionally, so a user with an active Cursor
            // session saw no Cursor row at all unless they enabled the
            // privacy-sensitive app-data scan. Keep the persistent
            // `cursor-agent worker start --worker-dir` daemon filtered by its
            // rule above, but surface the actual Cursor app as an honest
            // process-only fallback.
            var hit = acc[id] ?? Hit(id: id, count: 0, viaWarp: false)
            hit.count += 1
            hit.evidence = match.evidence
            if underWarp(p.pid) { hit.viaWarp = true }
            if hit.hostApp == nil { hit.hostApp = resolveHostApp(p.pid) }
            if hit.pid == 0 {
                hit.pid = p.pid
                hit.tty = resolveTTY(p.pid)
                hit.elapsedSeconds = p.elapsedSeconds
            } else if hit.tty.isEmpty {
                let t = resolveTTY(p.pid)
                if !t.isEmpty {
                    hit.pid = p.pid
                    hit.tty = t
                    hit.elapsedSeconds = p.elapsedSeconds
                }
            }
            acc[id] = hit
        }
        // `lsof` asks the kernel for another process's open cwd and can be
        // classified as cross-app data by macOS. Activity rows already carry
        // their workspace from the agent store; keep this enrichment behind
        // the same explicit privacy switch as deep app-data harvest. A scoped
        // grant is filtered by AgentID before any PID reaches lsof — selecting
        // Cursor must never widen the lookup to every matching process.
        let allowed = allowAppData ? Set(acc.keys) : appDataAgents
        let workingDirectories = allowed.isEmpty
            ? [:]
            : currentWorkingDirectories(
                pids: acc.values
                    .filter { allowed.contains($0.id) }
                    .map(\.pid)
                    .filter { $0 > 0 }
            )
        for id in acc.keys {
            guard var hit = acc[id], let cwd = workingDirectories[hit.pid] else { continue }
            hit.cwd = usefulWorkingDirectory(cwd)
            acc[id] = hit
        }
        let hits = Array(acc.values)
        DebugLog.write("probe psLines=\(procs.count) hits=\(hits.count) ids=\(hits.map(\.id.rawValue).joined(separator: ","))")
        return hits
    }

    /// Stable fingerprint of the live agent set. When this is unchanged there is
    /// very little chance session data moved, so the expensive harvest can be
    /// skipped for a tick or two.
    ///
    /// It answers "did the process set change", never "what are those
    /// processes doing": a value that moves every tick would make the
    /// fingerprint differ from itself forever and the harvest skip would
    /// never fire again.
    package static func signature(_ hits: [Hit]) -> String {
        hits
            .map { "\($0.id.rawValue):\($0.count):\($0.pid)" }
            .sorted()
            .joined(separator: "|")
    }

    private static func isRealTTY(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespaces)
        return !(t.isEmpty || t == "?" || t == "??" || t == "-")
    }

    private static func normalizeTTY(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("/dev/") { t = String(t.dropFirst(5)) }
        return isRealTTY(t) ? t : ""
    }

    /// `ps etime`: `mm:ss`, `hh:mm:ss`, or `dd-hh:mm:ss`.
    package static func parseElapsed(_ raw: String) -> Double {
        let split = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "-", maxSplits: 1)
        let days = split.count == 2 ? Double(split[0]) ?? 0 : 0
        let clock = (split.last ?? "").split(separator: ":").compactMap { Double($0) }
        guard clock.count == 2 || clock.count == 3 else { return 0 }
        let hours = clock.count == 3 ? clock[0] : 0
        let minutes = clock.count == 3 ? clock[1] : clock[0]
        let seconds = clock.count == 3 ? clock[2] : clock[1]
        return days * 86_400 + hours * 3_600 + minutes * 60 + seconds
    }

    /// Parse one `ps -axo pid=,ppid=,tty=,etime=,args=` table into rows.
    ///
    /// Pulled out of `scan` so the field order — the part that breaks silently
    /// when a column is added in the wrong place — can be held to real vendor
    /// output in a test without launching a single process.
    package static func parseProcessLines(_ output: String) -> [Proc] {
        let columns = 5
        var procs: [Proc] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(
                maxSplits: columns - 1,
                whereSeparator: { $0.isWhitespace || $0 == "\t" }
            )
            guard parts.count >= columns,
                  let pid = Int(parts[0]),
                  let ppid = Int(parts[1]) else { continue }
            procs.append(Proc(
                pid: pid,
                ppid: ppid,
                tty: String(parts[2]),
                elapsedSeconds: parseElapsed(String(parts[3])),
                // The remainder of the line, spaces and all.
                args: String(parts[columns - 1]).trimmingCharacters(in: .whitespaces)
            ))
        }
        return procs
    }

    /// Parse `lsof -Ffpn -a -d cwd -p ...` without depending on column spacing.
    ///
    /// The `f` field must be requested. `lsof -F<chars>` emits **only** the
    /// fields named, so the earlier `-Fpn` produced
    ///
    ///     p4432
    ///     n/Users/me/code/Pulse
    ///
    /// with no `fcwd` line at all — and this parser, which only accepted an
    /// `n` after seeing `fcwd`, returned nothing for every real invocation.
    /// The caller then read an empty map as "lsof is unavailable", armed a
    /// five-minute backoff, and negative-cached every pid, so no process row
    /// ever recovered a working directory. The unit test passed because its
    /// fixture was hand-written with the `fcwd` line the tool does not send.
    ///
    /// The parser stays tolerant of both shapes: `-d cwd` restricts the result
    /// to one descriptor per process, so an `n` line following a `p` line is
    /// unambiguous even when the `f` field is absent.
    package static func parseWorkingDirectories(_ output: String) -> [Int: String] {
        var result: [Int: String] = [:]
        var pid: Int?
        var expectingPath = false
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.hasPrefix("p"), let value = Int(line.dropFirst()) {
                pid = value
                // Without an `f` field the next `n` belongs to this process.
                expectingPath = true
            } else if line.hasPrefix("f") {
                expectingPath = line == "fcwd"
            } else if line.hasPrefix("n"), expectingPath, let pid {
                result[pid] = String(line.dropFirst())
                expectingPath = false
            }
        }
        return result
    }

    /// Keep only paths that can identify user work. `/`, app bundles and
    /// support folders are implementation context, not a project.
    package static func usefulWorkingDirectory(_ raw: String) -> String {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), path != "/" else { return "" }
        // lsof annotates a directory it could not resolve in place, e.g.
        // `/private/var/x (readlink: Permission denied)`. That is an error
        // message with a path glued to the front, not a workspace. Match the
        // annotation shape rather than any parenthesis — `~/Documents/Work
        // (old)` is a perfectly ordinary directory.
        guard !isLsofErrorAnnotated(path) else { return "" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path != home, path != home + "/" else { return "" }
        let excluded = [
            "/Applications/", "/System/", "/Library/",
            home + "/Library/", "/private/var/", "/var/",
        ]
        guard !excluded.contains(where: path.hasPrefix) else { return "" }
        return path
    }

    /// `… (readlink: Permission denied)` / `… (stat: No such file or directory)`.
    /// Anchored to a trailing parenthetical that names an lsof syscall, so a
    /// directory literally called `Work (old)` still counts as a workspace.
    package static func isLsofErrorAnnotated(_ path: String) -> Bool {
        guard path.hasSuffix(")"), let open = path.range(of: " (", options: .backwards) else {
            return false
        }
        let inner = path[open.upperBound...].dropLast().lowercased()
        let markers = ["readlink:", "stat:", "lstat:", "opendir:", "no such file", "permission denied"]
        return markers.contains { inner.contains($0) }
    }

    private static func currentWorkingDirectories(pids: [Int]) -> [Int: String] {
        let unique = Array(Set(pids)).sorted()
        guard !unique.isEmpty else { return [:] }
        let now = Date().timeIntervalSince1970
        var result: [Int: String] = [:]
        var unresolved: [Int] = []
        for pid in unique {
            if let cached = cwdCache[pid], now - cached.observedAt < 60 {
                result[pid] = cached.path
            } else {
                unresolved.append(pid)
            }
        }
        if !unresolved.isEmpty {
            if now < cwdLookupBackoffUntil {
                // Cache a negative observation too. Otherwise the same PIDs
                // would stay unresolved and re-enter this branch on every
                // probe even while the privacy backoff is active.
                for pid in unresolved {
                    cwdCache[pid] = ("", now)
                }
            } else {
                let list = unresolved.map(String.init).joined(separator: ",")
                let invocation = run(
                    "/usr/sbin/lsof",
                    ["-Ffpn", "-a", "-d", "cwd", "-p", list]
                )
                // `lsof` exits 1 when it could not find *anything* it was asked
                // about — including a single PID that exited between the `ps`
                // snapshot and this call — while still printing every process
                // it did resolve. Reading the exit status as "the call failed"
                // therefore threw away good answers for every other agent and
                // armed the five-minute backoff, which is the same damage the
                // field-selection bug did before 0.99.1. Judge the output.
                let paths = workingDirectories(from: invocation)
                if paths.isEmpty, shouldBackOff(invocation, pids: unresolved) {
                    cwdLookupBackoffUntil = now + cwdLookupBackoffSeconds
                    DebugLog.write(
                        "cwd lookup unavailable; retry in \(Int(cwdLookupBackoffSeconds))s"
                    )
                }
                for pid in unresolved {
                    let path = paths[pid] ?? ""
                    // Empty paths are intentional negative cache entries. They
                    // prevent a denied or unavailable lsof from becoming a
                    // recurring cross-app permission prompt.
                    cwdCache[pid] = (path, now)
                    if !path.isEmpty { result[pid] = path }
                }
            }
        }
        cwdCache = cwdCache.filter { unique.contains($0.key) && now - $0.value.observedAt < 300 }
        return result
    }

    /// Match one `ps` argv. Internal so the complete supported-agent roster
    /// can be held to a detection contract in tests.
    package static func match(args: String) -> AgentID? {
        matchEvidence(args: args)?.id
    }

    package struct Match: Equatable {
        package var id: AgentID
        package var evidence: ProcessEvidence
    }

    /// Match plus a privacy-safe explanation for support diagnostics.
    package static func matchEvidence(args: String) -> Match? {
        let exe = args.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? args
        let base = (exe as NSString).lastPathComponent
        for (id, rule) in rules {
            if rule.denyNeedles.contains(where: { args.contains($0) }) { continue }
            let baseHit = rule.basenames.contains { $0.caseInsensitiveCompare(base) == .orderedSame }
            // Prefer path needles; bare basename only when explicitly trusted,
            // pathNeedles are absent, or the name is naturally distinctive.
            let pathHit = rule.pathNeedles.contains { args.contains($0) }
            if pathHit { return Match(id: id, evidence: .pathSignature) }
            // Electron gives many Cursor helper processes the same `Cursor`
            // comm name as the GUI. They do not contain the app's main
            // executable path, so treating the basename as a hit inflated one
            // app into a misleading "15 processes" row.
            if id == .cursor, baseHit { continue }
            if baseHit, !rule.pathNeedles.isEmpty {
                if base.count <= 3 && !rule.allowBareBasename {
                    continue
                }
                return Match(id: id, evidence: .executable)
            }
            if baseHit, rule.pathNeedles.isEmpty {
                return Match(id: id, evidence: .executable)
            }
        }
        return nil
    }

    /// One probe subprocess, exit status included. `nil` means the tool could
    /// not be launched or had to be killed — the only states in which its
    /// output says nothing at all.
    package struct Invocation: Equatable {
        package var stdout: String
        package var status: Int32
    }

    private static func run(_ launchPath: String, _ arguments: [String]) -> Invocation? {
        guard let result = ProcessIO.run(
            executable: launchPath,
            arguments: arguments,
            timeout: 1.5
        ), !result.timedOut else {
            DebugLog.write("probe shell failed \(URL(fileURLWithPath: launchPath).lastPathComponent)")
            return nil
        }
        return Invocation(
            stdout: String(data: result.stdout, encoding: .utf8) ?? "",
            status: result.status
        )
    }

    /// `ps` is only useful when it succeeded outright; a partial process table
    /// would silently shrink the fleet.
    private static func shell(_ launchPath: String, _ arguments: [String]) -> String? {
        guard let invocation = run(launchPath, arguments) else { return nil }
        guard invocation.status == 0 else {
            DebugLog.write(
                "probe \(URL(fileURLWithPath: launchPath).lastPathComponent) exit=\(invocation.status)"
            )
            return nil
        }
        return invocation.stdout
    }

    /// Every process `lsof` did resolve, whatever it exited with.
    ///
    /// The exit status answers "did you find everything I named", not "did you
    /// work". Those are different questions, and reading the first as the
    /// second is what kept the answer from ever being used.
    package static func workingDirectories(from invocation: Invocation?) -> [Int: String] {
        guard let invocation else { return [:] }
        return parseWorkingDirectories(invocation.stdout)
    }

    /// An empty `lsof` answer is only evidence that `lsof` is unusable when the
    /// processes we asked about are still alive.
    ///
    /// Backoff exists to stop a denied lookup from becoming a recurring
    /// cross-app privacy prompt. A PID that simply exited explains the silence
    /// by itself, and punishing every future lookup for five minutes because
    /// one agent finished is how a working feature stays invisible.
    package static func shouldBackOff(_ invocation: Invocation?, pids: [Int]) -> Bool {
        guard let invocation else { return true }
        if invocation.status == 0 { return true }
        // Non-zero: `lsof` reported it could not resolve something. If nothing
        // we asked about is alive, that is the whole explanation.
        return pids.contains(where: processExists)
    }

    /// Liveness only — no signal is sent.
    package static func processExists(_ pid: Int) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }
}
