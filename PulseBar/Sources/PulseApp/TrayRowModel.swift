import Foundation

/// The tray row's face as a value.
///
/// One line — lamp · agent · project · headline · time — and a second line
/// only when the row has something to add: the ask of a blocked row, the why
/// of a stalled one, or — quietly — a running row's last step ("Bash · swift
/// test · 12m ago", a past step, never "running"). No chip, no tint, no "new"
/// dot, no buttons on the row: the verbs are a click (the body goes, the
/// trailing "›" or an ⌥-click opens the detail — `clickAction`), keys (↩ →
/// ⌘D), the context menu (which shows each key), VoiceOver actions and
/// the detail page.
///
/// Pure: the row, the language, the clock and a few facts only the store
/// knows, passed in as plain values. Every sentence Pulse says of a row —
/// the headline, the why, the state word, the step and time words — is a
/// static function here (below), and `DetailModel` says the same ones, so
/// the row and the detail page say one thing.
struct TrayRowModel: Equatable {
    /// Everything a row can ask the store to do.
    enum Action: String, Equatable, Hashable {
        /// Go: focus the terminal when there is a handle, else the detail.
        case primary
        case details, dismiss, focus
    }

    /// Where on the row a click landed: its body (both lines) or the
    /// trailing "›" column.
    enum ClickZone: Equatable { case body, chevron }

    /// What a click does. The body goes; the "›" opens the detail; an
    /// ⌥-click anywhere opens the detail. The view reads the modifier at
    /// click time and asks this. Pure.
    static func clickAction(zone: ClickZone, option: Bool) -> Action {
        if option { return .details }
        switch zone {
        case .body: return .primary
        case .chevron: return .details
        }
    }

    struct Button: Equatable, Identifiable {
        var action: Action
        var title: String
        var id: Action { action }
        /// The tray key that does the same (`TrayKeys`), shown beside the
        /// item in the context menu — the menu is where the keys are taught.
        var key: TrayKeys.Key? {
            switch action {
            case .focus: return .enter
            case .details: return .right
            case .dismiss: return .dismiss
            case .primary: return nil
            }
        }
    }

    /// The second line, when the row has one.
    struct SecondLine: Equatable {
        enum Kind: Equatable {
            /// What a blocked row is asking, in the agent's words.
            case ask
            /// Why a stalled row is orange.
            case warning
            /// A running row's last step — quiet.
            case step
        }
        var kind: Kind
        var text: String
    }

    var lang: ResolvedLanguage
    var rowKey: String
    var agent: AgentID
    var lamp: Lamp
    /// The short project name — "" when the headline already is the project.
    var project: String
    /// `headline(_:lang:nowMs:)`: the tray hero.
    var headline: String
    /// A process-only row's headline is quiet: it says what little is true.
    var headlineQuiet: Bool
    /// The one time on the row: how long a blocked row has waited, how long
    /// a running row's turn has run, else when the session last moved.
    var age: String
    /// "Your turn", quietly, for a session whose turn ended unseen.
    var turnLabel: String?
    var secondLine: SecondLine?
    /// `why(_:lang:nowMs:)`: which evidence put this row in its state.
    var why: String
    /// The whole row goes somewhere real: the terminal when there is a
    /// handle, else the detail page.
    var canFocus: Bool
    var menu: [Button]
    /// What the last click did, when it did not do the thing.
    var notice: RowNotice?
    var accessibilityLabel: String
    var accessibilityHint: String

    /// Store-only facts, as values.
    struct Input {
        var row: AgentRow
        var lang: ResolvedLanguage
        var nowMs: Int64
        var notice: RowNotice? = nil
    }

    static func make(_ input: Input) -> TrayRowModel {
        let row = input.row
        let lang = input.lang
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        let headline = Self.headline(row, lang: lang, nowMs: input.nowMs)
        let why = Self.why(row, lang: lang, nowMs: input.nowMs)
        let lamp = Lamp(row)
        let age = Self.rowTime(row, nowMs: input.nowMs, lang: lang)
        let place = row.shortPlace
        let project = place == headline ? "" : place
        let second = secondLine(row, why: why, lamp: lamp, lang: lang, nowMs: input.nowMs)
        let turnLabel = row.isYourTurn ? t(.yourTurn) : nil

        var menu: [Button] = []
        if row.canFocusTerminal {
            menu.append(Button(action: .focus, title: Self.focusTitle(row, lang: lang)))
        }
        menu.append(Button(action: .details, title: t(.details)))
        if row.isBlocked { menu.append(Button(action: .dismiss, title: t(.ignoreWait))) }

        // VoiceOver hears whole words: "4 minutes", never the drawn "4m".
        var spoken = [row.agent.displayName, Self.stateText(row, lang: lang), headline]
        if !project.isEmpty { spoken.append(project) }
        let spokenAge = Self.rowTime(row, nowMs: input.nowMs, lang: lang, spoken: true)
        if !spokenAge.isEmpty { spoken.append(spokenAge) }
        if let second, second.kind != .step { spoken.append(second.text) } else { spoken.append(why) }
        if let second, second.kind == .step { spoken.append(second.text) }

        return TrayRowModel(
            lang: lang,
            rowKey: row.rowKey,
            agent: row.agent,
            lamp: lamp,
            project: project,
            headline: headline,
            headlineQuiet: row.isProcessOnly,
            age: age,
            turnLabel: turnLabel,
            secondLine: second,
            why: why,
            canFocus: row.canFocusTerminal,
            menu: menu,
            notice: input.notice,
            accessibilityLabel: spoken.joined(separator: ", "),
            accessibilityHint: row.canFocusTerminal ? Self.focusTitle(row, lang: lang) : t(.details)
        )
    }

    /// The second line exists only for a blocked row (its ask — or, when
    /// the agent did not say, what kind of wait it is), for an orange row
    /// (the why, which names the last step) and for a running row whose hook
    /// named a step (the step, quietly). Everything else is one line — a
    /// Cursor or OpenCode row among them: their hooks name no tool.
    static func secondLine(
        _ row: AgentRow,
        why: String,
        lamp: Lamp,
        lang: ResolvedLanguage,
        nowMs: Int64
    ) -> SecondLine? {
        if let wait = row.wait {
            let text = ask(row) ?? L10n.waitKind(wait.kind, lang)
            return SecondLine(kind: .ask, text: truncate(text, 140))
        }
        if lamp == .stalled {
            return SecondLine(kind: .warning, text: why)
        }
        if row.state == .running, let step = row.lastStep {
            return SecondLine(kind: .step, text: truncate(stepLine(step, nowMs: nowMs, lang: lang), 140))
        }
        return nil
    }
}

// MARK: - The words

/// What a row is doing and why Pulse says so, in plain words:
///
/// - `headline` — what it is doing or asking: the tray hero;
/// - `why` — one sentence: what put the row in its state, and since when
///   ("Claude asked for permission · 4m ago", "Nothing new for 23m",
///   "Started before Pulse — details after its next step"). Never the word
///   "hook" — `surface_check.py` holds it.
///
/// Pure: the row, the language and the clock in; the same inputs always
/// give the same sentences. It never guesses — every word comes from a
/// field the row carries.
extension TrayRowModel {
    /// Hard ceiling on the headline, in characters — a guard against a
    /// pathological title, not the thing that shapes the row.
    static let headlineLimit = 96

    // MARK: - Headline

    /// The tray hero, by value. A wait leads with what the person must
    /// recognise to answer (the task, else the project); a process-only row
    /// says what little is true; a session leads with its task (a stable line
    /// the eye can find), then the agent's fresh last words, then the
    /// project.
    static func headline(_ row: AgentRow, lang: ResolvedLanguage, nowMs: Int64) -> String {
        truncate(rawHeadline(row, lang: lang, nowMs: nowMs), headlineLimit)
    }

    private static func rawHeadline(_ row: AgentRow, lang: ResolvedLanguage, nowMs: Int64) -> String {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        let project = TitleHeuristics.shortProject(row.project)
        switch row.state {
        case .blocked:
            if let task = row.usefulTask { return task }
            return project.isEmpty ? t(.needsYou) : project
        case .processOnly:
            return row.canFocusTerminal ? t(.terminalDetectedNoDetails) : t(.appDetectedNoDetails)
        case .running, .yourTurn, .recent:
            if let task = row.usefulTask { return task }
            if !row.lastWord.isEmpty, row.selfReportFresh(at: nowMs) { return row.lastWord }
            if !project.isEmpty { return project }
            return row.canFocusTerminal ? t(.terminalSession) : t(.appSession)
        }
    }

    // MARK: - Why

    /// Which evidence put the row in its state, and since when.
    static func why(_ row: AgentRow, lang: ResolvedLanguage, nowMs: Int64) -> String {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        let name = row.agent.displayName
        func since(_ ms: Int64) -> String { ms > 0 ? L10n.ago(ms, nowMs: nowMs, lang) : "?" }
        let quiet = L10n.duration(row.lastActivitySeconds(at: nowMs), lang)
        switch row.state {
        case .blocked(let wait):
            let kind = kindNoun(wait.kind, lang: lang)
            var text = String(format: t(.explainAsked), name, kind, since(wait.sinceMs))
            if wait.inFront { text += t(.explainAskedFront) }
            return text
        case .yourTurn(let sinceMs):
            return String(format: t(.explainTurn), name, since(sinceMs))
        case .processOnly:
            return t(.explainProcessOnly)
        case .running:
            if row.isStalled {
                guard row.lastActivityMs > 0 else { return t(.explainStalledUnknown) }
                if let step = row.lastStep {
                    return String(format: t(.stepStalled), quiet, stepText(step))
                }
                return String(format: t(.explainStalled), quiet)
            }
            guard row.lastActivityMs > 0 else { return t(.explainRunningNoClock) }
            return String(format: t(.explainRunning), name, since(row.lastActivityMs))
        case .recent:
            // Which rule made it recent — never a guess that it runs.
            switch row.recentReason {
            case .atPrompt:
                return String(format: t(.explainIdle), since(row.lastActivityMs))
            case .ended:
                return String(format: t(.explainEnded), since(row.stateSinceMs > 0 ? row.stateSinceMs : row.lastActivityMs))
            case .quiet:
                return String(format: t(.explainQuiet), quiet)
            case .silent:
                return String(format: t(.explainSilent), quiet)
            }
        }
    }

    /// A wait kind as what the agent did: "asked for permission".
    static func kindNoun(_ kind: String, lang: ResolvedLanguage) -> String {
        switch kind {
        case "Permission": return L10n.t(.explainKindPermission, lang)
        case "Input": return L10n.t(.explainKindInput, lang)
        case "Waiting", "": return L10n.t(.explainKindWaiting, lang)
        default: return kind
        }
    }

    // MARK: - State

    /// The state in a word or two ("Needs you", "Running", "Your turn").
    static func stateText(_ row: AgentRow, lang: ResolvedLanguage) -> String {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        switch row.state {
        case .blocked: return t(.needsYou)
        case .processOnly: return t(.processOnly)
        case .yourTurn: return t(.yourTurn)
        case .recent: return t(.recent)
        case .running: return row.isStalled ? t(.stalled) : t(.running)
        }
    }

    /// A blocked row's question in the agent's words; nil when unknown.
    static func ask(_ row: AgentRow) -> String? {
        guard let ask = row.wait?.ask.trimmingCharacters(in: .whitespacesAndNewlines), !ask.isEmpty else { return nil }
        return ask
    }

    // MARK: - Steps

    /// A step in the words a row uses: "Bash · swift test", or the tool
    /// alone. What was reported, never a claim that it still runs.
    static func stepText(_ step: SessionBook.Step) -> String {
        step.target.isEmpty ? step.tool : "\(step.tool) · \(step.target)"
    }

    /// A step with its age: "Bash · swift test · 12m ago" — "now" below a
    /// minute, like the row's own time.
    static func stepLine(_ step: SessionBook.Step, nowMs: Int64, lang: ResolvedLanguage) -> String {
        "\(stepText(step)) · \(L10n.ago(step.ms, nowMs: nowMs, lang))"
    }

    // MARK: - Time

    /// How long the current turn has run ("14m", "now" below a minute);
    /// "" when its start is not known.
    static func turnDuration(_ row: AgentRow, nowMs: Int64, lang: ResolvedLanguage, spoken: Bool = false) -> String {
        guard row.turnStartMs > 0, row.turnStartMs <= nowMs else { return "" }
        return L10n.duration(Double(nowMs - row.turnStartMs) / 1000, lang, spoken: spoken)
    }

    /// The row's one time: how long a wait has been outstanding ("4m"); for
    /// a running row this turn's duration, when its start is known; else
    /// when it last moved ("3m ago"). `spoken`: in full units, as VoiceOver
    /// says it ("4 minutes"). "" when the row has none.
    static func rowTime(_ row: AgentRow, nowMs: Int64, lang: ResolvedLanguage, spoken: Bool = false) -> String {
        if let wait = row.wait {
            guard wait.sinceMs > 0 else { return "" }
            return L10n.duration(Double(nowMs - wait.sinceMs) / 1000, lang, spoken: spoken)
        }
        if row.state == .running {
            let turn = turnDuration(row, nowMs: nowMs, lang: lang, spoken: spoken)
            if !turn.isEmpty { return turn }
        }
        guard row.lastActivityMs > 0 else { return "" }
        return L10n.ago(row.lastActivityMs, nowMs: nowMs, lang, spoken: spoken)
    }

    // MARK: - Focus

    /// The focus verb, as honest as the plan: "Go to terminal" only when a
    /// click can land on the exact pane, session or tab; "Open app" when it
    /// can only bring the app (or its folder) forward.
    static func focusTitle(_ row: AgentRow, lang: ResolvedLanguage) -> String {
        switch row.landingPlan.precision {
        case .exact: return L10n.t(.focusExact, lang)
        case .app: return L10n.t(.focusApp, lang)
        case nil: return L10n.t(.focusOpenTray, lang)
        }
    }

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

/// One session, in full, as a value — what `SessionDetailFace` draws.
///
/// The row is one line; this is what a person reads after deciding to look,
/// in the order it is worth reading: the headline as the page's title (in
/// its header, once), the ask (and what to do about it), the why (when the
/// row's second line did not already say it), the recent steps, the agent's
/// last message, the last error and the folder — all from the session's own
/// events, in the words the row uses (`TrayRowModel`). Each thing is said
/// once: no headline block under a header that names it, no state-and-age
/// beside "This turn", no start time. How Pulse reads a session is not on
/// the page; it is in Settings → Hooks → "Copy report". Nothing is shown as
/// a placeholder: a fact Pulse does not have is not a row. Tokens, context,
/// cost, model and plan are never shown — a decision.
struct DetailModel: Equatable {
    struct Fact: Equatable {
        var label: String
        var value: String
    }

    /// What the detail page can ask for.
    enum Action: Equatable { case back, focus, dismiss }

    var lang: ResolvedLanguage
    var rowKey: String
    var agent: AgentID
    var lamp: Lamp
    /// `TrayRowModel.headline` — the page's title, in its header.
    var headline: String
    var headlineQuiet: Bool
    /// The full question of a blocked row.
    var ask: String?
    /// `TrayRowModel.why` — nil when it is the row's own second line (a
    /// stalled row's why), which would say the same sentence twice.
    var why: String?
    /// Up to `SessionBook.maxSteps` recent steps, newest first: how long
    /// ago, and "tool · target".
    var steps: [Fact]
    var lastMessage: String?
    var error: String?
    /// This turn's duration (the page's one clock) and the folder.
    var facts: [Fact]
    var canFocus: Bool
    var focusTitle: String
    var canDismiss: Bool
    /// What the last Go did when it did not land exactly (`RowNotice`) —
    /// the same words as the row.
    var notice: RowNotice? = nil

    static func make(
        row: AgentRow,
        lang: ResolvedLanguage,
        nowMs: Int64,
        notice: RowNotice? = nil
    ) -> DetailModel {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        typealias Words = TrayRowModel
        let fresh = row.selfReportFresh(at: nowMs)

        var facts: [Fact] = []
        if row.state == .running || row.isBlocked {
            let turn = Words.turnDuration(row, nowMs: nowMs, lang: lang)
            if !turn.isEmpty { facts.append(Fact(label: t(.stepThisTurn), value: turn)) }
        }
        if !row.displayPath.isEmpty { facts.append(Fact(label: t(.detailFolder), value: row.displayPath)) }

        let steps = row.recentSteps.reversed().map { step in
            Fact(label: L10n.ago(step.ms, nowMs: nowMs, lang), value: Words.stepText(step))
        }
        let lamp = Lamp(row)
        let why = Words.why(row, lang: lang, nowMs: nowMs)
        let second = Words.secondLine(row, why: why, lamp: lamp, lang: lang, nowMs: nowMs)

        return DetailModel(
            lang: lang,
            rowKey: row.rowKey,
            agent: row.agent,
            lamp: lamp,
            headline: Words.headline(row, lang: lang, nowMs: nowMs),
            headlineQuiet: row.isProcessOnly,
            ask: Words.ask(row),
            why: second?.text == why ? nil : why,
            steps: steps,
            lastMessage: fresh && !row.lastWord.isEmpty ? row.lastWord : nil,
            error: row.lastErrorText.isEmpty ? nil : row.lastErrorText,
            facts: facts,
            canFocus: row.canFocusTerminal,
            focusTitle: Words.focusTitle(row, lang: lang),
            canDismiss: row.isBlocked,
            notice: notice
        )
    }
}

/// A row's brief notice: what the last click did when it did not do the
/// thing. Pure.
struct RowNotice: Equatable {
    var text: String

    /// A Go that reached the app, not the exact terminal. When the plan
    /// tried an iTerm session or a Terminal / iTerm tab — AppleScript, which
    /// macOS lets run only once the person allowed it in its own Automation
    /// prompt — the notice says where that permission is; otherwise it says
    /// only where it landed. No button: macOS's prompt is the consent.
    static func appOnly(row: AgentRow, lang: ResolvedLanguage) -> RowNotice {
        let scripted = row.landingPlan.steps.contains { step in
            switch step {
            case .iTermSession, .ttyTab: return true
            default: return false
            }
        }
        return RowNotice(text: L10n.t(scripted ? .focusAppOnlyAutomation : .focusAppOnly, lang))
    }
}

/// What VoiceOver says of its own accord: only a new wait. When the number
/// of blocked sessions rises it says who and what — "Claude needs you:
/// Bash: npm run build" — at high priority; a count that falls or holds,
/// and every other change, is said by nobody (the tray says it when the
/// person looks). Pure.
enum WaitAnnouncement {
    /// `previous`: the blocked count VoiceOver last knew (nil: the first
    /// scan — the baseline, never announced). `rows`: every row now.
    static func text(previousBlocked: Int?, rows: [AgentRow], lang: ResolvedLanguage) -> String? {
        let blocked = rows.filter(\.isBlocked)
        guard let previousBlocked, blocked.count > previousBlocked else { return nil }
        // The newest wait: the latest clock; one with no clock is newer
        // than any that has one (the projection lists it last).
        guard let newest = blocked.max(by: { a, b in
            let x = a.wait?.sinceMs ?? 0, y = b.wait?.sinceMs ?? 0
            if x <= 0 { return false }
            if y <= 0 { return true }
            return x < y
        }) else { return nil }
        let name = newest.agent.displayName
        if let ask = TrayRowModel.ask(newest) {
            return String(format: L10n.t(.a11yNewWait, lang), name, TrayRowModel.truncate(ask, 140))
        }
        return String(format: L10n.t(.a11yNewWaitNoAsk, lang), name)
    }
}
