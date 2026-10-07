import AppKit
import Observation
import SwiftUI

/// The status item: the lamp in the menu bar, and the tray in an
/// `NSPopover` anchored to its button.
///
/// The popover owns the surface (the system's material — Liquid Glass on
/// macOS 26), the arrow, the size (it follows the SwiftUI tray's ideal size,
/// `TrayView`) and closing on a click outside (`.transient`). This class
/// owns the lamp, the button's clicks and the keys: every key the tray's
/// window receives goes through `TrayKeys.reduce` (`TrayUI.handle`),
/// whatever view has focus — so Esc and ⌘W work in every state.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    static weak var shared: StatusItemController?

    private let store: StatusStore
    /// Internal: `PulseQA` photographs the button (`captureStatusItem(to:)`).
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    /// The tray's per-open state — keys, frozen order, height budget.
    let ui: TrayUI
    private let hosting: NSHostingController<TrayView>
    /// Follows only `snapshot` — a settings write does not touch the lamp.
    private var snapshotLoop: ObservationLoop?
    private var keyMonitor: Any?
    private var shownLamp: Lamp?
    /// The blocked count the lamp's dip and VoiceOver last knew; nil until
    /// the first scan.
    private var lastBlocked: Int?
    private var dipTask: Task<Void, Never>?
    /// When the popover last began to close. The mouse-down on the button
    /// that closes a transient popover is also the button's click, and must
    /// not open it again.
    private var closedAt = Date.distantPast
    /// Pulse was not the active app when the tray opened: closing it hands
    /// the keyboard back to the app that had it.
    private var activatedForTray = false
    /// The status item's menu is up. `performClick` tracks the menu in a
    /// nested run loop, and a click on the status item inside it would
    /// otherwise show the menu again from within itself.
    private var showingMenu = false

    init(store: StatusStore) {
        self.store = store
        let ui = TrayUI(store: store)
        self.ui = ui
        hosting = NSHostingController(rootView: TrayView(store: store, ui: ui))
        // The popover takes the tray's ideal size, and follows it as rows
        // come and go or the detail page opens.
        hosting.sizingOptions = [.preferredContentSize]
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = hosting
        popover.delegate = self
        ui.onClose = { [weak self] in self?.close() }
    }

    func install() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(buttonPressed)
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
            self.updateStatusItem(store.snapshot)
            if self.popover.isShown { self.ui.absorbScan() }
        }
        updateStatusItem(store.snapshot)
    }

    func uninstall() {
        close()
        dipTask?.cancel()
        dipTask = nil
        snapshotLoop?.cancel()
        snapshotLoop = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: - The button

    /// A left click toggles the tray; a right click (or Control-click)
    /// shows the status item's menu.
    @objc private func buttonPressed() {
        guard !showingMenu else { return }
        let event = NSApp?.currentEvent
        if event?.type == .rightMouseDown || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if popover.isShown {
            close()
        } else if Date().timeIntervalSince(closedAt) > 0.3 {
            show()
        }
    }

    /// Open Pulse · Settings… · Quit Pulse — shown the system way: the
    /// menu is the status item's for exactly one click.
    private func showMenu() {
        showingMenu = true
        defer { showingMenu = false }
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

    @objc private func menuOpenPulse() { show() }

    @objc private func menuSettings() { store.openSettings() }

    @objc private func menuQuit() { store.quit() }

    // MARK: - The tray

    func show() {
        // Already open: a reveal (a banner, a jump) is applied in place —
        // even over an open detail page — and nothing else resets.
        if popover.isShown {
            ui.applyPendingReveal()
            return
        }
        guard let button = statusItem.button else { return }
        store.trayWillAppear()
        ui.maxListHeight = Self.listHeightBudget(on: button.window?.screen ?? NSScreen.main)
        ui.open(pointer: NSEvent.mouseLocation)
        // Lay the fresh tray out before it is shown — twice: the list's
        // height is measured in one pass and applied in the next — so the
        // popover opens at its size instead of growing into it.
        hosting.view.layoutSubtreeIfNeeded()
        hosting.view.layoutSubtreeIfNeeded()
        popover.contentSize = hosting.view.fittingSize
        // An accessory app's window gets keys only while the app is active,
        // and the tray is a keyboard surface (↑↓ ↩ → ⌘D).
        // (Closing hides Pulse to hand the keyboard back; unhide first.)
        activatedForTray = NSApp?.isActive == false
        if NSApp?.isHidden == true { NSApp?.unhide(nil) }
        NSApp?.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        hosting.view.window?.makeKey()
        // Pressed while the tray is open, as a menu's title is while its
        // menu is. The button un-highlights itself when the click that
        // opened the tray is let go (its tracking runs in the event-tracking
        // mode), so press it again once the run loop is back in the default
        // mode — after that mouse-up.
        button.highlight(true)
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.popover.isShown else { return }
                self.statusItem.button?.highlight(true)
            }
        }
        store.trayDidAppear()
    }

    func close() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    /// The tallest the list may be on this screen: the tray never runs off
    /// the bottom of the visible frame.
    static func listHeightBudget(on screen: NSScreen?) -> Double {
        let visible = screen?.visibleFrame.height ?? .infinity
        return Double(max(120, min(TrayChrome.maxListHeight, visible - 200)))
    }

    func popoverDidShow(_ notification: Notification) {
        statusItem.button?.highlight(true)
        installKeyMonitor()
        // Another window taking the keyboard — Settings, the terminal a row
        // went to — closes the tray, as a click outside does.
        if let window = hosting.view.window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(trayWindowResignedKey),
                name: NSWindow.didResignKeyNotification, object: window
            )
        }
    }

    @objc private func trayWindowResignedKey() { close() }

    func popoverWillClose(_ notification: Notification) {
        closedAt = Date()
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        store.trayDidDisappear()
        // Hand the keyboard back to the app that had it — unless another app
        // already took it, or Pulse has a window of its own up (Settings).
        if activatedForTray, NSApp?.isActive == true, !SettingsWindowController.shared.isOpen {
            NSApp?.hide(nil)
        }
        activatedForTray = false
    }

    /// Every key in the tray's window goes through one reducer
    /// (`TrayKeys.reduce`), whatever view has focus.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, event.window === self.hosting.view.window,
                  let key = TrayKeys.key(
                      keyCode: event.keyCode,
                      characters: event.charactersIgnoringModifiers ?? "",
                      command: event.modifierFlags.contains(.command)
                  )
            else { return event }
            return self.ui.handle(key) ? nil : event
        }
    }

    // MARK: - The lamp

    private func updateStatusItem(_ snapshot: PulseSnapshot) {
        guard let button = statusItem.button else { return }
        if snapshot.lamp != shownLamp {
            // Drawn by a handler at the button's own point size, and redrawn
            // when the menu bar's appearance changes.
            button.image = snapshot.lamp.statusBarImage
            shownLamp = snapshot.lamp
        }
        // A coloured lamp owns its colour and a grey one is a template.
        // `contentTintColor` stays nil so AppKit keeps the adjacent title
        // readable against the actual menu bar appearance.
        button.contentTintColor = nil
        // The icon alone unless something is blocked; then how many and how
        // long the oldest has waited ("2 · 4m").
        if button.title != snapshot.title { button.title = snapshot.title }
        // One line: the rule that set the lamp.
        button.toolTip = snapshot.tooltip
        button.setAccessibilityLabel(snapshot.accessibilityLabel)

        // The empty bootstrap snapshot is not a transition: the first
        // completed scan seeds the count, so launching Pulse dips and
        // announces nothing.
        guard snapshot.updatedAt != .distantPast else { return }
        if let previous = lastBlocked, snapshot.counts.blocked > previous {
            dipLamp(button)
        }
        // VoiceOver speaks up only for a new wait: who, and what it asks
        // (`WaitAnnouncement`). Other changes are the tray's to say when the
        // person looks.
        if let text = WaitAnnouncement.text(previousBlocked: lastBlocked, rows: store.cachedAll, lang: store.lang) {
            NSAccessibility.post(
                element: button,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: text,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )
        }
        lastBlocked = snapshot.counts.blocked
    }

    /// A new wait dips the lamp once (EXPERIENCE §3) — a blink is an alarm.
    /// With Reduce Motion on, the steady red is the whole signal.
    private func dipLamp(_ button: NSStatusBarButton) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        dipTask?.cancel()
        dipTask = Task { @MainActor [weak self, weak button] in
            button?.alphaValue = 0.3
            try? await Task.sleep(nanoseconds: 180_000_000)
            button?.alphaValue = 1
            self?.dipTask = nil
        }
    }
}

/// AppKit's way to follow an `@Observable` value.
///
/// SwiftUI re-reads what a body touched; AppKit code (the status item, the
/// menu-bar lamp) has no body. This re-arms `withObservationTracking` after
/// every change so `onChange` runs once per change of anything `track`
/// read — and never for a change of something it did not read, which is the
/// point: the status item is not woken by a write it does not draw.
///
/// `Observations` (the async sequence) would do this, but needs macOS 26;
/// Pulse deploys to 14.
///
/// Changes are delivered on the next main-actor turn, after the write has
/// landed (Observation reports `willSet`), and a burst of writes inside one
/// turn is delivered once.
@MainActor
final class ObservationLoop {
    private let track: @MainActor () -> Void
    private let onChange: @MainActor () -> Void
    private var active = true
    /// How many times `onChange` ran. Tests read it.
    private(set) var deliveries = 0

    init(track: @escaping @MainActor () -> Void, onChange: @escaping @MainActor () -> Void) {
        self.track = track
        self.onChange = onChange
        arm()
    }

    func cancel() {
        active = false
    }

    private func arm() {
        guard active else { return }
        withObservationTracking {
            track()
        } onChange: { [weak self] in
            // Bind before the Task: the handler is @Sendable, and a captured
            // `weak self` var cannot be referenced from inside a Task.
            guard let loop = self else { return }
            Task { @MainActor in loop.fire() }
        }
    }

    private func fire() {
        guard active else { return }
        deliveries += 1
        onChange()
        arm()
    }
}
