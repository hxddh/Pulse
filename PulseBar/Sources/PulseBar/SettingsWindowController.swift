import AppKit
import SwiftUI

/// AppKit-hosted settings window — reliable for LSUIElement / accessory apps.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var hosting: NSHostingController<SettingsView>?
    private(set) var isOpen = false

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
        // Spec width band is 420–460 (EXPERIENCE.md §5); the form grew a
        // notifications and a shortcuts section in 0.22.
        win.setContentSize(NSSize(width: 440, height: 560))
        win.contentMinSize = NSSize(width: 420, height: 420)
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
                DebugLog.write("settings capture wrote \(url.path)")
            } catch {
                DebugLog.write("settings capture failed \(error.localizedDescription)")
            }
        }
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
