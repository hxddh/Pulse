import SwiftUI

/// One session, in full, inside the tray.
///
/// The row is one line; everything a person reads *after* deciding to look
/// lives here, one keystroke (→ or Space) away and one keystroke (← or Esc)
/// back. The store builds a `DetailModel` and this view hands it to
/// `SessionDetailFace`, which renders the value and sends intents — so a
/// fixture can draw it (`SurfaceCapture`).
@MainActor
struct SessionDetailView: View {
    var store: StatusStore
    var ui: TrayUI
    let row: AgentRow

    var body: some View {
        SessionDetailFace(model: store.detailModel(row), maxHeight: CGFloat(ui.maxListHeight)) { action in
            ui.send(action, row: row)
        }
    }
}

/// Renders a `DetailModel` and nothing else: the header (back, lamp,
/// agent · project, state and age), then the ask with Go and Dismiss, the
/// why, the recent steps, the last message, the error and the facts — each
/// block only when it has something to say.
struct SessionDetailFace: View {
    let model: DetailModel
    /// Off for a fixture capture, which measures the whole page.
    var scrolls = true
    var maxHeight: CGFloat = TrayChrome.maxListHeight
    var send: (DetailModel.Action) -> Void = { _ in }

    private func t(_ key: L10n.Key) -> String { L10n.t(key, model.lang) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)
            if scrolls {
                ScrollView { content }
                    .frame(maxHeight: maxHeight)
            } else {
                content
            }
        }
        .frame(width: TrayChrome.width)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: PulseTheme.Space.s) {
            Button { send(.back) } label: {
                Image(systemName: "chevron.left")
                    .font(PulseTheme.Font.hero.weight(.regular))
                    .frame(width: TrayChrome.headerControlSize, height: TrayChrome.headerControlSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(t(.detailBack))
            LampShapeView(lamp: model.lamp, size: TrayChrome.lampSize + 1)
            AgentIconView(id: model.agent)
            Text(model.project.isEmpty ? model.agentName : "\(model.agentName) · \(model.project)")
                .font(PulseTheme.Font.label)
                .lineLimit(1)
                .truncationMode(.middle)
            if model.muted {
                Image(systemName: "bell.slash")
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(t(.mutedWord))
            }
            Spacer(minLength: PulseTheme.Space.s)
            Text(model.age.isEmpty ? model.state : "\(model.state) · \(model.age)")
                .font(PulseTheme.Font.caption)
                .foregroundStyle(model.lamp.tone == .idle ? AnyShapeStyle(.secondary) : AnyShapeStyle(model.lamp.tone.color))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, PulseTheme.Space.s)
        .padding(.vertical, PulseTheme.Space.s)
    }

    // MARK: Content, in the order it is worth reading

    private var content: some View {
        VStack(alignment: .leading, spacing: PulseTheme.Space.m) {
            Text(model.headline)
                .font(model.headlineQuiet ? PulseTheme.Font.heroQuiet : PulseTheme.Font.hero)
                .foregroundStyle(model.headlineQuiet ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let ask = model.ask {
                Text(ask)
                    .font(PulseTheme.Font.bodyEmphasis)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .pulseInner()
            }
            if model.canFocus || model.canDismiss {
                actions
            }
            if let notice = model.notice {
                Text(notice)
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(model.why)
                .font(PulseTheme.Font.body)
                .foregroundStyle(model.lamp.tone == .attention ? AnyShapeStyle(PulseTheme.Tone.attention.color) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
            if !model.steps.isEmpty {
                section(t(.stepHeading)) {
                    FactGrid(facts: model.steps)
                }
            }
            if let message = model.lastMessage {
                section(t(.detailLastMessage)) {
                    Text(message)
                        .font(PulseTheme.Font.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let error = model.error {
                section(t(.detailErrorHeading)) {
                    Text(error)
                        .font(PulseTheme.Font.code)
                        .foregroundStyle(PulseTheme.Tone.attention.color)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            }
            FactGrid(facts: model.facts)
        }
        .padding(.horizontal, TrayChrome.padX)
        .padding(.vertical, PulseTheme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        HStack(spacing: PulseTheme.Space.s) {
            if model.canFocus {
                Button {
                    send(.focus)
                } label: {
                    Text(model.focusTitle) + Text("  ↩").foregroundStyle(.secondary)
                }
            }
            if model.canDismiss {
                Button {
                    send(.dismiss)
                } label: {
                    Text(t(.dismissWait)) + Text("  ⌘D").foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: PulseTheme.Space.xs) {
            Text(title)
                .font(PulseTheme.Font.heading)
                .foregroundStyle(.secondary)
            content()
        }
    }
}

/// Plain facts, label beside value.
struct FactGrid: View {
    let facts: [DetailModel.Fact]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: PulseTheme.Space.m, verticalSpacing: PulseTheme.Space.xxs) {
            ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                GridRow {
                    Text(fact.label)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(fact.value)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .font(PulseTheme.Font.caption)
    }
}

/// The lamp's shape in its tone — filled, ring, hollow or dotted
/// (`LampFace`). The same vocabulary as the menu-bar glyph.
struct LampShapeView: View {
    let lamp: LampFace
    var size: CGFloat = 9

    private var color: Color { lamp.tone == .idle ? Color.secondary : lamp.tone.color }

    var body: some View {
        Group {
            switch lamp.shape {
            case .filled:
                Circle().fill(color)
            case .ring:
                ZStack {
                    Circle().strokeBorder(color, lineWidth: 1.4)
                    Circle().fill(color).frame(width: size * 0.36, height: size * 0.36)
                }
            case .hollow:
                Circle().strokeBorder(color, lineWidth: 1.4)
            case .dotted:
                Circle().strokeBorder(color, style: StrokeStyle(lineWidth: 1.4, dash: [1.4, 1.6]))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
