import AppKit
import SwiftUI

/// Runtime adapter evidence is an operational surface, not a preference.
/// Keep it in its own searchable window so Settings remains a short set of
/// choices and 32 adapters can be inspected without disclosure gymnastics.
@MainActor
final class SupportCoverageWindowController: NSObject, NSWindowDelegate {
    static let shared = SupportCoverageWindowController()

    private var window: NSWindow?
    private var hosting: NSHostingController<SupportCoverageView>?

    func show(store: StatusStore) {
        SettingsPresenter.prepareToOpen()
        if let window, let hosting {
            hosting.rootView = SupportCoverageView(store: store)
            window.title = store.tr(.supportHealth)
            present(window)
            return
        }

        let host = NSHostingController(rootView: SupportCoverageView(store: store))
        let win = NSWindow(contentViewController: host)
        win.title = store.tr(.supportHealth)
        win.identifier = NSUserInterfaceItemIdentifier("pulse-support-coverage")
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.setContentSize(NSSize(width: 640, height: 460))
        win.contentMinSize = NSSize(width: 580, height: 360)
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
                DebugLog.write("support capture wrote \(url.path)")
            } catch {
                DebugLog.write("support capture failed \(error.localizedDescription)")
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
