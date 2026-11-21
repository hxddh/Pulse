import AppKit
import Observation
import SwiftUI

/// Non-activating borderless floating panel used by the Waiting Beacon HUD:
/// appears over Full Screen apps and across all Spaces without ever taking
/// keyboard focus or entering the ⌘Tab switcher.
private final class NonActivatingBeaconPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Pure value-rendering view for the Floating Waiting Beacon pill.
/// Holds zero reference to `StatusStore` (`surface_check.py`).
struct FloatingBeaconFace: View {
    let model: BeaconModel
    var send: (BeaconModel.Action) -> Void = { _ in }

    private func t(_ key: L10n.Key) -> String { L10n.t(key, model.lang) }

    var body: some View {
        Button {
            send(.jump)
        } label: {
            HStack(spacing: PulseTheme.Space.s) {
                LampShapeView(lamp: .waiting, size: 9)
                AgentIconView(id: model.agent)
                if model.blockedCount > 1 {
                    Text("\(model.blockedCount)")
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
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Lamp.waiting.color.opacity(0.45), lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 420)
        .fixedSize(horizontal: true, vertical: true)
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
private struct FloatingBeaconHostView: View {
    let store: StatusStore
    let send: (BeaconModel.Action) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: TrayChrome.clock)) { context in
            if let model = BeaconModel.make(
                rows: store.rows,
                lang: store.lang,
                nowMs: Int64(context.date.timeIntervalSince1970 * 1000),
                quiet: store.settings.isQuiet(at: Int64(context.date.timeIntervalSince1970 * 1000))
            ) {
                FloatingBeaconFace(model: model, send: send)
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

    private let store: StatusStore
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
        observeStore()
    }

    func stop() {
        stopped = true
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
        guard !stopped else { return }
        let shouldShow = store.settings.floatingBeacon
            && !trayOpen
            && !store.previewFixtureActive
            && store.rows.contains(where: \.isBlocked)
        guard shouldShow else {
            panel?.orderOut(nil)
            return
        }
        let panel = ensurePanel()
        hosting?.view.layoutSubtreeIfNeeded()
        if let size = hosting?.view.fittingSize, size.width > 20, size.height > 20 {
            let oldFrame = panel.frame
            let newOrigin = savedOrigin() ?? defaultOrigin(for: size)
            let origin = oldFrame.size.width > 0 && panel.isVisible ? oldFrame.origin : newOrigin
            panel.setFrame(clampedFrame(origin: origin, size: size), display: true)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func ensurePanel() -> NonActivatingBeaconPanel {
        if let panel { return panel }
        let host = NSHostingController(rootView: FloatingBeaconHostView(store: store) { [weak self] action in
            self?.handle(action)
        })
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
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        self.hosting = host
        self.panel = panel
        return panel
    }

    private func handle(_ action: BeaconModel.Action) {
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

    func windowDidMove(_ notification: Notification) {
        guard let panel, panel.isVisible else { return }
        let origin = panel.frame.origin
        UserDefaults.standard.set([Double(origin.x), Double(origin.y)], forKey: Self.originDefaultsKey)
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
