import Foundation

/// The tray row's face as a value.
///
/// One line — lamp · agent · project · headline · time — and a second line
/// only when the row has something to add: the ask of a blocked row, the why
/// of a stalled one, or — quietly — a running row's last step ("Bash · swift
/// test · 12m ago", a past step, never "running"). No chip, no tint, no "new"
/// dot, no buttons on the row: the verbs are keys (↩ D M →), the context
/// menu and VoiceOver actions, and the detail page.
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
        case details, dismiss, focus, mute
        /// The row notice's offer: let the next Go land on the exact tab.
        case allowAutomation, declineAutomation
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
            /// A running row's last step — quiet.
            case step
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
    /// `headline(_:lang:nowMs:)`: the tray hero.
    var headline: String
    /// A process-only row's headline is quiet: it says what little is true.
    var headlineQuiet: Bool
    /// The one time on the row: how long a blocked row has waited, how long
    /// a running row's turn has run, else when the session last moved.
    var age: String
    /// "Your turn", quietly, for a session whose turn ended unseen.
    var turnLabel: String?
    /// The agent is muted (no banners); the row shows a bell.slash.
    var muted: Bool
    var secondLine: SecondLine?
    /// `why(_:lang:nowMs:)`: which evidence put this row in its state.
    var why: String
    /// The whole row goes somewhere real: the terminal when there is a
    /// handle, else the detail page.
    var canFocus: Bool
    var menu: [Button]
    /// What the last click did, when it did not do the thing — and, once,
    /// the offer that would let it next time.
    var notice: RowNotice?
    var accessibilityLabel: String
    var accessibilityHint: String

    /// Store-only facts, as values.
    struct Input {
        var row: AgentRow
        var lang: ResolvedLanguage
        var nowMs: Int64
        var notice: RowNotice? = nil
        var muted: Bool = false
    }

    static func make(_ input: Input) -> TrayRowModel {
        let row = input.row
        let lang = input.lang
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        let headline = Self.headline(row, lang: lang, nowMs: input.nowMs)
        let why = Self.why(row, lang: lang, nowMs: input.nowMs)
        let lamp = LampFace.row(row)
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
        if row.isBlocked { menu.append(Button(action: .dismiss, title: t(.dismissWait))) }
        // Muting lives on the row it silences, not in a list of switches.
        menu.append(Button(action: .mute, title: t(input.muted ? .unmute : .mute)))

        var spoken = [row.agent.displayName, Self.stateText(row, lang: lang), headline]
        if !project.isEmpty { spoken.append(project) }
        if !age.isEmpty { spoken.append(age) }
        if let second, second.kind != .step { spoken.append(second.text) } else { spoken.append(why) }
        if let second, second.kind == .step { spoken.append(second.text) }
        if input.muted { spoken.append(t(.mutedWord)) }

        return TrayRowModel(
            lang: lang,
            rowKey: row.rowKey,
            agent: row.agent,
            agentName: row.agent.displayName,
            lamp: lamp,
            project: project,
            headline: headline,
            headlineQuiet: row.isProcessOnly,
            age: age,
            turnLabel: turnLabel,
            muted: input.muted,
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
        lamp: LampFace,
        lang: ResolvedLanguage,
        nowMs: Int64
    ) -> SecondLine? {
        if let wait = row.wait {
            let text = ask(row) ?? L10n.waitKind(wait.kind, lang)
            return SecondLine(kind: .ask, text: truncate(text, 140))
        }
        if lamp.tone == .attention {
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
        let project = AgentRow.shortProject(row.project)
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
        func since(_ ms: Int64) -> String { ms > 0 ? ago(ms, nowMs: nowMs, lang: lang) : "?" }
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
                let quiet = DurationFormat.label(seconds: row.lastActivitySeconds(at: nowMs), lang: lang, spoken: true)
                if let step = row.lastStep {
                    return String(format: t(.stepStalled), quiet, stepText(step))
                }
                return String(format: t(.explainStalled), quiet)
            }
            guard row.lastActivityMs > 0 else { return t(.explainRunningNoClock) }
            return String(format: t(.explainRunning), name, ago(row.lastActivityMs, nowMs: nowMs, lang: lang))
        case .recent:
            // Which rule made it recent — never a guess that it runs.
            switch row.recentReason {
            case .atPrompt:
                return String(format: t(.explainIdle), since(row.lastActivityMs))
            case .ended:
                return String(format: t(.explainEnded), since(row.stateSinceMs > 0 ? row.stateSinceMs : row.lastActivityMs))
            case .quiet:
                let quiet = DurationFormat.label(seconds: row.lastActivitySeconds(at: nowMs), lang: lang, spoken: true)
                return String(format: t(.explainQuiet), quiet)
            case .silent:
                let quiet = DurationFormat.label(seconds: row.lastActivitySeconds(at: nowMs), lang: lang, spoken: true)
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
    /// minute, like the row's own time, so a standing row is not redrawn
    /// every tick.
    static func stepLine(_ step: SessionBook.Step, nowMs: Int64, lang: ResolvedLanguage) -> String {
        "\(stepText(step)) · \(minuteAgo(step.ms, nowMs: nowMs, lang: lang))"
    }

    /// How long the current turn has run ("14m"); "" when its start is not
    /// known. Below a minute it says so ("<1m"), so it is not redrawn every
    /// tick.
    static func turnDuration(_ row: AgentRow, nowMs: Int64, lang: ResolvedLanguage) -> String {
        guard row.turnStartMs > 0, row.turnStartMs <= nowMs else { return "" }
        let seconds = Double(nowMs - row.turnStartMs) / 1000
        if seconds < 60 { return L10n.t(.durUnderMinute, lang) }
        return DurationFormat.label(seconds: seconds, lang: lang)
    }

    // MARK: - Time

    /// "12m ago", or "now" below a minute.
    static func minuteAgo(_ ms: Int64, nowMs: Int64, lang: ResolvedLanguage) -> String {
        let seconds = max(0, Double(nowMs - ms) / 1000)
        if seconds < 60 { return L10n.t(.durNow, lang) }
        return String(format: L10n.t(.agoFormat, lang), DurationFormat.label(seconds: seconds, lang: lang, spoken: true))
    }

    /// "3m ago" / "3 分钟前", or "now" alone — never "now ago".
    static func ago(_ ms: Int64, nowMs: Int64, lang: ResolvedLanguage) -> String {
        let seconds = max(0, Double(nowMs - ms) / 1000)
        if seconds < 5 { return L10n.t(.durNow, lang) }
        return String(format: L10n.t(.agoFormat, lang), DurationFormat.label(seconds: seconds, lang: lang, spoken: true))
    }

    /// The row's trailing time: when it last moved. Below a minute it is
    /// simply "now" — the tray rescans every few seconds and nobody acts on
    /// the difference between 40 and 54 seconds.
    static func activityLabel(_ row: AgentRow, nowMs: Int64, lang: ResolvedLanguage) -> String {
        guard row.lastActivityMs > 0 else { return "" }
        return minuteAgo(row.lastActivityMs, nowMs: nowMs, lang: lang)
    }

    /// The row's one time: a wait's duration; for a running row this
    /// turn's duration, when its start is known; else when it last moved.
    static func rowTime(_ row: AgentRow, nowMs: Int64, lang: ResolvedLanguage) -> String {
        if row.isBlocked { return waitDuration(row, nowMs: nowMs, lang: lang) }
        if row.state == .running {
            let turn = turnDuration(row, nowMs: nowMs, lang: lang)
            if !turn.isEmpty { return turn }
        }
        return activityLabel(row, nowMs: nowMs, lang: lang)
    }

    /// How long a wait has been outstanding ("4m"); "" when unknown.
    static func waitDuration(_ row: AgentRow, nowMs: Int64, lang: ResolvedLanguage) -> String {
        guard let since = row.wait?.sinceMs, since > 0 else { return "" }
        return DurationFormat.label(seconds: max(0, Double(nowMs - since) / 1000), lang: lang)
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

/// A row's brief notice: what the last click did when it did not do
/// the thing, or the one-time offer to make the next Go exact. Pure.
struct RowNotice: Equatable {
    var text: String
    /// Carries "Allow" and "Not now" (`TrayRowModel.Action.allowAutomation`
    /// / `.declineAutomation`).
    var offersAutomation = false

    /// "Jump to the exact tab next time — Allow": said the first time a Go
    /// lands on the app only because Terminal automation is off, when the
    /// same plan with it on would have been exact (an iTerm session or a
    /// Terminal / iTerm tab). Never again once the person answered it.
    static func shouldOfferAutomation(
        outcome: LandingOutcome, row: AgentRow, automationAllowed: Bool, offerAnswered: Bool
    ) -> Bool {
        outcome == .appOnly && !automationAllowed && !offerAnswered && row.exactWithAutomation
    }

    static func automationOffer(lang: ResolvedLanguage) -> RowNotice {
        RowNotice(text: L10n.t(.automationOffer, lang), offersAutomation: true)
    }
}
