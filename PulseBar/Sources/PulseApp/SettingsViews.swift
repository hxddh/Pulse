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
        return SettingsModel(
            lang: lang,
            launchAtLogin: login.isOn,
            loginNote: login.note,
            notifications: SettingsModel.notifications(notifyAuthorized),
            hooksStatus: hooksStatus.label(lang: lang),
            hooksInstalled: !hooksStatus.installedAgents.isEmpty || connections.contains { $0.install.carriesHook },
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
    }

    func performSettings(_ action: SettingsModel.Action) {
        switch action {
        case .setLaunchAtLogin(let on): setLaunchAtLogin(on)
        case .openLoginItems: LoginItem.openSystemSettings()
        case .enableNotifications: PulseNotify.requestAuthorizationAfterUserAction()
        case .openNotificationSettings: PulseNotify.openSystemSettings()
        case .installHooks, .uninstallHooks:
            if let job = SettingsModel.hooksJob(action) { runHooks(job) }
        case .copyReport: copyReport()
        case .openReleases:
            if let url = URL(string: SettingsModel.releasesURL) { NSWorkspace.shared.open(url) }
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
            // One line per agent: its name and state, then — quietly — that
            // it does not report waits, what was heard (and any caveat), and
            // the last event not used.
            ForEach(model.hookAgents) { line in
                LabeledContent {
                    Text(line.state)
                        .foregroundStyle(Self.style(line.tone))
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
