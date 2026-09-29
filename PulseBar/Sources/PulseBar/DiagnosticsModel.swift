import Foundation

/// 23.0 · the Diagnostics window (it was "Health") as a value.
///
/// Problems first — what on this Mac stops Pulse from seeing, then what the
/// self-check found wrong — each with the one action that fixes it. Then
/// every agent on one line (icon · name · state · one fix), its details a
/// click away. The activity log is its own tab. One "Copy report". Pure: the
/// store supplies the sentences; this decides the order.
struct DiagnosticsModel: Equatable {
    enum Tab: String, CaseIterable, Equatable {
        case overview, activity
    }

    enum Fix: Equatable {
        case installHooks
        case openHooksSettings
        case doctor(DoctorModel.Fix)
    }

    struct Problem: Equatable, Identifiable {
        var id: String
        var text: String
        var detail: String = ""
        var fix: Fix?
        var fixTitle: String = ""
    }

    struct Agent: Equatable, Identifiable {
        var agent: AgentID
        var name: String
        /// The state in a word ("Available", "Needs action"…).
        var state: String
        var tone: PulseTheme.Tone
        /// Higher sorts first: what needs action before what merely works.
        var severity: Int
        var fix: Fix?
        var fixTitle: String = ""
        /// Said in orange on the collapsed line.
        var warning: String?
        /// Everything else, one sentence per line, shown on expansion.
        var details: [String]

        var id: AgentID { agent }
    }

    var lang: ResolvedLanguage
    /// When Pulse last read, how often, what it cost.
    var scanLine: String
    var problems: [Problem]
    var doctor: DoctorModel.Report?
    var doctorRunning: Bool
    var agents: [Agent]
    var activity: ActivityLogModel
    var activityAgents: [AgentID]
    var copied: Bool

    struct Input {
        var lang: ResolvedLanguage
        var scanLine: String
        /// Standing problems on this Mac (a hook missing, a stale bundle),
        /// already worded.
        var banners: [Problem]
        var doctor: DoctorModel.Report?
        var doctorRunning: Bool
        var agents: [Agent]
        var activity: ActivityLogModel
        var activityAgents: [AgentID]
        var copied: Bool
    }

    static func make(_ input: Input) -> DiagnosticsModel {
        var problems = input.banners
        if let report = input.doctor {
            for check in report.checks where check.verdict == .attention {
                let fix = DoctorModel.fix(for: check, lang: report.lang)
                problems.append(Problem(
                    id: "doctor-\(check.id)",
                    text: check.title,
                    detail: check.next.isEmpty ? check.detail : check.next,
                    fix: fix.map { .doctor($0) },
                    fixTitle: fix.map { fixTitle(.doctor($0), lang: input.lang) } ?? ""
                ))
            }
        }
        let order = AgentID.priority
        let agents = input.agents.sorted { a, b in
            if a.severity != b.severity { return a.severity > b.severity }
            return (order.firstIndex(of: a.agent) ?? 999) < (order.firstIndex(of: b.agent) ?? 999)
        }
        return DiagnosticsModel(
            lang: input.lang,
            scanLine: input.scanLine,
            problems: problems,
            doctor: input.doctor,
            doctorRunning: input.doctorRunning,
            agents: agents,
            activity: input.activity,
            activityAgents: input.activityAgents,
            copied: input.copied
        )
    }

    static func fixTitle(_ fix: Fix, lang: ResolvedLanguage) -> String {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        switch fix {
        case .installHooks, .doctor(.installHooks): return t(.installHooks)
        case .openHooksSettings, .doctor(.openConnections): return t(.setupWaitingSignals)
        }
    }

    /// The one action an agent's line offers: install a missing hook, or —
    /// for a live agent whose hook cannot report a wait — the Hooks section,
    /// which says so.
    static func fix(for item: AgentSupportHealth) -> Fix? {
        if item.disposition == .needsAction { return .installHooks }
        if item.agent.waitingSource == .none, item.sessionCount + item.processOnlyCount > 0 {
            return .openHooksSettings
        }
        return nil
    }

    /// The disposition as a severity, a tone and a word.
    static func severity(_ disposition: SupportDisposition) -> Int {
        switch disposition {
        case .needsAction: return 5
        case .unproven: return 4
        case .available: return 3
        case .noRecentSession: return 2
        case .notInstalled: return 1
        }
    }

    /// Red is for a blocked agent, so nothing here is red.
    static func tone(_ disposition: SupportDisposition) -> PulseTheme.Tone {
        switch disposition {
        case .needsAction, .unproven: return .attention
        case .available: return .running
        case .notInstalled, .noRecentSession: return .idle
        }
    }

    static func stateWord(_ disposition: SupportDisposition, lang: ResolvedLanguage) -> String {
        func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }
        switch disposition {
        case .needsAction: return t(.supportNeedsAction)
        case .unproven: return t(.supportUnproven)
        case .available: return t(.supportAvailable)
        case .notInstalled: return t(.supportNotInstalled)
        case .noRecentSession: return t(.supportNoRecentSession)
        }
    }
}
