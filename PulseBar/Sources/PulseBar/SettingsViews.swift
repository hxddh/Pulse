// 3.0-α: the settings scene, moved verbatim out of PulseApp.swift.

import SwiftUI
import AppKit

@MainActor
struct SettingsView: View {
    /// The store itself (19.0). Under Observation this form is redrawn only
    /// by the properties it reads, and it reads no per-scan fact
    /// (`surface_check.py` keeps it so).
    let store: StatusStore

    init(store: StatusStore) {
        self.store = store
    }

    /// 22.0 Lamp: one page. Five panes held 28 controls; most of them were
    /// consent switches for features that are gone, or preferences the
    /// system already owns (quiet hours → Focus, sound → Notifications).
    /// What is left fits on one screen.

    /// A binding to one setting: reading it reads `store.settings`, and
    /// writing it goes through `StatusStore.set`, which saves and applies.
    private func setting<Value: Equatable>(_ keyPath: WritableKeyPath<PulseSettings, Value>) -> Binding<Value> {
        let store = self.store
        return Binding(get: { store.settings[keyPath: keyPath] }, set: { store.set(keyPath, $0) })
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                generalSection
                shortcutSection
                notificationsSection
                hooksSection
                    .id("settings-connections")
                controlSection
                dataAccessSection
                    .id("settings-data")
                updatesSection
                aboutSection
                installSection
            }
            .formStyle(.grouped)
            .onAppear {
                store.landHooksStatus(HooksSupport.probeStatus())
                PulseNotify.refreshAuthorization()
                followFocus(proxy)
            }
            // A token, not the focus values: a second deep link with the same
            // target must still land (the values would not change).
            .onChange(of: store.settingsFocus.token) { _, _ in followFocus(proxy) }
        }
    }

    /// A deep link from the tray scrolls to what it names.
    private func followFocus(_ proxy: ScrollViewProxy) {
        let target: String
        switch store.settingsFocus.target {
        case .waitingSignals: target = "settings-connections"
        case .appData: target = "settings-data"
        case nil: return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(PulseTheme.motion) { proxy.scrollTo(target, anchor: .top) }
        }
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
            Toggle(store.tr(.launchAtLogin), isOn: setting(\.launchAtLogin))
            Picker(store.tr(.language), selection: setting(\.language)) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.menuLabel).tag(lang)
                }
            }
        }
    }

    /// One control for one bit: the shortcut, or Off.
    private var shortcutSection: some View {
        Section(store.tr(.shortcuts)) {
            Picker(selection: setting(\.hotkey)) {
                Text(store.tr(.shortcutOff)).tag(HotkeyChoice.off)
                Divider()
                ForEach(HotkeyChoice.allCases.filter { $0 != .off }) { choice in
                    Text(choice.label).tag(choice)
                }
            } label: {
                Text(store.tr(.revealShortcut))
                Text(store.tr(.globalShortcutHint))
            }
            if store.settings.hotkey != .off, !store.hotkeyRegistered {
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
            // The stored preference can remain enabled while macOS has
            // denied or not configured notification access. Render the
            // effective value instead; once permission is granted, the saved
            // preference comes back.
            Toggle(store.tr(.notifyWaiting), isOn: Binding(
                get: { store.notifyAuthorized == true && store.settings.notifyOnWaiting },
                set: { enabled in
                    guard store.notifyAuthorized == true else { return }
                    store.set(\.notifyOnWaiting, enabled)
                }
            ))
            .disabled(store.notifyAuthorized != true)
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

    // MARK: Permissions

    /// One switch for every agent whose sessions live in data macOS
    /// protects (23.0: the per-agent scopes are gone).
    private var dataAccessSection: some View {
        Section {
            explainedToggle(
                store.tr(.agentDataAccess),
                hint: store.tr(.agentDataAccessHint),
                isOn: Binding(
                    get: { store.settings.readProtectedAppData },
                    set: { store.setReadProtectedAppData($0) }
                )
            )
            .listRowBackground(
                store.settingsFocus.target == .appData
                    ? Color.accentColor.opacity(PulseTheme.Fill.selected)
                    : Color.clear
            )
        } header: {
            Text(store.tr(.settingsPaneDataHeader))
        } footer: {
            Text(store.tr(.agentDataAccessSkipHint))
                .font(PulseTheme.Font.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Everything that lets Pulse act on your behalf, each off until you say.
    private var controlSection: some View {
        Section {
            explainedToggle(
                store.tr(.allowTerminalAutomation),
                hint: store.tr(.allowTerminalAutomationHint),
                isOn: setting(\.allowTerminalAutomation)
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
            Toggle(store.tr(.checkForUpdates), isOn: setting(\.updateCheckEnabled))
            LabeledContent {
                if let url = store.updateAvailableURL {
                    Button(store.tr(.openRelease)) { NSWorkspace.shared.open(url) }
                } else {
                    Button(store.tr(.checkNow)) { store.checkForUpdatesNow() }
                }
            } label: {
                Text(store.updateStatusText)
                    .foregroundStyle(store.updateAvailableURL == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(PulseTheme.Tone.running.color))
            }
        }
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
                Text(Bundle.main.bundleURL.path)
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
            Button(store.diagnostics.didCopyDiagnostics ? store.tr(.copied) : store.tr(.copyDiagnostics)) {
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
