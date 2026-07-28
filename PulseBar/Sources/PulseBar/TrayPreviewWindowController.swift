import AppKit
import SwiftUI

/// Opt-in visual QA host for the MenuBarExtra content.
///
/// It is reachable only through `--open-tray-preview`; no production control
/// links to it. The actual `TrayPanel` is hosted unchanged so screenshot tests
/// inspect the shipped view rather than a hand-maintained mock.
@MainActor
final class TrayPreviewWindowController: NSObject, NSWindowDelegate {
    static let shared = TrayPreviewWindowController()

    private var window: NSWindow?
    private var hosting: NSHostingController<TrayPanel>?

    func show(store: StatusStore) {
        if let window, let hosting {
            hosting.rootView = TrayPanel(store: store)
            present(window)
            return
        }

        let host = NSHostingController(rootView: TrayPanel(store: store))
        host.sizingOptions = [.intrinsicContentSize]
        let win = NSWindow(contentViewController: host)
        win.title = "Pulse Tray Preview"
        win.identifier = NSUserInterfaceItemIdentifier("pulse-tray-preview")
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        hosting = host
        window = win

        host.view.layoutSubtreeIfNeeded()
        let fitting = host.view.fittingSize
        win.setContentSize(NSSize(
            width: max(400, fitting.width),
            height: min(620, max(180, fitting.height))
        ))
        present(win)
    }

    private func present(_ window: NSWindow) {
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }
}
