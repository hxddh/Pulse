// 3.0-α: the settings scene, moved verbatim out of PulseApp.swift.

import SwiftUI
import AppKit

@MainActor
struct SettingsView: View {
    @ObservedObject var store: StatusStore
    @State private var confirmDuplicateRemoval = false

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                generalSection
                notificationsSection
                waitingSignalsSection
                    .id("settings-waiting-signals")
                shortcutsSection
                if !store.waitHistory.isEmpty { historySection }
                aboutSection
            }
            .formStyle(.grouped)
            .padding(8)
            .background(Color(nsColor: .windowBackgroundColor))
            .onAppear {
                store.hooksStatus = HooksSupport.probeStatus()
                store.refreshInstallTruth()
                PulseNotify.refreshAuthorization()
                scrollToWaitingIfNeeded(proxy)
            }
            .onChange(of: store.settingsFocusWaitingSignals) { _, focused in
                if focused { scrollToWaitingIfNeeded(proxy) }
            }
            .alert(
                store.tr(.removeDuplicateApps),
                isPresented: $confirmDuplicateRemoval
            ) {
                Button(store.tr(.cancel), role: .cancel) {}
                Button(store.tr(.moveToTrash), role: .destructive) {
                    store.recycleDuplicateApps()
                }
            } message: {
                Text(String(
                    format: store.tr(.removeDuplicateAppsConfirm),
                    store.installReport.removableDuplicates.count
                ))
            }
        }
    }

    private func scrollToWaitingIfNeeded(_ proxy: ScrollViewProxy) {
        guard store.settingsFocusWaitingSignals else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo("settings-waiting-signals", anchor: .top)
            }
        }
    }

    // MARK: General

    private var generalSection: some View {
        Section(store.tr(.general)) {
            Toggle(store.tr(.liveUpdates), isOn: $store.autoProbe)
                .onChange(of: store.autoProbe) { _, _ in store.saveSettings() }
            Toggle(store.tr(.agentDataAccess), isOn: Binding(
                get: { store.allowAppData },
                set: { store.setAllAppDataAccess($0) }
            ))
            Text(store.tr(.agentDataAccessHint))
                .font(.caption)
                .foregroundStyle(.secondary)
            DisclosureGroup(
                isExpanded: Binding(
                    get: { store.settingsExpandAppDataScopes },
                    set: { store.settingsExpandAppDataScopes = $0 }
                ),
                content: {
                Text(store.tr(.agentDataAccessScopeHint))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(store.tr(.agentDataAccessSkipHint))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                ForEach(store.protectedAppDataAgents, id: \.self) { agent in
                    Toggle(isOn: Binding(
                        get: { store.allowAppData || store.appDataAgents.contains(agent) },
                        set: { enabled in store.setAppDataAccess(for: agent, enabled: enabled) }
                    )) {
                        HStack(spacing: 6) {
                            AgentIconView(id: agent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.displayName)
                                Text(String(format: store.tr(.agentDataAccessAgentDetail), agent.displayName, store.appDataScopeDescription(for: agent)))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .disabled(store.allowAppData)
                    .listRowBackground(
                        store.settingsFocusAppDataAgent == agent
                            ? Color.accentColor.opacity(0.12)
                            : Color.clear
                    )
                }
            },
                label: { Text(store.tr(.agentDataAccessScopes)) }
            )
            Toggle(store.tr(.launchAtLogin), isOn: $store.launchAtLogin)
                .onChange(of: store.launchAtLogin) { _, _ in store.saveSettings() }
            Picker(store.tr(.language), selection: $store.language) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.menuLabel).tag(lang)
                }
            }
            .onChange(of: store.language) { _, _ in store.saveSettings() }
            Picker(store.tr(.groupingLabel), selection: $store.trayGrouping) {
                ForEach(TrayGrouping.allCases) { mode in
                    Text(store.tr(mode.labelKey)).tag(mode)
                }
            }
            .onChange(of: store.trayGrouping) { _, _ in store.saveSettings() }
            // Twenty minutes was compiled in and fits nobody in particular: a
            // long build is not stalled at twenty, a short exchange is stuck
            // well before it. "Never" has to be reachable too — on a machine
            // that runs hour-long jobs the badge is pure noise.
            Picker(store.tr(.stallAfter), selection: $store.stallMinutes) {
                Text(store.tr(.stallOff)).tag(0)
                ForEach([5, 10, 20, 30, 60], id: \.self) { m in
                    Text(String(format: store.tr(.minutesShort), m)).tag(m)
                }
            }
            .onChange(of: store.stallMinutes) { _, _ in store.saveSettings() }
            Picker(store.tr(.snooze), selection: $store.snoozeMinutes) {
                ForEach([5, 10, 30, 60], id: \.self) { m in
                    Text(String(format: store.tr(.minutesShort), m)).tag(m)
                }
            }
            .onChange(of: store.snoozeMinutes) { _, _ in store.saveSettings() }
        }
    }

    // MARK: Notifications

    private var notificationsSection: some View {
        Section(store.tr(.notificationsSection)) {
            if store.notifyAuthorized == nil {
                Label(store.tr(.notifyNotConfigured), systemImage: "bell.badge")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(store.tr(.enableNotifications)) {
                    store.requestNotificationAuthorization()
                }
            } else if store.notifyAuthorized == false {
                // A denied prompt used to leave these toggles reading "on"
                // while nothing could ever fire.
                Label(store.tr(.notifyDenied), systemImage: "bell.slash")
                    .font(.caption)
                    .foregroundStyle(GlanceKind.error.lampColor)
                Text(store.tr(.notifyDeniedPersistentHint))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(store.tr(.openNotificationSettings)) {
                    store.openSystemNotificationSettings()
                }
            }
            notificationToggle(
                store.tr(.notifications),
                preference: \StatusStore.notifyOnIdle
            )
            notificationToggle(
                store.tr(.notifyWaiting),
                preference: \StatusStore.notifyOnWaiting
            )
            notificationToggle(
                store.tr(.playSound),
                preference: \StatusStore.playSoundOnWaiting
            )

            Toggle(store.tr(.quietHours), isOn: $store.quietHoursEnabled)
                .onChange(of: store.quietHoursEnabled) { _, _ in store.saveSettings() }
            if store.quietHoursEnabled {
                Text(store.tr(.quietHoursHint))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                MinutePicker(
                    label: store.tr(.quietStart),
                    minutes: $store.quietStartMinute
                ) { store.saveSettings() }
                MinutePicker(
                    label: store.tr(.quietEnd),
                    minutes: $store.quietEndMinute
                ) { store.saveSettings() }
            }

            if !mutableAgents.isEmpty {
                DisclosureGroup(store.tr(.muteAgents)) {
                    Text(store.tr(.muteHint))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    ForEach(mutableAgents, id: \.self) { agent in
                        Toggle(isOn: Binding(
                            get: { store.mutedAgents.contains(agent) },
                            set: { _ in store.toggleMute(agent) }
                        )) {
                            HStack(spacing: 6) {
                                AgentIconView(id: agent)
                                Text(agent.displayName)
                            }
                        }
                    }
                }
            }
        }
    }

    /// The stored preference can remain enabled while macOS has denied or not
    /// configured notification access. Showing that raw value as an enabled
    /// switch is misleading: the user sees "on" beside copy saying it cannot
    /// fire. Render the effective value instead; once permission is granted,
    /// the saved preference comes back without being silently discarded.
    private func notificationToggle(
        _ title: String,
        preference: ReferenceWritableKeyPath<StatusStore, Bool>
    ) -> some View {
        Toggle(title, isOn: Binding(
            get: { store.notifyAuthorized == true && store[keyPath: preference] },
            set: { enabled in
                guard store.notifyAuthorized == true else { return }
                store[keyPath: preference] = enabled
                store.saveSettings()
            }
        ))
        .tint(store.notifyAuthorized == true ? .accentColor : .gray)
        .disabled(store.notifyAuthorized != true)
    }

    /// Agents worth offering a mute for: whatever Pulse has actually seen,
    /// plus anything already muted so the switch never disappears.
    private var mutableAgents: [AgentID] {
        var seen = Set(store.snapshot.rows.map(\.agent))
        seen.formUnion(store.mutedAgents)
        return seen.sorted {
            (AgentID.priority.firstIndex(of: $0) ?? 999) < (AgentID.priority.firstIndex(of: $1) ?? 999)
        }
    }

    // MARK: Waiting signals

    private var waitingSignalsSection: some View {
        Section(store.tr(.waitingSignals)) {
            if store.settingsFocusWaitingSignals {
                Label(store.attentionBridgeFocusHintText(), systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text(store.waitingReachStepsText())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(store.tr(.ensurePulseHook)) {
                        store.ensurePulseHookLauncher()
                    }
                    Text(
                        store.pulseHookLauncherReady
                            ? store.tr(.pulseHookReady)
                            : store.tr(.pulseHookMissing)
                    )
                    .font(.caption2)
                    .foregroundStyle(store.pulseHookLauncherReady ? Color.secondary : Color.orange)
                }
                Text(store.tr(.ensurePulseHookHint))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(store.tr(.hooksHint))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button(store.tr(.installHooks)) { store.installHooks() }
                if store.hooksInstalled {
                    Button(store.tr(.uninstallHooks), role: .destructive) {
                        store.uninstallHooks()
                    }
                }
            }
            Text(store.hooksStatus.label(lang: store.lang))
                .font(.caption2)
                .foregroundStyle(store.hooksInstalled ? Color.secondary : Color.orange)
            HStack {
                Button(store.tr(.testWaitingSignal)) { store.runHookSelfTest() }
                    .disabled(!store.hooksInstalled || store.hookSelfTestResult == .running)
                Text(store.hookSelfTestText)
                    .font(.caption2)
                    .foregroundStyle(hookTestColor)
                    .lineLimit(1)
            }
            Text(store.attentionBridgeHintText())
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !store.settingsFocusWaitingSignals {
                Button(store.tr(.ensurePulseHook)) {
                    store.ensurePulseHookLauncher()
                }
                .font(.caption)
            }
            Button(store.tr(.revealAttentionFolder)) {
                store.revealAttentionBridgeFolder()
            }
            .font(.caption)
            Button(store.tr(.revealAttentionBridgeKit)) {
                store.revealAttentionBridgeKit()
            }
            .font(.caption)
            if let agent = store.settingsFocusWaitingAgent {
                Button(String(format: store.tr(.attentionBridgeWriteSampleFocused), agent.displayName)) {
                    store.writeAttentionBridgeSample(for: agent)
                }
                .font(.caption)
                Button(
                    store.didCopyAttentionRaise
                        ? store.tr(.attentionRaiseCopied)
                        : store.tr(.copyAttentionRaiseCommand)
                ) {
                    store.copyAttentionRaiseCommand(for: agent)
                }
                .font(.caption)
            }
            Button(store.tr(.attentionBridgeWriteSample)) {
                store.writeAttentionBridgeSample()
            }
            .font(.caption)
            Button(store.tr(.attentionBridgeClearSample)) {
                store.clearAttentionBridgeSample()
            }
            .font(.caption)
            Text(store.attentionBridgeWriteSampleHintText())
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { store.refreshPulseHookLauncherStatus() }
    }

    private var hookTestColor: Color {
        switch store.hookSelfTestResult {
        case .failed: return .red
        case .passed: return GlanceKind.running.lampColor
        case .idle, .running: return .secondary
        }
    }

    // MARK: Shortcuts

    private var shortcutsSection: some View {
        Section(store.tr(.shortcuts)) {
            Picker(store.tr(.revealShortcut), selection: $store.hotkey) {
                ForEach(HotkeyChoice.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .disabled(!store.hotkeyEnabled)
            .onChange(of: store.hotkey) { _, choice in
                store.hotkeyEnabled = choice != .off
                store.saveSettings()
            }
            Toggle(store.tr(.globalShortcut), isOn: $store.hotkeyEnabled)
                .onChange(of: store.hotkeyEnabled) { _, _ in
                    store.saveSettings()
                }
            Text(store.tr(.globalShortcutHint))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if store.hotkeyEnabled, store.hotkey != .off, !store.hotkeyRegistered {
                // Previously this failure was invisible and the hint blamed
                // Accessibility, which was usually the wrong culprit.
                Label(store.tr(.hotkeyTaken), systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(GlanceKind.error.lampColor)
            }
            Text(store.tr(.hotkeyHint))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(store.tr(.a11yHint))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Toggle(store.tr(.allowTerminalAutomation), isOn: $store.allowTerminalAutomation)
                .onChange(of: store.allowTerminalAutomation) { _, _ in
                    store.saveSettings()
                    store.refresh(reason: "terminalAutomation")
                }
            Text(store.tr(.allowTerminalAutomationHint))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            // Off by default, and the switch is a key file: turning it off
            // stops every hold immediately, because the hook's rule is "no
            // key, no hold".
            Toggle(store.tr(.respondLocal), isOn: Binding(
                get: { store.respondLocalEnabled },
                set: { store.setRespondLocalEnabled($0) }
            ))
            Text(store.tr(.respondLocalHint))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            // On by default: an evidence axis nobody switches on is worth
            // nothing. Off means not one git command runs.
            Toggle(store.tr(.measureWorkspaceEffect), isOn: $store.measureWorkspaceEffect)
                .onChange(of: store.measureWorkspaceEffect) { _, _ in
                    store.saveSettings()
                    store.refresh(reason: "workspaceEffect")
                }
            Text(store.tr(.measureWorkspaceEffectHint))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            // Off by default: this is the one switch that sends content OFF
            // this machine. Turning it off also deletes this Mac's snapshot,
            // so a dead broadcast cannot keep riding the sync tool.
            Toggle(store.tr(.fleetBroadcast), isOn: Binding(
                get: { store.broadcastFleet },
                set: { store.setBroadcastFleet($0) }
            ))
            Text(store.tr(.fleetBroadcastHint))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Wait history

    private var historySection: some View {
        Section(store.tr(.recentWaits)) {
            // One line, not a dashboard: how often today's work was actually
            // interrupted, and for how long on average.
            if let summary = store.interruptionsTodayLine {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(store.waitHistory) { entry in
                HStack(alignment: .top, spacing: 8) {
                    AgentIconView(id: entry.agent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title.isEmpty ? entry.agent.displayName : entry.title)
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                        Text(store.historyDetail(entry))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
            }
            Text(store.waitHistoryRetentionLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button(store.tr(.clearHistory)) { store.clearWaitHistory() }
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section(store.tr(.about)) {
            Button(store.tr(.supportHealth)) {
                store.openSupportHealth()
            }
            HStack(spacing: 10) {
                PulseMarkView(size: 22, tone: .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(PulseVersion.about)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text(store.tr(.tagline))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if PulseVersion.distributionChannel == "preview" {
                        Text(store.tr(.updatePreview))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    } else if PulseVersion.distributionChannel == "signed" {
                        Text(store.tr(.updateSignedUnnotarized))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 4)
            }
            LabeledContent(store.tr(.build)) {
                Text(buildText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            LabeledContent(store.tr(.runningFrom)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.installReport.runningURL.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if let current = store.installReport.copies.first(where: \.isCurrent) {
                        Text(installKindLabel(current.kind))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            if store.isVersionMismatch, let bundle = PulseVersion.bundleVersion {
                Text(String(format: store.tr(.versionMismatchHint), PulseVersion.semver, bundle))
                    .font(.caption2)
                    .foregroundStyle(GlanceKind.error.lampColor)
            }
            if !store.installReport.duplicates.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        String(
                            format: store.tr(.duplicateAppsFound),
                            store.installReport.duplicates.count
                        ),
                        systemImage: "square.on.square"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    ForEach(store.installReport.aboutVisibleDuplicates) { copy in
                        Text("\(copy.version) · \(copy.url.path)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if store.installReport.aboutHiddenDuplicateCount > 0 {
                        Text(
                            String(
                                format: store.tr(.duplicateAppsMore),
                                store.installReport.aboutHiddenDuplicateCount
                            )
                        )
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                    if !store.installReport.removableDuplicates.isEmpty {
                        Button(store.tr(.removeDuplicateApps)) {
                            confirmDuplicateRemoval = true
                        }
                        .font(.caption)
                    }
                    if store.installReport.hasOtherRunningCopy {
                        Text(store.tr(.duplicateAppRunning))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Toggle(store.tr(.checkForUpdates), isOn: $store.updateCheckEnabled)
                .onChange(of: store.updateCheckEnabled) { _, _ in store.saveSettings() }
            HStack {
                Text(store.updateStatusText)
                    .font(.caption2)
                    .foregroundStyle(store.updateAvailableURL == nil ? .secondary : GlanceKind.running.lampColor)
                Spacer(minLength: 4)
                if let url = store.updateAvailableURL {
                    if store.updateCanVerifyDownload {
                        Button(store.tr(.downloadAndVerify)) {
                            store.downloadAndVerifyUpdate()
                        }
                        .font(.caption)
                        .disabled(
                            store.updateDownloadStatus == .downloading
                                || store.updateDownloadStatus == .verifying
                                || store.updateDownloadStatus == .installing
                        )
                    } else {
                        Button(store.tr(.openRelease)) { NSWorkspace.shared.open(url) }
                            .font(.caption)
                    }
                } else {
                    Button(store.tr(.checkNow)) { store.checkForUpdatesNow() }
                        .font(.caption)
                }
            }
            if let download = store.updateDownloadStatusText {
                Text(download)
                    .font(.caption2)
                    .foregroundStyle(
                        {
                            if case .failed = store.updateDownloadStatus { return Color.red }
                            if case .ready = store.updateDownloadStatus {
                                return GlanceKind.running.lampColor
                            }
                            return Color.secondary
                        }()
                    )
            }
            if case .ready = store.updateDownloadStatus, store.updateCanInstallInPlace {
                Button(store.tr(.installUpdate)) { store.installVerifiedUpdate() }
                    .font(.caption)
            } else if case .ready = store.updateDownloadStatus, !store.updateCanInstallInPlace {
                Text(store.tr(.updateInstallRequiresNotarized))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button(store.didCopyDiagnostics ? store.tr(.copied) : store.tr(.copyDiagnostics)) {
                store.copyDiagnostics()
            }
        }
    }

    /// `a1b2c3d · 2026-07-27`, or an honest `dev build` when unpackaged.
    private var buildText: String {
        let line = PulseVersion.buildLine
        return line.isEmpty ? store.tr(.devBuild) : line
    }

    private func installKindLabel(_ kind: InstallTruth.CopyKind) -> String {
        switch kind {
        case .currentInstalled: return store.tr(.runningFrom)
        case .buildArtifact: return store.tr(.installCopyBuildArtifact)
        case .rollback: return store.tr(.installCopyRollback)
        case .orphanDuplicate: return store.tr(.duplicateAppsFound).replacingOccurrences(of: "%d", with: "1")
        }
    }

}


/// Hour+minute picker backed by minutes-since-midnight.
/// Quiet hours were whole-hour only, so 22:30 was not expressible.
private struct MinutePicker: View {
    let label: String
    @Binding var minutes: Int
    let onCommit: () -> Void

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                Picker("", selection: hourBinding) {
                    ForEach(0..<24, id: \.self) { h in
                        Text(String(format: "%02d", h)).tag(h)
                    }
                }
                .labelsHidden()
                .frame(width: 62)
                Text(":")
                Picker("", selection: minuteBinding) {
                    ForEach([0, 15, 30, 45], id: \.self) { m in
                        Text(String(format: "%02d", m)).tag(m)
                    }
                }
                .labelsHidden()
                .frame(width: 62)
            }
        }
    }

    private var hourBinding: Binding<Int> {
        Binding(
            get: { min(23, max(0, minutes / 60)) },
            set: { minutes = $0 * 60 + (minutes % 60); onCommit() }
        )
    }

    private var minuteBinding: Binding<Int> {
        Binding(
            get: {
                let m = minutes % 60
                // Snap a legacy/odd value onto the nearest offered step.
                return [0, 15, 30, 45].min(by: { abs($0 - m) < abs($1 - m) }) ?? 0
            },
            set: { minutes = (minutes / 60) * 60 + $0; onCommit() }
        )
    }
}
