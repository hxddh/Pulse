import AppKit
import SwiftUI
@testable import PulseApp

/// Opt-in visual QA host for the tray content.
///
/// It is reachable only through `--open-tray-preview`; no production control
/// links to it. The actual `TrayView` is hosted unchanged so screenshot tests
/// inspect the shipped view rather than a hand-maintained mock.
@MainActor
final class TrayPreviewWindowController: NSObject, NSWindowDelegate {
    static let shared = TrayPreviewWindowController()

    private var window: NSWindow?
    private var hosting: NSHostingController<TrayView>?
    private weak var store: StatusStore?
    private var ui: TrayUI?

    func show(store: StatusStore) {
        self.store = store
        let ui = self.ui ?? TrayUI(store: store)
        self.ui = ui
        ui.open()
        if let window, let hosting {
            hosting.rootView = TrayView(store: store, ui: ui)
            present(window)
            store.trayDidAppear()
            return
        }

        let host = NSHostingController(rootView: TrayView(store: store, ui: ui))
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
        store.trayDidAppear()
    }

    func windowWillClose(_ notification: Notification) {
        store?.trayDidDisappear()
    }

    private func present(_ window: NSWindow) {
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }
}
