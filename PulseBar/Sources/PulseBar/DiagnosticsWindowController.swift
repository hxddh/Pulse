import AppKit
import SwiftUI

/// 23.0 · Diagnostics (it was "Health"): what stops Pulse from seeing, the
/// self-check, every agent on one line, and the activity log — an
/// operational surface, not a preference, so it has its own window and
/// Settings stays a short set of choices.
@MainActor
final class DiagnosticsWindowController: NSObject, NSWindowDelegate {
    static let shared = DiagnosticsWindowController()

    private var window: NSWindow?
    private var hosting: NSHostingController<DiagnosticsView>?

    func show(store: StatusStore) {
        SettingsPresenter.prepareToOpen()
        if let window, let hosting {
            hosting.rootView = DiagnosticsView(store: store)
            window.title = store.tr(.diagnosticsTitle)
            present(window)
            return
        }

        let host = NSHostingController(rootView: DiagnosticsView(store: store))
        let win = NSWindow(contentViewController: host)
        win.title = store.tr(.diagnosticsTitle)
        win.identifier = NSUserInterfaceItemIdentifier("pulse-diagnostics")
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // One line per agent: a calm canvas, the list scrolls.
        win.setContentSize(NSSize(width: 620, height: 600))
        win.contentMinSize = NSSize(width: 520, height: 360)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        hosting = host
        window = win
        present(win)
    }

    func capture(store: StatusStore, to url: URL) {
        show(store: store)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, let view = self.window?.contentView else { return }
            view.layoutSubtreeIfNeeded()
            let bounds = view.bounds
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
            view.cacheDisplay(in: bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
            do {
                try data.write(to: url, options: .atomic)
                DebugLog.write("diagnostics capture wrote \(url.path)")
            } catch {
                DebugLog.write("diagnostics capture failed \(error.localizedDescription)")
            }
        }
    }

    private func present(_ window: NSWindow) {
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        SettingsPresenter.restoreAccessoryIfNeeded()
    }
}
