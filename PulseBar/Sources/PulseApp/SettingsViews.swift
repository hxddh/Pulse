// Settings: one page of three short groups and a footer. `SettingsView`
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
            store.probeHooks()
            store.refreshPresentAgents()
            store.refreshLoginItem()
            store.refreshAutomation()
            PulseNotify.refreshAuthorization()
        }
    }
}

@MainActor
extension StatusStore {
    /// The Settings page as a value.
    var settingsModel: SettingsModel {
        var warning: String?
        // A stale `Pulse.app` beside a fresh build; never for a QA fixture,
        // whose host bundle's version is unrelated to Pulse.
        if !previewFixtureActive, case .mismatch(let bundle) = PulseVersion.channel {
            warning = String(format: tr(.versionMismatchHint), PulseVersion.semver, bundle)
        } else if PulseVersion.distributionChannel == "preview" {
            warning = tr(.buildPreview)
        }
        let build = PulseVersion.buildLine
        let login = SettingsModel.loginLine(asked: settings.launchAtLogin, state: loginItem)
        let connections = self.connections
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        var model = SettingsModel(
            lang: lang,
            launchAtLogin: login.isOn,
            loginNote: login.note,
            notifications: SettingsModel.notifications(notifyAuthorized),
            hooksStatus: hooksStatus.label(installed: connections.filter { $0.install.carriesHook }.count, lang: lang),
            hooksInstalled: connections.contains { $0.install.carriesHook },
            hooksBusy: hooksStatus.isWorking,
            hookAgents: SettingsModel.hookAgents(
                connections: connections,
                present: presentAgents,
                nowMs: Int64(Date().timeIntervalSince1970 * 1000),
                lang: lang
            ),
            absentAgents: SettingsModel.absentAgents(connections: connections, present: presentAgents),
            version: build.isEmpty ? PulseVersion.about : "\(PulseVersion.about) · \(build)",
            buildWarning: warning,
            focus: settingsFocus.target.map(SettingsModel.section(for:))
        )
        model.globalShortcut = settings.globalShortcut
        model.shortcutNote = SettingsModel.shortcutNote(
            on: settings.globalShortcut, registered: shortcutRegistered, choice: settings.shortcut, lang: lang
        )
        model.shortcutChoice = settings.shortcut
        model.directJumpShortcut = settings.directJumpShortcut
        model.directJumpNote = SettingsModel.directJumpNote(
            on: settings.directJumpShortcut, registered: directJumpRegistered, lang: lang
        )
        model.groupByProject = settings.groupByProject
        model.menuBarStyle = settings.menuBarStyle
        model.floatingBeacon = settings.floatingBeacon
        model.automation = SettingsModel.automationLines(automation, lang: lang)
        model.muteCandidates = SettingsModel.muteCandidates(present: presentAgents)
        model.mutedAgents = Set(settings.mutedAgents)
        model.notifyDoneCandidates = SettingsModel.notifyDoneCandidates(present: presentAgents)
        model.notifyDoneAgents = Set(settings.notifyDoneAgents)
        model.notifyLongTurnSeconds = settings.notifyLongTurnSeconds
        model.notificationSound = settings.notificationSound
        model.quietRemaining = settings.quietRemaining(at: nowMs, lang: lang)
        let ping = SettingsModel.pingLine(hookPing, nowMs: nowMs, lang: lang)
        model.pingLine = ping?.text
        model.pingWarning = ping?.warning ?? false
        return model
    }

    func performSettings(_ action: SettingsModel.Action) {
        switch action {
        case .setLaunchAtLogin(let on): setLaunchAtLogin(on)
        case .openLoginItems: LoginItem.openSystemSettings()
        case .enableNotifications: PulseNotify.requestAuthorizationAfterUserAction()
        case .openNotificationSettings: PulseNotify.openSystemSettings()
        case .installHooks, .uninstallHooks:
            if let job = SettingsModel.hooksJob(action) { runHooks(job) }
        case .installAgent(let agent): runHooks(.install, agents: [agent])
        case .uninstallAgent(let agent): runHooks(.uninstall, agents: [agent])
        case .copyReport: copyReport()
        case .openReleases:
            if let url = URL(string: SettingsModel.releasesURL) { NSWorkspace.shared.open(url) }
        case .setGlobalShortcut(let on): setGlobalShortcut(on)
        case .setDirectJumpShortcut(let on): setDirectJumpShortcut(on)
        case .setMuted(let agent, let muted): setMuted(agent, muted)
        case .setNotifyDone(let agent, let on): setNotifyDone(agent, on)
        case .setLongTurnSeconds(let seconds): setLongTurnSeconds(seconds)
        case .setNotificationSound(let sound): setNotificationSound(sound)
        case .testConnection: testHookConnection()
        case .setShortcut(let choice): setShortcut(choice)
        case .setGroupByProject(let on): set(\.groupByProject, on)
        case .setMenuBarStyle(let style): setMenuBarStyle(style)
        case .setFloatingBeacon(let on): set(\.floatingBeacon, on)
        case .resumeQuiet: resumeQuiet()
        case .openAutomationSettings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// "Copy report": the plain-text report (`SettingsModel.report`), only
    /// on the person's click, only to their own clipboard.
    var reportText: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return SettingsModel.report(SettingsModel.ReportInput(
            version: "\(PulseVersion.fingerprint) · \(PulseVersion.distributionChannel)",
            macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            connections: connections,
            present: presentAgents,
            nowMs: Int64(Date().timeIntervalSince1970 * 1000),
            notifyAuthorized: notifyAuthorized,
            launchAtLogin: settings.launchAtLogin,
            loginItem: loginItem,
            sessions: rows.map { SettingsModel.ReportSession($0, facts: facts(for: $0.key)) }
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
                        .foregroundStyle(PulseTheme.warning)
                }
            case .failed?:
                Label(t(.loginItemFailed), systemImage: "exclamationmark.triangle")
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(PulseTheme.warning)
            case nil:
                EmptyView()
            }
            Toggle(String(format: t(.settingsShortcut), model.shortcutChoice.display), isOn: binding(model.globalShortcut) { .setGlobalShortcut($0) })
            if model.globalShortcut {
                Picker(t(.settingsShortcutChoice), selection: Binding(
                    get: { model.shortcutChoice },
                    set: { [send] choice in send(.setShortcut(choice)) }
                )) {
                    ForEach(ShortcutChoice.allCases, id: \.self) { choice in
                        Text(choice.display).tag(choice)
                    }
                }
            }
            if let note = model.shortcutNote {
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(PulseTheme.warning)
            }
            Toggle(t(.settingsDirectJump), isOn: binding(model.directJumpShortcut) { .setDirectJumpShortcut($0) })
            Text(t(.settingsDirectJumpHint))
                .font(PulseTheme.Font.caption)
                .foregroundStyle(.secondary)
            if let note = model.directJumpNote {
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(PulseTheme.warning)
            }
            Toggle(t(.settingsGroupByProject), isOn: binding(model.groupByProject) { .setGroupByProject($0) })
            Picker(t(.settingsMenuBarStyleTitle), selection: Binding(
                get: { model.menuBarStyle },
                set: { [send] style in send(.setMenuBarStyle(style)) }
            )) {
                ForEach(MenuBarStyle.allCases, id: \.self) { style in
                    Text(SettingsModel.menuBarStyleLabel(style, lang: model.lang)).tag(style)
                }
            }
            Toggle(t(.settingsFloatingBeacon), isOn: binding(model.floatingBeacon) { .setFloatingBeacon($0) })
            Text(t(.settingsFloatingBeaconHint))
                .font(PulseTheme.Font.caption)
                .foregroundStyle(.secondary)
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
                        .foregroundStyle(PulseTheme.warning)
                }
            case .allowed:
                LabeledContent {
                    Button(t(.openNotificationSettings)) { send(.openNotificationSettings) }
                } label: {
                    Text(t(.notifyAllowed))
                    Text(t(.notifyFocusNote))
                }
            }
            if let quietRemaining = model.quietRemaining {
                LabeledContent {
                    Button(t(.quietResume)) { send(.resumeQuiet) }
                } label: {
                    Label(String(format: t(.quietActiveBadge), quietRemaining), systemImage: "bell.slash.fill")
                        .foregroundStyle(.secondary)
                }
            }
            Picker(t(.settingsSoundTitle), selection: Binding(
                get: { model.notificationSound },
                set: { [send] sound in send(.setNotificationSound(sound)) }
            )) {
                Text(t(.settingsSoundDefault)).tag(NotificationSound.default)
                Text(t(.settingsSoundDistinct)).tag(NotificationSound.distinct)
                Text(t(.settingsSoundSilent)).tag(NotificationSound.silent)
            }
            if !model.muteCandidates.isEmpty {
                VStack(alignment: .leading, spacing: PulseTheme.Space.xs) {
                    Text(t(.settingsMuteTitle))
                    HStack(spacing: PulseTheme.Space.m) {
                        ForEach(model.muteCandidates, id: \.self) { agent in
                            let muted = model.mutedAgents.contains(agent)
                            Toggle(isOn: binding(!muted) { .setMuted(agent, !$0) }) {
                                Label { Text(agent.displayName) } icon: { AgentIconView(id: agent) }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    Text(t(.settingsMuteHint))
                        .font(PulseTheme.Font.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !model.notifyDoneCandidates.isEmpty {
                VStack(alignment: .leading, spacing: PulseTheme.Space.xs) {
                    Text(t(.settingsDoneNotifyTitle))
                    HStack(spacing: PulseTheme.Space.m) {
                        ForEach(model.notifyDoneCandidates, id: \.self) { agent in
                            let enabled = model.notifyDoneAgents.contains(agent)
                            Toggle(isOn: binding(enabled) { .setNotifyDone(agent, $0) }) {
                                Label { Text(agent.displayName) } icon: { AgentIconView(id: agent) }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    Text(t(.settingsDoneNotifyHint))
                        .font(PulseTheme.Font.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Picker(t(.settingsLongTurnTitle), selection: Binding(
                get: { model.notifyLongTurnSeconds },
                set: { [send] seconds in send(.setLongTurnSeconds(seconds)) }
            )) {
                ForEach(PulseSettings.longTurnOptions, id: \.self) { seconds in
                    Text(SettingsModel.longTurnLabel(seconds, lang: model.lang)).tag(seconds)
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
                    .foregroundStyle(model.hooksInstalled ? AnyShapeStyle(.secondary) : AnyShapeStyle(PulseTheme.warning))
            }
            if model.hooksNeedUpdate {
                Text(t(.settingsHookUpdateHint))
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(PulseTheme.warning)
            }
            // One line per agent: its name and state, with a quick per-agent
            // Install / Update / Remove button beside the state.
            ForEach(model.hookAgents) { line in
                LabeledContent {
                    HStack(spacing: PulseTheme.Space.s) {
                        Text(line.state)
                            .foregroundStyle(Self.style(line.tone))
                        if line.connection.install.needsUpdate {
                            Button(t(.updateOne)) { send(.installAgent(line.agent)) }
                                .controlSize(.small)
                                .disabled(model.hooksBusy)
                        } else if line.installed {
                            Button(t(.removeOne)) { send(.uninstallAgent(line.agent)) }
                                .controlSize(.small)
                                .disabled(model.hooksBusy)
                        } else {
                            Button(t(.installOne)) { send(.installAgent(line.agent)) }
                                .controlSize(.small)
                                .disabled(model.hooksBusy)
                        }
                    }
                } label: {
                    Label {
                        Text(line.agent.displayName)
                        if let noWaits = line.noWaits {
                            Text(noWaits)
                        }
                        if !line.detail.isEmpty {
                            Text(line.detail)
                        }
                        if let notUsed = line.notUsed {
                            Text(notUsed)
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
            ForEach(model.automation) { line in
                LabeledContent {
                    if line.warning {
                        Button(t(.openAutomationSettings)) { send(.openAutomationSettings) }
                    }
                } label: {
                    Text(line.name)
                    Text(line.text)
                        .foregroundStyle(line.warning ? AnyShapeStyle(PulseTheme.warning) : AnyShapeStyle(.secondary))
                }
            }
            LabeledContent {
                Button(t(.settingsTestConnection)) { send(.testConnection) }
                    .disabled(model.hooksBusy)
            } label: {
                if let ping = model.pingLine {
                    Text(ping)
                        .foregroundStyle(model.pingWarning ? AnyShapeStyle(PulseTheme.warning) : AnyShapeStyle(.secondary))
                } else {
                    Text(t(.settingsTestConnection))
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent {
                Button(t(.copyReport)) { send(.copyReport) }
            } label: {
                Text(t(.settingsReportHint))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func style(_ tone: SettingsModel.HookAgent.Tone) -> AnyShapeStyle {
        switch tone {
        case .ok: return AnyShapeStyle(.secondary)
        case .warning: return AnyShapeStyle(PulseTheme.warning)
        case .quiet: return AnyShapeStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func footer(_ section: SettingsModel.Section) -> some View {
        switch section {
        case .hooks:
            Text(t(.hooksHint))
                .font(PulseTheme.Font.caption)
                .foregroundStyle(.secondary)
        case .general, .notifications:
            EmptyView()
        }
    }

    /// The version and what kind of build it is — one small block — and
    /// "Releases…", the one way to a newer Pulse.
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
                        .foregroundStyle(PulseTheme.warning)
                }
            }
            Button(t(.releases)) { send(.openReleases) }
        }
    }
}

/// AppKit-hosted settings window — reliable for LSUIElement / accessory apps.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    /// Read by `PulseQA`'s settings capture.
    private(set) var window: NSWindow?
    private var hosting: NSHostingController<SettingsView>?
    private(set) var isOpen = false

    /// Where it scrolls is `store.settingsFocus`, set by
    /// `StatusStore.openSettings(focus:)`.
    func show(store: StatusStore) {
        // Fast path: reuse window + hosting; SettingsView already observes store.
        if let window, let hosting {
            hosting.rootView = SettingsView(store: store)
            window.title = store.tr(.settingsTitle)
            present(window)
            return
        }

        let root = SettingsView(store: store)
        let host = NSHostingController(rootView: root)
        let win = NSWindow(contentViewController: host)
        win.title = store.tr(.settingsTitle)
        win.identifier = NSUserInterfaceItemIdentifier("pulse-settings")
        win.styleMask = [.titled, .closable, .miniaturizable]
        // One page of short groups (EXPERIENCE.md, Settings).
        win.setContentSize(NSSize(width: 500, height: 620))
        win.contentMinSize = NSSize(width: 460, height: 420)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        hosting = host
        window = win
        present(win)
    }

    private func present(_ window: NSWindow) {
        isOpen = true
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp?.activate(ignoringOtherApps: true)
        // Escalate only if the window did not become key (the slow path):
        // Pulse is a regular app while Settings is open, an accessory again
        // once it closes. Flipping the policy is the slow part, so it stays
        // `.accessory` whenever it can.
        DispatchQueue.main.async {
            if !window.isKeyWindow {
                if NSApp?.activationPolicy() != .regular {
                    NSApp?.setActivationPolicy(.regular)
                }
                window.makeKeyAndOrderFront(nil)
                NSApp?.activate(ignoringOtherApps: true)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        isOpen = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if SettingsWindowController.shared.isOpen { return }
            if NSApp?.activationPolicy() != .accessory {
                NSApp?.setActivationPolicy(.accessory)
            }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        isOpen = true
    }
}
