import SwiftUI

/// 22.0 · Lamp — one session, in full, inside the tray.
///
/// The row is one line; everything a person reads *after* deciding to look
/// lives here, one keystroke (→) away and one keystroke (←, Esc) back.
/// 23.0: the store builds a `DetailModel` and this view hands it to
/// `SessionDetailFace`, which renders the value and sends intents — so a
/// fixture can draw it (`SurfaceCapture`).
@MainActor
struct SessionDetailView: View {
    var store: StatusStore
    let row: AgentRow
    var onBack: () -> Void

    var body: some View {
        SessionDetailFace(model: store.detailModel(row)) { action in
            switch action {
            case .back: onBack()
            case .focus: store.focusTerminal(row)
            case .dismiss: store.dismissWaiting(row)
            }
        }
    }
}

/// Renders a `DetailModel` and nothing else.
struct SessionDetailFace: View {
    let model: DetailModel
    /// Off for a fixture capture, which measures the whole page.
    var scrolls = true
    var send: (DetailModel.Action) -> Void = { _ in }

    private func t(_ key: L10n.Key) -> String { L10n.t(key, model.lang) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)
            if scrolls {
                ScrollView { content }
                    .frame(maxHeight: TrayChrome.maxListHeight)
            } else {
                content
            }
        }
        .frame(width: TrayChrome.width)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: PulseTheme.Space.m) {
            if let task = model.task {
                Text(task)
                    .font(PulseTheme.Font.hero)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Label(model.why, systemImage: "info.circle")
                .font(PulseTheme.Font.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let ask = model.ask {
                Text(ask)
                    .font(PulseTheme.Font.bodyEmphasis)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let strip = model.timeline {
                TimelineStripView(model: strip, lang: model.lang)
            }
            if model.canDismiss {
                actions
            }
            if let words = model.lastWord {
                section(t(.detailLastWords)) {
                    Text(words)
                        .font(PulseTheme.Font.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let error = model.error {
                Text(error)
                    .font(PulseTheme.Font.code)
                    .foregroundStyle(PulseTheme.Tone.attention.color)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            if let plan = model.plan {
                section(t(.detailPlanHeading)) { PlanFace(model: plan) }
            }
            if !model.audit.isEmpty {
                section(t(.detailNotificationHeading)) {
                    VStack(alignment: .leading, spacing: PulseTheme.Space.xxs) {
                        ForEach(Array(model.audit.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(PulseTheme.Font.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            facts
        }
        .padding(.horizontal, TrayChrome.padX)
        .padding(.vertical, PulseTheme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        let face = model.face
        return HStack(spacing: PulseTheme.Space.s) {
            Button { send(.back) } label: {
                Image(systemName: "chevron.left")
                    .font(PulseTheme.Font.hero.weight(.regular))
                    .frame(width: TrayChrome.headerControlSize, height: TrayChrome.headerControlSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut(.leftArrow, modifiers: [])
            .accessibilityLabel(t(.detailBack))
            LampShapeView(shape: face.shape, tone: face.tone, size: 9)
            AgentIconView(id: face.agent)
            Text(face.agentName)
                .font(PulseTheme.Font.label)
            if !face.project.isEmpty {
                Text(face.project)
                    .font(PulseTheme.Font.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: PulseTheme.Space.s)
            if let chip = face.chip, face.lamp == .waiting {
                PulseChip(label: chip.label, tone: .waiting)
            }
            Text(face.accessoryTime)
                .font(PulseTheme.Font.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, PulseTheme.Space.s)
        .padding(.vertical, PulseTheme.Space.s)
    }

    private var actions: some View {
        HStack(spacing: PulseTheme.Space.s) {
            if model.canFocus {
                Button(model.focusTitle) { send(.focus) }
                    .keyboardShortcut(.return, modifiers: [])
            }
            Button(t(.dismissWait)) { send(.dismiss) }
            Spacer(minLength: 0)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    /// Model, source, folder, start — one quiet line each.
    private var facts: some View {
        VStack(alignment: .leading, spacing: PulseTheme.Space.xxs) {
            ForEach(Array(model.facts.enumerated()), id: \.offset) { _, fact in
                HStack(alignment: .firstTextBaseline, spacing: PulseTheme.Space.s) {
                    Text(fact.label)
                        .foregroundStyle(.secondary)
                    Text(fact.value)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .font(PulseTheme.Font.caption)
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

/// The agent's own checklist.
struct PlanFace: View {
    let model: DetailModel.Plan

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let progress = model.progress {
                Text(progress)
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(model.steps.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(step.mark)
                        .font(PulseTheme.Font.code)
                        .foregroundStyle(step.current ? .primary : .secondary)
                    Text(step.text)
                        .font(PulseTheme.Font.caption)
                        .foregroundStyle(step.current ? .primary : .secondary)
                        .strikethrough(step.done)
                        .lineLimit(1)
                }
            }
            if model.overflow > 0 {
                Text("… \(model.overflow)")
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The last hour of one session as a thin strip, in lamp tones, with the
/// minutes per state underneath. Renders a value.
struct TimelineStripView: View {
    let model: TimelineStripModel
    let lang: ResolvedLanguage
    var height: CGFloat = 6

    private func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }

    var body: some View {
        VStack(alignment: .leading, spacing: PulseTheme.Space.xs) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(Array(model.segments.enumerated()), id: \.offset) { _, segment in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(fill(segment.state))
                            .frame(width: max(1, geo.size.width * segment.fraction - 1))
                            .help(label(segment))
                    }
                }
            }
            .frame(height: height)
            .accessibilityHidden(true)
            HStack(spacing: PulseTheme.Space.s) {
                Text(t(.detailLastHour))
                ForEach(Array(model.minutesByState.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: PulseTheme.Space.xxs) {
                        Circle().fill(item.0.tone.color).frame(width: 6, height: 6)
                        Text(String(format: t(.detailMinutesIn), item.1, stateName(item.0)))
                    }
                }
            }
            .font(PulseTheme.Font.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }

    private func fill(_ state: TimelineState?) -> Color {
        guard let state else { return Color.primary.opacity(PulseTheme.Fill.subtle) }
        return state.tone.color.opacity(state == .recent || state == .turn ? 0.35 : 0.85)
    }

    private func stateName(_ state: TimelineState) -> String {
        switch state {
        case .blocked: return t(.needsYou)
        case .running: return t(.running)
        case .thin: return t(.limitedData)
        case .stalled: return t(.stalled)
        case .turn: return t(.yourTurn)
        case .recent: return t(.recent)
        }
    }

    private func label(_ segment: TimelineStripModel.Segment) -> String {
        guard let state = segment.state else { return "" }
        let minutes = max(1, Int((segment.endMs - segment.startMs) / 60_000))
        var text = String(format: t(.detailMinutesIn), minutes, stateName(state))
        if !segment.kind.isEmpty { text += " · \(L10n.waitKind(segment.kind, lang))" }
        return text
    }
}

/// 22.0: the lamp's shape, in its tone — filled, half, hollow or dotted.
struct LampShapeView: View {
    let shape: TrayRowModel.Shape
    let tone: PulseTheme.Tone
    var size: CGFloat = 8

    var body: some View {
        Group {
            switch shape {
            case .filled:
                Circle().fill(tone.color)
            case .half:
                ZStack {
                    Circle().strokeBorder(tone.color, lineWidth: 1.4)
                    Circle().trim(from: 0.25, to: 0.75).fill(tone.color).rotationEffect(.degrees(180))
                }
            case .hollow:
                Circle().strokeBorder(tone.color, lineWidth: 1.4)
            case .dotted:
                Circle().strokeBorder(tone.color, style: StrokeStyle(lineWidth: 1.4, dash: [1.6, 1.6]))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
