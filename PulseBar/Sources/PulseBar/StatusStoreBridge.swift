import Foundation
import AppKit

/// 4.0-γ file split — Attention bridge reach — deep links, sample writes, hook launcher.
/// Behavior-frozen: every member moved verbatim from StatusStore.swift;
/// the full test suite is the contract that nothing changed.
extension StatusStore {
    func openSettings(
        focusAppDataFor agent: AgentID? = nil,
        focusWaitingSignals: Bool = false,
        focusWaitingAgent: AgentID? = nil
    ) {
        settingsFocusAppDataAgent = agent
        if agent != nil {
            settingsExpandAppDataScopes = true
        }
        settingsFocusWaitingSignals = focusWaitingSignals
        settingsFocusWaitingAgent = focusWaitingAgent
        SettingsWindowController.shared.show(
            store: self,
            focusAppDataFor: agent,
            focusWaitingSignals: focusWaitingSignals
        )
    }

    /// Open the Pulse Application Support folder so the Attention bridge path
    /// is one click away — never expands the hook installer past Claude/Codex.
    func revealAttentionBridgeFolder() {
        ensurePulseHookLauncher()
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pulse", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    /// Reveal the seeded bridge kit (`raise.sh` / `clear.sh`) under Application Support.
    func revealAttentionBridgeKit() {
        ensurePulseHookLauncher()
        let url = HooksSupport.attentionBridgeKitDir()
        NSWorkspace.shared.open(url)
    }

    /// Write or refresh native `pulse-hook` only — does **not** merge Claude/Codex hooks.
    func ensurePulseHookLauncher() {
        do {
            try HooksInstaller.ensureLauncher()
            HooksInstaller.refreshRunnerPath()
            HooksSupport.seedAttentionBridgeKit()
            refreshPulseHookLauncherStatus()
            DebugLog.write("pulse-hook launcher ensured ready=\(pulseHookLauncherReady)")
        } catch {
            refreshPulseHookLauncherStatus()
            DebugLog.write("pulse-hook launcher ensure failed \(error.localizedDescription)")
        }
    }

    func refreshPulseHookLauncherStatus() {
        pulseHookLauncherReady = FileManager.default.isExecutableFile(
            atPath: HooksInstaller.launcherURL.path
        )
    }

    /// Agents with `waitingSource=.none` — derived from `AgentID.waitingNoneAgents`.
    /// Does not expand the Claude/Codex hook installer.
    nonisolated static var attentionSampleAgents: [AgentID] { AgentID.waitingNoneAgents }

    /// Localized sample hint listing every Waiting-none display name from the
    /// enum — never a hand-maintained seven-name string.
    ///
    /// The list is derived from `AgentID.waitingNoneAgents`, so these four
    /// sentences cannot be plain table lookups — but the *sentences* still
    /// belong in `L10n` (EXPERIENCE §4: every user-facing string goes through
    /// the table). They used to switch on `lang` inline, which is the same
    /// defect one indirection later.
    func attentionBridgeWriteSampleHintText() -> String {
        let names = Self.attentionSampleAgents.map(\.displayName)
        return String(
            format: tr(.attentionBridgeWriteSampleHintNamed),
            names.count,
            L10n.joinNames(names, lang)
        )
    }

    func attentionBridgeHintText() -> String {
        let names = Self.attentionSampleAgents.map(\.displayName)
        return String(format: tr(.attentionBridgeHintNamed), L10n.joinNames(names, lang))
    }

    func attentionBridgeFocusHintText() -> String {
        guard let agent = settingsFocusWaitingAgent else {
            return tr(.attentionBridgeFocusHint)
        }
        return String(format: tr(.attentionBridgeFocusHintNamed), agent.displayName)
    }

    func waitingReachStepsText() -> String {
        guard let agent = settingsFocusWaitingAgent else {
            return tr(.waitingReachSteps)
        }
        return String(format: tr(.waitingReachStepsNamed), agent.displayName)
    }

    func attentionRaiseCommand(for agent: AgentID) -> String {
        let hook = HooksInstaller.launcherURL.path
        let quoted = hook.contains(" ") ? "\"\(hook)\"" : hook
        return "\(quoted) \(agent.rawValue)"
    }

    func copyAttentionRaiseCommand(for agent: AgentID? = nil) {
        let target = agent ?? settingsFocusWaitingAgent ?? firstLiveWaitingNoneAgent ?? .zcode
        ensurePulseHookLauncher()
        let command = attentionRaiseCommand(for: target)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(command, forType: .string)
        didCopyAttentionRaise = true
        DebugLog.write("attention raise command copied agent=\(target.rawValue)")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            self?.didCopyAttentionRaise = false
        }
    }

    /// Settings one-click sample Waiting via Attention bridge.
    /// When `agent` is set, only that Waiting-none Agent is raised (Reach funnel).
    func writeAttentionBridgeSample(for agent: AgentID? = nil) {
        ensurePulseHookLauncher()
        let cwd = FileManager.default.homeDirectoryForCurrentUser.path
        let agents: [AgentID]
        if let agent {
            guard agent.waitingSource == .none else { return }
            agents = [agent]
        } else {
            agents = Self.attentionSampleAgents
        }
        for id in agents {
            AttentionIO.appendPermission(
                agent: id,
                message: "Approve tool (sample)",
                session: "pulse-sample",
                cwd: cwd
            )
        }
        DebugLog.write(
            "attention sample written agents=\(agents.map(\.rawValue).joined(separator: ",")) session=pulse-sample"
        )
        pendingSampleRevealSession = "pulse-sample"
        refresh(reason: "attentionSample")
    }

    func applyPendingSampleReveal() {
        guard !pendingSampleRevealSession.isEmpty else { return }
        if let row = cachedAll.first(where: {
            $0.sessionID == pendingSampleRevealSession && $0.waiting
        }) {
            requestTrayReveal(rowKey: row.rowKey)
            pendingSampleRevealSession = ""
        }
    }

    /// Test seam: sample Go-Look waits until the named session row exists.
    func testingRevealSampleIfPresent(session: String) {
        pendingSampleRevealSession = session
        applyPendingSampleReveal()
    }

    var testingHasPendingSampleReveal: Bool { !pendingSampleRevealSession.isEmpty }

    func clearAttentionBridgeSample() {
        for agent in Self.attentionSampleAgents {
            AttentionIO.appendDone(agent: agent, session: "pulse-sample")
        }
        DebugLog.write(
            "attention sample cleared agents=\(Self.attentionSampleAgents.map(\.rawValue).joined(separator: ",")) session=pulse-sample"
        )
        refresh(reason: "attentionSampleClear")
    }
}
