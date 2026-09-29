import Foundation

/// 19.0 · the self-check: what this Mac can prove about Pulse's contracts
/// with the agents, as a value.
///
/// Every vendor contract Pulse depends on — `claude agents --json`, the
/// Claude and Codex hook files, Codex's rollout format — was written from vendor source and tested on fixtures in CI.
/// None of it had been run on a real Mac by the people building it. This
/// turns "needs real-machine confirmation" into one click: `DoctorProbe`
/// gathers `Facts` read-only, `evaluate` judges them here (pure, tested),
/// and the report the user may copy carries counts, names and ages only —
/// never a path under the home folder, a session id, a prompt or a cwd.
///
/// A check says only what the facts show. "Could not tell" is its own
/// verdict and is never rounded up to "works".
enum DoctorModel {
    enum Verdict: String, Equatable, Sendable {
        /// The facts show the contract working on this Mac.
        case works
        /// Installed / present, but nothing yet proves it runs.
        case unproven
        /// Something is missing or wrong, and the check says what to do.
        case attention
        /// Not applicable here (the agent is not installed).
        case absent
    }

    struct Check: Equatable, Identifiable, Sendable {
        var id: String
        var title: String
        var verdict: Verdict
        var detail: String
        /// What the user can do next; empty when nothing is needed.
        var next: String = ""
    }

    /// 21.0: the next step as a button, where Pulse can take it itself.
    enum Fix: Equatable, Sendable {
        case installHooks, copyShapeReport, openConnections
    }

    /// Which finding Pulse can fix from the self-check, by what it asked for.
    static func fix(for check: Check, lang: ResolvedLanguage) -> Fix? {
        let c = Copy(lang: lang)
        switch check.next {
        case "": return nil
        case c.installHooks, c.reinstallHooks: return .installHooks
        case c.reportShape: return .copyShapeReport
        case c.fixSettings: return .openConnections
        default: return nil
        }
    }

    struct Report: Equatable, Sendable {
        var lang: ResolvedLanguage
        var header: String
        var checks: [Check]
        var ranAtMs: Int64

        var counts: [Verdict: Int] {
            Dictionary(grouping: checks, by: \.verdict).mapValues(\.count)
        }
    }

    // MARK: - Facts

    /// What `claude agents --json` did, once, on the user's click.
    enum AgentsAnswer: Equatable, Sendable {
        case noCLI
        /// Non-zero exit or timeout — an older Claude without the command.
        case failed(exitStatus: Int32, timedOut: Bool)
        /// Exit 0 but the output is not the documented shape.
        case unreadable(bytes: Int)
        case parsed(sessions: Int, waiting: Int)
    }

    enum RolloutShape: String, Equatable, Sendable {
        /// No rollout written in the window looked at.
        case none
        /// `user_message` / `agent_message` event lines.
        case legacy
        /// 18.0: `item_completed` turn items (paginated history).
        case paginated
        /// Both kinds in one file.
        case mixed
        /// Lines Pulse reads neither way.
        case unknown
    }

    struct HookFire: Equatable, Sendable {
        var kind: String
        var tsMs: Int64
    }

    struct Facts: Equatable, Sendable {
        var version: String = PulseVersion.semver
        var channel: String = ""
        var macOS: String = ""

        var claudeInstalled = false
        var claudeAgents: AgentsAnswer = .noCLI
        /// Events whose hook list carries a Pulse command.
        var claudeHookEvents: Set<String> = []
        /// The matcher on Pulse's Notification entry, when there is one.
        var claudeNotificationMatcher: String?
        var claudeSettingsUnreadable = false
        /// Newest hook event per agent, from `attention.tsv`.
        var lastFire: [String: HookFire] = [:]

        var codexInstalled = false
        var codexHookEvents: Set<String> = []
        /// Pulse must never install this one (it fires before Codex's own
        /// auto-review) — seeing it means an old or foreign install.
        var codexPermissionHook = false
        var codexNotifyInstalled = false
        var codexRollout: RolloutShape = .none
        var codexCompressedRollouts = 0

        /// 20.0: how much Pulse actually read from each agent's sessions this
        /// run, keyed by agent raw value. A format that drifted does not fail
        /// — it reads less; this is where that shows.
        var readCoverage: [String: Coverage] = [:]

        var nowMs: Int64 = 0
    }

    struct Coverage: Equatable, Sendable {
        var name: String
        var sessions = 0
        var withTask = 0
        var withLastWord = 0
        /// Whether this agent's format carries the assistant's words at all.
        var expectsLastWord = true
    }

    /// What Pulse installs; a missing one is named.
    static let claudeEvents = [
        "Notification", "Stop", "StopFailure", "SubagentStart", "SubagentStop",
        "PermissionRequest", "PreToolUse", "UserPromptSubmit",
    ]
    static let codexEvents = ["Stop", "UserPromptSubmit"]
    /// Tokens the Notification matcher needs for questions to reach Pulse.
    static let matcherTokens = ["permission_prompt", "idle_prompt", "elicitation_dialog"]
    /// A hook that has not fired for this long proves little about today.
    static let staleFireMs: Int64 = 7 * 24 * 60 * 60 * 1000

    // MARK: - Judgement

    static func evaluate(_ facts: Facts, lang: ResolvedLanguage) -> Report {
        let c = Copy(lang: lang)
        var checks: [Check] = []

        // Claude · hooks installed
        if !facts.claudeInstalled {
            checks.append(Check(id: "claude-hooks", title: c.claudeHooks, verdict: .absent, detail: c.notInstalled("Claude Code")))
        } else if facts.claudeSettingsUnreadable {
            checks.append(Check(id: "claude-hooks", title: c.claudeHooks, verdict: .attention, detail: c.settingsUnreadable, next: c.fixSettings))
        } else {
            let missing = claudeEvents.filter { !facts.claudeHookEvents.contains($0) }
            let matcher = facts.claudeNotificationMatcher ?? ""
            let matcherGaps = matcherTokens.filter { !matcher.contains($0) }
            if facts.claudeHookEvents.isEmpty {
                checks.append(Check(id: "claude-hooks", title: c.claudeHooks, verdict: .attention, detail: c.noHooks, next: c.installHooks))
            } else if !missing.isEmpty || !matcherGaps.isEmpty {
                let gaps = missing + matcherGaps.map { "Notification:\($0)" }
                checks.append(Check(id: "claude-hooks", title: c.claudeHooks, verdict: .attention, detail: c.missing(gaps), next: c.reinstallHooks))
            } else {
                checks.append(Check(id: "claude-hooks", title: c.claudeHooks, verdict: .works, detail: c.allEvents(claudeEvents.count)))
            }
        }

        // Claude · hooks actually fire
        if facts.claudeInstalled, !facts.claudeHookEvents.isEmpty {
            checks.append(fireCheck(id: "claude-fired", agent: "claude", title: c.claudeFired, facts: facts, c: c))
        }

        // Claude · its own report of waiting sessions
        switch facts.claudeAgents {
        case .noCLI:
            checks.append(Check(
                id: "claude-agents", title: c.claudeAgents,
                verdict: facts.claudeInstalled ? .attention : .absent,
                detail: facts.claudeInstalled ? c.noCLI : c.notInstalled("Claude Code"),
                next: facts.claudeInstalled ? c.cliOnPath : ""
            ))
        case .failed(let status, let timedOut):
            checks.append(Check(
                id: "claude-agents", title: c.claudeAgents, verdict: .attention,
                detail: timedOut ? c.agentsTimedOut : c.agentsFailed(status),
                next: c.updateClaude
            ))
        case .unreadable(let bytes):
            checks.append(Check(
                id: "claude-agents", title: c.claudeAgents, verdict: .attention,
                detail: c.agentsUnreadable(bytes), next: c.reportShape
            ))
        case .parsed(let sessions, let waiting):
            checks.append(Check(id: "claude-agents", title: c.claudeAgents, verdict: .works, detail: c.agentsParsed(sessions, waiting)))
        }

        // Codex · hooks
        if !facts.codexInstalled {
            checks.append(Check(id: "codex-hooks", title: c.codexHooks, verdict: .absent, detail: c.notInstalled("Codex")))
        } else {
            let missing = codexEvents.filter { !facts.codexHookEvents.contains($0) }
            if facts.codexPermissionHook {
                checks.append(Check(id: "codex-hooks", title: c.codexHooks, verdict: .attention, detail: c.codexPermissionHook, next: c.reinstallHooks))
            } else if facts.codexHookEvents.isEmpty, !facts.codexNotifyInstalled {
                checks.append(Check(id: "codex-hooks", title: c.codexHooks, verdict: .attention, detail: c.noHooks, next: c.installHooks))
            } else if !missing.isEmpty {
                checks.append(Check(
                    id: "codex-hooks", title: c.codexHooks,
                    verdict: facts.codexNotifyInstalled ? .unproven : .attention,
                    detail: c.missing(missing) + (facts.codexNotifyInstalled ? c.notifyOnly : ""),
                    next: c.reinstallHooks
                ))
            } else {
                // The file cannot say whether Codex trusts it; only a fired
                // event can. So the install alone is "unproven".
                checks.append(Check(id: "codex-hooks", title: c.codexHooks, verdict: .unproven, detail: c.codexInstalledNeedsTrust, next: c.codexTrust))
            }
            if !facts.codexHookEvents.isEmpty || facts.codexNotifyInstalled {
                checks.append(fireCheck(id: "codex-fired", agent: "codex", title: c.codexFired, facts: facts, c: c))
            }
        }

        // Codex · the rollout format Pulse parses
        if facts.codexInstalled {
            let compressed = facts.codexCompressedRollouts > 0 ? c.compressed(facts.codexCompressedRollouts) : ""
            switch facts.codexRollout {
            case .none:
                checks.append(Check(id: "codex-rollout", title: c.codexRollout, verdict: .unproven, detail: c.noRollout + compressed))
            case .legacy, .paginated, .mixed:
                checks.append(Check(id: "codex-rollout", title: c.codexRollout, verdict: .works, detail: c.rollout(facts.codexRollout) + compressed))
            case .unknown:
                checks.append(Check(id: "codex-rollout", title: c.codexRollout, verdict: .attention, detail: c.rolloutUnknown + compressed, next: c.reportShape))
            }
        }

        // Reading · did the parsers get what the formats carry (20.0)
        checks.append(coverageCheck(facts.readCoverage, c: c))

        return Report(
            lang: lang,
            header: c.header(version: facts.version, channel: facts.channel, macOS: facts.macOS),
            checks: checks,
            ranAtMs: facts.nowMs
        )
    }

    /// Two or more sessions of an agent and not one title (or, where the
    /// format carries it, not one last word) is what a drifted format looks
    /// like from here. Fewer than half is a softer "cannot vouch".
    static let coverageMinimumSessions = 2

    private static func coverageCheck(_ coverage: [String: Coverage], c: Copy) -> Check {
        let read = coverage.values.filter { $0.sessions > 0 }
        guard !read.isEmpty else {
            return Check(id: "reading", title: c.reading, verdict: .absent, detail: c.noSessions)
        }
        var empty: [String] = []
        var thin: [String] = []
        for item in read.sorted(by: { $0.name < $1.name }) where item.sessions >= coverageMinimumSessions {
            let missingTask = item.withTask == 0
            let missingWords = item.expectsLastWord && item.withLastWord == 0
            if missingTask || missingWords {
                empty.append(c.coverageGap(item))
            } else if item.withTask * 2 < item.sessions || (item.expectsLastWord && item.withLastWord * 2 < item.sessions) {
                thin.append(c.coverageGap(item))
            }
        }
        let total = read.reduce(0) { $0 + $1.sessions }
        if !empty.isEmpty {
            return Check(id: "reading", title: c.reading, verdict: .attention, detail: empty.joined(separator: "; "), next: c.reportShape)
        }
        if !thin.isEmpty {
            return Check(id: "reading", title: c.reading, verdict: .unproven, detail: thin.joined(separator: "; "), next: c.reportShape)
        }
        return Check(id: "reading", title: c.reading, verdict: .works, detail: c.coverageFine(total, read.count))
    }

    private static func fireCheck(id: String, agent: String, title: String, facts: Facts, c: Copy) -> Check {
        guard let fire = facts.lastFire[agent] else {
            return Check(id: id, title: title, verdict: .unproven, detail: c.neverFired, next: c.useOnce(agent))
        }
        let age = max(0, facts.nowMs - fire.tsMs)
        if age > staleFireMs {
            return Check(id: id, title: title, verdict: .unproven, detail: c.firedLongAgo(fire.kind, age), next: c.useOnce(agent))
        }
        return Check(id: id, title: title, verdict: .works, detail: c.fired(fire.kind, age))
    }

    // MARK: - Export

    /// The text the user copies — the same checks, one per line, nothing
    /// the facts did not already reduce to counts and names.
    static func text(_ report: Report) -> String {
        let c = Copy(lang: report.lang)
        var lines = [report.header]
        for check in report.checks {
            lines.append("[\(c.verdict(check.verdict))] \(check.title): \(check.detail)")
            if !check.next.isEmpty { lines.append("    → \(check.next)") }
        }
        return redact(lines.joined(separator: "\n")) + "\n"
    }

    /// Belt and braces: the facts carry no paths, but a vendor's error text
    /// could. Anything that looks like a home path is cut to `~`.
    static func redact(_ text: String) -> String {
        var out = text
        for pattern in [#"/Users/[^/\s]+"#, #"/home/[^/\s]+"#] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                out = regex.stringByReplacingMatches(
                    in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "~"
                )
            }
        }
        return out
    }

    // MARK: - Copy

    /// The self-check's words, from `L10n` (23.0: the inline English/Chinese
    /// pairs that lived here were a second localization mechanism).
    struct Copy {
        var lang: ResolvedLanguage
        private func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        private func f(_ key: L10n.Key, _ args: CVarArg...) -> String { String(format: t(key), arguments: args) }

        func verdict(_ v: Verdict) -> String {
            switch v {
            case .works: return t(.doctorVerdictWorks)
            case .unproven: return t(.doctorVerdictUnproven)
            case .attention: return t(.doctorVerdictAttention)
            case .absent: return t(.doctorVerdictAbsent)
            }
        }

        func header(version: String, channel: String, macOS: String) -> String {
            f(.doctorHeader, version, channel, macOS)
        }

        var claudeHooks: String { t(.doctorClaudeHooks) }
        var claudeFired: String { t(.doctorClaudeFired) }
        /// A command's name, the same in every language.
        var claudeAgents: String { "claude agents --json" }
        var codexHooks: String { t(.doctorCodexHooks) }
        var codexFired: String { t(.doctorCodexFired) }
        var codexRollout: String { t(.doctorCodexRollout) }
        var reading: String { t(.doctorReading) }
        var noSessions: String { t(.doctorNoSessions) }
        func coverageGap(_ c: Coverage) -> String {
            let base = f(.doctorCoverageGap, c.name, c.sessions, c.withTask)
            return c.expectsLastWord ? base + f(.doctorCoverageGapWords, c.withLastWord) : base
        }
        func coverageFine(_ sessions: Int, _ agents: Int) -> String {
            f(.doctorCoverageFine, sessions, agents)
        }

        func notInstalled(_ agent: String) -> String { f(.doctorNotInstalled, agent) }
        var settingsUnreadable: String { t(.doctorSettingsUnreadable) }
        var fixSettings: String { t(.doctorFixSettings) }
        var noHooks: String { t(.doctorNoHooks) }
        var installHooks: String { t(.doctorInstallHooks) }
        var reinstallHooks: String { t(.doctorReinstallHooks) }
        func missing(_ items: [String]) -> String { f(.doctorMissing, L10n.joinNames(items, lang)) }
        func allEvents(_ n: Int) -> String { f(.doctorAllEvents, n) }

        var neverFired: String { t(.doctorNeverFired) }
        func useOnce(_ agent: String) -> String {
            agent == "codex" ? t(.doctorUseOnceCodex) : t(.doctorUseOnceClaude)
        }
        func fired(_ kind: String, _ ageMs: Int64) -> String { f(.doctorFired, kind, ago(ageMs)) }
        func firedLongAgo(_ kind: String, _ ageMs: Int64) -> String { f(.doctorFiredLongAgo, kind, ago(ageMs)) }

        var noCLI: String { t(.doctorNoCLI) }
        var cliOnPath: String { t(.doctorCLIOnPath) }
        var agentsTimedOut: String { t(.doctorAgentsTimedOut) }
        func agentsFailed(_ status: Int32) -> String { f(.doctorAgentsFailed, Int(status)) }
        var updateClaude: String { t(.doctorUpdateClaude) }
        func agentsUnreadable(_ bytes: Int) -> String { f(.doctorAgentsUnreadable, bytes) }
        var reportShape: String { t(.doctorReportShape) }
        func agentsParsed(_ n: Int, _ w: Int) -> String { f(.doctorAgentsParsed, n, w) }

        var codexPermissionHook: String { t(.doctorCodexPermissionHook) }
        var notifyOnly: String { t(.doctorNotifyOnly) }
        var codexInstalledNeedsTrust: String { t(.doctorCodexNeedsTrust) }
        var codexTrust: String { t(.doctorCodexTrust) }

        var noRollout: String { t(.doctorNoRollout) }
        func rollout(_ shape: RolloutShape) -> String {
            switch shape {
            case .legacy: return t(.doctorRolloutLegacy)
            case .paginated: return t(.doctorRolloutPaginated)
            case .mixed: return t(.doctorRolloutMixed)
            case .none, .unknown: return ""
            }
        }
        var rolloutUnknown: String { t(.doctorRolloutUnknown) }
        func compressed(_ n: Int) -> String { f(.doctorCompressed, n) }

        func ago(_ ms: Int64) -> String {
            let minutes = Int(ms / 60_000)
            if minutes < 1 { return t(.doctorAgoNow) }
            if minutes < 60 { return f(.doctorAgoMinutes, minutes) }
            let hours = minutes / 60
            if hours < 48 { return f(.doctorAgoHours, hours) }
            return f(.doctorAgoDays, hours / 24)
        }
    }
}
