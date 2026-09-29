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

    // MARK: - 9.0 Craft · one type scale, one card chrome

    /// The row's type scale. Six ad-hoc point sizes had accreted across the
    /// row's lines; the scale names the role a line plays and every call
    /// site says which role it is, not which number it happened to like.
    /// (Fonts carry no appearance-dependent colour, so `static let` is safe
    /// here — the appearance gate's rule is about colour, not metrics.)
    static let heroSize: CGFloat = 13
    static let bodySize: CGFloat = 11
    static let captionSize: CGFloat = 10.5
    static let microSize: CGFloat = 9.5
    static func heroFont(processOnly: Bool) -> Font {
        .system(size: heroSize, weight: processOnly ? .regular : .semibold, design: .rounded)
    }
    /// Narration — the row's human sentence.
    static let storyFont: Font = .system(size: bodySize, weight: .medium, design: .rounded)
    /// Dense fact lines: work, observation, signal.
    static let detailFont: Font = .system(size: captionSize, weight: .medium)
    /// The secondary where/when line.
    static let contextFont: Font = .system(size: 10.75)
    /// Inline row verbs (dismiss / snooze / focus / open …).
    static let actionFont: Font = .system(size: bodySize, weight: .medium)
    static let identityNameFont: Font = .system(size: captionSize, weight: .semibold, design: .rounded)
    static let sourceLabelFont: Font = .system(size: microSize, weight: .medium, design: .rounded)

    /// Card chrome: every in-list and expanded card shares one radius family
    /// and one padding rhythm, so the popup reads as a single system instead
    /// of four slightly different boxes.
    static let cardRadius: CGFloat = 8
    static let innerRadius: CGFloat = 6
    static let cardPadding: CGFloat = 10
    static let cardSpacing: CGFloat = 8
}

struct StatusChip: View {
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
    static let defaultValue: CGFloat = 0
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
                    .font(TrayChrome.storyFont)
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
    /// 7.0-β: rows opened in place. Keys, not indices — the list reorders
    /// under live scans and an index would expand a different session.
    @State fileprivate var expandedRowKeys: Set<String> = []
    @FocusState fileprivate var listFocused: Bool

    fileprivate func toggleExpanded(_ key: String) {
        withAnimation(PulseTheme.motion) {
            if expandedRowKeys.contains(key) {
                expandedRowKeys.remove(key)
            } else {
                expandedRowKeys.insert(key)
            }
        }
    }

    fileprivate func toggleFold(_ id: String) {
        // A panel that repaints itself every couple of seconds cannot afford
        // hard cuts: a block of rows appearing instantly is indistinguishable
        // from a reorder, and you re-read the whole list to find out which it
        // was. Short and flat — this is a menu-bar panel, not a launch screen.
        withAnimation(PulseTheme.motion) {
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
        // A reveal means "I need to deal with this row" — arrive with the
        // in-place card already open (scene BM).
        expandedRowKeys.insert(key)
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
                    // 16.0: finished sessions nobody has looked at. A count,
                    // in the quiet colour — the red lamp stays for blocked.
                    if !store.isRefreshing, store.snapshot.turnCount > 0 {
                        Text("·").foregroundStyle(.tertiary)
                        Text(String(format: store.tr(.turnCount), store.snapshot.turnCount))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
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
                        } else if store.snapshot.turnCount > 0 {
                            Button(store.tr(.jumpToTurn)) { store.focusNextTurn() }
                            Divider()
                        }
                        Button(store.tr(.searchSessions)) { searchActive = true }
                            .keyboardShortcut("f", modifiers: .command)
                        if !query.isEmpty {
                            Button(store.tr(.clearSearch)) { query = "" }
                        }
                        // 3.0-β: the workbench — the tray answers "who needs
                        // me", the window answers everything after that.
                        Button(store.tr(.openWorkbench)) { store.openWorkbench() }
                            .keyboardShortcut("w", modifiers: [.command, .shift])
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
                        .font(TrayChrome.actionFont)
                    Text(notice)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .opacity(0.55)
                }
                .font(TrayChrome.actionFont)
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
            .font(TrayChrome.actionFont)
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
                                        compact: filteredRows.count >= TrayFold.crowdedFrom,
                                        expanded: expandedRowKeys.contains(row.rowKey),
                                        onToggleExpand: { toggleExpanded(row.rowKey) }
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
                .animation(PulseTheme.motion, value: store.snapshot.rows.map(\.rowKey))
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
                .font(TrayChrome.storyFont)
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
struct ConditionalRowButton<Content: View>: View {
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
    /// 7.0-β: the row opens in place. State lives in `TrayPanel` (a set of
    /// row keys), not here — rows are recreated on every scan and `@State`
    /// would forget the user's click within seconds.
    var expanded = false
    var onToggleExpand: (() -> Void)?
    @State private var hovering = false

    /// 11.0-α: a dead turn is a needs-you state — the recovery box rides
    /// the in-list cards like an ask does.
    private var needsRecovery: Bool {
        switch store.managedRunner(for: row)?.model.status {
        case .interrupted, .failed: return true
        default: return false
        }
    }

    private var needsYou: Bool {
        row.waiting
            || !store.managedPermissionRequests(for: row).isEmpty
            || needsRecovery
    }

    /// The row's default depth before any click (scene BV).
    private var depthTier: RowDepth.Tier {
        RowDepth.tier(
            expanded: expanded,
            needsYou: needsYou,
            live: row.liveProcess || row.isExplicitlyRunningPhase,
            crowded: compact
        )
    }

    private var highlight: Color {
        if selected { return Color.primary.opacity(0.10) }
        return hovering ? Color.primary.opacity(0.055) : .clear
    }

    /// 17.0: the face is a value; this wrapper builds it and carries out
    /// what it asks for.
    private var model: TrayRowModel { store.trayRowModel(row) }

    private func perform(_ action: TrayRowModel.Action) {
        switch action {
        case .primary: store.primaryAction(row)
        case .details: store.openAgentDetail(row)
        case .dismiss: store.dismissWaiting(row)
        case .snooze: store.snooze(row)
        case .unsnooze: store.unsnooze(row)
        case .respondDeny: store.respondDeny(row)
        case .respondReview: store.openRespond(row)
        case .focus: store.focusTerminal(row)
        case .supportHealth: store.openSupportHealth()
        case .setupWaiting: store.openWaitingReach(for: row)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TrayRowFace(
                model: model,
                hovering: hovering,
                selected: selected,
                expanded: expanded,
                compact: compact,
                onToggleExpand: onToggleExpand,
                send: perform
            )

            // 8.0-β inbox (scene BN): a blocked agent's ask is the popup's
            // highest-value content and must not cost a click — permission
            // cards, the Respond card and the managed reply live in the list
            // itself. The expanded card renders the same cards, never twice.
            // 11.0-α (scene BV): the digest tier — a live row's information
            // arrives without a click; the act surfaces stay behind the
            // chevron. Never beside an ask: the question owns that space.
            if depthTier == .digest,
               SessionBriefCard.hasContent(store: store, row: row) {
                SessionBriefCard(store: store, row: row)
                    .padding(.leading, 48)
                    .padding(.trailing, TrayChrome.padX)
                    .padding(.bottom, 8)
            }

            if !expanded {
                let asks = store.managedPermissionRequests(for: row)
                let inbound = row.waiting ? store.respondRequest(for: row) : nil
                // 10.0-γ (scene BU): the in-list card is for "needs you NOW"
                // only — a blocked ask or a turn that died. An idle managed
                // row's reply box lives behind expansion; a standing reply
                // box on every row was a wall, not an inbox.
                if !asks.isEmpty || inbound != nil || needsRecovery {
                    VStack(alignment: .leading, spacing: TrayChrome.cardSpacing) {
                        ForEach(asks, id: \.id) { request in
                            SessionPermissionCard(store: store, request: request, compact: true)
                        }
                        if let inbound {
                            SessionRespondCard(store: store, row: row, inbound: inbound, compact: true)
                        }
                        if needsRecovery {
                            SessionManagedReply(store: store, row: row, compact: true)
                        }
                    }
                    .padding(TrayChrome.cardPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: TrayChrome.cardRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: TrayChrome.cardRadius)
                            .strokeBorder(.quaternary, lineWidth: 1)
                    )
                    .padding(.leading, 48)
                    .padding(.trailing, TrayChrome.padX)
                    .padding(.bottom, 8)
                }
            }

            // 7.0-β: the in-place mini-inspector (scene BM). Same cards as
            // the workbench, compact face — understanding and acting no
            // longer require leaving the popup.
            if expanded {
                TrayExpandedCard(store: store, row: row)
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
    }

}

/// 17.0 · the row's face: renders a `TrayRowModel` and nothing else, so a
/// fixture can render every state of it (`SurfaceCapture`). Hover, selection
/// and expansion are inputs; every click is an action sent to the owner.
struct TrayRowFace: View {
    let model: TrayRowModel
    var hovering = false
    var selected = false
    var expanded = false
    var compact = false
    var onToggleExpand: (() -> Void)? = nil
    var send: (TrayRowModel.Action) -> Void = { _ in }

    private func t(_ key: L10n.Key) -> String { L10n.t(key, model.lang) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Keep the row action and its overflow menu as sibling controls.
            // Nesting Menu inside Button made a click on “…” bubble into the
            // primary focus action on macOS.
            ZStack(alignment: .topTrailing) {
                ConditionalRowButton(actionable: model.canPrimary, action: { send(.primary) }) {
                    HStack(alignment: .top, spacing: TrayChrome.iconToIdentityGap) {
                        AgentIconView(id: model.agent)
                        VStack(alignment: .leading, spacing: 2) {
                            identityLine
                            // A real session is semibold, a bare process is not.
                            Text(model.hero)
                                .font(TrayChrome.heroFont(processOnly: model.heroProcessOnly))
                                .foregroundStyle(.primary)
                                .lineLimit(model.heroProcessOnly ? 1 : 2)
                                .fixedSize(horizontal: false, vertical: true)
                            // ONE composed meta line; a fresh error keeps its
                            // own words — a fault changes what you do next.
                            if let error = model.errorLine, !expanded {
                                Text(error)
                                    .font(.system(size: TrayChrome.captionSize).monospaced())
                                    .foregroundStyle(.orange)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            } else if !model.metaLine.isEmpty {
                                Text(model.metaLine)
                                    .font(TrayChrome.detailFont)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            // The question itself is the point of the product.
                            if let detail = model.waitDetail {
                                Text(detail)
                                    .font(.system(size: TrayChrome.bodySize))
                                    .foregroundStyle(TrayChrome.waitAccent)
                                    .lineLimit(2)
                            }
                            // 17.0: open, the row says why it is in this state.
                            if expanded, let why = model.why {
                                Text(why)
                                    .font(TrayChrome.detailFont)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.trailing, model.hasSecondaryActions ? TrayChrome.headerControlSize + 4 : 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, TrayChrome.rowLeadingInset)
                    .padding(.trailing, TrayChrome.padX)
                    .padding(.vertical, compact ? 5 : (model.heroProcessOnly ? 6 : 7))
                    // The wait gutter overlays its own inset and never takes
                    // part in layout, so identity columns stay aligned.
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
                .accessibilityLabel(model.accessibilityLabel)
                .accessibilityHint(model.accessibilityHint)
                .help(model.why ?? "")

                HStack(spacing: 4) {
                    if onToggleExpand != nil { expandChevron }
                    if model.hasSecondaryActions {
                        menu
                            .opacity(hovering || selected ? 1 : 0)
                            .allowsHitTesting(hovering || selected)
                            .accessibilityHidden(false)
                    }
                }
                .padding(.top, 6)
                .padding(.trailing, TrayChrome.padX)
            }

            // Urgent actions stay visible; the rest appear on hover.
            if model.stripAlwaysVisible || hovering {
                HStack(spacing: 16) {
                    ForEach(model.strip) { button in
                        Button(button.title) { send(button.action) }
                            .buttonStyle(.borderless)
                            .font(TrayChrome.actionFont)
                    }
                    if let fate = model.fateNote {
                        Text(fate)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 48)
                .padding(.trailing, TrayChrome.padX)
                .padding(.bottom, 8)
            }

            if let notice = model.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 48)
                    .padding(.trailing, TrayChrome.padX)
                    .padding(.bottom, 8)
            }
        }
        .contextMenu { menuItems }
    }

    private var identityLine: some View {
        HStack(alignment: .center, spacing: TrayChrome.identityLampToNameGap) {
            Circle()
                .fill(lampColor)
                .frame(width: TrayChrome.identityLampSize, height: TrayChrome.identityLampSize)
                .frame(width: TrayChrome.identityLampSize, height: 18)
                .accessibilityHidden(true)
            Text(model.agentName)
                .font(TrayChrome.identityNameFont)
                .foregroundStyle(.secondary)
            if let source = model.sourceLabel {
                Text(source)
                    .font(TrayChrome.sourceLabelFont)
                    .foregroundStyle(.secondary.opacity(0.78))
            }
            Spacer(minLength: 6)
            if !model.accessoryTime.isEmpty {
                Text(model.accessoryTime)
                    .font(TrayChrome.detailFont)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            if let chip = model.chip {
                StatusChip(kind: chipKind(chip.kind), label: chip.label)
            }
        }
    }

    private var lampColor: Color {
        switch model.lamp {
        case .waiting: return GlanceKind.waiting.lampColor
        case .error: return GlanceKind.error.lampColor
        case .process: return .orange
        case .running: return GlanceKind.running.lampColor
        case .idle: return GlanceKind.idle.lampColor
        }
    }

    private func chipKind(_ kind: TrayRowModel.ChipKind) -> StatusChip.Kind {
        switch kind {
        case .waiting: return .waiting
        case .running: return .running
        case .recent: return .recent
        case .process: return .process
        case .snoozed: return .snoozed
        }
    }

    private var accentFill: Color {
        switch model.accent {
        case .none: return .clear
        case .snoozed: return TrayChrome.waitAccent.opacity(0.28)
        case .normal, .urgent: return TrayChrome.waitAccent
        }
    }

    private var accentWidth: CGFloat {
        switch model.accent {
        case .none: return 0
        case .snoozed, .normal: return 3
        case .urgent: return 6
        }
    }

    private var expandChevron: some View {
        Button {
            onToggleExpand?()
        } label: {
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 20)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(hovering || expanded ? 0.08 : 0.03))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t(expanded ? .trayCollapseRow : .trayExpandRow))
    }

    private var menu: some View {
        Menu {
            menuItems
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
        .accessibilityLabel(t(.moreActions))
    }

    @ViewBuilder
    private var menuItems: some View {
        ForEach(model.menu) { button in
            Button(button.title) { send(button.action) }
        }
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
