import SwiftUI
import AppKit
import Darwin

enum AppServices {
    @MainActor static let store = StatusStore()
}

/// Explicit entry point so `--selftest` can answer before AppKit starts —
/// `App.main()` connects to the WindowServer, which a CI runner may not have.
@main
enum PulseBarMain {
    private static var instanceGuard: SingleInstanceGuard?

    static func main() {
        if let dmg = CommandLine.arguments.first(where: { $0.hasPrefix("--install-update=") }),
           let target = CommandLine.arguments.first(where: { $0.hasPrefix("--install-target=") }),
           let parent = CommandLine.arguments.first(where: { $0.hasPrefix("--install-parent-pid=") }),
           let pid = pid_t(String(parent.dropFirst("--install-parent-pid=".count))) {
            do {
                try UpdateInstaller.runHelper(
                    dmgURL: URL(fileURLWithPath: String(dmg.dropFirst("--install-update=".count))),
                    targetApp: URL(fileURLWithPath: String(target.dropFirst("--install-target=".count))),
                    parentPID: pid
                )
                exit(0)
            } catch {
                fputs("Pulse update failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--selftest") {
            exit(PulseSelfTest.run() ? 0 : 1)
        }
        if CommandLine.arguments.contains("--hook") {
            // Native Waiting path for Claude/Codex — no Python. Always exit 0
            // so vendor hooks never block the agent process.
            var stdinText = ""
            // Vendors pipe JSON on stdin. Never read when attached to a TTY —
            // that would block the menu-bar binary until EOF.
            if isatty(STDIN_FILENO) == 0,
               let data = try? FileHandle.standardInput.readToEnd(),
               let text = String(data: data, encoding: .utf8) {
                stdinText = text
            }
            exit(Int32(PulseHookReceiver.run(arguments: CommandLine.arguments, stdin: stdinText)))
        }
        if CommandLine.arguments.contains("--harvest-test") {
            let started = Date()
            // Match the menu-bar store: App Data grants live in settings.txt.
            // Ignoring that file made A/B harvest dumps always look process-only.
            let settings = PulseSettings.loadFromDisk()
            let agentsLabel = settings.allowAppData
                ? "all"
                : (settings.appDataAgents.isEmpty
                    ? "none"
                    : settings.appDataAgents.map(\.rawValue).sorted().joined(separator: ","))
            let result = ActivityHarvest.scan(
                allowAppData: settings.allowAppData,
                appDataAgents: settings.appDataAgents
            )
            print(
                "harvest rows=\(result.rows.count) adapters=\(result.health.count) "
                    + "unreliable=\(result.unreliable) "
                    + "complete=\(result.complete) "
                    + "appData=\(settings.allowAppData ? 1 : 0) "
                    + "agents=\(agentsLabel) "
                    + "elapsed=\(String(format: "%.3f", Date().timeIntervalSince(started)))s"
            )
            if CommandLine.arguments.contains("--harvest-dump") {
                for health in result.health.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
                    print("  health \(health.id.rawValue)=\(health.state.rawValue) rows=\(health.rowCount) source=\(health.sourcePresent) duration_ms=\(health.durationMs) error=\(health.errorKind)")
                    if let row = result.rows.first(where: { $0.id == health.id }) {
                        let title = row.task.isEmpty ? "<no title>" : row.task
                        let action = row.tool.isEmpty ? "-" : row.tool
                        print("    sample \(title) · \(row.cwd) · action=\(action) · evidence=\(row.evidence.rawValue)")
                    }
                }
                if CommandLine.arguments.contains("--harvest-dump-all") {
                    for row in result.rows {
                        print("    row \(row.id.rawValue) sid=\(row.sessionID) task=\(row.task) cwd=\(row.cwd) tool=\(row.tool) model=\(row.model) phase=\(row.phase) outcome=\(row.outcome) tokens=\(row.tokensIn)/\(row.tokensOut) files=\(row.files) errors=\(row.errors) context=\(row.contextPercent) progress=\(row.progressDone)/\(row.progressTotal) records=\(row.records) evidence=\(row.evidence.rawValue)")
                    }
                }
            }
            exit(result.unreliable ? 1 : 0)
        }
        if CommandLine.arguments.contains("--native-fixture-test") {
            exit(NativeHarvestSelfTest.run() ? 0 : 1)
        }
        // Donate a sample without donating your work. Prints the *shape* of the
        // newest session records — key names and value kinds, no values — so a
        // parsing bug can be fixed against what the vendor actually writes
        // instead of against a format someone inferred. Opt-in, off by
        // default, and short enough to read before sharing.
        if CommandLine.arguments.contains("--harvest-shape") {
            let settings = PulseSettings.loadFromDisk()
            print(NativeActivityHarvest.shapeReport(
                allowAppData: settings.allowAppData,
                appDataAgents: settings.appDataAgents
            ))
            exit(0)
        }
        // Per-adapter account of the last scan: files, bytes, truncation,
        // facts, which record kind produced the hero, and which layer lost it
        // when there is none.
        if CommandLine.arguments.contains("--harvest-explain") {
            let settings = PulseSettings.loadFromDisk()
            let result = ActivityHarvest.scan(
                allowAppData: settings.allowAppData,
                appDataAgents: settings.appDataAgents
            )
            for health in result.health.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
                print("\(health.id.rawValue) \(health.state.rawValue) \(health.explain.summary)")
            }
            exit(0)
        }
        if Bundle.main.bundleURL.pathExtension == "app" {
            _ = UpdateInstaller.recoverIfNeeded(at: Bundle.main.bundleURL)
        }
        let guardLock = SingleInstanceGuard()
        guard guardLock.acquire() else {
            Task { @MainActor in
                SingleInstanceGuard.activateExistingCopy()
                exit(0)
            }
            RunLoop.main.run()
            return
        }
        instanceGuard = guardLock
        // AppKit-only run loop — no SwiftUI `Settings { EmptyView() }` scene.
        // That scene was a lifecycle anchor and became a blank Settings window
        // on Finder/Spotlight reopen after update (0.56.1 workaround). Real
        // settings stay in SettingsWindowController.
        let app = NSApplication.shared
        let delegate = AppDelegate()
        retainedAppDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// Retained for the process lifetime — NSApplication does not keep a strong
    /// reference to its delegate.
    private static var retainedAppDelegate: AppDelegate?
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Visual QA captures must represent the first completed scan, not the
    /// transient launch state where every adapter is still `unscanned`.
    /// ActivityHarvest has a 6s hard deadline, so 6.8s covers either a
    /// completed scan or its honest timeout result.
    private static let captureDelay: TimeInterval = 6.8

    /// Windows Pulse intentionally owns. Orphan titled windows without these
    /// ids are closed as defense-in-depth (should not appear without a Settings scene).
    private static let ownedWindowIDs: Set<String> = [
        "pulse-settings",
        "pulse-support-coverage",
        "pulse-agent-detail",
        "pulse-tray-preview",
    ]

    private var statusPanel: StatusPanelController?
    private var activationObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Activation policy is also set before run(); keep accessory here so
        // CLI/QA relaunch paths stay consistent.
        NSApp.setActivationPolicy(.accessory)
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            PulseNotify.refreshAuthorization()
            self?.dismissPhantomSettingsWindows()
        }
        if CommandLine.arguments.contains("--appearance=dark") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        } else if CommandLine.arguments.contains("--appearance=light") {
            NSApp.appearance = NSAppearance(named: .aqua)
        }
        if CommandLine.arguments.contains("--language=zh") {
            AppServices.store.language = .zh
        } else if CommandLine.arguments.contains("--language=en") {
            AppServices.store.language = .en
        }
        let panel = StatusPanelController(store: AppServices.store)
        statusPanel = panel
        StatusPanelController.shared = panel
        panel.install()
        if let fixture = CommandLine.arguments.first(where: { $0.hasPrefix("--tray-fixture=") }) {
            AppServices.store.installPreviewFixture(
                String(fixture.dropFirst("--tray-fixture=".count))
            )
        } else {
            AppServices.store.start()
        }
        if CommandLine.arguments.contains("--open-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                AppServices.store.openSettings()
            }
        }
        if let focus = CommandLine.arguments.first(where: { $0.hasPrefix("--open-settings-agent=") }) {
            let raw = String(focus.dropFirst("--open-settings-agent=".count))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                AppServices.store.openSettings(focusAppDataFor: AgentID(rawValue: raw))
            }
        }
        if CommandLine.arguments.contains("--open-support-health") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                AppServices.store.openSupportHealth()
            }
        }
        // This opt-in QA surface hosts the exact TrayPanel view in a normal
        // window so layout and accessibility regressions are testable without
        // Screen Recording or UI automation permissions.
        if CommandLine.arguments.contains("--open-tray-preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                TrayPreviewWindowController.shared.show(store: AppServices.store)
            }
        }
        if CommandLine.arguments.contains("--open-tray-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                StatusPanelController.shared?.show()
            }
        }
        if let capture = CommandLine.arguments.first(where: { $0.hasPrefix("--capture-tray-panel=") }) {
            let path = String(capture.dropFirst("--capture-tray-panel=".count))
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.captureDelay) {
                StatusPanelController.shared?.capture(to: URL(fileURLWithPath: path))
            }
        }
        if let capture = CommandLine.arguments.first(where: { $0.hasPrefix("--capture-status-item=") }) {
            let path = String(capture.dropFirst("--capture-status-item=".count))
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.captureDelay) {
                StatusPanelController.shared?.captureStatusItem(to: URL(fileURLWithPath: path))
            }
        }
        if let capture = CommandLine.arguments.first(where: { $0.hasPrefix("--capture-support-health=") }) {
            let path = String(capture.dropFirst("--capture-support-health=".count))
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.captureDelay) {
                SupportCoverageWindowController.shared.capture(
                    store: AppServices.store,
                    to: URL(fileURLWithPath: path)
                )
            }
        }
        if let capture = CommandLine.arguments.first(where: { $0.hasPrefix("--capture-settings=") }) {
            let path = String(capture.dropFirst("--capture-settings=".count))
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.captureDelay) {
                SettingsWindowController.shared.capture(
                    store: AppServices.store,
                    to: URL(fileURLWithPath: path)
                )
            }
        }
        // Post-update Launch Services reopen can surface the EmptyView Settings
        // scene before we refuse it — sweep once on the next runloop turn.
        DispatchQueue.main.async { [weak self] in
            self?.dismissPhantomSettingsWindows()
        }
    }

    /// Finder / Spotlight reopen must not invent windows. Tray is user-driven.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        dismissPhantomSettingsWindows()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Defense-in-depth: close titled windows that are not Pulse-owned.
    /// After removing the SwiftUI Settings scene this should be a no-op.
    private func dismissPhantomSettingsWindows() {
        for window in NSApp.windows {
            if let id = window.identifier?.rawValue, Self.ownedWindowIDs.contains(id) {
                continue
            }
            if window.styleMask.contains(.borderless) { continue }
            if window.level != .normal { continue }
            guard window.styleMask.contains(.titled) else { continue }
            if window.identifier == nil {
                window.close()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        GlobalHotKey.uninstall()
        statusPanel?.uninstall()
        AppServices.store.markCleanShutdown()
    }
}

// MARK: - Glance

// SwiftUI views only ever run on the main actor, but only `body` is
// implicitly isolated — helper computed properties are not, so calling
// StatusStore's @MainActor methods from them is an error. Annotate the
// whole view rather than sprinkling MainActor.assumeIsolated.
@MainActor
struct MenuBarLabel: View {
    let snapshot: PulseSnapshot
    /// Dips once when a *new* wait arrives, then holds steady.
    ///
    /// This used to breathe forever while anything was waiting. A permanent
    /// animation in the menu bar is noise: it draws the eye every time it
    /// crosses zero, says nothing new after the first second, and — because it
    /// looks identical at 30 seconds and 40 minutes — competes with the one
    /// signal that does carry urgency, the elapsed time beside it.
    @State private var flash = false
    @State private var flashTask: Task<Void, Never>?

    private var waitingCount: Int { snapshot.sectionTotals[.needsYou] ?? 0 }

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: PulseBrand.menuIcon(for: snapshot.glance))
                .resizable()
                .renderingMode(.template)
                .frame(width: 14, height: 14)
                .foregroundStyle(snapshot.glance.lampColor)
                .opacity(flash ? 0.4 : 1.0)
                .accessibilityLabel(snapshot.accessibilityLabel)
            if snapshot.glance != .idle, !snapshot.title.isEmpty {
                Text(snapshot.title)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(snapshot.glance.lampColor)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .help(snapshot.tooltip)
        .onChange(of: waitingCount) { old, new in
            guard new > old else { return }
            flashTask?.cancel()
            flashTask = Task { @MainActor in
                withAnimation(.easeOut(duration: 0.10)) { flash = true }
                try? await Task.sleep(nanoseconds: 110_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.45)) { flash = false }
            }
        }
    }
}
