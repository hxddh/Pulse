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
/// Pure: the row, what its session said lately (`SessionFacts`, read from
/// the book when the row is drawn), the language, the clock and a few facts
/// only the store knows, passed in as plain values. Every sentence Pulse says of a row —
/// the headline, the why, the state word, the step and time words — is a
/// static function here (below), and `DetailModel` says the same ones, so
/// the row and the detail page say one thing.
package struct TrayRowModel: Equatable {
    /// Everything a row can ask the store to do.
    package enum Action: String, Equatable, Hashable {
        /// Go: focus the terminal when there is a handle, else the detail.
        case primary
        case details, dismiss, focus
    }

    /// Where on the row a click landed: its body (both lines) or the
    /// trailing "›" column.
    package enum ClickZone: Equatable { case body, chevron }

    /// What a click does. The body goes; the "›" opens the detail; an
    /// ⌥-click anywhere opens the detail. The view reads the modifier at
    /// click time and asks this. Pure.
    package static func clickAction(zone: ClickZone, option: Bool) -> Action {
        if option { return .details }
        switch zone {
        case .body: return .primary
        case .chevron: return .details
        }
    }

    package struct Button: Equatable, Identifiable {
        package var action: Action
        package var title: String
        package var id: Action { action }
        /// The tray key that does the same (`TrayKeys`), shown beside the
        /// item in the context menu — the menu is where the keys are taught.
        package var key: TrayKeys.Key? {
            switch action {
            case .focus: return .enter
            case .details: return .right
            case .dismiss: return .dismiss
            case .primary: return nil
            }
        }
    }

    /// The second line, when the row has one.
    package struct SecondLine: Equatable {
        package enum Kind: Equatable {
            /// What a blocked row is asking, in the agent's words.
            case ask
            /// Why a stalled row is orange.
            case warning
            /// A running row's last step — quiet.
            case step
        }
        package var kind: Kind
        package var text: String
    }

    package var lang: ResolvedLanguage
    package var key: SessionKey
    package var agent: AgentID
    package var lamp: Lamp
    /// The short project name — "" when the headline already is the project.
    package var project: String
    /// `headline(_:lang:nowMs:)`: the tray hero.
    package var headline: String
    /// A process-only row's headline is quiet: it says what little is true.
    package var headlineQuiet: Bool
    /// The one time on the row: how long a blocked row has waited, how long
    /// a running row's turn has run, else when the session last moved.
    package var age: String
    /// "Your turn", quietly, for a session whose turn ended unseen.
    package var turnLabel: String?
    package var secondLine: SecondLine?
    /// `why(_:lang:nowMs:)`: which evidence put this row in its state.
    package var why: String
    /// The whole row goes somewhere real: the terminal when there is a
    /// handle, else the detail page.
    package var canFocus: Bool
    package var menu: [Button]
    /// What the last click did, when it did not do the thing.
    package var notice: RowNotice?
    package var accessibilityLabel: String
    package var accessibilityHint: String

    /// The row, what its session said lately, and store-only facts, as
    /// values.
    package struct Input {
        package var row: AgentRow
        package var facts: SessionFacts
        package var lang: ResolvedLanguage
        package var nowMs: Int64
        package var notice: RowNotice?

        package init(row: AgentRow, facts: SessionFacts = SessionFacts(), lang: ResolvedLanguage, nowMs: Int64, notice: RowNotice? = nil) {
            self.row = row
            self.facts = facts
            self.lang = lang
            self.nowMs = nowMs
            self.notice = notice
        }
    }

    package static func make(_ input: Input) -> TrayRowModel {
        let row = input.row
        let facts = input.facts
        let lang = input.lang
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        let headline = Self.headline(row, facts: facts, lang: lang, nowMs: input.nowMs)
        let why = Self.why(row, facts: facts, lang: lang, nowMs: input.nowMs)
        let lamp = row.lamp
        let age = Self.rowTime(row, facts: facts, nowMs: input.nowMs, lang: lang)
        let place = row.project
        let project = place == headline ? "" : place
        let second = secondLine(row, facts: facts, why: why, lang: lang, nowMs: input.nowMs)
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
        let spokenAge = Self.rowTime(row, facts: facts, nowMs: input.nowMs, lang: lang, spoken: true)
        if !spokenAge.isEmpty { spoken.append(spokenAge) }
        if let second, second.kind != .step { spoken.append(second.text) } else { spoken.append(why) }
        if let second, second.kind == .step { spoken.append(second.text) }

        return TrayRowModel(
            lang: lang,
            key: row.key,
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
    package static func secondLine(
        _ row: AgentRow,
        facts: SessionFacts,
        why: String,
        lang: ResolvedLanguage,
        nowMs: Int64
    ) -> SecondLine? {
        switch row.status {
        case .needsYou(let block):
            let text = ask(row) ?? L10n.waitKind(block.kind, lang)
            return SecondLine(kind: .ask, text: truncate(text, 140))
        case .running(stalled: true):
            return SecondLine(kind: .warning, text: why)
        case .running(stalled: false):
            guard let step = facts.lastStep else { return nil }
            return SecondLine(kind: .step, text: truncate(stepLine(step, nowMs: nowMs, lang: lang), 140))
        case .yourTurn, .recent, .processOnly:
            return nil
        }
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
/// Pure: the row, its facts, the language and the clock in; the same inputs
/// always give the same sentences. It never guesses — every word comes from
/// a field the row or its facts carry.
extension TrayRowModel {
    /// Hard ceiling on the headline, in characters — a guard against a
    /// pathological title, not the thing that shapes the row.
    package static let headlineLimit = 96

    // MARK: - Headline

    /// The tray hero, by value. A wait leads with what the person must
    /// recognise to answer (the task, else the project); a process-only row
    /// says what little is true; a session leads with its task (a stable line
    /// the eye can find), then the agent's fresh last words, then the
    /// project.
    package static func headline(_ row: AgentRow, facts: SessionFacts = SessionFacts(), lang: ResolvedLanguage, nowMs: Int64) -> String {
        truncate(rawHeadline(row, facts: facts, lang: lang, nowMs: nowMs), headlineLimit)
    }

    private static func rawHeadline(_ row: AgentRow, facts: SessionFacts, lang: ResolvedLanguage, nowMs: Int64) -> String {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        let project = row.project
        switch row.status {
        case .needsYou:
            if let task = row.usefulTask { return task }
            return project.isEmpty ? t(.needsYou) : project
        case .processOnly:
            return row.canFocusTerminal ? t(.terminalDetectedNoDetails) : t(.appDetectedNoDetails)
        case .running, .yourTurn, .recent:
            if let task = row.usefulTask { return task }
            if !facts.lastWords.isEmpty, facts.selfReportFresh(at: nowMs) { return facts.lastWords }
            if !project.isEmpty { return project }
            return row.canFocusTerminal ? t(.terminalSession) : t(.appSession)
        }
    }

    // MARK: - Why

    /// Which evidence put the row in its state, and since when.
    package static func why(_ row: AgentRow, facts: SessionFacts = SessionFacts(), lang: ResolvedLanguage, nowMs: Int64) -> String {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        let name = row.agent.displayName
        func since(_ ms: Int64) -> String { ms > 0 ? L10n.ago(ms, nowMs: nowMs, lang) : "?" }
        let quiet = L10n.duration(facts.lastActivitySeconds(at: nowMs), lang)
        let last = facts.lastActivityMs
        switch row.status {
        case .needsYou(let block):
            var text = String(format: t(.explainAsked), name, kindNoun(block.kind, lang: lang), since(block.sinceMs))
            if block.inFront { text += t(.explainAskedFront) }
            return text
        case .yourTurn(let sinceMs):
            return String(format: t(.explainTurn), name, since(sinceMs))
        case .processOnly:
            return t(.explainProcessOnly)
        case .running(stalled: true):
            guard last > 0 else { return t(.explainStalledUnknown) }
            if let step = facts.lastStep {
                return String(format: t(.stepStalled), quiet, stepText(step))
            }
            return String(format: t(.explainStalled), quiet)
        case .running(stalled: false):
            guard last > 0 else { return t(.explainRunningNoClock) }
            return String(format: t(.explainRunning), name, since(last))
        // Which rule made it recent — never a guess that it runs.
        case .recent(.atPrompt):
            return String(format: t(.explainIdle), since(last))
        case .recent(.ended(let atMs)):
            return String(format: t(.explainEnded), since(atMs > 0 ? atMs : last))
        case .recent(.quiet):
            return String(format: t(.explainQuiet), quiet)
        case .recent(.silent):
            return String(format: t(.explainSilent), quiet)
        }
    }

    /// A wait kind as what the agent did: "asked for permission".
    package static func kindNoun(_ kind: AttentionKind, lang: ResolvedLanguage) -> String {
        switch kind {
        case .permission: return L10n.t(.explainKindPermission, lang)
        case .question: return L10n.t(.explainKindInput, lang)
        default: return L10n.t(.explainKindWaiting, lang)
        }
    }

    // MARK: - State

    /// The state in a word or two ("Needs you", "Running", "Your turn").
    package static func stateText(_ row: AgentRow, lang: ResolvedLanguage) -> String {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        switch row.status {
        case .needsYou: return t(.needsYou)
        case .processOnly: return t(.processOnly)
        case .yourTurn: return t(.yourTurn)
        case .recent: return t(.recent)
        case .running(let stalled): return stalled ? t(.stalled) : t(.running)
        }
    }

    /// A blocked row's question in the agent's words; nil when unknown.
    package static func ask(_ row: AgentRow) -> String? {
        guard let ask = row.wait?.ask.trimmingCharacters(in: .whitespacesAndNewlines), !ask.isEmpty else { return nil }
        return ask
    }

    // MARK: - Steps

    /// A step in the words a row uses: "Bash · swift test", or the tool
    /// alone. What was reported, never a claim that it still runs.
    package static func stepText(_ step: SessionBook.Step) -> String {
        step.target.isEmpty ? step.tool : "\(step.tool) · \(step.target)"
    }

    /// A step with its age: "Bash · swift test · 12m ago" — "now" below a
    /// minute, like the row's own time.
    package static func stepLine(_ step: SessionBook.Step, nowMs: Int64, lang: ResolvedLanguage) -> String {
        "\(stepText(step)) · \(L10n.ago(step.ms, nowMs: nowMs, lang))"
    }

    // MARK: - Time

    /// How long the current turn has run ("14m", "now" below a minute);
    /// "" when its start is not known.
    package static func turnDuration(_ facts: SessionFacts, nowMs: Int64, lang: ResolvedLanguage, spoken: Bool = false) -> String {
        guard facts.turnStartMs > 0, facts.turnStartMs <= nowMs else { return "" }
        return L10n.duration(Double(nowMs - facts.turnStartMs) / 1000, lang, spoken: spoken)
    }

    /// The row's one time: how long a wait has been outstanding ("4m"); for
    /// a running row this turn's duration, when its start is known; else
    /// when it last moved ("3m ago"). `spoken`: in full units, as VoiceOver
    /// says it ("4 minutes"). "" when the row has none.
    package static func rowTime(_ row: AgentRow, facts: SessionFacts = SessionFacts(), nowMs: Int64, lang: ResolvedLanguage, spoken: Bool = false) -> String {
        if let wait = row.wait {
            guard wait.sinceMs > 0 else { return "" }
            return L10n.duration(Double(nowMs - wait.sinceMs) / 1000, lang, spoken: spoken)
        }
        if row.isRunning {
            let turn = turnDuration(facts, nowMs: nowMs, lang: lang, spoken: spoken)
            if !turn.isEmpty { return turn }
        }
        guard facts.lastActivityMs > 0 else { return "" }
        return L10n.ago(facts.lastActivityMs, nowMs: nowMs, lang, spoken: spoken)
    }

    // MARK: - Focus

    /// The focus verb, as honest as the plan: "Go to terminal" only when a
    /// click can land on the exact pane, session or tab; "Open app" when it
    /// can only bring the app (or its folder) forward.
    package static func focusTitle(_ row: AgentRow, lang: ResolvedLanguage) -> String {
        switch row.landingPlan.precision {
        case .exact: return L10n.t(.focusExact, lang)
        case .app: return L10n.t(.focusApp, lang)
        case nil: return L10n.t(.focusOpenTray, lang)
        }
    }

    package static func truncate(_ s: String, _ n: Int) -> String {
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
/// events (the row and its `SessionFacts`), in the words the row uses
/// (`TrayRowModel`). Each thing is said
/// once: no headline block under a header that names it, no state-and-age
/// beside "This turn", no start time. How Pulse reads a session is not on
/// the page; it is in Settings → Hooks → "Copy report". Nothing is shown as
/// a placeholder: a fact Pulse does not have is not a row. Tokens, context,
/// cost, model and plan are never shown — a decision.
package struct DetailModel: Equatable {
    package struct Fact: Equatable {
        package var label: String
        package var value: String
    }

    /// What the detail page can ask for.
    package enum Action: Equatable { case back, focus, dismiss }

    package var lang: ResolvedLanguage
    package var key: SessionKey
    package var agent: AgentID
    package var lamp: Lamp
    /// `TrayRowModel.headline` — the page's title, in its header.
    package var headline: String
    package var headlineQuiet: Bool
    /// The full question of a blocked row.
    package var ask: String?
    /// `TrayRowModel.why` — nil when it is the row's own second line (a
    /// stalled row's why), which would say the same sentence twice.
    package var why: String?
    /// Up to `SessionBook.maxSteps` recent steps, newest first: how long
    /// ago, and "tool · target".
    package var steps: [Fact]
    package var lastMessage: String?
    package var error: String?
    /// This turn's duration (the page's one clock) and the folder.
    package var facts: [Fact]
    package var canFocus: Bool
    package var focusTitle: String
    package var canDismiss: Bool
    /// What the last Go did when it did not land exactly (`RowNotice`) —
    /// the same words as the row.
    package var notice: RowNotice? = nil

    package static func make(
        row: AgentRow,
        facts said: SessionFacts = SessionFacts(),
        lang: ResolvedLanguage,
        nowMs: Int64,
        notice: RowNotice? = nil
    ) -> DetailModel {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        typealias Words = TrayRowModel
        let fresh = said.selfReportFresh(at: nowMs)

        var facts: [Fact] = []
        if row.isRunning || row.isBlocked {
            let turn = Words.turnDuration(said, nowMs: nowMs, lang: lang)
            if !turn.isEmpty { facts.append(Fact(label: t(.stepThisTurn), value: turn)) }
        }
        if !row.displayPath.isEmpty { facts.append(Fact(label: t(.detailFolder), value: row.displayPath)) }

        let steps = said.steps.reversed().map { step in
            Fact(label: L10n.ago(step.ms, nowMs: nowMs, lang), value: Words.stepText(step))
        }
        let why = Words.why(row, facts: said, lang: lang, nowMs: nowMs)
        let second = Words.secondLine(row, facts: said, why: why, lang: lang, nowMs: nowMs)

        return DetailModel(
            lang: lang,
            key: row.key,
            agent: row.agent,
            lamp: row.lamp,
            headline: Words.headline(row, facts: said, lang: lang, nowMs: nowMs),
            headlineQuiet: row.isProcessOnly,
            ask: Words.ask(row),
            why: second?.text == why ? nil : why,
            steps: steps,
            lastMessage: fresh && !said.lastWords.isEmpty ? said.lastWords : nil,
            error: said.lastError.isEmpty ? nil : said.lastError,
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
package struct RowNotice: Equatable {
    package var text: String

    package init(text: String) {
        self.text = text
    }

    /// A Go that reached the app, not the exact terminal. When the plan
    /// tried an iTerm session or a Terminal / iTerm tab — AppleScript, which
    /// macOS lets run only once the person allowed it in its own Automation
    /// prompt — the notice says where that permission is; otherwise it says
    /// only where it landed. No button: macOS's prompt is the consent.
    package static func appOnly(row: AgentRow, lang: ResolvedLanguage) -> RowNotice {
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
package enum WaitAnnouncement {
    /// `previous`: the blocked count VoiceOver last knew (nil: the first
    /// scan — the baseline, never announced). `rows`: every row now.
    package static func text(previousBlocked: Int?, rows: [AgentRow], lang: ResolvedLanguage) -> String? {
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
