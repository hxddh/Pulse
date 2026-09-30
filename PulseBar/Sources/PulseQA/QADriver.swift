import AppKit
import SwiftUI
@testable import PulseApp

// PulseQA — the product's QA driver, never linked into the shipping app.
//
// It runs the real app (`PulseBarMain.main`) and, once the status item is
// installed, takes the launch over as the command line asks:
//
//   --capture-surfaces=<dir>    render every surface fixture to PNGs, then quit
//   --tray-fixture=<name>       a fixed world instead of this Mac's sessions
//   --open-settings             open Settings
//   --open-tray-preview         host the tray in a normal window
//   --open-tray-panel           open the tray panel
//   --capture-tray-panel=<png>  photograph the tray panel
//   --capture-status-item=<png> photograph the menu-bar item
//   --capture-settings=<png>    photograph Settings
//
//   --language=zh|en            this run's language (never saved)
//   --appearance=light|dark     this run's appearance
//
// Built in the debug configuration only: it reaches the app's internals
// through `@testable import`. The shipping app reads none of these flags
// (`scripts/package_check.py` fails a binary that carries one).
@main
enum PulseQAMain {
    @MainActor
    static func main() {
        QADriver.prepare(ProcessInfo.processInfo.arguments)
        PulseBarMain.main(launchHook: QADriver.launch)
    }
}

@MainActor
enum QADriver {
    /// Captures must show the first landed reads (the event log replay,
    /// the process table), not the launch state.
    static let captureDelay: TimeInterval = 3

    static func value(_ flag: String, in arguments: [String]) -> String? {
        arguments.first(where: { $0.hasPrefix(flag) }).map { String($0.dropFirst(flag.count)) }
    }

    /// Before the app launches: the language (read once, as the tray and
    /// the menu are built) and the appearance.
    static func prepare(_ arguments: [String]) {
        switch value("--language=", in: arguments) {
        case "zh": AppServices.store.languageOverride = .zh
        case "en": AppServices.store.languageOverride = .en
        default: break
        }
        switch value("--appearance=", in: arguments) {
        case "dark": NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }

    /// Returns true when a fixture replaced this Mac's sessions (the live
    /// start is skipped).
    static func launch() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        let store = AppServices.store
        // Render the surface fixtures and quit — no scan, nothing read from
        // this Mac.
        if let directory = SurfaceCapture.requestedDirectory(arguments) {
            SurfaceCapture.run(
                to: directory,
                lang: store.lang,
                dark: arguments.contains("--appearance=dark")
            )
            NSApp.terminate(nil)
            return true
        }
        var fixture = false
        if let name = value("--tray-fixture=", in: arguments) {
            store.installPreviewFixture(name)
            fixture = true
        }
        if arguments.contains("--open-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                AppServices.store.openSettings()
            }
        }
        // Hosts the exact TrayPanel view in a normal window so layout and
        // accessibility regressions are testable without Screen Recording or
        // UI automation permissions.
        if arguments.contains("--open-tray-preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                TrayPreviewWindowController.shared.show(store: AppServices.store)
            }
        }
        if arguments.contains("--open-tray-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                StatusPanelController.shared?.show()
            }
        }
        if let path = value("--capture-tray-panel=", in: arguments) {
            DispatchQueue.main.asyncAfter(deadline: .now() + captureDelay) {
                StatusPanelController.shared?.capture(to: URL(fileURLWithPath: path))
            }
        }
        if let path = value("--capture-status-item=", in: arguments) {
            DispatchQueue.main.asyncAfter(deadline: .now() + captureDelay) {
                StatusPanelController.shared?.captureStatusItem(to: URL(fileURLWithPath: path))
            }
        }
        if let path = value("--capture-settings=", in: arguments) {
            DispatchQueue.main.asyncAfter(deadline: .now() + captureDelay) {
                SettingsWindowController.shared.capture(store: AppServices.store, to: URL(fileURLWithPath: path))
            }
        }
        return fixture
    }
}

extension StatusPanelController {
    /// Render this process's own panel for visual QA without Screen Recording,
    /// Accessibility, Apple Events, or UI automation permissions.
    func capture(to url: URL) {
        captureInProgress = true
        // `--open-tray-panel` is commonly paired with capture. Calling
        // `show()` again in that case resizes an already-visible SwiftUI host
        // while AppKit is in its display cycle — the exact macOS 26 path that
        // raises `_postWindowNeedsUpdateConstraints`. Reuse the settled panel
        // instead of starting a second layout transaction.
        if panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
        } else {
            show()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
            guard let self else { return }
            defer {
                self.captureInProgress = false
                self.close()
            }
            // Capture the window root, not only the rounded material child.
            // Capturing only `effectView` hid rectangular frame artefacts from
            // visual QA even though they were visible on the real desktop.
            let surface = self.rootView
            // `show()` has already sized and laid out the panel. A display pass
            // is enough to flush the layer tree without asking SwiftUI to
            // invalidate its constraints recursively during the snapshot.
            surface.displayIfNeeded()
            let bounds = surface.bounds
            guard bounds.width > 0, bounds.height > 0 else {
                DebugLog.write("tray capture failed — empty surface")
                return
            }
            guard let bitmap = surface.bitmapImageRepForCachingDisplay(in: bounds) else {
                DebugLog.write("tray capture failed — no bitmap")
                return
            }
            surface.cacheDisplay(in: bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                DebugLog.write("tray capture failed — no PNG representation")
                return
            }
            do {
                try data.write(to: url, options: .atomic)
                DebugLog.write("tray capture wrote \(url.path)")
            } catch {
                DebugLog.write("tray capture failed \(error.localizedDescription)")
            }
        }
    }

    /// Capture only this app's status-bar button for appearance QA.
    ///
    /// `cacheDisplay` renders a view owned by this process, so this proves the
    /// actual `NSStatusBarButton` presentation without Screen Recording,
    /// Accessibility, Apple Events, or UI automation permissions.
    func captureStatusItem(to url: URL) {
        guard let button = statusItem.button else {
            DebugLog.write("status item capture failed — no button")
            return
        }
        button.layoutSubtreeIfNeeded()
        let bounds = button.bounds
        guard bounds.width > 0, bounds.height > 0,
              let bitmap = button.bitmapImageRepForCachingDisplay(in: bounds) else {
            DebugLog.write("status item capture failed — no bitmap")
            return
        }
        button.cacheDisplay(in: bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            DebugLog.write("status item capture failed — no PNG representation")
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            DebugLog.write(
                "status item capture wrote \(url.path) "
                    + "appearance=\(button.effectiveAppearance.name.rawValue)"
            )
        } catch {
            DebugLog.write("status item capture failed \(error.localizedDescription)")
        }
    }
}

extension SettingsWindowController {
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
}
