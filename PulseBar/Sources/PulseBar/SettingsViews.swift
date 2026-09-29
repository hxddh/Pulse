// 3.0-α: the settings scene, moved out of PulseApp.swift.
//
// 23.0 · one page of seven short groups and a footer. `SettingsView` builds
// a `SettingsModel` from the store (settings and a few flags, never a scan)
// and performs its actions; `SettingsFace` renders the value.

import SwiftUI
import AppKit

@MainActor
struct SettingsView: View {
    /// The store itself (19.0). Under Observation this page is redrawn only
    /// by the properties it reads, and it reads no per-scan fact
    /// (`surface_check.py` keeps it so).
    let store: StatusStore

    init(store: StatusStore) {
        self.store = store
    }

    var body: some View {
        SettingsFace(
            model: store.settingsModel,
            focusToken: store.settingsFocus.token
        ) { action in
            store.performSettings(action)
        }
        .onAppear {
            store.landHooksStatus(HooksSupport.probeStatus())
            PulseNotify.refreshAuthorization()
        }
    }
}

@MainActor
extension StatusStore {
    /// The Settings page as a value.
    var settingsModel: SettingsModel {
        let notifications = SettingsModel.notifications(notifyAuthorized)
        var warning: String?
        if isVersionMismatch, let bundle = PulseVersion.bundleVersion {
            warning = String(format: tr(.versionMismatchHint), PulseVersion.semver, bundle)
        } else if PulseVersion.distributionChannel == "preview" {
            warning = tr(.updatePreview)
        } else if PulseVersion.distributionChannel == "signed" {
            warning = tr(.updateSignedUnnotarized)
        }
        let build = PulseVersion.buildLine
        let hookTone: PulseTheme.Tone
        switch hookSelfTestResult {
        case .failed: hookTone = .waiting
        case .passed: hookTone = .running
        case .idle, .running: hookTone = .idle
        }
        return SettingsModel(
            lang: lang,
            launchAtLogin: settings.launchAtLogin,
            language: settings.language,
            hotkey: settings.hotkey,
            hotkeyTaken: settings.hotkey != .off && !hotkeyRegistered,
            notifications: notifications,
            notifyOnWaiting: notifications == .allowed && settings.notifyOnWaiting,
            mutedAgents: SettingsModel.sortedMuted(settings.mutedAgents),
            hooksStatus: hooksStatus.label(lang: lang),
            hooksInstalled: hooksInstalled,
            hookAgents: SettingsModel.hookAgents(
                installed: hooksStatus.installedAgents,
                present: Set(AgentID.priority.filter(HooksInstaller.vendorPresent)),
                lastEventMs: engine.latestHookEventMs,
                nowMs: Int64(Date().timeIntervalSince1970 * 1000),
                lang: lang
            ),
            hookTest: hookSelfTestText,
            hookTestTone: hookTone,
            hookTestRunning: hookSelfTestResult == .running,
            allowTerminalAutomation: settings.allowTerminalAutomation,
            readProtectedAppData: settings.readProtectedAppData,
            updateCheckEnabled: settings.updateCheckEnabled,
            updateStatus: updateStatusText,
            updateAvailable: updateAvailableURL != nil,
            version: build.isEmpty ? PulseVersion.about : "\(PulseVersion.about) · \(build)",
            buildWarning: warning,
            focus: settingsFocus.target.map(SettingsModel.section(for:))
        )
    }

    func performSettings(_ action: SettingsModel.Action) {
        switch action {
        case .setLaunchAtLogin(let on): set(\.launchAtLogin, on)
        case .setLanguage(let language): set(\.language, language)
        case .setHotkey(let choice): set(\.hotkey, choice)
        case .enableNotifications: requestNotificationAuthorization()
        case .openNotificationSettings: openSystemNotificationSettings()
        case .setNotifyOnWaiting(let on):
            guard notifyAuthorized == true else { return }
            set(\.notifyOnWaiting, on)
        case .unmute(let agent):
            if settings.mutedAgents.contains(agent) { toggleMute(agent) }
        case .installHooks: installHooks()
        case .uninstallHooks: uninstallHooks()
        case .testHooks: runHookSelfTest()
        case .setTerminalAutomation(let on): set(\.allowTerminalAutomation, on)
        case .setReadAppData(let on): setReadProtectedAppData(on)
        case .setUpdateCheck(let on): set(\.updateCheckEnabled, on)
        case .checkForUpdates: checkForUpdatesNow()
        case .openRelease:
            if let url = updateAvailableURL { NSWorkspace.shared.open(url) }
        case .openDiagnostics: openDiagnostics()
        }
    }
}

/// Renders a `SettingsModel` and sends its actions. A deep link scrolls to
/// the section it names (the token moves on every link, so a second link to
/// the same place still lands).
struct SettingsFace: View {
    let model: SettingsModel
    var focusToken = 0
    /// Sendable: the page's bindings carry it.
    var send: @MainActor @Sendable (SettingsModel.Action) -> Void = { _ in }

    private func t(_ key: L10n.Key) -> String { L10n.t(key, model.lang) }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                ForEach(SettingsModel.sections, id: \.self) { section in
                    Section {
                        rows(section)
                    } header: {
                        Text(SettingsModel.title(section, lang: model.lang))
                    } footer: {
                        footer(section)
                    }
                    .id(section)
                }
                about
            }
            .formStyle(.grouped)
            .onAppear { follow(proxy) }
            .onChange(of: focusToken) { _, _ in follow(proxy) }
        }
    }

    private func follow(_ proxy: ScrollViewProxy) {
        guard let target = model.focus else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(PulseTheme.motion) { proxy.scrollTo(target, anchor: .top) }
        }
    }

    private func binding(_ value: Bool, _ action: @escaping @Sendable (Bool) -> SettingsModel.Action) -> Binding<Bool> {
        let send = self.send
        return Binding(get: { value }, set: { send(action($0)) })
    }

    private var languageBinding: Binding<AppLanguage> {
        let send = self.send
        let value = model.language
        return Binding(get: { value }, set: { send(.setLanguage($0)) })
    }

    private var hotkeyBinding: Binding<HotkeyChoice> {
        let send = self.send
        let value = model.hotkey
        return Binding(get: { value }, set: { send(.setHotkey($0)) })
    }

    // MARK: Rows

    @ViewBuilder
    private func rows(_ section: SettingsModel.Section) -> some View {
        switch section {
        case .general:
            Toggle(t(.launchAtLogin), isOn: binding(model.launchAtLogin) { .setLaunchAtLogin($0) })
            Picker(t(.language), selection: languageBinding) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.menuLabel).tag(lang)
                }
            }
        case .shortcut:
            Picker(selection: hotkeyBinding) {
                Text(t(.shortcutOff)).tag(HotkeyChoice.off)
                Divider()
                ForEach(HotkeyChoice.allCases.filter { $0 != .off }) { choice in
                    Text(choice.label).tag(choice)
                }
            } label: {
                Text(t(.revealShortcut))
            }
            if model.hotkeyTaken {
                Label(t(.hotkeyTaken), systemImage: "exclamationmark.triangle")
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(PulseTheme.Tone.attention.color)
            }
        case .notifications:
            switch model.notifications {
            case .notAsked:
                LabeledContent {
                    Button(t(.enableNotifications)) { send(.enableNotifications) }
                } label: {
                    Text(t(.notifyNotConfigured))
                }
            case .denied:
                LabeledContent {
                    Button(t(.openNotificationSettings)) { send(.openNotificationSettings) }
                } label: {
                    Text(t(.notifyDenied))
                        .foregroundStyle(PulseTheme.Tone.attention.color)
                }
            case .allowed:
                EmptyView()
            }
            Toggle(t(.notifyWaiting), isOn: binding(model.notifyOnWaiting) { .setNotifyOnWaiting($0) })
                .disabled(model.notifications != .allowed)
            ForEach(model.mutedAgents, id: \.self) { agent in
                LabeledContent {
                    Button {
                        send(.unmute(agent))
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(t(.unmute) + " " + agent.displayName)
                } label: {
                    Label {
                        Text(agent.displayName)
                    } icon: {
                        AgentIconView(id: agent)
                    }
                }
            }
        case .hooks:
            LabeledContent {
                HStack(spacing: PulseTheme.Space.s) {
                    if model.hooksInstalled {
                        Button(t(.uninstallHooks), role: .destructive) { send(.uninstallHooks) }
                    }
                    Button(t(.installHooks)) { send(.installHooks) }
                }
            } label: {
                Text(t(.settingsHooksTitle))
                Text(model.hooksStatus)
                    .foregroundStyle(model.hooksInstalled ? AnyShapeStyle(.secondary) : AnyShapeStyle(PulseTheme.Tone.attention.color))
            }
            ForEach(model.hookAgents) { line in
                LabeledContent {
                    Text(line.state)
                        .foregroundStyle(line.installed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                } label: {
                    Label {
                        Text(line.agent.displayName)
                        if !line.lastEvent.isEmpty {
                            Text(line.lastEvent)
                        }
                        if let note = line.note {
                            Text(note)
                        }
                    } icon: {
                        AgentIconView(id: line.agent)
                    }
                }
            }
            LabeledContent {
                Button(t(.testWaitingSignal)) { send(.testHooks) }
                    .disabled(!model.hooksInstalled || model.hookTestRunning)
            } label: {
                Text(t(.settingsHooksTest))
                Text(model.hookTest)
                    .foregroundStyle(model.hookTestTone == .idle ? AnyShapeStyle(.secondary) : AnyShapeStyle(model.hookTestTone.color))
            }
        case .terminal:
            Toggle(isOn: binding(model.allowTerminalAutomation) { .setTerminalAutomation($0) }) {
                Text(t(.allowTerminalAutomation))
                Text(t(.allowTerminalAutomationHint))
            }
        case .dataAccess:
            Toggle(isOn: binding(model.readProtectedAppData) { .setReadAppData($0) }) {
                Text(t(.agentDataAccess))
                Text(t(.agentDataAccessHint))
            }
            .listRowBackground(
                model.focus == .dataAccess
                    ? Color.accentColor.opacity(PulseTheme.Fill.selected)
                    : Color.clear
            )
        case .updates:
            Toggle(t(.checkForUpdates), isOn: binding(model.updateCheckEnabled) { .setUpdateCheck($0) })
            LabeledContent {
                if model.updateAvailable {
                    Button(t(.openRelease)) { send(.openRelease) }
                } else {
                    Button(t(.checkNow)) { send(.checkForUpdates) }
                }
            } label: {
                Text(model.updateStatus)
                    .foregroundStyle(model.updateAvailable ? AnyShapeStyle(PulseTheme.Tone.running.color) : AnyShapeStyle(.secondary))
            }
        }
    }

    @ViewBuilder
    private func footer(_ section: SettingsModel.Section) -> some View {
        switch section {
        case .hooks:
            Text(t(.hooksHint))
                .font(PulseTheme.Font.caption)
                .foregroundStyle(.secondary)
        case .dataAccess:
            Text(t(.agentDataAccessSkipHint))
                .font(PulseTheme.Font.caption)
                .foregroundStyle(.secondary)
        case .general, .shortcut, .notifications, .terminal, .updates:
            EmptyView()
        }
    }

    /// The version, what kind of build it is, and the way into Diagnostics
    /// — one small block, not two sections.
    private var about: some View {
        Section {
            VStack(alignment: .leading, spacing: PulseTheme.Space.xs) {
                Text(model.version)
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let warning = model.buildWarning {
                    Text(warning)
                        .font(PulseTheme.Font.caption)
                        .foregroundStyle(PulseTheme.Tone.attention.color)
                }
                Button(t(.diagnosticsOpen)) { send(.openDiagnostics) }
                    .buttonStyle(.link)
                    .font(PulseTheme.Font.caption)
            }
        }
    }
}
