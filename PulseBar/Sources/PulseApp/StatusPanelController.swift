import AppKit
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
    /// Internal, not private: `PulseQA` photographs the status item and the
    /// panel's root (`capture(to:)`, `captureStatusItem(to:)`).
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let panel: NSPanel
    let rootView = NSView()
    private let shadowView = NSView()
    /// The panel's surface: Liquid Glass on macOS 26, the menu material
    /// before it. One view either way, so chrome and capture treat it alike.
    private let effectView: NSView
    /// One lamp image per shape and tone. Each draws itself (a drawing
    /// handler), so it follows the menu bar's appearance on its own.
    private var iconCache: [String: NSImage] = [:]
    private var lastIconKey = ""
    private let hosting: NSHostingController<TrayPanelHost>
    /// The tray's per-open state — keys, frozen order, height budget.
    let ui: TrayUI
    /// Follows only `snapshot` — a settings write does not touch the lamp.
    private var snapshotLoop: ObservationLoop?
    /// Follows the tray's own state (the selection, the detail page), the
    /// tray notice and the row notices to re-fit the panel.
    private var uiLoop: ObservationLoop?
    /// What the last fit measured, so only a change in the number of rows
    /// animates the frame (EXPERIENCE §4: nothing moves on a plain scan).
    private var lastFitRowCount = -1
    private var lastFitDetail: String?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    /// The blocked count VoiceOver last knew; nil until the first scan.
    private var lastAnnouncedBlocked: Int?
    /// One-shot status-lamp pulse for a newly observed Waiting edge. The red
    /// colour remains steady until the wait is resolved; only the transition
    /// gets motion, so the menu bar can remind without becoming a permanent
    /// animation or requiring notification permission.
    private var lampAttentionTask: Task<Void, Never>?
    private var lastWaitingCount: Int?
    /// The QA renderer (`PulseQA`) owns the same panel as the user. Suspend
    /// resize callbacks while it snapshots the view; AppKit can otherwise
    /// invalidate SwiftUI safe-area constraints in the middle of
    /// `cacheDisplay` and terminate the process with an exception.
    var captureInProgress = false

    init(store: StatusStore) {
        self.store = store
        let ui = TrayUI(store: store)
        self.ui = ui
        hosting = NSHostingController(rootView: TrayPanelHost(store: store, ui: ui))
        effectView = StatusPanelChrome.makeSurface()
        panel = PulseStatusPanel(
            contentRect: .init(
                x: 0,
                y: 0,
                width: TrayChrome.width + StatusPanelChrome.shadowInset * 2,
                height: 180 + StatusPanelChrome.shadowInset * 2
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        ui.onClose = { [weak self] in self?.close() }
        configurePanel()
    }

    func install() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemPressed)
        // On mouse-down, like the system's own menu-bar items: the tray is
        // open by the time the button is let go.
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        button.imagePosition = .imageLeading
        // The lamp is drawn at its own size; never scaled into a blur.
        button.imageScaling = .scaleNone
        // The menu bar's own font, with digits that do not change width as
        // "4m" becomes "5m" — the title no longer nudges its neighbours.
        button.font = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.menuBarFont(ofSize: 0).pointSize,
            weight: .medium
        )

        let store = self.store
        snapshotLoop = ObservationLoop(track: { _ = store.snapshot }) { [weak self] in
            guard let self else { return }
            self.updateStatusItem(self.store.snapshot)
            if self.panel.isVisible { self.ui.absorbScan() }
            self.scheduleResize()
        }
        let ui = self.ui
        // The tray's own state, and the lines that come and go above and
        // under the rows — the one notice, a row's brief action notice, the
        // rows pinned while open — all change the panel's height.
        uiLoop = ObservationLoop(track: {
            _ = ui.keys
            _ = ui.pinned
            _ = store.trayNotice
            _ = store.rowActionNotices
        }) { [weak self] in
            self?.scheduleResize()
        }
        updateStatusItem(store.snapshot)
    }

    func uninstall() {
        close()
        lampAttentionTask?.cancel()
        lampAttentionTask = nil
        snapshotLoop?.cancel()
        snapshotLoop = nil
        uiLoop?.cancel()
        uiLoop = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc private func togglePanel() {
        panel.isVisible ? close() : show()
    }

    /// A left click toggles the tray; a right click (or Control-click)
    /// shows the status item's menu.
    @objc private func statusItemPressed() {
        let event = NSApp?.currentEvent
        let secondary = event?.type == .rightMouseDown
            || (event?.type == .leftMouseDown && event?.modifierFlags.contains(.control) == true)
        if secondary {
            showStatusMenu()
        } else {
            togglePanel()
        }
    }

    /// Open Pulse · Settings… · Quit Pulse — shown the system way: the
    /// menu is the status item's for exactly one click.
    private func showStatusMenu() {
        close()
        let lang = store.lang
        let menu = NSMenu()
        let open = NSMenuItem(title: L10n.t(.menuOpenPulse, lang), action: #selector(menuOpenPulse), keyEquivalent: "")
        let settings = NSMenuItem(title: L10n.t(.settings, lang), action: #selector(menuSettings), keyEquivalent: ",")
        let quit = NSMenuItem(title: L10n.t(.quit, lang), action: #selector(menuQuit), keyEquivalent: "q")
        for item in [open, settings, quit] { item.target = self }
        menu.addItem(open)
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuOpenPulse() {
        show()
    }

    @objc private func menuSettings() {
        store.openSettings()
    }

    @objc private func menuQuit() {
        store.quit()
    }

    /// The global shortcut is the menu-bar click — open closes,
    /// closed opens on the oldest wait.
    func toggleFromHotkey() {
        togglePanel()
    }

    func show() {
        // Already open: a reveal (a banner, a jump) is applied in place —
        // even over an open detail page — and nothing else resets.
        if panel.isVisible {
            ui.applyPendingReveal()
            panel.makeKeyAndOrderFront(nil)
            return
        }
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        // Every open is a fresh glance. Do it before the first layout pass so
        // the panel is never ordered in showing the previous visit's detail
        // page or expanded list (EXPERIENCE §4); `settleLayout` below flushes
        // the rebuilt tree, so the reset and the measurement agree.
        store.trayWillAppear()
        let anchor = buttonWindow.convertToScreen(button.frame)
        ui.maxListHeight = Double(Self.listHeightBudget(on: buttonWindow.screen ?? NSScreen.main))
        ui.open()
        lastFitRowCount = ui.displayRows.count
        lastFitDetail = ui.keys.detail
        settleLayout()
        positionPanel(below: anchor)
        panel.makeKeyAndOrderFront(nil)
        StatusPanelChrome.apply(
            to: panel,
            rootView: rootView,
            shadowView: shadowView,
            effectView: effectView
        )
        installOutsideClickMonitors()
        // Pressed while the tray is open, as a menu's title is while its
        // menu is. The button un-highlights itself when the click that
        // opened the tray is let go (its mouse tracking runs in the
        // event-tracking mode), so press it again once the run loop is back
        // in the default mode — after that mouse-up.
        button.highlight(true)
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                self.statusItem.button?.highlight(true)
            }
        }
        store.trayDidAppear()
        scheduleResize()
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        removeOutsideClickMonitors()
        statusItem.button?.highlight(false)
        store.trayDidDisappear()
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

        StatusPanelChrome.embed(hosting.view, in: effectView)
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
        let lamp = snapshot.lamp
        let key = "\(lamp.shape.rawValue)|\(lamp.tone)"
        if key != lastIconKey {
            let image: NSImage
            if let cached = iconCache[key] {
                image = cached
            } else {
                // Drawn by a handler at the button's own point size: crisp
                // at every scale, and redrawn when the menu bar's appearance
                // changes (a grey lamp is a template the menu bar colours).
                let rendered = PulseBrand.statusBarIcon(for: lamp)
                iconCache[key] = rendered
                image = rendered
            }
            button.image = image
            lastIconKey = key
        }
        // A coloured lamp owns its colour and a grey one is a template.
        // `contentTintColor` stays nil so AppKit keeps the adjacent title
        // readable against the actual menu bar appearance instead of tinting
        // both icon and text together.
        button.contentTintColor = nil
        // The icon alone unless something is blocked; then how many
        // and how long the oldest has waited ("2 · 4m").
        if button.title != snapshot.title { button.title = snapshot.title }
        // One line: the rule that set the lamp.
        button.toolTip = snapshot.tooltip
        button.setAccessibilityLabel(snapshot.accessibilityLabel)

        let waitingCount = snapshot.counts.blocked
        if snapshot.updatedAt != .distantPast {
            if let previousWaitingCount = lastWaitingCount,
               waitingCount > previousWaitingCount {
                pulseStatusLamp(button)
            }
            lastWaitingCount = waitingCount
        }

        // VoiceOver speaks up only for a new wait: who, and what it asks
        // (`WaitAnnouncement`). Other changes are the tray's to say when the
        // person looks. The empty bootstrap snapshot is not a transition:
        // the first completed scan seeds the count, so launching Pulse
        // announces nothing.
        if snapshot.updatedAt != .distantPast {
            if let text = WaitAnnouncement.text(
                previousBlocked: lastAnnouncedBlocked, rows: store.cachedAll, lang: store.lang
            ) {
                NSAccessibility.post(
                    element: button,
                    notification: .announcementRequested,
                    userInfo: [
                        .announcement: text,
                        .priority: NSAccessibilityPriorityLevel.high.rawValue,
                    ]
                )
            }
            lastAnnouncedBlocked = snapshot.counts.blocked
        }
    }

    /// A new wait dips the lamp once (EXPERIENCE §3: "flash once") — it
    /// flashed three times, which is a blink, and a blink is an alarm. With
    /// Reduce Motion on, the steady red is the whole signal.
    private func pulseStatusLamp(_ button: NSStatusBarButton) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        lampAttentionTask?.cancel()
        lampAttentionTask = Task { @MainActor [weak self, weak button] in
            guard let self else { return }
            button?.alphaValue = 0.3
            try? await Task.sleep(nanoseconds: 180_000_000)
            button?.alphaValue = 1
            self.lampAttentionTask = nil
        }
    }

    /// One deferred measure per change, and only a real change moves the
    /// frame. Only a change in the number of rows animates it; a plain scan
    /// or the detail page (which has its own transition) moves the edge at
    /// once, so nothing moves twice.
    private var resizeScheduled = false

    private func scheduleResize() {
        guard panel.isVisible, !captureInProgress, !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizeScheduled = false
            let count = self.ui.displayRows.count
            let detail = self.ui.keys.detail
            let animated = count != self.lastFitRowCount && detail == self.lastFitDetail && detail == nil
            self.lastFitRowCount = count
            self.lastFitDetail = detail
            self.resizeToFit(animated: animated)
        }
    }

    /// Measure, then measure again.
    ///
    /// SwiftUI reports the content height through a preference, so the first
    /// layout pass produces the number and the second one applies it. State
    /// that carried over made one pass look sufficient; a tray that is rebuilt
    /// on every open (see `TrayPanelHost`) would otherwise be ordered in at its
    /// minimum height and visibly grow.
    private func settleLayout() {
        resizeToFit()
        resizeToFit()
    }

    /// The tallest the list may be on this screen: the panel never runs off
    /// the bottom of the visible frame.
    static func listHeightBudget(on screen: NSScreen?) -> CGFloat {
        let visible = screen?.visibleFrame.height ?? TrayChrome.maxHeight
        let panel = min(TrayChrome.maxHeight, visible - 24 - StatusPanelChrome.shadowInset * 2)
        return max(120, min(TrayChrome.maxListHeight, panel - (TrayChrome.maxHeight - TrayChrome.maxListHeight)))
    }

    private func resizeToFit(animated: Bool = false) {
        hosting.view.layoutSubtreeIfNeeded()
        let fitting = hosting.view.fittingSize
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        let visibleHeight = screen?.visibleFrame.height ?? TrayChrome.maxHeight
        // The list scrolls past its budget; the panel itself stops at
        // `maxHeight` and at the screen's visible frame.
        let limit = min(TrayChrome.maxHeight, visibleHeight - 24 - StatusPanelChrome.shadowInset * 2)
        let height = min(limit, max(96, fitting.height))
        let inset = StatusPanelChrome.shadowInset
        let target = NSSize(
            width: max(TrayChrome.width, fitting.width) + inset * 2,
            height: height + inset * 2
        )
        guard abs(panel.frame.width - target.width) > 0.5
                || abs(panel.frame.height - target.height) > 0.5 else { return }

        var frame = panel.frame
        let oldTop = frame.maxY
        frame.size = target
        frame.origin.y = oldTop - target.height
        if let visible = screen?.visibleFrame {
            frame.origin.y = max(frame.origin.y, visible.minY + 8 - inset)
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animated, !reduceMotion {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }, completionHandler: { [weak self] in
                // The chrome below ran against the pre-animation bounds; the
                // shadow path must follow the frame the animation ended on.
                guard let self else { return }
                Task { @MainActor in self.reapplyChrome() }
            })
        } else {
            panel.setFrame(frame, display: true)
        }
        reapplyChrome()
    }

    /// Lay the root out at the panel's current frame and redraw the chrome
    /// (shadow path, border) against those bounds.
    private func reapplyChrome() {
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
            if event.type == .keyDown {
                // Every tray key goes through one reducer
                // (`TrayKeys.reduce`), whatever view has focus — so Esc works
                // in every state.
                guard event.window === self.panel else { return event }
                guard let key = TrayKeys.key(
                    keyCode: event.keyCode,
                    characters: event.charactersIgnoringModifiers ?? "",
                    command: event.modifierFlags.contains(.command)
                ) else { return event }
                return self.ui.handle(key) ? nil : event
            }
            // A click on the status item itself is the button's to handle:
            // closing here on mouse-down let its mouse-up action reopen the
            // panel it was meant to close.
            if let buttonWindow = self.statusItem.button?.window,
               event.window === buttonWindow {
                return event
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
    static let cornerRadius: CGFloat = PulseTheme.Radius.panel
    static let shadowInset: CGFloat = 12

    /// macOS 26's Liquid Glass where the system has it — the material
    /// the system's own menu-bar panels use there — and the menu material
    /// before it. A `.popover` material behind a borderless panel had no
    /// popover host and rendered flat grey; `.menu` within the window is the
    /// adaptive, deterministic fallback.
    static func makeSurface() -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.blendingMode = .withinWindow
        effect.state = .active
        return effect
    }

    /// Pins the tray's SwiftUI host edge to edge inside the surface. Glass
    /// hosts its content through `contentView`, so it is tinted and lit
    /// correctly; the material takes a plain subview.
    static func embed(_ content: NSView, in surface: NSView) {
        if #available(macOS 26.0, *), let glass = surface as? NSGlassEffectView {
            glass.contentView = content
            return
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            content.topAnchor.constraint(equalTo: surface.topAnchor),
            content.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
        ])
    }

    static func apply(
        to panel: NSPanel,
        rootView: NSView,
        shadowView: NSView,
        effectView: NSView
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
        // A hairline edge: dark mode lost the panel's outline against a dark
        // desktop. Resolved against the panel's own appearance on each open.
        let dark = effectView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        effectView.layer?.borderColor = NSColor(white: dark ? 1 : 0, alpha: dark ? 0.18 : 0.12).cgColor
        effectView.layer?.borderWidth = 0.5

        if let frameView = rootView.superview {
            frameView.wantsLayer = true
            frameView.layer?.backgroundColor = NSColor.clear.cgColor
            frameView.layer?.masksToBounds = false
        }
    }
}
