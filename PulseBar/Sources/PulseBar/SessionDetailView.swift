import SwiftUI

/// 22.0 · Lamp — one session, in full, inside the tray.
///
/// The row is one line; everything a person reads *after* deciding to look
/// lives here, one keystroke (→) away and one keystroke (←, Esc) back: why
/// the row is in its state, the last hour as a strip, the full request with
/// Allow beside it when there is one, the agent's own words and plan, what
/// happened to the banner, and how Pulse read the session. It replaced the
/// expanded row card, the digest and the Workbench inspector — three
/// inspectors for one row.
@MainActor
struct SessionDetailView: View {
    var store: StatusStore
    let row: AgentRow
    var onBack: () -> Void

    private var cards: RowCardModel { store.rowCardModel(row) }
    private var face: TrayRowModel { store.trayRowModel(row) }

    var body: some View {
        let cards = self.cards
        let face = self.face
        VStack(alignment: .leading, spacing: 0) {
            header(face)
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: PulseTheme.Space.m) {
                    if let task = cards.task {
                        Text(task)
                            .font(PulseTheme.Font.hero)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let why = face.why {
                        Label(why, systemImage: "info.circle")
                            .font(PulseTheme.Font.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let strip = store.timelineStrip(for: row) {
                        TimelineStripView(model: strip, lang: store.lang)
                    }
                    if row.waiting {
                        actions(face)
                    }
                    if let words = cards.lastWord {
                        section(store.tr(.detailLastWords)) {
                            Text(words)
                                .font(PulseTheme.Font.body)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let error = cards.errorText {
                        Text(error)
                            .font(PulseTheme.Font.code)
                            .foregroundStyle(PulseTheme.Tone.attention.color)
                            .lineLimit(4)
                            .textSelection(.enabled)
                    }
                    if let plan = cards.plan {
                        section(store.tr(.detailPlanHeading)) { PlanCompactFace(model: plan) }
                    }
                    if !cards.workFacts.isEmpty {
                        FactLinesFace(lines: cards.workFacts)
                    }
                    if let audit = store.notificationAudit(for: row) {
                        section(store.tr(.detailNotificationHeading)) {
                            VStack(alignment: .leading, spacing: PulseTheme.Space.xxs) {
                                ForEach(Array(audit.lines.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(PulseTheme.Font.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    WhyDetailSection(store: store, row: row)
                    SessionDiagnosticsCard(store: store, row: row)
                }
                .padding(.horizontal, TrayChrome.padX)
                .padding(.vertical, PulseTheme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: TrayChrome.maxListHeight)
        }
        .frame(width: TrayChrome.width)
    }

    private func header(_ face: TrayRowModel) -> some View {
        HStack(spacing: PulseTheme.Space.s) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(PulseTheme.Font.hero.weight(.regular))
                    .frame(width: TrayChrome.headerControlSize, height: TrayChrome.headerControlSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut(.leftArrow, modifiers: [])
            .accessibilityLabel(store.tr(.detailBack))
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

    private func actions(_ face: TrayRowModel) -> some View {
        HStack(spacing: PulseTheme.Space.s) {
            if row.canFocusTerminal {
                Button(store.focusActionTitle(row)) { store.focusTerminal(row) }
                    .keyboardShortcut(.return, modifiers: [])
            }
            Button(store.tr(.dismissWait)) { store.dismissWaiting(row) }
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
