import Foundation

/// 17.0 · the tray row's face as a value.
///
/// The row is the product — the thing a glance lands on — and until 16.0 it
/// was ~600 lines of SwiftUI reading `StatusStore` 150 times, so nobody could
/// render its states without a running app and a real fleet. The face (lamp,
/// identity, chip, hero, meta, the ask, the why, the action strip, the menu,
/// VoiceOver) is now this value: a pure function of the row, the narrator,
/// and a handful of facts only the store knows, passed in as plain values.
/// The cards that open under a row are `RowCardModel`.
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
    var hero: String
    var heroProcessOnly: Bool
    /// The question itself, for a waiting row.
    var waitDetail: String?
    /// 17.0: which evidence put this row in its state.
    var why: String?
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
        var narrator: RowNarrator
        var notice: String? = nil
        var needsReach: Bool = false
        var muted: Bool = false
    }

    static func make(_ input: Input) -> TrayRowModel {
        let row = input.row
        let n = input.narrator
        func t(_ key: L10n.Key) -> String { n.tr(key) }

        let hero = heroTitle(row, narrator: n)
        let meta = n.rowMetaLine(row)
        let time = n.lastActivityLabel(row)

        // 21.0: one fact, said once. Every verb lives in the ⋯ menu (and
        // VoiceOver's actions); a waiting row additionally shows at most two
        // of them — the way to answer and the way to put it down. Before,
        // the same six verbs were printed in the strip, the menu, the
        // context menu and the expanded card.
        var menu: [Button] = [Button(action: .details, title: t(.details))]
        let focus = row.canFocusTerminal ? Button(action: .focus, title: n.focusActionTitle(row)) : nil
        let dismiss = Button(action: .dismiss, title: t(.dismissWait))

        let lampState = lamp(row)
        let why = n.whyLine(row)
        let waitDetail = n.localizedWaitDetail(row).map { truncate($0, 78) }

        var strip: [Button] = []
        if row.waiting {
            if let focus {
                strip = [focus, dismiss]
            } else {
                strip = [dismiss]
            }
        }
        if let focus { menu.append(focus) }
        if row.waiting { menu.append(dismiss) }
        if row.isProcessOnly { menu.append(Button(action: .supportHealth, title: t(.supportHealth))) }
        if input.needsReach { menu.append(Button(action: .setupWaiting, title: t(.setupWaitingSignals))) }
        // 22.0: muting lives on the row it silences, not in a 32-switch list.
        menu.append(Button(
            action: .mute,
            title: String(format: t(input.muted ? .unmuteAgent : .muteAgent), row.agent.displayName)
        ))

        return TrayRowModel(
            lang: n.lang,
            rowKey: row.rowKey,
            agent: row.agent,
            agentName: row.agent.displayName,
            lamp: lampState,
            shape: shape(row, lamp: lampState),
            project: AgentRow.shortProject(row.project.isEmpty ? row.cwd : row.project),
            accessoryTime: time,
            chip: chip(row, input: input),
            hero: hero,
            heroProcessOnly: row.isProcessOnly,
            waitDetail: waitDetail,
            why: why,
            whyInline: why != nil && (lampState == .error || lampState == .process
                || (lampState == .waiting && waitDetail == nil)),
            accent: accent(row),
            canPrimary: row.canFocusTerminal,
            stripAlwaysVisible: !strip.isEmpty,
            strip: strip,
            menu: menu,
            notice: input.notice,
            accessibilityLabel: accessibilityText(row, hero: hero, meta: meta, time: time, narrator: n),
            accessibilityHint: row.isProcessOnly
                ? t(.processOnlyHint)
                : (row.canFocusTerminal ? n.primaryActionTitle(row) : "")
        )
    }

    static func shape(_ row: AgentRow, lamp: Lamp) -> Shape {
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

    // MARK: - The rules, moved verbatim from the view

    /// Red = waiting; error = stalled, errors or a failed outcome; orange =
    /// process-only (liveness, not a session feed); green = live; grey else.
    static func lamp(_ row: AgentRow) -> Lamp {
        if row.waiting { return .waiting }
        let outcome = row.outcome.lowercased()
        if row.isStalled || row.errors > 0
            || outcome.contains("fail") || outcome.contains("cancel") {
            return .error
        }
        if row.isProcessOnly { return .process }
        if row.liveProcess || row.isExplicitlyRunningPhase || row.subRunning > 0 { return .running }
        return .idle
    }

    static func accent(_ row: AgentRow) -> Accent {
        guard row.waiting else { return .none }
        return row.isUrgentWait ? .urgent : .normal
    }

    /// Only abnormal states get a badge; **no badge means running**.
    static func chip(_ row: AgentRow, input: Input) -> Chip? {
        let n = input.narrator
        if row.waiting {
            let kind = row.waitKind.isEmpty ? n.tr(.needsYou) : n.localizedWaitKind(row.waitKind)
            let duration = n.waitDurationLabel(row)
            return Chip(kind: .waiting, label: duration.isEmpty ? kind : "\(kind) · \(duration)")
        }
        if row.isStalled { return Chip(kind: .process, label: n.tr(.stalled)) }
        // 16.0: finished, unseen. Quiet on purpose — red is for blocked.
        if row.yourTurn { return Chip(kind: .recent, label: n.tr(.yourTurn)) }
        if row.subRunning > 0 {
            return Chip(kind: .running, label: String(format: n.tr(.subChipActive), row.subRunning))
        }
        if row.subTotal > 0 {
            return Chip(kind: .running, label: String(format: n.tr(.subChipObserved), row.subTotal))
        }
        if row.isRecentOnly { return Chip(kind: .recent, label: n.tr(.recent)) }
        return nil
    }

    /// The row hero, chosen by `TrayRowLead` (scene BL).
    static func heroTitle(_ row: AgentRow, narrator n: RowNarrator) -> String {
        let short = AgentRow.shortProject(row.project)
        switch TrayRowLead.source(
            waiting: row.waiting,
            isProcessOnly: row.isProcessOnly,
            canFocusTerminal: row.canFocusTerminal,
            hasTask: row.usefulTask != nil,
            hasProject: !short.isEmpty,
            freshWords: row.selfReportFresh && !row.lastWord.isEmpty,
            hasToolTitle: n.heroToolTitle(row) != nil
        ) {
        case .waitTask, .task: return truncate(row.usefulTask ?? "", heroLimit)
        case .waitProject, .project: return short
        case .needsYou: return n.tr(.needsYou)
        case .processTerminal: return n.tr(.terminalDetectedNoDetails)
        case .processApp: return n.tr(.appDetectedNoDetails)
        case .freshWords: return truncate(row.lastWord, heroLimit)
        case .toolTitle: return truncate(n.heroToolTitle(row) ?? "", heroLimit)
        case .terminalSession: return n.tr(.terminalSession)
        // The agent's name is already on the identity line.
        case .appSession: return n.tr(.appSession)
        }
    }

    static func accessibilityText(
        _ row: AgentRow, hero: String, meta: String, time: String, narrator n: RowNarrator
    ) -> String {
        var parts = [hero, row.agent.displayName]
        let state: String
        if row.waiting {
            state = row.waitKind.isEmpty ? n.tr(.needsYou) : n.localizedWaitKind(row.waitKind)
        } else if row.isProcessOnly {
            state = n.tr(.limitedData)
        } else if row.isStalled {
            state = n.tr(.stalled)
        } else if row.yourTurn {
            state = n.tr(.yourTurn)
        } else if row.isRecentOnly {
            state = n.tr(.recent)
        } else {
            state = n.tr(.running)
        }
        parts.append(state)
        if !meta.isEmpty { parts.append(meta) }
        if !time.isEmpty { parts.append(time) }
        if row.waiting {
            let line = n.localizedWaitLine(row)
            if !line.isEmpty { parts.append(line) }
        }
        if let why = n.whyLine(row) { parts.append(why) }
        return parts.joined(separator: ", ")
    }

    /// Hard ceiling on the row hero, in characters — a guard against a
    /// pathological title, not the thing that shapes the row.
    static let heroLimit = 96

    static func truncate(_ s: String, _ n: Int) -> String {
        guard s.count > n else { return s }
        let cut = String(s.prefix(n - 1))
        // Cutting mid-word reads as damage.
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > n / 2 {
            return String(cut[..<space]) + "…"
        }
        return cut + "…"
    }
}
