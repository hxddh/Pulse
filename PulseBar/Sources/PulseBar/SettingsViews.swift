// 3.0-α: the settings scene, moved verbatim out of PulseApp.swift.

import SwiftUI
import AppKit

@MainActor
struct SettingsView: View {
    /// The store itself (19.0). Under Observation this form is redrawn only
    /// by the properties it reads, and it reads no per-scan fact:
    /// `snapshotAgents` rather than `snapshot`. `surface_check.py` keeps it so.
    let store: StatusStore

    init(store: StatusStore) {
        self.store = store
    }

    /// 21.0 Clarity: five panes, each one question. Before, "Shortcuts" held
    /// five unrelated consent switches, "Waiting signals" a dozen developer
    /// buttons, and the self-check sat at the bottom of "About".
    enum Pane: String, CaseIterable, Identifiable {
        case general, alerts, connections, permissions, about
        var id: String { rawValue }
    }

    /// A binding into the store, like `$store.x`.
    private func bind<Value>(_ keyPath: ReferenceWritableKeyPath<StatusStore, Value>) -> Binding<Value> {
        let store = self.store
        return Binding(get: { store[keyPath: keyPath] }, set: { store[keyPath: keyPath] = $0 })
    }
    @State private var pane: Pane = .general
    @State private var confirmDuplicateRemoval = false
    @State private var bridgeExpanded = false

    var body: some View {
        TabView(selection: $pane) {
            form { generalSection; shortcutSection }
                .tabItem { Label(store.tr(.general), systemImage: "gearshape") }
                .tag(Pane.general)
            form {
                notificationsSection
                timingSection
                if !store.waitHistory.isEmpty { historySection }
            }
            .tabItem { Label(store.tr(.settingsPaneAlerts), systemImage: "bell") }
            .tag(Pane.alerts)
            form { hooksSection; bridgeSection }
                .tabItem { Label(store.tr(.settingsPaneConnections), systemImage: "point.3.connected.trianglepath.dotted") }
                .tag(Pane.connections)
            form { dataAccessSection; controlSection }
                .tabItem { Label(store.tr(.settingsPanePermissions), systemImage: "hand.raised") }
                .tag(Pane.permissions)
            form { aboutSection; updatesSection; installSection }
                .tabItem { Label(store.tr(.about), systemImage: "info.circle") }
                .tag(Pane.about)
        }
        .onAppear {
            store.hooksStatus = HooksSupport.probeStatus()
            store.refreshInstallTruth()
            PulseNotify.refreshAuthorization()
            store.refreshPulseHookLauncherStatus()
            followFocus()
        }
        .onChange(of: store.settingsFocusWaitingSignals) { _, _ in followFocus() }
        .onChange(of: store.settingsFocusAppDataAgent) { _, _ in followFocus() }
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

    /// A deep link from the tray lands on the pane it names.
    private func followFocus() {
        if store.settingsFocusWaitingSignals {
            pane = .connections
            bridgeExpanded = store.settingsFocusWaitingAgent != nil
        } else if store.settingsFocusAppDataAgent != nil {
            pane = .permissions
        }
    }

    private func form<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Form { content() }
            .formStyle(.grouped)
    }

    /// A switch with its consequence underneath, the way System Settings
    /// writes it — not a paragraph floating between two switches.
    private func explainedToggle(_ title: String, hint: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
            Text(hint)
        }
    }

    // MARK: General

    private var generalSection: some View {
        Section {
            Toggle(store.tr(.launchAtLogin), isOn: bind(\.launchAtLogin))
                .onChange(of: store.launchAtLogin) { _, _ in store.saveSettings() }
            Picker(store.tr(.language), selection: bind(\.language)) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.menuLabel).tag(lang)
                }
            }
            .onChange(of: store.language) { _, _ in store.saveSettings() }
            Picker(store.tr(.groupingLabel), selection: bind(\.trayGrouping)) {
                ForEach(TrayGrouping.allCases) { mode in
                    Text(store.tr(mode.labelKey)).tag(mode)
                }
            }
            .onChange(of: store.trayGrouping) { _, _ in store.saveSettings() }
            explainedToggle(
                store.tr(.liveUpdates),
                hint: store.tr(.liveUpdatesHint),
                isOn: bind(\.autoProbe)
            )
            .onChange(of: store.autoProbe) { _, _ in store.saveSettings() }
        }
    }

    /// One control for one bit: the shortcut, or Off.
    private var shortcutSection: some View {
        Section(store.tr(.shortcuts)) {
            Picker(selection: bind(\.hotkey)) {
                Text(store.tr(.shortcutOff)).tag(HotkeyChoice.off)
                Divider()
                ForEach(HotkeyChoice.allCases.filter { $0 != .off }) { choice in
                    Text(choice.label).tag(choice)
                }
            } label: {
                Text(store.tr(.revealShortcut))
                Text(store.tr(.globalShortcutHint))
            }
            .onChange(of: store.hotkey) { _, _ in store.saveSettings() }
            if store.hotkey != .off, !store.hotkeyRegistered {
                Label(store.tr(.hotkeyTaken), systemImage: "exclamationmark.triangle")
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(PulseTheme.Tone.attention.color)
            }
        }
    }

    // MARK: Alerts

    private var notificationsSection: some View {
        Section(store.tr(.notificationsSection)) {
            if store.notifyAuthorized == nil {
                LabeledContent {
                    Button(store.tr(.enableNotifications)) {
                        store.requestNotificationAuthorization()
                    }
                } label: {
                    Label(store.tr(.notifyNotConfigured), systemImage: "bell.badge")
                }
            } else if store.notifyAuthorized == false {
                // A denied prompt used to leave these toggles reading "on"
                // while nothing could ever fire.
                LabeledContent {
                    Button(store.tr(.openNotificationSettings)) {
                        store.openSystemNotificationSettings()
                    }
                } label: {
                    Label(store.tr(.notifyDenied), systemImage: "bell.slash")
                        .foregroundStyle(PulseTheme.Tone.attention.color)
                    Text(store.tr(.notifyDeniedPersistentHint))
                }
            }
            notificationToggle(
                store.tr(.notifyWaiting),
                preference: \StatusStore.notifyOnWaiting
            )
            notificationToggle(
                store.tr(.notifications),
                preference: \StatusStore.notifyOnIdle
            )
            notificationToggle(
                store.tr(.playSound),
                preference: \StatusStore.playSoundOnWaiting
            )
            Toggle(isOn: bind(\.quietHoursEnabled)) {
                Text(store.tr(.quietHours))
                Text(store.tr(.quietHoursHint))
            }
            .onChange(of: store.quietHoursEnabled) { _, _ in store.saveSettings() }
            if store.quietHoursEnabled {
                MinutePicker(
                    label: store.tr(.quietStart),
                    minutes: bind(\.quietStartMinute)
                ) { store.saveSettings() }
                MinutePicker(
                    label: store.tr(.quietEnd),
                    minutes: bind(\.quietEndMinute)
                ) { store.saveSettings() }
            }
            if !mutableAgents.isEmpty {
                DisclosureGroup(store.tr(.muteAgents)) {
                    Text(store.tr(.muteHint))
                        .font(PulseTheme.Font.caption)
                        .foregroundStyle(.secondary)
                    ForEach(mutableAgents, id: \.self) { agent in
                        Toggle(isOn: Binding(
                            get: { store.mutedAgents.contains(agent) },
                            set: { _ in store.toggleMute(agent) }
                        )) {
                            HStack(spacing: PulseTheme.Space.s) {
                                AgentIconView(id: agent)
                                Text(agent.displayName)
                            }
                        }
                    }
                }
            }
        }
    }

    private var timingSection: some View {
        Section {
            // Twenty minutes was compiled in and fits nobody in particular.
            // "Never" has to be reachable too — on a machine that runs
            // hour-long jobs the badge is pure noise.
            Picker(store.tr(.stallAfter), selection: bind(\.stallMinutes)) {
                Text(store.tr(.stallOff)).tag(0)
                ForEach([5, 10, 20, 30, 60], id: \.self) { m in
                    Text(String(format: store.tr(.minutesShort), m)).tag(m)
                }
            }
            .onChange(of: store.stallMinutes) { _, _ in store.saveSettings() }
            Picker(store.tr(.snooze), selection: bind(\.snoozeMinutes)) {
                ForEach([5, 10, 30, 60], id: \.self) { m in
                    Text(String(format: store.tr(.minutesShort), m)).tag(m)
                }
            }
            .onChange(of: store.snoozeMinutes) { _, _ in store.saveSettings() }
        }
    }

    /// The stored preference can remain enabled while macOS has denied or not
    /// configured notification access. Render the effective value instead;
    /// once permission is granted, the saved preference comes back.
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
        .disabled(store.notifyAuthorized != true)
    }

    /// Agents worth offering a mute for: whatever Pulse has actually seen,
    /// plus anything already muted so the switch never disappears.
    private var mutableAgents: [AgentID] {
        var seen = store.snapshotAgents
        seen.formUnion(store.mutedAgents)
        return seen.sorted {
            (AgentID.priority.firstIndex(of: $0) ?? 999) < (AgentID.priority.firstIndex(of: $1) ?? 999)
        }
    }

    private var historySection: some View {
        Section(store.tr(.recentWaits)) {
            // One line, not a dashboard: how often today's work was actually
            // interrupted, and for how long on average.
            if let summary = store.interruptionsTodayLine {
                Text(summary)
                    .font(PulseTheme.Font.body)
                    .foregroundStyle(.secondary)
            }
            ForEach(store.waitHistory.prefix(8)) { entry in
                HStack(alignment: .top, spacing: PulseTheme.Space.s) {
                    AgentIconView(id: entry.agent)
                    VStack(alignment: .leading, spacing: PulseTheme.Space.xxs) {
                        Text(entry.title.isEmpty ? entry.agent.displayName : entry.title)
                            .font(PulseTheme.Font.bodyEmphasis)
                            .lineLimit(1)
                        Text(store.historyDetail(entry))
                            .font(PulseTheme.Font.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: PulseTheme.Space.xs)
                }
            }
            LabeledContent {
                Button(store.tr(.clearHistory)) { store.clearWaitHistory() }
            } label: {
                Text(store.waitHistoryRetentionLine)
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Connections

    /// Claude and Codex: the two agents Pulse installs hooks for.
    private var hooksSection: some View {
        Section {
            LabeledContent {
                HStack(spacing: PulseTheme.Space.s) {
                    if store.hooksInstalled {
                        Button(store.tr(.uninstallHooks), role: .destructive) {
                            store.uninstallHooks()
                        }
                    }
                    Button(store.tr(.installHooks)) { store.installHooks() }
                }
            } label: {
                Text(store.tr(.settingsHooksTitle))
                Text(store.hooksStatus.label(lang: store.lang))
                    .foregroundStyle(store.hooksInstalled ? AnyShapeStyle(.secondary) : AnyShapeStyle(PulseTheme.Tone.attention.color))
            }
            LabeledContent {
                Button(store.tr(.testWaitingSignal)) { store.runHookSelfTest() }
                    .disabled(!store.hooksInstalled || store.hookSelfTestResult == .running)
            } label: {
                Text(store.tr(.settingsHooksTest))
                Text(store.hookSelfTestText)
                    .foregroundStyle(hookTestColor)
            }
        } header: {
            Text(store.tr(.waitingSignals))
        } footer: {
            Text(store.tr(.hooksHint))
                .font(PulseTheme.Font.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var hookTestColor: Color {
        switch store.hookSelfTestResult {
        case .failed: return PulseTheme.Tone.waiting.color
        case .passed: return PulseTheme.Tone.running.color
        case .idle, .running: return .secondary
        }
    }

    /// Every other agent reports through the Attention bridge. Its tools are
    /// for the person wiring an agent up, so they stay folded until asked
    /// for — or until the tray sent you here for exactly that.
    private var bridgeSection: some View {
        Section {
            Text(store.attentionBridgeHintText())
                .font(PulseTheme.Font.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup(isExpanded: $bridgeExpanded) {
                if store.settingsFocusWaitingSignals {
                    Label(store.attentionBridgeFocusHintText(), systemImage: "link")
                        .font(PulseTheme.Font.body)
                    Text(store.waitingReachStepsText())
                        .font(PulseTheme.Font.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LabeledContent {
                    Button(store.tr(.ensurePulseHook)) {
                        store.ensurePulseHookLauncher()
                    }
                } label: {
                    Text("pulse-hook")
                    Text(store.pulseHookLauncherReady ? store.tr(.pulseHookReady) : store.tr(.pulseHookMissing))
                        .foregroundStyle(store.pulseHookLauncherReady ? AnyShapeStyle(.secondary) : AnyShapeStyle(PulseTheme.Tone.attention.color))
                }
                if let error = store.pulseHookLauncherError {
                    Text(error)
                        .font(PulseTheme.Font.caption)
                        .foregroundStyle(PulseTheme.Tone.attention.color)
                }
                if let agent = store.settingsFocusWaitingAgent {
                    Button(String(format: store.tr(.attentionBridgeWriteSampleFocused), agent.displayName)) {
                        store.writeAttentionBridgeSample(for: agent)
                    }
                    Button(
                        store.didCopyAttentionRaise
                            ? store.tr(.attentionRaiseCopied)
                            : store.tr(.copyAttentionRaiseCommand)
                    ) {
                        store.copyAttentionRaiseCommand(for: agent)
                    }
                }
                HStack(spacing: PulseTheme.Space.s) {
                    Button(store.tr(.attentionBridgeWriteSample)) {
                        store.writeAttentionBridgeSample()
                    }
                    Button(store.tr(.attentionBridgeClearSample)) {
                        store.clearAttentionBridgeSample()
                    }
                }
                HStack(spacing: PulseTheme.Space.s) {
                    Button(store.tr(.revealAttentionFolder)) {
                        store.revealAttentionBridgeFolder()
                    }
                    Button(store.tr(.revealAttentionBridgeKit)) {
                        store.revealAttentionBridgeKit()
                    }
                }
                Text(store.attentionBridgeWriteSampleHintText())
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } label: {
                Text(store.tr(.settingsBridgeTools))
            }
        } header: {
            Text(store.tr(.settingsOtherAgents))
        }
    }

    // MARK: Permissions

    private var dataAccessSection: some View {
        Section {
            explainedToggle(
                store.tr(.agentDataAccess),
                hint: store.tr(.agentDataAccessHint),
                isOn: Binding(
                    get: { store.allowAppData },
                    set: { store.setAllAppDataAccess($0) }
                )
            )
            DisclosureGroup(
                isExpanded: Binding(
                    get: { store.settingsExpandAppDataScopes },
                    set: { store.settingsExpandAppDataScopes = $0 }
                ),
                content: {
                    Text(store.tr(.agentDataAccessScopeHint) + " " + store.tr(.agentDataAccessSkipHint))
                        .font(PulseTheme.Font.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(store.protectedAppDataAgents, id: \.self) { agent in
                        Toggle(isOn: Binding(
                            get: { store.allowAppData || store.appDataAgents.contains(agent) },
                            set: { enabled in store.setAppDataAccess(for: agent, enabled: enabled) }
                        )) {
                            HStack(spacing: PulseTheme.Space.s) {
                                AgentIconView(id: agent)
                                VStack(alignment: .leading, spacing: PulseTheme.Space.xxs) {
                                    Text(agent.displayName)
                                    Text(String(format: store.tr(.agentDataAccessAgentDetail), agent.displayName, store.appDataScopeDescription(for: agent)))
                                        .font(PulseTheme.Font.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .disabled(store.allowAppData)
                        .listRowBackground(
                            store.settingsFocusAppDataAgent == agent
                                ? Color.accentColor.opacity(PulseTheme.Fill.selected)
                                : Color.clear
                        )
                    }
                },
                label: { Text(store.tr(.agentDataAccessScopes)) }
            )
        } header: {
            Text(store.tr(.settingsPaneDataHeader))
        }
    }

    /// Everything that lets Pulse act on your behalf, each off until you say.
    private var controlSection: some View {
        Section {
            explainedToggle(
                store.tr(.allowTerminalAutomation),
                hint: store.tr(.allowTerminalAutomationHint),
                isOn: bind(\.allowTerminalAutomation)
            )
            .onChange(of: store.allowTerminalAutomation) { _, _ in
                store.saveSettings()
                store.refresh(reason: "terminalAutomation")
            }
            // 4.0-β: one notch above tab-select — the keystroke grant. The
            // switch existing is the consent; off kills all actuation now.
            explainedToggle(
                store.tr(.allowWorkbenchActuation),
                hint: store.tr(.allowWorkbenchActuationHint),
                isOn: bind(\.allowWorkbenchActuation)
            )
            .onChange(of: store.allowWorkbenchActuation) { _, _ in store.saveSettings() }
            // Off by default, and the switch is a key file: turning it off
            // stops every hold immediately ("no key, no hold").
            explainedToggle(
                store.tr(.respondLocal),
                hint: store.tr(.respondLocalHint),
                isOn: Binding(
                    get: { store.respondLocalEnabled },
                    set: { store.setRespondLocalEnabled($0) }
                )
            )
            // On by default: an evidence axis nobody switches on is worth
            // nothing. Off means not one git command runs.
            explainedToggle(
                store.tr(.measureWorkspaceEffect),
                hint: store.tr(.measureWorkspaceEffectHint),
                isOn: bind(\.measureWorkspaceEffect)
            )
            .onChange(of: store.measureWorkspaceEffect) { _, _ in
                store.saveSettings()
                store.refresh(reason: "workspaceEffect")
            }
            // Off by default: the one switch that sends content off this
            // machine. Turning it off also deletes this Mac's snapshot.
            explainedToggle(
                store.tr(.fleetBroadcast),
                hint: store.tr(.fleetBroadcastHint),
                isOn: Binding(
                    get: { store.broadcastFleet },
                    set: { store.setBroadcastFleet($0) }
                )
            )
        } header: {
            Text(store.tr(.settingsPaneControlHeader))
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section {
            HStack(spacing: PulseTheme.Space.m) {
                PulseMarkView(size: 28, tone: .secondary)
                VStack(alignment: .leading, spacing: PulseTheme.Space.xxs) {
                    Text(PulseVersion.about)
                        .font(PulseTheme.Font.hero)
                    Text(store.tr(.tagline))
                        .font(PulseTheme.Font.caption)
                        .foregroundStyle(.secondary)
                    if PulseVersion.distributionChannel == "preview" {
                        Text(store.tr(.updatePreview))
                            .font(PulseTheme.Font.caption)
                            .foregroundStyle(PulseTheme.Tone.attention.color)
                    } else if PulseVersion.distributionChannel == "signed" {
                        Text(store.tr(.updateSignedUnnotarized))
                            .font(PulseTheme.Font.caption)
                            .foregroundStyle(PulseTheme.Tone.attention.color)
                    }
                }
                Spacer(minLength: PulseTheme.Space.xs)
            }
            // 21.0: the self-check, per-agent support and diagnostics are one
            // window now — Health — reachable from here and from the tray.
            LabeledContent {
                Button(store.tr(.healthOpen)) { store.openSupportHealth() }
            } label: {
                Text(store.tr(.healthTitle))
                Text(store.tr(.healthSettingsHint))
            }
        }
    }

    private var updatesSection: some View {
        Section(store.tr(.checkForUpdates)) {
            Toggle(store.tr(.checkForUpdates), isOn: bind(\.updateCheckEnabled))
                .onChange(of: store.updateCheckEnabled) { _, _ in store.saveSettings() }
            LabeledContent {
                if let url = store.updateAvailableURL {
                    if store.updateCanVerifyDownload {
                        Button(store.tr(.downloadAndVerify)) {
                            store.downloadAndVerifyUpdate()
                        }
                        .disabled(
                            store.updateDownloadStatus == .downloading
                                || store.updateDownloadStatus == .verifying
                                || store.updateDownloadStatus == .installing
                        )
                    } else {
                        Button(store.tr(.openRelease)) { NSWorkspace.shared.open(url) }
                    }
                } else {
                    Button(store.tr(.checkNow)) { store.checkForUpdatesNow() }
                }
            } label: {
                Text(store.updateStatusText)
                    .foregroundStyle(store.updateAvailableURL == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(PulseTheme.Tone.running.color))
            }
            if let download = store.updateDownloadStatusText {
                Text(download)
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(downloadColor)
            }
            if case .ready = store.updateDownloadStatus, store.updateCanInstallInPlace {
                Button(store.tr(.installUpdate)) { store.installVerifiedUpdate() }
            } else if case .ready = store.updateDownloadStatus, !store.updateCanInstallInPlace {
                Text(store.tr(.updateInstallRequiresNotarized))
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var downloadColor: Color {
        if case .failed = store.updateDownloadStatus { return PulseTheme.Tone.waiting.color }
        if case .ready = store.updateDownloadStatus { return PulseTheme.Tone.running.color }
        return .secondary
    }

    private var installSection: some View {
        Section {
            LabeledContent(store.tr(.build)) {
                Text(buildText)
                    .font(PulseTheme.Font.code)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            LabeledContent(store.tr(.runningFrom)) {
                Text(store.installReport.runningURL.path)
                    .font(PulseTheme.Font.code)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if store.isVersionMismatch, let bundle = PulseVersion.bundleVersion {
                Text(String(format: store.tr(.versionMismatchHint), PulseVersion.semver, bundle))
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(PulseTheme.Tone.attention.color)
            }
            if !store.installReport.duplicates.isEmpty {
                VStack(alignment: .leading, spacing: PulseTheme.Space.xs) {
                    Label(
                        String(
                            format: store.tr(.duplicateAppsFound),
                            store.installReport.duplicates.count
                        ),
                        systemImage: "square.on.square"
                    )
                    .foregroundStyle(PulseTheme.Tone.attention.color)
                    ForEach(store.installReport.aboutVisibleDuplicates) { copy in
                        Text("\(copy.version) · \(copy.url.path)")
                            .font(PulseTheme.Font.code)
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
                        .font(PulseTheme.Font.caption)
                        .foregroundStyle(.secondary)
                    }
                    if !store.installReport.removableDuplicates.isEmpty {
                        Button(store.tr(.removeDuplicateApps)) {
                            confirmDuplicateRemoval = true
                        }
                    }
                    if store.installReport.hasOtherRunningCopy {
                        Text(store.tr(.duplicateAppRunning))
                            .font(PulseTheme.Font.caption)
                            .foregroundStyle(PulseTheme.Tone.attention.color)
                    }
                }
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
