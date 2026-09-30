import AppKit
import SwiftUI

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
        SettingsPresenter.prepareToOpen()

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
        // One page of short groups (EXPERIENCE.md §6).
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
        NSApp.activate(ignoringOtherApps: true)
        // Escalate activation only if the window didn't become key (slow path).
        DispatchQueue.main.async {
            if !window.isKeyWindow {
                SettingsPresenter.ensureKeyableIfNeeded()
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        isOpen = false
        SettingsPresenter.restoreAccessoryIfNeeded()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        isOpen = true
    }
}
