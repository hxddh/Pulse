import Foundation

/// Port of Zig probe rules for surface coding agents (+ Warp parent + TTY).
enum ProcessProbe {
    /// `lsof` is only needed when a new agent process appears. Re-running it at
    /// the 2 s Waiting cadence would turn one useful fallback fact into a
    /// permanent energy cost.
    private static var cwdCache: [Int: (path: String, observedAt: TimeInterval)] = [:]

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
            basenames: ["Antigravity", "antigravity", "Antigravity IDE"],
            pathNeedles: [
                "Antigravity.app/Contents/MacOS/Antigravity",
                "Antigravity IDE.app",
                "/bin/antigravity",
                "google.antigravity",
            ],
            denyNeedles: ["crashpad", "Antigravity Helper", "AntigravityUI"]
        ),
        .init(
            id: .kimi,
            basenames: ["kimi"],
            pathNeedles: ["kimi-code", "/.kimi-code/", "@moonshot-ai/kimi-code", "moonshotai/kimi", "/bin/kimi"],
            denyNeedles: ["crashpad", "Kimis", "kimisc"]
        ),
    ]

    static func scan() -> [Hit] {
        let output = shell("/bin/ps", ["-axo", "pid=,ppid=,tty=,etime=,args="]) ?? ""
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
        var procs: [(pid: Int, ppid: Int, tty: String, elapsed: Double, args: String)] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(maxSplits: 4, whereSeparator: { $0.isWhitespace || $0 == "\t" })
            guard parts.count >= 5,
                  let pid = Int(parts[0]),
                  let ppid = Int(parts[1]) else { continue }
            procs.append((
                pid,
                ppid,
                String(parts[2]),
                parseElapsed(String(parts[3])),
                String(parts[4])
            ))
        }

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
            if id == .cursor { continue }
            var hit = acc[id] ?? Hit(id: id, count: 0, viaWarp: false)
            hit.count += 1
            hit.evidence = match.evidence
            if underWarp(p.pid) { hit.viaWarp = true }
            if hit.pid == 0 {
                hit.pid = p.pid
                hit.tty = resolveTTY(p.pid)
                hit.elapsedSeconds = p.elapsed
            } else if hit.tty.isEmpty {
                let t = resolveTTY(p.pid)
                if !t.isEmpty {
                    hit.pid = p.pid
                    hit.tty = t
                    hit.elapsedSeconds = p.elapsed
                }
            }
            acc[id] = hit
        }
        let workingDirectories = currentWorkingDirectories(
            pids: acc.values.map(\.pid).filter { $0 > 0 }
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

    /// Parse `lsof -Fpn -a -d cwd -p ...` without depending on column spacing.
    static func parseWorkingDirectories(_ output: String) -> [Int: String] {
        var result: [Int: String] = [:]
        var pid: Int?
        var sawCwd = false
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.hasPrefix("p"), let value = Int(line.dropFirst()) {
                pid = value
                sawCwd = false
            } else if line == "fcwd" {
                sawCwd = true
            } else if line.hasPrefix("n"), sawCwd, let pid {
                result[pid] = String(line.dropFirst())
                sawCwd = false
            }
        }
        return result
    }

    /// Keep only paths that can identify user work. `/`, app bundles and
    /// support folders are implementation context, not a project.
    static func usefulWorkingDirectory(_ raw: String) -> String {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), path != "/" else { return "" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path != home, path != home + "/" else { return "" }
        let excluded = [
            "/Applications/", "/System/", "/Library/",
            home + "/Library/", "/private/var/", "/var/",
        ]
        guard !excluded.contains(where: path.hasPrefix) else { return "" }
        return path
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
            let list = unresolved.map(String.init).joined(separator: ",")
            let output = shell(
                "/usr/sbin/lsof",
                ["-Fpn", "-a", "-d", "cwd", "-p", list]
            ) ?? ""
            for (pid, path) in parseWorkingDirectories(output) {
                cwdCache[pid] = (path, now)
                result[pid] = path
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

    private static func shell(_ launchPath: String, _ arguments: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        task.standardOutput = out
        task.standardError = err
        do {
            try task.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            _ = err.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
