import Foundation

/// The tray row's face as a value.
///
/// One line — lamp · agent · project · headline · time — and a second line
/// only when the row has something to add: the ask of a blocked row, the why
/// of a stalled one, or — quietly — a running row's live tool ("Now: Bash ·
/// npm test · 3m", only while the agent says it has not finished — "+2" when
/// two more are going beside it) else its
/// last step ("Bash · swift test · 12m ago", a past step, never "running"),
/// or a failed turn's error ("Turn failed: …"); on a live row whose agent
/// reported a plan this turn, a quiet "3/7" beside the time. No chip, no tint, no "new"
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
            /// A running row's last step — quiet. A past step: never
            /// "running" (`surface_check`).
            case step
            /// The tool the agent said started and has not finished
            /// (`SessionFacts.running`) — quiet, "Now: …".
            case now
            /// The error a turn ended on — quiet; the lamp stays grey.
            case failure

            /// Said in small, quiet type.
            package var isQuiet: Bool {
                switch self {
                case .step, .now, .failure: return true
                case .ask, .warning: return false
                }
            }
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
    /// The plan's progress, "3/7", quietly, on a live row whose agent
    /// reported a plan this turn (`planBadge`); never red.
    package var planProgress: String?
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
        /// Pulse's hook is installed for the row's agent — what a
        /// process-only row's why says it is waiting for.
        package var connected: Bool

        package init(
            row: AgentRow, facts: SessionFacts = SessionFacts(), lang: ResolvedLanguage, nowMs: Int64,
            notice: RowNotice? = nil, connected: Bool = true
        ) {
            self.row = row
            self.facts = facts
            self.lang = lang
            self.nowMs = nowMs
            self.notice = notice
            self.connected = connected
        }
    }

    package static func make(_ input: Input) -> TrayRowModel {
        let row = input.row
        let facts = input.facts
        let lang = input.lang
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        let headline = Self.headline(row, facts: facts, lang: lang, nowMs: input.nowMs)
        let why = Self.why(row, facts: facts, lang: lang, nowMs: input.nowMs, connected: input.connected)
        let lamp = row.lamp
        let age = Self.rowTime(row, facts: facts, nowMs: input.nowMs, lang: lang)
        let place = row.project
        let project = place == headline ? "" : place
        let second = secondLine(row, facts: facts, why: why, lang: lang, nowMs: input.nowMs)
        let turnLabel = row.isYourTurn ? t(.yourTurn) : nil
        let plan = Self.planBadge(row, facts: facts)

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
        if let second, !second.kind.isQuiet { spoken.append(second.text) } else { spoken.append(why) }
        if let second, second.kind.isQuiet { spoken.append(second.text) }
        if let plan { spoken.append(String(format: t(.rowPlanSpoken), plan)) }

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
            planProgress: plan,
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
    /// (the why, which names the last step), for a running row whose agent
    /// said a tool started and has not finished (that tool, "Now: …") or
    /// named a step (the step, quietly), and for a turn that ended on an
    /// error with words (the error's first line, quietly). Everything else
    /// is one line — a running row whose hook has named no tool yet among
    /// them.
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
            // Only the agent's own "started, not finished" says a tool is
            // live; a finished step never does.
            // Several tools going at once: the newest, and how many others
            // ("Now: Bash · npm test · 3m +2").
            if let live = facts.running {
                var text = truncate(nowLine(live, nowMs: nowMs, lang: lang), 132)
                let others = facts.runningSteps.count - 1
                if others > 0 { text += " +\(others)" }
                return SecondLine(kind: .now, text: text)
            }
            guard let step = facts.lastStep else { return nil }
            return SecondLine(kind: .step, text: truncate(stepLine(step, nowMs: nowMs, lang: lang), 140))
        case .yourTurn:
            guard facts.failedTurn, !facts.lastError.isEmpty else { return nil }
            return SecondLine(kind: .failure, text: truncate(String(format: L10n.t(.failedTurnLine, lang), facts.lastError), 140))
        case .recent, .processOnly:
            return nil
        }
    }
}

// MARK: - The words

/// What a row is doing and why Pulse says so, in plain words:
///
/// - `headline` — what it is doing or asking: the tray hero;
/// - `why` — one sentence: what put the row in its state and since when
///   ("Asked permission · 4m ago", "Turn failed · 2m ago", "Stopped by you
///   · now", "Nothing new for 23m", "Started before Pulse — details after
///   its next step"). The vendor's event names are not in it — they are in
///   the detail page's timeline and Settings → Hooks. The agent's name is
///   the row's icon; never the word "hook" — `surface_check.py` holds it.
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
            return t(.sessionNoTitle)
        }
    }

    // MARK: - Why

    /// What put the row in its state, and since when — in the words the
    /// timeline and the banner use for the same thing; `connected`: Pulse's
    /// hook is installed for the agent (a process-only row is waiting for
    /// its next step, else for Pulse to connect it).
    package static func why(
        _ row: AgentRow, facts: SessionFacts = SessionFacts(), lang: ResolvedLanguage, nowMs: Int64, connected: Bool = true
    ) -> String {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        func since(_ ms: Int64) -> String { ms > 0 ? L10n.ago(ms, nowMs: nowMs, lang) : "?" }
        func said(_ what: String, at ms: Int64) -> String {
            String(format: t(.explainWhen), what, since(ms))
        }
        let quiet = L10n.duration(facts.lastActivitySeconds(at: nowMs), lang)
        let last = facts.lastActivityMs
        switch row.status {
        case .needsYou(let block):
            var text = said(L10n.waitKind(block.kind, lang), at: block.sinceMs)
            if block.inFront { text += t(.explainAskedFront) }
            return text
        case .yourTurn(let sinceMs):
            return said(t(facts.failedTurn ? .timelineFailed : .explainTurn), at: sinceMs)
        case .processOnly:
            return t(connected ? .explainProcessOnly : .explainProcessOnlyUnconnected)
        case .running(stalled: true):
            guard last > 0 else { return t(.explainStalledUnknown) }
            if let step = facts.lastStep {
                return String(format: t(.stepStalled), quiet, stepText(step))
            }
            return String(format: t(.explainStalled), quiet)
        case .running(stalled: false):
            guard last > 0 else { return t(.explainRunningNoClock) }
            return said(t(.timelineWorking), at: last)
        // Which rule made it recent — never a guess that it runs.
        case .recent(.atPrompt):
            return said(t(facts.stopped ? .timelineStopped : .timelineAtPrompt), at: last)
        case .recent(.ended(let atMs)):
            return said(t(.explainEnded), at: atMs > 0 ? atMs : last)
        case .recent(.quiet):
            return String(format: t(.explainQuiet), quiet)
        case .recent(.silent):
            return String(format: t(.explainSilent), quiet)
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
    /// minute, like the row's own time; "Subagent · Grep · TODO · …" when a
    /// subagent took it, "… · failed · 1m ago" when it failed.
    package static func stepLine(_ step: SessionBook.Step, nowMs: Int64, lang: ResolvedLanguage) -> String {
        var text = stepText(step)
        if !step.sub.isEmpty { text = String(format: L10n.t(.timelineBySubagent, lang), text) }
        if step.failed { text += " · " + L10n.t(.stepFailedMark, lang) }
        return "\(text) · \(L10n.ago(step.ms, nowMs: nowMs, lang))"
    }

    /// The live tool — the one the agent said started and has not finished
    /// (`SessionFacts.running`, never a finished step): "Now: Bash · npm
    /// test · 3m", how long it has been going; no time below a minute.
    /// Its own words, never a step's (`surface_check`).
    package static func nowLine(_ live: SessionBook.Step, nowMs: Int64, lang: ResolvedLanguage) -> String {
        var text = stepText(live)
        if !live.sub.isEmpty { text = String(format: L10n.t(.timelineBySubagent, lang), text) }
        var line = String(format: L10n.t(.stepNow, lang), text)
        let seconds = Double(nowMs - live.ms) / 1000
        if live.ms > 0, seconds >= 60 { line += " · " + L10n.duration(seconds, lang) }
        return line
    }

    /// How long one step ran, from the vendor's `took`: "2.3s" / "2.3秒"
    /// below a minute, else one unit ("4m"); "" unknown.
    package static func tookText(_ ms: Int64, lang: ResolvedLanguage) -> String {
        guard ms > 0 else { return "" }
        let seconds = Double(ms) / 1000
        if seconds >= 60 { return L10n.duration(seconds, lang) }
        return String(format: L10n.t(.stepTook, lang), String(format: "%.1f", seconds))
    }

    // MARK: - Timeline

    /// One heard line's words on the timeline: what it did, how long a
    /// single step ran ("Bash · swift test · 2.3s"), marked "Subagent · …"
    /// when a subagent said it.
    package static func heardText(_ heard: SessionBook.Heard, lang: ResolvedLanguage) -> String {
        var text = heard.effect.text(lang)
        if case .steps(let run) = heard.effect, run.count == 1 {
            let took = tookText(heard.tookMs, lang: lang)
            if !took.isEmpty { text += " · " + took }
        }
        return heard.sub.isEmpty ? text : String(format: L10n.t(.timelineBySubagent, lang), text)
    }

    /// This turn as the detail page says it: "14m · 23 steps (2 failed)" —
    /// the duration when its start is known, the steps when any were
    /// taken; "" when neither.
    package static func turnText(_ facts: SessionFacts, nowMs: Int64, lang: ResolvedLanguage) -> String {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        var parts: [String] = []
        let duration = turnDuration(facts, nowMs: nowMs, lang: lang)
        if !duration.isEmpty { parts.append(duration) }
        if facts.turnSteps > 0 {
            var steps = facts.turnSteps == 1 ? t(.turnStepsOne) : String(format: t(.turnStepsN), facts.turnSteps)
            if facts.turnFailedSteps > 0 { steps = String(format: t(.turnStepsFailed), steps, facts.turnFailedSteps) }
            parts.append(steps)
        }
        return parts.joined(separator: " · ")
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
/// row's second line did not already say it), **Now** — while the turn is
/// live, every tool the agent said started and has not finished, each with
/// how long it has been going, and every subagent whose start was heard and
/// whose end was not — then **This turn** (its clock and steps, the prompt,
/// the tools it ran, the files it changed, the skills, MCP servers and
/// subagents it used, the plan's progress, how the session started and why
/// it ended — each only when known; `TurnDigest`), the timeline of what
/// Pulse heard (a run of steps is one entry, its steps disclosed under it on
/// request — `stepsShown`), the agent's last message, the last error and
/// the folder — all from the session's own events (the row and its
/// `SessionFacts`), in the words the row uses (`TrayRowModel`). Each thing
/// is said once: no headline block under a header that names it, no
/// state-and-age beside "This turn", no start time, no prompt that is the
/// title. How Pulse reads a session is not on the page; it is in Settings →
/// Hooks → "Copy report". Nothing is shown as a placeholder: a fact Pulse
/// does not have is not a row. Tokens, context, cost, model and billing
/// plan are never shown — a decision. (The agent's own to-do plan, its
/// `meta` `plan`, is a fact of the turn and is shown.)
package struct DetailModel: Equatable {
    package struct Fact: Equatable {
        package var label: String
        package var value: String
        /// One item per line (the files): drawn on as many lines as it has.
        package var multiline = false
    }

    /// One step behind a timeline entry: "Edit · Sources/App.swift · 1.2s",
    /// and whether it failed.
    package struct StepLine: Equatable {
        package var text: String
        package var failed: Bool
    }

    /// One heard line on the timeline: how long ago, the vendor's event
    /// ("" when it is not a name) and what it did; for a run of steps, the
    /// steps behind it (`steps`, the newest `SessionBook.maxStepsPerEntry`)
    /// and how many earlier ones it no longer holds.
    package struct Entry: Equatable {
        package typealias Tone = SessionBook.Effect.Tone
        package var time: String
        package var event: String
        package var effect: String
        package var tone: Tone
        /// The steps a run is made of, oldest first; empty for anything
        /// that is not a run of two or more.
        package var steps: [StepLine] = []
        /// Steps of the run older than those it keeps.
        package var earlier = 0

        /// A run whose steps can be disclosed.
        package var discloses: Bool { !steps.isEmpty }
    }

    /// What the detail page can ask for.
    package enum Action: Equatable {
        case back, focus, dismiss
        /// Show or hide the steps behind every run on the timeline.
        case toggleSteps
        /// Copy this turn's summary (`TurnSummary`) to the clipboard.
        case copySummary
    }

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
    /// Now: what the agent said started and has not finished, newest
    /// first, and its live subagents — only while the turn is live.
    package var now: [String] = []
    /// "This turn", or "Last turn" once the turn is over.
    package var turnHeading: String = ""
    /// This turn's facts (`TurnDigest` and the turn's clock), each only
    /// when known.
    package var turn: [Fact] = []
    /// Up to `SessionBook.maxTimeline` heard lines, newest first.
    package var timeline: [Entry]
    /// The steps behind each run are disclosed (`TrayKeys.State.disclosed`).
    package var stepsShown = false
    package var lastMessage: String?
    package var error: String?
    /// The folder.
    package var facts: [Fact]
    /// "This agent doesn't report waits" — only for an agent whose hook
    /// cannot (`WaitingSource.none`); nil otherwise.
    package var caveat: String?
    package var canFocus: Bool
    package var focusTitle: String
    package var canDismiss: Bool
    /// There is a turn to summarize: "Copy this turn's summary".
    package var canCopySummary = false
    /// What the last Go did when it did not land exactly (`RowNotice`) —
    /// the same words as the row.
    package var notice: RowNotice? = nil

    package static func make(
        row: AgentRow,
        facts said: SessionFacts = SessionFacts(),
        lang: ResolvedLanguage,
        nowMs: Int64,
        notice: RowNotice? = nil,
        connected: Bool = true,
        disclosed: Bool = false
    ) -> DetailModel {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        typealias Words = TrayRowModel
        let fresh = said.selfReportFresh(at: nowMs)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let live = row.isRunning || row.isBlocked
        let headline = Words.headline(row, facts: said, lang: lang, nowMs: nowMs)

        var facts: [Fact] = []
        if !row.displayPath.isEmpty { facts.append(Fact(label: t(.detailFolder), value: row.displayPath)) }

        let timeline: [Entry] = said.timeline.reversed().map { heard in
            var entry = Entry(
                time: L10n.ago(min(heard.ms, nowMs), nowMs: nowMs, lang),
                event: EventName.display(heard.event),
                effect: Words.heardText(heard, lang: lang),
                tone: heard.effect.tone
            )
            if case .steps(let run) = heard.effect, run.count > 1, !heard.steps.isEmpty {
                entry.steps = heard.steps.map { step in
                    StepLine(text: Words.stepDetailText(step, cwd: row.cwd, home: home, lang: lang), failed: step.failed)
                }
                entry.earlier = max(0, run.count - heard.steps.count)
            }
            return entry
        }
        let why = Words.why(row, facts: said, lang: lang, nowMs: nowMs, connected: connected)
        let second = Words.secondLine(row, facts: said, why: why, lang: lang, nowMs: nowMs)
        let turn = Words.turnFacts(row, facts: said, headline: headline, home: home, lang: lang, nowMs: nowMs)
        let summarizable = !row.isProcessOnly && (said.turnSteps > 0 || !said.lastPrompt.isEmpty || !said.digest.isEmpty)

        return DetailModel(
            lang: lang,
            key: row.key,
            agent: row.agent,
            lamp: row.lamp,
            headline: headline,
            headlineQuiet: row.isProcessOnly,
            ask: Words.ask(row),
            why: second?.text == why ? nil : why,
            now: live ? Words.nowItems(said, nowMs: nowMs, lang: lang) : [],
            turnHeading: t(live ? .stepThisTurn : .detailLastTurn),
            turn: turn,
            timeline: timeline,
            stepsShown: disclosed && timeline.contains(where: \.discloses),
            lastMessage: fresh && !said.lastWords.isEmpty ? said.lastWords : nil,
            error: said.lastError.isEmpty ? nil : said.lastError,
            facts: facts,
            caveat: row.agent.waitingSource == .none ? t(.detailNoWaits) : nil,
            canFocus: row.canFocusTerminal,
            focusTitle: Words.focusTitle(row, lang: lang),
            canDismiss: row.isBlocked,
            canCopySummary: summarizable,
            notice: notice
        )
    }
}

/// This turn's words — the detail page's Now and This turn, and the plan's
/// quiet suffix on the row. Pure, like every sentence here.
extension TrayRowModel {
    /// Tools named in "This turn" before the rest is "…".
    package static let toolsShown = 4
    /// Files listed in "This turn" before the rest is "+N".
    package static let filesShown = 5

    /// The row's quiet plan suffix, "3/7": only on a live row (running,
    /// stalled or blocked), only when the main agent reported a plan this
    /// turn. Never red, never a colour of its own.
    package static func planBadge(_ row: AgentRow, facts: SessionFacts) -> String? {
        guard row.isRunning || row.isBlocked, let plan = facts.turnPlan else { return nil }
        return "\(plan.done)/\(plan.total)"
    }

    /// "3/7 · Write the tests" — the plan's progress and the item in
    /// progress, when it named one.
    package static func planText(_ plan: SessionBook.PlanProgress) -> String {
        let progress = "\(plan.done)/\(plan.total)"
        return plan.now.isEmpty ? progress : "\(progress) · \(plan.now)"
    }

    /// One of the tools the agent said started and has not finished, on
    /// the detail page's Now: "Bash · npm test · 3m" — how long it has
    /// been going, from a minute on; "Subagent · …" when a subagent runs
    /// it. Only ever given an entry of `SessionFacts.runningSteps`.
    package static func liveText(_ live: SessionBook.Step, nowMs: Int64, lang: ResolvedLanguage) -> String {
        var text = stepText(live)
        if !live.sub.isEmpty { text = String(format: L10n.t(.timelineBySubagent, lang), text) }
        let seconds = Double(nowMs - live.ms) / 1000
        if live.ms > 0, seconds >= 60 { text += " · " + L10n.duration(seconds, lang) }
        return text
    }

    /// The detail page's Now: every tool still going, newest first, then
    /// every live subagent — "Subagent · Explore · 6 steps".
    package static func nowItems(_ facts: SessionFacts, nowMs: Int64, lang: ResolvedLanguage) -> [String] {
        var items: [String] = facts.runningSteps.reversed().map { liveText($0, nowMs: nowMs, lang: lang) }
        for subagent in facts.digest.liveSubagents {
            var parts: [String] = []
            if !subagent.type.isEmpty { parts.append(subagent.type) }
            if subagent.steps > 0 { parts.append(stepsText(subagent.steps, lang: lang)) }
            if parts.isEmpty {
                items.append(L10n.t(.detailSubagents, lang))
            } else {
                items.append(String(format: L10n.t(.timelineBySubagent, lang), parts.joined(separator: " · ")))
            }
        }
        return items
    }

    /// "1 step" / "6 steps".
    package static func stepsText(_ count: Int, lang: ResolvedLanguage) -> String {
        count == 1 ? L10n.t(.turnStepsOne, lang) : String(format: L10n.t(.turnStepsN, lang), count)
    }

    /// One step behind a run, as the detail page discloses it: "Edit ·
    /// Sources/App.swift · 1.2s" — its target relative to the session's
    /// folder when it is a path inside it, "· failed" when it failed, how
    /// long it ran when the vendor said; "Subagent · …" for a subagent's.
    package static func stepDetailText(_ step: SessionBook.Step, cwd: String, home: String, lang: ResolvedLanguage) -> String {
        var shown = step
        shown.target = TitleHeuristics.relativePath(step.target, cwd: cwd, home: home)
        var text = stepText(shown)
        if !step.sub.isEmpty { text = String(format: L10n.t(.timelineBySubagent, lang), text) }
        if step.failed { text += " · " + L10n.t(.stepFailedMark, lang) }
        let took = tookText(step.tookMs, lang: lang)
        if !took.isEmpty { text += " · " + took }
        return text
    }

    /// The main agent's tools this turn, the most used first: "Edit 9 ·
    /// Bash 6 · Read 5"; at most `limit` (nil: all), then "…".
    package static func toolsText(_ digest: TurnDigest, limit: Int? = TrayRowModel.toolsShown) -> String {
        let tools = digest.toolsByCount
        let shown = limit.map { Array(tools.prefix($0)) } ?? tools
        var text = shown.map { "\($0.name) \($0.count)" }.joined(separator: " · ")
        if shown.count < tools.count { text += " · …" }
        return text
    }

    /// The files this turn changed, relative to the session's folder: at
    /// most `limit` (nil: all), then "+N" — "+N…" when more were heard than
    /// the digest keeps. One per line.
    package static func filesText(_ digest: TurnDigest, cwd: String, home: String, limit: Int? = TrayRowModel.filesShown) -> String {
        let files = digest.files.map { TitleHeuristics.relativePath($0, cwd: cwd, home: home) }
        let shown = limit.map { Array(files.prefix($0)) } ?? files
        var lines = shown
        let rest = files.count - shown.count
        if rest > 0 || digest.filesOverflowed {
            lines.append("+\(rest)" + (digest.filesOverflowed ? "…" : ""))
        }
        return lines.joined(separator: "\n")
    }

    /// The subagents this turn: "2 · Explore · worker", each type once
    /// ("Explore ×2" when two ran).
    package static func subagentsText(_ digest: TurnDigest, lang: ResolvedLanguage) -> String {
        var types: [TurnDigest.Count] = []
        for subagent in digest.subagents where !subagent.type.isEmpty {
            if let index = types.firstIndex(where: { $0.name == subagent.type }) {
                types[index].count += 1
            } else {
                types.append(TurnDigest.Count(name: subagent.type, count: 1))
            }
        }
        let count = String(format: L10n.t(.detailSubagentCount, lang), digest.subagents.count)
        return ([count] + types.map { $0.count > 1 ? "\($0.name) ×\($0.count)" : $0.name }).joined(separator: " · ")
    }

    /// How the session started, when it was not a plain start: "Resumed
    /// session", "After /clear"…; another word as the vendor said it; nil
    /// for a plain start or none.
    package static func startSourceText(_ source: String, lang: ResolvedLanguage) -> String? {
        switch source.lowercased() {
        case "", "startup", "new", "start", "init": return nil
        case "resume", "resumed": return L10n.t(.sourceResume, lang)
        case "clear": return L10n.t(.sourceClear, lang)
        case "compact": return L10n.t(.sourceCompact, lang)
        case "fork": return L10n.t(.sourceFork, lang)
        default: return source
        }
    }

    /// Why the session ended, in words; another word as the vendor said
    /// it; nil none.
    package static func endReasonText(_ reason: String, lang: ResolvedLanguage) -> String? {
        switch reason.lowercased() {
        case "": return nil
        case "clear": return L10n.t(.endClear, lang)
        case "logout": return L10n.t(.endLogout, lang)
        case "prompt_input_exit": return L10n.t(.endPromptExit, lang)
        case "quit", "exit": return L10n.t(.endQuit, lang)
        case "user_close": return L10n.t(.endUserClose, lang)
        case "archived": return L10n.t(.endArchived, lang)
        case "error": return L10n.t(.endError, lang)
        default: return reason
        }
    }

    /// This turn, as the detail page lists it — each fact only when known:
    /// its clock and steps ("14m · 23 steps (2 failed)", the clock only
    /// while the turn is live), the prompt (unless it is the headline), the
    /// main agent's tools, the files changed, the skills, the MCP servers,
    /// the subagents, the plan reported this turn, how the session started
    /// (unless plainly) and — for an ended session — why it ended.
    package static func turnFacts(
        _ row: AgentRow, facts said: SessionFacts, headline: String, home: String, lang: ResolvedLanguage, nowMs: Int64
    ) -> [DetailModel.Fact] {
        typealias Fact = DetailModel.Fact
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        guard !row.isProcessOnly else { return [] }
        let live = row.isRunning || row.isBlocked
        var facts: [Fact] = []
        let clock = live ? turnText(said, nowMs: nowMs, lang: lang) : stepsOnlyText(said, lang: lang)
        if !clock.isEmpty { facts.append(Fact(label: t(.stepThisTurn), value: clock)) }
        let prompt = TitleHeuristics.firstLine(said.lastPrompt, limit: 120)
        if !prompt.isEmpty, prompt != headline, prompt != row.task {
            facts.append(Fact(label: t(.detailPrompt), value: prompt))
        }
        let digest = said.digest
        let tools = toolsText(digest)
        if !tools.isEmpty { facts.append(Fact(label: t(.detailTools), value: tools)) }
        if !digest.files.isEmpty {
            facts.append(Fact(label: t(.detailFiles), value: filesText(digest, cwd: row.cwd, home: home), multiline: true))
        }
        if !digest.skills.isEmpty { facts.append(Fact(label: t(.detailSkills), value: digest.skills.joined(separator: " · "))) }
        if !digest.mcpServers.isEmpty { facts.append(Fact(label: t(.detailMCP), value: digest.mcpServers.joined(separator: " · "))) }
        if !digest.subagents.isEmpty { facts.append(Fact(label: t(.detailSubagents), value: subagentsText(digest, lang: lang))) }
        if let plan = said.turnPlan { facts.append(Fact(label: t(.detailPlan), value: planText(plan))) }
        if let source = startSourceText(said.startSource, lang: lang) { facts.append(Fact(label: t(.detailStarted), value: source)) }
        if case .recent(.ended) = row.status, let reason = endReasonText(said.endReason, lang: lang) {
            facts.append(Fact(label: t(.detailEnded), value: reason))
        }
        return facts
    }

    /// A finished turn's steps without a clock (its duration against now
    /// would be wrong): "23 steps (2 failed)"; "" none.
    package static func stepsOnlyText(_ facts: SessionFacts, lang: ResolvedLanguage) -> String {
        guard facts.turnSteps > 0 else { return "" }
        let steps = stepsText(facts.turnSteps, lang: lang)
        guard facts.turnFailedSteps > 0 else { return steps }
        return String(format: L10n.t(.turnStepsFailed, lang), steps, facts.turnFailedSteps)
    }
}

/// "Copy this turn's summary": the turn in plain text, for the person to
/// paste where they keep notes — the title, the agent, the prompt's first
/// line, the clock and steps, the tools, the files changed (relative to the
/// session's folder), the skills, MCP servers and subagents, the plan and
/// — once the turn is over — the last message's first line, in the
/// interface's language, each only when known.
///
/// Owner decision: unlike Settings → Hooks → "Copy report"
/// (`SettingsModel.report`), which is content-free by design (no path, no
/// prompt, no project — it is what a person sends when Pulse misbehaves),
/// this summary carries content — the prompt, the paths, the last words —
/// because the person asks for exactly that, of one session, with one
/// click, to their own clipboard. It is never written anywhere else. Pure.
package enum TurnSummary {
    package static func text(row: AgentRow, facts said: SessionFacts, lang: ResolvedLanguage, nowMs: Int64) -> String {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        typealias Words = TrayRowModel
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let colon = lang == .zh ? "：" : ": "
        var lines = [Words.headline(row, facts: said, lang: lang, nowMs: nowMs)]
        var agentLine = row.agent.displayName
        if !row.displayPath.isEmpty { agentLine += " · " + row.displayPath }
        lines.append(agentLine)
        func add(_ key: L10n.Key, _ value: String) {
            if !value.isEmpty { lines.append(t(key) + colon + value) }
        }
        add(.detailPrompt, TitleHeuristics.firstLine(said.lastPrompt, limit: 200))
        let live = row.isRunning || row.isBlocked
        add(.stepThisTurn, live ? Words.turnText(said, nowMs: nowMs, lang: lang) : Words.stepsOnlyText(said, lang: lang))
        let digest = said.digest
        add(.detailTools, Words.toolsText(digest, limit: nil))
        if !digest.files.isEmpty {
            lines.append(t(.detailFiles) + colon)
            let files = Words.filesText(digest, cwd: row.cwd, home: home, limit: nil)
            lines += files.split(separator: "\n").map { "  " + String($0) }
        }
        add(.detailSkills, digest.skills.joined(separator: " · "))
        add(.detailMCP, digest.mcpServers.joined(separator: " · "))
        if !digest.subagents.isEmpty { add(.detailSubagents, Words.subagentsText(digest, lang: lang)) }
        if let plan = said.turnPlan { add(.detailPlan, Words.planText(plan)) }
        // While the turn goes on, the last words are an earlier turn's.
        if !live { add(.detailLastMessage, TitleHeuristics.firstLine(said.lastWords, limit: 200)) }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// How a heard line is said: in a few words on the timeline ("Asked
/// permission" — the banner's and the why's words — "Answered", "Bash ·
/// swift test" as the row says a step, "Edit ×4 · Bash ×2" for a run, "Not
/// used — not an installed event"), how loud (`tone`), and in Copy report's
/// words (`reportWord`: a step by its tool alone — its target can be a path
/// or a command — an ignored line by a reason the receiver writes). One
/// table for the effects that carry nothing, so the three say one thing.
extension SessionBook.Effect {
    /// How loud a timeline line is.
    package enum Tone: Equatable, Sendable {
        /// The lamp went red.
        case alert
        /// A step or a turn failed.
        case failure
        /// It moved the session.
        case plain
        /// Heard, and nothing new: said again, held, status, ignored.
        case quiet
    }

    /// The words, report word and tone of an effect that carries nothing;
    /// nil for a step, a raise or an ignored line.
    private var named: (key: L10n.Key, word: String, tone: Tone)? {
        switch self {
        case .started: return (.timelineStarted, "started", .plain)
        case .prompt: return (.timelinePrompt, "prompt", .plain)
        case .working: return (.timelineWorking, "working", .plain)
        case .status: return (.timelineStatus, "status", .quiet)
        case .again: return (.timelineAgain, "same ask again", .quiet)
        case .answered: return (.timelineAnswered, "answered", .plain)
        case .yourTurn: return (.yourTurn, "your turn", .plain)
        case .turnEnded: return (.timelineTurnEnded, "turn ended in front", .plain)
        case .failed: return (.timelineFailed, "turn failed", .failure)
        case .held: return (.timelineHeld, "turn held", .quiet)
        case .atPrompt: return (.timelineAtPrompt, "at prompt", .quiet)
        case .resolved: return (.timelineResolved, "resolved", .plain)
        case .dismissed: return (.timelineDismissed, "dismissed", .plain)
        case .seen: return (.timelineSeen, "seen", .plain)
        case .stopped: return (.timelineStopped, "stopped", .plain)
        case .named: return (.timelineNamed, "named", .quiet)
        case .subagent: return (.timelineSubagent, "subagent lifecycle", .quiet)
        case .ended: return (.timelineEnded, "ended", .plain)
        case .steps, .raised, .skipped: return nil
        }
    }

    /// The timeline's words.
    package func text(_ lang: ResolvedLanguage) -> String {
        switch self {
        case .steps(let run):
            if run.count == 1, let tool = run.tools.first?.tool {
                let step = TrayRowModel.stepText(SessionBook.Step(tool: tool, target: run.target, ms: 0))
                return run.failed > 0 ? String(format: L10n.t(.timelineFailedStep, lang), step) : step
            }
            let tools = run.tools.map { $0.count > 1 ? "\($0.tool) ×\($0.count)" : $0.tool }.joined(separator: " · ")
            return run.failed > 0 ? String(format: L10n.t(.timelineStepsFailed, lang), tools, run.failed) : tools
        case .raised(let kind):
            return L10n.waitKind(kind, lang)
        case .skipped(let reason):
            return String(format: L10n.t(.timelineSkipped, lang), Connection.reasonText(reason, lang: lang))
        default:
            return named.map { L10n.t($0.key, lang) } ?? ""
        }
    }

    /// Red for a raise, the warning tone for a failure, quiet for a line
    /// that changed nothing anyone waits on.
    package var tone: Tone {
        switch self {
        case .steps(let run): return run.failed > 0 ? .failure : .plain
        case .raised: return .alert
        case .skipped: return .quiet
        default: return named?.tone ?? .plain
        }
    }

    /// Copy report's words.
    package var reportWord: String {
        switch self {
        case .steps(let run):
            if run.count == 1, let tool = run.tools.first?.tool {
                return (run.failed > 0 ? "failed step " : "step ") + Connection.reportEvent(tool)
            }
            let tools = run.tools.map { "\(Connection.reportEvent($0.tool))×\($0.count)" }.joined(separator: " ")
            return "steps \(tools)" + (run.failed > 0 ? " (\(run.failed) failed)" : "")
        case .raised(let kind):
            return "raised \(kind.rawValue)"
        case .skipped(let reason):
            return "not used (\(Connection.reportReason(reason)))"
        default:
            return named?.word ?? ""
        }
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
