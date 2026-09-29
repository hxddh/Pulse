import Foundation

/// 17.0 · the tray row's face as a value.
///
/// The face (lamp, identity, chip, hero, the ask, the why, the verbs, the
/// menu, VoiceOver) is a pure function of the row, the language, the clock
/// and a handful of facts only the store knows, passed in as plain values.
/// 23.0: the words come from `Explain` — the hero is its headline and the
/// why is its why — so the row, the detail page and the lamp say one thing.
struct TrayRowModel: Equatable {
    /// The small lamp beside the agent's name.
    enum Lamp: Equatable { case waiting, error, process, running, idle }
    /// 22.0: the lamp's shape carries what the chips and source labels used
    /// to spell out — filled is live, half is stalled or failed, hollow is
    /// done (your turn, recent), dotted is seen only as a process. Shape
    /// plus tone, so the state reads without colour too.
    enum Shape: Equatable { case filled, half, hollow, dotted }
    enum ChipKind: Equatable { case waiting, running, recent, process }
    struct Chip: Equatable {
        var kind: ChipKind
        var label: String
    }
    /// The left gutter: the loudest thing in a row, so only a wait has one.
    enum Accent: Equatable { case none, normal, urgent }

    /// Everything a row can ask the store to do.
    enum Action: String, Equatable, Hashable {
        case primary, details, dismiss
        case focus, supportHealth, setupWaiting, mute
    }
    struct Button: Equatable, Identifiable {
        var action: Action
        var title: String
        var id: Action { action }
    }

    var lang: ResolvedLanguage
    var rowKey: String
    var agent: AgentID
    var agentName: String
    var lamp: Lamp
    var shape: Shape
    /// The short project name, shown between the agent and the task.
    var project: String
    var accessoryTime: String
    var chip: Chip?
    /// `Explain.headline`.
    var hero: String
    var heroProcessOnly: Bool
    /// The question itself, for a waiting row.
    var waitDetail: String?
    /// `Explain.why`: which evidence put this row in its state.
    var why: String
    /// 21.0: the why is shown without a click for an orange row (stalled,
    /// failed, process-only) and for a wait whose question is unknown — the
    /// states that least explain themselves.
    var whyInline: Bool
    var accent: Accent
    /// The whole row is a button (focus) only when there is a real handle.
    var canPrimary: Bool
    /// 21.0: the strip exists only for a wait and is always shown — a row
    /// never grows under the pointer.
    var stripAlwaysVisible: Bool
    var strip: [Button]
    var menu: [Button]
    /// What the last click did, when it did not do the thing.
    var notice: String?
    var accessibilityLabel: String
    var accessibilityHint: String

    /// Store-only facts, as values.
    struct Input {
        var row: AgentRow
        var lang: ResolvedLanguage
        var nowMs: Int64
        var stallMinutes: Int = 0
        var notice: String? = nil
        var needsReach: Bool = false
        var muted: Bool = false
    }

    static func make(_ input: Input) -> TrayRowModel {
        let row = input.row
        let lang = input.lang
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        let explain = Explain.make(row, lang: lang, nowMs: input.nowMs, stallMinutes: input.stallMinutes)
        let time = Explain.activityLabel(row, nowMs: input.nowMs, lang: lang)

        // 21.0: one fact, said once. Every verb lives in the ⋯ menu (and
        // VoiceOver's actions); a waiting row additionally shows at most two
        // of them — the way to answer and the way to put it down.
        var menu: [Button] = [Button(action: .details, title: t(.details))]
        let focus = row.canFocusTerminal ? Button(action: .focus, title: Explain.focusTitle(row, lang: lang)) : nil
        let dismiss = Button(action: .dismiss, title: t(.dismissWait))

        let lampState = lamp(row)
        let waitDetail = explain.ask.map { truncate($0, 78) }

        var strip: [Button] = []
        if row.isBlocked {
            strip = focus.map { [$0, dismiss] } ?? [dismiss]
        }
        if let focus { menu.append(focus) }
        if row.isBlocked { menu.append(dismiss) }
        if row.isProcessOnly { menu.append(Button(action: .supportHealth, title: t(.supportHealth))) }
        if input.needsReach { menu.append(Button(action: .setupWaiting, title: t(.setupWaitingSignals))) }
        // 22.0: muting lives on the row it silences, not in a 32-switch list.
        menu.append(Button(
            action: .mute,
            title: String(format: t(input.muted ? .unmuteAgent : .muteAgent), row.agent.displayName)
        ))

        var spoken = [explain.headline, row.agent.displayName, explain.state]
        if !time.isEmpty { spoken.append(time) }
        if let ask = explain.ask { spoken.append(ask) }
        spoken.append(explain.why)

        return TrayRowModel(
            lang: lang,
            rowKey: row.rowKey,
            agent: row.agent,
            agentName: row.agent.displayName,
            lamp: lampState,
            shape: shape(lampState),
            project: row.shortPlace,
            accessoryTime: time,
            chip: chip(row, explain: explain, input: input),
            hero: explain.headline,
            heroProcessOnly: row.isProcessOnly,
            waitDetail: waitDetail,
            why: explain.why,
            whyInline: lampState == .error || lampState == .process
                || (lampState == .waiting && waitDetail == nil),
            accent: row.isBlocked ? (row.isUrgentWait(at: input.nowMs) ? .urgent : .normal) : .none,
            canPrimary: row.canFocusTerminal,
            stripAlwaysVisible: !strip.isEmpty,
            strip: strip,
            menu: menu,
            notice: input.notice,
            accessibilityLabel: spoken.joined(separator: ", "),
            accessibilityHint: row.isProcessOnly
                ? t(.processOnlyHint)
                : (row.canFocusTerminal ? Explain.focusTitle(row, lang: lang) : "")
        )
    }

    static func shape(_ lamp: Lamp) -> Shape {
        switch lamp {
        case .waiting, .running: return .filled
        case .error: return .half
        case .process: return .dotted
        case .idle: return .hollow
        }
    }

    var tone: PulseTheme.Tone {
        switch lamp {
        case .waiting: return .waiting
        case .running: return .running
        case .error, .process: return .attention
        case .idle: return .idle
        }
    }

    /// Red = blocked; error = stalled or errors reported; orange-dotted =
    /// process-only (liveness, not a session feed); green = running; grey
    /// else (your turn, recent).
    static func lamp(_ row: AgentRow) -> Lamp {
        switch row.state {
        case .blocked: return .waiting
        case .processOnly: return .process
        case .running:
            return row.isStalled || row.errors > 0 ? .error : .running
        case .yourTurn, .recent:
            return row.errors > 0 ? .error : .idle
        }
    }

    /// Only abnormal states get a badge; **no badge means running**.
    static func chip(_ row: AgentRow, explain: Explain, input: Input) -> Chip? {
        switch row.state {
        case .blocked:
            let duration = Explain.waitDuration(row, nowMs: input.nowMs, lang: input.lang)
            return Chip(kind: .waiting, label: duration.isEmpty ? explain.state : "\(explain.state) · \(duration)")
        case .running:
            return row.isStalled ? Chip(kind: .process, label: explain.state) : nil
        // 16.0: finished, unseen. Quiet on purpose — red is for blocked.
        case .yourTurn, .recent:
            return Chip(kind: .recent, label: explain.state)
        case .processOnly:
            return nil
        }
    }

    static func truncate(_ s: String, _ n: Int) -> String { Explain.truncate(s, n) }
}
