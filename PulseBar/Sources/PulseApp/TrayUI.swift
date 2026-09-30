import Foundation
import Observation

/// The tray's per-open state: the keyboard state (selection, detail), the
/// frozen row order and the height the list may use on this
/// screen. Owned by `StatusPanelController`, reset on every open, and
/// changed only through `TrayKeys.reduce` or a click — never by a view.
@MainActor
@Observable
final class TrayUI {
    let store: StatusStore
    var keys = TrayKeys.State()
    /// The order the rows had when the tray opened, newcomers appended.
    var frozen: [String] = []
    /// Every row that has been on screen this glance. While the tray is open
    /// they stay listed as long as they exist, even when the projection's
    /// window would now fold them away for a newer wait.
    var pinned: Set<String> = []
    /// `store.showAllAgents` when `pinned` was taken — "show all / show
    /// less" re-lays the list at the person's request.
    var pinnedShowAll = false
    /// The list's height budget on the current screen.
    var maxListHeight: Double = Double(TrayChrome.maxListHeight)
    /// Asks the panel to close (Esc on the list).
    @ObservationIgnored var onClose: () -> Void = {}

    init(store: StatusStore) {
        self.store = store
    }

    // MARK: - What the tray lists

    /// The rows on screen: the rows already shown this glance plus
    /// newcomers to the projection's window (`TrayOrder.openWindow`), in the
    /// frozen order.
    var displayRows: [AgentRow] {
        let showAll = store.showAllAgents
        return TrayOrder.openWindow(
            all: store.allRowsForDisplay,
            window: store.snapshot.rows,
            pinned: pinnedShowAll == showAll ? pinned : [],
            frozen: frozen,
            cap: showAll ? Int.max : TrayOrder.openCap
        )
    }

    /// The row whose detail page is open, while it still exists.
    var detailRow: AgentRow? {
        guard let key = keys.detail else { return nil }
        return store.allRowsForDisplay.first { $0.rowKey == key }
    }

    private func reducerRows() -> [TrayKeys.Row] {
        var rows = displayRows.map { TrayKeys.Row($0) }
        if let detail = detailRow, !rows.contains(where: { $0.key == detail.rowKey }) {
            rows.append(TrayKeys.Row(detail))
        }
        return rows
    }

    private func lookup(_ key: String) -> AgentRow? {
        store.allRowsForDisplay.first { $0.rowKey == key }
    }

    // MARK: - Lifecycle

    /// A new glance: nothing carries over from the last one. One
    /// gesture — a menu-bar click and the shortcut both open on the first
    /// row, which the projection's order makes the oldest wait
    /// (`TrayState.assemble`: waits first, the oldest first, an unknown
    /// clock last).
    func open() {
        frozen = store.snapshot.rows.map(\.rowKey)
        pinned = Set(frozen)
        pinnedShowAll = store.showAllAgents
        var next = TrayKeys.State()
        next.selected = displayRows.first?.rowKey
        if keys != next { keys = next }
        applyPendingReveal()
    }

    /// A reveal from a banner or a jump: select the row — and open its
    /// detail when asked — even while another detail page is open. A reveal
    /// for a row that no longer exists is dropped.
    func applyPendingReveal() {
        guard let reveal = store.takePendingReveal() else { return }
        guard lookup(reveal.rowKey) != nil else { return }
        if !store.snapshot.rows.contains(where: { $0.rowKey == reveal.rowKey }), !store.showAllAgents {
            store.toggleShowAllAgents()
        }
        var next = keys
        next.selected = reveal.rowKey
        next.detail = reveal.detail ? reveal.rowKey : nil
        if keys != next { keys = next }
    }

    /// A scan landed: newcomers take the next place, a detail page whose row
    /// left closes, and the selection stays on a row that is on screen.
    func absorbScan() {
        let extended = TrayOrder.extend(frozen, with: store.allRowsForDisplay)
        if extended != frozen { frozen = extended }
        let showAll = store.showAllAgents
        let shown = Set(displayRows.map(\.rowKey))
        let nextPinned = pinnedShowAll == showAll ? pinned.union(shown) : shown
        if nextPinned != pinned { pinned = nextPinned }
        if pinnedShowAll != showAll { pinnedShowAll = showAll }
        var next = keys
        if let detail = next.detail, lookup(detail) == nil { next.detail = nil }
        next = TrayKeys.normalize(next, rows: displayRows.map { TrayKeys.Row($0) })
        if keys != next { keys = next }
    }

    // MARK: - Keys

    /// One key from the panel's monitor. False: not the tray's key.
    func handle(_ key: TrayKeys.Key) -> Bool {
        let outcome = TrayKeys.reduce(keys, key, rows: reducerRows())
        let next = TrayKeys.normalize(outcome.state, rows: displayRows.map { TrayKeys.Row($0) })
        if keys != next { keys = next }
        if let effect = outcome.effect { perform(effect) }
        return outcome.handled
    }

    private func perform(_ effect: TrayKeys.Effect) {
        switch effect {
        case .focus(let key):
            if let row = lookup(key) { store.focusTerminal(row) }
        case .dismiss(let key):
            if let row = lookup(key) { store.dismissWaiting(row) }
        case .toggleMute(let key):
            if let row = lookup(key) { store.toggleMute(row.agent) }
        case .refresh:
            store.refresh(reason: "manual")
        case .openSettings:
            store.openSettings()
        case .closePanel:
            onClose()
        case .quit:
            store.quit()
        }
    }

    // MARK: - Clicks

    func send(_ action: TrayRowModel.Action, row: AgentRow) {
        switch action {
        case .primary:
            if row.canFocusTerminal {
                store.focusTerminal(row)
            } else {
                showDetail(row.rowKey)
            }
        case .details: showDetail(row.rowKey)
        case .dismiss: store.dismissWaiting(row)
        case .focus: store.focusTerminal(row)
        case .mute: store.toggleMute(row.agent)
        case .allowAutomation: store.answerAutomationOffer(row, allow: true)
        case .declineAutomation: store.answerAutomationOffer(row, allow: false)
        }
    }

    func send(_ action: DetailModel.Action, row: AgentRow) {
        switch action {
        case .back: closeDetail()
        case .focus: store.focusTerminal(row)
        case .dismiss: store.dismissWaiting(row)
        case .mute: store.toggleMute(row.agent)
        }
    }

    func showDetail(_ key: String) {
        var next = keys
        next.detail = key
        next.selected = key
        if keys != next { keys = next }
    }

    func closeDetail() {
        var next = keys
        if let open = next.detail { next.selected = open }
        next.detail = nil
        if keys != next { keys = next }
    }
}
