// The tray: a header that says why the lamp is lit, at most one notice, a
// list of one-line sessions in an order that holds still while it is open
// (every session; it scrolls inside the panel's height), and a detail page
// one click or one key away. Every key goes
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
    /// The height the panel may grow to before the list scrolls. One
    /// number, read by the list and by `StatusPanelController` (which also
    /// clamps it to the screen).
    static let maxHeight: CGFloat = 760
    /// The list's share of it: the panel minus header, notice and margin.
    static let maxListHeight: CGFloat = maxHeight - 120
    /// The selected row's fill (the pointer's or the keyboard's) is inset
    /// from the panel edge.
    static let highlightInset: CGFloat = PulseTheme.Space.s
    /// One hit target for every compact header control.
    static let headerControlSize: CGFloat = 28
    /// The row lamp's diameter.
    static let lampSize: CGFloat = 9
    /// Where a row's second line starts — under the project and headline,
    /// past the lamp and the agent's icon (18) and their two gaps.
    static let oneLineTextStart: CGFloat = lampSize + PulseTheme.Space.s + 18 + PulseTheme.Space.s
    /// The most a project may take from the headline.
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
/// resets every piece of per-view state (the measured height).
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
                TrayNoticeFace(model: notice) { [store] action in store.performTrayNotice(action) }
                    .padding(.horizontal, TrayChrome.highlightInset)
                    .padding(.bottom, PulseTheme.Space.s)
            }
            if rows.isEmpty {
                emptyState
            } else {
                agentList(rows)
                    .padding(.bottom, PulseTheme.Space.s)
            }
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
                // Follow the keyboard, not the pointer.
                guard let key, key != ui.pointerSelection else { return }
                proxy.scrollTo(key)
            }
        }
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

/// The tray's one notice, with its one action as a button.
/// The setup card's remaining steps, one line each, under its text, and its
/// "Open at login" checkbox — unticked until the person ticks it.
struct TrayNoticeFace: View {
    let model: TrayNoticeModel
    /// Sendable: the checkbox's binding carries it.
    var send: @MainActor @Sendable (TrayNoticeModel.Action) -> Void = { _ in }

    @MainActor private var loginBinding: Binding<Bool> {
        let send = self.send
        let value = model.openAtLogin ?? false
        return Binding(get: { value }, set: { send(.setOpenAtLogin($0)) })
    }

    var body: some View {
        HStack(alignment: .center, spacing: PulseTheme.Space.s) {
            Image(systemName: model.systemImage)
                .foregroundStyle(model.tone == .idle ? Color.secondary : model.tone.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: PulseTheme.Space.xxs) {
                Text(model.text)
                    .font(PulseTheme.Font.body)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(model.steps, id: \.self) { step in
                    Text("· " + step)
                        .font(PulseTheme.Font.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.openAtLogin != nil {
                    Toggle(model.openAtLoginTitle, isOn: loginBinding)
                        .toggleStyle(.checkbox)
                        .font(PulseTheme.Font.caption)
                        .controlSize(.small)
                }
            }
            Spacer(minLength: PulseTheme.Space.s)
            Button(model.actionTitle) { send(model.action) }
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
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Agent row

/// The store-bound wrapper: builds the row's value and routes the row's
/// intents through `TrayUI`. The pointer entering a row selects it — one
/// highlight, as in a menu: the keyboard and the pointer move the same
/// selection.
@MainActor
private struct TrayRowButton: View {
    var store: StatusStore
    var ui: TrayUI
    let row: AgentRow
    var selected = false

    var body: some View {
        TrayRowFace(
            model: store.trayRowModel(row),
            selected: selected
        ) { action in
            ui.send(action, row: row)
        }
        .onHover { inside in
            if inside { ui.hover(row.rowKey, at: NSEvent.mouseLocation) }
        }
    }
}

/// The row's face: one line — lamp, icon, project, headline, time — and a
/// second line only for a blocked row (its ask), an orange one (its why) or
/// a running one whose hook named its last step (quietly).
/// The row's body, both lines, is one button: a click goes (the terminal,
/// else the detail). A "›" column at the trailing edge, as tall as the row
/// and always drawn, opens the detail; so does an ⌥-click anywhere on the
/// row (`TrayRowModel.clickAction`). The selected row — the pointer's or
/// the keyboard's — is the one highlight. The agent's name is not written
/// beside its icon — the icon says it, VoiceOver names it. Renders a
/// `TrayRowModel` and nothing else, so a fixture can draw every state
/// (`PulseQA`'s `SurfaceCapture`).
struct TrayRowFace: View {
    let model: TrayRowModel
    var selected = false
    var send: (TrayRowModel.Action) -> Void = { _ in }

    /// The "›" column: wide enough to hit without aiming, the full height
    /// of the row. The first line leaves it free, so it never sits on the
    /// time.
    static let chevronZoneWidth: CGFloat = 28
    private static let verticalPadding: CGFloat = 5
    private static let lineHeight: CGFloat = 22

    private func t(_ key: L10n.Key) -> String { L10n.t(key, model.lang) }

    /// ⌥ held at the moment of the click — read from the event, never
    /// remembered. The decision is `TrayRowModel.clickAction`.
    private static func optionHeld() -> Bool {
        NSEvent.modifierFlags.contains(.option)
    }

    private func click(_ zone: TrayRowModel.ClickZone) {
        send(TrayRowModel.clickAction(zone: zone, option: Self.optionHeld()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                Button { click(.body) } label: { content }
                    .buttonStyle(.plain)
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
                chevron
            }
            // The "›" column takes the row's full height, both lines.
            .fixedSize(horizontal: false, vertical: true)
            if let note = model.notice {
                notice(note)
            }
        }
        .padding(.trailing, TrayChrome.highlightInset)
        .background(
            RoundedRectangle(cornerRadius: PulseTheme.Radius.card, style: .continuous)
                .fill(selected ? Color.primary.opacity(PulseTheme.Fill.selected) : Color.clear)
                .padding(.horizontal, TrayChrome.highlightInset)
        )
        .contextMenu {
            ForEach(model.menu) { button in
                Button(button.title) { send(button.action) }
                    .keyboardShortcut(Self.shortcut(button.key))
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// The menu item's shortcut: the tray key that does the same.
    private static func shortcut(_ key: TrayKeys.Key?) -> KeyboardShortcut? {
        switch key {
        case .enter: return KeyboardShortcut(.return, modifiers: [])
        case .right: return KeyboardShortcut(.rightArrow, modifiers: [])
        case .dismiss: return KeyboardShortcut("d", modifiers: .command)
        case .mute: return KeyboardShortcut("m", modifiers: .command)
        default: return nil
        }
    }

    @MainActor private var content: some View {
        VStack(alignment: .leading, spacing: PulseTheme.Space.xxs) {
            line
            if let second = model.secondLine {
                Text(second.text)
                    .font(second.kind == .step ? PulseTheme.Font.caption : PulseTheme.Font.body)
                    .foregroundStyle(Self.secondLineStyle(second.kind))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, TrayChrome.oneLineTextStart)
            }
        }
        .padding(.leading, TrayChrome.padX)
        .padding(.trailing, PulseTheme.Space.xs)
        .padding(.vertical, Self.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// Always drawn and always hit-testable: quiet at rest, clearer on the
    /// selected row. VoiceOver reaches it as its own "Details" button.
    @MainActor private var chevron: some View {
        Button { click(.chevron) } label: {
            Image(systemName: "chevron.right")
                .font(PulseTheme.Font.caption.weight(.semibold))
                .foregroundStyle(selected ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .frame(width: Self.chevronZoneWidth)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t(.details))
    }

    /// What the last Go did when it did not land exactly — and, when
    /// Terminal automation is what stood in the way, its "Turn on".
    @MainActor private func notice(_ note: RowNotice) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PulseTheme.Space.s) {
            Text(note.text)
                .font(PulseTheme.Font.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if note.offersAutomation {
                Button(t(.turnOnAutomation)) { send(.turnOnAutomation) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.leading, TrayChrome.padX + TrayChrome.oneLineTextStart)
        .padding(.trailing, PulseTheme.Space.xs)
        .padding(.bottom, Self.verticalPadding)
    }

    /// The ask reads as secondary, the why of a stall in its tone, a step
    /// quietest of all.
    private static func secondLineStyle(_ kind: TrayRowModel.SecondLine.Kind) -> AnyShapeStyle {
        switch kind {
        case .ask: return AnyShapeStyle(.secondary)
        case .warning: return AnyShapeStyle(PulseTheme.Tone.attention.color)
        case .step: return AnyShapeStyle(.tertiary)
        }
    }

    private var line: some View {
        HStack(alignment: .center, spacing: PulseTheme.Space.s) {
            LampShapeView(lamp: model.lamp, size: TrayChrome.lampSize)
            AgentIconView(id: model.agent)
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
        .frame(minHeight: Self.lineHeight)
    }
}
