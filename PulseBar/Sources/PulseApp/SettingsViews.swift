// Settings: one page of five short groups and a footer. `SettingsView`
// builds a `SettingsModel` from the store (settings and a few flags, never a
// scan) and performs its actions; `SettingsFace` renders the value.

import SwiftUI
import AppKit

@MainActor
struct SettingsView: View {
    /// The store itself. Under Observation this page is redrawn only
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
            store.refreshLoginItem()
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
        }
        let build = PulseVersion.buildLine
        let present = Set(AgentID.priority.filter(HooksInstaller.vendorPresent))
        let login = SettingsModel.loginLine(asked: settings.launchAtLogin, state: loginItem)
        return SettingsModel(
            lang: lang,
            launchAtLogin: login.isOn,
            loginNote: login.note,
            language: settings.language,
            terminalAutomation: settings.allowTerminalAutomation,
            hotkeyLabel: settings.hotkey?.label,
            hotkeyRecording: hotkeyRecorder.recording,
            hotkeyProblem: hotkeyRecorder.problem
                ?? (settings.hotkey != nil && !hotkeyRegistered && !hotkeyRecorder.recording ? .cantUse : nil),
            notifications: notifications,
            notifyOnWaiting: notifications == .allowed && settings.notifyOnWaiting,
            mutedAgents: SettingsModel.sortedMuted(settings.mutedAgents),
            hooksStatus: hooksStatus.label(lang: lang),
            hooksInstalled: hooksInstalled,
            hooksBusy: hooksStatus.isWorking,
            hookAgents: SettingsModel.hookAgents(
                installed: hooksStatus.installedAgents,
                present: present,
                lastEventMs: engine.latestHookEventMs,
                nowMs: Int64(Date().timeIntervalSince1970 * 1000),
                lang: lang,
                failed: hooksStatus.failures
            ),
            absentAgents: SettingsModel.absentAgents(
                installed: hooksStatus.installedAgents,
                present: present,
                failed: hooksStatus.failures
            ),
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
        case .setLaunchAtLogin(let on): setLaunchAtLogin(on)
        case .openLoginItems: LoginItem.openSystemSettings()
        case .setLanguage(let language): set(\.language, language)
        case .setTerminalAutomation(let on): set(\.allowTerminalAutomation, on)
        case .recordHotkey: startRecordingHotkey()
        case .stopRecordingHotkey: stopRecordingHotkey()
        case .clearHotkey:
            stopRecordingHotkey()
            set(\.hotkey, nil)
            if hotkeyRecorder.problem != nil { hotkeyRecorder.problem = nil }
        case .enableNotifications: requestNotificationAuthorization()
        case .openNotificationSettings: openSystemNotificationSettings()
        case .setNotifyOnWaiting(let on):
            guard notifyAuthorized == true else { return }
            set(\.notifyOnWaiting, on)
        case .unmute(let agent):
            if settings.mutedAgents.contains(agent) { toggleMute(agent) }
        case .installHooks, .uninstallHooks, .installHook, .uninstallHook:
            if let job = SettingsModel.hooksJob(action) { runHooks(job) }
        case .copyReport: copyReport()
        case .setUpdateCheck(let on): set(\.updateCheckEnabled, on)
        case .checkForUpdates: checkForUpdatesNow()
        case .openRelease:
            if let url = updateAvailableURL { NSWorkspace.shared.open(url) }
        case .uninstallPulse: uninstallPulse()
        }
    }

    /// "Copy report": the plain-text report (`SettingsModel.report`), only
    /// on the person's click, only to their own clipboard.
    var reportText: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return SettingsModel.report(SettingsModel.ReportInput(
            version: "\(PulseVersion.fingerprint) · \(PulseVersion.distributionChannel)",
            macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            installed: hooksStatus.installedAgents,
            present: Set(AgentID.priority.filter(HooksInstaller.vendorPresent)),
            failed: hooksStatus.failures,
            lastEventMs: engine.latestHookEventMs,
            nowMs: Int64(Date().timeIntervalSince1970 * 1000),
            notifyAuthorized: notifyAuthorized,
            notifyOnWaiting: settings.notifyOnWaiting,
            terminalAutomation: settings.allowTerminalAutomation,
            hotkey: settings.hotkey,
            hotkeyRegistered: hotkeyRegistered,
            launchAtLogin: settings.launchAtLogin,
            loginItem: loginItem,
            sessions: cachedAll.map(SettingsModel.ReportSession.init)
        ))
    }

    func copyReport() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(reportText, forType: .string)
        DebugLog.write("report copied")
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

    // MARK: Rows

    @ViewBuilder
    private func rows(_ section: SettingsModel.Section) -> some View {
        switch section {
        case .general:
            Toggle(t(.launchAtLogin), isOn: binding(model.launchAtLogin) { .setLaunchAtLogin($0) })
            switch model.loginNote {
            case .needsApproval?:
                LabeledContent {
                    Button(t(.openLoginItems)) { send(.openLoginItems) }
                } label: {
                    Text(t(.loginItemNeedsApproval))
                        .foregroundStyle(PulseTheme.Tone.attention.color)
                }
            case .failed?:
                Label(t(.loginItemFailed), systemImage: "exclamationmark.triangle")
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(PulseTheme.Tone.attention.color)
            case nil:
                EmptyView()
            }
            Picker(t(.language), selection: languageBinding) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.menuLabel(model.lang)).tag(lang)
                }
            }
            Toggle(isOn: binding(model.terminalAutomation) { .setTerminalAutomation($0) }) {
                Text(t(.terminalAutomation))
                Text(t(.terminalAutomationHint))
            }
        case .shortcut:
            LabeledContent {
                HStack(spacing: PulseTheme.Space.xs) {
                    Button {
                        send(model.hotkeyRecording ? .stopRecordingHotkey : .recordHotkey)
                    } label: {
                        Text(SettingsModel.shortcutTitle(model))
                            .frame(minWidth: 120)
                    }
                    .buttonStyle(.bordered)
                    if model.hotkeyLabel != nil, !model.hotkeyRecording {
                        Button { send(.clearHotkey) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(t(.shortcutClear))
                    }
                }
            } label: {
                Text(t(.revealShortcut))
            }
            if model.hotkeyRecording, model.hotkeyProblem == nil {
                Text(t(.shortcutRecordingHint))
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(.secondary)
            }
            switch model.hotkeyProblem {
            case .needsModifier?:
                Label(t(.shortcutNeedsModifier), systemImage: "keyboard")
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(.secondary)
            case .cantUse?:
                Label(t(.hotkeyTaken), systemImage: "exclamationmark.triangle")
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(PulseTheme.Tone.attention.color)
            case nil:
                EmptyView()
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
                            .disabled(model.hooksBusy)
                    }
                    Button(t(.installHooks)) { send(.installHooks) }
                        .disabled(model.hooksBusy)
                }
            } label: {
                Text(t(.settingsHooksTitle))
                Text(model.hooksStatus)
                    .foregroundStyle(model.hooksInstalled ? AnyShapeStyle(.secondary) : AnyShapeStyle(PulseTheme.Tone.attention.color))
            }
            ForEach(model.hookAgents) { line in
                LabeledContent {
                    HStack(spacing: PulseTheme.Space.s) {
                        Text(line.state)
                            .foregroundStyle(
                                line.failed ? AnyShapeStyle(PulseTheme.Tone.attention.color)
                                    : line.installed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary)
                            )
                        if line.needsFix {
                            Button(t(.hookInstallOne)) { send(.installHook(line.agent)) }
                                .controlSize(.small)
                                .disabled(model.hooksBusy)
                                .accessibilityLabel(String(format: t(.hookInstallOneA11y), line.agent.displayName))
                        }
                        if line.installed {
                            Button(t(.hookRemoveOne)) { send(.uninstallHook(line.agent)) }
                                .controlSize(.small)
                                .disabled(model.hooksBusy)
                                .accessibilityLabel(String(format: t(.hookRemoveOneA11y), line.agent.displayName))
                        }
                    }
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
            if let absent = SettingsModel.absentLine(model.absentAgents, lang: model.lang) {
                Text(absent)
                    .foregroundStyle(.secondary)
            }
            LabeledContent {
                Button(t(.copyReport)) { send(.copyReport) }
            } label: {
                Text(t(.settingsReportHint))
                    .foregroundStyle(.secondary)
            }
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
        case .general, .shortcut, .notifications, .updates:
            EmptyView()
        }
    }

    /// The version and what kind of build it is — one small block — and
    /// "Uninstall Pulse…".
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
            }
            Button(t(.uninstallPulse), role: .destructive) { send(.uninstallPulse) }
                .disabled(model.hooksBusy)
        }
    }
}
