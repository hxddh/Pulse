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
//   --open-tray                 open the tray (the status item's popover)
//   --capture-tray=<png>        photograph the tray
//   --capture-status-item=<png> photograph the menu-bar item
//   --capture-settings=<png>    photograph Settings
//
//   --appearance=light|dark     this run's appearance
//
// The language is the system's, as in the app; a run picks one the macOS
// way, with `-AppleLanguages "(zh-Hans)"` (`scripts/qa_captures.sh`).
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

    /// Before the app launches: the appearance.
    static func prepare(_ arguments: [String]) {
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
        // Hosts the exact tray view in a normal window so layout and
        // accessibility regressions are testable without Screen Recording or
        // UI automation permissions.
        if arguments.contains("--open-tray-preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                TrayPreviewWindowController.shared.show(store: AppServices.store)
            }
        }
        if arguments.contains("--open-tray") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                StatusItemController.shared?.show()
            }
        }
        if let path = value("--capture-tray=", in: arguments) {
            DispatchQueue.main.asyncAfter(deadline: .now() + captureDelay) {
                QADriver.captureTray(to: URL(fileURLWithPath: path))
            }
        }
        if let path = value("--capture-status-item=", in: arguments) {
            DispatchQueue.main.asyncAfter(deadline: .now() + captureDelay) {
                StatusItemController.shared?.captureStatusItem(to: URL(fileURLWithPath: path))
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

extension QADriver {
    /// Photograph the tray — the same SwiftUI root the popover hosts, on a
    /// fresh glance, drawn offscreen like every surface fixture
    /// (`SurfaceCapture.render`), so no Screen Recording, Accessibility or
    /// automation permission is asked. The popover's own material and arrow
    /// are the system's and are not in the picture.
    static func captureTray(to url: URL) {
        let store = AppServices.store
        let ui = TrayUI(store: store)
        ui.open()
        let view = AnyView(TrayView(store: store, ui: ui))
        let width = Double(TrayChrome.width)
        // The first pass measures the list (`TrayUI.listHeight` keeps it);
        // the second is drawn at that height.
        _ = SurfaceCapture.render(view, width: width, appearance: NSApp.effectiveAppearance)
        guard let image = SurfaceCapture.render(view, width: width, appearance: NSApp.effectiveAppearance),
              SurfaceCapture.write(image, to: url) else {
            DebugLog.write("tray capture failed")
            return
        }
        DebugLog.write("tray capture wrote \(url.path)")
    }
}

extension StatusItemController {
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
