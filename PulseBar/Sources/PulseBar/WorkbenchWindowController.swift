import AppKit
import SwiftUI

/// 3.0-β Mission Control — the workbench window.
///
/// Nine 2.x releases pushed facts into a 448pt dropdown until the container,
/// not the collection, was the ceiling. The tray stays the glance layer, one
/// pixel unchanged; this window is where "see clearly" lives, and where the
/// verbs (3.0 final) will live. AppKit-hosted for the same LSUIElement
/// reliability reasons as Settings, and it shares SettingsPresenter's
/// activation dance for the same reason.
@MainActor
final class WorkbenchWindowController: NSObject, NSWindowDelegate {
    static let shared = WorkbenchWindowController()

    private var window: NSWindow?
    private var hosting: NSHostingController<WorkbenchView>?
    private(set) var isOpen = false

    func show(store: StatusStore) {
        SettingsPresenter.prepareToOpen()
        if let window, let hosting {
            hosting.rootView = WorkbenchView(store: store)
            window.title = store.tr(.workbenchTitle)
            present(window)
            return
        }
        let host = NSHostingController(rootView: WorkbenchView(store: store))
        let win = NSWindow(contentViewController: host)
        win.title = store.tr(.workbenchTitle)
        win.identifier = NSUserInterfaceItemIdentifier("pulse-workbench")
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.setContentSize(NSSize(width: 980, height: 660))
        win.contentMinSize = NSSize(width: 760, height: 480)
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
