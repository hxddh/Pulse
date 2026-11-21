import AppKit
import Observation
import SwiftUI

/// Non-activating borderless floating panel used by the Waiting Beacon HUD:
/// appears over Full Screen apps and across all Spaces without ever taking
/// keyboard focus or entering the ⌘Tab switcher. Separates dragging (> 4 pt)
/// from clicks in screen coordinates so dragging never triggers a jump or
/// fights button tracking.
private final class NonActivatingBeaconPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var onDragFinished: (() -> Void)?

    private var mouseDownScreen: NSPoint?
    private var mouseDownOrigin: NSPoint?
    private var dragging = false

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            mouseDownScreen = NSEvent.mouseLocation
            mouseDownOrigin = frame.origin
            dragging = false
            super.sendEvent(event)
        case .leftMouseDragged:
            if let start = mouseDownScreen, let origin = mouseDownOrigin {
                let now = NSEvent.mouseLocation
                let dx = now.x - start.x
                let dy = now.y - start.y
                if dragging || hypot(dx, dy) > 4 {
                    dragging = true
                    setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
                    return
                }
            }
            super.sendEvent(event)
        case .leftMouseUp:
            if dragging {
                dragging = false
                mouseDownScreen = nil
                mouseDownOrigin = nil
                onDragFinished?()
                return
            }
            mouseDownScreen = nil
            mouseDownOrigin = nil
            super.sendEvent(event)
        default:
            super.sendEvent(event)
        }
    }
}

/// Pure value-rendering view for the Floating Waiting Beacon pill.
/// Holds zero reference to `StatusStore` (`surface_check.py`).
struct FloatingBeaconFace: View {
    let model: BeaconModel
    var send: (BeaconModel.Action) -> Void = { _ in }
    var onHoverChanged: (Bool) -> Void = { _ in }
    @State private var hovered = false

    private func t(_ key: L10n.Key) -> String { L10n.t(key, model.lang) }

    var body: some View {
        HStack(spacing: PulseTheme.Space.s) {
            HStack(spacing: PulseTheme.Space.s) {
                LampShapeView(lamp: .waiting, size: 9)
                AgentIconView(id: model.agent)
                if model.blockedCount > 1 {
                    Text("\(model.queueIndex)/\(model.blockedCount)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Lamp.waiting.color, in: Capsule())
                        .fixedSize()
                }
                if !model.project.isEmpty {
                    Text(model.project)
                        .font(PulseTheme.Font.body.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                Text(model.headline)
                    .font(PulseTheme.Font.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if model.hasConflict {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(PulseTheme.warning)
                        .accessibilityHidden(true)
                }
                if model.quiet {
                    Image(systemName: "bell.slash.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                if !model.waitAge.isEmpty {
                    Text(model.waitAge)
                        .font(PulseTheme.Font.caption)
                        .foregroundStyle(Lamp.waiting.color)
                        .monospacedDigit()
                        .fixedSize()
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { send(.jump) }

            if hovered {
                Divider()
                    .frame(height: 12)
                    .opacity(0.45)
                HStack(spacing: 2) {
                    Button {
                        send(.openTray)
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(t(.beaconOpenTray))
                    .accessibilityLabel(t(.beaconOpenTray))

                    Button {
                        send(.ignorePrimary)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(t(.ignoreWait))
                    .accessibilityLabel(t(.ignoreWait))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Lamp.waiting.color.opacity(hovered ? 0.65 : 0.45), lineWidth: 1)
        )
        .contentShape(Capsule())
        .frame(maxWidth: hovered ? 472 : 420)
        .fixedSize(horizontal: true, vertical: true)
        .onHover { inside in
            if hovered != inside {
                hovered = inside
                onHoverChanged(inside)
            }
        }
        .contextMenu {
            Button(t(.menuJumpOldestWait)) { send(.jump) }
            Button(t(.menuOpenPulse)) { send(.openTray) }
            Divider()
            Button(t(.ignoreWait)) { send(.ignorePrimary) }
            Menu(t(.quietNotifications)) {
                Button(t(.quietFor30m)) { send(.quiet(minutes: 30)) }
                Button(t(.quietFor1h)) { send(.quiet(minutes: 60)) }
            }
            Divider()
            Button(t(.beaconHide)) { send(.hideBeacon) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { send(.jump) }
    }
}

@MainActor
@Observable
private final class FloatingBeaconPreviewState {
    var active = false
}

@MainActor
private struct FloatingBeaconHostView: View {
    let store: StatusStore
    let preview: FloatingBeaconPreviewState
    let send: (BeaconModel.Action) -> Void
    let onHoverChanged: (Bool) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: TrayChrome.clock)) { context in
            let nowMs = Int64(context.date.timeIntervalSince1970 * 1000)
            if preview.active {
                FloatingBeaconFace(
                    model: BeaconModel.preview(lang: store.lang),
                    send: send,
                    onHoverChanged: onHoverChanged
                )
                .padding(6)
            } else if let model = BeaconModel.make(
                rows: store.rows,
                lang: store.lang,
                nowMs: nowMs,
                quiet: store.settings.isQuiet(at: nowMs)
            ) {
                FloatingBeaconFace(model: model, send: send, onHoverChanged: onHoverChanged)
                    .padding(6)
            }
        }
    }
}

/// Manages the lifecycle, positioning, and non-activating visibility of the
/// Floating Waiting Beacon HUD.
@MainActor
final class FloatingBeaconController: NSObject, NSWindowDelegate {
    static weak var shared: FloatingBeaconController?

    private static let originDefaultsKey = "pulse.floatingBeacon.origin"
    private static let anchorRightDefaultsKey = "pulse.floatingBeacon.anchorRight"

    private let store: StatusStore
    private let previewState = FloatingBeaconPreviewState()
    private var previewTask: Task<Void, Never>?
    private var panel: NonActivatingBeaconPanel?
    private var hosting: NSHostingController<FloatingBeaconHostView>?
    private var trayOpen = false
    private var stopped = false

    init(store: StatusStore) {
        self.store = store
        super.init()
    }

    func start() {
        stopped = false
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        observeStore()
    }

    func stop() {
        stopped = true
        previewTask?.cancel()
        previewTask = nil
        previewState.active = false
        NotificationCenter.default.removeObserver(self)
        panel?.orderOut(nil)
        panel?.delegate = nil
        panel = nil
        hosting = nil
    }

    func setTrayOpen(_ open: Bool) {
        guard trayOpen != open else { return }
        trayOpen = open
        syncVisibility()
    }

    /// Show a 5-second interactive preview pill (invoked from Settings) so the
    /// user can see and drag-position the HUD even when no agent is blocked.
    func showPreview() {
        guard !stopped else { return }
        previewTask?.cancel()
        previewState.active = true
        syncVisibility()
        previewTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.endPreview()
        }
    }

    private func endPreview() {
        previewTask?.cancel()
        previewTask = nil
        guard previewState.active else { return }
        previewState.active = false
        syncVisibility()
    }

    @objc private func screensChanged() {
        guard let panel, panel.isVisible else { return }
        panel.setFrame(clampedFrame(origin: panel.frame.origin, size: panel.frame.size), display: true)
    }

    private var shouldBeVisible: Bool {
        guard !stopped else { return false }
        if previewState.active { return true }
        return store.settings.floatingBeacon
            && !trayOpen
            && !store.previewFixtureActive
            && store.rows.contains(where: \.isBlocked)
    }

    private func observeStore() {
        guard !stopped else { return }
        withObservationTracking {
            _ = store.rows
            _ = store.settings.floatingBeacon
            _ = store.settings.quietUntilMs
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.syncVisibility()
                self?.observeStore()
            }
        }
        syncVisibility()
    }

    private func syncVisibility() {
        guard shouldBeVisible else {
            hidePanel()
            return
        }
        let panel = ensurePanel()
        relayoutPanel(panel)
        if !panel.isVisible {
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            panel.alphaValue = reduceMotion ? 1 : 0
            panel.orderFrontRegardless()
            if !reduceMotion {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.16
                    panel.animator().alphaValue = 1
                }
            }
        }
    }

    private func hidePanel() {
        guard let panel, panel.isVisible else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            panel.orderOut(nil)
            panel.alphaValue = 1
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.16
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, !self.shouldBeVisible else { return }
                    self.panel?.orderOut(nil)
                    self.panel?.alphaValue = 1
                }
            })
        }
    }

    private func relayoutPanel(_ panel: NonActivatingBeaconPanel) {
        hosting?.view.layoutSubtreeIfNeeded()
        guard let size = hosting?.view.fittingSize, size.width > 20, size.height > 20 else { return }
        let oldFrame = panel.frame
        let anchorRight = isAnchoredRight()
        let origin: NSPoint
        if panel.isVisible, oldFrame.size.width > 0 {
            if anchorRight {
                origin = NSPoint(x: oldFrame.maxX - size.width, y: oldFrame.origin.y)
            } else {
                origin = oldFrame.origin
            }
        } else if let saved = savedOrigin() {
            origin = saved
        } else {
            origin = defaultOrigin(for: size)
        }
        panel.setFrame(clampedFrame(origin: origin, size: size), display: true)
    }

    private func ensurePanel() -> NonActivatingBeaconPanel {
        if let panel { return panel }
        let host = NSHostingController(rootView: FloatingBeaconHostView(
            store: store,
            preview: previewState,
            send: { [weak self] action in self?.handle(action) },
            onHoverChanged: { [weak self] _ in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                DispatchQueue.main.async { [weak self, weak panel] in
                    guard let self, let panel, panel.isVisible else { return }
                    self.relayoutPanel(panel)
                }
            }
        ))
        let panel = NonActivatingBeaconPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 48),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = host
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.onDragFinished = { [weak self] in self?.persistCurrentPosition() }
        panel.delegate = self
        self.hosting = host
        self.panel = panel
        return panel
    }

    private func handle(_ action: BeaconModel.Action) {
        if previewState.active {
            endPreview()
            switch action {
            case .openTray:
                store.requestTrayReveal(key: store.rows.first(where: \.isBlocked)?.key)
            case .quiet(let minutes):
                store.setQuiet(minutes: minutes)
            case .hideBeacon:
                store.set(\.floatingBeacon, false)
            case .jump, .ignorePrimary:
                break
            }
            return
        }
        switch action {
        case .jump:
            store.jumpToOldestWait()
        case .openTray:
            store.requestTrayReveal(key: store.rows.first(where: \.isBlocked)?.key)
        case .ignorePrimary:
            if let primary = store.rows.first(where: \.isBlocked) {
                store.dismissWaiting(primary)
            }
        case .quiet(let minutes):
            store.setQuiet(minutes: minutes)
        case .hideBeacon:
            store.set(\.floatingBeacon, false)
        }
    }

    private func persistCurrentPosition() {
        guard let panel, panel.isVisible else { return }
        let clamped = clampedFrame(origin: panel.frame.origin, size: panel.frame.size)
        if clamped != panel.frame {
            panel.setFrame(clamped, display: true)
        }
        let screen = NSScreen.screens.first { $0.frame.contains(clamped.origin) } ?? NSScreen.main ?? NSScreen.screens.first
        let anchorRight: Bool
        if let visible = screen?.visibleFrame {
            anchorRight = clamped.midX >= visible.midX
        } else {
            anchorRight = true
        }
        UserDefaults.standard.set([Double(clamped.origin.x), Double(clamped.origin.y)], forKey: Self.originDefaultsKey)
        UserDefaults.standard.set(anchorRight, forKey: Self.anchorRightDefaultsKey)
    }

    private func isAnchoredRight() -> Bool {
        if UserDefaults.standard.object(forKey: Self.anchorRightDefaultsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: Self.anchorRightDefaultsKey)
    }

    private func savedOrigin() -> NSPoint? {
        guard let pair = UserDefaults.standard.array(forKey: Self.originDefaultsKey) as? [Double],
              pair.count == 2 else { return nil }
        return NSPoint(x: pair[0], y: pair[1])
    }

    private func defaultOrigin(for size: NSSize) -> NSPoint {
        let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(
            x: frame.maxX - size.width - 18,
            y: frame.maxY - size.height - 14
        )
    }

    private func clampedFrame(origin: NSPoint, size: NSSize) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.contains(origin) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return NSRect(origin: origin, size: size) }
        let x = min(max(origin.x, visible.minX + 8), max(visible.minX + 8, visible.maxX - size.width - 8))
        let y = min(max(origin.y, visible.minY + 8), max(visible.minY + 8, visible.maxY - size.height - 8))
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }
}
