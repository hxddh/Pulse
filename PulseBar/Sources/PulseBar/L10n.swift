import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case auto, en, zh
    var id: String { rawValue }

    var menuLabel: String {
        switch self {
        case .auto: return "System"
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
    /// They reach the user in the glance tooltip, the banner body and the row
    /// chip, so they belong here rather than in whichever surface happened to
    /// need them first — `SnapshotBuilder` is pure and has no store, and it was
    /// printing the raw token into a Chinese tooltip.
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
        case .justNow: return "just now"
        case .notYet: return "not yet"
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
        case .allowTerminalAutomation: return "Allow Terminal / iTerm tab focus"
        case .allowTerminalAutomationHint:
            return "Off by default. When on, Go may ask macOS for Automation access to select the exact iTerm session or Terminal tab. tmux, other terminals and editors never need this."
        case .supportFocusNone: return "Focus: observation only"
        case .supportFocusExact: return "Focus: the exact terminal"
        case .supportFocusApp: return "Focus: the app only"
        case .signalHooks: return "hook report"
        case .launchAtLogin: return "Launch at login"
        case .language: return "Language"
        case .hooksHint: return "Installs each agent's own documented hook, plugin or extension — observe-only events, never one that can gate or answer. Remove puts every file back byte for byte."
        case .installHooks: return "Install hooks"
        case .testWaitingSignal: return "Test connection"
        case .hookTestIdle: return "Not tested"
        case .hookTestRunning: return "Testing…"
        case .hookTestPassed: return "Connection passed"
        case .hookTestFailed: return "Connection failed"
        case .shortcuts: return "Shortcuts"
        case .running: return "Running"
        case .settingsTitle: return "Pulse Settings"
        case .recent: return "Recent"
        case .dismissWait: return "Dismiss"
        case .focusFailed: return "Could not open it — that window may be gone. Rescanning."
        case .hooksNudge: return "Install hooks to see exact requests and \"your turn\" for the agents you run"
        case .hooksUnknown: return "Not checked"
        case .hooksMissing: return "Not installed"
        case .hooksInstalledCount: return "Installed · %d of %d agents"
        case .hooksFailed: return "Failed"
        case .kindPermission: return "Permission"
        case .kindInput: return "Input"
        case .kindWaiting: return "Waiting"
        case .terminalSession: return "Terminal session running"
        case .appSession: return "Agent app running"
        case .terminalDetectedNoDetails: return "Terminal session running · activity feed unavailable"
        case .appDetectedNoDetails: return "Agent app running · session feed unavailable"
        case .setupWaitingSignals: return "Connect “needs you”…"
        case .copied: return "Copied"
        case .versionMismatchHint:
            return "Binary reports %@ but the bundle says %@ — repackage with PulseBar/Scripts/package.sh."
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
        case .emptyHint:
            return "Pulse shows agents running now and sessions active in the last 45 minutes, read from this Mac."
        case .checkForUpdates: return "Check for updates"
        case .checkNow: return "Check now"
        case .openRelease: return "Open release"
        case .updateIdle: return "Not checked"
        case .updateChecking: return "Checking…"
        case .updateCurrent: return "Up to date"
        case .updateCurrentPrerelease:
            return "Up to date on the preview channel (unsigned)"
        case .updateCurrentStable:
            return "Up to date on stable (excludes prereleases; notarization may lag)"
        case .updateAvailable: return "Update available: %@"
        case .updateFailed: return "Check failed"
        case .probeEvery: return "processes checked every %ds"
        case .probeParked: return "paused (display off)"
        case .a11yIdle: return "Idle"
        case .a11yRunning: return "Running"
        case .a11yStalled: return "Stalled"
        case .a11yWaiting: return "Needs you"
        case .sectionNeedsYou: return "Needs you"
        case .sectionRunning: return "Running"
        case .sectionStalled: return "Stalled"
        case .sectionRecent: return "Recent"
        case .moreActions: return "More actions"
        case .agoFormat: return "%@ ago"
        case .stalled: return "Stalled"
        case .supportWaitingHooks: return "Waiting route: hooks"
        case .supportWaitingNoneDetail:
            return "No native Waiting path — use the Attention bridge"
        case .supportSharedCursor: return "The Cursor IDE and the cursor-agent CLI are one agent"
        case .supportNeedsAction: return "Needs action"
        case .supportAvailable: return "Available"
        case .supportNotInstalled: return "Not installed"
        case .supportNoRecentSession: return "No recent session"
        case .notifFocus: return "Go"
        case .waitingSummaryTitle: return "%d agents need your attention"
        case .searchNoResults: return "No sessions match “%@”"
        case .updatePreview: return "Preview build · ad-hoc signed · not notarized"
        case .updateSignedUnnotarized: return "Developer ID signed · not notarized · Gatekeeper may block"
        case .doctorRun: return "Run self-check"
        case .doctorHint: return "Reads each agent's hook file and the hook log on this Mac, runs claude agents --json once, and says which contracts are proven here. Writes nothing; the copied report has no paths, prompts or session ids."
        case .yourTurn: return "Your turn"
        case .shortcutOff: return "Off"
        case .settingsHooksTitle: return "Agent hooks"
        case .settingsHooksTest: return "Test the connection"
        case .healthAgentsHeading: return "Agents"
        case .healthRunCheck: return "Run"
        case .healthRunAgain: return "Run again"
        case .lastReadJustNow: return "Read just now"
        case .lastReadAgo: return "Read %@ ago"
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
        case .auditRaised: return "Raised %@"
        case .auditPosted: return "Banner shown %@"
        case .auditSummary: return "Shown in a summary banner %@"
        case .auditQueued: return "Banner queued %@"
        case .auditClicked: return "You clicked it %@"
        case .auditAcknowledged: return "You dismissed it %@"
        case .auditResolved: return "Resolved %@"
        case .auditSkipInFront: return "No banner (%@): the prompt was already in front of you"
        case .auditSkipMuted: return "No banner (%@): this agent is muted"
        case .auditSkipAcknowledged: return "No banner (%@): you had already dismissed it"
        case .auditSkipHeld: return "Held (%@): another banner was shown moments ago"
        case .auditSkipNotifyOff: return "No banner (%@): “needs you” notifications are off"
        case .auditSkipNotAuthorized: return "No banner (%@): macOS has not allowed Pulse to notify"
        case .auditSkipAtLaunch: return "No banner (%@): it was already waiting when Pulse started"
        case .auditSkipRejected: return "No banner (%@): macOS refused it — check Notifications and Focus"
        case .details: return "Details"
        case .detailNotificationHeading: return "Notification"
        case .detailBack: return "Back"
        case .detailMinutesIn: return "%@ %d min"
        case .filterMatches: return "%d matches"
        case .trayKeyHints: return "↑↓ select   ↩ go   → details   ⌘D dismiss   ⌘M mute   esc close"
        case .activityLeft: return "left the list"
        case .activityFromProcess: return "process only"
        case .activityHeading: return "Activity"
        case .activityEmpty: return "Nothing recorded yet. State changes and banners appear here as they happen."
        case .activityAllAgents: return "All agents"
        case .explainHook: return "%@'s hook reported %@ %@"
        case .explainHookFront: return " — its window was in front, so no banner"
        case .explainTurn: return "%@'s hook reported the turn ended %@ — focus it or reply to clear"
        case .explainProcessOnly: return "Seen only as a process — no hook event since Pulse started"
        case .explainStalled: return "No new output for %@"
        case .explainStalledUnknown: return "Running, but Pulse has no clock for its activity"
        case .explainRunning: return "%@'s hook reported work %@"
        case .explainRunningNoClock: return "A live process, and no clock for its activity yet"
        case .explainKindPermission: return "a permission request"
        case .explainKindInput: return "a question"
        case .explainKindWaiting: return "that it is waiting"
        case .sourceHooks: return "Hooks only"
        case .sourceProcess: return "Process only"
        case .detailModel: return "Model"
        case .detailSource: return "Source"
        case .detailFolder: return "Folder"
        case .detailStarted: return "Started"
        case .doctorVerdictWorks: return "works"
        case .doctorVerdictUnproven: return "unproven"
        case .doctorVerdictAttention: return "attention"
        case .doctorVerdictAbsent: return "n/a"
        case .doctorHeader: return "Pulse %@ (%@) · macOS %@ · self-check"
        case .doctorAgentHooks: return "%@ hooks installed"
        case .doctorAgentFired: return "%@ hooks reach Pulse"
        case .doctorNotInstalled: return "%@ is not installed on this Mac"
        case .doctorSettingsUnreadable: return "The settings file is not valid JSON; Pulse will not edit it"
        case .doctorFixSettings: return "Fix the JSON, then install hooks from Settings"
        case .doctorNoHooks: return "No Pulse hook found"
        case .doctorInstallHooks: return "Settings → Hooks → Install hooks"
        case .doctorReinstallHooks: return "Reinstall hooks from Settings to pick up this version's events"
        case .doctorMissing: return "Missing: %@"
        case .doctorAllEvents: return "All %d events"
        case .doctorNeverFired: return "No hook event recorded in the last day"
        case .doctorUseOnceCodex: return "Finish one Codex turn; if nothing arrives, run /hooks in Codex and trust Pulse's hooks"
        case .doctorUseOnce: return "Use %@ once, then run the self-check again"
        case .doctorFired: return "Last event: %@, %@"
        case .doctorFiredLongAgo: return "Last event %@ was %@ — too old to prove today's install"
        case .doctorGatingHook: return "A Pulse entry sits on %@, which can gate the agent or fake a wait; reinstall hooks to remove it"
        case .doctorNotifyOnly: return " (the older notify hook is present)"
        case .doctorCodexNeedsTrust: return "Pulse's hooks are installed; whether Codex trusts them only shows once one fires"
        case .doctorCodexTrust: return "Run /hooks in Codex once and trust Pulse's entries"
        case .doctorAgoNow: return "just now"
        case .doctorAgoMinutes: return "%d min ago"
        case .doctorAgoHours: return "%d h ago"
        case .doctorAgoDays: return "%d days ago"
        case .processOnly: return "Process only"
        case .processOnlyN: return "process only"
        case .waiting1: return "needs you"
        case .stalledN: return "stalled"
        case .yourTurnN: return "your turn"
        case .lampRuleProcessOnly: return "Grey: an agent is running that Pulse can see only as a process."
        case .mute: return "Mute"
        case .unmute: return "Unmute"
        case .mutedWord: return "muted"
        case .diagnosticsOpen: return "Diagnostics…"
        case .diagnosticsTitle: return "Diagnostics"
        case .diagnosticsOverview: return "Overview"
        case .diagnosticsProblems: return "Problems"
        case .diagnosticsNoProblems: return "Nothing on this Mac needs fixing"
        case .copyReport: return "Copy report"
        case .headerUpdating: return "updating…"
        case .headerUpdatedNow: return "updated just now"
        case .headerUpdatedAgo: return "updated %@ ago"
        case .headerNotUpdated: return "not updated for %@"
        case .noticeNotificationsDenied: return "Notifications are off for Pulse — an agent that needs you cannot reach you"
        case .noticeNotificationsOff: return "Turn on notifications so an agent that needs you can reach you"
        case .filterLabel: return "Filter"
        case .settingsHookInstalled: return "Installed"
        case .settingsHookNotFound: return "Not on this Mac"
        case .settingsHookLastEvent: return "last event %@ ago"
        case .settingsHookLastEventNow: return "last event just now"
        case .settingsHookNoEvent: return "no event yet"
        case .settingsHookNoWait: return "Doesn't report when it waits — running and your turn only"
        case .doctorNoWaitNote: return " · reports running and your turn, never a wait"
        case .settingsHooksSection: return "Hooks"
        case .settingsTerminalSection: return "Terminal control"
        case .settingsUpdatesSection: return "Updates"
        case .detailLastMessage: return "Last message"
        case .detailErrorHeading: return "Error"
        case .detailSession: return "Session"
        case .detailGo: return "Go"
        case .detailGoNone: return "No way to reach it — observed only"
        case .detailProcess: return "Process"
        case .detailLastChange: return "Last change"
        case .detailDiagnostics: return "How Pulse reads this session"
        case .explainIdle: return "At its prompt, nothing owed; last event %@"
        case .explainEnded: return "The session ended %@"
        case .explainQuiet: return "No event for %@, and no process Pulse can see — shown as recent"
        case .supportSessions: return "%d session(s) from its hook events"
        case .supportProcessOnly: return "%d process(es) with no hook event yet — started before Pulse, or without its hook"
        case .supportUnproven: return "Hook never fired"
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
        case .justNow: return "刚刚"
        case .notYet: return "尚未更新"
        case .andMore: return "另有 %d 个…"
        case .showLess: return "收起"
        case .settings: return "偏好设置…"
        case .quit: return "退出 Pulse"
        case .general: return "通用"
        case .notifyWaiting: return "Agent 需要我时通知"
        case .focusExact: return "前往终端"
        case .focusApp: return "打开应用"
        case .focusOpenTray: return "打开 Pulse 托盘"
        case .focusAppOnly: return "已打开应用 —— 无法选中具体终端"
        case .allowTerminalAutomation: return "允许聚焦 Terminal / iTerm 标签"
        case .allowTerminalAutomationHint:
            return "默认关闭。开启后，「前往」时 macOS 可能请求自动化权限，以选中确切的 iTerm 会话或 Terminal 标签。tmux、其他终端与编辑器不需要此项。"
        case .supportFocusNone: return "聚焦：仅观测"
        case .supportFocusExact: return "聚焦：确切的终端"
        case .supportFocusApp: return "聚焦：仅应用"
        case .signalHooks: return "Hook 报告"
        case .launchAtLogin: return "登录时启动"
        case .language: return "语言"
        case .hooksHint: return "为每个 Agent 安装它自己文档里的 hook、插件或扩展——只用观察型事件，从不用能拦截或代答的事件。移除时每个文件逐字节还原。"
        case .installHooks: return "安装 hooks"
        case .testWaitingSignal: return "测试连接"
        case .hookTestIdle: return "尚未测试"
        case .hookTestRunning: return "测试中…"
        case .hookTestPassed: return "连接测试通过"
        case .hookTestFailed: return "连接测试失败"
        case .shortcuts: return "快捷键"
        case .running: return "运行中"
        case .settingsTitle: return "Pulse 偏好设置"
        case .recent: return "最近"
        case .dismissWait: return "忽略"
        case .focusFailed: return "没能打开 —— 那个窗口可能已经不在了，正在重扫"
        case .hooksNudge: return "安装 hooks，就能看到你在用的 Agent 的确切请求和「轮到你」"
        case .hooksUnknown: return "未检查"
        case .hooksMissing: return "未安装"
        case .hooksInstalledCount: return "已安装 · %d / %d 个 Agent"
        case .hooksFailed: return "失败"
        case .kindPermission: return "需要授权"
        case .kindInput: return "等待输入"
        case .kindWaiting: return "等待中"
        case .terminalSession: return "终端会话正在运行"
        case .appSession: return "Agent 应用正在运行"
        case .terminalDetectedNoDetails: return "终端会话正在运行 · 暂无活动数据"
        case .appDetectedNoDetails: return "Agent 应用正在运行 · 暂无会话数据"
        case .setupWaitingSignals: return "接入「需要你」…"
        case .copied: return "已复制"
        case .versionMismatchHint: return "程序版本为 %@，但 app 包标记为 %@ — 请用 PulseBar/Scripts/package.sh 重新打包。"
        case .durNow: return "刚刚"
        case .durSec: return "%d 秒"
        case .durMin: return "%d 分"
        case .durHour: return "%d 小时"
        case .notificationsSection: return "通知"
        case .notifyNotConfigured: return "通知尚未启用。点击“启用通知”后 Pulse 才会请求权限。"
        case .enableNotifications: return "启用通知"
        case .notifyDenied: return "系统已关闭 Pulse 的通知权限，下面的开关不会生效。"
        case .openNotificationSettings: return "打开系统设置"
        case .uninstallHooks: return "移除 hooks"
        case .revealShortcut: return "打开或关闭 Pulse"
        case .hotkeyTaken: return "该快捷键已被其他应用占用，请换一个。"
        case .emptyHint: return "Pulse 显示正在运行的 Agent，以及 45 分钟内有过活动的会话，全部读自这台 Mac。"
        case .checkForUpdates: return "检查更新"
        case .checkNow: return "立即检查"
        case .openRelease: return "打开发布页"
        case .updateIdle: return "未检查"
        case .updateChecking: return "检查中…"
        case .updateCurrent: return "已是最新"
        case .updateCurrentPrerelease: return "已是最新（preview 通道 · 未签名公证）"
        case .updateCurrentStable:
            return "已是最新（stable 不含 prerelease；公证前能力可能仍在预发布）"
        case .updateAvailable: return "有新版本：%@"
        case .updateFailed: return "检查失败"
        case .probeEvery: return "每 %d 秒查看一次进程"
        case .probeParked: return "已暂停（屏幕关闭）"
        case .a11yIdle: return "空闲"
        case .a11yRunning: return "运行中"
        case .a11yStalled: return "停滞"
        case .a11yWaiting: return "需要你"
        case .sectionNeedsYou: return "需要你"
        case .sectionRunning: return "运行中"
        case .sectionStalled: return "停滞"
        case .sectionRecent: return "最近"
        case .moreActions: return "更多操作"
        case .agoFormat: return "%@前"
        case .stalled: return "停滞"
        case .supportWaitingHooks: return "等待通路：hooks"
        case .supportWaitingNoneDetail: return "不能主动报告「需要你」—— 可以通过 Attention 桥接入"
        case .supportSharedCursor: return "Cursor IDE 与 cursor-agent 命令行是同一个 Agent"
        case .supportNeedsAction: return "需要处理"
        case .supportAvailable: return "可用"
        case .supportNotInstalled: return "未安装"
        case .supportNoRecentSession: return "无近期会话"
        case .notifFocus: return "前往"
        case .waitingSummaryTitle: return "%d 个 Agent 需要你"
        case .searchNoResults: return "没有匹配「%@」的会话"
        case .updatePreview: return "预览版 · ad-hoc 签名 · 未公证"
        case .updateSignedUnnotarized: return "已用 Developer ID 签名 · 未公证 · Gatekeeper 可能拦截"
        case .doctorRun: return "运行自检"
        case .doctorHint: return "读取这台 Mac 上每个 Agent 的 hook 文件与 hook 记录，运行一次 claude agents --json，说明哪些约定在这里已被证实。不写任何东西；复制出的报告不含路径、提示词或会话 id。"
        case .yourTurn: return "轮到你"
        case .shortcutOff: return "关闭"
        case .settingsHooksTitle: return "Agent 的 hooks"
        case .settingsHooksTest: return "测试连接"
        case .healthAgentsHeading: return "Agent"
        case .healthRunCheck: return "运行"
        case .healthRunAgain: return "重新运行"
        case .lastReadJustNow: return "刚刚读取"
        case .lastReadAgo: return "%@前读取"
        case .updateFailedBadFeed: return "更新源地址无效"
        case .updateFailedNetwork: return "无法连接 GitHub"
        case .updateFailedHTTP: return "GitHub 返回 %d"
        case .updateFailedBadResponse: return "GitHub 返回的不是发布信息"
        case .updateFailedNoTag: return "最新发布没有版本标签"
        case .staleHidden: return "%d 个较早的会话未显示（%@）"
        case .waitingBannerFailed: return "macOS 没有显示上一条「需要你」的通知 —— 请检查通知设置"
        case .lampRuleBlocked: return "红：有 Agent 在等你。"
        case .lampRuleStalled: return "橙：有运行中的会话停滞了。"
        case .lampRuleRunning: return "绿：Agent 在工作，没有需要你的事。"
        case .lampRuleTurn: return "灰：有回合结束了，轮到你（不急）。"
        case .lampRuleRecent: return "灰：没有在运行的；列出的是最近的会话。"
        case .lampRuleIdle: return "灰：没有在运行的编码 Agent。"
        case .auditRaised: return "%@ 开始等待"
        case .auditPosted: return "%@ 发出通知"
        case .auditSummary: return "%@ 合并进汇总通知"
        case .auditQueued: return "%@ 通知排队中"
        case .auditClicked: return "%@ 你点了通知"
        case .auditAcknowledged: return "%@ 你忽略了它"
        case .auditResolved: return "%@ 已解决"
        case .auditSkipInFront: return "没有通知（%@）：提示已经在你眼前"
        case .auditSkipMuted: return "没有通知（%@）：这个 Agent 已静音"
        case .auditSkipAcknowledged: return "没有通知（%@）：你已经忽略过它"
        case .auditSkipHeld: return "延后（%@）：刚刚发过另一条通知"
        case .auditSkipNotifyOff: return "没有通知（%@）：「需要你」通知已关闭"
        case .auditSkipNotAuthorized: return "没有通知（%@）：macOS 尚未允许 Pulse 发通知"
        case .auditSkipAtLaunch: return "没有通知（%@）：Pulse 启动时它已经在等"
        case .auditSkipRejected: return "没有通知（%@）：macOS 拒绝了 —— 请检查通知与专注模式"
        case .details: return "详情"
        case .detailNotificationHeading: return "通知"
        case .detailBack: return "返回"
        case .detailMinutesIn: return "%@ %d 分钟"
        case .filterMatches: return "%d 个匹配"
        case .trayKeyHints: return "↑↓ 选择   ↩ 前往   → 详情   ⌘D 忽略   ⌘M 静音   esc 关闭"
        case .activityLeft: return "离开了列表"
        case .activityFromProcess: return "仅进程"
        case .activityHeading: return "动态"
        case .activityEmpty: return "还没有记录。状态变化和通知会在发生时出现在这里。"
        case .activityAllAgents: return "全部 Agent"
        case .explainHook: return "%@ 的 hook 报告了%@ · %@"
        case .explainHookFront: return " —— 当时提示窗口就在最前，所以没有通知"
        case .explainTurn: return "%@ 的 hook 报告回合结束 · %@ —— 聚焦或回复它即消失"
        case .explainProcessOnly: return "只看到进程——Pulse 启动后它还没发过 hook 事件"
        case .explainStalled: return "已经 %@ 没有新输出"
        case .explainStalledUnknown: return "在运行，但 Pulse 读不到它的活动时间"
        case .explainRunning: return "%@ 的 hook 报告在工作 · %@"
        case .explainRunningNoClock: return "进程在运行，还读不到它的活动时间"
        case .explainKindPermission: return "权限请求"
        case .explainKindInput: return "一个问题"
        case .explainKindWaiting: return "在等待"
        case .sourceHooks: return "仅 hook"
        case .sourceProcess: return "仅进程"
        case .detailModel: return "模型"
        case .detailSource: return "来源"
        case .detailFolder: return "目录"
        case .detailStarted: return "开始于"
        case .doctorVerdictWorks: return "已验证"
        case .doctorVerdictUnproven: return "未证实"
        case .doctorVerdictAttention: return "需处理"
        case .doctorVerdictAbsent: return "不适用"
        case .doctorHeader: return "Pulse %@（%@）· macOS %@ · 自检"
        case .doctorAgentHooks: return "%@ hooks 已安装"
        case .doctorAgentFired: return "%@ hooks 到达 Pulse"
        case .doctorNotInstalled: return "这台 Mac 没有安装 %@"
        case .doctorSettingsUnreadable: return "设置文件不是合法 JSON；Pulse 不会改它"
        case .doctorFixSettings: return "修好 JSON 后在设置里安装 hooks"
        case .doctorNoHooks: return "没有找到 Pulse 的 hook"
        case .doctorInstallHooks: return "设置 → Hooks → 安装 hooks"
        case .doctorReinstallHooks: return "在设置里重新安装 hooks，以获得这一版的事件"
        case .doctorMissing: return "缺少：%@"
        case .doctorAllEvents: return "全部 %d 个事件"
        case .doctorNeverFired: return "最近一天没有记录到 hook 事件"
        case .doctorUseOnceCodex: return "在 Codex 里完成一轮；若仍没有，在 Codex 里运行 /hooks 并信任 Pulse 的 hooks"
        case .doctorUseOnce: return "用 %@ 完成一次操作后再自检一次"
        case .doctorFired: return "最近事件：%@，%@"
        case .doctorFiredLongAgo: return "最近事件 %@ 在 %@——太久，证明不了现在的安装"
        case .doctorGatingHook: return "Pulse 的条目挂在 %@ 上，它可能拦住 Agent 或造成假的等待；重新安装 hooks 即可移除"
        case .doctorNotifyOnly: return "（仍有旧的 notify hook）"
        case .doctorCodexNeedsTrust: return "Pulse 的 hooks 已安装；Codex 是否信任它们，要等触发一次才知道"
        case .doctorCodexTrust: return "在 Codex 里运行一次 /hooks 并信任 Pulse 的条目"
        case .doctorAgoNow: return "刚刚"
        case .doctorAgoMinutes: return "%d 分钟前"
        case .doctorAgoHours: return "%d 小时前"
        case .doctorAgoDays: return "%d 天前"
        case .processOnly: return "仅进程"
        case .processOnlyN: return "仅进程"
        case .waiting1: return "需要你"
        case .stalledN: return "停滞"
        case .yourTurnN: return "轮到你"
        case .lampRuleProcessOnly: return "灰：有 Agent 在运行，但 Pulse 只看到进程。"
        case .mute: return "静音"
        case .unmute: return "取消静音"
        case .mutedWord: return "已静音"
        case .diagnosticsOpen: return "诊断…"
        case .diagnosticsTitle: return "诊断"
        case .diagnosticsOverview: return "概览"
        case .diagnosticsProblems: return "问题"
        case .diagnosticsNoProblems: return "这台 Mac 上没有需要修的问题"
        case .copyReport: return "复制报告"
        case .headerUpdating: return "正在读取…"
        case .headerUpdatedNow: return "刚刚更新"
        case .headerUpdatedAgo: return "%@前更新"
        case .headerNotUpdated: return "已 %@ 未更新"
        case .noticeNotificationsDenied: return "Pulse 的通知被关闭了 —— 需要你的 Agent 没法提醒你"
        case .noticeNotificationsOff: return "开启通知，需要你的 Agent 才能提醒到你"
        case .filterLabel: return "筛选"
        case .settingsHookInstalled: return "已安装"
        case .settingsHookNotFound: return "这台 Mac 上没有"
        case .settingsHookLastEvent: return "最近事件 %@ 前"
        case .settingsHookLastEventNow: return "最近事件：刚刚"
        case .settingsHookNoEvent: return "还没有事件"
        case .settingsHookNoWait: return "不会报告它在等你——只显示运行中与轮到你"
        case .doctorNoWaitNote: return " · 只报告运行中与轮到你，从不报告等待"
        case .settingsHooksSection: return "Hooks"
        case .settingsTerminalSection: return "终端控制"
        case .settingsUpdatesSection: return "更新"
        case .detailLastMessage: return "最后的消息"
        case .detailErrorHeading: return "错误"
        case .detailSession: return "会话"
        case .detailGo: return "前往"
        case .detailGoNone: return "无法前往 —— 仅观测"
        case .detailProcess: return "进程"
        case .detailLastChange: return "最后变化"
        case .detailDiagnostics: return "Pulse 如何读取这个会话"
        case .explainIdle: return "停在提示符，没有欠你的事 · 最近事件 %@"
        case .explainEnded: return "会话已结束 · %@"
        case .explainQuiet: return "已经 %@ 没有事件，也看不到它的进程 —— 按最近显示"
        case .supportSessions: return "hook 事件带来 %d 个会话"
        case .supportProcessOnly: return "%d 个进程还没发过 hook 事件 —— 在 Pulse 之前启动，或没装 hook"
        case .supportUnproven: return "hook 还没触发过"
        }
    }

    /// `CaseIterable` so tests can assert every key resolves in both languages
    /// and that format specifiers match (a mismatched %d crashes String(format:)).
    enum Key: CaseIterable {
        case noAgents, noAgentsDetected, needsYou, waitingN, runningN
        case recent1, recentN, recent
        case justNow, notYet, andMore, showLess
        case settings, quit
        case focusExact, focusApp, focusOpenTray, dismissWait
        case focusFailed, focusAppOnly
        case allowTerminalAutomation, allowTerminalAutomationHint
        case supportFocusNone, supportFocusExact, supportFocusApp
        case general, notifyWaiting, launchAtLogin, language
        case hooksHint, installHooks, testWaitingSignal
        case hookTestIdle, hookTestRunning, hookTestPassed, hookTestFailed
        case shortcuts
        case running, settingsTitle
        case hooksNudge, hooksUnknown, hooksMissing, hooksInstalledCount
        case hooksFailed
        case kindPermission, kindInput, kindWaiting
        case signalHooks
        case terminalSession, appSession
        case terminalDetectedNoDetails, appDetectedNoDetails
        case setupWaitingSignals
        case copied
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
        case probeEvery, probeParked
        case a11yIdle, a11yRunning, a11yStalled, a11yWaiting
        case sectionNeedsYou, sectionRunning, sectionStalled, sectionRecent
        case moreActions
        case agoFormat
        case stalled
        case supportWaitingHooks, supportWaitingNoneDetail, supportSharedCursor
        case supportNeedsAction, supportAvailable, supportNotInstalled, supportNoRecentSession
        case notifFocus
        case waitingSummaryTitle, searchNoResults
        case updatePreview, updateSignedUnnotarized
        case yourTurn
        case doctorRun, doctorHint
        case shortcutOff
        case settingsHooksTitle
        case settingsHooksTest
        case settingsHookInstalled, settingsHookNotFound, settingsHookLastEvent, settingsHookLastEventNow, settingsHookNoEvent, settingsHookNoWait, doctorNoWaitNote
        case healthAgentsHeading
        case healthRunCheck
        case healthRunAgain
        case lastReadJustNow
        case lastReadAgo
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
        case auditRaised
        case auditPosted
        case auditSummary
        case auditQueued
        case auditClicked
        case auditAcknowledged
        case auditResolved
        case auditSkipInFront
        case auditSkipMuted
        case auditSkipAcknowledged
        case auditSkipHeld
        case auditSkipNotifyOff
        case auditSkipNotAuthorized
        case auditSkipAtLaunch
        case auditSkipRejected
        case details
        case detailNotificationHeading
        case detailBack
        case detailMinutesIn
        case filterMatches
        case trayKeyHints
        case activityLeft
        case activityFromProcess
        case activityHeading
        case activityEmpty
        case activityAllAgents
        case explainHook
        case explainHookFront
        case explainTurn
        case explainProcessOnly
        case explainStalled
        case explainStalledUnknown
        case explainRunning
        case explainRunningNoClock
        case explainKindPermission
        case explainKindInput
        case explainKindWaiting
        case sourceHooks
        case sourceProcess
        case detailModel
        case detailSource
        case detailFolder
        case detailStarted
        case doctorVerdictWorks
        case doctorVerdictUnproven
        case doctorVerdictAttention
        case doctorVerdictAbsent
        case doctorHeader
        case doctorAgentHooks
        case doctorAgentFired
        case doctorNotInstalled
        case doctorSettingsUnreadable
        case doctorFixSettings
        case doctorNoHooks
        case doctorInstallHooks
        case doctorReinstallHooks
        case doctorMissing
        case doctorAllEvents
        case doctorNeverFired
        case doctorUseOnceCodex
        case doctorUseOnce
        case doctorFired
        case doctorFiredLongAgo
        case doctorGatingHook
        case doctorNotifyOnly
        case doctorCodexNeedsTrust
        case doctorCodexTrust
        case doctorAgoNow
        case doctorAgoMinutes
        case doctorAgoHours
        case doctorAgoDays
        // 23.0
        case processOnly
        case processOnlyN
        case waiting1
        case stalledN
        case yourTurnN
        case lampRuleProcessOnly
        case mute
        case unmute
        case mutedWord
        case diagnosticsOpen
        case diagnosticsTitle
        case diagnosticsOverview
        case diagnosticsProblems
        case diagnosticsNoProblems
        case copyReport
        case headerUpdating
        case headerUpdatedNow
        case headerUpdatedAgo
        case headerNotUpdated
        case noticeNotificationsDenied
        case noticeNotificationsOff
        case filterLabel
        case settingsHooksSection
        case settingsTerminalSection
        case settingsUpdatesSection
        case detailLastMessage
        case detailErrorHeading
        case detailSession
        case detailGo
        case detailGoNone
        case detailProcess
        case detailLastChange
        case detailDiagnostics
        case explainIdle, explainEnded, explainQuiet
        case supportSessions, supportProcessOnly, supportUnproven
    }
}

/// Shared duration wording. Lived on `StatusStore` as an instance method, so
/// `SnapshotBuilder` — which is pure and has no store — could not reuse it and
/// the menu bar had no way to say how long something had been waiting.
enum DurationFormat {
    static func label(seconds ago: Double, lang: ResolvedLanguage) -> String {
        if ago < 5 { return L10n.t(.durNow, lang) }
        if ago < 60 { return String(format: L10n.t(.durSec, lang), Int(ago)) }
        if ago < 3600 { return String(format: L10n.t(.durMin, lang), Int(ago / 60)) }
        return String(format: L10n.t(.durHour, lang), Int(ago / 3600))
    }
}
