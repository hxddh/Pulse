// The tray: a header that says why the lamp is lit, at most one notice, a
// list of one-line sessions in an order that holds still while it is open, a
// detail page one key away, and a footer with the keys. Every key goes
// through `TrayKeys.reduce` (the panel's key monitor calls `TrayUI.handle`);
// the faces here render values.

import SwiftUI
import AppKit

// MARK: - Tray chrome

enum TrayChrome {
    /// 360 lost the end of most session titles; 448 is forty characters of
    /// title instead of thirty, still narrow beside the system popovers.
    static let width: CGFloat = 448
    static let padX: CGFloat = PulseTheme.Space.l
    /// 21.0: the height the panel may grow to before the list scrolls. One
    /// number, read by the list and by `StatusPanelController` (which also
    /// clamps it to the screen).
    static let maxHeight: CGFloat = 760
    /// The list's share of it: the panel minus header, notice and footer.
    static let maxListHeight: CGFloat = maxHeight - 120
    /// The row's hover and selection fill is inset from the panel edge.
    static let highlightInset: CGFloat = PulseTheme.Space.s
    /// One hit target for every compact header control.
    static let headerControlSize: CGFloat = 28
    /// The row lamp's diameter.
    static let lampSize: CGFloat = 9
    /// Where a row's second line starts — under the agent's name, past the
    /// lamp and the icon (18) and their two gaps.
    static let oneLineTextStart: CGFloat = lampSize + PulseTheme.Space.s + 18 + PulseTheme.Space.s
    /// The most an agent's name or a project may take from the headline.
    static let identityMaxWidth: CGFloat = 112
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
/// resets every piece of per-view state (hover, measured height).
@MainActor
struct TrayPanelHost: View {
    var store: StatusStore
    var ui: TrayUI

    var body: some View {
        TrayPanel(store: store, ui: ui)
            .id(store.traySessionToken)
    }
}

@MainActor
struct TrayPanel: View {
    var store: StatusStore
    var ui: TrayUI
    @State private var measuredHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(store: StatusStore, ui: TrayUI) {
        self.store = store
        self.ui = ui
    }

    private func t(_ key: L10n.Key) -> String { store.tr(key) }

    var body: some View {
        ZStack(alignment: .top) {
            if let row = ui.detailRow {
                SessionDetailView(store: store, ui: ui, row: row)
                    .transition(.opacity)
            } else {
                list
                    .transition(.opacity)
            }
        }
        .frame(width: TrayChrome.width)
        // The one motion when the detail page opens or closes; the panel's
        // frame follows without an animation of its own.
        .animation(PulseTheme.motion(reduced: reduceMotion), value: ui.keys.detail)
    }

    private var list: some View {
        let rows = ui.displayRows
        return VStack(alignment: .leading, spacing: 0) {
            TrayHeaderFace(model: store.trayHeaderModel) { action in
                switch action {
                case .settings: store.openSettings()
                case .quit: store.quit()
                }
            }
            if let notice = store.trayNotice {
                TrayNoticeFace(model: notice) { store.performTrayNotice(notice.action) }
                    .padding(.horizontal, TrayChrome.highlightInset)
                    .padding(.bottom, PulseTheme.Space.s)
            }
            if rows.isEmpty {
                emptyState
            } else {
                agentList(rows)
            }
            footer(hasRows: !rows.isEmpty)
        }
    }

    // MARK: List

    private func agentList(_ rows: [AgentRow]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        TrayRowButton(
                            store: store,
                            ui: ui,
                            row: row,
                            selected: ui.keys.selected == row.rowKey
                        )
                        .id(row.rowKey)
                    }
                }
                .padding(.vertical, PulseTheme.Space.xxs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                    }
                )
            }
            .scrollIndicators(.automatic)
            .frame(height: min(max(measuredHeight, 40), CGFloat(ui.maxListHeight)))
            .onPreferenceChange(ContentHeightKey.self) { measuredHeight = $0 }
            .onChange(of: ui.keys.selected) { _, key in
                guard let key else { return }
                proxy.scrollTo(key)
            }
        }
    }

    // MARK: Footer

    /// What is not on screen, then the keys — one quiet line each.
    private func footer(hasRows: Bool) -> some View {
        VStack(alignment: .leading, spacing: PulseTheme.Space.xs) {
            if store.snapshot.hiddenCount > 0 {
                Button {
                    store.toggleShowAllAgents()
                } label: {
                    Text(String(format: t(.andMore), store.snapshot.hiddenCount))
                        .font(PulseTheme.Font.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else if store.showAllAgents, store.snapshot.totalCount > TrayState.maxVisibleRows {
                Button {
                    store.toggleShowAllAgents()
                } label: {
                    Text(t(.showLess))
                        .font(PulseTheme.Font.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if store.snapshot.staleHidden > 0 {
                // Sessions that went quiet within the last day and left the
                // list for age — said, not silently dropped.
                Text(String(
                    format: t(.staleHidden),
                    store.snapshot.staleHidden,
                    L10n.joinNames(store.snapshot.staleHiddenAgents.prefix(3).map(\.displayName), store.lang)
                ))
                .font(PulseTheme.Font.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
            if hasRows {
                Text(t(.trayKeyHints))
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, TrayChrome.padX)
        .padding(.top, PulseTheme.Space.xs)
        .padding(.bottom, PulseTheme.Space.s)
    }

    // MARK: Empty

    private var emptyState: some View {
        HStack(spacing: PulseTheme.Space.m) {
            PulseMarkView(size: 28, tone: .secondary)
            VStack(alignment: .leading, spacing: PulseTheme.Space.xxs) {
                Text(t(.noAgentsDetected))
                    .font(PulseTheme.Font.hero)
                Text(t(.emptyHint))
                    .font(PulseTheme.Font.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, TrayChrome.padX)
        .padding(.vertical, PulseTheme.Space.m)
    }
}

// MARK: - Header

/// One line: the counts in their tones. The ⋯ menu holds Settings and Quit;
/// ⌘R refreshes. Renders a `TrayHeaderModel`.
struct TrayHeaderFace: View {
    enum Action: Equatable { case settings, quit }

    let model: TrayHeaderModel
    var send: (Action) -> Void = { _ in }

    private func t(_ key: L10n.Key) -> String { L10n.t(key, model.lang) }

    var body: some View {
        HStack(alignment: .center, spacing: PulseTheme.Space.s) {
            summary
                .font(PulseTheme.Font.heading)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.numericText())
            Spacer(minLength: 0)
            Menu {
                Button(t(.settings)) { send(.settings) }
                Divider()
                Button(t(.quit)) { send(.quit) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(PulseTheme.Font.hero.weight(.regular))
                    .foregroundStyle(.secondary)
                    .frame(width: TrayChrome.headerControlSize, height: TrayChrome.headerControlSize, alignment: .center)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: TrayChrome.headerControlSize, height: TrayChrome.headerControlSize, alignment: .center)
            .accessibilityLabel(t(.moreActions))
        }
        .padding(.horizontal, TrayChrome.padX)
        .padding(.top, PulseTheme.Space.m)
        .padding(.bottom, PulseTheme.Space.s)
        .accessibilityElement(children: .contain)
    }

    private var summary: Text {
        guard !model.counts.isEmpty else { return Text(model.title).foregroundStyle(.primary) }
        let separator = Text("  ·  ").foregroundStyle(.tertiary)
        var text = Text("")
        for (index, count) in model.counts.enumerated() {
            if index > 0 { text = text + separator }
            let numberColor: Color = count.tone == .idle ? .secondary : count.tone.color
            text = text
                + Text("\(count.count) ").foregroundStyle(numberColor).monospacedDigit()
                + Text(count.label).foregroundStyle(count.tone == .idle ? Color.secondary : Color.primary)
        }
        return text
    }
}

// MARK: - Notice

/// 21.0: the tray's one notice. 23.0: with its one action as a button.
struct TrayNoticeFace: View {
    let model: TrayNoticeModel
    var send: () -> Void = {}

    var body: some View {
        HStack(alignment: .center, spacing: PulseTheme.Space.s) {
            Image(systemName: model.systemImage)
                .foregroundStyle(model.tone == .idle ? Color.secondary : model.tone.color)
                .accessibilityHidden(true)
            Text(model.text)
                .font(PulseTheme.Font.body)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: PulseTheme.Space.s)
            Button(model.actionTitle, action: send)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, PulseTheme.Space.s)
        .padding(.vertical, PulseTheme.Space.xs + 2)
        .background(
            (model.tone == .idle ? Color.primary : model.tone.color)
                .opacity(model.tone == .idle ? PulseTheme.Fill.subtle : PulseTheme.Fill.waitTint),
            in: RoundedRectangle(cornerRadius: PulseTheme.Radius.card, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Agent row

/// The store-bound wrapper: builds the row's value, tracks the pointer, and
/// routes the row's intents through `TrayUI`.
@MainActor
private struct TrayRowButton: View {
    var store: StatusStore
    var ui: TrayUI
    let row: AgentRow
    var selected = false
    @State private var hovering = false

    var body: some View {
        TrayRowFace(
            model: store.trayRowModel(row),
            hovering: hovering,
            selected: selected
        ) { action in
            ui.send(action, row: row)
        }
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

/// The row's face: one line — lamp, agent, project, headline, age — and a
/// second line only for a blocked row (its ask) or an orange one (its why).
/// A click goes (the terminal, else the detail); the chevron that appears
/// under the pointer opens the detail. Renders a `TrayRowModel` and nothing
/// else, so a fixture can draw every state (`PulseQA`'s `SurfaceCapture`).
struct TrayRowFace: View {
    let model: TrayRowModel
    var hovering = false
    var selected = false
    var send: (TrayRowModel.Action) -> Void = { _ in }

    private var showsChevron: Bool { hovering || selected }

    var body: some View {
        VStack(alignment: .leading, spacing: PulseTheme.Space.xxs) {
            HStack(alignment: .center, spacing: PulseTheme.Space.xs) {
                Button { send(.primary) } label: { line }
                    .buttonStyle(.plain)
                Button { send(.details) } label: {
                    Image(systemName: "chevron.right")
                        .font(PulseTheme.Font.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(showsChevron ? 1 : 0)
                .allowsHitTesting(showsChevron)
            }
            if let second = model.secondLine {
                Text(second.text)
                    .font(PulseTheme.Font.body)
                    .foregroundStyle(second.kind == .warning
                        ? AnyShapeStyle(PulseTheme.Tone.attention.color)
                        : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, TrayChrome.oneLineTextStart)
                    .padding(.trailing, PulseTheme.Space.l)
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
        .contentShape(Rectangle())
        .contextMenu {
            ForEach(model.menu) { button in
                Button(button.title) { send(button.action) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityLabel)
        .accessibilityHint(model.accessibilityHint)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { send(.primary) }
        .accessibilityActions {
            ForEach(model.menu) { button in
                Button(button.title) { send(button.action) }
            }
        }
    }

    private var line: some View {
        HStack(alignment: .center, spacing: PulseTheme.Space.s) {
            LampShapeView(lamp: model.lamp, size: TrayChrome.lampSize)
            AgentIconView(id: model.agent)
            Text(model.agentName)
                .font(PulseTheme.Font.label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: TrayChrome.identityMaxWidth, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            if !model.project.isEmpty {
                Text(model.project)
                    .font(PulseTheme.Font.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: TrayChrome.identityMaxWidth, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Text(model.headline)
                .font(model.headlineQuiet ? PulseTheme.Font.heroQuiet : PulseTheme.Font.hero)
                .foregroundStyle(model.headlineQuiet ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let turn = model.turnLabel {
                Text(turn)
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            if model.muted {
                Image(systemName: "bell.slash")
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(.tertiary)
            }
            if !model.age.isEmpty {
                Text(model.age)
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(model.lamp.tone == .waiting ? AnyShapeStyle(PulseTheme.Tone.waiting.color) : AnyShapeStyle(.secondary))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .frame(minHeight: 22)
        .contentShape(Rectangle())
    }
}
