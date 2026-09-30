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
    /// A second copy's "open the tray" (`SingleInstanceGuard`).
    private var reopenObserver: NSObjectProtocol?

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
            MainActor.assumeIsolated { AppServices.store.refreshLoginItem() }
        }
        reopenObserver = DistributedNotificationCenter.default().addObserver(
            forName: SingleInstanceGuard.reopenNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { AppServices.store.reopen() }
        }
        // Never shown by an accessory app; it routes the standard key
        // equivalents — ⌘W closes Settings, ⌘C / ⌘A work on selectable text.
        MainMenu.install(lang: AppServices.store.lang)
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

    /// Finder / Spotlight opening Pulse again: the person wants to see it,
    /// so the tray opens (`StatusStore.reopen`). No window is invented —
    /// false tells AppKit not to do its own reopen.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        AppServices.store.reopen()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        if let reopenObserver {
            DistributedNotificationCenter.default().removeObserver(reopenObserver)
            self.reopenObserver = nil
        }
        GlobalHotKey.uninstall()
        statusPanel?.uninstall()
    }
}


/// The app's main menu. An accessory app never shows it (it does while
/// Settings is open, when Pulse is briefly a regular app); either way it
/// routes the standard key equivalents to the key window: ⌘W closes
/// Settings, ⌘C / ⌘A / ⌘Z work on selectable and editable text, ⌘, opens
/// Settings, ⌘Q quits. Items that act on text or windows go to the first
/// responder (a nil target).
@MainActor
enum MainMenu {
    static func install(lang: ResolvedLanguage) {
        NSApp?.mainMenu = make(lang: lang)
    }

    static func make(lang: ResolvedLanguage) -> NSMenu {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        func item(
            _ title: String, _ action: Selector?, _ key: String,
            _ modifiers: NSEvent.ModifierFlags = .command
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        let main = NSMenu()

        let app = NSMenu(title: "Pulse")
        let about = item(t(.menuAbout), #selector(MainMenuActions.about(_:)), "")
        let settings = item(t(.settings), #selector(MainMenuActions.settings(_:)), ",")
        let quit = item(t(.quit), #selector(MainMenuActions.quit(_:)), "q")
        for own in [about, settings, quit] { own.target = MainMenuActions.shared }
        app.addItem(about)
        app.addItem(.separator())
        app.addItem(settings)
        app.addItem(.separator())
        app.addItem(quit)

        let edit = NSMenu(title: t(.menuEdit))
        edit.addItem(item(t(.menuUndo), Selector(("undo:")), "z"))
        edit.addItem(item(t(.menuRedo), Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item(t(.menuCut), #selector(NSText.cut(_:)), "x"))
        edit.addItem(item(t(.menuCopy), #selector(NSText.copy(_:)), "c"))
        edit.addItem(item(t(.menuPaste), #selector(NSText.paste(_:)), "v"))
        edit.addItem(item(t(.menuSelectAll), #selector(NSText.selectAll(_:)), "a"))

        let window = NSMenu(title: t(.menuWindow))
        window.addItem(item(t(.menuClose), #selector(NSWindow.performClose(_:)), "w"))
        window.addItem(item(t(.menuMinimize), #selector(NSWindow.performMiniaturize(_:)), "m"))

        for (title, submenu) in [("Pulse", app), (t(.menuEdit), edit), (t(.menuWindow), window)] {
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = submenu
            main.addItem(holder)
        }
        return main
    }
}

/// The main menu's own items: About, Settings, Quit.
@MainActor
final class MainMenuActions: NSObject {
    static let shared = MainMenuActions()

    @objc func about(_ sender: Any?) {
        NSApp?.activate(ignoringOtherApps: true)
        NSApp?.orderFrontStandardAboutPanel(sender)
    }

    @objc func settings(_ sender: Any?) {
        AppServices.store.openSettings()
    }

    @objc func quit(_ sender: Any?) {
        AppServices.store.quit()
    }
}
