// 3.0-α: the tray scene, moved verbatim out of PulseApp.swift — the view
// layer gets one file per scene instead of a 3,000-line monolith.

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
    /// icon at 16, the identity line at 44, the agent's name at 56.
    static let rowLeadingInset: CGFloat = PulseTheme.Space.l
    static let iconColumnWidth: CGFloat = 18
    static let iconToIdentityGap: CGFloat = 10
    static let identityLampSize: CGFloat = 6
    static let identityLampToNameGap: CGFloat = 6
    static let rowIdentityStart: CGFloat =
        rowLeadingInset + iconColumnWidth + iconToIdentityGap
    static let rowNameStart: CGFloat =
        rowIdentityStart + identityLampSize + identityLampToNameGap
    /// The row's hover and selection fill is inset from the panel edge.
    static let highlightInset: CGFloat = PulseTheme.Space.s
    /// Section headers keep their title on the same column as Agent names.
    static let sectionAccentPrefix: CGFloat = rowIdentityStart - padX
    /// One hit target for every compact header action.
    static let headerControlSize: CGFloat = 28
    /// 22.0: where a row's second line starts — under the agent's name, past
    /// the lamp (8) and the icon (18) and their two gaps.
    static let oneLineTextStart: CGFloat = 8 + PulseTheme.Space.s + 18 + PulseTheme.Space.s
}

// MARK: - Tray panel

/// Measured height of the row list, so the panel is sized by its content.
private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Owns nothing but the tray's identity: re-identifying the subtree per open
/// resets every piece of per-glance state (filter, selection, detail).
@MainActor
struct TrayPanelHost: View {
    var store: StatusStore

    var body: some View {
        TrayPanel(store: store)
            .id(store.traySessionToken)
    }
}

/// 22.0 · Lamp — the tray is a list of one-line sessions in the lamp's own
/// order (needs you → running → your turn → recent), a detail view one key
/// away, and the keyboard for everything. No groups, no folds, no depth
/// tiers, no search bar: typing filters.
@MainActor
struct TrayPanel: View {
    var store: StatusStore
    @State fileprivate var measuredHeight: CGFloat = 0
    /// Type-to-filter, Spotlight style.
    @State fileprivate var query = ""
    @State fileprivate var selectedKey: String?
    /// The session shown in the detail view, if any.
    @State fileprivate var detailKey: String?
    @FocusState fileprivate var listFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var rows: [AgentRow] { filteredRows }

    fileprivate func moveSelection(_ delta: Int) {
        let rows = self.rows
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

    private var selectedRow: AgentRow? {
        guard let key = selectedKey else { return nil }
        return rows.first { $0.rowKey == key }
    }

    fileprivate func openDetail(_ key: String) {
        withAnimation(PulseTheme.motion(reduced: reduceMotion)) { detailKey = key }
    }

    fileprivate func closeDetail() {
        withAnimation(PulseTheme.motion(reduced: reduceMotion)) { detailKey = nil }
        listFocused = true
    }

    /// A reveal from a notification or the hotkey: select the row.
    fileprivate func applyPendingReveal() {
        guard let key = store.pendingRevealRowKey, !key.isEmpty else { return }
        query = ""
        if !store.snapshot.rows.contains(where: { $0.rowKey == key }),
           store.allRowsForDisplay.contains(where: { $0.rowKey == key }),
           !store.showAllAgents {
            store.toggleShowAllAgents()
            return
        }
        guard let row = rows.first(where: { $0.rowKey == key }) else { return }
        selectedKey = row.rowKey
        listFocused = true
        store.clearPendingRevealRowKey()
    }

    var body: some View {
        Group {
            if let key = detailKey, let row = store.allRowsForDisplay.first(where: { $0.rowKey == key }) {
                SessionDetailView(store: store, row: row, onBack: closeDetail)
                    .onKeyPress(.escape) { closeDetail(); return .handled }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                list
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(width: TrayChrome.width)
        .onChange(of: detailKey != nil || !query.isEmpty) { _, consumed in
            store.trayEscapeConsumed = consumed
        }
        .onAppear { store.trayEscapeConsumed = false }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !query.isEmpty { filterLine }
            notice
            if rows.isEmpty {
                if !query.isEmpty {
                    ContentUnavailableView(store.tr(.searchNoResults), systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, PulseTheme.Space.xl)
                } else if store.snapshot.glance == .error {
                    cantRefreshState
                } else {
                    emptyState
                }
            } else {
                agentList
            }
            footer
        }
    }

    // MARK: Header

    /// One line: the fleet in counts, each in its state's tone.
    private var header: some View {
        HStack(alignment: .center, spacing: PulseTheme.Space.s) {
            headerText
                .font(PulseTheme.Font.title)
                .lineLimit(1)
                .contentTransition(.numericText())
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
        .padding(.horizontal, TrayChrome.padX)
        .padding(.top, PulseTheme.Space.m)
        .padding(.bottom, PulseTheme.Space.s)
        .help(store.snapshot.tooltip)
    }

    private var headerText: Text {
        let totals = store.snapshot.sectionTotals
        var parts: [(Int, String, PulseTheme.Tone)] = []
        if let n = totals[.needsYou], n > 0 { parts.append((n, store.tr(.waitingN), .waiting)) }
        if let n = totals[.running], n > 0 { parts.append((n, store.tr(.runningN), .running)) }
        if let n = totals[.stalled], n > 0 { parts.append((n, store.tr(.sectionStalled).lowercased(), .attention)) }
        if store.snapshot.turnCount > 0 { parts.append((store.snapshot.turnCount, store.tr(.yourTurn).lowercased(), .idle)) }
        guard !parts.isEmpty else {
            let title = store.snapshot.headerTitle.isEmpty ? store.snapshot.header : store.snapshot.headerTitle
            return Text(title).foregroundStyle(store.snapshot.glance == .error
                ? PulseTheme.Tone.attention.color : Color.primary)
        }
        var text = Text("")
        for (index, part) in parts.enumerated() {
            if index > 0 { text = text + Text("  ·  ").foregroundStyle(.tertiary) }
            let color: Color = part.2 == .idle ? .secondary : part.2.color
            text = text + Text("\(part.0) ").foregroundStyle(color).monospacedDigit()
                + Text(part.1).foregroundStyle(part.2 == .idle ? Color.secondary : Color.primary)
        }
        return text
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
                .frame(width: TrayChrome.headerControlSize, height: TrayChrome.headerControlSize, alignment: .center)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: TrayChrome.headerControlSize, height: TrayChrome.headerControlSize, alignment: .center)
        .help(store.tr(.moreActions))
        .accessibilityLabel(store.tr(.moreActions))
    }

    // MARK: Filter

    private var filterLine: some View {
        HStack(spacing: PulseTheme.Space.s) {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(.secondary)
            Text(query)
                .font(PulseTheme.Font.bodyEmphasis)
            Spacer(minLength: 0)
            Text(String(format: store.tr(.filterMatches), rows.count))
                .font(PulseTheme.Font.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, TrayChrome.padX)
        .padding(.bottom, PulseTheme.Space.s)
    }

    private var filteredRows: [AgentRow] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return store.snapshot.rows }
        // Filtering walks every retained session, not the visible window.
        return store.allRowsForDisplay.filter { row in
            [
                row.agent.displayName, row.agent.rawValue, row.task, row.project,
                row.cwd, row.sessionID, row.tool, row.model,
            ].contains { $0.localizedCaseInsensitiveContains(text) }
        }
    }

    // MARK: Notice

    /// One notice at a time: something on this Mac needs fixing.
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

    // MARK: List

    private var agentList: some View {
        let rows = self.rows
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        AgentRowButton(
                            row: row,
                            store: store,
                            selected: selectedKey == row.rowKey,
                            onDetails: { openDetail(row.rowKey) }
                        )
                        .id(row.rowKey)
                        .transition(.opacity)
                    }
                }
                .animation(PulseTheme.motion(reduced: reduceMotion), value: rows.map(\.rowKey))
                .padding(.vertical, PulseTheme.Space.xxs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                    }
                )
            }
            .scrollIndicators(.automatic)
            .frame(height: min(max(measuredHeight, 40), TrayChrome.maxListHeight))
            .onPreferenceChange(ContentHeightKey.self) { measuredHeight = $0 }
            // The hand is usually on the keyboard (the panel is summoned by a
            // shortcut), so every verb has a key.
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onAppear {
                listFocused = true
                if selectedKey == nil { selectedKey = rows.first(where: \.waiting)?.rowKey }
                applyPendingReveal()
            }
            .onKeyPress(.downArrow) { moveSelection(1); return .handled }
            .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
            .onKeyPress(.rightArrow) {
                guard let key = selectedKey else { return .ignored }
                openDetail(key)
                return .handled
            }
            .onKeyPress(.return) {
                guard let row = selectedRow else { return .ignored }
                store.primaryAction(row)
                return .handled
            }
            .onKeyPress(.delete) {
                guard let row = selectedRow, row.waiting else { return .ignored }
                store.dismissWaiting(row)
                return .handled
            }
            .onKeyPress(.escape) {
                if !query.isEmpty { query = ""; return .handled }
                return .ignored
            }
            .onKeyPress(characters: .alphanumerics.union(.punctuationCharacters).union(.whitespaces), phases: .down) { press in
                // Plain typing filters; anything with ⌘ or ⌃ stays a shortcut.
                guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
                if query.isEmpty, press.characters == " " { return .ignored }
                query += press.characters
                selectedKey = filteredRows.first?.rowKey
                return .handled
            }
            .onChange(of: selectedKey) { _, key in
                guard let key else { return }
                withAnimation(PulseTheme.motion(reduced: reduceMotion)) {
                    proxy.scrollTo(key, anchor: .center)
                }
            }
            .onChange(of: store.pendingRevealRowKey) { _, _ in applyPendingReveal() }
            .onChange(of: store.showAllAgents) { _, _ in applyPendingReveal() }
        }
    }

    // MARK: Footer

    /// What is not on screen, then the keys — one quiet line each.
    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: PulseTheme.Space.xs) {
            if query.isEmpty, store.snapshot.hiddenCount > 0 {
                Button {
                    store.toggleShowAllAgents()
                } label: {
                    Text(String(format: store.tr(.andMore), store.snapshot.hiddenCount))
                        .font(PulseTheme.Font.bodyEmphasis)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else if query.isEmpty, store.showAllAgents, store.snapshot.totalCount > SnapshotBuilder.maxVisibleRows {
                Button {
                    store.toggleShowAllAgents()
                } label: {
                    Text(store.tr(.showLess))
                        .font(PulseTheme.Font.bodyEmphasis)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if query.isEmpty, !footerFacts.isEmpty {
                Text(footerFacts.joined(separator: " · "))
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(.secondary)
            }
            if !rows.isEmpty {
                Text(store.tr(.trayKeyHints))
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, TrayChrome.padX)
        .padding(.top, PulseTheme.Space.xs)
        .padding(.bottom, PulseTheme.Space.s)
    }

    private var footerFacts: [String] {
        var facts: [String] = []
        if store.snapshot.cappedSessions > 0 {
            facts.append(String(format: store.tr(.cappedSessions), store.snapshot.cappedSessions))
        }
        if store.snapshot.staleHidden > 0 {
            let names = L10n.joinNames(store.snapshot.staleHiddenAgents.prefix(3).map(\.displayName), store.lang)
            facts.append(String(format: store.tr(.staleHidden), store.snapshot.staleHidden, names))
        }
        return facts
    }

    // MARK: Empty and failed

    /// A setup checklist computed from what is actually true on this Mac.
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
                    title: store.tr(.setupTerminalFocus),
                    detail: store.tr(.setupTerminalFocusDetail),
                    done: store.allowTerminalAutomation,
                    actionTitle: store.tr(.setupTurnOn)
                ) {
                    store.allowTerminalAutomation = true
                    store.saveSettings()
                }
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
        .padding(.bottom, PulseTheme.Space.s)
    }

    /// Probe and harvest both failed: say so, with a way forward.
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
}

// MARK: - Agent row

/// Give the whole row button semantics only when it can complete a real
/// navigation task.
struct ConditionalRowButton<Content: View>: View {
    let actionable: Bool
    let action: () -> Void
    let content: Content

    init(actionable: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
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
    var store: StatusStore
    var selected = false
    var onDetails: () -> Void = {}
    @State private var hovering = false

    private var model: TrayRowModel { store.trayRowModel(row) }

    private func perform(_ action: TrayRowModel.Action) {
        switch action {
        case .primary: store.primaryAction(row)
        case .details: onDetails()
        case .dismiss: store.dismissWaiting(row)
        case .focus: store.focusTerminal(row)
        case .supportHealth: store.openSupportHealth()
        case .setupWaiting: store.openWaitingReach(for: row)
        case .mute: store.toggleMute(row.agent)
        }
    }

    var body: some View {
        TrayRowFace(
            model: model,
            hovering: hovering,
            selected: selected,
            send: perform
        )
        .background(
            RoundedRectangle(cornerRadius: PulseTheme.Radius.card, style: .continuous)
                .fill(selected
                    ? Color.primary.opacity(PulseTheme.Fill.selected)
                    : (hovering ? Color.primary.opacity(PulseTheme.Fill.hover) : .clear))
                .padding(.horizontal, TrayChrome.highlightInset)
        )
        .onHover { hovering = $0 }
    }
}

/// 22.0 · the row's face: one line — lamp, agent, project, task, time —
/// plus, only for a wait, the ask in the agent's words and at most two
/// verbs. Renders a `TrayRowModel` and nothing else, so a fixture can draw
/// every state (`SurfaceCapture`).
struct TrayRowFace: View {
    let model: TrayRowModel
    var hovering = false
    var selected = false
    var send: (TrayRowModel.Action) -> Void = { _ in }

    private func t(_ key: L10n.Key) -> String { L10n.t(key, model.lang) }

    private var secondLine: String? {
        if let ask = model.waitDetail { return ask }
        if model.lamp == .error, model.whyInline, let why = model.why { return why }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PulseTheme.Space.xxs) {
            ConditionalRowButton(actionable: true, action: {
                send(model.canPrimary ? .primary : .details)
            }) {
                HStack(alignment: .center, spacing: PulseTheme.Space.s) {
                    LampShapeView(shape: model.shape, tone: model.tone, size: 8)
                    AgentIconView(id: model.agent)
                    Text(model.agentName)
                        .font(PulseTheme.Font.label)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                    if !model.project.isEmpty {
                        Text(model.project)
                            .font(PulseTheme.Font.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    Text(model.hero)
                        .font(model.heroProcessOnly ? PulseTheme.Font.heroQuiet : PulseTheme.Font.hero)
                        .foregroundStyle(model.heroProcessOnly ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if model.lamp == .waiting, let chip = model.chip {
                        PulseChip(label: chip.label, tone: .waiting)
                    }
                    ZStack(alignment: .trailing) {
                        Text(model.accessoryTime)
                            .font(PulseTheme.Font.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .opacity(hovering || selected ? 0 : 1)
                        Image(systemName: "chevron.right")
                            .font(PulseTheme.Font.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .opacity(hovering || selected ? 1 : 0)
                    }
                    .frame(minWidth: 28, alignment: .trailing)
                }
                .frame(minHeight: 22)
                .contentShape(Rectangle())
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(model.accessibilityLabel)
            .accessibilityHint(model.accessibilityHint)
            .accessibilityActions {
                ForEach(model.menu) { button in
                    Button(button.title) { send(button.action) }
                }
            }
            .help(model.why ?? "")

            if let line = secondLine {
                HStack(alignment: .firstTextBaseline, spacing: PulseTheme.Space.s) {
                    Text(line)
                        .font(PulseTheme.Font.body)
                        .foregroundStyle(model.lamp == .waiting ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if model.stripAlwaysVisible {
                        ForEach(model.strip) { button in
                            Button(button.title) { send(button.action) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
                .padding(.leading, TrayChrome.oneLineTextStart)
            } else if model.stripAlwaysVisible {
                HStack(spacing: PulseTheme.Space.s) {
                    ForEach(model.strip) { button in
                        Button(button.title) { send(button.action) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, TrayChrome.oneLineTextStart)
            }
            if let note = model.notice {
                Text(note)
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, TrayChrome.oneLineTextStart)
            }
        }
        .padding(.horizontal, TrayChrome.padX)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: PulseTheme.Radius.card, style: .continuous)
                .fill(waitTint)
                .padding(.horizontal, TrayChrome.highlightInset)
        )
        .contextMenu {
            ForEach(model.menu) { button in
                Button(button.title) { send(button.action) }
            }
        }
    }

    private var waitTint: Color {
        switch model.accent {
        case .none: return .clear
        case .normal: return PulseTheme.Tone.waiting.color.opacity(PulseTheme.Fill.waitTint)
        case .urgent: return PulseTheme.Tone.waiting.color.opacity(PulseTheme.Fill.waitTintUrgent)
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
