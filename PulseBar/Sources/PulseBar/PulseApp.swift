import SwiftUI
import AppKit

enum AppServices {
    @MainActor static let store = StatusStore()
}

@main
struct PulseBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var store = AppServices.store

    var body: some Scene {
        MenuBarExtra {
            TrayPanel(store: store)
        } label: {
            MenuBarLabel(snapshot: store.snapshot)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppServices.store.start()
        if CommandLine.arguments.contains("--open-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                AppServices.store.openSettings()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotKey.uninstall()
    }
}

// MARK: - Glance

struct MenuBarLabel: View {
    let snapshot: PulseSnapshot
    @State private var waitPulse = false

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: PulseBrand.menuIcon(for: snapshot.glance))
                .resizable()
                .renderingMode(.template)
                .frame(width: 14, height: 14)
                .foregroundStyle(snapshot.glance.lampColor)
                .opacity(snapshot.glance == .waiting ? (waitPulse ? 1.0 : 0.55) : 1.0)
                .animation(
                    snapshot.glance == .waiting
                        ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                        : .default,
                    value: waitPulse
                )
                .onAppear { waitPulse = snapshot.glance == .waiting }
                .onChange(of: snapshot.glance) { _, g in
                    waitPulse = g == .waiting
                }
                .accessibilityLabel(snapshot.glance.accessibilityLabel)
            if snapshot.glance != .idle, !snapshot.title.isEmpty {
                Text(snapshot.title)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(snapshot.glance.lampColor)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .help(snapshot.tooltip)
    }
}

// MARK: - Tray chrome

private enum TrayChrome {
    static let width: CGFloat = 360
    static let padX: CGFloat = 14
    static let waitAccent = GlanceKind.waiting.lampColor
    static let runAccent = GlanceKind.running.lampColor
}

private struct StatusChip: View {
    enum Kind { case waiting, running, recent, process }

    let kind: Kind
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(background, in: Capsule(style: .continuous))
    }

    private var foreground: Color {
        switch kind {
        case .waiting: return TrayChrome.waitAccent
        case .running: return TrayChrome.runAccent
        case .process: return Color.secondary.opacity(0.9)
        case .recent: return Color.secondary.opacity(0.85)
        }
    }

    private var background: Color {
        switch kind {
        case .waiting: return TrayChrome.waitAccent.opacity(0.16)
        case .running: return TrayChrome.runAccent.opacity(0.12)
        case .process: return Color.primary.opacity(0.05)
        case .recent: return Color.primary.opacity(0.04)
        }
    }
}

// MARK: - Tray panel

struct TrayPanel: View {
    @ObservedObject var store: StatusStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            nudge
            Divider().opacity(0.4)

            if store.snapshot.rows.isEmpty {
                emptyState
            } else {
                agentList
            }

            Divider().opacity(0.4)
            actions
            versionFooter
        }
        .frame(width: TrayChrome.width)
    }

    /// Tertiary build badge — answers "which Pulse am I running?" without
    /// opening Settings. Muted so it never competes with the status narrative.
    private var versionFooter: some View {
        Button {
            store.copyDiagnostics()
        } label: {
            HStack(spacing: 5) {
                Text(PulseVersion.about)
                if store.isVersionMismatch {
                    Text(store.tr(.versionStale))
                        .foregroundStyle(GlanceKind.error.lampColor)
                }
                Spacer(minLength: 0)
                Text(store.didCopyDiagnostics ? store.tr(.copied) : store.tr(.copyDiagnostics))
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, TrayChrome.padX)
            .padding(.bottom, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(PulseVersion.fingerprint)
        .accessibilityLabel(PulseVersion.fingerprint)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            PulseMarkView(
                size: 18,
                tone: store.snapshot.glance.lampColor
            )
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if store.isRefreshing {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(store.isRefreshing ? store.tr(.refreshing) : headerTitle)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(headerTitleColor)
                        .lineLimit(1)
                }
                if !store.isRefreshing, !headerDetail.isEmpty {
                    Text(headerDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, TrayChrome.padX)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var headerTitle: String {
        let t = store.snapshot.headerTitle
        return t.isEmpty ? store.snapshot.header : t
    }

    private var headerDetail: String {
        store.snapshot.headerDetail
    }

    private var headerTitleColor: Color {
        store.snapshot.glance.lampColor
    }

    @ViewBuilder
    private var nudge: some View {
        if store.needsHooksNudge {
            Button { store.openSettings() } label: {
                Text(store.tr(.hooksNudge))
                    .font(.system(size: 11))
                    .foregroundStyle(TrayChrome.waitAccent.opacity(0.95))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, TrayChrome.padX)
                    .padding(.bottom, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else if store.needsWaitingSignalNudge {
            Text(store.tr(.waitingSignalNudge))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, TrayChrome.padX)
                .padding(.bottom, 10)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            PulseMarkView(size: 40, tone: Color.secondary.opacity(0.45))
            Text(store.tr(.noAgentsDetected))
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 20)
    }

    private var agentList: some View {
        let maxH: CGFloat = store.showAllAgents ? 440 : 300
        let contentH = min(maxH, store.snapshot.rows.reduce(CGFloat(0)) { $0 + Self.estimateHeight($1) })

        return VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(store.snapshot.rows.enumerated()), id: \.element.id) { index, row in
                        AgentRowButton(row: row, store: store)
                        if index < store.snapshot.rows.count - 1 {
                            Divider()
                                .padding(.leading, row.waiting ? 18 : 46)
                                .opacity(0.28)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: max(56, contentH))

            if store.snapshot.hiddenCount > 0 {
                overflowButton(
                    String(format: store.tr(.andMore), store.snapshot.hiddenCount)
                ) { store.toggleShowAllAgents() }
            } else if store.showAllAgents, store.snapshot.totalCount > 4 {
                overflowButton(store.tr(.showLess)) { store.toggleShowAllAgents() }
            }
        }
    }

    private func overflowButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, TrayChrome.padX)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var actions: some View {
        VStack(spacing: 0) {
            TrayAction(title: store.tr(.refresh), systemImage: "arrow.clockwise", shortcut: "r") {
                store.refresh(reason: "manual")
            }
            .disabled(store.isRefreshing)
            if store.snapshot.rows.contains(where: \.waiting) {
                TrayAction(title: store.tr(.clearWaiting), systemImage: "checkmark.circle") {
                    store.clearWaiting()
                }
            }
            TrayAction(title: store.tr(.settings), systemImage: "gearshape", shortcut: ",") {
                store.openSettings()
            }
            TrayAction(title: store.tr(.quit), systemImage: "power", shortcut: "q") {
                store.quit()
            }
        }
        .padding(.vertical, 5)
    }

    private static func estimateHeight(_ row: AgentRow) -> CGFloat {
        var h: CGFloat = 44
        if row.waiting { h += 20 }
        if row.isProcessOnly { h -= 4 }
        if row.metaLine != nil { h += 14 }
        if row.waiting || row.canFocusTerminal || row.canOpenFolder { h += 28 }
        return h + 8
    }
}

// MARK: - Agent row

private struct AgentRowButton: View {
    let row: AgentRow
    let store: StatusStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                store.primaryAction(row)
            } label: {
                HStack(alignment: .top, spacing: 0) {
                    // Waiting scream: solid color block, not a 3pt rail.
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(row.waiting ? TrayChrome.waitAccent : Color.clear)
                        .frame(width: row.waiting ? 8 : 0)
                        .padding(.vertical, 4)

                    HStack(alignment: .top, spacing: 10) {
                        AgentIconView(id: row.agent, waiting: row.waiting)
                            .padding(.top, 2)
                            .opacity(row.isProcessOnly ? 0.55 : 1)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(heroTitle)
                                    .font(.system(
                                        size: row.isProcessOnly ? 12.5 : 13.5,
                                        weight: row.isProcessOnly ? .medium : .semibold,
                                        design: .rounded
                                    ))
                                    .foregroundStyle(heroColor)
                                    .lineLimit(2)
                                Spacer(minLength: 6)
                                statusChip
                            }

                            Text(agentLine)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)

                            if let detail = store.localizedWaitDetail(row) {
                                Text(Self.truncate(detail, 78))
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(TrayChrome.waitAccent)
                                    .lineLimit(2)
                            }

                            if let meta = row.metaLine {
                                Text(meta)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.leading, row.waiting ? 10 : TrayChrome.padX - 2)
                    .padding(.trailing, TrayChrome.padX)
                    .padding(.vertical, row.waiting ? 11 : 9)
                }
                .background(row.waiting ? TrayChrome.waitAccent.opacity(0.10) : Color.clear)
                .opacity(row.isProcessOnly ? 0.82 : 1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
            .accessibilityHint(store.focusActionTitle(row))

            if row.waiting || row.canFocusTerminal || row.canOpenFolder {
                HStack(spacing: 16) {
                    if row.waiting {
                        Button(store.tr(.dismissWait)) { store.dismissWaiting(row) }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11, weight: .medium))
                    }
                    if row.canFocusTerminal {
                        Button(store.focusActionTitle(row)) { store.focusTerminal(row) }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11, weight: .medium))
                    }
                    if row.canOpenFolder {
                        Button(store.tr(.openFolder)) { store.openProject(row) }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .padding(.leading, row.waiting ? 52 : 48)
                .padding(.trailing, TrayChrome.padX)
                .padding(.bottom, 8)
                .background(row.waiting ? TrayChrome.waitAccent.opacity(0.10) : Color.clear)
            }
        }
    }

    /// Session title is the row hero; process-only rows de-rank to a status phrase.
    private var heroTitle: String {
        if row.waiting {
            if let t = row.usefulTask { return Self.truncate(t, 72) }
            let short = AgentRow.shortProject(row.project)
            if !short.isEmpty { return short }
            return store.tr(.needsYou)
        }
        if row.isProcessOnly {
            return store.tr(.processDetected)
        }
        if let t = row.usefulTask {
            let label = row.isRecentOnly
                ? "\(store.tr(.activityPrefix)) · \(t)"
                : t
            return Self.truncate(label, 72)
        }
        let short = AgentRow.shortProject(row.project)
        if !short.isEmpty { return short }
        return row.agent.displayName
    }

    private var heroColor: Color {
        if row.waiting { return .primary }
        if row.isProcessOnly { return .secondary }
        return .primary
    }

    /// Agent identity as secondary line (name · project · Warp).
    private var agentLine: String {
        var bits: [String] = [row.agent.displayName]
        let short = AgentRow.shortProject(row.project)
        if !short.isEmpty, short != heroTitle {
            bits.append(short)
        } else if let hint = row.shortSessionHint, row.usefulTask != nil {
            bits.append(hint)
        }
        if row.processCount > 1 { bits.append("×\(row.processCount)") }
        if row.viaWarp { bits.append("Warp") }
        if let sig = row.waitSignal {
            bits.append(sig == .hooks ? store.tr(.signalHooks) : store.tr(.signalPending))
        }
        return bits.joined(separator: " · ")
    }

    @ViewBuilder
    private var statusChip: some View {
        if row.waiting {
            StatusChip(
                kind: .waiting,
                label: row.waitKind.isEmpty ? store.tr(.needsYou) : store.localizedWaitKind(row.waitKind)
            )
        } else if row.isProcessOnly {
            StatusChip(kind: .process, label: store.tr(.processWord))
        } else if row.liveProcess || row.subRunning > 0 {
            if row.subRunning > 0 {
                StatusChip(kind: .running, label: "sub \(row.subRunning)↑")
            } else {
                StatusChip(kind: .running, label: store.tr(.running))
            }
        } else {
            StatusChip(kind: .recent, label: store.tr(.recent))
        }
    }

    private var accessibilityText: String {
        var parts = [heroTitle, row.agent.displayName]
        if row.waiting {
            let line = store.localizedWaitLine(row)
            if !line.isEmpty { parts.append(line) }
        }
        return parts.joined(separator: ", ")
    }

    private static func truncate(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }
}

private struct TrayAction: View {
    let title: String
    let systemImage: String
    var shortcut: Character? = nil
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, TrayChrome.padX)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(title)
        .modifier(OptionalShortcut(shortcut: shortcut))
    }
}

private struct OptionalShortcut: ViewModifier {
    let shortcut: Character?
    func body(content: Content) -> some View {
        if let shortcut {
            content.keyboardShortcut(KeyEquivalent(shortcut), modifiers: .command)
        } else {
            content
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var store: StatusStore

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    PulseMarkView(
                        size: 28,
                        tone: store.snapshot.glance.lampColor
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.snapshot.headerTitle.isEmpty
                              ? store.snapshot.header
                              : store.snapshot.headerTitle)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                        if !store.snapshot.headerDetail.isEmpty {
                            Text(store.snapshot.headerDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            Section(store.tr(.general)) {
                Toggle(store.tr(.liveUpdates), isOn: $store.autoProbe)
                    .onChange(of: store.autoProbe) { _, _ in store.saveSettings() }
                Toggle(store.tr(.notifications), isOn: $store.notifyOnIdle)
                    .onChange(of: store.notifyOnIdle) { _, _ in store.saveSettings() }
                Toggle(store.tr(.notifyWaiting), isOn: $store.notifyOnWaiting)
                    .onChange(of: store.notifyOnWaiting) { _, _ in store.saveSettings() }
                Toggle(store.tr(.quietHours), isOn: $store.quietHoursEnabled)
                    .onChange(of: store.quietHoursEnabled) { _, _ in store.saveSettings() }
                if store.quietHoursEnabled {
                    Text(store.tr(.quietHoursHint))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Stepper("\(store.tr(.quietStart)): \(store.quietStartHour)", value: $store.quietStartHour, in: 0...23)
                        .onChange(of: store.quietStartHour) { _, _ in store.saveSettings() }
                    Stepper("\(store.tr(.quietEnd)): \(store.quietEndHour)", value: $store.quietEndHour, in: 0...23)
                        .onChange(of: store.quietEndHour) { _, _ in store.saveSettings() }
                }
                Toggle(store.tr(.launchAtLogin), isOn: $store.launchAtLogin)
                    .onChange(of: store.launchAtLogin) { _, _ in store.saveSettings() }
                Picker(store.tr(.language), selection: $store.language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.menuLabel).tag(lang)
                    }
                }
                .onChange(of: store.language) { _, _ in store.saveSettings() }
            }

            Section(store.tr(.waitingSignals)) {
                Text(store.tr(.hooksHint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(store.tr(.installHooks)) {
                    store.installHooks()
                }
                Text(store.hooksStatus.label(lang: store.lang))
                    .font(.caption2)
                    .foregroundStyle({
                        switch store.hooksStatus {
                        case .installed, .installedBoth, .installedClaude, .installedCodex:
                            return Color.secondary
                        default:
                            return Color.orange
                        }
                    }())
                Text(store.tr(.attentionBridgeHint))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section(store.tr(.shortcuts)) {
                Text(store.tr(.hotkeyHint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(store.tr(.a11yHint))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !store.snapshot.rows.isEmpty {
                Section(store.tr(.agents)) {
                    ForEach(store.snapshot.rows) { row in
                        HStack(alignment: .top, spacing: 8) {
                            AgentIconView(id: row.agent, waiting: row.waiting)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.titleLine)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .lineLimit(1)
                                if let session = row.usefulTask {
                                    Text(session)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer(minLength: 4)
                            Text(Self.statusLabel(row: row, store: store))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(row.waiting ? Color.orange : Color.secondary)
                        }
                    }
                }
            }

            Section(store.tr(.about)) {
                HStack(spacing: 10) {
                    PulseMarkView(size: 22, tone: .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(PulseVersion.about)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                        Text(store.tr(.tagline))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 4)
                }
                LabeledContent(store.tr(.build)) {
                    Text(buildText)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if store.isVersionMismatch, let bundle = PulseVersion.bundleVersion {
                    Text(String(format: store.tr(.versionMismatchHint), PulseVersion.semver, bundle))
                        .font(.caption2)
                        .foregroundStyle(GlanceKind.error.lampColor)
                }
                Button(store.didCopyDiagnostics ? store.tr(.copied) : store.tr(.copyDiagnostics)) {
                    store.copyDiagnostics()
                }
            }
        }
        .formStyle(.grouped)
        .padding(8)
        .onAppear {
            store.hooksStatus = HooksSupport.probeStatus()
        }
    }

    /// `a1b2c3d · 2026-07-27`, or an honest `dev build` when unpackaged.
    private var buildText: String {
        let line = PulseVersion.buildLine
        return line.isEmpty ? store.tr(.devBuild) : line
    }

    private static func statusLabel(row: AgentRow, store: StatusStore) -> String {
        if row.waiting {
            return row.waitKind.isEmpty ? store.tr(.needsYou) : store.localizedWaitKind(row.waitKind)
        }
        if row.liveProcess || row.subRunning > 0 {
            return store.tr(.running)
        }
        return store.tr(.recent)
    }
}
