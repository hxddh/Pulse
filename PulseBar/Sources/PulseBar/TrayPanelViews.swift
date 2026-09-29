// 3.0-α: the tray scene, moved verbatim out of PulseApp.swift.
// Behavior-frozen split — the view layer gets one file per scene so the
// workbench (3.0-β) grows beside its siblings instead of inside a
// 3,000-line monolith.

import SwiftUI
import AppKit

// MARK: - Tray chrome

enum TrayChrome {
    /// 360 lost the end of most session titles; 448 is forty characters of
    /// title instead of thirty, still narrow beside the system popovers.
    static let width: CGFloat = 448
    static let padX: CGFloat = PulseTheme.Space.l
    /// 21.0: the height the panel may grow to before the list scrolls. One
    /// number, read by the list and by `StatusPanelController`.
    static let maxHeight: CGFloat = 760
    /// The list's share of it: the panel minus header, notice and footer.
    static let maxListHeight: CGFloat = maxHeight - 120
    /// Shared identity grid for rows and headings, on the 4-pt grid: the
    /// icon at 16, the identity line and every card under a row at 44, the
    /// agent's name at 56.
    static let rowLeadingInset: CGFloat = PulseTheme.Space.l
    static let iconColumnWidth: CGFloat = 18
    static let iconToIdentityGap: CGFloat = 10
    static let identityLampSize: CGFloat = 6
    static let identityLampToNameGap: CGFloat = 6
    static let rowIdentityStart: CGFloat =
        rowLeadingInset + iconColumnWidth + iconToIdentityGap
    static let rowNameStart: CGFloat =
        rowIdentityStart + identityLampSize + identityLampToNameGap
    /// Cards, the action strip and notices under a row start where the
    /// row's text starts — one content column, not a column of their own.
    static let contentInset: CGFloat = rowIdentityStart
    /// The row's hover and selection fill is inset from the panel edge.
    static let highlightInset: CGFloat = PulseTheme.Space.s
    /// Section headers keep their title on the same column as Agent names.
    static let sectionAccentPrefix: CGFloat = rowIdentityStart - padX
    static let sectionHeaderLeadWidth: CGFloat =
        rowNameStart - padX - 8
    /// One hit target for every compact header action.
    static let headerControlSize: CGFloat = 28
    /// The row's trailing controls (disclosure + ⋯): reserved in layout so
    /// they never sit on top of the time and chip.
    static let rowControlSize = CGSize(width: 22, height: 20)
    static let rowControlsWidth: CGFloat = rowControlSize.width * 2 + PulseTheme.Space.xs
    static var waitAccent: Color { PulseTheme.Tone.waiting.color }
    static var runAccent: Color { PulseTheme.Tone.running.color }

    // MARK: Type — the row's roles, on PulseTheme's semantic scale

    static func heroFont(processOnly: Bool) -> Font {
        processOnly ? PulseTheme.Font.heroQuiet : PulseTheme.Font.hero
    }
    /// Narration — the row's human sentence.
    static let storyFont: Font = PulseTheme.Font.bodyEmphasis
    /// Dense fact lines: work, observation, signal.
    static let detailFont: Font = PulseTheme.Font.body
    /// Inline row verbs.
    static let actionFont: Font = PulseTheme.Font.bodyEmphasis
    static let identityNameFont: Font = PulseTheme.Font.label
    static let sourceLabelFont: Font = PulseTheme.Font.caption

    /// Card chrome: the tray shares PulseTheme's family.
    static let cardRadius: CGFloat = PulseTheme.Radius.card
    static let innerRadius: CGFloat = PulseTheme.Radius.inner
    static let cardPadding: CGFloat = PulseTheme.Space.m
    static let cardSpacing: CGFloat = PulseTheme.Space.s
}

struct StatusChip: View {
    enum Kind { case waiting, running, recent, process, snoozed }

    let kind: Kind
    let label: String

    var body: some View {
        PulseChip(label: label, tone: tone, muted: kind == .snoozed)
    }

    /// 21.0: a chip is in its state's tone — a stalled chip is orange like
    /// its lamp, not grey.
    private var tone: PulseTheme.Tone {
        switch kind {
        case .waiting, .snoozed: return .waiting
        case .running: return .running
        case .process: return .attention
        case .recent: return .idle
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
    var lang: ResolvedLanguage = .en

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
                        Image(systemName: "chevron.right")
                            .font(PulseTheme.Font.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(collapsed ? 0 : 90))
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
                .font(PulseTheme.Font.heading)
                .foregroundStyle(.secondary)
            // "No project 2 Pi · Amp" — two names and a 2. The count only
            // earns its place when the names do not already give it.
            if showCount {
                Text("\(count)")
                    .font(PulseTheme.Font.heading)
                    .monospacedDigit()
                    .foregroundStyle(accent ? TrayChrome.waitAccent : Color.secondary)
            }
            if !summary.isEmpty {
                Text(summary)
                    .font(PulseTheme.Font.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, TrayChrome.padX)
        .padding(.top, PulseTheme.Space.m)
        .padding(.bottom, PulseTheme.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)

        if let toggle {
            Button(action: toggle) { line.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityValue(summary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHint(collapsed == true ? L10n.t(.trayExpandRow, lang) : L10n.t(.trayCollapseRow, lang))
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
    var store: StatusStore

    var body: some View {
        TrayPanel(store: store)
            .id(store.traySessionToken)
    }
}

@MainActor
struct TrayPanel: View {
    var store: StatusStore
    @State fileprivate var measuredHeight: CGFloat = 0
    /// Folding is opt-in and per-panel. A fresh glance shows every row; the
    /// header must never claim five sessions while the list silently shows one.
    @State fileprivate var folded: Set<String> = []
    @State fileprivate var query = ""
    @State fileprivate var searchActive = false
    @State fileprivate var filterAgentRaw = ""

    /// Row key the keyboard has selected, if any.
    @State fileprivate var selectedKey: String?
    /// 7.0-β: rows opened in place. Keys, not indices — the list reorders
    /// under live scans and an index would expand a different session.
    @State fileprivate var expandedRowKeys: Set<String> = []
    @FocusState fileprivate var listFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    fileprivate func toggleExpanded(_ key: String) {
        withAnimation(PulseTheme.motion(reduced: reduceMotion)) {
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
        withAnimation(PulseTheme.motion(reduced: reduceMotion)) {
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
                searchBar
            }
            notice

            if filteredRows.isEmpty {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !hasSessionFilters {
                    if store.snapshot.glance == .error {
                        cantRefreshState
                    } else {
                        emptyState
                    }
                } else {
                    ContentUnavailableView(store.tr(.searchNoResults), systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, PulseTheme.Space.xl)
                }
            } else {
                agentList
            }
        }
        .frame(width: TrayChrome.width)
        // StatusPanelController owns the rounded surface. Content is
        // transparent and pinned to that surface's exact bounds. Visibility
        // is owned by the controller too: a hosting view appears when the
        // hidden panel is constructed, not when the user opens it.
    }

    // MARK: Header

    private var header: some View {
        // No lamp here: the menu-bar mark sits 40px above, same shape, same
        // colour. 21.0: the header is the fleet in counts — one capsule per
        // state in that state's tone — and the line under it says how fresh
        // they are. Section headings no longer repeat the counts.
        VStack(alignment: .leading, spacing: PulseTheme.Space.xs) {
            HStack(alignment: .center, spacing: PulseTheme.Space.s) {
                if headerStates.isEmpty, store.snapshot.turnCount == 0 {
                    Text(headerTitle)
                        .font(PulseTheme.Font.title)
                        .foregroundStyle(store.snapshot.glance == .error
                            ? PulseTheme.Tone.attention.color : Color.primary)
                        .lineLimit(1)
                } else {
                    HStack(spacing: PulseTheme.Space.xs) {
                        ForEach(headerStates, id: \.0) { item in
                            HeaderCount(
                                count: item.1,
                                label: headerLabel(item.0),
                                tone: headerTone(item.0)
                            )
                        }
                        // 16.0: finished sessions nobody has looked at — a
                        // count in the quiet tone; red stays for blocked.
                        if store.snapshot.turnCount > 0 {
                            HeaderCount(
                                count: store.snapshot.turnCount,
                                label: store.tr(.yourTurn),
                                tone: .idle
                            )
                        }
                    }
                }
                Spacer(minLength: 0)

                HStack(alignment: .center, spacing: PulseTheme.Space.xxs) {
                    TrayIconAction(
                        systemImage: "arrow.clockwise",
                        help: store.tr(.refresh),
                        shortcut: "r",
                        busy: store.isRefreshing
                    ) {
                        store.refresh(reason: "manual")
                    }
                    .disabled(store.isRefreshing)
                    moreMenu
                }
                .frame(height: TrayChrome.headerControlSize, alignment: .center)
            }
            freshnessLine
        }
        .padding(.horizontal, TrayChrome.padX)
        .padding(.top, PulseTheme.Space.m)
        .padding(.bottom, PulseTheme.Space.s)
    }

    private var moreMenu: some View {
        Menu {
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
            // 3.0-β: the workbench — the tray answers "who needs me", the
            // window answers everything after that.
            Button(store.tr(.openWorkbench)) { store.openWorkbench() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            Divider()
            Button(store.tr(.supportHealth)) { store.openSupportHealth() }
            Button(store.tr(.settings)) { store.openSettings() }
                .keyboardShortcut(",", modifiers: .command)
            Divider()
            Button(store.tr(.quit)) { store.quit() }
                .keyboardShortcut("q", modifiers: .command)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(PulseTheme.Font.hero.weight(.regular))
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

    /// 21.0: how fresh the counts are. "Updated 3 s ago · every 5 s" ticks
    /// on its own (SwiftUI's relative date), so it costs the store nothing;
    /// with live updates off it says so instead of looking current.
    @ViewBuilder
    private var freshnessLine: some View {
        let detail = headerDetail
        HStack(spacing: PulseTheme.Space.xs) {
            if !detail.isEmpty {
                Text(detail)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Text("·")
            }
            if !store.autoProbe {
                Text(store.tr(.probePaused))
                    .foregroundStyle(PulseTheme.Tone.attention.color)
            } else if store.snapshot.updatedAt != .distantPast, store.snapshot.glance != .error {
                // "Updated %@ ago" / "%@前更新": the relative date is a live
                // Text, so the format is split around its slot.
                let parts = store.tr(.freshAgo).components(separatedBy: "%@")
                (Text(parts.first ?? "")
                    + Text(store.snapshot.updatedAt, style: .relative)
                    + Text(parts.count > 1 ? parts[1] : ""))
                    .monospacedDigit()
                    .environment(\.locale, store.lang == .zh ? Locale(identifier: "zh-Hans") : Locale(identifier: "en"))
                    .lineLimit(1)
                Text("·")
                Text(store.probeIntervalDescription)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .font(PulseTheme.Font.caption)
        .foregroundStyle(.secondary)
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

    private func headerLabel(_ section: TraySection) -> String {
        switch section {
        case .needsYou: return store.tr(.waitingN)
        case .running: return store.tr(.runningN)
        case .stalled: return store.tr(.sectionStalled).lowercased()
        case .recent: return store.tr(.recentN)
        }
    }

    private func headerTone(_ section: TraySection) -> PulseTheme.Tone {
        switch section {
        case .needsYou: return .waiting
        case .running: return .running
        case .stalled: return .attention
        case .recent: return .idle
        }
    }

    // MARK: Search

    private var hasSessionFilters: Bool {
        !filterAgentRaw.isEmpty
    }

    private var searchBar: some View {
        HStack(spacing: PulseTheme.Space.s) {
            TextField(store.tr(.searchSessions), text: $query)
                .textFieldStyle(.roundedBorder)
                .font(PulseTheme.Font.body)
                // Escape clears the search before it closes the panel.
                .onExitCommand {
                    query = ""
                    filterAgentRaw = ""
                    searchActive = false
                    listFocused = true
                }
            Menu {
                Button(store.tr(.supportFilterAll)) { filterAgentRaw = "" }
                ForEach(Array(Set(store.allRowsForDisplay.map(\.agent))).sorted { $0.displayName < $1.displayName }, id: \.self) { agent in
                    Button(agent.displayName) { filterAgentRaw = agent.rawValue }
                }
            } label: {
                Text(AgentID(rawValue: filterAgentRaw)?.displayName ?? store.tr(.agents))
                    .font(PulseTheme.Font.body)
                    .lineLimit(1)
            }
            .fixedSize()
            if !query.isEmpty || hasSessionFilters {
                Text(String(format: store.tr(.allSessionsCount), filteredRows.count))
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, TrayChrome.padX)
        .padding(.bottom, PulseTheme.Space.s)
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
            guard !text.isEmpty else { return true }
            return [
                row.agent.displayName, row.agent.rawValue, row.task, row.project,
                row.cwd, row.sessionID, row.tool, row.skill, row.phase,
                row.outcome, row.model, row.mode,
            ].contains { $0.localizedCaseInsensitiveContains(text) }
        }
    }

    // MARK: Notice

    /// 21.0: one notice at a time, in one component. Up to three bars used
    /// to stack under the header, each hand-built. The order is what the
    /// person most needs to act on: something broken on this Mac, then a
    /// scan that did not finish, then what happened while they were away.
    private var noticeModel: TrayNotice.Model? {
        if let text = store.maintenanceNoticeText {
            return .init(
                text: text,
                systemImage: store.waitingNotificationNeedsSetup ? "bell.badge" : "exclamationmark.circle",
                tone: store.waitingNotificationNeedsSetup ? .waiting : .attention,
                action: { store.performMaintenanceNoticeAction() }
            )
        }
        if let incomplete = store.trayScanIncompleteNotice {
            return .init(
                text: store.tr(.trayScanIncomplete),
                systemImage: "clock.badge.exclamationmark",
                tone: .attention,
                accessibility: incomplete,
                action: { store.openSupportHealth() }
            )
        }
        if !store.lookContinuityNotice.isEmpty {
            return .init(
                text: store.lookContinuityNotice,
                systemImage: "clock.arrow.circlepath",
                tone: .idle,
                accessibility: store.tr(.lookClosureHint),
                action: { store.activateLookContinuity() }
            )
        }
        if store.missedWhileAway > 0 {
            return .init(
                text: String(format: store.tr(.whileAway), store.missedWhileAway),
                systemImage: "clock.arrow.circlepath",
                tone: .idle,
                action: { store.activateLookContinuity() }
            )
        }
        return nil
    }

    @ViewBuilder
    private var notice: some View {
        if let model = noticeModel {
            TrayNotice(model: model)
                .padding(.horizontal, TrayChrome.highlightInset)
                .padding(.bottom, PulseTheme.Space.s)
        }
    }

    // MARK: Empty and failed

    /// 21.0: empty is the first thing most people see, so it is a setup
    /// checklist computed from what is actually true on this Mac — not a
    /// link into the Attention-bridge developer tools.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: PulseTheme.Space.m) {
            HStack(spacing: PulseTheme.Space.m) {
                PulseMarkView(size: 32, tone: .secondary)
                VStack(alignment: .leading, spacing: PulseTheme.Space.xxs) {
                    Text(store.tr(.noAgentsDetected))
                        .font(PulseTheme.Font.hero)
                    Text(store.tr(.emptyHint))
                        .font(PulseTheme.Font.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(spacing: 0) {
                SetupStep(
                    title: store.tr(.setupNotifications),
                    detail: store.tr(.setupNotificationsDetail),
                    done: store.notifyAuthorized == true,
                    actionTitle: store.notifyAuthorized == false
                        ? store.tr(.openNotificationSettings) : store.tr(.enableNotifications)
                ) {
                    if store.notifyAuthorized == false {
                        store.openSystemNotificationSettings()
                    } else {
                        store.requestNotificationAuthorization()
                    }
                }
                Divider().padding(.leading, 28)
                SetupStep(
                    title: store.tr(.settingsHooksTitle),
                    detail: store.tr(.setupHooksDetail),
                    done: store.hooksInstalled,
                    actionTitle: store.tr(.installHooks)
                ) { store.installHooks() }
                Divider().padding(.leading, 28)
                SetupStep(
                    title: store.tr(.agentDataAccess),
                    detail: store.tr(.setupAppDataDetail),
                    done: store.allowAppData || !store.appDataAgents.isEmpty,
                    actionTitle: store.tr(.setupChoose)
                ) {
                    store.openSettings(focusAppDataFor: store.protectedAppDataAgents.first)
                }
            }
            .pulseCard(padding: PulseTheme.Space.s)
            Button(store.tr(.setupOtherAgents)) {
                store.openSettings(focusWaitingSignals: true)
            }
            .buttonStyle(.link)
            .font(PulseTheme.Font.body)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, TrayChrome.padX)
        .padding(.top, PulseTheme.Space.xs)
        .padding(.bottom, PulseTheme.Space.l)
    }

    /// Probe and harvest both failed. This used to fall through to "No
    /// coding agents detected" under a "Can't refresh" header — two
    /// contradicting sentences and no way forward.
    private var cantRefreshState: some View {
        VStack(spacing: PulseTheme.Space.s) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .font(PulseTheme.Font.title)
                .foregroundStyle(PulseTheme.Tone.attention.color)
                .accessibilityHidden(true)
            Text(store.tr(.cantRefresh))
                .font(PulseTheme.Font.hero)
            Text(store.tr(.cantRefreshHint))
                .font(PulseTheme.Font.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: PulseTheme.Space.s) {
                Button(store.tr(.supportRetry)) { store.refresh(reason: "cant-refresh-retry") }
                    .buttonStyle(.borderedProminent)
                Button(store.tr(.supportHealth)) { store.openSupportHealth() }
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PulseTheme.Space.xl)
        .padding(.horizontal, PulseTheme.Space.xl)
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
        let cap: CGFloat = TrayChrome.maxListHeight

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
                                    // 21.0: the header already counts each
                                    // state; a heading counts only what it
                                    // has folded away.
                                    showCount: isFolded && !TrayFold.summaryNamesEveryRow(group.rows),
                                    lang: store.lang
                                )
                            }
                        }
                    }
                }
                // Rows fade rather than pop. A list that rebuilds itself every
                // two seconds otherwise makes "a session appeared" and "the
                // order changed" look identical.
                .animation(PulseTheme.motion(reduced: reduceMotion), value: store.snapshot.rows.map(\.rowKey))
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
                    withAnimation(PulseTheme.motion(reduced: reduceMotion)) {
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

            // What is not on screen, said once: sessions beyond the
            // per-agent cap and the searchable total, on one quiet line.
            if query.isEmpty, !hasSessionFilters, !footerFacts.isEmpty {
                Text(footerFacts.joined(separator: " · "))
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, TrayChrome.padX)
                    .padding(.bottom, PulseTheme.Space.s)
            }
        }
    }

    private var footerFacts: [String] {
        var facts: [String] = []
        if store.snapshot.totalCount > SnapshotBuilder.maxVisibleRows {
            facts.append(String(format: store.tr(.allSessionsCount), store.snapshot.totalCount))
        }
        if store.snapshot.cappedSessions > 0 {
            facts.append(String(format: store.tr(.cappedSessions), store.snapshot.cappedSessions))
        }
        if store.snapshot.staleHidden > 0 {
            let names = L10n.joinNames(store.snapshot.staleHiddenAgents.prefix(3).map(\.displayName), store.lang)
            facts.append(String(format: store.tr(.staleHidden), store.snapshot.staleHidden, names))
        }
        return facts
    }

    private func overflowButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(TrayChrome.storyFont)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, TrayChrome.padX)
                .padding(.vertical, PulseTheme.Space.s + 2)
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
    var store: StatusStore
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

    /// 19.0: the cards under the row are a value too.
    private var cards: RowCardModel { store.rowCardModel(row) }

    private func needsYou(_ cards: RowCardModel) -> Bool {
        row.waiting || !cards.permissions.isEmpty || cards.needsRecovery
    }

    /// The row's default depth before any click (scene BV).
    private func depthTier(_ cards: RowCardModel) -> RowDepth.Tier {
        RowDepth.tier(
            expanded: expanded,
            needsYou: needsYou(cards),
            live: row.liveProcess || row.isExplicitlyRunningPhase,
            crowded: compact
        )
    }

    private var highlight: Color {
        if selected { return Color.primary.opacity(PulseTheme.Fill.selected) }
        return hovering ? Color.primary.opacity(PulseTheme.Fill.hover) : .clear
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

    private func performCard(_ action: RowCardModel.Action) {
        store.performRowCard(action, row: row)
    }

    var body: some View {
        let cards = self.cards
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
            if depthTier(cards) == .digest, !cards.brief.isEmpty {
                BriefCardFace(model: cards.brief)
                    .padding(.leading, TrayChrome.contentInset)
                    .padding(.trailing, TrayChrome.padX)
                    .padding(.bottom, PulseTheme.Space.s)
            }

            // 10.0-γ (scene BU): the in-list card is for "needs you NOW"
            // only — a blocked ask or a turn that died. An idle managed
            // row's reply box lives behind expansion; a standing reply box
            // on every row was a wall, not an inbox.
            if !expanded, cards.hasAsks {
                RowAsksFace(model: cards, send: performCard)
                    .padding(.leading, TrayChrome.contentInset)
                    .padding(.trailing, TrayChrome.padX)
                    .padding(.bottom, PulseTheme.Space.s)
            }

            // 7.0-β: the in-place mini-inspector (scene BM). Same cards as
            // the workbench, compact face — understanding and acting no
            // longer require leaving the popup.
            if expanded {
                TrayExpandedFace(model: cards, send: performCard)
                    .padding(.leading, TrayChrome.contentInset)
                    .padding(.trailing, TrayChrome.padX)
                    .padding(.bottom, PulseTheme.Space.s)
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
            RoundedRectangle(cornerRadius: PulseTheme.Radius.card, style: .continuous)
                .fill(highlight)
                .padding(.horizontal, TrayChrome.highlightInset)
        )
        .onHover { hovering = $0 }
    }

}

/// 17.0 · the row's face: renders a `TrayRowModel` and nothing else, so a
/// fixture can render every state of it (`SurfaceCapture`). Hover, selection
/// and expansion are inputs; every click is an action sent to the owner.
///
/// 21.0 Clarity: one red carrier (the row's own tint plus its lamp and
/// chip, all in one tone), at most two visible verbs, trailing controls that
/// take part in layout, and nothing that changes the row's height under the
/// pointer.
struct TrayRowFace: View {
    let model: TrayRowModel
    var hovering = false
    var selected = false
    var expanded = false
    var compact = false
    var onToggleExpand: (() -> Void)? = nil
    var send: (TrayRowModel.Action) -> Void = { _ in }

    private func t(_ key: L10n.Key) -> String { L10n.t(key, model.lang) }

    /// Space the trailing controls occupy, reserved even while ⋯ is hidden
    /// so the time and chip never move under the pointer.
    private var controlsReserve: CGFloat {
        (onToggleExpand != nil || model.hasSecondaryActions)
            ? TrayChrome.rowControlsWidth + PulseTheme.Space.xs : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Keep the row action and its overflow menu as sibling controls.
            // Nesting Menu inside Button made a click on “…” bubble into the
            // primary focus action on macOS.
            ZStack(alignment: .topTrailing) {
                ConditionalRowButton(actionable: model.canPrimary, action: { send(.primary) }) {
                    HStack(alignment: .top, spacing: TrayChrome.iconToIdentityGap) {
                        AgentIconView(id: model.agent)
                        VStack(alignment: .leading, spacing: PulseTheme.Space.xxs) {
                            identityLine
                                .padding(.trailing, controlsReserve)
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
                                    .font(PulseTheme.Font.code)
                                    .foregroundStyle(PulseTheme.Tone.attention.color)
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
                            // In the primary colour: the row's tint and lamp
                            // already say "blocked"; the words are for reading.
                            if let detail = model.waitDetail {
                                Text(detail)
                                    .font(PulseTheme.Font.body)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                            }
                            // 17.0 / 21.0: the row says why it is in this
                            // state — open, or without a click for the states
                            // that least explain themselves.
                            if let why = model.why, expanded || model.whyInline {
                                Text(why)
                                    .font(PulseTheme.Font.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(expanded ? nil : 2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, TrayChrome.rowLeadingInset)
                    .padding(.trailing, TrayChrome.padX)
                    .padding(.vertical, compact ? 6 : PulseTheme.Space.s)
                    .contentShape(Rectangle())
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(model.accessibilityLabel)
                .accessibilityHint(model.accessibilityHint)
                // Every verb is reachable without a pointer.
                .accessibilityActions {
                    ForEach(model.menu) { button in
                        Button(button.title) { send(button.action) }
                    }
                }
                .help(model.why ?? "")

                HStack(spacing: PulseTheme.Space.xs) {
                    if model.hasSecondaryActions {
                        menu
                            .opacity(hovering || selected ? 1 : 0)
                            .allowsHitTesting(hovering || selected)
                            .accessibilityHidden(!(hovering || selected))
                    }
                    if onToggleExpand != nil { expandChevron }
                }
                .padding(.top, PulseTheme.Space.s - 1)
                .padding(.trailing, TrayChrome.padX)
            }

            // Only a wait has verbs outside the menu, and they are always
            // there — a row never grows under the pointer.
            if model.stripAlwaysVisible {
                HStack(spacing: PulseTheme.Space.s) {
                    ForEach(model.strip) { button in
                        Button(button.title) { send(button.action) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .font(TrayChrome.actionFont)
                    }
                    if let fate = model.fateNote {
                        Text(fate)
                            .font(PulseTheme.Font.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, TrayChrome.contentInset)
                .padding(.trailing, TrayChrome.padX)
                .padding(.bottom, PulseTheme.Space.s)
            } else if let fate = model.fateNote {
                Text(fate)
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, TrayChrome.contentInset)
                    .padding(.trailing, TrayChrome.padX)
                    .padding(.bottom, PulseTheme.Space.s)
            }

            if let notice = model.notice {
                Text(notice)
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(PulseTheme.Tone.attention.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, TrayChrome.contentInset)
                    .padding(.trailing, TrayChrome.padX)
                    .padding(.bottom, PulseTheme.Space.s)
            }
        }
        // The wait's surface: a quiet tint of the row in the waiting tone
        // replaces the old gutter bar, chip-red detail text and red border —
        // five red things became one.
        .background(
            RoundedRectangle(cornerRadius: PulseTheme.Radius.card, style: .continuous)
                .fill(waitTint)
                .padding(.horizontal, TrayChrome.highlightInset)
        )
        .contextMenu { menuItems }
    }

    private var waitTint: Color {
        switch model.accent {
        case .none, .snoozed: return .clear
        case .normal: return PulseTheme.Tone.waiting.color.opacity(PulseTheme.Fill.waitTint)
        case .urgent: return PulseTheme.Tone.waiting.color.opacity(PulseTheme.Fill.waitTintUrgent)
        }
    }

    private var identityLine: some View {
        HStack(alignment: .center, spacing: TrayChrome.identityLampToNameGap) {
            PulseLamp(tone: lampTone, size: TrayChrome.identityLampSize)
                .frame(width: TrayChrome.identityLampSize, height: 18)
            Text(model.agentName)
                .font(TrayChrome.identityNameFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let source = model.sourceLabel {
                Text(source)
                    .font(TrayChrome.sourceLabelFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: PulseTheme.Space.s)
            if !model.accessoryTime.isEmpty {
                Text(model.accessoryTime)
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            if let chip = model.chip {
                StatusChip(kind: chipKind(chip.kind), label: chip.label)
            }
        }
    }

    /// One tone per state, shared with the menu-bar lamp and the header.
    private var lampTone: PulseTheme.Tone {
        switch model.lamp {
        case .waiting: return .waiting
        case .error, .process: return .attention
        case .running: return .running
        case .idle: return .idle
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

    private var expandChevron: some View {
        Button {
            onToggleExpand?()
        } label: {
            Image(systemName: "chevron.down")
                .font(PulseTheme.Font.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 180 : 0))
                .frame(width: TrayChrome.rowControlSize.width, height: TrayChrome.rowControlSize.height)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(hovering || expanded ? PulseTheme.Fill.hover : 0))
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
                .font(PulseTheme.Font.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: TrayChrome.rowControlSize.width, height: TrayChrome.rowControlSize.height)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(PulseTheme.Fill.hover))
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
    /// 21.0: the refresh control shows its own progress instead of the
    /// header swapping its counts for "Refreshing…".
    var busy = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                        .font(PulseTheme.Font.hero.weight(.regular))
                }
            }
            .frame(
                width: TrayChrome.headerControlSize,
                height: TrayChrome.headerControlSize,
                alignment: .center
            )
            .background(
                RoundedRectangle(cornerRadius: PulseTheme.Radius.inner, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(PulseTheme.Fill.hover) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .modifier(OptionalShortcut(shortcut: shortcut))
    }
}

/// One count in the header, in its state's tone.
private struct HeaderCount: View {
    let count: Int
    let label: String
    let tone: PulseTheme.Tone

    var body: some View {
        HStack(spacing: PulseTheme.Space.xs) {
            Text("\(count)")
                .contentTransition(.numericText())
                .monospacedDigit()
            Text(label)
        }
        .font(PulseTheme.Font.heading)
        .foregroundStyle(tone == .idle ? AnyShapeStyle(.secondary) : AnyShapeStyle(tone.color))
        .padding(.horizontal, PulseTheme.Space.s)
        .padding(.vertical, 3)
        .background(
            (tone == .idle ? Color.primary : tone.color)
                .opacity(tone == .idle ? PulseTheme.Fill.hover : PulseTheme.Fill.chip),
            in: Capsule(style: .continuous)
        )
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// 21.0: the tray's one notice bar.
struct TrayNotice: View {
    struct Model {
        var text: String
        var systemImage: String
        var tone: PulseTheme.Tone
        var accessibility: String = ""
        var action: () -> Void
    }

    let model: Model
    @State private var hovering = false

    var body: some View {
        Button(action: model.action) {
            HStack(alignment: .firstTextBaseline, spacing: PulseTheme.Space.s) {
                Image(systemName: model.systemImage)
                    .foregroundStyle(tint)
                Text(model.text)
                    .foregroundStyle(model.tone == .idle ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(PulseTheme.Font.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(PulseTheme.Font.body)
            .padding(.horizontal, PulseTheme.Space.s)
            .padding(.vertical, PulseTheme.Space.s - 2)
            .background(
                RoundedRectangle(cornerRadius: PulseTheme.Radius.card, style: .continuous)
                    .fill(background)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(model.accessibility.isEmpty ? model.text : model.accessibility)
    }

    private var tint: Color {
        model.tone == .idle ? .secondary : model.tone.color
    }

    private var background: Color {
        let base = model.tone == .idle ? Color.primary : model.tone.color
        let amount = model.tone == .idle ? PulseTheme.Fill.subtle : PulseTheme.Fill.waitTint
        return base.opacity(hovering ? amount + PulseTheme.Fill.subtle : amount)
    }
}

/// One line of the first-run checklist: done, or the button that does it.
private struct SetupStep: View {
    let title: String
    let detail: String
    let done: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PulseTheme.Space.s) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? AnyShapeStyle(PulseTheme.Tone.running.color) : AnyShapeStyle(.tertiary))
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: PulseTheme.Space.xxs) {
                Text(title)
                    .font(PulseTheme.Font.bodyEmphasis)
                Text(detail)
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: PulseTheme.Space.s)
            if !done {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, PulseTheme.Space.s)
        .accessibilityElement(children: .combine)
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
