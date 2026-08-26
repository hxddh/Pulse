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
            autoProbe: autoProbe,
            notifyOnIdle: notifyOnIdle,
            notifyOnWaiting: notifyOnWaiting,
            quietHoursEnabled: quietHoursEnabled,
            quietStartMinute: quietStartMinute,
            quietEndMinute: quietEndMinute,
            launchAtLogin: launchAtLogin,
            language: language,
            updateCheckEnabled: updateCheckEnabled,
            allowAppData: allowAppData,
            appDataAgents: appDataAgents,
            hotkey: hotkey,
            hotkeyEnabled: hotkeyEnabled,
            allowTerminalAutomation: allowTerminalAutomation,
            allowWorkbenchActuation: allowWorkbenchActuation,
            measureWorkspaceEffect: measureWorkspaceEffect,
            broadcastFleet: broadcastFleet,
            mutedAgents: mutedAgents,
            trayGrouping: trayGrouping,
            playSoundOnWaiting: playSoundOnWaiting,
            stallMinutes: stallMinutes,
            snoozeMinutes: snoozeMinutes
        )
    }

    func apply(_ s: PulseSettings) {
        autoProbe = s.autoProbe
        notifyOnIdle = s.notifyOnIdle
        notifyOnWaiting = s.notifyOnWaiting
        quietHoursEnabled = s.quietHoursEnabled
        quietStartMinute = s.quietStartMinute
        quietEndMinute = s.quietEndMinute
        launchAtLogin = s.launchAtLogin
        language = s.language
        updateCheckEnabled = s.updateCheckEnabled
        allowAppData = s.allowAppData
        appDataAgents = s.appDataAgents
        hotkey = s.hotkey
        hotkeyEnabled = s.hotkeyEnabled
        allowTerminalAutomation = s.allowTerminalAutomation
        allowWorkbenchActuation = s.allowWorkbenchActuation
        measureWorkspaceEffect = s.measureWorkspaceEffect
        broadcastFleet = s.broadcastFleet
        mutedAgents = s.mutedAgents
        trayGrouping = s.trayGrouping
        playSoundOnWaiting = s.playSoundOnWaiting
        stallMinutes = s.stallMinutes
        snoozeMinutes = s.snoozeMinutes
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
        quietStartMinute = PulseSettings.clampMinute(quietStartMinute)
        quietEndMinute = PulseSettings.clampMinute(quietEndMinute)
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

    /// Follow a process-only → session identity change so snooze/dismiss survive.
    func migrateRowIdentity(from oldKey: String, to newKey: String) {
        guard oldKey != newKey, !newKey.isEmpty else { return }
        if dismissedPendingKeys.remove(oldKey) != nil {
            dismissedPendingKeys.insert(newKey)
            persistDismissedPendingKeys()
        }
        if let until = snoozedUntil.removeValue(forKey: oldKey) {
            snoozedUntil[newKey] = until
        }
        if let queued = pendingWaitingNotifications.removeValue(forKey: oldKey) {
            var moved = queued
            moved.rowKey = newKey
            pendingWaitingNotifications[newKey] = moved
        }
        if knownWaitingKeys.remove(oldKey) != nil {
            knownWaitingKeys.insert(newKey)
        }
        if lookMovedRowKeys.remove(oldKey) != nil {
            lookMovedRowKeys.insert(newKey)
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
        let choice = hotkeyEnabled ? hotkey : .off
        hotkeyRegistered = GlobalHotKey.install(choice: choice)
        if choice != .off, !hotkeyRegistered {
            DebugLog.write("hotkey \(hotkey.rawValue) registration FAILED — likely taken")
        }
    }

    /// Create or remove `respond-local.key`, then read back what actually
    /// happened. The hook's rule is "no key, no hold", so a failed write must
    /// leave the switch off rather than promising something no agent will do.
    func setRespondLocalEnabled(_ enabled: Bool) {
        RespondSpool.setLocalAnsweringEnabled(enabled)
        let actual = RespondSpool.localHasSecret()
        if respondLocalEnabled != actual { respondLocalEnabled = actual }
        DebugLog.write("respond local answering requested=\(enabled) actual=\(actual)")
    }

    /// Turning the broadcast off also removes this Mac's file: a snapshot
    /// nobody is refreshing must age out on the readers, not keep riding the
    /// sync tool looking authoritative.
    func setBroadcastFleet(_ enabled: Bool) {
        broadcastFleet = enabled
        saveSettings()
        if !enabled {
            let own = FleetSnapshot.directory
                .appendingPathComponent(FleetSnapshot.sanitize(PulseHookReceiver.respondHost()) + ".json")
            scanQueue.async { try? FileManager.default.removeItem(at: own) }
            lastFleetWriteMs = 0
        }
    }

    func toggleMute(_ agent: AgentID) {
        if mutedAgents.contains(agent) {
            mutedAgents.remove(agent)
        } else {
            mutedAgents.insert(agent)
        }
        saveSettings()
    }

    func isInQuietHours(now: Date = Date()) -> Bool {
        currentSettings.isInQuietHours(now: now)
    }
}
