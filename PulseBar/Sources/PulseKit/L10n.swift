import Foundation

/// The interface's language: the system's. Every Chinese — zh-Hans,
/// zh-Hant, zh-TW, zh-HK — reads the one Chinese table there is,
/// Simplified; everything else reads English.
package enum ResolvedLanguage {
    case en, zh

    /// The system's preferred language, as one of the two tables.
    package static var system: ResolvedLanguage {
        let code = Locale.preferredLanguages.first ?? "en"
        return code.hasPrefix("zh") ? .zh : .en
    }
}

package enum L10n {
    /// One key in one language.
    package static func t(_ key: Key, _ lang: ResolvedLanguage) -> String {
        let pair = key.copy
        switch lang {
        case .en: return pair.en
        case .zh: return pair.zh
        }
    }

    /// A wait in the one phrase every surface says it with — the banner's
    /// body, the row's second line when the agent gave no words, the why
    /// and the timeline: "Asked permission", "Asked a question", "Waiting
    /// for input".
    package static func waitKind(_ kind: AttentionKind, _ lang: ResolvedLanguage) -> String {
        switch kind {
        case .permission: return t(.kindPermission, lang)
        case .question: return t(.kindInput, lang)
        default: return t(.kindWaiting, lang)
        }
    }

    /// Joins a list of agent display names the way the language does it.
    package static func joinNames(_ names: [String], _ lang: ResolvedLanguage) -> String {
        names.joined(separator: lang == .zh ? "、" : ", ")
    }

    /// A duration as the interface writes it — drawn "4m" / "4分钟",
    /// spoken "4 minutes" / "4分钟" — in one unit, rounded down; "now" /
    /// "刚刚" below a minute (one key, so nothing is redrawn every tick).
    /// `DateComponentsFormatter`, in the interface's language. Pure.
    package static func duration(_ seconds: Double, _ lang: ResolvedLanguage, spoken: Bool = false) -> String {
        guard seconds >= 60 else { return t(.now, lang) }
        let unit: Double = seconds >= 3600 ? 3600 : 60
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: lang == .zh ? "zh-Hans" : "en")
        let formatter = DateComponentsFormatter()
        formatter.calendar = calendar
        formatter.unitsStyle = spoken ? .full : .abbreviated
        formatter.allowedUnits = [.hour, .minute]
        formatter.maximumUnitCount = 1
        return formatter.string(from: (seconds / unit).rounded(.down) * unit) ?? t(.now, lang)
    }

    /// How long ago `ms` was, against the caller's clock: "12m ago" /
    /// "12分钟前" (spoken "12 minutes ago"), or "now" alone — never "now ago".
    package static func ago(_ ms: Int64, nowMs: Int64, _ lang: ResolvedLanguage, spoken: Bool = false) -> String {
        let seconds = Double(nowMs - ms) / 1000
        guard seconds >= 60 else { return t(.now, lang) }
        return String(format: t(.agoFormat, lang), duration(seconds, lang, spoken: spoken))
    }

    /// Every string Pulse says. `CaseIterable` so tests can assert every key
    /// resolves in both languages and that format specifiers match (a
    /// mismatched %d crashes `String(format:)`).
    package enum Key: CaseIterable {
        case noAgents
        case noAgentsDetected
        case needsYou
        case waitingN
        case runningN
        case recentN
        case recent
        case settings
        case quit
        case focusExact
        case focusApp
        case focusOpenTray
        case ignoreWait
        case focusFailed
        case focusAppOnly
        case general
        case launchAtLogin
        case hooksHint
        case installHooks
        case running
        case settingsTitle
        case hooksUnknown
        case hooksMissing
        case hooksInstalledCount
        case hooksFailed
        case hooksWorking
        case hooksAgentFailed
        case hooksFailureInvalidJSON
        case hooksFailureNotOurs
        case hooksFailureUnwritable
        case hooksFailureHasComments
        case hooksFailureShape
        case kindPermission
        case kindInput
        case kindWaiting
        case terminalDetectedNoDetails
        case appDetectedNoDetails
        case versionMismatchHint
        case notificationsSection
        case notifyNotConfigured
        case enableNotifications
        case notifyDenied
        case openNotificationSettings
        case uninstallHooks
        case emptyHint
        case a11yIdle
        case moreActions
        case agoFormat
        case now
        case stalled
        case notifFocus
        case buildPreview
        case releases
        case notifyAllowed
        case yourTurn
        case settingsHooksTitle
        case settingsHookAbsent
        case settingsReportHint
        case settingsHookInstalled
        case settingsHookNoEvent
        case settingsHookHeard
        case settingsHookHeardUnnamed
        case settingsHookIgnored
        case settingsHookPartial
        case settingsHookStale
        case settingsHookUpdateHint
        case ignoredNoEvent
        case ignoredNotInstalled
        case ignoredUnparsable
        case ignoredCannotWait
        case ignoredNoSession
        case ignoredSilent
        case ignoredNotABlock
        case ignoredNoPrompt
        case ignoredOtherSession
        case ignoredOtherHost
        case ignoredOther
        case settingsHookConfigDir
        case settingsHookTurnedOff
        case settingsHookManagedOnly
        case settingsHookNeverHeard
        case waitingBannerFailed
        case lampRuleBlocked
        case lampRuleStalled
        case lampRuleRunning
        case lampRuleTurn
        case lampRuleRecent
        case lampRuleIdle
        case details
        case detailBack
        case explainWhen
        case explainAskedFront
        case explainTurn
        case explainProcessOnly
        case explainStalled
        case explainStalledUnknown
        case explainRunningNoClock
        case detailFolder
        case processOnly
        case processOnlyN
        case waiting1
        case stalledN
        case yourTurnN
        case lampRuleProcessOnly
        case copyReport
        case noticeNotificationsDenied
        case noticeNotificationsOff
        case settingsHooksSection
        case detailLastMessage
        case detailErrorHeading
        case explainEnded
        case explainQuiet
        case explainSilent
        case setupFound
        case setupConnect
        case setupDone
        case setupGotIt
        case setupStepCodex
        case setupStepRestart
        case focusAppOnlyAutomation
        case stepStalled
        case timelineHeading
        case timelineStarted
        case timelinePrompt
        case timelineWorking
        case timelineStatus
        case timelineAgain
        case timelineAnswered
        case timelineTurnEnded
        case timelineFailed
        case timelineHeld
        case timelineAtPrompt
        case timelineResolved
        case timelineDismissed
        case timelineSeen
        case timelineEnded
        case timelineSkipped
        case timelineFailedStep
        case timelineStopped
        case timelineNamed
        case timelineSubagent
        case timelineBySubagent
        case stepThisTurn
        case setupFailedAction
        case menuOpenPulse
        case menuAbout
        case menuEdit
        case menuUndo
        case menuRedo
        case menuCut
        case menuCopy
        case menuPaste
        case menuSelectAll
        case menuWindow
        case menuClose
        case menuMinimize
        case loginItemNeedsApproval
        case loginItemFailed
        case openLoginItems
        case a11yNewWait
        case a11yNewWaitNoAsk
        case explainProcessOnlyUnconnected
        case sessionNoTitle
        case stepFailedMark
        case stepNow
        case stepTook
        case failedTurnLine
        case timelineStepsFailed
        case turnStepsOne
        case turnStepsN
        case turnStepsFailed
        case detailNoWaits
        case rowPlanSpoken
        case detailNowHeading
        case detailLastTurn
        case detailPrompt
        case detailTools
        case detailFiles
        case detailSkills
        case detailMCP
        case detailSubagents
        case detailSubagentCount
        case detailPlan
        case detailStarted
        case detailEnded
        case sourceResume
        case sourceClear
        case sourceCompact
        case sourceFork
        case endClear
        case endLogout
        case endPromptExit
        case endQuit
        case endUserClose
        case endArchived
        case endError
        case timelineEarlierSteps
        case timelineShowSteps
        case timelineHideSteps
        case copyTurnSummary
    }
}

extension L10n.Key {
    /// The copy, one line per key: English, then 简体中文. One exhaustive
    /// switch over one dimension — a key without both languages does not
    /// compile.
    fileprivate var copy: (en: String, zh: String) {
        switch self {
        case .noAgents: return ("No coding agents", "当前没有编码 Agent")
        case .noAgentsDetected: return ("No coding agents detected", "未检测到编码 Agent")
        case .needsYou: return ("Needs you", "需要你")
        case .waitingN: return ("need you", "需要你")
        case .runningN: return ("running", "运行中")
        case .recentN: return ("recent", "最近")
        case .recent: return ("Recent", "最近")
        case .settings: return ("Settings…", "设置…")
        case .quit: return ("Quit Pulse", "退出 Pulse")
        case .focusExact: return ("Go to terminal", "前往终端")
        case .focusApp: return ("Open app", "打开应用")
        case .focusOpenTray: return ("Open Pulse tray", "打开 Pulse 托盘")
        case .ignoreWait: return ("Ignore", "忽略")
        case .focusFailed: return ("Could not open it — that window may be gone. Rescanning.", "没能打开——那个窗口可能已经不在了，正在重新扫描")
        case .focusAppOnly: return ("Opened the app — can't select the exact terminal", "已打开应用——无法选中具体的终端")
        case .general: return ("General", "通用")
        case .launchAtLogin: return ("Open at login", "登录时打开")
        case .hooksHint: return ("Installs each agent's own documented hook, plugin or extension — observe-only events, never one that can gate or answer. Remove puts every file back byte for byte.", "为每个 Agent 安装它自己文档里的 hook、插件或扩展——只用观察型事件，从不用能拦截或代答的事件。移除时每个文件逐字节还原。")
        case .installHooks: return ("Install all", "全部安装")
        case .running: return ("Running", "运行中")
        case .settingsTitle: return ("Pulse Settings", "Pulse 设置")
        case .hooksUnknown: return ("Not checked", "未检查")
        case .hooksMissing: return ("Not installed", "未安装")
        case .hooksInstalledCount: return ("Installed · %d of %d agents", "已安装 · %d / %d 个 Agent")
        case .hooksFailed: return ("Failed", "失败")
        case .hooksWorking: return ("Working…", "处理中…")
        case .hooksAgentFailed: return ("%@: %@", "%@：%@")
        case .hooksFailureInvalidJSON: return ("its settings file is not valid JSON — fix it, then install again", "它的设置文件不是合法 JSON——修好后再安装")
        case .hooksFailureNotOurs: return ("a file Pulse did not write is in the way — move it, then install again", "那里有一个不是 Pulse 写的文件——移走后再安装")
        case .hooksFailureUnwritable: return ("its settings could not be written", "无法写入它的设置")
        case .hooksFailureHasComments: return ("its settings file has comments, which Pulse will not rewrite — remove them, then install again", "它的设置文件里有注释，Pulse 不会改写——删掉注释后再安装")
        case .hooksFailureShape: return ("its hooks section is not the shape its docs describe — fix it, then install again", "它的 hooks 部分和文档写的结构不一样——修好后再安装")
        case .kindPermission: return ("Asked permission", "请求权限")
        case .kindInput: return ("Asked a question", "在问你")
        case .kindWaiting: return ("Waiting for input", "等待输入")
        case .terminalDetectedNoDetails: return ("Terminal session · no events yet", "终端会话 · 尚未收到事件")
        case .appDetectedNoDetails: return ("Agent app · no events yet", "Agent 应用 · 尚未收到事件")
        case .versionMismatchHint: return ("This build is %@ but its app bundle says %@ — reinstall Pulse.", "程序版本是 %@，但应用包标记为 %@——请重新安装 Pulse。")
        case .notificationsSection: return ("Notifications", "通知")
        case .notifyNotConfigured: return ("Notifications are not enabled yet. Pulse will not ask until you choose Enable.", "通知尚未启用。点「启用通知」后 Pulse 才会请求权限。")
        case .enableNotifications: return ("Enable notifications", "启用通知")
        case .notifyDenied: return ("Notifications are turned off for Pulse — an agent that needs you cannot reach you.", "系统已关闭 Pulse 的通知权限——需要你的 Agent 没法提醒你。")
        case .openNotificationSettings: return ("Open System Settings", "打开系统设置")
        case .uninstallHooks: return ("Remove all", "全部移除")
        case .emptyHint: return ("When a connected agent starts working, its session appears here.", "已连接的 Agent 开始工作时，会话会出现在这里。")
        case .a11yIdle: return ("Idle", "空闲")
        case .moreActions: return ("More actions", "更多操作")
        case .agoFormat: return ("%@ ago", "%@前")
        case .now: return ("now", "刚刚")
        case .stalled: return ("Stalled", "停滞")
        case .notifFocus: return ("Go", "前往")
        case .buildPreview: return ("Preview build · ad-hoc signed · not notarized", "预览版 · ad-hoc 签名 · 未公证")
        case .releases: return ("Releases…", "版本发布…")
        case .notifyAllowed: return ("Allowed — macOS decides how banners look and when they show.", "已允许——横幅的样式和时机由 macOS 决定。")
        case .yourTurn: return ("Your turn", "轮到你")
        case .settingsHooksTitle: return ("Agent hooks", "Agent 的 hooks")
        case .settingsHookAbsent: return ("Not on this Mac: %@", "这台 Mac 上没有：%@")
        case .settingsReportHint: return ("A plain-text report of each connection, what each agent reports, the latest events, notifications and this build — no paths, prompts or sessions", "一份纯文本报告：每个连接、每个 Agent 报告什么、最近的事件、通知与这个版本——不含路径、提示词或会话")
        case .settingsHookInstalled: return ("Installed", "已安装")
        case .settingsHookNoEvent: return ("Nothing heard yet", "还没有听到事件")
        case .settingsHookHeard: return ("Heard %@ · %@", "最近听到 %@ · %@")
        case .settingsHookHeardUnnamed: return ("Heard an event · %@", "听到事件 · %@")
        case .settingsHookIgnored: return ("Last not used %@ — %@ · %@", "最近未采用 %@——%@ · %@")
        case .settingsHookPartial: return ("Needs update — %d of %d events", "需要更新——%d / %d 个事件")
        case .settingsHookStale: return ("Needs update — runs an old copy of Pulse", "需要更新——指向旧的 Pulse")
        case .settingsHookUpdateHint: return ("Install all brings every agent that needs an update up to date", "「全部安装」会更新所有需要更新的 Agent")
        case .ignoredNoEvent: return ("no event named", "没有指明事件")
        case .ignoredNotInstalled: return ("not an installed event", "不是已安装的事件")
        case .ignoredUnparsable: return ("its payload is not JSON", "负载不是 JSON")
        case .ignoredCannotWait: return ("it cannot report waits", "它不报告等待")
        case .ignoredNoSession: return ("no session", "没有会话")
        case .ignoredSilent: return ("nothing to show", "没有可显示的内容")
        case .ignoredNotABlock: return ("a prompt that does not block", "不阻塞的提示")
        case .ignoredNoPrompt: return ("no prompt can be shown", "没有可显示的提示")
        case .ignoredOtherSession: return ("may be about another session", "可能属于另一个会话")
        case .ignoredOtherHost: return ("another app ran Claude's hook", "另一个应用运行了 Claude 的 hook")
        case .ignoredOther: return ("unknown reason", "原因不明")
        case .settingsHookTurnedOff: return ("Installed — but hooks are turned off in %@'s settings (disableAllHooks)", "已安装——但 %@ 的设置关掉了所有 hooks（disableAllHooks）")
        case .settingsHookManagedOnly: return ("Installed — but a managed policy keeps %@ from running it", "已安装——但管理策略不让 %@ 运行它")
        case .settingsHookNeverHeard: return ("Installed — nothing heard yet", "已安装——还没有听到事件")
        case .settingsHookConfigDir: return ("Pulse installs to ~/%@, which isn't there yet — a %@ set to another folder (%@) won't load it", "Pulse 装在 ~/%@，这个文件夹还不存在——若 %@ 用了别的文件夹（%@），就不会加载它")
        case .waitingBannerFailed: return ("macOS did not show the last “needs you” banner — check Notifications", "macOS 没有显示上一条「需要你」通知——请检查通知设置")
        case .lampRuleBlocked: return ("Red: an agent is waiting on you.", "红：有 Agent 在等你。")
        case .lampRuleStalled: return ("Orange: a running session has gone quiet.", "橙：有运行中的会话停滞了。")
        case .lampRuleRunning: return ("Green: agents are working and nothing needs you.", "绿：Agent 在工作，没有需要你的事。")
        case .lampRuleTurn: return ("Gray: a turn ended — your move when you are ready.", "灰：有回合结束了，轮到你（不急）。")
        case .lampRuleRecent: return ("Gray: nothing running; recent sessions are listed.", "灰：没有在运行的；列出的是最近的会话。")
        case .lampRuleIdle: return ("Gray: no coding agent is running.", "灰：没有在运行的编码 Agent。")
        case .details: return ("Details", "详情")
        case .detailBack: return ("Back", "返回")
        case .explainWhen: return ("%@ · %@", "%@ · %@")
        case .explainAskedFront: return (" — it was in front of you, so no banner yet", "——当时它就在你眼前，所以先不发通知")
        case .explainTurn: return ("Turn ended", "回合结束")
        case .explainProcessOnly: return ("Started before Pulse — details after its next step", "在 Pulse 之前启动——下一步之后显示详情")
        case .explainStalled: return ("Nothing new for %@", "已经%@没有新动静")
        case .explainStalledUnknown: return ("Running, but its last step has no time", "在运行，但不知道它上一步的时间")
        case .explainRunningNoClock: return ("Working — no step reported yet", "在工作——还没有报告任何一步")
        case .detailFolder: return ("Folder", "目录")
        case .processOnly: return ("Process only", "仅进程")
        case .processOnlyN: return ("process only", "仅进程")
        case .waiting1: return ("needs you", "需要你")
        case .stalledN: return ("stalled", "停滞")
        case .yourTurnN: return ("your turn", "轮到你")
        case .lampRuleProcessOnly: return ("Gray: an agent is running that Pulse can see only as a process.", "灰：有 Agent 在运行，但 Pulse 只看到进程。")
        case .copyReport: return ("Copy report", "复制报告")
        case .noticeNotificationsDenied: return ("Notifications are off for Pulse — an agent that needs you cannot reach you", "Pulse 的通知被关闭了——需要你的 Agent 没法提醒你")
        case .noticeNotificationsOff: return ("Turn on notifications so an agent that needs you can reach you", "开启通知，需要你的 Agent 才能提醒到你")
        case .settingsHooksSection: return ("Hooks", "Hooks")
        case .detailLastMessage: return ("Last message", "最后的消息")
        case .detailErrorHeading: return ("Error", "错误")
        case .explainEnded: return ("Session ended", "会话已结束")
        case .explainQuiet: return ("Nothing heard for %@ and no process to watch — moved to recent", "已经%@没有消息，也看不到进程——移到最近")
        case .explainSilent: return ("Nothing heard for %@ — moved to recent", "已经%@没有消息——移到最近")
        case .setupFound: return ("Found %@ on this Mac — connect them so Pulse hears when they need you", "在这台 Mac 上找到 %@——连接后，它们需要你时 Pulse 就会知道")
        case .setupConnect: return ("Connect", "连接")
        case .setupDone: return ("Connected %@", "已连接 %@")
        case .setupGotIt: return ("Got it", "知道了")
        case .setupStepCodex: return ("Codex: run /hooks in Codex and trust Pulse", "Codex：在 Codex 里运行 /hooks 并信任 Pulse")
        case .setupStepRestart: return ("Sessions already running appear after their next step", "已在运行的会话会在它们的下一步之后出现")
        case .focusAppOnlyAutomation: return ("Opened the app — to land on the tab itself, allow Pulse in System Settings → Privacy & Security → Automation", "已打开应用——要直接落到那个标签页，请在 系统设置 → 隐私与安全性 → 自动化 中允许 Pulse")
        case .stepStalled: return ("Nothing new for %@ — last step: %@", "已经%@没有新动静——上一步：%@")
        case .timelineHeading: return ("Timeline", "时间线")
        case .timelineStarted: return ("Started", "开始")
        case .timelinePrompt: return ("Prompt", "提示")
        case .timelineWorking: return ("Working", "在工作")
        case .timelineStatus: return ("Status", "状态")
        case .timelineAgain: return ("Same ask again", "同一次提问")
        case .timelineAnswered: return ("Answered", "已回答")
        case .timelineTurnEnded: return ("Turn ended — you were watching", "回合结束——你当时在看")
        case .timelineFailed: return ("Turn failed", "回合出错")
        case .timelineHeld: return ("Turn held — lands after the grace", "回合暂缓——宽限期后落地")
        case .timelineAtPrompt: return ("At its prompt", "停在提示符")
        case .timelineResolved: return ("Closed by the agent", "Agent 关闭了提示")
        case .timelineDismissed: return ("You ignored it", "你忽略了它")
        case .timelineSeen: return ("You looked", "你看过了")
        case .timelineEnded: return ("Ended", "结束")
        case .timelineSkipped: return ("Not used — %@", "未采用——%@")
        case .timelineFailedStep: return ("%@ — failed", "%@——失败")
        case .timelineStopped: return ("Stopped by you", "你中止了")
        case .timelineNamed: return ("Named", "已命名")
        case .timelineSubagent: return ("Started or finished", "开始或结束")
        case .timelineBySubagent: return ("Subagent · %@", "子代理 · %@")
        case .stepThisTurn: return ("This turn", "本轮")
        case .setupFailedAction: return ("Open Settings", "打开设置")
        case .menuOpenPulse: return ("Open Pulse", "打开 Pulse")
        case .menuAbout: return ("About Pulse", "关于 Pulse")
        case .menuEdit: return ("Edit", "编辑")
        case .menuUndo: return ("Undo", "撤销")
        case .menuRedo: return ("Redo", "重做")
        case .menuCut: return ("Cut", "剪切")
        case .menuCopy: return ("Copy", "拷贝")
        case .menuPaste: return ("Paste", "粘贴")
        case .menuSelectAll: return ("Select All", "全选")
        case .menuWindow: return ("Window", "窗口")
        case .menuClose: return ("Close", "关闭")
        case .menuMinimize: return ("Minimize", "最小化")
        case .loginItemNeedsApproval: return ("macOS is waiting for your OK in Login Items", "macOS 在等你在「登录项」里允许")
        case .loginItemFailed: return ("macOS did not add Pulse to Login Items", "macOS 没有把 Pulse 加进登录项")
        case .openLoginItems: return ("Open Login Items", "打开登录项")
        case .a11yNewWait: return ("%@ needs you: %@", "%@ 需要你：%@")
        case .a11yNewWaitNoAsk: return ("%@ needs you", "%@ 需要你")
        case .explainProcessOnlyUnconnected: return ("Seen as a process only — Pulse isn't connected to it yet", "只看到进程——Pulse 还没有连接它")
        case .sessionNoTitle: return ("Session · no title yet", "会话 · 暂无标题")
        case .stepFailedMark: return ("failed", "失败")
        case .stepNow: return ("Now: %@", "当前：%@")
        case .stepTook: return ("%@s", "%@秒")
        case .failedTurnLine: return ("Turn failed: %@", "回合出错：%@")
        case .timelineStepsFailed: return ("%@ · %d failed", "%@ · %d 步失败")
        case .turnStepsOne: return ("1 step", "1 步")
        case .turnStepsN: return ("%d steps", "%d 步")
        case .turnStepsFailed: return ("%@ (%d failed)", "%@（%d 步失败）")
        case .detailNoWaits: return ("This agent doesn't report waits", "这个 Agent 不报告等待")
        case .rowPlanSpoken: return ("plan %@", "计划 %@")
        case .detailNowHeading: return ("Now", "正在进行")
        case .detailLastTurn: return ("Last turn", "上一轮")
        case .detailPrompt: return ("Prompt", "提示")
        case .detailTools: return ("Tools", "工具")
        case .detailFiles: return ("Files", "文件")
        case .detailSkills: return ("Skills", "技能")
        case .detailMCP: return ("MCP", "MCP")
        case .detailSubagents: return ("Subagents", "子代理")
        case .detailSubagentCount: return ("%d", "%d 个")
        case .detailPlan: return ("Plan", "计划")
        case .detailStarted: return ("Started", "开始")
        case .detailEnded: return ("Ended", "结束")
        case .sourceResume: return ("Resumed session", "恢复的会话")
        case .sourceClear: return ("After /clear", "/clear 之后")
        case .sourceCompact: return ("After compaction", "压缩之后")
        case .sourceFork: return ("Forked session", "分叉的会话")
        case .endClear: return ("/clear", "/clear")
        case .endLogout: return ("Logged out", "退出登录")
        case .endPromptExit: return ("Exited at its prompt", "在提示符退出")
        case .endQuit: return ("Quit", "退出")
        case .endUserClose: return ("Closed by you", "你关闭了它")
        case .endArchived: return ("Archived", "已归档")
        case .endError: return ("Ended on an error", "因出错结束")
        case .timelineEarlierSteps: return ("%d earlier", "更早的 %d 步")
        case .timelineShowSteps: return ("Show each step", "展开每一步")
        case .timelineHideSteps: return ("Hide the steps", "收起每一步")
        case .copyTurnSummary: return ("Copy this turn's summary", "复制本轮摘要")
        }
    }
}
