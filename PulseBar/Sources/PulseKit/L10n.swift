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

    /// A blocked kind in a word, as the banner body and the row's second
    /// line say it when the agent gave no words.
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
        case terminalSession
        case appSession
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
        case a11yRunning
        case a11yStalled
        case a11yWaiting
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
        case settingsHookLastEvent
        case settingsHookLastEventNow
        case settingsHookNoEvent
        case settingsHookNoWait
        case waitingBannerFailed
        case lampRuleBlocked
        case lampRuleStalled
        case lampRuleRunning
        case lampRuleTurn
        case lampRuleRecent
        case lampRuleIdle
        case details
        case detailBack
        case explainAsked
        case explainAskedFront
        case explainTurn
        case explainProcessOnly
        case explainStalled
        case explainStalledUnknown
        case explainRunning
        case explainRunningNoClock
        case explainKindPermission
        case explainKindInput
        case explainKindWaiting
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
        case explainIdle
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
        case stepHeading
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
        case .kindPermission: return ("Permission", "需要授权")
        case .kindInput: return ("Input", "等待输入")
        case .kindWaiting: return ("Waiting", "等待中")
        case .terminalSession: return ("Terminal session running", "终端会话正在运行")
        case .appSession: return ("Agent app running", "Agent 应用正在运行")
        case .terminalDetectedNoDetails: return ("Terminal session running · activity feed unavailable", "终端会话正在运行 · 暂无活动数据")
        case .appDetectedNoDetails: return ("Agent app running · session feed unavailable", "Agent 应用正在运行 · 暂无会话数据")
        case .versionMismatchHint: return ("This build is %@ but its app bundle says %@ — reinstall Pulse.", "程序版本是 %@，但应用包标记为 %@——请重新安装 Pulse。")
        case .notificationsSection: return ("Notifications", "通知")
        case .notifyNotConfigured: return ("Notifications are not enabled yet. Pulse will not ask until you choose Enable.", "通知尚未启用。点「启用通知」后 Pulse 才会请求权限。")
        case .enableNotifications: return ("Enable notifications", "启用通知")
        case .notifyDenied: return ("Notifications are turned off for Pulse — an agent that needs you cannot reach you.", "系统已关闭 Pulse 的通知权限——需要你的 Agent 没法提醒你。")
        case .openNotificationSettings: return ("Open System Settings", "打开系统设置")
        case .uninstallHooks: return ("Remove all", "全部移除")
        case .emptyHint: return ("When a connected agent starts working, its session appears here.", "已连接的 Agent 开始工作时，会话会出现在这里。")
        case .a11yIdle: return ("Idle", "空闲")
        case .a11yRunning: return ("Running", "运行中")
        case .a11yStalled: return ("Stalled", "停滞")
        case .a11yWaiting: return ("Needs you", "需要你")
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
        case .settingsReportHint: return ("A plain-text report of each hook, notifications and this build — no paths, prompts or sessions", "一份纯文本报告：每个 hook、通知与这个版本——不含路径、提示词或会话")
        case .settingsHookInstalled: return ("Installed", "已安装")
        case .settingsHookLastEvent: return ("last event %@ ago", "最近事件 %@前")
        case .settingsHookLastEventNow: return ("last event just now", "最近事件：刚刚")
        case .settingsHookNoEvent: return ("no event yet", "还没有事件")
        case .settingsHookNoWait: return ("Doesn't report when it waits — running and your turn only", "不会报告它在等你——只显示运行中和轮到你")
        case .waitingBannerFailed: return ("macOS did not show the last “needs you” banner — check Notifications", "macOS 没有显示上一条「需要你」通知——请检查通知设置")
        case .lampRuleBlocked: return ("Red: an agent is waiting on you.", "红：有 Agent 在等你。")
        case .lampRuleStalled: return ("Orange: a running session has gone quiet.", "橙：有运行中的会话停滞了。")
        case .lampRuleRunning: return ("Green: agents are working and nothing needs you.", "绿：Agent 在工作，没有需要你的事。")
        case .lampRuleTurn: return ("Gray: a turn ended — your move when you are ready.", "灰：有回合结束了，轮到你（不急）。")
        case .lampRuleRecent: return ("Gray: nothing running; recent sessions are listed.", "灰：没有在运行的；列出的是最近的会话。")
        case .lampRuleIdle: return ("Gray: no coding agent is running.", "灰：没有在运行的编码 Agent。")
        case .details: return ("Details", "详情")
        case .detailBack: return ("Back", "返回")
        case .explainAsked: return ("%@ %@ · %@", "%@ %@ · %@")
        case .explainAskedFront: return (" — it was in front of you, so no banner yet", "——当时它就在你眼前，所以先不发通知")
        case .explainTurn: return ("%@ finished its turn · %@", "%@ 的回合结束了 · %@")
        case .explainProcessOnly: return ("Started before Pulse — details after its next step", "在 Pulse 之前启动——下一步之后显示详情")
        case .explainStalled: return ("Nothing new for %@", "已经 %@ 没有新动静")
        case .explainStalledUnknown: return ("Running, but its last step has no time", "在运行，但不知道它上一步的时间")
        case .explainRunning: return ("%@ is working · last step %@", "%@ 在工作 · 上一步：%@")
        case .explainRunningNoClock: return ("Working — no step reported yet", "在工作——还没有报告任何一步")
        case .explainKindPermission: return ("asked for permission", "请求权限")
        case .explainKindInput: return ("asked a question", "提了一个问题")
        case .explainKindWaiting: return ("is waiting for you", "在等你")
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
        case .explainIdle: return ("At its prompt · last step %@", "停在提示符 · 上一步：%@")
        case .explainEnded: return ("The session ended %@", "会话已结束 · %@")
        case .explainQuiet: return ("Nothing heard for %@ and no process to watch — moved to recent", "已经 %@ 没有消息，也看不到进程——移到最近")
        case .explainSilent: return ("Nothing heard for %@ — moved to recent", "已经 %@ 没有消息——移到最近")
        case .setupFound: return ("Found %@ on this Mac — connect them so Pulse hears when they need you", "在这台 Mac 上找到 %@——连接后，它们需要你时 Pulse 就会知道")
        case .setupConnect: return ("Connect", "连接")
        case .setupDone: return ("Connected %@", "已连接 %@")
        case .setupGotIt: return ("Got it", "知道了")
        case .setupStepCodex: return ("Codex: run /hooks in Codex and trust Pulse", "Codex：在 Codex 里运行 /hooks 并信任 Pulse")
        case .setupStepRestart: return ("Sessions already running appear after their next step", "已在运行的会话会在它们的下一步之后出现")
        case .focusAppOnlyAutomation: return ("Opened the app — to land on the tab itself, allow Pulse in System Settings → Privacy & Security → Automation", "已打开应用——要直接落到那个标签页，请在 系统设置 → 隐私与安全性 → 自动化 中允许 Pulse")
        case .stepStalled: return ("Nothing new for %@ — last step: %@", "已经 %@ 没有新动静——上一步：%@")
        case .stepHeading: return ("Recent steps", "最近几步")
        case .stepThisTurn: return ("This turn", "本回合")
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
        }
    }
}
