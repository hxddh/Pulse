import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case auto, en, zh
    var id: String { rawValue }

    /// The picker's label, in the interface's language for "System"; each
    /// language names itself.
    func menuLabel(_ lang: ResolvedLanguage) -> String {
        switch self {
        case .auto: return L10n.t(.languageSystem, lang)
        case .en: return "English"
        case .zh: return "中文"
        }
    }

    var resolved: ResolvedLanguage {
        switch self {
        case .en: return .en
        case .zh: return .zh
        case .auto:
            let code = Locale.preferredLanguages.first ?? "en"
            return code.hasPrefix("zh") ? .zh : .en
        }
    }
}

enum ResolvedLanguage {
    case en, zh
}

enum L10n {
    /// Split per language on purpose: one `switch (key, lang)` over ~100 keys
    /// made the compiler give up — "unable to check that this switch is
    /// exhaustive in reasonable time". Two single-dimension switches stay both
    /// fast to type-check and exhaustive-checked, so a missing key is still a
    /// compile error.
    static func t(_ key: Key, _ lang: ResolvedLanguage) -> String {
        switch lang {
        case .en: return en(key)
        case .zh: return zh(key)
        }
    }

    /// Vendor wait kinds arrive as protocol tokens (`Permission` / `Input` /
    /// `Waiting`), which are English words by coincidence, not by translation.
    /// They reach the user in the banner body and the row's second line, so
    /// they belong here rather than in whichever surface happened to need
    /// them first.
    ///
    /// An unknown kind is passed through: inventing a translation for a token
    /// this build has never seen would be worse than showing what the agent
    /// actually said.
    static func waitKind(_ kind: String, _ lang: ResolvedLanguage) -> String {
        switch kind {
        case "Permission": return t(.kindPermission, lang)
        case "Input": return t(.kindInput, lang)
        case "Waiting": return t(.kindWaiting, lang)
        case "": return t(.needsYou, lang)
        default: return kind
        }
    }

    /// Joins a list of agent display names the way the language does it.
    static func joinNames(_ names: [String], _ lang: ResolvedLanguage) -> String {
        names.joined(separator: lang == .zh ? "、" : ", ")
    }

    /// English copy.
    private static func en(_ key: Key) -> String {
        switch key {
        case .noAgents: return "No coding agents"
        case .noAgentsDetected: return "No coding agents detected"
        case .needsYou: return "Needs you"
        case .waitingN: return "need you"
        case .runningN: return "running"
        case .recent1: return "1 recent"
        case .recentN: return "recent"
        case .andMore: return "and %d more…"
        case .showLess: return "Show less"
        case .settings: return "Settings…"
        case .quit: return "Quit Pulse"
        case .general: return "General"
        case .notifyWaiting: return "Notify when an agent needs me"
        case .focusExact: return "Go to terminal"
        case .focusApp: return "Open app"
        case .focusOpenTray: return "Open Pulse tray"
        case .focusAppOnly: return "Opened the app — can't select the exact terminal"
        case .launchAtLogin: return "Launch at login"
        case .language: return "Language"
        case .hooksHint: return "Installs each agent's own documented hook, plugin or extension — observe-only events, never one that can gate or answer. Remove puts every file back byte for byte."
        case .installHooks: return "Install hooks"
        case .shortcuts: return "Shortcuts"
        case .running: return "Running"
        case .settingsTitle: return "Pulse Settings"
        case .recent: return "Recent"
        case .dismissWait: return "Dismiss"
        case .focusFailed: return "Could not open it — that window may be gone. Rescanning."
        case .hooksUnknown: return "Not checked"
        case .hooksMissing: return "Not installed"
        case .hooksInstalledCount: return "Installed · %d of %d agents"
        case .hooksFailed: return "Failed"
        case .hooksWorking: return "Working…"
        case .hooksAgentFailed: return "%@: %@"
        case .hooksFailureInvalidJSON: return "its settings file is not valid JSON — fix it, then install again"
        case .hooksFailureNotOurs: return "a file Pulse did not write is in the way — move it, then install again"
        case .hooksFailureUnwritable: return "its settings could not be written"
        case .hooksFailureHasComments: return "its settings file has comments, which Pulse will not rewrite — remove them, then install again"
        case .hooksFailureShape: return "its hooks section is not the shape its docs describe — fix it, then install again"
        case .kindPermission: return "Permission"
        case .kindInput: return "Input"
        case .kindWaiting: return "Waiting"
        case .terminalSession: return "Terminal session running"
        case .appSession: return "Agent app running"
        case .terminalDetectedNoDetails: return "Terminal session running · activity feed unavailable"
        case .appDetectedNoDetails: return "Agent app running · session feed unavailable"
        case .versionMismatchHint: return "This build is %@ but its app bundle says %@ — reinstall Pulse."
        case .durNow: return "now"
        case .durSec: return "%ds"
        case .durMin: return "%dm"
        case .durHour: return "%dh"
        case .notificationsSection: return "Notifications"
        case .notifyNotConfigured: return "Notifications are not enabled yet. Pulse will not ask until you choose Enable."
        case .enableNotifications: return "Enable notifications"
        case .notifyDenied: return "Notifications are turned off for Pulse — these switches cannot fire."
        case .openNotificationSettings: return "Open System Settings"
        case .uninstallHooks: return "Remove hooks"
        case .revealShortcut: return "Open or close Pulse"
        case .hotkeyTaken: return "Another app already owns this shortcut — pick a different one."
        case .emptyHint: return "When a connected agent starts working, its session appears here."
        case .checkForUpdates: return "Check for updates"
        case .checkNow: return "Check now"
        case .openRelease: return "Open release"
        case .updateIdle: return "Not checked"
        case .updateChecking: return "Checking…"
        case .updateCurrent: return "Up to date"
        case .updateCurrentPrerelease: return "Up to date on the preview channel (ad-hoc signed, not notarized)"
        case .updateCurrentStable: return "Up to date on the stable channel"
        case .updateAvailable: return "Update available: %@"
        case .updateFailed: return "Check failed"
        case .a11yIdle: return "Idle"
        case .a11yRunning: return "Running"
        case .a11yStalled: return "Stalled"
        case .a11yWaiting: return "Needs you"
        case .moreActions: return "More actions"
        case .agoFormat: return "%@ ago"
        case .stalled: return "Stalled"
        case .notifFocus: return "Go"
        case .waitingSummaryTitle: return "%d agents need you"
        case .updatePreview: return "Preview build · ad-hoc signed · not notarized"
        case .updateSignedUnnotarized: return "Developer ID signed · not notarized · Gatekeeper may block"
        case .yourTurn: return "Your turn"
        case .shortcutOff: return "Off"
        case .settingsHooksTitle: return "Agent hooks"
        case .updateFailedBadFeed: return "Update feed address is invalid"
        case .updateFailedNetwork: return "Could not reach GitHub"
        case .updateFailedHTTP: return "GitHub answered %d"
        case .updateFailedBadResponse: return "GitHub's answer was not a release"
        case .updateFailedNoTag: return "The latest release has no version tag"
        case .staleHidden: return "%d older session(s) not shown (%@)"
        case .waitingBannerFailed: return "macOS did not show the last “needs you” banner — check Notifications"
        case .lampRuleBlocked: return "Red: an agent is waiting on you."
        case .lampRuleStalled: return "Orange: a running session has gone quiet."
        case .lampRuleRunning: return "Green: agents are working and nothing needs you."
        case .lampRuleTurn: return "Grey: a turn ended — your move when you are ready."
        case .lampRuleRecent: return "Grey: nothing running; recent sessions are listed."
        case .lampRuleIdle: return "Grey: no coding agent is running."
        case .details: return "Details"
        case .detailBack: return "Back"
        case .trayKeyHints: return "↑↓ select   ↩ go   → details   ⌘D dismiss   ⌘M mute   esc close"
        case .explainAsked: return "%@ %@ · %@"
        case .explainAskedFront: return " — it was in front of you, so no banner yet"
        case .explainTurn: return "%@ finished its turn · %@"
        case .explainProcessOnly: return "Started before Pulse — details after its next step"
        case .explainStalled: return "Nothing new for %@"
        case .explainStalledUnknown: return "Running, but its last step has no time"
        case .explainRunning: return "%@ is working · last step %@"
        case .explainRunningNoClock: return "Working — no step reported yet"
        case .explainKindPermission: return "asked for permission"
        case .explainKindInput: return "asked a question"
        case .explainKindWaiting: return "is waiting for you"
        case .detailFolder: return "Folder"
        case .detailStarted: return "Started"
        case .processOnly: return "Process only"
        case .processOnlyN: return "process only"
        case .waiting1: return "needs you"
        case .stalledN: return "stalled"
        case .yourTurnN: return "your turn"
        case .lampRuleProcessOnly: return "Grey: an agent is running that Pulse can see only as a process."
        case .mute: return "Mute"
        case .unmute: return "Unmute"
        case .mutedWord: return "muted"
        case .copyReport: return "Copy report"
        case .noticeNotificationsDenied: return "Notifications are off for Pulse — an agent that needs you cannot reach you"
        case .noticeNotificationsOff: return "Turn on notifications so an agent that needs you can reach you"
        case .settingsHookInstalled: return "Installed"
        case .settingsHookAbsent: return "Not on this Mac: %@"
        case .settingsReportHint: return "A plain-text report of each hook, notifications and this build — no paths, prompts or sessions"
        case .settingsHookLastEvent: return "last event %@ ago"
        case .settingsHookLastEventNow: return "last event just now"
        case .settingsHookNoEvent: return "no event yet"
        case .settingsHookNoWait: return "Doesn't report when it waits — running and your turn only"
        case .settingsHooksSection: return "Hooks"
        case .settingsUpdatesSection: return "Updates"
        case .detailLastMessage: return "Last message"
        case .detailErrorHeading: return "Error"
        case .explainIdle: return "At its prompt · last step %@"
        case .explainEnded: return "The session ended %@"
        case .explainQuiet: return "Nothing heard for %@ and no process to watch — moved to recent"
        case .explainSilent: return "Nothing heard for %@ — moved to recent"
        case .setupFound: return "Found %@ on this Mac — connect them so Pulse hears when they need you"
        case .setupConnect: return "Connect"
        case .setupDone: return "Connected %@"
        case .setupGotIt: return "Got it"
        case .setupStepCodex: return "Codex: run /hooks in Codex and trust Pulse"
        case .setupStepRestart: return "Sessions already running appear after their next step"
        case .automationOffer: return "Jump to the exact tab next time — macOS will ask you once"
        case .automationAllow: return "Allow"
        case .automationNotNow: return "Not now"
        case .automationAllowed: return "Allowed — the next Go lands on the exact tab"
        case .durSecSpoken: return "%ds"
        case .durMinSpoken: return "%dm"
        case .durHourSpoken: return "%dh"
        case .durUnderMinute: return "<1m"
        case .stepStalled: return "Nothing new for %@ — last step: %@"
        case .stepHeading: return "Recent steps"
        case .stepThisTurn: return "This turn"
        case .setupFailedAction: return "Open Settings"
        case .languageSystem: return "System"
        }
    }

    /// 简体中文文案。
    private static func zh(_ key: Key) -> String {
        switch key {
        case .noAgents: return "当前没有编码 Agent"
        case .noAgentsDetected: return "未检测到编码 Agent"
        case .needsYou: return "需要你"
        case .waitingN: return "需要你"
        case .runningN: return "运行中"
        case .recent1: return "1 个最近会话"
        case .recentN: return "最近"
        case .andMore: return "另有 %d 个…"
        case .showLess: return "收起"
        case .settings: return "设置…"
        case .quit: return "退出 Pulse"
        case .general: return "通用"
        case .notifyWaiting: return "Agent 需要我时通知"
        case .focusExact: return "前往终端"
        case .focusApp: return "打开应用"
        case .focusOpenTray: return "打开 Pulse 托盘"
        case .focusAppOnly: return "已打开应用——无法选中具体的终端"
        case .launchAtLogin: return "登录时启动"
        case .language: return "语言"
        case .hooksHint: return "为每个 Agent 安装它自己文档里的 hook、插件或扩展——只用观察型事件，从不用能拦截或代答的事件。移除时每个文件逐字节还原。"
        case .installHooks: return "安装 hooks"
        case .shortcuts: return "快捷键"
        case .running: return "运行中"
        case .settingsTitle: return "Pulse 设置"
        case .recent: return "最近"
        case .dismissWait: return "忽略"
        case .focusFailed: return "没能打开——那个窗口可能已经不在了，正在重新扫描"
        case .hooksUnknown: return "未检查"
        case .hooksMissing: return "未安装"
        case .hooksInstalledCount: return "已安装 · %d / %d 个 Agent"
        case .hooksFailed: return "失败"
        case .hooksWorking: return "处理中…"
        case .hooksAgentFailed: return "%@：%@"
        case .hooksFailureInvalidJSON: return "它的设置文件不是合法 JSON——修好后再安装"
        case .hooksFailureNotOurs: return "那里有一个不是 Pulse 写的文件——移走后再安装"
        case .hooksFailureUnwritable: return "无法写入它的设置"
        case .hooksFailureHasComments: return "它的设置文件里有注释，Pulse 不会改写——删掉注释后再安装"
        case .hooksFailureShape: return "它的 hooks 部分和文档写的结构不一样——修好后再安装"
        case .kindPermission: return "需要授权"
        case .kindInput: return "等待输入"
        case .kindWaiting: return "等待中"
        case .terminalSession: return "终端会话正在运行"
        case .appSession: return "Agent 应用正在运行"
        case .terminalDetectedNoDetails: return "终端会话正在运行 · 暂无活动数据"
        case .appDetectedNoDetails: return "Agent 应用正在运行 · 暂无会话数据"
        case .versionMismatchHint: return "程序版本是 %@，但应用包标记为 %@——请重新安装 Pulse。"
        case .durNow: return "刚刚"
        case .durSec: return "%d 秒"
        case .durMin: return "%d 分"
        case .durHour: return "%d 小时"
        case .notificationsSection: return "通知"
        case .notifyNotConfigured: return "通知尚未启用。点「启用通知」后 Pulse 才会请求权限。"
        case .enableNotifications: return "启用通知"
        case .notifyDenied: return "系统已关闭 Pulse 的通知权限，下面的开关不会生效。"
        case .openNotificationSettings: return "打开系统设置"
        case .uninstallHooks: return "移除 hooks"
        case .revealShortcut: return "打开或关闭 Pulse"
        case .hotkeyTaken: return "该快捷键已被其他应用占用，请换一个。"
        case .emptyHint: return "已连接的 Agent 开始工作时，会话会出现在这里。"
        case .checkForUpdates: return "检查更新"
        case .checkNow: return "立即检查"
        case .openRelease: return "打开发布页"
        case .updateIdle: return "未检查"
        case .updateChecking: return "检查中…"
        case .updateCurrent: return "已是最新"
        case .updateCurrentPrerelease: return "已是最新（预览通道 · ad-hoc 签名 · 未公证）"
        case .updateCurrentStable: return "已是最新（正式通道）"
        case .updateAvailable: return "有新版本：%@"
        case .updateFailed: return "检查失败"
        case .a11yIdle: return "空闲"
        case .a11yRunning: return "运行中"
        case .a11yStalled: return "停滞"
        case .a11yWaiting: return "需要你"
        case .moreActions: return "更多操作"
        case .agoFormat: return "%@前"
        case .stalled: return "停滞"
        case .notifFocus: return "前往"
        case .waitingSummaryTitle: return "%d 个 Agent 需要你"
        case .updatePreview: return "预览版 · ad-hoc 签名 · 未公证"
        case .updateSignedUnnotarized: return "已用 Developer ID 签名 · 未公证 · Gatekeeper 可能拦截"
        case .yourTurn: return "轮到你"
        case .shortcutOff: return "关闭"
        case .settingsHooksTitle: return "Agent 的 hooks"
        case .updateFailedBadFeed: return "更新源地址无效"
        case .updateFailedNetwork: return "无法连接 GitHub"
        case .updateFailedHTTP: return "GitHub 返回 %d"
        case .updateFailedBadResponse: return "GitHub 返回的不是发布信息"
        case .updateFailedNoTag: return "最新发布没有版本标签"
        case .staleHidden: return "%d 个较早的会话未显示（%@）"
        case .waitingBannerFailed: return "macOS 没有显示上一条「需要你」通知——请检查通知设置"
        case .lampRuleBlocked: return "红：有 Agent 在等你。"
        case .lampRuleStalled: return "橙：有运行中的会话停滞了。"
        case .lampRuleRunning: return "绿：Agent 在工作，没有需要你的事。"
        case .lampRuleTurn: return "灰：有回合结束了，轮到你（不急）。"
        case .lampRuleRecent: return "灰：没有在运行的；列出的是最近的会话。"
        case .lampRuleIdle: return "灰：没有在运行的编码 Agent。"
        case .details: return "详情"
        case .detailBack: return "返回"
        case .trayKeyHints: return "↑↓ 选择   ↩ 前往   → 详情   ⌘D 忽略   ⌘M 静音   esc 关闭"
        case .explainAsked: return "%@ %@ · %@"
        case .explainAskedFront: return "——当时它就在你眼前，所以先不发通知"
        case .explainTurn: return "%@ 的回合结束了 · %@"
        case .explainProcessOnly: return "在 Pulse 之前启动——下一步之后显示详情"
        case .explainStalled: return "已经 %@ 没有新动静"
        case .explainStalledUnknown: return "在运行，但不知道它上一步的时间"
        case .explainRunning: return "%@ 在工作 · 上一步 %@"
        case .explainRunningNoClock: return "在工作——还没有报告任何一步"
        case .explainKindPermission: return "请求权限"
        case .explainKindInput: return "提了一个问题"
        case .explainKindWaiting: return "在等你"
        case .detailFolder: return "目录"
        case .detailStarted: return "开始于"
        case .processOnly: return "仅进程"
        case .processOnlyN: return "仅进程"
        case .waiting1: return "需要你"
        case .stalledN: return "停滞"
        case .yourTurnN: return "轮到你"
        case .lampRuleProcessOnly: return "灰：有 Agent 在运行，但 Pulse 只看到进程。"
        case .mute: return "静音"
        case .unmute: return "取消静音"
        case .mutedWord: return "已静音"
        case .copyReport: return "复制报告"
        case .noticeNotificationsDenied: return "Pulse 的通知被关闭了——需要你的 Agent 没法提醒你"
        case .noticeNotificationsOff: return "开启通知，需要你的 Agent 才能提醒到你"
        case .settingsHookInstalled: return "已安装"
        case .settingsHookAbsent: return "这台 Mac 上没有：%@"
        case .settingsReportHint: return "一份纯文本报告：每个 hook、通知与这个版本——不含路径、提示词或会话"
        case .settingsHookLastEvent: return "最近事件 %@前"
        case .settingsHookLastEventNow: return "最近事件：刚刚"
        case .settingsHookNoEvent: return "还没有事件"
        case .settingsHookNoWait: return "不会报告它在等你——只显示运行中和轮到你"
        case .settingsHooksSection: return "Hooks"
        case .settingsUpdatesSection: return "更新"
        case .detailLastMessage: return "最后的消息"
        case .detailErrorHeading: return "错误"
        case .explainIdle: return "停在提示符 · 上一步 %@"
        case .explainEnded: return "会话已结束 · %@"
        case .explainQuiet: return "已经 %@ 没有消息，也看不到进程——移到最近"
        case .explainSilent: return "已经 %@ 没有消息——移到最近"
        case .setupFound: return "在这台 Mac 上找到 %@——连接后，它们需要你时 Pulse 就会知道"
        case .setupConnect: return "连接"
        case .setupDone: return "已连接 %@"
        case .setupGotIt: return "知道了"
        case .setupStepCodex: return "Codex：在 Codex 里运行 /hooks 并信任 Pulse"
        case .setupStepRestart: return "已在运行的会话会在它们的下一步之后出现"
        case .automationOffer: return "下次直接跳到那个标签页——macOS 会询问你一次"
        case .automationAllow: return "允许"
        case .automationNotNow: return "暂不"
        case .automationAllowed: return "已允许——下次前往会直接到那个标签页"
        case .durSecSpoken: return "%d 秒"
        case .durMinSpoken: return "%d 分钟"
        case .durHourSpoken: return "%d 小时"
        case .durUnderMinute: return "<1 分"
        case .stepStalled: return "已经 %@ 没有新动静——上一步：%@"
        case .stepHeading: return "最近几步"
        case .stepThisTurn: return "本回合"
        case .setupFailedAction: return "打开设置"
        case .languageSystem: return "跟随系统"
        }
    }

    /// `CaseIterable` so tests can assert every key resolves in both languages
    /// and that format specifiers match (a mismatched %d crashes String(format:)).
    enum Key: CaseIterable {
        case noAgents, noAgentsDetected, needsYou, waitingN, runningN
        case recent1, recentN, recent
        case andMore, showLess
        case settings, quit
        case focusExact, focusApp, focusOpenTray, dismissWait
        case focusFailed, focusAppOnly
        case general, notifyWaiting, launchAtLogin, language
        case hooksHint, installHooks
        case shortcuts
        case running, settingsTitle
        case hooksUnknown, hooksMissing, hooksInstalledCount
        case hooksFailed
        case hooksWorking, hooksAgentFailed, hooksFailureInvalidJSON, hooksFailureNotOurs, hooksFailureUnwritable
        case hooksFailureHasComments, hooksFailureShape
        case kindPermission, kindInput, kindWaiting
        case terminalSession, appSession
        case terminalDetectedNoDetails, appDetectedNoDetails
        case versionMismatchHint
        case durNow, durSec, durMin, durHour
        case notificationsSection, notifyNotConfigured
        case enableNotifications, notifyDenied, openNotificationSettings
        case uninstallHooks
        case revealShortcut, hotkeyTaken
        case emptyHint
        case checkForUpdates, checkNow, openRelease
        case updateIdle, updateChecking, updateCurrent, updateCurrentPrerelease, updateCurrentStable
        case updateAvailable, updateFailed
        case a11yIdle, a11yRunning, a11yStalled, a11yWaiting
        case moreActions
        case agoFormat
        case stalled
        case notifFocus
        case waitingSummaryTitle
        case updatePreview, updateSignedUnnotarized
        case yourTurn
        case shortcutOff
        case settingsHooksTitle
        case settingsHookAbsent, settingsReportHint
        case settingsHookInstalled, settingsHookLastEvent, settingsHookLastEventNow, settingsHookNoEvent, settingsHookNoWait
        case updateFailedBadFeed
        case updateFailedNetwork
        case updateFailedHTTP
        case updateFailedBadResponse
        case updateFailedNoTag
        case staleHidden
        case waitingBannerFailed
        case lampRuleBlocked
        case lampRuleStalled
        case lampRuleRunning
        case lampRuleTurn
        case lampRuleRecent
        case lampRuleIdle
        case details
        case detailBack
        case trayKeyHints
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
        case detailStarted
        case processOnly
        case processOnlyN
        case waiting1
        case stalledN
        case yourTurnN
        case lampRuleProcessOnly
        case mute
        case unmute
        case mutedWord
        case copyReport
        case noticeNotificationsDenied
        case noticeNotificationsOff
        case settingsHooksSection
        case settingsUpdatesSection
        case detailLastMessage
        case detailErrorHeading
        case explainIdle, explainEnded, explainQuiet, explainSilent
        case setupFound, setupConnect, setupDone, setupGotIt, setupStepCodex, setupStepRestart
        case automationOffer, automationAllow, automationNotNow, automationAllowed
        case durSecSpoken, durMinSpoken, durHourSpoken
        case durUnderMinute
        case stepStalled, stepHeading, stepThisTurn
        case setupFailedAction
        case languageSystem
    }
}

/// Shared duration wording — pure, so the projection (`TrayState`) can put
/// the elapsed wait in the menu bar.
enum DurationFormat {
    /// `spoken`: the words a sentence uses ("4 分钟", not the menu bar's
    /// compact "4 分") — the same in English.
    static func label(seconds ago: Double, lang: ResolvedLanguage, spoken: Bool = false) -> String {
        if ago < 5 { return L10n.t(.durNow, lang) }
        if ago < 60 { return String(format: L10n.t(spoken ? .durSecSpoken : .durSec, lang), Int(ago)) }
        if ago < 3600 { return String(format: L10n.t(spoken ? .durMinSpoken : .durMin, lang), Int(ago / 60)) }
        return String(format: L10n.t(spoken ? .durHourSpoken : .durHour, lang), Int(ago / 3600))
    }
}
