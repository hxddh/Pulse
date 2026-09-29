import Foundation

/// 17.0 · the tray row's face as a value.
///
/// 23.0 · one line — lamp · agent · project · headline · age — and a second
/// line only when the row owes an explanation: the ask of a blocked row, or
/// the why of a stalled or failing one. No chip, no tint, no "new" dot, no
/// buttons on the row: the verbs are keys (↩ D M →), the context menu and
/// VoiceOver actions, and the detail page.
///
/// Pure: the row, the language, the clock and a few facts only the store
/// knows, passed in as plain values. The words come from `Explain`, so the
/// row, the detail page and the lamp say one thing.
struct TrayRowModel: Equatable {
    /// Everything a row can ask the store to do.
    enum Action: String, Equatable, Hashable {
        /// Go: focus the terminal when there is a handle, else the detail.
        case primary
        case details, dismiss, focus, diagnostics, setupWaiting, mute
    }

    struct Button: Equatable, Identifiable {
        var action: Action
        var title: String
        var id: Action { action }
    }

    /// The second line, when the row has one.
    struct SecondLine: Equatable {
        enum Kind: Equatable {
            /// What a blocked row is asking, in the agent's words.
            case ask
            /// Why a stalled row is orange.
            case warning
        }
        var kind: Kind
        var text: String
    }

    var lang: ResolvedLanguage
    var rowKey: String
    var agent: AgentID
    var agentName: String
    var lamp: LampFace
    /// The short project name — "" when the headline already is the project.
    var project: String
    /// `Explain.headline`.
    var headline: String
    /// A process-only row's headline is quiet: it says what little is true.
    var headlineQuiet: Bool
    /// The one time on the row: how long a blocked row has waited, else when
    /// the session last moved.
    var age: String
    /// "Your turn", quietly, for a session whose turn ended unseen.
    var turnLabel: String?
    /// The agent is muted (no banners); the row shows a bell.slash.
    var muted: Bool
    var secondLine: SecondLine?
    /// `Explain.why`: which evidence put this row in its state.
    var why: String
    /// The whole row goes somewhere real: the terminal when there is a
    /// handle, else the detail page.
    var canFocus: Bool
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
        var notice: String? = nil
        var needsReach: Bool = false
        var muted: Bool = false
    }

    static func make(_ input: Input) -> TrayRowModel {
        let row = input.row
        let lang = input.lang
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        let explain = Explain.make(row, lang: lang, nowMs: input.nowMs)
        let lamp = LampFace.row(row)
        let age = row.isBlocked
            ? Explain.waitDuration(row, nowMs: input.nowMs, lang: lang)
            : Explain.activityLabel(row, nowMs: input.nowMs, lang: lang)
        let place = row.shortPlace
        let project = place == explain.headline ? "" : place
        let second = secondLine(row, explain: explain, lamp: lamp, lang: lang)
        let turnLabel = row.isYourTurn ? t(.yourTurn) : nil

        var menu: [Button] = []
        if row.canFocusTerminal {
            menu.append(Button(action: .focus, title: Explain.focusTitle(row, lang: lang)))
        }
        menu.append(Button(action: .details, title: t(.details)))
        if row.isBlocked { menu.append(Button(action: .dismiss, title: t(.dismissWait))) }
        // 22.0: muting lives on the row it silences, not in a 32-switch list.
        menu.append(Button(action: .mute, title: t(input.muted ? .unmute : .mute)))
        if input.needsReach { menu.append(Button(action: .setupWaiting, title: t(.setupWaitingSignals))) }
        if row.isProcessOnly { menu.append(Button(action: .diagnostics, title: t(.diagnosticsOpen))) }

        var spoken = [row.agent.displayName, explain.state, explain.headline]
        if !project.isEmpty { spoken.append(project) }
        if !age.isEmpty { spoken.append(age) }
        if let second { spoken.append(second.text) } else { spoken.append(explain.why) }
        if input.muted { spoken.append(t(.mutedWord)) }

        return TrayRowModel(
            lang: lang,
            rowKey: row.rowKey,
            agent: row.agent,
            agentName: row.agent.displayName,
            lamp: lamp,
            project: project,
            headline: explain.headline,
            headlineQuiet: row.isProcessOnly,
            age: age,
            turnLabel: turnLabel,
            muted: input.muted,
            secondLine: second,
            why: explain.why,
            canFocus: row.canFocusTerminal,
            menu: menu,
            notice: input.notice,
            accessibilityLabel: spoken.joined(separator: ", "),
            accessibilityHint: row.canFocusTerminal ? Explain.focusTitle(row, lang: lang) : t(.details)
        )
    }

    /// The second line exists only for a blocked row (its ask — or, when
    /// the agent did not say, what kind of wait it is) and for an orange row
    /// (the why). Everything else is one line.
    static func secondLine(
        _ row: AgentRow,
        explain: Explain,
        lamp: LampFace,
        lang: ResolvedLanguage
    ) -> SecondLine? {
        if let wait = row.wait {
            let text = explain.ask ?? L10n.waitKind(wait.kind, lang)
            return SecondLine(kind: .ask, text: Explain.truncate(text, 140))
        }
        if lamp.tone == .attention {
            return SecondLine(kind: .warning, text: explain.why)
        }
        return nil
    }
}
