import AppKit
import Combine
import SwiftUI

/// Native status item + a single-surface panel whose bounds exactly match the
/// tray content.
///
/// `MenuBarExtra(.window)` owns a private content container with top and bottom
/// insets outside SwiftUI's root. When the root is transparent those insets
/// appear as bars; when the root paints a material it becomes a second,
/// rectangular surface inside the system popover. An app-owned borderless panel
/// avoids both failure modes: one visual-effect view owns the whole window and
/// the exact same `TrayPanel` is pinned edge to edge inside it.
@MainActor
final class StatusPanelController: NSObject, NSWindowDelegate {
    static weak var shared: StatusPanelController?

    private let store: StatusStore
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel: PulseStatusPanel
    private let rootView = NSView()
    private let shadowView = NSView()
    private let effectView = NSVisualEffectView()
    private let hosting: NSHostingController<TrayPanel>
    private var subscriptions = Set<AnyCancellable>()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastAnnouncedState: String?

    init(store: StatusStore) {
        self.store = store
        hosting = NSHostingController(rootView: TrayPanel(store: store))
        panel = PulseStatusPanel(
            contentRect: .init(
                x: 0,
                y: 0,
                width: 420 + StatusPanelChrome.shadowInset * 2,
                height: 180 + StatusPanelChrome.shadowInset * 2
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
    }

    func install() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePanel)
        button.sendAction(on: [.leftMouseUp])
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.font = .systemFont(ofSize: 11.5, weight: .semibold)

        store.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                self?.updateStatusItem(snapshot)
                self?.scheduleResize()
            }
            .store(in: &subscriptions)
        updateStatusItem(store.snapshot)
    }

    func uninstall() {
        close()
        subscriptions.removeAll()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc private func togglePanel() {
        panel.isVisible ? close() : show()
    }

    func show() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        resizeToFit()
        positionPanel(below: buttonWindow.convertToScreen(button.frame))
        panel.makeKeyAndOrderFront(nil)
        StatusPanelChrome.apply(
            to: panel,
            rootView: rootView,
            shadowView: shadowView,
            effectView: effectView
        )
        installOutsideClickMonitors()
        store.trayDidAppear()
        scheduleResize()
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        removeOutsideClickMonitors()
        store.trayDidDisappear()
    }

    /// Render this process's own panel for visual QA without Screen Recording,
    /// Accessibility, Apple Events, or UI automation permissions.
    func capture(to url: URL) {
        show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            self.resizeToFit()
            // Capture the window root, not only the rounded material child.
            // Capturing only `effectView` hid rectangular frame artefacts from
            // visual QA even though they were visible on the real desktop.
            let surface = self.rootView
            surface.layoutSubtreeIfNeeded()
            let bounds = surface.bounds
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
            self.close()
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

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    private func configurePanel() {
        panel.delegate = self
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // WindowServer's borderless-window shadow remained rectangular even
        // after invalidateShadow(), leaving four light points around a rounded
        // material. A rounded in-window shadow is deterministic and matches
        // the same path as the visible surface.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow

        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active

        shadowView.translatesAutoresizingMaskIntoConstraints = false
        effectView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(shadowView)
        rootView.addSubview(effectView)
        let inset = StatusPanelChrome.shadowInset
        NSLayoutConstraint.activate([
            shadowView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: inset),
            shadowView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -inset),
            shadowView.topAnchor.constraint(equalTo: rootView.topAnchor, constant: inset),
            shadowView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -inset),
            effectView.leadingAnchor.constraint(equalTo: shadowView.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: shadowView.trailingAnchor),
            effectView.topAnchor.constraint(equalTo: shadowView.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: shadowView.bottomAnchor),
        ])

        let content = hosting.view
        content.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            content.topAnchor.constraint(equalTo: effectView.topAnchor),
            content.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
        ])
        panel.contentView = rootView
        StatusPanelChrome.apply(
            to: panel,
            rootView: rootView,
            shadowView: shadowView,
            effectView: effectView
        )
    }

    private func updateStatusItem(_ snapshot: PulseSnapshot) {
        guard let button = statusItem.button else { return }
        let image = PulseBrand.statusBarIcon(for: snapshot.glance)
        image.size = NSSize(width: 15, height: 15)
        button.image = image
        // A status button's effective appearance belongs to the menu bar, not
        // necessarily to the app's Aqua/Dark Aqua appearance. A forced
        // The image owns its state colour. `contentTintColor` stays nil so
        // AppKit keeps the adjacent title readable against the actual menu bar
        // appearance instead of tinting both icon and text together.
        button.contentTintColor = nil
        button.title = snapshot.glance == .idle ? "" : snapshot.title
        button.toolTip = snapshot.tooltip
        button.setAccessibilityLabel(snapshot.accessibilityLabel)

        let state = TraySection.allCases
            .map { "\(String(describing: $0))=\(snapshot.sectionTotals[$0] ?? 0)" }
            .joined(separator: ",")
        // The empty bootstrap snapshot is not a state transition. Seed from
        // the first completed scan so launching Pulse does not speak an
        // unsolicited "Running" announcement.
        if snapshot.updatedAt != .distantPast {
            if let previous = lastAnnouncedState, previous != state {
                NSAccessibility.post(
                    element: button,
                    notification: .announcementRequested,
                    userInfo: [
                        .announcement: snapshot.headerTitle,
                        .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                    ]
                )
            }
            lastAnnouncedState = state
        }
    }

    private func scheduleResize() {
        guard panel.isVisible else { return }
        DispatchQueue.main.async { [weak self] in self?.resizeToFit() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.resizeToFit()
        }
    }

    private func resizeToFit() {
        hosting.view.layoutSubtreeIfNeeded()
        let fitting = hosting.view.fittingSize
        // Keep the default seven-row glance intact. The list itself remains
        // scrollable, but a panel that ends halfway through a row reads as a
        // layout failure rather than an intentional viewport.
        // Keep the default information-rich glance intact. The SwiftUI list
        // already scrolls when there are many sessions, but capping the host
        // at 720pt clipped the final row in the common seven-row case.
        let height = min(780, max(96, fitting.height))
        let inset = StatusPanelChrome.shadowInset
        let target = NSSize(
            width: max(420, fitting.width) + inset * 2,
            height: height + inset * 2
        )
        guard abs(panel.frame.width - target.width) > 0.5
                || abs(panel.frame.height - target.height) > 0.5 else { return }

        let oldTop = panel.frame.maxY
        panel.setContentSize(target)
        var frame = panel.frame
        frame.origin.y = oldTop - frame.height
        panel.setFrame(frame, display: true)
        rootView.layoutSubtreeIfNeeded()
        StatusPanelChrome.apply(
            to: panel,
            rootView: rootView,
            shadowView: shadowView,
            effectView: effectView
        )
    }

    private func positionPanel(below anchor: NSRect) {
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        var origin = NSPoint(
            x: anchor.midX - panel.frame.width / 2,
            y: anchor.minY - panel.frame.height - 6 + StatusPanelChrome.shadowInset
        )
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - panel.frame.width - 8)
        origin.y = max(origin.y, visible.minY + 8)
        panel.setFrameOrigin(origin)
    }

    private func installOutsideClickMonitors() {
        removeOutsideClickMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.close()
                return nil
            }
            if event.window !== self.panel,
               event.type == .leftMouseDown || event.type == .rightMouseDown {
                self.close()
            }
            return event
        }
    }

    private func removeOutsideClickMonitors() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }
}

private final class PulseStatusPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// One owner for the panel's visible shape.
///
/// The material child was rounded in 0.36.0, but the AppKit frame view and its
/// cached WindowServer shadow still described a rectangle. On a light desktop
/// the clipped material exposed four white triangular corners. Disable that
/// outer shadow and draw a bounded rounded shadow behind the material using
/// the exact same path.
@MainActor
enum StatusPanelChrome {
    static let cornerRadius: CGFloat = 12
    static let shadowInset: CGFloat = 12

    static func apply(
        to panel: NSPanel,
        rootView: NSView,
        shadowView: NSView,
        effectView: NSVisualEffectView
    ) {
        panel.hasShadow = false
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor
        rootView.layer?.masksToBounds = false

        shadowView.wantsLayer = true
        shadowView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.01).cgColor
        shadowView.layer?.cornerRadius = cornerRadius
        shadowView.layer?.cornerCurve = .continuous
        shadowView.layer?.masksToBounds = false
        shadowView.layer?.shadowColor = NSColor.black.cgColor
        shadowView.layer?.shadowOpacity = 0.24
        shadowView.layer?.shadowRadius = 10
        shadowView.layer?.shadowOffset = CGSize(width: 0, height: -3)
        shadowView.layer?.shadowPath = CGPath(
            roundedRect: shadowView.bounds,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )

        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = cornerRadius
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.masksToBounds = true

        if let frameView = rootView.superview {
            frameView.wantsLayer = true
            frameView.layer?.backgroundColor = NSColor.clear.cgColor
            frameView.layer?.masksToBounds = false
        }
    }
}
