import Foundation
import Observation

/// AppKit's way to follow an `@Observable` value.
///
/// SwiftUI re-reads what a body touched; AppKit code (the status item, the
/// panel's size) has no body. This re-arms `withObservationTracking` after
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
