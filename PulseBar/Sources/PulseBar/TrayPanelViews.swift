// 3.0-α: the tray scene, moved verbatim out of PulseApp.swift.
// Behavior-frozen split — the view layer gets one file per scene so the
// workbench (3.0-β) grows beside its siblings instead of inside a
// 3,000-line monolith.

import SwiftUI
import AppKit

// MARK: - Tray chrome

enum TrayChrome {
    /// 360 lost the end of most session titles: after the 12pt accent gutter,
    /// the 18pt icon, and the status chip, a row title had ~230pt — roughly
    /// thirty characters, where a real task name is fifty. A menu-bar panel at
    /// 400 is still narrow next to the calendar and reminder popovers people
    /// already run, and it is forty characters instead of thirty.
    static let width: CGFloat = 448
    static let padX: CGFloat = 16
    /// Shared identity grid for rows and project/status headings. Keeping the
    /// columns explicit prevents a section marker from drifting away from the
    /// lamp it explains when the grouping mode changes.
    static let rowLeadingInset: CGFloat = 14
    static let iconColumnWidth: CGFloat = 18
    static let iconToIdentityGap: CGFloat = 11
    static let identityLampSize: CGFloat = 6
    static let identityLampToNameGap: CGFloat = 6
    static let rowIdentityStart: CGFloat =
        rowLeadingInset + iconColumnWidth + iconToIdentityGap
    static let rowNameStart: CGFloat =
        rowIdentityStart + identityLampSize + identityLampToNameGap
    /// Section headers keep their title on the same column as Agent names.
    /// The accent marker starts where a row's lamp starts, not in the old
    /// disclosure-column centre.
    static let sectionAccentPrefix: CGFloat = rowIdentityStart - padX
    /// The heading's first item plus its 9pt inter-item gap must land on the
    /// same name column as a row (icon → lamp → name). Derive it from the
    /// actual row grid instead of letting a future icon-size tweak drift the
    /// heading independently.
    static let sectionHeaderLeadWidth: CGFloat =
        rowNameStart - padX - 9
    /// One hit target for every compact header action. SF Symbols have
    /// different intrinsic boxes; the shared frame aligns their visible
    /// centres and keeps the title on the same row.
    static let headerControlSize: CGFloat = 28
    static let waitAccent = GlanceKind.waiting.lampColor
    static let runAccent = GlanceKind.running.lampColor

}

private struct StatusChip: View {
    enum Kind { case waiting, running, recent, process, snoozed }

    let kind: Kind
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(background, in: Capsule(style: .continuous))
    }

    private var foreground: Color {
        switch kind {
        case .waiting: return TrayChrome.waitAccent
        case .running: return TrayChrome.runAccent
        case .process: return Color.secondary.opacity(0.9)
        case .recent: return Color.secondary.opacity(0.85)
        // Still the waiting colour, drained. Snoozed is a waiting row that
        // agreed to be quiet, not a different kind of thing.
        case .snoozed: return TrayChrome.waitAccent.opacity(0.6)
        }
    }

    private var background: Color {
        switch kind {
        case .waiting: return TrayChrome.waitAccent.opacity(0.16)
        case .running: return TrayChrome.runAccent.opacity(0.12)
        case .process: return Color.primary.opacity(0.05)
        case .recent: return Color.primary.opacity(0.04)
        case .snoozed: return TrayChrome.waitAccent.opacity(0.08)
        }
    }
}

// MARK: - Tray panel

/// Measured height of the row list, so the panel is sized by its content
/// instead of by arithmetic.
private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// One heading per tray section: "Needs you · 2".
private struct SectionHeader: View {
    let title: String
    let count: Int
    let accent: Bool
    /// Non-nil turns the heading into the group's disclosure control.
    var collapsed: Bool?
    /// Who is in the group, shown while it is folded away — a count alone
    /// answers "how many" and not "which", and folded is exactly when the
    /// rows are not there to answer it.
    var summary: String = ""
    var toggle: (() -> Void)?
    /// False when `summary` already names every row in the group.
    var showCount = true

    var body: some View {
        let line = HStack(spacing: 9) {
            if collapsed == nil, accent {
                // Project headings with a waiting row use the same lamp column
                // as their child rows. The title still starts at the shared
                // rowNameStart, so the marker is no longer stranded at x=85.
                ZStack(alignment: .leading) {
                    Color.clear
                    Circle()
                        .fill(TrayChrome.waitAccent)
                        .frame(
                            width: TrayChrome.identityLampSize,
                            height: TrayChrome.identityLampSize
                        )
                        .offset(x: TrayChrome.sectionAccentPrefix)
                }
                .frame(width: TrayChrome.sectionHeaderLeadWidth, height: 14, alignment: .center)
            } else {
                Group {
                    if let collapsed {
                        Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .opacity(0.6)
                    } else {
                        Color.clear
                    }
                }
                // Reserve the disclosure column even for a non-foldable group.
                // The row identity now has an icon, a status lamp, and two small
                // gaps before its name. Match that optical start here so section
                // headings do not appear to drift left of every agent name.
                // The lead width plus the 9pt gap keeps the heading on the
                // exact same baseline column as the row identity text.
                .frame(width: TrayChrome.sectionHeaderLeadWidth, height: 14, alignment: .center)
            }
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            // "No project 2 Pi · Amp" — two names and a 2. The count only
            // earns its place when the names do not already give it.
            if showCount {
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .opacity(0.7)
                    .foregroundStyle(accent ? TrayChrome.waitAccent : Color.secondary)
            }
            if !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 11))
                    .opacity(0.55)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, TrayChrome.padX)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)

        if let toggle {
            Button(action: toggle) { line.contentShape(Rectangle()) }
                .buttonStyle(.plain)
        } else {
            line
        }
    }
}

/// Owns nothing but the tray's identity.
///
/// `StatusPanelController` builds the hosting controller once and then only
/// orders the window in and out, so SwiftUI keeps `TrayPanel`'s `@State`
/// forever: fold, search text, session filters and keyboard selection all
/// survived closing the panel, and the next glance opened in the middle of the
/// last one's rummaging — the opposite of EXPERIENCE §4.
///
/// Re-identifying the subtree per open resets *every* piece of that state,
/// including any added later. An explicit reset callback would have to list
/// them, and the list is exactly the thing that rots: the defect it replaces
/// arrived when `filterPhase` / `filterOutcome` / `filterAgentRaw` were added
/// next to a `folded` set nobody was clearing either.
@MainActor
struct TrayPanelHost: View {
    @ObservedObject var store: StatusStore

    var body: some View {
        TrayPanel(store: store)
            .id(store.traySessionToken)
    }
}

@MainActor
struct TrayPanel: View {
    @ObservedObject var store: StatusStore
    @State fileprivate var measuredHeight: CGFloat = 0
    /// Folding is opt-in and per-panel. A fresh glance shows every row; the
    /// header must never claim five sessions while the list silently shows one.
    @State fileprivate var folded: Set<String> = []
    @State fileprivate var query = ""
    @State fileprivate var searchActive = false
    @State fileprivate var filterPhase = ""
    @State fileprivate var filterOutcome = ""
    @State fileprivate var filterAgentRaw = ""

    /// Row key the keyboard has selected, if any.
    @State fileprivate var selectedKey: String?
    @FocusState fileprivate var listFocused: Bool

    fileprivate func toggleFold(_ id: String) {
        // A panel that repaints itself every couple of seconds cannot afford
        // hard cuts: a block of rows appearing instantly is indistinguishable
        // from a reorder, and you re-read the whole list to find out which it
        // was. Short and flat — this is a menu-bar panel, not a launch screen.
        withAnimation(.easeOut(duration: 0.16)) {
            if folded.contains(id) { folded.remove(id) } else { folded.insert(id) }
        }
    }

    /// Rows in the order the keyboard walks them: what is actually on screen,
    /// so a folded group is skipped rather than silently selected.
    fileprivate func visibleRows(_ groups: [RowGroup]) -> [AgentRow] {
        groups.flatMap { group -> [AgentRow] in
            if group.foldable && TrayFold.isCollapsed(group.id, manuallyFolded: folded) { return [] }
            return group.rows
        }
    }

    fileprivate func moveSelection(_ delta: Int, in groups: [RowGroup]) {
        let rows = visibleRows(groups)
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.rowKey == selectedKey }
        let next: Int
        if let current {
            next = min(max(current + delta, 0), rows.count - 1)
        } else {
            next = delta > 0 ? 0 : rows.count - 1
        }
        selectedKey = rows[next].rowKey
    }

    fileprivate func activateSelection(_ groups: [RowGroup]) {
        guard let key = selectedKey,
              let row = visibleRows(groups).first(where: { $0.rowKey == key }) else { return }
        store.primaryAction(row)
    }

    /// Go-Look Closure: apply a one-shot reveal from notify / hotkey / jump.
    /// Keep the pending key until the target is actually visible — expanding
    /// "show all" or unfolding must not clear the reveal before scroll runs.
    fileprivate func applyPendingReveal(in groups: [RowGroup]) {
        guard let key = store.pendingRevealRowKey, !key.isEmpty else { return }
        // Clear filters so the target row is not hidden by search.
        query = ""
        searchActive = false
        filterPhase = ""
        filterOutcome = ""
        filterAgentRaw = ""
        if let group = groups.first(where: { $0.rows.contains(where: { $0.rowKey == key }) }),
           group.foldable {
            folded.remove(group.id)
        }
        // Expand the glance if the target sits past the default window.
        if !store.snapshot.rows.contains(where: { $0.rowKey == key }),
           store.allRowsForDisplay.contains(where: { $0.rowKey == key }),
           !store.showAllAgents {
            store.toggleShowAllAgents()
            // Defer selection until the next layout with the expanded list.
            return
        }
        let visible = visibleRows(groups)
        guard visible.contains(where: { $0.rowKey == key }) else { return }
        selectedKey = key
        listFocused = true
        store.clearPendingRevealRowKey()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if searchActive || !query.isEmpty || hasSessionFilters {
                VStack(alignment: .leading, spacing: 6) {
                    TextField(store.tr(.searchSessions), text: $query)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                    if hasSessionFilters || !query.isEmpty {
                        HStack(spacing: 6) {
                            Text(String(format: store.tr(.allSessionsCount), store.allRowsForDisplay.count))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                            Spacer(minLength: 0)
                            if hasSessionFilters {
                                Button(store.tr(.filterClear)) {
                                    filterPhase = ""
                                    filterOutcome = ""
                                    filterAgentRaw = ""
                                }
                                .font(.system(size: 10.5))
                                .buttonStyle(.plain)
                            }
                        }
                        sessionFilterBar
                    }
                }
                .padding(.horizontal, TrayChrome.padX)
                .padding(.bottom, 8)
            }
            missedNotice
            maintenanceNotice

            if filteredRows.isEmpty {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !hasSessionFilters {
                    emptyState
                } else {
                    ContentUnavailableView(store.tr(.searchNoResults), systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 26)
                }
            } else {
                agentList
            }
        }
        .frame(width: TrayChrome.width)
        // StatusPanelController owns the rounded material surface. Content is
        // transparent and pinned to that surface's exact bounds: one owner,
        // one rect, no extra top or bottom inset.
        // Visibility is owned by StatusPanelController. A hosting view appears
        // when the hidden panel is constructed, not when the user opens it;
        // tying cadence to SwiftUI onAppear left the app in its 2 s foreground
        // probe mode permanently.
    }

    private var header: some View {
        // No lamp here.
        //
        // The menu-bar mark sits about 40px above this line, same shape, same
        // colour, driven by the same `glance`. The header's job is to say what
        // the rows cannot; repeating the thing the user just clicked on is the
        // opposite. The status word keeps the glance colour, which is the part
        // that carried information.
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 10) {
                HStack(spacing: 6) {
                    if store.isRefreshing {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    // Bigger, because it is now the only thing in the header.
                    // Dropping the 18pt mark was right — it restated the lamp
                    // the user had just clicked — but the padding stayed, and
                    // a 13pt label alone in a 40pt band reads as a leftover.
                    if store.isRefreshing {
                        Text(store.tr(.refreshing))
                            .foregroundStyle(.secondary)
                    } else if headerStates.isEmpty {
                        Text(headerTitle)
                            .foregroundStyle(store.snapshot.glance.lampColor)
                    } else {
                        ForEach(Array(headerStates.enumerated()), id: \.element.0) { index, item in
                            if index > 0 {
                                Text("·").foregroundStyle(.tertiary)
                            }
                            Text("\(item.1) \(headerLabel(item.0))")
                                .foregroundStyle(headerColor(item.0))
                                .monospacedDigit()
                        }
                    }
                }
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .lineLimit(1)
                Spacer(minLength: 0)

                HStack(alignment: .center, spacing: 4) {
                    TrayIconAction(
                        systemImage: "arrow.clockwise",
                        help: store.tr(.refresh),
                        shortcut: "r"
                    ) {
                        store.refresh(reason: "manual")
                    }
                    .disabled(store.isRefreshing)

                    Menu {
                        if store.needsWaitingSignalNudge {
                            Button(store.tr(.setupWaitingSignals)) {
                                store.openSettings(
                                    focusWaitingSignals: true,
                                    focusWaitingAgent: store.firstLiveWaitingNoneAgent
                                )
                            }
                            Divider()
                        }
                        if store.snapshot.rows.contains(where: \.waiting) {
                            Button(store.tr(.jumpToOldest)) { store.focusOldestWait() }
                            Button(store.tr(.clearWaiting)) { store.clearWaiting() }
                            Divider()
                        }
                        Button(store.tr(.searchSessions)) { searchActive = true }
                            .keyboardShortcut("f", modifiers: .command)
                        if !query.isEmpty {
                            Button(store.tr(.clearSearch)) { query = "" }
                        }
                        Button(store.tr(.supportHealth)) { store.openSupportHealth() }
                        Button(store.tr(.settings)) { store.openSettings() }
                            .keyboardShortcut(",", modifiers: .command)
                        Button("\(store.tr(.copyDiagnostics)) · \(PulseVersion.about)") {
                            store.copyDiagnostics()
                        }
                        Divider()
                        Button(store.tr(.quit)) { store.quit() }
                            .keyboardShortcut("q", modifiers: .command)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(
                                width: TrayChrome.headerControlSize,
                                height: TrayChrome.headerControlSize,
                                alignment: .center
                            )
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(
                        width: TrayChrome.headerControlSize,
                        height: TrayChrome.headerControlSize,
                        alignment: .center
                    )
                    .help(store.tr(.moreActions))
                    .accessibilityLabel(store.tr(.moreActions))
                }
                .frame(height: TrayChrome.headerControlSize, alignment: .center)
            }

            if !store.isRefreshing, !headerDetail.isEmpty {
                Text(headerDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, TrayChrome.padX)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private var headerTitle: String {
        let t = store.snapshot.headerTitle
        return t.isEmpty ? store.snapshot.header : t
    }

    private var headerDetail: String {
        store.snapshot.headerDetail
    }

    private var headerStates: [(TraySection, Int)] {
        // Search/filter counts the matching window. The default header must
        // use the fleet totals so a 12-row glance cannot report "9 running"
        // when 15 sessions are live.
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || hasSessionFilters
        return TraySection.allCases.compactMap { section in
            let count: Int
            if searching {
                count = filteredRows.filter { $0.section == section }.count
            } else {
                count = store.snapshot.sectionTotals[section] ?? 0
            }
            return count > 0 ? (section, count) : nil
        }
    }

    private var hasSessionFilters: Bool {
        !filterPhase.isEmpty || !filterOutcome.isEmpty || !filterAgentRaw.isEmpty
    }

    private var sessionFilterBar: some View {
        HStack(spacing: 6) {
            filterMenu(
                title: store.tr(.agents),
                selection: $filterAgentRaw,
                options: Array(Set(store.allRowsForDisplay.map(\.agent.rawValue))).sorted()
            )
            filterMenu(
                title: store.tr(.filterPhase),
                selection: $filterPhase,
                options: Array(Set(store.allRowsForDisplay.map(\.phase).filter { !$0.isEmpty })).sorted()
            )
            filterMenu(
                title: store.tr(.filterOutcome),
                selection: $filterOutcome,
                options: Array(Set(store.allRowsForDisplay.map(\.outcome).filter { !$0.isEmpty })).sorted()
            )
        }
    }

    private func filterMenu(title: String, selection: Binding<String>, options: [String]) -> some View {
        Menu {
            Button(store.tr(.supportFilterAll)) { selection.wrappedValue = "" }
            ForEach(options, id: \.self) { option in
                Button(option) { selection.wrappedValue = option }
            }
        } label: {
            Text(selection.wrappedValue.isEmpty ? title : "\(title): \(selection.wrappedValue)")
                .font(.system(size: 10.5))
                .lineLimit(1)
        }
    }

    private var filteredRows: [AgentRow] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [AgentRow]
        if text.isEmpty && !hasSessionFilters {
            base = store.snapshot.rows
        } else {
            // Search/filter walk the full retain index (up to 500/agent), not
            // the twelve-row glance window.
            base = store.allRowsForDisplay
        }
        return base.filter { row in
            if !filterAgentRaw.isEmpty, row.agent.rawValue != filterAgentRaw { return false }
            if !filterPhase.isEmpty, row.phase != filterPhase { return false }
            if !filterOutcome.isEmpty, row.outcome != filterOutcome { return false }
            guard !text.isEmpty else { return true }
            return [
                row.agent.displayName, row.agent.rawValue, row.task, row.project,
                row.cwd, row.sessionID, row.tool, row.skill, row.phase,
                row.outcome, row.model, row.mode,
            ].contains { $0.localizedCaseInsensitiveContains(text) }
        }
    }

    private func headerLabel(_ section: TraySection) -> String {
        switch section {
        case .needsYou: return store.tr(.waitingN)
        case .running: return store.tr(.runningN)
        case .stalled: return store.tr(.sectionStalled).lowercased()
        case .recent: return store.tr(.recentN)
        }
    }

    private func headerColor(_ section: TraySection) -> Color {
        switch section {
        case .needsYou: return GlanceKind.waiting.lampColor
        case .running: return GlanceKind.running.lampColor
        case .stalled: return GlanceKind.stalled.lampColor
        case .recent: return .secondary
        }
    }

    /// The panel only ever showed the present moment. Coming back to it, the
    /// first question is what happened while you were gone (0.93 Look Closure).
    @ViewBuilder
    private var missedNotice: some View {
        if !store.lookContinuityNotice.isEmpty {
            Button { store.activateLookContinuity() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 11))
                    Text(store.lookContinuityNotice)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .opacity(0.55)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, TrayChrome.padX)
                .padding(.bottom, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(store.tr(.lookClosureHint))
        } else if store.missedWhileAway > 0 {
            Button { store.activateLookContinuity() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 11))
                    Text(String(format: store.tr(.whileAway), store.missedWhileAway))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .opacity(0.55)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, TrayChrome.padX)
                .padding(.bottom, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else if let incomplete = store.trayScanIncompleteNotice {
            Button { store.openSupportHealth() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.system(size: 11))
                    Text(store.tr(.trayScanIncomplete))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .opacity(0.55)
                }
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .padding(.horizontal, TrayChrome.padX)
                .padding(.bottom, 10)
                .contentShape(Rectangle())
                .accessibilityLabel(incomplete)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var maintenanceNotice: some View {
        if let notice = store.maintenanceNoticeText {
            Button { store.performMaintenanceNoticeAction() } label: {
                HStack(spacing: 7) {
                    Image(systemName: store.waitingNotificationNeedsSetup
                        ? "bell.badge"
                        : "exclamationmark.circle")
                        .font(.system(size: 11, weight: .medium))
                    Text(notice)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .opacity(0.55)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(store.waitingNotificationNeedsSetup ? .red : .orange)
                .padding(.horizontal, TrayChrome.padX)
                .padding(.bottom, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(store.tr(.settings))
        }
    }

    /// Empty is the first thing most people see. Say what Pulse is waiting for
    /// and give the one action that makes Waiting work, instead of a dead end.
    private var emptyState: some View {
        VStack(spacing: 10) {
            PulseMarkView(size: 40, tone: Color.secondary.opacity(0.45))
            Text(store.tr(.noAgentsDetected))
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(store.tr(.emptyHint))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(store.tr(.setupWaitingSignals)) {
                store.openSettings(
                    focusWaitingSignals: true,
                    focusWaitingAgent: store.firstLiveWaitingNoneAgent
                )
            }
            .buttonStyle(.link)
            .font(.system(size: 11, weight: .medium))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 20)
    }

    /// A tray group: heading, count, and its rows.
    fileprivate struct RowGroup: Identifiable {
        var id: String
        var title: String
        var count: Int
        var accent: Bool
        var rows: [AgentRow]
        /// The heading is a location, so rows underneath must not repeat it.
        var statesPath = false
        /// The heading doubles as a disclosure control when the user chooses
        /// to fold the otherwise-visible rows.
        var foldable = false
        /// Not a project — the bucket for rows that have no location at all.
        var isBucket = false
    }

    /// A heading earns its line only when it separates things.
    fileprivate func showHeading(_ group: RowGroup, of groups: [RowGroup]) -> Bool {
        guard groups.count > 1 else { return false }
        // Grouping by project produced "~/Documents/Cursor 1" over exactly one
        // row whose own second line said "~/Documents/Cursor". Two lines, one
        // fact, and a whole row of height spent on it.
        if group.rows.count == 1 { return false }
        return true
    }

    /// Sentinel for "this row has no location", kept out of the localized
    /// strings so the grouping key does not change with the language.
    fileprivate static let bucketKey = "\u{0}no-project"

    /// Rows grouped under a heading.
    ///
    /// The list was sorted by urgency but rendered as one flat stack, so five
    /// rows read as five equals. A heading costs one line and answers "which of
    /// these actually need me" before any row is read.
    ///
    /// Grouping by project is the alternative for people running several repos
    /// at once; a project containing a wait sorts first, so the urgent case
    /// still surfaces without reading every heading.
    fileprivate var groupedRows: [RowGroup] {
        let rows = filteredRows
        switch store.trayGrouping {
        case .status:
            let present = TraySection.allCases.filter { s in rows.contains { $0.section == s } }
            return present.map { section in
                let group = rows.filter { $0.section == section }
                let fleet = store.snapshot.sectionTotals[section] ?? group.count
                return RowGroup(
                    id: "s\(section.rawValue)",
                    title: store.tr(section.titleKey),
                    count: fleet,
                    accent: section == .needsYou,
                    rows: group,
                    foldable: TrayFold.foldable(
                        section: section,
                        groupCount: present.count,
                        rowCount: group.count,
                        totalRows: rows.count
                    )
                )
            }
        case .project:
            var order: [String] = []
            var byProject: [String: [AgentRow]] = [:]
            for row in rows {
                // Key on the real location. Falling back to the agent name made
                // headings that restated the row beneath them ("Amp 1" over a
                // row whose only content was Amp).
                let path = row.displayPath
                // Home is not a project; everything without a real location
                // shares one bucket instead of inventing names for it.
                let key = path.isEmpty ? Self.bucketKey : path
                if byProject[key] == nil { order.append(key) }
                byProject[key, default: []].append(row)
            }
            // Projects with something waiting float up; ties keep row order.
            let ranked = order.enumerated().sorted { a, b in
                let aWait = byProject[a.element]?.contains(where: \.waiting) ?? false
                let bWait = byProject[b.element]?.contains(where: \.waiting) ?? false
                if aWait != bWait { return aWait && !bWait }
                return a.offset < b.offset
            }
            return ranked.map { entry in
                let group = byProject[entry.element] ?? []
                let hasWaiting = group.contains(where: \.waiting)
                let bucket = entry.element == Self.bucketKey
                return RowGroup(
                    id: "p\(entry.element)",
                    title: bucket ? store.tr(.noProject) : entry.element,
                    count: group.count,
                    accent: hasWaiting,
                    rows: group,
                    statesPath: true,
                    // Project grouping exists for people running several repos,
                    // and was the one mode where nothing folded: a flat list of
                    // every project, however many. A project with a wait in it
                    // is never folded away.
                    foldable: TrayFold.foldableProject(
                        hasWaiting: hasWaiting,
                        groupCount: ranked.count,
                        rowCount: group.count,
                        totalRows: rows.count
                    ),
                    isBucket: bucket
                )
            }
        }
    }

    private var agentList: some View {
        // Height comes from the content now. It used to be a hand-summed
        // estimate (44 + 20 - 4 + 14 + 28 + 8) that any font or spacing change
        // silently invalidated — the panel and its contents disagreed and there
        // was no way to notice except by looking.
        // 420 pt regularly orphaned the next group heading at the bottom
        // ("Recent 1" with no row), which reads like missing data rather than
        // scrollable content. The wait row is intentionally information-rich
        // (reason, signal, age, and two actions), so a short cap cut the next
        // session in half even when only seven rows existed. Keep the default
        // glance tall enough for complete rows; scrolling remains the guard
        // for large workspaces.
        let cap: CGFloat = store.showAllAgents ? 700 : 660

        let groups = groupedRows
        return VStack(spacing: 0) {
            ScrollViewReader { scrollProxy in
                ScrollView {
                // Not pinned.
                //
                // A pinned heading has to be opaque so rows can scroll under
                // it, and every opaque thing laid over the panel's material
                // compounds with it into a lighter band — which is what both
                // 0.27.1 and 0.27.2 showed, whichever material was used. A
                // panel that caps at a handful of rows gains nothing from
                // sticky headings, and un-pinning removes the band by
                // construction rather than by picking a better shade.
                // At most twelve rows are visible. A LazyVStack inside a
                // ScrollView reports the viewport proposal rather than its
                // materialised content height on some macOS builds, pinning
                // the list to the 420 pt cap and leaving a large empty tail.
                // A regular stack is cheap at this scale and measures exactly.
                VStack(spacing: 0) {
                    ForEach(groups) { group in
                        Section {
                            // No rules between rows: whitespace already
                            // separates them, and a line every 56pt turns a
                            // short list into a table.
                            if !(group.foldable && TrayFold.isCollapsed(group.id, manuallyFolded: folded)) {
                                ForEach(group.rows) { row in
                                    AgentRowButton(
                                        row: row,
                                        store: store,
                                        pathInHeading: group.statesPath && showHeading(group, of: groups),
                                        selected: selectedKey == row.rowKey,
                                        compact: filteredRows.count >= TrayFold.crowdedFrom
                                    )
                                    .id(row.rowKey)
                                    .transition(.opacity)
                                }
                            }
                        } header: {
                            // A lone heading restates the panel header directly
                            // above it — "2 running / Cursor · Amp" followed by
                            // "Running 2". Headings earn their line only when
                            // there is more than one group to tell apart, and a
                            // heading over a single row is just that row's own
                            // path on a line of its own.
                            if showHeading(group, of: groups) {
                                let isFolded = group.foldable
                                    && TrayFold.isCollapsed(group.id, manuallyFolded: folded)
                                SectionHeader(
                                    title: group.title,
                                    count: group.count,
                                    accent: group.accent,
                                    collapsed: group.foldable ? isFolded : nil,
                                    summary: isFolded ? TrayFold.summary(group.rows) : "",
                                    toggle: group.foldable ? { toggleFold(group.id) } : nil,
                                    showCount: !(isFolded && TrayFold.summaryNamesEveryRow(group.rows))
                                )
                            }
                        }
                    }
                }
                // Rows fade rather than pop. A list that rebuilds itself every
                // two seconds otherwise makes "a session appeared" and "the
                // order changed" look identical.
                .animation(.easeOut(duration: 0.16), value: store.snapshot.rows.map(\.rowKey))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                    }
                )
                }
                .scrollIndicators(.visible)
                .frame(height: min(max(measuredHeight, 56), cap))
                .onPreferenceChange(ContentHeightKey.self) { measuredHeight = $0 }
                // Do not paint a bottom fade over the material. It reads as a
                // second horizontal chrome band on a short popover and was the
                // same visual failure as the old system container bars. The
                // native scroll indicator already communicates overflow without
                // introducing another surface or stealing contrast from the
                // final row.
                // The panel is usually summoned by a shortcut, so the hand is
                // already on the keyboard; finishing with the mouse is the awkward
                // part. Arrow keys walk the visible rows, Return focuses the
                // terminal, Escape gives up.
                .focusable()
                // Keep arrow/Return navigation without drawing AppKit's blue
                // focus ring around the ScrollView. The rounded panel clips
                // that ring into a stray horizontal blue rule and two edge
                // fragments, which looks like broken panel chrome.
                .focusEffectDisabled()
                .focused($listFocused)
                .onAppear { listFocused = true }
                .onKeyPress(.downArrow) { moveSelection(1, in: groups); return .handled }
                .onKeyPress(.upArrow) { moveSelection(-1, in: groups); return .handled }
                .onKeyPress(.return) { activateSelection(groups); return .handled }
                .onKeyPress(.escape) { selectedKey = nil; return .handled }
                .onKeyPress(.space) {
                    // Space folds whichever group owns the selection — the fold
                    // control is a heading, and headings are not in the tab order.
                    guard let key = selectedKey,
                          let group = groups.first(where: { g in
                              g.foldable && g.rows.contains { $0.rowKey == key }
                          })
                    else { return .ignored }
                    toggleFold(group.id)
                    return .handled
                }
                .onChange(of: selectedKey) { _, key in
                    guard let key else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        scrollProxy.scrollTo(key, anchor: .center)
                    }
                }
                .onAppear { applyPendingReveal(in: groups) }
                .onChange(of: store.pendingRevealRowKey) { _, _ in
                    applyPendingReveal(in: groups)
                }
                .onChange(of: store.showAllAgents) { _, _ in
                    applyPendingReveal(in: groups)
                }
                .onChange(of: store.snapshot.totalCount) { _, _ in
                    applyPendingReveal(in: groups)
                }
            }

            if !query.isEmpty || hasSessionFilters {
                EmptyView()
            } else if store.snapshot.hiddenCount > 0 {
                overflowButton(
                    String(format: store.tr(.andMore), store.snapshot.hiddenCount)
                ) { store.toggleShowAllAgents() }
            } else if store.showAllAgents, store.snapshot.totalCount > SnapshotBuilder.maxVisibleRows {
                overflowButton(store.tr(.showLess)) { store.toggleShowAllAgents() }
            }

            // Sessions beyond the per-agent cap: say so rather than pretend
            // they do not exist. Always show the searchable total when expanded.
            if query.isEmpty, !hasSessionFilters {
                if store.snapshot.cappedSessions > 0 {
                    Text(String(format: store.tr(.cappedSessions), store.snapshot.cappedSessions))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, TrayChrome.padX)
                        .padding(.bottom, 4)
                }
                if store.snapshot.totalCount > SnapshotBuilder.maxVisibleRows {
                    Text(String(format: store.tr(.allSessionsCount), store.snapshot.totalCount))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, TrayChrome.padX)
                        .padding(.bottom, 8)
                }
            }
        }
    }

    private func overflowButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, TrayChrome.padX)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

}

// MARK: - Agent row

/// Give the whole row button semantics only when it can complete a real
/// navigation task. Observational rows remain readable content; they no longer
/// advertise a click that either did nothing or merely opened Finder.
private struct ConditionalRowButton<Content: View>: View {
    let actionable: Bool
    let action: () -> Void
    let content: Content

    init(
        actionable: Bool,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.actionable = actionable
        self.action = action
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if actionable {
            Button(action: action) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }
}

@MainActor
private struct AgentRowButton: View {
    let row: AgentRow
    /// Must be observed, not merely held.
    ///
    /// This was `let store: StatusStore`. The row's body reads `store.tr(...)`
    /// for its title and badge, but a plain `let` does not subscribe: when the
    /// language changed, `TrayPanel` re-rendered while every row kept the same
    /// `row` value and the same store *reference*, so SwiftUI saw identical
    /// inputs and skipped the child entirely. The result was a panel whose
    /// chrome was English and whose rows were still Chinese.
    @ObservedObject var store: StatusStore
    /// True when a project heading directly above already states this path, so
    /// the row must not repeat it. 0.25 wrote the rule "a fact appears once,
    /// row > heading > header" and then applied it only to the panel header —
    /// grouped by project, every path was printed twice.
    ///
    /// Declared after `store` because the memberwise initialiser takes
    /// arguments in declaration order, and the call site passes it last.
    var pathInHeading = false
    /// True when keyboard navigation has this row selected.
    var selected = false
    /// Preserve the core hierarchy when the list is crowded; only secondary
    /// execution context is sacrificed.
    var compact = false
    @State private var hovering = false

    private var highlight: Color {
        if selected { return Color.primary.opacity(0.10) }
        return hovering ? Color.primary.opacity(0.055) : .clear
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Keep the row action and its overflow menu as sibling controls.
            // Nesting Menu inside Button made a click on “…” bubble into the
            // primary focus action on macOS, especially when the menu was
            // revealed by keyboard focus rather than hover.
            ZStack(alignment: .topTrailing) {
                ConditionalRowButton(
                    actionable: row.canFocusTerminal,
                    action: { store.primaryAction(row) }
                ) {
                    HStack(
                        alignment: .top,
                        spacing: TrayChrome.iconToIdentityGap
                    ) {
                        // The icon and identity line share the same top edge.
                        // A former 3pt optical nudge made the icon visibly sink
                        // below the lamp/name line, especially in CJK mode.
                        AgentIconView(id: row.agent)

                        VStack(alignment: .leading, spacing: 2) {
                            // Agent identity is text, not an icon-recognition
                            // quiz. With the full 33-agent roster (ten of them
                            // Pulse-made), an
                            // icon alone cannot answer "which agent?".
                            HStack(
                                alignment: .center,
                                spacing: TrayChrome.identityLampToNameGap
                            ) {
                                Circle()
                                    .fill(statusIndicatorColor)
                                    .frame(
                                        width: TrayChrome.identityLampSize,
                                        height: TrayChrome.identityLampSize
                                    )
                                    // Reserve a stable identity-line slot so
                                    // the lamp stays optically centred while
                                    // the Agent/source labels vary in font.
                                    .frame(width: TrayChrome.identityLampSize, height: 18)
                                    .accessibilityHidden(true)
                                Text(row.agent.displayName)
                                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.secondary)
                                if let sourceLabel {
                                    Text(sourceLabel)
                                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                                        // Evidence labels are important state,
                                        // not decorative metadata. Tertiary
                                        // contrast made Privacy-limited and
                                        // Local cache disappear in light mode.
                                        .foregroundStyle(.secondary.opacity(0.78))
                                }
                                Spacer(minLength: 6)
                                statusChip
                            }

                            // Encoding 3 of 3: a real session is semibold, a
                            // bare process is not. The title no longer competes
                            // horizontally with age, state and the menu.
                            Text(heroTitle)
                                .font(.system(
                                    size: 13,
                                    weight: row.isProcessOnly ? .regular : .semibold,
                                    design: .rounded
                                ))
                                .foregroundStyle(.primary)
                                // Keep two lines for real session titles even when
                                // the list is crowded — the title tail is the
                                // identifying half. Process-only stays one line.
                                .lineLimit(row.isProcessOnly ? 1 : 2)
                                .fixedSize(horizontal: false, vertical: true)

                            // 0.91/0.92 Row Story — readable even when crowded.
                            if !storyLine.isEmpty {
                                Text(storyLine)
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(.primary.opacity(0.82))
                                    .lineLimit(2)
                                    .truncationMode(.tail)
                            }

                            if !contextLine.isEmpty {
                                Text(contextLine)
                                    .font(.system(size: 10.75))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(compact ? 1 : 2)
                                    .truncationMode(.middle)
                            }

                            // Motion only — Now / Changed / stalled age.
                            if !signalLine.isEmpty {
                                Text(signalLine)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }

                            // EXPERIENCE 观测行: model · tokens · progress — default,
                            // never Details-only. Disappears when empty (0.80).
                            if !observationLine.isEmpty {
                                Text(observationLine)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .lineLimit(compact ? 1 : 2)
                                    .truncationMode(.tail)
                            }

                            // Waiting rows get a third line, because the actual
                            // question is the entire point of the product.
                            if let detail = store.localizedWaitDetail(row) {
                                Text(Self.truncate(detail, 78))
                                    .font(.system(size: 11))
                                    .foregroundStyle(TrayChrome.waitAccent)
                                    .lineLimit(2)
                            }

                        }
                    }
                    .padding(.trailing, hasSecondaryActions ? TrayChrome.headerControlSize + 4 : 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, TrayChrome.rowLeadingInset)
                    .padding(.trailing, TrayChrome.padX)
                    .padding(.vertical, compact ? 5 : (row.isProcessOnly ? 6 : 7))
                    // The wait gutter overlays its own inset and never
                    // participates in layout. Waiting and non-waiting identity
                    // columns therefore remain exactly aligned.
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(accentFill)
                            .frame(width: accentWidth)
                            .padding(.leading, 6)
                            .padding(.vertical, 4)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityText)
                .accessibilityHint(
                    row.isProcessOnly
                        ? store.tr(.supportHealth)
                        : (row.canFocusTerminal ? store.primaryActionTitle(row) : "")
                )

                if hasSecondaryActions {
                    secondaryActionsMenu
                        .opacity(hovering || selected ? 1 : 0)
                        .allowsHitTesting(hovering || selected)
                        .accessibilityHidden(false)
                        .padding(.top, 6)
                        .padding(.trailing, TrayChrome.padX)
                }
            }

            // Actions stay visible where they are urgent, and appear on hover
            // everywhere else. Showing them on every row cost ~28pt each and
            // was the main reason only three agents fit in the panel.
            if showActions {
                HStack(spacing: 16) {
                    if row.waiting {
                        Button(store.tr(.dismissWait)) { store.dismissWaiting(row) }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11, weight: .medium))
                        // A countdown you cannot stop is a worse deal than no
                        // countdown, so the same button undoes it.
                        Button(row.isSnoozed ? store.tr(.snoozed) : store.tr(.snooze)) {
                            if row.isSnoozed { store.unsnooze(row) } else { store.snooze(row) }
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11, weight: .medium))
                    }
                    // Respond (scene AR): only on a remote row with a matched
                    // full request. Deny is safe from here; Allow lives only
                    // in Details next to the complete request text.
                    if store.respondRequest(for: row) != nil, !store.respondVerdictSent(row) {
                        Button(store.tr(.respondDeny)) { store.respondDeny(row) }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11, weight: .medium))
                        Button(store.tr(.respondReview)) { store.openRespond(row) }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11, weight: .medium))
                    } else if let fate = store.respondFateNote(row) {
                        // The receipt, on the row that asked. Without it a
                        // decided row simply goes quiet, which is the same
                        // silence 2.3 spent a version removing.
                        Text(fate)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if row.canFocusTerminal {
                        Button(store.focusActionTitle(row)) { store.focusTerminal(row) }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11, weight: .medium))
                    }
                    if row.isProcessOnly {
                        Button(store.tr(.supportHealth)) { store.openSupportHealth() }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11, weight: .medium))
                    }
                    if store.isWaitingNoneNeedsReach(row) {
                        Button(store.tr(.setupWaitingSignals)) {
                            store.openWaitingReach(for: row)
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11, weight: .medium))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 48)
                .padding(.trailing, TrayChrome.padX)
                .padding(.bottom, 8)
            }

            // What the last click actually did, when it did not do the thing.
            // A button that reached nothing and a button that is broken look
            // identical unless the row says which one happened.
            if let notice = store.rowActionNotice(row) {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 48)
                    .padding(.trailing, TrayChrome.padX)
                    .padding(.bottom, 8)
            }
        }
        // Inset rounded, not a full-bleed rectangle.
        //
        // Every native macOS list — Mail, the Finder sidebar, Notification
        // Centre — insets its hover and selection fill and rounds it. A
        // full-width square block that runs into both edges is the web
        // convention, and in a menu-bar panel it is the single easiest thing to
        // read as "not a Mac app".
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(highlight)
                .padding(.horizontal, 6)
        )
        .onHover { hovering = $0 }
        .contextMenu {
            secondaryActionItems
        }
    }

    /// The gutter is the loudest thing in the row, so a snoozed wait must not
    /// keep it. Everything else about the row stays put — the point is that it
    /// is still there, just not shouting.
    private var accentFill: Color {
        guard row.waiting else { return .clear }
        return row.isSnoozed ? TrayChrome.waitAccent.opacity(0.28) : TrayChrome.waitAccent
    }

    private var accentWidth: CGFloat {
        guard row.waiting else { return 0 }
        if row.isSnoozed { return 3 }
        return row.isUrgentWait ? 6 : 3
    }

    private var observationLine: String { store.rowObservationLine(row) }
    private var signalLine: String { store.rowSignalLine(row) }
    private var storyLine: String { store.rowStoryLine(row) }
    private var sourceLabel: String? { store.rowSourceLabel(row) }

    private var showActions: Bool {
        // Waiting-none Reach stays in the secondary menu; do not permanently
        // expand every non-Waiting live row (EXPERIENCE: action strip for Waiting).
        row.waiting || hovering
    }

    private var hasSecondaryActions: Bool {
        row.waiting || row.canFocusTerminal || row.isProcessOnly
            || store.isWaitingNoneNeedsReach(row)
    }

    /// A compact per-session lamp makes the state of every visible Agent
    /// scannable without opening Support Health. It is deliberately derived
    /// only from facts already present on the row: red = waiting/error, orange
    /// = limited or stalled, green = live with session evidence, gray = recent
    /// or unknown.
    private var statusIndicatorColor: Color {
        if row.waiting { return GlanceKind.waiting.lampColor }
        let outcome = row.outcome.lowercased()
        if row.isStalled || row.errors > 0
            || outcome.contains("fail") || outcome.contains("cancel") {
            return GlanceKind.error.lampColor
        }
        // A process is liveness evidence, not a session feed. Keep its lamp
        // orange so the tray agrees with Support Health's Limited disposition
        // instead of visually claiming that the row is fully observed.
        if row.isProcessOnly { return .orange }
        if row.liveProcess || row.isExplicitlyRunningPhase || row.subRunning > 0 {
            return GlanceKind.running.lampColor
        }
        return GlanceKind.idle.lampColor
    }

    /// Always-present action access for keyboard and VoiceOver users.
    ///
    /// Hover actions remain a fast pointer path, but are no longer the only
    /// route to focus or waiting controls.
    private var secondaryActionsMenu: some View {
        Menu {
            secondaryActionItems
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 20)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.08 : 0.045))
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(store.tr(.moreActions))
    }

    @ViewBuilder
    private var secondaryActionItems: some View {
        Button(store.tr(.details)) { store.openAgentDetail(row) }
        if row.waiting {
            Button(store.tr(.dismissWait)) { store.dismissWaiting(row) }
            Button(row.isSnoozed ? store.tr(.snoozed) : store.tr(.snooze)) {
                if row.isSnoozed { store.unsnooze(row) } else { store.snooze(row) }
            }
        }
        if row.canFocusTerminal {
            Button(store.focusActionTitle(row)) { store.focusTerminal(row) }
        }
        if row.isProcessOnly {
            Button(store.tr(.supportHealth)) { store.openSupportHealth() }
        }
        if store.isWaitingNoneNeedsReach(row) {
            Button(store.tr(.setupWaitingSignals)) {
                store.openWaitingReach(for: row)
            }
        }
    }

    /// Session title is the row hero; process-only rows de-rank to a status phrase.
    private var heroTitle: String {
        if row.waiting {
            if let t = row.usefulTask { return Self.truncate(t, Self.heroLimit) }
            let short = AgentRow.shortProject(row.project)
            if !short.isEmpty { return short }
            return store.tr(.needsYou)
        }
        if row.isProcessOnly {
            return row.canFocusTerminal
                ? store.tr(.terminalDetectedNoDetails)
                : store.tr(.appDetectedNoDetails)
        }
        if let t = row.usefulTask {
            return Self.truncate(t, Self.heroLimit)
        }
        // Humanize the live tool — never show update_plan / Bash raw.
        if let toolTitle = store.heroToolTitle(row) {
            return Self.truncate(toolTitle, Self.heroLimit)
        }
        let short = AgentRow.shortProject(row.project)
        if !short.isEmpty { return short }
        // Agent product name is already on the identity line — do not reuse it
        // as the hero (EXPERIENCE: no agent-as-hero).
        return row.canFocusTerminal ? store.tr(.terminalSession) : store.tr(.appSession)
    }

    /// Second line: where this session is, and how long since it moved.
    ///
    /// It used to be `Agent · project`, which restated the icon and — when the
    /// folder happened to match the agent — printed "Cursor · Cursor". The two
    /// facts a row could never state were *where* and *how long*; both were
    /// collected all along.
    private var contextLine: String {
        return store.rowContextLine(row, omitPath: pathInHeading)
    }

    /// Only abnormal states get a badge.
    ///
    /// Running was announced three times over — panel header, section header,
    /// and a green pill on every row. Running with a live session is the
    /// ordinary case, and the ordinary case does not need saying: **no badge
    /// means running**.
    @ViewBuilder
    private var statusChip: some View {
        if row.isSnoozed {
            // The row keeps its place and says why it is quiet. Hiding it would
            // make "Later" a button people are afraid to press.
            StatusChip(kind: .snoozed, label: store.snoozeLabel(row))
        } else if row.waiting {
            let kind = row.waitKind.isEmpty
                ? store.tr(.needsYou)
                : store.localizedWaitKind(row.waitKind)
            let dur = store.waitDurationLabel(row)
            StatusChip(
                kind: .waiting,
                label: dur.isEmpty ? kind : "\(kind) · \(dur)"
            )
        } else if row.isStalled {
            // Live for twenty minutes with nothing happening. Never surfaced
            // before, and it looked exactly like a healthy session.
            StatusChip(kind: .process, label: store.tr(.stalled))
        } else if store.lookMarkedWhileAway(row) {
            // Look Closure (0.93): session moved while the tray was closed.
            // Waiting / stalled chips win; this is only for quiet motion.
            StatusChip(kind: .recent, label: store.tr(.lookMovedMark))
        } else if row.subRunning > 0 {
            StatusChip(kind: .running, label: String(format: store.tr(.subChipActive), row.subRunning))
        } else if row.subTotal > 0 {
            StatusChip(kind: .running, label: String(format: store.tr(.subChipObserved), row.subTotal))
        } else if row.isRecentOnly {
            StatusChip(kind: .recent, label: store.tr(.recent))
        }
        // Live with a session and nothing unusual: no badge.
    }

    private var accessibilityText: String {
        var parts = [heroTitle, row.agent.displayName]
        let state: String
        if row.waiting {
            state = row.waitKind.isEmpty ? store.tr(.needsYou) : store.localizedWaitKind(row.waitKind)
        } else if row.isProcessOnly {
            state = store.tr(.limitedData)
        } else if row.isStalled {
            state = store.tr(.stalled)
        } else if row.isRecentOnly {
            state = store.tr(.recent)
        } else {
            state = store.tr(.running)
        }
        parts.append(state)
        if !storyLine.isEmpty { parts.append(storyLine) }
        // The tray line has room for "lost contact"; VoiceOver has room for
        // what it means, and a two-word state that cannot be unpacked is the
        // kind of thing this project keeps having to go back and fix.
        if row.lostContact { parts.append(store.tr(.remoteLostContactWhy)) }
        // There is no Focus button on a remote row. Silence would read as a
        // missing control rather than an absent capability.
        if row.isRemote { parts.append(store.tr(.remoteNoFocus)) }
        if !contextLine.isEmpty { parts.append(contextLine) }
        // Canonical dynamic summary — do not also append activityChange +
        // metrics; that duplicated Context / Changed facts for VoiceOver.
        if !signalLine.isEmpty { parts.append(signalLine) }
        if !observationLine.isEmpty, observationLine != signalLine {
            parts.append(observationLine)
        }
        if row.waiting {
            let line = store.localizedWaitLine(row)
            if !line.isEmpty { parts.append(line) }
        }
        return parts.joined(separator: ", ")
    }

    /// Hard ceiling on the row hero, in characters.
    ///
    /// It is a guard against a pathological title, not the thing that shapes
    /// the row — two lines at 400pt hold roughly eighty, so at 96 SwiftUI's
    /// own wrapping decides where the line ends and this only stops a title
    /// that would take the whole panel. It used to be 72, which is under what
    /// the panel can show: the string was cut before it was ever laid out.
    static let heroLimit = 96

    private static func truncate(_ s: String, _ n: Int) -> String {
        guard s.count > n else { return s }
        let cut = String(s.prefix(n - 1))
        // Cutting mid-word ("Review repository for bugs a…") reads as damage.
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > n / 2 {
            return String(cut[..<space]) + "…"
        }
        return cut + "…"
    }
}

/// Compact icon action for the tray's single action bar.
private struct TrayIconAction: View {
    let systemImage: String
    let help: String
    var shortcut: Character? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .frame(
                    width: TrayChrome.headerControlSize,
                    height: TrayChrome.headerControlSize,
                    alignment: .center
                )
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hovering ? Color.primary.opacity(0.08) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .modifier(OptionalShortcut(shortcut: shortcut))
    }
}

private struct OptionalShortcut: ViewModifier {
    let shortcut: Character?
    func body(content: Content) -> some View {
        if let shortcut {
            content.keyboardShortcut(KeyEquivalent(shortcut), modifiers: .command)
        } else {
            content
        }
    }
}

// MARK: - Settings
