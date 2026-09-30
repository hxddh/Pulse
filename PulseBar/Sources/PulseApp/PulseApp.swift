import SwiftUI
import AppKit
import Darwin

enum AppServices {
    @MainActor static let store = StatusStore()
}

/// A QA driver's hook into the launch (`PulseQA`): it runs once the status
/// item is installed, before the live start, and returns true when it took
/// the launch over (a fixture, a capture) so the live start is skipped. The
/// shipping app passes none.
package typealias PulseLaunchHook = @MainActor () -> Bool

/// The app's entry: `PulseBar` (the product) and `PulseQA` both call `main`.
/// Explicit so `--selftest` and `--hook` answer before AppKit starts —
/// `App.main()` connects to the WindowServer, which a CI runner may not have.
package enum PulseBarMain {
    nonisolated(unsafe) private static var instanceGuard: SingleInstanceGuard?

    @MainActor
    package static func main(launchHook: PulseLaunchHook? = nil) {
        if ProcessInfo.processInfo.arguments.contains("--selftest") {
            exit(PulseSelfTest.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.arguments.contains("--hook") {
            // Every supported agent's hook lands here. Always exit 0 so a
            // vendor hook never blocks the agent process.
            let arguments = ProcessInfo.processInfo.arguments
            var stdinText = ""
            // Vendors pipe JSON on stdin. Never read when attached to a TTY,
            // nor when the payload came in argv (the two modules); otherwise
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
        // AppKit-only run loop — no SwiftUI scene, so a Finder or Spotlight
        // reopen has no window to invent. Settings is
        // SettingsWindowController.
        let app = NSApplication.shared
        let delegate = AppDelegate()
        delegate.launchHook = launchHook
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
    /// `PulseQA`'s driver, when it launched the app; nil in the product.
    var launchHook: PulseLaunchHook?
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
        ) { _ in
            PulseNotify.refreshAuthorization()
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
        let panel = StatusPanelController(store: AppServices.store)
        statusPanel = panel
        StatusPanelController.shared = panel
        panel.install()
        if let launchHook, launchHook() {
            // QA took the launch over: a fixture, not this Mac's sessions.
        } else {
            AppServices.store.start()
        }
    }

    /// Finder / Spotlight reopen must not invent windows. Tray is user-driven.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        GlobalHotKey.uninstall()
        statusPanel?.uninstall()
    }
}

