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

    /// English copy.
    private static func en(_ key: Key) -> String {
        switch key {
        case .noAgents: return "No coding agents"
        case .noAgentsDetected: return "No coding agents detected"
        case .needsYou: return "Needs you"
        case .waitingN: return "waiting"
        case .runningN: return "running"
        case .running1: return "1 running"
        case .recent1: return "1 recent"
        case .recentN: return "recent"
        case .justNow: return "just now"
        case .notYet: return "not yet"
        case .cantRefresh: return "Can't refresh"
        case .andMore: return "and %d more…"
        case .showLess: return "Show less"
        case .refresh: return "Refresh"
        case .refreshing: return "Refreshing…"
        case .clearWaiting: return "Clear waiting"
        case .settings: return "Settings…"
        case .quit: return "Quit Pulse"
        case .focusTerminal: return "Focus terminal"
        case .openFolder: return "Open folder"
        case .general: return "General"
        case .liveUpdates: return "Live updates"
        case .notifications: return "Notify when idle"
        case .notifyWaiting: return "Notify on new Waiting"
        case .quietHours: return "Quiet hours (idle only)"
        case .quietHoursHint:
            return "Waiting notifications still fire. Equal start/end disables quiet hours. The window may wrap past midnight."
        case .quietStart: return "From"
        case .quietEnd: return "Until"
        case .focusTTY: return "Focus TTY"
        case .focusWarp: return "Focus Warp"
        case .activityPrefix: return "Doing"
        case .signalHooks: return "hooks"
        case .signalPending: return "pending"
        case .attentionBridgeHint:
            return "Optional: Droid / Kimi can append attention.tsv — see docs/attention-bridge.md (no extra installer)."
        case .launchAtLogin: return "Launch at login"
        case .language: return "Language"
        case .waitingSignals: return "Waiting signals"
        case .hooksHint:
            return "Install Claude/Codex hooks so Pulse can show permission, input waits, and subagent lifecycle."
        case .installHooks: return "Install hooks"
        case .shortcuts: return "Shortcuts"
        case .hotkeyHint: return "Tap a notification to focus the waiting agent."
        case .agents: return "Agents"
        case .running: return "Running"
        case .idleNotify: return "All coding agents idle"
        case .settingsTitle: return "Pulse Settings"
        case .recent: return "Recent"
        case .dismissWait: return "Dismiss"
        case .hooksNudge: return "Install hooks so Claude/Codex can signal Waiting"
        case .waitingSignalNudge: return "This agent has no Waiting signal yet — Running only"
        case .hooksUnknown: return "Not checked"
        case .hooksMissing: return "Not installed"
        case .hooksInstalledBoth: return "Installed · Claude + Codex"
        case .hooksInstalledClaude: return "Installed · Claude"
        case .hooksInstalledCodex: return "Installed · Codex"
        case .hooksFailed: return "Failed"
        case .a11yHint: return "If the shortcut does nothing, grant Accessibility to Pulse in System Settings."
        case .kindPermission: return "Permission"
        case .kindInput: return "Input"
        case .kindWaiting: return "Waiting"
        case .idleWord: return "idle"
        case .processDetected: return "Process detected"
        case .processWord: return "process"
        case .processCount: return "%d processes"
        case .about: return "About"
        case .tagline: return "Status lamp for coding agents"
        case .build: return "Build"
        case .devBuild: return "dev build"
        case .copyDiagnostics: return "Copy diagnostics"
        case .copied: return "Copied"
        case .versionStale: return "stale bundle"
        case .versionMismatchHint:
            return "Binary reports %@ but the bundle says %@ — repackage with PulseBar/Scripts/package.sh."
        case .durNow: return "now"
        case .durSec: return "%ds"
        case .durMin: return "%dm"
        case .durHour: return "%dh"
        case .notificationsSection: return "Notifications"
        case .notifyDenied: return "Notifications are turned off for Pulse — these switches cannot fire."
        case .openNotificationSettings: return "Open System Settings"
        case .muteAgents: return "Mute agents"
        case .muteHint: return "Muted agents still appear in the tray; they just stop sending notifications."
        case .uninstallHooks: return "Remove hooks"
        case .revealShortcut: return "Reveal Pulse"
        case .hotkeyTaken: return "Another app already owns this shortcut — pick a different one."
        case .recentWaits: return "Recent waits"
        case .clearHistory: return "Clear history"
        case .waitedFor: return "waited %@"
        case .cappedSessions: return "%d more session(s) not shown"
        case .emptyHint:
            return "Pulse lights up when a coding agent is running or needs you. Install hooks so Claude/Codex can report Waiting."
        case .checkForUpdates: return "Check for updates"
        case .checkNow: return "Check now"
        case .openRelease: return "Open release"
        case .updateIdle: return "Not checked"
        case .updateChecking: return "Checking…"
        case .updateCurrent: return "Up to date"
        case .updateAvailable: return "Update available: %@"
        case .updateFailed: return "Check failed"
        case .probeEvery: return "every %ds"
        case .probeParked: return "paused (display off)"
        case .probePaused: return "live updates off"
        case .a11yIdle: return "Idle"
        case .a11yRunning: return "Running"
        case .a11yWaiting: return "Needs attention"
        case .a11yError: return "Cannot refresh"
        case .sectionNeedsYou: return "Needs you"
        case .sectionRunning: return "Running"
        case .sectionRecent: return "Recent"
        case .groupByAgent: return "By agent"
        case .groupByProject: return "By project"
        case .groupingLabel: return "Group tray by"
        case .jumpToOldest: return "Jump to longest wait"
        case .interruptionsToday: return "Today: %d interruptions, %@ average wait"
        case .playSound: return "Play a sound on new waits"
        case .waitedLongest: return "longest"
        case .moreActions: return "More actions"
        case .acrossProjects: return "across %d projects"
        case .agoFormat: return "%@ ago"
        case .whileAway: return "%d wait(s) ended while you were away"
        case .noActivityYet: return "no activity yet"
        case .noProject: return "No project"
        case .stalled: return "Stalled"
        case .snooze: return "Later"
        case .snoozed: return "snoozed"
        case .snoozedFor: return "Later · %@ left"
        case .stallAfter: return "Call it stalled after"
        case .stallOff: return "Never"
        case .minutesShort: return "%d min"
        case .notifFocus: return "Focus"
        case .recordsSuffix: return " records"
        case .sessionAge: return "session %@"
        }
    }

    /// 简体中文文案。
    private static func zh(_ key: Key) -> String {
        switch key {
        case .noAgents: return "当前没有编码 Agent"
        case .noAgentsDetected: return "未检测到编码 Agent"
        case .needsYou: return "需要你处理"
        case .waitingN: return "个等待中"
        case .runningN: return "个运行中"
        case .running1: return "1 个运行中"
        case .recent1: return "1 个最近会话"
        case .recentN: return "个最近会话"
        case .justNow: return "刚刚"
        case .notYet: return "尚未更新"
        case .cantRefresh: return "无法刷新"
        case .andMore: return "另有 %d 个…"
        case .showLess: return "收起"
        case .refresh: return "刷新"
        case .refreshing: return "刷新中…"
        case .clearWaiting: return "清除等待"
        case .settings: return "偏好设置…"
        case .quit: return "退出 Pulse"
        case .focusTerminal: return "聚焦终端"
        case .openFolder: return "打开目录"
        case .general: return "通用"
        case .liveUpdates: return "实时更新"
        case .notifications: return "全部空闲时通知"
        case .notifyWaiting: return "新的「需要你」时通知"
        case .quietHours: return "安静时段（仅抑制空闲通知）"
        case .quietHoursHint: return "Waiting 通知仍会发送。起止相同时安静时段不生效。时段可跨午夜。"
        case .quietStart: return "开始"
        case .quietEnd: return "结束"
        case .focusTTY: return "聚焦终端页"
        case .focusWarp: return "聚焦 Warp"
        case .activityPrefix: return "刚才"
        case .signalHooks: return "hooks"
        case .signalPending: return "pending"
        case .attentionBridgeHint: return "可选：Droid / Kimi 可写入 attention.tsv — 见 docs/attention-bridge.md（不扩安装器）。"
        case .launchAtLogin: return "登录时启动"
        case .language: return "语言"
        case .waitingSignals: return "等待信号"
        case .hooksHint: return "安装 Claude/Codex hooks 后，Pulse 才能显示权限、输入等待与 subagent 生命周期。"
        case .installHooks: return "安装连接"
        case .shortcuts: return "快捷键"
        case .hotkeyHint: return "点击通知即可聚焦等待中的 Agent。"
        case .agents: return "Agents"
        case .running: return "运行中"
        case .idleNotify: return "所有编码 Agent 已空闲"
        case .settingsTitle: return "Pulse 偏好设置"
        case .recent: return "最近"
        case .dismissWait: return "忽略等待"
        case .hooksNudge: return "安装 hooks 后，Claude/Codex 才能点亮「需要你」"
        case .waitingSignalNudge: return "该 Agent 暂无 Waiting 信号，目前仅显示运行中"
        case .hooksUnknown: return "未检查"
        case .hooksMissing: return "未安装"
        case .hooksInstalledBoth: return "已安装 · Claude + Codex"
        case .hooksInstalledClaude: return "已安装 · Claude"
        case .hooksInstalledCodex: return "已安装 · Codex"
        case .hooksFailed: return "失败"
        case .a11yHint: return "若快捷键无响应，请在系统设置中为 Pulse 开启辅助功能权限。"
        case .kindPermission: return "需要授权"
        case .kindInput: return "等待输入"
        case .kindWaiting: return "等待中"
        case .idleWord: return "空闲"
        case .processDetected: return "检测到进程"
        case .processWord: return "进程"
        case .processCount: return "%d 个进程"
        case .about: return "关于"
        case .tagline: return "编码 Agent 状态灯"
        case .build: return "构建"
        case .devBuild: return "开发构建"
        case .copyDiagnostics: return "复制诊断信息"
        case .copied: return "已复制"
        case .versionStale: return "版本不一致"
        case .versionMismatchHint: return "程序版本为 %@，但 app 包标记为 %@ — 请用 PulseBar/Scripts/package.sh 重新打包。"
        case .durNow: return "刚刚"
        case .durSec: return "%d 秒"
        case .durMin: return "%d 分"
        case .durHour: return "%d 小时"
        case .notificationsSection: return "通知"
        case .notifyDenied: return "系统已关闭 Pulse 的通知权限，下面的开关不会生效。"
        case .openNotificationSettings: return "打开系统设置"
        case .muteAgents: return "静音 Agent"
        case .muteHint: return "被静音的 Agent 仍会出现在列表中，只是不再发送通知。"
        case .uninstallHooks: return "移除连接"
        case .revealShortcut: return "唤出 Pulse"
        case .hotkeyTaken: return "该快捷键已被其他应用占用，请换一个。"
        case .recentWaits: return "最近的等待"
        case .clearHistory: return "清空记录"
        case .waitedFor: return "等待 %@"
        case .cappedSessions: return "另有 %d 个会话未显示"
        case .emptyHint: return "有编码 Agent 在跑或在等你时，Pulse 才会亮。安装 hooks 后 Claude/Codex 才能上报「需要你」。"
        case .checkForUpdates: return "检查更新"
        case .checkNow: return "立即检查"
        case .openRelease: return "打开发布页"
        case .updateIdle: return "未检查"
        case .updateChecking: return "检查中…"
        case .updateCurrent: return "已是最新"
        case .updateAvailable: return "有新版本：%@"
        case .updateFailed: return "检查失败"
        case .probeEvery: return "每 %d 秒"
        case .probeParked: return "已暂停（屏幕关闭）"
        case .probePaused: return "实时更新已关闭"
        case .a11yIdle: return "空闲"
        case .a11yRunning: return "运行中"
        case .a11yWaiting: return "需要你处理"
        case .a11yError: return "无法刷新"
        case .sectionNeedsYou: return "需要你"
        case .sectionRunning: return "运行中"
        case .sectionRecent: return "最近"
        case .groupByAgent: return "按 Agent"
        case .groupByProject: return "按项目"
        case .groupingLabel: return "托盘分组方式"
        case .jumpToOldest: return "跳到等待最久的"
        case .interruptionsToday: return "今天：被打断 %d 次，平均等待 %@"
        case .playSound: return "新等待时播放提示音"
        case .waitedLongest: return "最久"
        case .moreActions: return "更多操作"
        case .acrossProjects: return "%d 个项目"
        case .agoFormat: return "%@前"
        case .whileAway: return "你离开时有 %d 个等待已结束"
        case .noActivityYet: return "暂无动静"
        case .noProject: return "无项目"
        case .stalled: return "停滞"
        case .snooze: return "稍后"
        case .snoozed: return "已稍后"
        case .snoozedFor: return "已稍后 · 剩 %@"
        case .stallAfter: return "多久算停滞"
        case .stallOff: return "不判定"
        case .minutesShort: return "%d 分钟"
        case .notifFocus: return "去看看"
        case .recordsSuffix: return " 条记录"
        case .sessionAge: return "会话 %@"
        }
    }

    /// `CaseIterable` so tests can assert every key resolves in both languages
    /// and that format specifiers match (a mismatched %d crashes String(format:)).
    enum Key: CaseIterable {
        case noAgents, noAgentsDetected, needsYou, waitingN, runningN, running1
        case recent1, recentN, recent, idleWord
        case justNow, notYet, cantRefresh, andMore, showLess
        case refresh, refreshing, clearWaiting, settings, quit
        case focusTerminal, focusTTY, focusWarp, openFolder, dismissWait
        case general, liveUpdates, notifications, notifyWaiting, launchAtLogin, language
        case quietHours, quietHoursHint, quietStart, quietEnd
        case waitingSignals, hooksHint, installHooks, attentionBridgeHint, shortcuts, hotkeyHint, a11yHint
        case agents, running, idleNotify, settingsTitle
        case hooksNudge, waitingSignalNudge, hooksUnknown, hooksMissing, hooksInstalledBoth
        case hooksInstalledClaude, hooksInstalledCodex, hooksFailed
        case kindPermission, kindInput, kindWaiting
        case activityPrefix, signalHooks, signalPending
        case processDetected, processWord, processCount
        case about, tagline, build, devBuild, copyDiagnostics, copied
        case versionStale, versionMismatchHint
        case durNow, durSec, durMin, durHour
        case notificationsSection, notifyDenied, openNotificationSettings
        case muteAgents, muteHint, uninstallHooks
        case revealShortcut, hotkeyTaken
        case recentWaits, clearHistory, waitedFor, cappedSessions, emptyHint
        case checkForUpdates, checkNow, openRelease
        case updateIdle, updateChecking, updateCurrent, updateAvailable, updateFailed
        case probeEvery, probeParked, probePaused
        case a11yIdle, a11yRunning, a11yWaiting, a11yError
        case sectionNeedsYou, sectionRunning, sectionRecent
        case groupByAgent, groupByProject, groupingLabel
        case jumpToOldest, interruptionsToday, playSound
        case waitedLongest, moreActions
        case acrossProjects, agoFormat, whileAway, noActivityYet
        case noProject, stalled
        case snooze, snoozed, snoozedFor, stallAfter, stallOff, minutesShort, notifFocus
        case recordsSuffix, sessionAge
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
