import Foundation

/// One Explain — what a row is doing, why Pulse says so, and why the lamp
/// is the colour it is. It says three things of a row:
///
/// - `headline` — what it is doing or asking: the tray hero;
/// - `why` — one sentence: which evidence put the row in its state, and
///   since when ("Claude's hook reported a permission request 4m ago",
///   "No new output for 23m", "Seen only as a process — no hook event
///   since Pulse started", "No event for 40m and no process Pulse can see");
/// - `source` — where the facts came from, in plain words.
///
/// and one of the menu-bar lamp: `lampRule` / `lampSentence`, the rule that
/// set its colour, in one sentence — the status item's whole tooltip.
///
/// Pure: the row, the language and the clock in; the same inputs always
/// give the same sentences. It never guesses — every word comes from a
/// field the row carries.
struct Explain: Equatable {
    var headline: String
    var why: String
    var source: String
    /// The state in a word or two ("Needs you", "Running", "Your turn").
    var state: String
    /// A blocked row's question in the agent's words; nil when unknown.
    var ask: String?

    /// Hard ceiling on the headline, in characters — a guard against a
    /// pathological title, not the thing that shapes the row.
    static let headlineLimit = 96

    static func make(_ row: AgentRow, lang: ResolvedLanguage, nowMs: Int64) -> Explain {
        let ask = row.wait.map { $0.ask.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        return Explain(
            headline: Self.truncate(Self.headline(row, lang: lang, nowMs: nowMs), Self.headlineLimit),
            why: Self.why(row, lang: lang, nowMs: nowMs),
            source: Self.sourceText(row.source, lang: lang),
            state: Self.stateText(row, lang: lang),
            ask: ask
        )
    }

    // MARK: - The lamp

    /// The rule that set the menu-bar lamp. The sentence names the rule;
    /// the tray names the sessions.
    enum LampRule: String, Equatable, Sendable {
        case blocked, stalled, running, processOnly, yourTurn, recent, idle
    }

    /// A grey lamp says the most useful thing that is true: a finished turn,
    /// then a live process Pulse can only see from outside, then recent
    /// sessions.
    static func lampRule(rows: [AgentRow], glance: GlanceKind) -> LampRule {
        switch glance {
        case .waiting: return .blocked
        case .stalled: return .stalled
        case .running: return .running
        case .idle:
            if rows.contains(where: \.isYourTurn) { return .yourTurn }
            if rows.contains(where: \.isProcessOnly) { return .processOnly }
            if rows.contains(where: \.isRecent) { return .recent }
            return .idle
        }
    }

    /// The one line the tooltip and VoiceOver say.
    static func lampSentence(_ rule: LampRule, lang: ResolvedLanguage) -> String {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        switch rule {
        case .blocked: return t(.lampRuleBlocked)
        case .stalled: return t(.lampRuleStalled)
        case .running: return t(.lampRuleRunning)
        case .processOnly: return t(.lampRuleProcessOnly)
        case .yourTurn: return t(.lampRuleTurn)
        case .recent: return t(.lampRuleRecent)
        case .idle: return t(.lampRuleIdle)
        }
    }

    // MARK: - Headline

    /// The tray hero, by value. A wait leads with what the person must
    /// recognise to answer (the task, else the project); a process-only row
    /// says what little is true; a session leads with its task (22.0 — a
    /// stable line the eye can find), then the agent's fresh last words, then
    /// the project.
    static func headline(_ row: AgentRow, lang: ResolvedLanguage, nowMs: Int64) -> String {
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
            var text = String(format: t(.explainHook), name, kind, since(wait.sinceMs))
            if wait.inFront { text += t(.explainHookFront) }
            return text
        case .yourTurn(let sinceMs):
            return String(format: t(.explainTurn), name, since(sinceMs))
        case .processOnly:
            return t(.explainProcessOnly)
        case .running:
            if row.isStalled {
                guard row.lastActivityMs > 0 else { return t(.explainStalledUnknown) }
                let quiet = DurationFormat.label(seconds: row.lastActivitySeconds(at: nowMs), lang: lang)
                return String(format: t(.explainStalled), quiet)
            }
            guard row.lastActivityMs > 0 else { return t(.explainRunningNoClock) }
            return String(format: t(.explainRunning), name, ago(row.lastActivityMs, nowMs: nowMs, lang: lang))
        case .recent:
            // 24.0: which rule made it recent — never a guess that it runs.
            switch row.recentReason {
            case .atPrompt:
                return String(format: t(.explainIdle), since(row.lastActivityMs))
            case .ended:
                return String(format: t(.explainEnded), since(row.stateSinceMs > 0 ? row.stateSinceMs : row.lastActivityMs))
            case .quiet:
                let quiet = DurationFormat.label(seconds: row.lastActivitySeconds(at: nowMs), lang: lang)
                return String(format: t(.explainQuiet), quiet)
            case .silent:
                let quiet = DurationFormat.label(seconds: row.lastActivitySeconds(at: nowMs), lang: lang)
                return String(format: t(.explainSilent), quiet)
            }
        }
    }

    /// A wait kind as the object of "reported …".
    static func kindNoun(_ kind: String, lang: ResolvedLanguage) -> String {
        switch kind {
        case "Permission": return L10n.t(.explainKindPermission, lang)
        case "Input": return L10n.t(.explainKindInput, lang)
        case "Waiting", "": return L10n.t(.explainKindWaiting, lang)
        default: return kind
        }
    }

    // MARK: - Source and state

    static func sourceText(_ source: RowSource, lang: ResolvedLanguage) -> String {
        switch source {
        case .hooks: return L10n.t(.sourceHooks, lang)
        case .process: return L10n.t(.sourceProcess, lang)
        }
    }

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

    // MARK: - Time

    /// "3m ago" / "3 分钟前", or "now" alone — never "now ago".
    static func ago(_ ms: Int64, nowMs: Int64, lang: ResolvedLanguage) -> String {
        let seconds = max(0, Double(nowMs - ms) / 1000)
        if seconds < 5 { return L10n.t(.durNow, lang) }
        return String(format: L10n.t(.agoFormat, lang), DurationFormat.label(seconds: seconds, lang: lang))
    }

    /// The row's trailing time: when it last moved. Below a minute it is
    /// simply "now" — the tray rescans every few seconds and nobody acts on
    /// the difference between 40 and 54 seconds.
    static func activityLabel(_ row: AgentRow, nowMs: Int64, lang: ResolvedLanguage) -> String {
        guard row.lastActivityMs > 0 else { return "" }
        let seconds = row.lastActivitySeconds(at: nowMs)
        if seconds < 60 { return L10n.t(.durNow, lang) }
        return String(format: L10n.t(.agoFormat, lang), DurationFormat.label(seconds: seconds, lang: lang))
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
