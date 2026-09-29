import Foundation

/// 19.0 · the self-check: what this Mac can prove about Pulse's contracts
/// with the agents, as a value.
///
/// Every vendor contract Pulse depends on — `claude agents --json`, the
/// Claude and Codex hook files, Codex's rollout format, Respond's verdict
/// hand-off — was written from vendor source and tested on fixtures in CI.
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
        /// Newest hook event per agent, from `attention-history.json`.
        var lastFire: [String: HookFire] = [:]

        var codexInstalled = false
        var codexHookEvents: Set<String> = []
        /// Pulse must never install this one (it fires before Codex's own
        /// auto-review) — seeing it means an old or foreign install.
        var codexPermissionHook = false
        var codexNotifyInstalled = false
        var codexRollout: RolloutShape = .none
        var codexCompressedRollouts = 0

        var respondEnabled = false
        /// This run's local verdicts, by what became of them.
        var respondWritten = 0
        var respondTaken = 0
        var respondExpired = 0

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

        // Respond · the verdict hand-off (2.0 P0-0)
        if !facts.respondEnabled {
            checks.append(Check(id: "respond", title: c.respond, verdict: .absent, detail: c.respondOff))
        } else if facts.respondTaken > 0 {
            checks.append(Check(id: "respond", title: c.respond, verdict: .works, detail: c.respondTaken(facts.respondTaken, facts.respondWritten), next: c.respondShapeNote))
        } else if facts.respondWritten > 0 {
            checks.append(Check(
                id: "respond", title: c.respond, verdict: .attention,
                detail: c.respondUnclaimed(facts.respondWritten, facts.respondExpired), next: c.respondCheckHook
            ))
        } else {
            checks.append(Check(id: "respond", title: c.respond, verdict: .unproven, detail: c.respondNone, next: c.respondTry))
        }

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

    /// The self-check's words. Kept beside the judgement rather than in
    /// `L10n`: it is one diagnostic surface whose sentences are built from
    /// the facts, and splitting each across two files made them harder to
    /// keep exact.
    struct Copy {
        var lang: ResolvedLanguage
        private func s(_ en: String, _ zh: String) -> String { lang == .zh ? zh : en }

        func verdict(_ v: Verdict) -> String {
            switch v {
            case .works: return s("works", "已验证")
            case .unproven: return s("unproven", "未证实")
            case .attention: return s("attention", "需处理")
            case .absent: return s("n/a", "不适用")
            }
        }

        func header(version: String, channel: String, macOS: String) -> String {
            s("Pulse \(version) (\(channel)) · macOS \(macOS) · self-check",
              "Pulse \(version)（\(channel)）· macOS \(macOS) · 自检")
        }

        var claudeHooks: String { s("Claude hooks installed", "Claude hooks 已安装") }
        var claudeFired: String { s("Claude hooks reach Pulse", "Claude hooks 到达 Pulse") }
        var claudeAgents: String { s("claude agents --json", "claude agents --json") }
        var codexHooks: String { s("Codex hooks installed", "Codex hooks 已安装") }
        var codexFired: String { s("Codex hooks reach Pulse", "Codex hooks 到达 Pulse") }
        var codexRollout: String { s("Codex session log format", "Codex 会话记录格式") }
        var respond: String { s("Respond verdict hand-off", "Respond 裁决交接") }
        var reading: String { s("Session formats read in full", "会话格式读全了") }
        var noSessions: String { s("No session files read this run", "本次运行没有读到会话文件") }
        func coverageGap(_ c: Coverage) -> String {
            s("\(c.name): \(c.sessions) session(s), \(c.withTask) with a title" + (c.expectsLastWord ? ", \(c.withLastWord) with last words" : ""),
              "\(c.name)：\(c.sessions) 个会话，\(c.withTask) 个有标题" + (c.expectsLastWord ? "，\(c.withLastWord) 个有最后一句话" : ""))
        }
        func coverageFine(_ sessions: Int, _ agents: Int) -> String {
            s("\(sessions) session(s) from \(agents) agent(s), titles and words where the format carries them",
              "\(agents) 个 Agent 的 \(sessions) 个会话，格式里有的标题与话都读到了")
        }

        func notInstalled(_ agent: String) -> String { s("\(agent) is not installed on this Mac", "这台 Mac 没有安装 \(agent)") }
        var settingsUnreadable: String { s("The settings file is not valid JSON; Pulse will not edit it", "设置文件不是合法 JSON；Pulse 不会改它") }
        var fixSettings: String { s("Fix the JSON, then install hooks from Settings", "修好 JSON 后在设置里安装 hooks") }
        var noHooks: String { s("No Pulse hook found", "没有找到 Pulse 的 hook") }
        var installHooks: String { s("Settings → Waiting signals → Install hooks", "设置 → 等待信号 → 安装 hooks") }
        var reinstallHooks: String { s("Reinstall hooks from Settings to pick up this version's events", "在设置里重新安装 hooks，以获得这一版的事件") }
        func missing(_ items: [String]) -> String { s("Missing: \(items.joined(separator: ", "))", "缺少：\(items.joined(separator: "、"))") }
        func allEvents(_ n: Int) -> String { s("All \(n) events, questions included", "全部 \(n) 个事件，含提问") }

        var neverFired: String { s("No hook event recorded in the last day", "最近一天没有记录到 hook 事件") }
        func useOnce(_ agent: String) -> String {
            agent == "codex"
                ? s("Finish one Codex turn; if nothing arrives, run /hooks in Codex and trust Pulse's hooks", "在 Codex 里完成一轮；若仍没有，在 Codex 里运行 /hooks 并信任 Pulse 的 hooks")
                : s("Finish one Claude turn, then run the self-check again", "在 Claude 里完成一轮后再自检一次")
        }
        func fired(_ kind: String, _ ageMs: Int64) -> String { s("Last event: \(kind), \(ago(ageMs))", "最近事件：\(kind)，\(ago(ageMs))") }
        func firedLongAgo(_ kind: String, _ ageMs: Int64) -> String { s("Last event \(kind) was \(ago(ageMs)) — too old to prove today's install", "最近事件 \(kind) 在 \(ago(ageMs))——太久，证明不了现在的安装") }

        var noCLI: String { s("No claude executable found where Pulse looks", "在 Pulse 查找的位置没有 claude 可执行文件") }
        var cliOnPath: String { s("Install Claude Code's CLI, or ignore this if you only use hooks", "安装 Claude Code 命令行；只用 hooks 可忽略") }
        var agentsTimedOut: String { s("Timed out after 3 s", "3 秒超时") }
        func agentsFailed(_ status: Int32) -> String { s("Exited with status \(status) — this Claude may predate the command", "退出码 \(status)——这版 Claude 可能还没有这个命令") }
        var updateClaude: String { s("Update Claude Code; hooks keep working meanwhile", "升级 Claude Code；在此之前 hooks 照常工作") }
        func agentsUnreadable(_ bytes: Int) -> String { s("Answered \(bytes) bytes Pulse cannot read as the documented shape", "返回了 \(bytes) 字节，不是 Pulse 认识的格式") }
        var reportShape: String { s("Copy this report into an issue — the shape changed", "把这份报告贴进 issue——格式变了") }
        func agentsParsed(_ n: Int, _ w: Int) -> String { s("Read \(n) session(s), \(w) waiting", "读到 \(n) 个会话，其中 \(w) 个在等") }

        var codexPermissionHook: String { s("A PermissionRequest hook is installed; it fires before Codex's own review and would show waits that are not real", "装了 PermissionRequest hook；它在 Codex 自己审批之前触发，会显示并不存在的等待") }
        var notifyOnly: String { s(" (the older notify hook is present)", "（仍有旧的 notify hook）") }
        var codexInstalledNeedsTrust: String { s("Stop and UserPromptSubmit are installed; whether Codex trusts them only shows once one fires", "Stop 与 UserPromptSubmit 已安装；Codex 是否信任它们，要等触发一次才知道") }
        var codexTrust: String { s("Run /hooks in Codex once and trust Pulse's entries", "在 Codex 里运行一次 /hooks 并信任 Pulse 的条目") }

        var noRollout: String { s("No session log in the last week to look at", "最近一周没有可查看的会话记录") }
        func rollout(_ shape: RolloutShape) -> String {
            switch shape {
            case .legacy: return s("Classic event lines — parsed", "经典事件行——可解析")
            case .paginated: return s("Paginated turn items — parsed (18.0)", "分页 turn 条目——可解析（18.0）")
            case .mixed: return s("Both formats in one log — parsed", "同一记录里两种格式——都可解析")
            case .none, .unknown: return ""
            }
        }
        var rolloutUnknown: String { s("The newest log has neither format Pulse reads", "最新的记录两种格式都不是") }
        func compressed(_ n: Int) -> String { s(" · \(n) compressed older log(s) left alone", " · \(n) 个压缩的旧记录不读") }

        var respondOff: String { s("Answering this Mac's own agents is off", "回答本机 Agent 未开启") }
        func respondTaken(_ taken: Int, _ written: Int) -> String { s("\(taken) of \(written) verdict(s) this run were claimed by the hook", "本次运行 \(written) 个裁决中有 \(taken) 个被 hook 取走") }
        var respondShapeNote: String { s("Claimed means the hook read it. Whether Claude honoured the decision shows in the agent itself", "取走表示 hook 读到了它；Claude 是否照办，要看 Agent 本身的行为") }
        func respondUnclaimed(_ written: Int, _ expired: Int) -> String { s("\(written) verdict(s) written, none claimed, \(expired) expired", "写了 \(written) 个裁决，没有一个被取走，\(expired) 个已过期") }
        var respondCheckHook: String { s("Check that Claude's PermissionRequest hook is installed (above)", "确认上面的 Claude PermissionRequest hook 已安装") }
        var respondNone: String { s("No verdict written this run", "本次运行还没有写过裁决") }
        var respondTry: String { s("Deny one harmless request from Pulse, then run the self-check again", "在 Pulse 里拒绝一个无害的请求，然后再自检一次") }

        func ago(_ ms: Int64) -> String {
            let minutes = ms / 60_000
            if minutes < 1 { return s("just now", "刚刚") }
            if minutes < 60 { return s("\(minutes) min ago", "\(minutes) 分钟前") }
            let hours = minutes / 60
            if hours < 48 { return s("\(hours) h ago", "\(hours) 小时前") }
            return s("\(hours / 24) days ago", "\(hours / 24) 天前")
        }
    }
}
