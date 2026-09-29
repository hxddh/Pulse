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
    nonisolated(unsafe) private static var instanceGuard: SingleInstanceGuard?

    static func main() {
        if ProcessInfo.processInfo.arguments.contains("--selftest") {
            exit(PulseSelfTest.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.arguments.contains("--hook") {
            // Every supported agent's hook lands here. Always exit 0 so a
            // vendor hook never blocks the agent process.
            let arguments = ProcessInfo.processInfo.arguments
            var stdinText = ""
            // Vendors pipe JSON on stdin. Never read when attached to a TTY,
            // nor when the payload came in argv (Codex `notify`); otherwise
            // read for at most a second — a pipe nobody closes must not hold
            // the agent that is waiting on this hook.
            if isatty(STDIN_FILENO) == 0, !PulseHookReceiver.payloadInArguments(arguments) {
                stdinText = PulseHookReceiver.readStdin()
            }
            exit(Int32(PulseHookReceiver.run(arguments: arguments, stdin: stdinText)))
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
    nonisolated(unsafe) private static var retainedAppDelegate: AppDelegate?
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Visual QA captures must represent the first landed reads (the
    /// attention file, the spool, the process table), not the launch state.
    private static let captureDelay: TimeInterval = 3

    /// Windows Pulse intentionally owns. Orphan titled windows without these
    /// ids are closed as defense-in-depth (should not appear without a Settings scene).
    private static let ownedWindowIDs: Set<String> = [
        "pulse-settings",
        "pulse-diagnostics",
        "pulse-tray-preview",
    ]

    private var statusPanel: StatusPanelController?
    private var activationObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Activation policy is also set before run(); keep accessory here so
        // CLI/QA relaunch paths stay consistent.
        NSApp.setActivationPolicy(.accessory)
        // The delegate lives for the whole process (`retainedAppDelegate`),
        // and the block runs on the main queue.
        let delegate = Unchecked(self)
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { _ in
            PulseNotify.refreshAuthorization()
            delegate.value.dismissPhantomSettingsWindows()
        }
        if ProcessInfo.processInfo.arguments.contains("--appearance=dark") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        } else if ProcessInfo.processInfo.arguments.contains("--appearance=light") {
            NSApp.appearance = NSAppearance(named: .aqua)
        }
        // Wins over settings.json for this run, and is never saved.
        if ProcessInfo.processInfo.arguments.contains("--language=zh") {
            AppServices.store.languageOverride = .zh
        } else if ProcessInfo.processInfo.arguments.contains("--language=en") {
            AppServices.store.languageOverride = .en
        }
        // 15.0 · Witness: render the surface fixtures and quit — no scan,
        // no tray, nothing read from this Mac.
        if let directory = SurfaceCapture.requestedDirectory(ProcessInfo.processInfo.arguments) {
            SurfaceCapture.run(
                to: directory,
                lang: AppServices.store.lang,
                dark: ProcessInfo.processInfo.arguments.contains("--appearance=dark")
            )
            NSApp.terminate(nil)
            return
        }
        let panel = StatusPanelController(store: AppServices.store)
        statusPanel = panel
        StatusPanelController.shared = panel
        panel.install()
        if let fixture = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--tray-fixture=") }) {
            AppServices.store.installPreviewFixture(
                String(fixture.dropFirst("--tray-fixture=".count))
            )
        } else {
            AppServices.store.start()
        }
        if ProcessInfo.processInfo.arguments.contains("--open-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                AppServices.store.openSettings()
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--open-support-health") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                AppServices.store.openDiagnostics()
            }
        }
        // This opt-in QA surface hosts the exact TrayPanel view in a normal
        // window so layout and accessibility regressions are testable without
        // Screen Recording or UI automation permissions.
        if ProcessInfo.processInfo.arguments.contains("--open-tray-preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                TrayPreviewWindowController.shared.show(store: AppServices.store)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--open-tray-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                StatusPanelController.shared?.show()
            }
        }
        if let capture = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--capture-tray-panel=") }) {
            let path = String(capture.dropFirst("--capture-tray-panel=".count))
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.captureDelay) {
                StatusPanelController.shared?.capture(to: URL(fileURLWithPath: path))
            }
        }
        if let capture = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--capture-status-item=") }) {
            let path = String(capture.dropFirst("--capture-status-item=".count))
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.captureDelay) {
                StatusPanelController.shared?.captureStatusItem(to: URL(fileURLWithPath: path))
            }
        }
        if let capture = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--capture-support-health=") }) {
            let path = String(capture.dropFirst("--capture-support-health=".count))
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.captureDelay) {
                DiagnosticsWindowController.shared.capture(
                    store: AppServices.store,
                    to: URL(fileURLWithPath: path)
                )
            }
        }
        if let capture = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--capture-settings=") }) {
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
        // AppKit window callbacks run on the main thread.
        MainActor.assumeIsolated {
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        GlobalHotKey.uninstall()
        statusPanel?.uninstall()
        // The log goes down now — a debounced change still in memory, and
        // the quit time the next launch closes open spans at.
        AppServices.store.sessionLogStore.flushAtQuit(AppServices.store.sessionLog)
    }
}

