import Foundation

/// Port of Zig probe rules for surface coding agents (+ Warp parent + TTY).
enum ProcessProbe {
    /// `lsof` is only needed when a new agent process appears. Re-running it at
    /// the 2 s Waiting cadence would turn one useful fallback fact into a
    /// permanent energy cost.
    private static var cwdCache: [Int: (path: String, observedAt: TimeInterval)] = [:]
    /// A denied/empty `lsof` result must not become a prompt loop. macOS can
    /// surface the cross-app privacy dialog from this lookup, and retrying it
    /// on every probe cadence is both noisy and wasteful. Keep the negative
    /// result for a bounded period; a later explicit refresh can try again.
    private static var cwdLookupBackoffUntil: TimeInterval = 0
    private static let cwdLookupBackoffSeconds: TimeInterval = 5 * 60

    /// Last accumulated-CPU reading per pid: `(cputime seconds, wall clock ms)`.
    ///
    /// Two points make a rate — the same shape `SessionDigest.bytesPerMinute`
    /// uses for transcript growth. One reading of `cputime` says how much CPU a
    /// process has burned *since it launched*, which for a three-hour agent is
    /// a fact about this morning, not about now. The difference between two
    /// readings is the only thing that answers "is it computing right now".
    ///
    /// Kept for matched agent processes only and rebuilt from the pids seen in
    /// each scan, so a process that exits takes its entry with it.
    private static var cpuSamples: [Int: (cpuSeconds: Double, atMs: Int64)] = [:]
    /// Hard ceiling on that store. Only agent processes are sampled, so this is
    /// never reached in practice; it exists so that a pathological machine
    /// cannot turn a cache into a leak.
    static let maxCPUSamples = 512
    /// Below this the two readings are too close together for their ratio to
    /// mean anything: `ps cputime` is reported to 1/100 s, so a 200 ms window
    /// quantises into steps of 5 % — a number about the sampler, not the agent.
    static let minCPUWindowMs: Int64 = 1_000
    /// Reported percentage ceiling. Percentages are per core, so a parallel
    /// build legitimately exceeds 100; past this the honest statement is "flat
    /// out", not a bigger number, and a clock jump cannot print an absurdity.
    static let maxCPUPercent: Double = 1_600
    /// Latched once if this `ps` will not accept `cputime`/`rss`, so the
    /// degraded field list is asked for directly from then on. A probe that
    /// cannot list processes shows nothing at all, and no new column is worth
    /// that; the app drops back to the field set it has always used and simply
    /// reports CPU as unknown.
    private static var psRejectsCPUFields = false
    private static let psFieldsWithCPU = "pid=,ppid=,tty=,etime=,cputime=,rss=,args="
    private static let psFieldsBase = "pid=,ppid=,tty=,etime=,args="

    struct Hit: Hashable {
        var id: AgentID
        var count: Int
        var viaWarp: Bool
        var pid: Int = 0
        /// Kernel tty name without `/dev/`, e.g. `ttys003`.
        var tty: String = ""
        /// Age of the matched process, not the agent session.
        var elapsedSeconds: Double = 0
        /// Current working directory observed from the process. This is useful
        /// context for CLI agents even when they expose no readable session
        /// store; it is not a focus handle and never creates an action.
        var cwd: String = ""
        /// Rule class only; never retain or show the matched argv.
        var evidence: ProcessEvidence = .executable
        /// Parent IDE / editor from `ps` argv walk — Focus host without TCC.
        var hostApp: HostAppKind? = nil
        /// Share of one core, in percent, burned between the previous scan and
        /// this one. **-1 means not known** — a process seen for the first time
        /// has no earlier reading to subtract from. 0 is a different and
        /// meaningful answer: sampled, and genuinely not computing.
        ///
        /// Highest value among this agent's matched processes. A row that said
        /// "0 %" while one of its three processes was pegged would be stating
        /// the one thing that is false.
        var cpuPercent: Double = -1
        /// Resident memory in bytes, summed over this agent's matched
        /// processes. 0 means not observed.
        var rssBytes: Int = 0
    }

    /// One parsed row of the process table.
    ///
    /// CPU and resident memory are the two facts no transcript can give. A run
    /// that is compiling, installing dependencies or waiting on a long tool
    /// call writes nothing at all, and on file evidence alone it looks exactly
    /// like a run that has stopped.
    struct Proc: Equatable {
        var pid: Int
        var ppid: Int
        var tty: String = ""
        /// Age of this process, not of the agent session.
        var elapsedSeconds: Double = 0
        /// Accumulated CPU seconds since launch (`ps cputime`). -1 when `ps`
        /// gave nothing parseable — never 0, which is a real answer meaning
        /// "this process has used no CPU".
        var cpuSeconds: Double = -1
        /// Share of one core over the interval since the previous scan, in
        /// percent; -1 for not known. Only matched agent processes are sampled
        /// (see `scan`), so an unmatched row keeps -1 by design.
        var cpuPercent: Double = -1
        /// Resident set size in bytes. `ps` reports KB.
        var rssBytes: Int = 0
        var args: String = ""
    }

    private struct Rule {
        var id: AgentID
        var basenames: [String]
        var pathNeedles: [String]
        var denyNeedles: [String]
        /// Some real CLIs intentionally use a short executable name (`pi`,
        /// `roo`, `cmd`). Their exact basename is useful evidence after the
        /// deny list has run; length alone must not make a live agent vanish.
        var allowBareBasename: Bool = false
    }

    private static let rules: [Rule] = [
        .init(id: .claude, basenames: ["claude"], pathNeedles: ["/.local/bin/claude", "/bin/claude"], denyNeedles: ["Claude.app", "chrome-native-host"]),
        .init(id: .codex, basenames: ["codex"], pathNeedles: ["/opt/homebrew/bin/codex", "/bin/codex", "Resources/codex"], denyNeedles: ["Codex Framework", "crashpad", "computer-use", "codex-code-mode-host"]),
        .init(id: .cursor, basenames: ["Cursor", "cursor"], pathNeedles: ["Cursor.app/Contents/MacOS/Cursor"], denyNeedles: ["crashpad", "CursorUIViewService"]),
        .init(
            id: .cursorAgent,
            basenames: ["cursor-agent", "cursor_agent"],
            pathNeedles: ["cursor-agent", "anysphere.cursor-agent", "cursor-agent-worker"],
            // Cursor's private-worker daemon is persistent infrastructure. It
            // remains alive with no composer running, so counting it as an
            // agent made an idle IDE look like "2 processes" forever.
            denyNeedles: ["crashpad", "worker start", "--worker-dir"]
        ),
        .init(id: .grok, basenames: ["grok"], pathNeedles: ["/.grok/bin/grok", "grok-0.", "GROK_AGENT=", "/bin/grok"], denyNeedles: []),
        .init(id: .pi, basenames: ["pi"], pathNeedles: ["pi-coding-agent", "/opt/homebrew/bin/pi", "/usr/local/bin/pi", "/.local/bin/pi"], denyNeedles: ["pip", "pip3", "pihole", "pickle", "pypi", "pixel", "piano"], allowBareBasename: true),
        .init(
            id: .amp,
            basenames: ["amp"],
            // Bare argv `amp` is 3 chars; non-empty pathNeedles would skip basename-only matches.
            pathNeedles: [],
            denyNeedles: ["AMPDevice", "AMPLibrary", "AMPDevices", "iTunesCloud", "AMPLibraryAgent"]
        ),
        .init(id: .aider, basenames: ["aider"], pathNeedles: ["/bin/aider", "-m aider"], denyNeedles: []),
        .init(id: .gemini, basenames: ["gemini", "gemini-cli"], pathNeedles: ["/bin/gemini", "gemini-cli", "@google/gemini-cli"], denyNeedles: ["Gemini.app"]),
        .init(
            id: .copilot,
            basenames: ["copilot"],
            pathNeedles: ["/bin/copilot", "github/gh-copilot", "@github/copilot", "copilot-cli"],
            denyNeedles: ["crashpad", "language-server", "copilot-language-server", "Copilot.Helper", "Copilot for Xcode"]
        ),
        .init(id: .opencode, basenames: ["opencode", "open-code"], pathNeedles: ["/bin/opencode", "/opencode/", "opencode@", "@opencode"], denyNeedles: []),
        .init(id: .goose, basenames: ["goose"], pathNeedles: ["/bin/goose", "block/goose", "goose-cli"], denyNeedles: []),
        .init(id: .openhands, basenames: ["openhands", "opendevin"], pathNeedles: ["openhands", "OpenHands", "OpenDevin"], denyNeedles: []),
        .init(id: .cline, basenames: ["cline"], pathNeedles: ["saoudrizwan.claude-dev", "/cline/", "cline@", "claude-dev"], denyNeedles: ["crashpad", "decline", "incline"]),
        .init(id: .roo, basenames: ["roo", "roo-code"], pathNeedles: ["roo-cline", "roo-code", "RooCode"], denyNeedles: ["crashpad"], allowBareBasename: true),
        .init(id: .continue_, basenames: ["continue", "continue-cli"], pathNeedles: ["continue.dev", "Continue.continue", "continue-cli"], denyNeedles: ["crashpad"]),
        .init(id: .amazonQ, basenames: ["amazon-q", "q-chat", "qchat"], pathNeedles: ["amazon-q", "Amazon Q", "/opt/homebrew/bin/q"], denyNeedles: ["qemu", "QuickTime"]),
        .init(
            id: .cascade,
            basenames: ["cascade", "windsurf-cascade"],
            pathNeedles: ["cascade-agent", "windsurf-cascade", "codeium.cascade", "Codeium.Cascade"],
            denyNeedles: ["crashpad", "Windsurf.app/Contents/MacOS/Windsurf", "Windsurf Helper"]
        ),
        .init(
            id: .windsurf,
            basenames: ["Windsurf", "windsurf"],
            pathNeedles: ["Windsurf.app/Contents/MacOS/Windsurf", "Exafunction/windsurf", "codeium.windsurf"],
            denyNeedles: ["crashpad", "Windsurf Helper", "WindsurfUI", "cascade-agent", "windsurf-cascade"]
        ),
        .init(
            id: .augment,
            basenames: ["augment", "auggie"],
            pathNeedles: ["augmentcode", "augment-code", "/bin/augment", "Augment"],
            denyNeedles: ["crashpad"]
        ),
        .init(
            id: .zedAgent,
            basenames: ["zed-agent", "zed_agent"],
            pathNeedles: ["zed-agent", "zed_agent", "Zed Agent", "zed-agentic"],
            denyNeedles: ["crashpad", "Zed.app/Contents/MacOS/Zed", "Zed.app/Contents/MacOS/zed"]
        ),
        .init(
            id: .trae,
            basenames: ["trae-agent", "TraeAgent"],
            pathNeedles: ["trae-agent", "bytedance.trae", "Trae Agent", "trae/agent"],
            denyNeedles: ["crashpad", "Trae Helper", "Trae.app/Contents/MacOS/Trae"]
        ),
        .init(
            id: .warpAgent,
            basenames: ["warp-agent", "warp_agent", "warp-ai"],
            pathNeedles: ["warp-agent", "warp_agent", "WarpAgent", "warp ai agent"],
            denyNeedles: ["crashpad", "Warp.app/Contents/MacOS/stable", "Warp.app/Contents/MacOS/Warp"]
        ),
        .init(
            id: .devin,
            basenames: ["devin", "devin-cli"],
            pathNeedles: ["/bin/devin", "cognition.devin", "devin-cli", "@cognition/devin"],
            denyNeedles: ["crashpad"]
        ),
        .init(
            id: .kiro,
            basenames: ["kiro", "kiro-cli", "kiro-agent"],
            pathNeedles: ["/bin/kiro", "kiro-cli", "kiro-agent", "amazon.kiro", "Kiro.app"],
            denyNeedles: ["crashpad", "Kiro Helper"]
        ),
        .init(
            id: .junie,
            basenames: ["junie", "junie-cli"],
            pathNeedles: ["/bin/junie", "junie-cli", "jetbrains.junie", "Junie"],
            denyNeedles: ["crashpad"]
        ),
        .init(
            id: .kilo,
            basenames: ["kilo", "kilo-code"],
            pathNeedles: ["kilocode", "kilo-code", "kilo.code", "Kilo Code"],
            denyNeedles: ["crashpad", "kilobyte"]
        ),
        .init(
            id: .replit,
            basenames: ["replit", "replit-agent"],
            pathNeedles: ["replit-agent", "replit.com/agent", "@replit/agent", "Replit Agent"],
            denyNeedles: ["crashpad"]
        ),
        .init(
            id: .droid,
            basenames: ["droid"],
            pathNeedles: ["/bin/droid", "factory.ai", "/.factory/", "@factory", "Factory-AI", "factory/droid"],
            denyNeedles: ["crashpad", "android", "droidcam"]
        ),
        .init(
            id: .commandCode,
            basenames: ["cmd", "command-code"],
            pathNeedles: [
                "command-code",
                "commandcode",
                "Command Code",
                "⌘ Command Code",
                "/.commandcode/",
                "@command-code",
                "node_modules/command-code",
                "/opt/homebrew/bin/cmd",
                "/usr/local/bin/cmd",
            ],
            denyNeedles: ["crashpad", "cmd.exe", "cmdline-tools"],
            allowBareBasename: true
        ),
        .init(
            id: .antigravity,
            basenames: ["Antigravity", "antigravity", "Antigravity IDE", "agy"],
            pathNeedles: [
                "Antigravity.app/Contents/MacOS/Antigravity",
                "Antigravity IDE.app",
                "/bin/antigravity",
                "/.local/bin/agy",
                "/bin/agy",
                "google.antigravity",
            ],
            denyNeedles: ["crashpad", "Antigravity Helper", "AntigravityUI"],
            allowBareBasename: true
        ),
        .init(
            id: .kimi,
            basenames: ["kimi"],
            pathNeedles: ["kimi-code", "/.kimi-code/", "@moonshot-ai/kimi-code", "moonshotai/kimi", "/bin/kimi"],
            denyNeedles: ["crashpad", "Kimis", "kimisc"]
        ),
        .init(
            id: .zcode,
            basenames: ["ZCode", "zcode"],
            pathNeedles: [
                "ZCode.app/Contents/MacOS/ZCode",
                "ZCode.app/",
                "/.zcode/",
                "zcode.cjs",
                "Resources/glm/zcode",
            ],
            denyNeedles: [
                "crashpad",
                "ZCode Helper",
                "ZCode Account Switcher",
            ]
        ),
    ]

    static func scan(
        allowAppData: Bool = false,
        appDataAgents: Set<AgentID> = []
    ) -> [Hit] {
        // `cputime` and `rss` ride along in the fork that already happens.
        // A second `ps` for them would be a per-tick energy cost for facts the
        // first one can hand over for free, and cadence is an invariant here.
        //
        // Field order matters: `args=` is the only column that contains
        // spaces, so it must stay last — everything before it is one token.
        var output = psRejectsCPUFields ? "" : (shell("/bin/ps", ["-axo", psFieldsWithCPU]) ?? "")
        var includesCPU = !output.isEmpty
        if output.isEmpty {
            output = shell("/bin/ps", ["-axo", psFieldsBase]) ?? ""
            includesCPU = false
            // Only latch when the shorter list *worked*: that is the evidence
            // that the two new keywords were the problem, rather than a probe
            // that failed for a moment. This costs one extra fork, once.
            if !output.isEmpty, !psRejectsCPUFields {
                psRejectsCPUFields = true
                DebugLog.write("probe ps rejected cputime/rss; CPU reported as unknown")
            }
        }
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
        var procs = parseProcessLines(output, includesCPU: includesCPU)

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
        // One wall-clock stamp for the whole scan: every pid's window is then
        // measured against the same instant, and the arithmetic cannot drift
        // with how long the loop below takes.
        let sampledAtMs = Int64(Date().timeIntervalSince1970 * 1_000)
        var nextSamples: [Int: (cpuSeconds: Double, atMs: Int64)] = [:]
        for index in procs.indices {
            let p = procs[index]
            if p.args.contains("Warp.app") { continue }
            let evidenceArgs = argsByPid[p.pid] ?? p.args
            guard let match = matchEvidence(args: evidenceArgs) else { continue }
            let id = match.id
            // Sample only what we matched. Sampling the whole process table
            // would put several hundred entries a tick through a bounded
            // store, and evict the agents we actually care about.
            if p.cpuSeconds >= 0 {
                let previous = cpuSamples[p.pid]
                if let previous {
                    procs[index].cpuPercent = cpuPercent(
                        previousCPUSeconds: previous.cpuSeconds,
                        previousAtMs: previous.atMs,
                        currentCPUSeconds: p.cpuSeconds,
                        currentAtMs: sampledAtMs
                    )
                }
                if let previous,
                   sampledAtMs - previous.atMs < minCPUWindowMs,
                   p.cpuSeconds >= previous.cpuSeconds {
                    // Too soon to say anything. Keep the older anchor rather
                    // than overwriting it, or a fast cadence would reset the
                    // window every tick and the answer would stay unknown
                    // forever.
                    nextSamples[p.pid] = previous
                } else {
                    // Includes the pid-reuse / counter-rewind case: a negative
                    // delta means this is not the process we measured before,
                    // so its history is dropped and counting restarts here.
                    nextSamples[p.pid] = (p.cpuSeconds, sampledAtMs)
                }
            }
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
            let percent = procs[index].cpuPercent
            if percent >= 0 { hit.cpuPercent = max(hit.cpuPercent, percent) }
            if p.rssBytes > 0 { hit.rssBytes += p.rssBytes }
            acc[id] = hit
        }
        // Only replace the store when this scan actually saw a process table.
        // A failed `ps` must not erase every anchor and cost the next scan its
        // answer; `cputime` is cumulative, so a gap is survivable.
        if !procs.isEmpty { cpuSamples = boundedCPUSamples(nextSamples) }
        // `lsof` asks the kernel for another process's open cwd and can be
        // classified as cross-app data by macOS. Activity rows already carry
        // their workspace from the agent store; keep this enrichment behind
        // the same explicit privacy switch as deep app-data harvest. A scoped
        // grant is filtered by AgentID before any PID reaches lsof — selecting
        // Cursor must never widen the lookup to every matching process.
        var scopedAgents = appDataAgents
        if scopedAgents.contains(.cursor) || scopedAgents.contains(.cursorAgent) {
            scopedAgents.insert(.cursor)
            scopedAgents.insert(.cursorAgent)
        }
        if scopedAgents.contains(.cascade) || scopedAgents.contains(.windsurf) {
            scopedAgents.insert(.cascade)
            scopedAgents.insert(.windsurf)
        }
        let allowed = allowAppData ? Set(acc.keys) : scopedAgents
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
    /// **CPU and RSS must never enter this string.** They move every single
    /// tick by design, so including them would make the fingerprint differ
    /// from itself forever, the harvest skip would never fire again, and a
    /// menu-bar app would be running its most expensive path continuously —
    /// the exact energy failure the cadence invariant exists to prevent. The
    /// fingerprint answers "did the process set change", not "what are those
    /// processes doing".
    static func signature(_ hits: [Hit]) -> String {
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
    static func parseElapsed(_ raw: String) -> Double {
        let split = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "-", maxSplits: 1)
        let days = split.count == 2 ? Double(split[0]) ?? 0 : 0
        let clock = (split.last ?? "").split(separator: ":").compactMap { Double($0) }
        guard clock.count == 2 || clock.count == 3 else { return 0 }
        let hours = clock.count == 3 ? clock[0] : 0
        let minutes = clock.count == 3 ? clock[1] : clock[0]
        let seconds = clock.count == 3 ? clock[2] : clock[1]
        return days * 86_400 + hours * 3_600 + minutes * 60 + seconds
    }

    /// Parse one `ps` process table into rows.
    ///
    /// Pulled out of `scan` so the field order — the part that breaks silently
    /// when a column is added in the wrong place — can be held to real vendor
    /// output in a test without launching a single process.
    ///
    /// `includesCPU: false` is the degraded field list, without `cputime` and
    /// `rss`. Those rows report CPU as -1 (not known) rather than 0.
    static func parseProcessLines(_ output: String, includesCPU: Bool = true) -> [Proc] {
        let columns = includesCPU ? 7 : 5
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
            let rssKB = includesCPU ? (Int(parts[5]) ?? 0) : 0
            procs.append(Proc(
                pid: pid,
                ppid: ppid,
                tty: String(parts[2]),
                elapsedSeconds: parseElapsed(String(parts[3])),
                cpuSeconds: includesCPU ? parseCPUTime(String(parts[4])) : -1,
                rssBytes: rssKB > 0 ? rssKB * 1_024 : 0,
                // The remainder of the line, spaces and all. Trimmed only at
                // the front, where a right-aligned `rss` column can leave
                // padding behind.
                args: String(parts[columns - 1]).trimmingCharacters(in: .whitespaces)
            ))
        }
        return procs
    }

    /// `ps cputime`: `mm:ss.cc`, `hh:mm:ss[.cc]`, or `dd-hh:mm:ss[.cc]`.
    /// Returns accumulated CPU seconds, or **-1 when the field said nothing
    /// parseable** — distinct from 0, which means the process has burned no
    /// CPU at all.
    static func parseCPUTime(_ raw: String) -> Double {
        func number(_ field: Substring) -> Double? {
            guard !field.isEmpty else { return nil }
            // `Double` would happily take "inf", "nan" or "1e9"; none of those
            // is a time, and accepting one would put nonsense into a rate.
            guard field.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "." }) else { return nil }
            guard let value = Double(field), value.isFinite, value >= 0 else { return nil }
            return value
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return -1 }
        let daySplit = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        var days: Double = 0
        var clock = trimmed[trimmed.startIndex...]
        if daySplit.count == 2 {
            guard let parsed = number(daySplit[0]) else { return -1 }
            days = parsed
            clock = daySplit[1]
        }
        let fields = clock.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2 || fields.count == 3 else { return -1 }
        var values: [Double] = []
        for field in fields {
            guard let parsed = number(field) else { return -1 }
            values.append(parsed)
        }
        let hours = values.count == 3 ? values[0] : 0
        let minutes = values.count == 3 ? values[1] : values[0]
        let seconds = values.count == 3 ? values[2] : values[1]
        return days * 86_400 + hours * 3_600 + minutes * 60 + seconds
    }

    /// CPU actually burned between two readings, as a percentage of one core.
    ///
    /// Deliberately **not** `ps %cpu`: on macOS that column is an average over
    /// the whole life of the process, so an agent that worked hard for ten
    /// minutes and has been parked for three hours still reports a healthy
    /// number. Presenting it as "busy now" would be a lie of exactly the kind
    /// this product exists to avoid. Two readings of the cumulative counter,
    /// subtracted, describe the interval between them and nothing else — the
    /// same construction `SessionDigest.bytesPerMinute` uses for transcript
    /// growth.
    ///
    /// Returns -1 for "not known": no previous reading, a window too short to
    /// divide by, or a counter that went backwards (pid reuse — a new process
    /// wearing a dead one's number, whose history means nothing).
    static func cpuPercent(
        previousCPUSeconds: Double,
        previousAtMs: Int64,
        currentCPUSeconds: Double,
        currentAtMs: Int64
    ) -> Double {
        guard previousAtMs > 0,
              previousCPUSeconds >= 0,
              currentCPUSeconds >= 0,
              previousCPUSeconds.isFinite,
              currentCPUSeconds.isFinite else { return -1 }
        let elapsedMs = currentAtMs - previousAtMs
        guard elapsedMs >= minCPUWindowMs else { return -1 }
        let burned = currentCPUSeconds - previousCPUSeconds
        guard burned >= 0 else { return -1 }
        let percent = (burned / (Double(elapsedMs) / 1_000)) * 100
        guard percent.isFinite else { return -1 }
        return min(percent, maxCPUPercent)
    }

    /// Keep the per-pid sample store bounded. Entries already belong to
    /// processes seen in this scan, so the usual eviction is simply that a pid
    /// stopped appearing; this is the floor under a machine with an
    /// implausible number of live agents.
    static func boundedCPUSamples(
        _ samples: [Int: (cpuSeconds: Double, atMs: Int64)]
    ) -> [Int: (cpuSeconds: Double, atMs: Int64)] {
        guard samples.count > maxCPUSamples else { return samples }
        var trimmed: [Int: (cpuSeconds: Double, atMs: Int64)] = [:]
        for entry in samples.sorted(by: { $0.value.atMs > $1.value.atMs }).prefix(maxCPUSamples) {
            trimmed[entry.key] = entry.value
        }
        return trimmed
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
    static func parseWorkingDirectories(_ output: String) -> [Int: String] {
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
    static func usefulWorkingDirectory(_ raw: String) -> String {
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
    static func isLsofErrorAnnotated(_ path: String) -> Bool {
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
    static func match(args: String) -> AgentID? {
        matchEvidence(args: args)?.id
    }

    struct Match: Equatable {
        var id: AgentID
        var evidence: ProcessEvidence
    }

    /// Match plus a privacy-safe explanation for support diagnostics.
    static func matchEvidence(args: String) -> Match? {
        let exe = args.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? args
        let base = (exe as NSString).lastPathComponent
        for rule in rules {
            if rule.denyNeedles.contains(where: { args.contains($0) }) { continue }
            let baseHit = rule.basenames.contains { $0.caseInsensitiveCompare(base) == .orderedSame }
            // Prefer path needles; bare basename only when explicitly trusted,
            // pathNeedles are absent, or the name is naturally distinctive.
            let pathHit = rule.pathNeedles.contains { args.contains($0) }
            if pathHit { return Match(id: rule.id, evidence: .pathSignature) }
            // Electron gives many Cursor helper processes the same `Cursor`
            // comm name as the GUI. They do not contain the app's main
            // executable path, so treating the basename as a hit inflated one
            // app into a misleading "15 processes" row.
            if rule.id == .cursor, baseHit { continue }
            if baseHit, !rule.pathNeedles.isEmpty {
                if base.count <= 3 && !rule.allowBareBasename {
                    continue
                }
                return Match(id: rule.id, evidence: .executable)
            }
            if baseHit, rule.pathNeedles.isEmpty {
                return Match(id: rule.id, evidence: .executable)
            }
        }
        return nil
    }

    /// One probe subprocess, exit status included. `nil` means the tool could
    /// not be launched or had to be killed — the only states in which its
    /// output says nothing at all.
    struct Invocation: Equatable {
        var stdout: String
        var status: Int32
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
    static func workingDirectories(from invocation: Invocation?) -> [Int: String] {
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
    static func shouldBackOff(_ invocation: Invocation?, pids: [Int]) -> Bool {
        guard let invocation else { return true }
        if invocation.status == 0 { return true }
        // Non-zero: `lsof` reported it could not resolve something. If nothing
        // we asked about is alive, that is the whole explanation.
        return pids.contains(where: processExists)
    }

    /// Liveness only — no signal is sent.
    static func processExists(_ pid: Int) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }
}
