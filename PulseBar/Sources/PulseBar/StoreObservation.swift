import Combine
import Foundation

/// A window's view of `StatusStore` that is not redrawn by every scan.
///
/// `StatusStore` publishes everything from one object, so any view observing
/// it directly re-evaluates its whole body on every scan — every two seconds
/// while something is Waiting — whether or not a single thing it shows moved.
/// For Settings that is a form of fifteen controls and ninety localized
/// strings rebuilt for nothing, on a resident app that lives or dies by its
/// energy use.
///
/// This observes the store and forwards its changes, except those made while
/// a scan is being applied (`StatusStore.isApplyingScan`). Those are forwarded
/// at most once per `scanRefreshInterval`, because a few facts Settings shows
/// (wait history, today's interruptions) do come from scans and must not
/// freeze — they just do not need to be fresher than that.
@MainActor
final class StoreObservation: ObservableObject {
    let store: StatusStore
    /// How many changes reached the observing view. Tests read it.
    private(set) var forwardedChanges = 0
    private var lastScanForwardMs: Int64
    private let scanRefreshIntervalMs: Int64
    private let nowMs: () -> Int64
    private var subscription: AnyCancellable?

    init(
        store: StatusStore,
        scanRefreshInterval: TimeInterval = 30,
        nowMs: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.store = store
        self.scanRefreshIntervalMs = Int64(scanRefreshInterval * 1000)
        self.nowMs = nowMs
        self.lastScanForwardMs = nowMs()
        subscription = store.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.storeWillChange() }
        }
    }

    private func storeWillChange() {
        if store.isApplyingScan {
            let now = nowMs()
            guard now - lastScanForwardMs >= scanRefreshIntervalMs else { return }
            lastScanForwardMs = now
        }
        forwardedChanges += 1
        objectWillChange.send()
    }
}
