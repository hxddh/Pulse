import Foundation
import AppKit

/// 4.0-γ file split — Settings persistence and application.
/// Behavior-frozen: every member moved verbatim from StatusStore.swift;
/// the full test suite is the contract that nothing changed.
extension StatusStore {
    private func applyLaunchAtLoginIfChanged() {
        guard appliedLaunchAtLogin != launchAtLogin else { return }
        appliedLaunchAtLogin = launchAtLogin
        let enabled = launchAtLogin
        DispatchQueue.global(qos: .utility).async {
            let applied = LoginItem.setEnabled(enabled)
            Task { @MainActor [weak self] in self?.loginItemApplied = applied }
        }
    }


    private func settingsURL() -> URL {
        PulseSettings.settingsFileURL()
    }

    /// Snapshot of the settings the store currently holds.
    var currentSettings: PulseSettings {
        PulseSettings(
            notifyOnIdle: notifyOnIdle,
            notifyOnWaiting: notifyOnWaiting,
            launchAtLogin: launchAtLogin,
            language: language,
            updateCheckEnabled: updateCheckEnabled,
            allowAppData: allowAppData,
            appDataAgents: appDataAgents,
            hotkey: hotkey,
            allowTerminalAutomation: allowTerminalAutomation,
            mutedAgents: mutedAgents,
            hooksNudgeOff: hooksNudgeOff
        )
    }

    func apply(_ s: PulseSettings) {
        notifyOnIdle = s.notifyOnIdle
        notifyOnWaiting = s.notifyOnWaiting
        launchAtLogin = s.launchAtLogin
        language = s.language
        updateCheckEnabled = s.updateCheckEnabled
        allowAppData = s.allowAppData
        appDataAgents = s.appDataAgents
        hotkey = s.hotkey
        allowTerminalAutomation = s.allowTerminalAutomation
        mutedAgents = s.mutedAgents
        hooksNudgeOff = s.hooksNudgeOff
    }

    func loadSettings() {
        guard let text = try? String(contentsOf: settingsURL(), encoding: .utf8) else {
            appliedLaunchAtLogin = launchAtLogin
            return
        }
        let parsed = PulseSettings.parse(text)
        apply(parsed)
        DebugLog.write("settings \(parsed.debugDescription)")
        // Launchd already reflects the persisted value at load; don't re-run it.
        appliedLaunchAtLogin = launchAtLogin
    }

    func saveSettings() {
        persistSettingsOnly()
        // Banner button titles are baked into the registered category, so they
        // go stale on a language switch unless re-registered here.
        PulseNotify.registerCategories(lang: lang)
        applyLaunchAtLoginIfChanged()
        applyHotkey()
        UpdateCheck.shared.startIfEnabled(store: self)
        rescheduleTimer()
        refresh(reason: "saveSettings")
    }

    /// Write settings without scheduling a full roster harvest. Used by
    /// per-Agent App Data toggles that refresh only the affected adapters.
    func persistSettingsOnly() {
        let dir = settingsURL().deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? currentSettings.serialized().write(to: settingsURL(), atomically: true, encoding: .utf8)
    }

    /// Soft-dismiss tombstones for harvest pending — survive relaunch until
    /// the builder observes a natural clear or complete absence (0.95).
    private static func dismissedPendingURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pulse/dismissed-pending.json")
    }

    static func loadDismissedPendingKeys() -> Set<String> {
        let url = dismissedPendingURL()
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(decoded.filter { !$0.isEmpty })
    }

    func persistDismissedPendingKeys() {
        let url = Self.dismissedPendingURL()
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keys = Array(dismissedPendingKeys).sorted()
        guard let data = try? JSONEncoder().encode(keys) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Follow a process-only → session identity change so dismiss and delivery state survive.
    func migrateRowIdentity(from oldKey: String, to newKey: String) {
        guard oldKey != newKey, !newKey.isEmpty else { return }
        if dismissedPendingKeys.remove(oldKey) != nil {
            dismissedPendingKeys.insert(newKey)
            persistDismissedPendingKeys()
        }
        if let queued = pendingWaitingNotifications.removeValue(forKey: oldKey) {
            var moved = queued
            moved.rowKey = newKey
            pendingWaitingNotifications[newKey] = moved
        }
        if knownWaitingKeys.remove(oldKey) != nil {
            knownWaitingKeys.insert(newKey)
        }
        if waitingDeliveryInFlight.remove(oldKey) != nil {
            waitingDeliveryInFlight.insert(newKey)
        }
        attentionLedger.remapRowKey(from: oldKey, to: newKey)
        attentionLedger.save()
        DebugLog.write("row identity \(DebugLog.key(oldKey)) → \(DebugLog.key(newKey))")
    }

    /// Re-register the global shortcut and report honestly when the system
    /// refuses (another app already owns the combination).
    func applyHotkey() {
        let choice = hotkey
        hotkeyRegistered = GlobalHotKey.install(choice: choice)
        if choice != .off, !hotkeyRegistered {
            DebugLog.write("hotkey \(hotkey.rawValue) registration FAILED — likely taken")
        }
    }

    /// Open Settings, optionally scrolled to an agent's data access or to
    /// the hook connections (how an agent gets a Waiting signal).
    func openSettings(
        focusAppDataFor agent: AgentID? = nil,
        focusWaitingSignals: Bool = false
    ) {
        settingsFocusAppDataAgent = agent
        if agent != nil {
            settingsExpandAppDataScopes = true
        }
        settingsFocusWaitingSignals = focusWaitingSignals
        SettingsWindowController.shared.show(
            store: self,
            focusAppDataFor: agent,
            focusWaitingSignals: focusWaitingSignals
        )
    }

    func toggleMute(_ agent: AgentID) {
        if mutedAgents.contains(agent) {
            mutedAgents.remove(agent)
        } else {
            mutedAgents.insert(agent)
        }
        saveSettings()
    }
}
