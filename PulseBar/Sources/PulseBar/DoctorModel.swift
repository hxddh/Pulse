import Foundation

/// 19.0 · the self-check: what this Mac can prove about Pulse's contracts
/// with the agents, as a value.
///
/// Every vendor contract Pulse depends on — 24.0: each agent's hook, plugin
/// or extension — was written from vendor source and tested on fixtures in CI.
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
        case installHooks, openConnections
    }

    /// Which finding Pulse can fix from the self-check, by what it asked for.
    static func fix(for check: Check, lang: ResolvedLanguage) -> Fix? {
        let c = Copy(lang: lang)
        switch check.next {
        case "": return nil
        case c.installHooks, c.reinstallHooks: return .installHooks
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

    struct HookFire: Equatable, Sendable {
        var kind: String
        var tsMs: Int64
    }

    struct Facts: Equatable, Sendable {
        var version: String = PulseVersion.semver
        var channel: String = ""
        var macOS: String = ""

        /// 24.0: each agent's hook as installed, keyed by agent raw value.
        var hooks: [String: AgentHooks] = [:]
        /// Newest hook event per agent, from `attention.tsv`.
        var lastFire: [String: HookFire] = [:]

        /// Codex's legacy `notify` line carries Pulse's hook.
        var codexNotifyInstalled = false

        var nowMs: Int64 = 0
    }

    /// One agent's hook as installed (24.0).
    struct AgentHooks: Equatable, Sendable {
        /// The vendor's own directory exists on this Mac.
        var present = false
        /// Contract events whose entry carries Pulse's command.
        var events: Set<String> = []
        /// The config is not its format (invalid JSON); Pulse leaves it.
        var unreadable = false
        /// Pulse entries on events Pulse must never use — an old or foreign
        /// install (23.0's PreToolUse, Codex's PermissionRequest).
        var forbidden: Set<String> = []
    }

    /// Events a Pulse entry must never sit on for this agent: every gating
    /// event, and Codex's PermissionRequest, which fires before its own
    /// auto-review.
    static func forbiddenEvents(_ agent: AgentID) -> Set<String> {
        agent == .codex ? HookContract.gatingEvents.union(["PermissionRequest"]) : HookContract.gatingEvents
    }

    /// A hook that has not fired for this long proves little about today.
    static let staleFireMs: Int64 = 7 * 24 * 60 * 60 * 1000

    // MARK: - Judgement

    static func evaluate(_ facts: Facts, lang: ResolvedLanguage) -> Report {
        let c = Copy(lang: lang)
        var checks: [Check] = []

        // 24.0: each agent's hook, then that it actually fires.
        for agent in AgentID.priority {
            checks += hookChecks(agent, facts: facts, c: c)
        }

        return Report(
            lang: lang,
            header: c.header(version: facts.version, channel: facts.channel, macOS: facts.macOS),
            checks: checks,
            ranAtMs: facts.nowMs
        )
    }

    private static func hookChecks(_ agent: AgentID, facts: Facts, c: Copy) -> [Check] {
        let raw = agent.rawValue
        let name = agent.displayName
        let id = "\(raw)-hooks"
        let title = c.agentHooks(name)
        let hooks = facts.hooks[raw] ?? AgentHooks()
        let notify = agent == .codex && facts.codexNotifyInstalled
        guard hooks.present || notify else {
            return [Check(id: id, title: title, verdict: .absent, detail: c.notInstalled(name))]
        }
        if hooks.unreadable {
            return [Check(id: id, title: title, verdict: .attention, detail: c.settingsUnreadable, next: c.fixSettings)]
        }
        if hooks.events.isEmpty, !notify {
            return [Check(id: id, title: title, verdict: .attention, detail: c.noHooks, next: c.installHooks)]
        }
        let wanted = agent.spec.hooks.events.map(\.name)
        let missing = wanted.filter { !hooks.events.contains($0) }
        let installed: Check
        if !hooks.forbidden.isEmpty {
            installed = Check(id: id, title: title, verdict: .attention, detail: c.gatingHook(hooks.forbidden.sorted()), next: c.reinstallHooks)
        } else if !missing.isEmpty {
            installed = Check(
                id: id, title: title,
                verdict: notify ? .unproven : .attention,
                detail: c.missing(missing) + (notify ? c.notifyOnly : ""),
                next: c.reinstallHooks
            )
        } else if agent == .codex {
            // The file cannot say whether Codex trusts it; only a fired
            // event can. So the install alone is "unproven".
            installed = Check(id: id, title: title, verdict: .unproven, detail: c.codexInstalledNeedsTrust, next: c.codexTrust)
        } else {
            let note = agent.waitingSource == .none ? c.noWaitNote : ""
            installed = Check(id: id, title: title, verdict: .works, detail: c.allEvents(wanted.count) + note)
        }
        return [installed, fireCheck(id: "\(raw)-fired", agent: agent, title: c.agentFired(name), facts: facts, c: c)]
    }

    private static func fireCheck(id: String, agent: AgentID, title: String, facts: Facts, c: Copy) -> Check {
        guard let fire = facts.lastFire[agent.rawValue] else {
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

        func agentHooks(_ name: String) -> String { f(.doctorAgentHooks, name) }
        func agentFired(_ name: String) -> String { f(.doctorAgentFired, name) }

        func notInstalled(_ agent: String) -> String { f(.doctorNotInstalled, agent) }
        var settingsUnreadable: String { t(.doctorSettingsUnreadable) }
        var fixSettings: String { t(.doctorFixSettings) }
        var noHooks: String { t(.doctorNoHooks) }
        var installHooks: String { t(.doctorInstallHooks) }
        var reinstallHooks: String { t(.doctorReinstallHooks) }
        func missing(_ items: [String]) -> String { f(.doctorMissing, L10n.joinNames(items, lang)) }
        func allEvents(_ n: Int) -> String { f(.doctorAllEvents, n) }

        var neverFired: String { t(.doctorNeverFired) }
        func useOnce(_ agent: AgentID) -> String {
            agent == .codex ? t(.doctorUseOnceCodex) : f(.doctorUseOnce, agent.displayName)
        }
        var noWaitNote: String { t(.doctorNoWaitNote) }
        func fired(_ kind: String, _ ageMs: Int64) -> String { f(.doctorFired, kind, ago(ageMs)) }
        func firedLongAgo(_ kind: String, _ ageMs: Int64) -> String { f(.doctorFiredLongAgo, kind, ago(ageMs)) }


        func gatingHook(_ events: [String]) -> String { f(.doctorGatingHook, L10n.joinNames(events, lang)) }
        var notifyOnly: String { t(.doctorNotifyOnly) }
        var codexInstalledNeedsTrust: String { t(.doctorCodexNeedsTrust) }
        var codexTrust: String { t(.doctorCodexTrust) }

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
