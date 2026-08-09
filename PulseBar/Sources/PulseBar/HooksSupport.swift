import Foundation

enum HooksSupport {
    enum Status: Equatable {
        case unknown
        case missing
        case installedClaude
        case installedCodex
        case installedBoth
        case failed(String)

        func label(lang: ResolvedLanguage) -> String {
            switch self {
            case .unknown: return L10n.t(.hooksUnknown, lang)
            case .missing: return L10n.t(.hooksMissing, lang)
            case .installedBoth: return L10n.t(.hooksInstalledBoth, lang)
            case .installedClaude: return L10n.t(.hooksInstalledClaude, lang)
            case .installedCodex: return L10n.t(.hooksInstalledCodex, lang)
            case .failed(let m): return "\(L10n.t(.hooksFailed, lang)) · \(m)"
            }
        }

        func isInstalled(for agent: AgentID) -> Bool {
            switch (self, agent) {
            case (.installedBoth, .claude), (.installedBoth, .codex),
                 (.installedClaude, .claude), (.installedCodex, .codex):
                return true
            default:
                return false
            }
        }
    }

    enum SelfTestResult: Equatable {
        case idle
        case running
        case passed(Date)
        case failed(String)
    }

    static func supportDir() -> URL {
        if let home = HooksInstaller.homeOverride {
            return home.appendingPathComponent("Library/Application Support/Pulse")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pulse")
    }

    /// Seed optional legacy Python assets + native launcher.
    /// Native install/self-test never require Python; the `.py` files remain for
    /// users who already wired `python3 …/pulse_hook.py` by hand.
    static func seedAssets() {
        let fm = FileManager.default
        let dir = supportDir()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["pulse_hook.py", "install_hooks.py"] {
            guard let src = resourceURL(named: name) else { continue }
            let dest = dir.appendingPathComponent(name)
            let srcText = (try? String(contentsOf: src, encoding: .utf8)) ?? ""
            if fm.fileExists(atPath: dest.path),
               let destText = try? String(contentsOf: dest, encoding: .utf8) {
                if destText == srcText { continue }
                // Never replace a flock-aware hook with a weaker bundled copy.
                if name == "pulse_hook.py",
                   destText.contains("fcntl.flock"),
                   !srcText.contains("fcntl.flock") {
                    DebugLog.write("seed skip downgrade \(name)")
                    continue
                }
                try? fm.removeItem(at: dest)
            }
            try? fm.copyItem(at: src, to: dest)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        }
        try? HooksInstaller.ensureLauncher()
        HooksInstaller.refreshRunnerPath()
        seedAttentionBridgeKit()
    }

    static func attentionBridgeKitDir() -> URL {
        supportDir().appendingPathComponent("attention-bridge", isDirectory: true)
    }

    /// Seed a minimal Attention bridge kit next to `pulse-hook`.
    /// Not an installer for other agents — raise/clear samples only (0.90).
    static func seedAttentionBridgeKit() {
        let fm = FileManager.default
        let dir = attentionBridgeKitDir()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let raise = #"""
        #!/bin/sh
        # Pulse Attention bridge sample — prefer native pulse-hook (0.90 kit).
        # Usage: raise.sh <agent_id> [session] [kind] [message]
        set -e
        PULSE="${PULSE_HOME:-$HOME/Library/Application Support/Pulse}"
        mkdir -p "$PULSE"
        agent="${1:?usage: raise.sh <agent_id> [session] [kind] [message]}"
        session="${2:-sample-$agent}"
        kind="${3:-permission}"
        message="${4:-Approve tool (sample)}"
        HOOK="$PULSE/pulse-hook"
        if [ -x "$HOOK" ]; then
          printf '%s\n' "{\"notification_type\":\"$kind\",\"message\":\"$message\",\"session_id\":\"$session\",\"cwd\":\"$PWD\"}" \
            | "$HOOK" "$agent"
          echo "Wrote $agent Waiting via pulse-hook (session=$session kind=$kind)"
          exit 0
        fi
        ms=$(($(date +%s) * 1000))
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$agent" "$kind" "$ms" "$message" "$session" "$PWD" >> "$PULSE/attention.tsv"
        echo "Wrote $agent Waiting → $PULSE/attention.tsv"
        """#
        let clear = #"""
        #!/bin/sh
        # Clear Attention bridge Waiting for one agent id (argv) or all Waiting-none.
        set -e
        PULSE="${PULSE_HOME:-$HOME/Library/Application Support/Pulse}"
        mkdir -p "$PULSE"
        ms=$(($(date +%s) * 1000))
        if [ "$#" -eq 0 ]; then
          set -- replit devin warpAgent trae antigravity junie zcode
        fi
        for agent in "$@"; do
          printf '%s\tdone\t%s\t\t\t\n' "$agent" "$ms" >> "$PULSE/attention.tsv"
          echo "Cleared $agent"
        done
        """#
        let readme = """
        Pulse Attention bridge kit (0.90)
        =================================
        raise.sh <agent_id>   Prefer pulse-hook; falls back to attention.tsv
        clear.sh [agent…]     Defaults to all Waiting-none agents (includes zcode)
        Protocol: docs/attention-protocol.md — not a Claude/Codex hook installer.
        """
        writeKitFile(dir.appendingPathComponent("raise.sh"), raise, executable: true)
        writeKitFile(dir.appendingPathComponent("clear.sh"), clear, executable: true)
        writeKitFile(dir.appendingPathComponent("README.txt"), readme, executable: false)
    }

    private static func writeKitFile(_ url: URL, _ text: String, executable: Bool) {
        let fm = FileManager.default
        let data = Data(text.utf8)
        if fm.fileExists(atPath: url.path),
           let existing = try? Data(contentsOf: url),
           existing == data {
            return
        }
        try? data.write(to: url, options: .atomic)
        if executable {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    static func probeStatus() -> Status {
        let launcher = HooksInstaller.launcherURL
        let legacy = supportDir().appendingPathComponent(HooksInstaller.legacyHookName)
        let hasAsset = FileManager.default.isExecutableFile(atPath: launcher.path)
            || FileManager.default.fileExists(atPath: legacy.path)
        guard hasAsset else { return .missing }

        let home = HooksInstaller.homeURL
        let claudeCandidates = [
            home.appendingPathComponent(".claude/settings.json"),
            home.appendingPathComponent(".claude/settings.local.json"),
        ]
        let codex = home.appendingPathComponent(".codex/config.toml")
        let claudeOK = claudeCandidates.contains { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return HooksInstaller.containsPulseMarker(text)
        }
        let codexOK: Bool = {
            guard let text = try? String(contentsOf: codex, encoding: .utf8) else { return false }
            return HooksInstaller.containsPulseMarker(text)
        }()
        switch (claudeOK, codexOK) {
        case (true, true): return .installedBoth
        case (true, false): return .installedClaude
        case (false, true): return .installedCodex
        case (false, false): return .missing
        }
    }

    /// Remove Pulse hooks from Claude/Codex configs. Native — no Python.
    @discardableResult
    static func uninstall() -> Status {
        seedAssets()
        do {
            _ = try HooksInstaller.uninstall()
        } catch {
            return .failed(error.localizedDescription)
        }
        return probeStatus()
    }

    /// Install native `pulse-hook` into Claude/Codex configs. No Python.
    @discardableResult
    static func install() -> Status {
        seedAssets()
        do {
            _ = try HooksInstaller.install()
        } catch {
            return .failed(error.localizedDescription)
        }
        let status = probeStatus()
        return status == .missing ? .missing : status
    }

    /// Exercise the native hook receiver end-to-end in an isolated temporary
    /// Pulse home. Never writes a fake wait into the user's attention log and
    /// never asks for Automation, Accessibility, or Screen Recording.
    /// Does **not** require Python.
    static func selfTest() -> SelfTestResult {
        seedAssets()
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent(
            "pulse-hook-selftest-\(UUID().uuidString)",
            isDirectory: true
        )
        let previousOverride = AttentionIO.pathOverride
        do {
            try fm.createDirectory(at: temp, withIntermediateDirectories: true)
            defer {
                AttentionIO.pathOverride = previousOverride
                try? fm.removeItem(at: temp)
            }
            AttentionIO.pathOverride = temp.appendingPathComponent("attention.tsv")
            PulseHookReceiver.appendEvent(
                agent: "codex",
                kind: PulseHookReceiver.normalizeKind("request_user_input"),
                message: "Pulse self-test",
                session: "selftest",
                cwd: ""
            )
            // Also exercise argv/stdin parsing the vendor path uses.
            _ = PulseHookReceiver.run(
                arguments: ["--hook", "codex", "request_user_input"],
                stdin: #"{"message":"Pulse self-test","session_id":"selftest"}"#
            )
            let text = try String(contentsOf: AttentionIO.path, encoding: .utf8)
            guard text.contains("codex\tidle_prompt\t"),
                  text.contains("\tPulse self-test\tselftest\t")
            else { return .failed("hook output mismatch") }
            return .passed(Date())
        } catch {
            AttentionIO.pathOverride = previousOverride
            return .failed(error.localizedDescription)
        }
    }

    private static func resourceURL(named name: String) -> URL? {
        let fm = FileManager.default
        // Prefer repo src/ in dev so seed never ships stale Resources.
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repo = here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("src/\(name)")
        if Bundle.main.bundleURL.pathExtension != "app",
           fm.fileExists(atPath: repo.path) {
            return repo
        }
        if let res = Bundle.main.resourceURL?.appendingPathComponent(name),
           fm.fileExists(atPath: res.path) {
            return res
        }
        if let url = PulseResources.url(forResource: name.replacingOccurrences(of: ".py", with: ""), withExtension: "py") {
            return url
        }
        let bundled = here.appendingPathComponent("Resources/\(name)")
        if fm.fileExists(atPath: bundled.path) { return bundled }
        return nil
    }
}
