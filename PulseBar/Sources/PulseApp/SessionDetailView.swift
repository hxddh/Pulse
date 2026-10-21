import SwiftUI

/// One session, in full, inside the tray.
///
/// The row is one line; everything a person reads *after* deciding to look
/// lives here, one click (the row's "›", or ⌥-click) or one keystroke (→ or
/// Space) away and one keystroke (← or Esc) back. The store builds a
/// `DetailModel` and this view hands it to
/// `SessionDetailFace`, which renders the value and sends intents — so a
/// fixture can draw it (`SurfaceCapture`).
@MainActor
struct SessionDetailView: View {
    var store: StatusStore
    var ui: TrayUI
    let row: AgentRow

    var body: some View {
        // On the tray's clock: the page's times, timeline and last words
        // move without a projection.
        TimelineView(.periodic(from: .now, by: TrayChrome.clock)) { context in
            SessionDetailFace(
                model: store.detailModel(row, at: context.date, disclosed: ui.keys.disclosed),
                maxHeight: CGFloat(ui.maxListHeight)
            ) { action in
                ui.send(action, row: row)
            }
        }
    }
}

/// Renders a `DetailModel` and nothing else: the header (back, lamp, the
/// agent's icon and the headline — the page's title), then the ask with Go
/// and Ignore, the landing notice, the why, Now (the tools still going and
/// the live subagents), This turn (its facts), the timeline of what Pulse
/// heard (a run's steps disclosed under it — a click on the run, or →), the
/// last message, the error, the folder, "Copy this turn's summary" and — for
/// an agent that cannot report one — that it does not report waits; each
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
            // The headline, once: the page's title. Two lines hold the
            // row's whole headline (`TrayRowModel.headlineLimit`).
            Text(model.headline)
                .font(model.headlineQuiet ? PulseTheme.Font.heroQuiet : PulseTheme.Font.hero)
                .foregroundStyle(model.headlineQuiet ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(2)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, PulseTheme.Space.s)
        .padding(.vertical, PulseTheme.Space.s)
    }

    // MARK: Content, in the order it is worth reading

    private var content: some View {
        VStack(alignment: .leading, spacing: PulseTheme.Space.m) {
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
                Text(notice.text)
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let why = model.why {
                Text(why)
                    .font(PulseTheme.Font.body)
                    .foregroundStyle(model.lamp == .stalled ? AnyShapeStyle(PulseTheme.warning) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.now.isEmpty {
                section(t(.detailNowHeading)) {
                    VStack(alignment: .leading, spacing: PulseTheme.Space.xxs) {
                        ForEach(Array(model.now.enumerated()), id: \.offset) { _, item in
                            Text(item)
                                .font(PulseTheme.Font.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            if !model.turn.isEmpty {
                section(model.turnHeading) {
                    FactGrid(facts: model.turn)
                }
            }
            if !model.timeline.isEmpty {
                section(t(.timelineHeading)) {
                    TimelineGrid(entries: model.timeline, stepsShown: model.stepsShown, lang: model.lang) {
                        send(.toggleSteps)
                    }
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
                        .foregroundStyle(PulseTheme.warning)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            }
            FactGrid(facts: model.facts)
            if model.canCopySummary {
                Button(t(.copyTurnSummary)) { send(.copySummary) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            if let caveat = model.caveat {
                Text(caveat)
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                    Text(t(.ignoreWait)) + Text("  ⌘D").foregroundStyle(.secondary)
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
                        .lineLimit(fact.multiline ? nil : 1)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: fact.multiline)
                }
            }
        }
        .font(PulseTheme.Font.caption)
    }
}

/// The timeline: one heard line per row — how long ago, the vendor's event
/// in small monospaced type, what it did. A raise is red; a line that
/// changed nothing is quiet. A run of steps ("Edit ×4") carries a
/// disclosure mark: a click on it shows (or hides) the steps behind every
/// run, each on its own line under its run — "Edit · Sources/App.swift ·
/// 1.2s", a failed one in the warning tone.
struct TimelineGrid: View {
    let entries: [DetailModel.Entry]
    var stepsShown = false
    var lang: ResolvedLanguage = .en
    var toggle: () -> Void = {}

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: PulseTheme.Space.s, verticalSpacing: PulseTheme.Space.xxs) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                GridRow {
                    Text(entry.time)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(entry.event)
                        .font(PulseTheme.Font.code)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    effect(entry)
                }
                if stepsShown, entry.discloses {
                    if entry.earlier > 0 {
                        stepRow(String(format: L10n.t(.timelineEarlierSteps, lang), entry.earlier), style: AnyShapeStyle(.tertiary))
                    }
                    ForEach(Array(entry.steps.enumerated()), id: \.offset) { _, step in
                        stepRow(step.text, style: step.failed ? AnyShapeStyle(PulseTheme.warning) : AnyShapeStyle(.secondary))
                    }
                }
            }
        }
        .font(PulseTheme.Font.caption)
    }

    @ViewBuilder
    private func effect(_ entry: DetailModel.Entry) -> some View {
        if entry.discloses {
            Button { toggle() } label: {
                HStack(spacing: PulseTheme.Space.xxs) {
                    Image(systemName: stepsShown ? "chevron.down" : "chevron.right")
                        .font(PulseTheme.Font.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    Text(entry.effect)
                        .foregroundStyle(Self.style(entry.tone))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(L10n.t(stepsShown ? .timelineHideSteps : .timelineShowSteps, lang))
        } else {
            Text(entry.effect)
                .foregroundStyle(Self.style(entry.tone))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// One disclosed step, under the effect column.
    private func stepRow(_ text: String, style: AnyShapeStyle) -> some View {
        GridRow {
            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            Text(text)
                .foregroundStyle(style)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, PulseTheme.Space.m)
        }
    }

    private static func style(_ tone: DetailModel.Entry.Tone) -> AnyShapeStyle {
        switch tone {
        case .alert: return AnyShapeStyle(Lamp.waiting.color)
        case .failure: return AnyShapeStyle(PulseTheme.warning)
        case .plain: return AnyShapeStyle(.primary)
        case .quiet: return AnyShapeStyle(.tertiary)
        }
    }
}
