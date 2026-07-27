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
    static func t(_ key: Key, _ lang: ResolvedLanguage) -> String {
        switch (key, lang) {
        case (.noAgents, .en): return "No coding agents"
        case (.noAgents, .zh): return "当前没有编码 Agent"
        case (.noAgentsDetected, .en): return "No coding agents detected"
        case (.noAgentsDetected, .zh): return "未检测到编码 Agent"
        case (.needsYou, .en): return "Needs you"
        case (.needsYou, .zh): return "需要你处理"
        case (.waitingN, .en): return "waiting"
        case (.waitingN, .zh): return "个等待中"
        case (.runningN, .en): return "running"
        case (.runningN, .zh): return "个运行中"
        case (.running1, .en): return "1 running"
        case (.running1, .zh): return "1 个运行中"
        case (.recent1, .en): return "1 recent"
        case (.recent1, .zh): return "1 个最近会话"
        case (.recentN, .en): return "recent"
        case (.recentN, .zh): return "个最近会话"
        case (.justNow, .en): return "just now"
        case (.justNow, .zh): return "刚刚"
        case (.notYet, .en): return "not yet"
        case (.notYet, .zh): return "尚未更新"
        case (.cantRefresh, .en): return "Can't refresh"
        case (.cantRefresh, .zh): return "无法刷新"
        case (.andMore, .en): return "and %d more…"
        case (.andMore, .zh): return "另有 %d 个…"
        case (.showLess, .en): return "Show less"
        case (.showLess, .zh): return "收起"
        case (.refresh, .en): return "Refresh"
        case (.refresh, .zh): return "刷新"
        case (.refreshing, .en): return "Refreshing…"
        case (.refreshing, .zh): return "刷新中…"
        case (.clearWaiting, .en): return "Clear waiting"
        case (.clearWaiting, .zh): return "清除等待"
        case (.settings, .en): return "Settings…"
        case (.settings, .zh): return "偏好设置…"
        case (.quit, .en): return "Quit Pulse"
        case (.quit, .zh): return "退出 Pulse"
        case (.focusTerminal, .en): return "Focus terminal"
        case (.focusTerminal, .zh): return "聚焦终端"
        case (.openFolder, .en): return "Open folder"
        case (.openFolder, .zh): return "打开目录"
        case (.general, .en): return "General"
        case (.general, .zh): return "通用"
        case (.liveUpdates, .en): return "Live updates"
        case (.liveUpdates, .zh): return "实时更新"
        case (.notifications, .en): return "Notify when idle"
        case (.notifications, .zh): return "全部空闲时通知"
        case (.notifyWaiting, .en): return "Notify on new Waiting"
        case (.notifyWaiting, .zh): return "新的「需要你」时通知"
        case (.quietHours, .en): return "Quiet hours (idle only)"
        case (.quietHours, .zh): return "安静时段（仅抑制空闲通知）"
        case (.quietHoursHint, .en): return "Waiting notifications still fire. Equal start/end disables quiet hours. The window may wrap past midnight."
        case (.quietHoursHint, .zh): return "Waiting 通知仍会发送。起止相同时安静时段不生效。时段可跨午夜。"
        case (.quietStart, .en): return "From"
        case (.quietStart, .zh): return "开始"
        case (.quietEnd, .en): return "Until"
        case (.quietEnd, .zh): return "结束"
        case (.focusTTY, .en): return "Focus TTY"
        case (.focusTTY, .zh): return "聚焦终端页"
        case (.focusWarp, .en): return "Focus Warp"
        case (.focusWarp, .zh): return "聚焦 Warp"
        case (.openInTerminal, .en): return "Open in terminal"
        case (.openInTerminal, .zh): return "在终端打开"
        case (.activityPrefix, .en): return "Doing"
        case (.activityPrefix, .zh): return "刚才"
        case (.signalHooks, .en): return "hooks"
        case (.signalHooks, .zh): return "hooks"
        case (.signalPending, .en): return "pending"
        case (.signalPending, .zh): return "pending"
        case (.attentionBridgeHint, .en): return "Optional: Droid / Kimi can append attention.tsv — see docs/attention-bridge.md (no extra installer)."
        case (.attentionBridgeHint, .zh): return "可选：Droid / Kimi 可写入 attention.tsv — 见 docs/attention-bridge.md（不扩安装器）。"
        case (.launchAtLogin, .en): return "Launch at login"
        case (.launchAtLogin, .zh): return "登录时启动"
        case (.language, .en): return "Language"
        case (.language, .zh): return "语言"
        case (.waitingSignals, .en): return "Waiting signals"
        case (.waitingSignals, .zh): return "等待信号"
        case (.hooksHint, .en): return "Install Claude/Codex hooks so Pulse can show permission, input waits, and subagent lifecycle."
        case (.hooksHint, .zh): return "安装 Claude/Codex hooks 后，Pulse 才能显示权限、输入等待与 subagent 生命周期。"
        case (.installHooks, .en): return "Install hooks"
        case (.installHooks, .zh): return "安装连接"
        case (.shortcuts, .en): return "Shortcuts"
        case (.shortcuts, .zh): return "快捷键"
        case (.hotkeyHint, .en): return "Tap a notification to focus the waiting agent."
        case (.hotkeyHint, .zh): return "点击通知即可聚焦等待中的 Agent。"
        case (.agents, .en): return "Agents"
        case (.agents, .zh): return "Agents"
        case (.waiting, .en): return "Waiting"
        case (.waiting, .zh): return "等待中"
        case (.running, .en): return "Running"
        case (.running, .zh): return "运行中"
        case (.idleNotify, .en): return "All coding agents idle"
        case (.idleNotify, .zh): return "所有编码 Agent 已空闲"
        case (.settingsTitle, .en): return "Pulse Settings"
        case (.settingsTitle, .zh): return "Pulse 偏好设置"
        case (.recent, .en): return "Recent"
        case (.recent, .zh): return "最近"
        case (.dismissWait, .en): return "Dismiss"
        case (.dismissWait, .zh): return "忽略等待"
        case (.hooksNudge, .en): return "Install hooks so Claude/Codex can signal Waiting"
        case (.hooksNudge, .zh): return "安装 hooks 后，Claude/Codex 才能点亮「需要你」"
        case (.waitingSignalNudge, .en): return "This agent has no Waiting signal yet — Running only"
        case (.waitingSignalNudge, .zh): return "该 Agent 暂无 Waiting 信号，目前仅显示运行中"
        case (.hooksUnknown, .en): return "Not checked"
        case (.hooksUnknown, .zh): return "未检查"
        case (.hooksMissing, .en): return "Not installed"
        case (.hooksMissing, .zh): return "未安装"
        case (.hooksInstalledBoth, .en): return "Installed · Claude + Codex"
        case (.hooksInstalledBoth, .zh): return "已安装 · Claude + Codex"
        case (.hooksInstalledClaude, .en): return "Installed · Claude"
        case (.hooksInstalledClaude, .zh): return "已安装 · Claude"
        case (.hooksInstalledCodex, .en): return "Installed · Codex"
        case (.hooksInstalledCodex, .zh): return "已安装 · Codex"
        case (.hooksFailed, .en): return "Failed"
        case (.hooksFailed, .zh): return "失败"
        case (.a11yHint, .en): return "If the shortcut does nothing, grant Accessibility to Pulse in System Settings."
        case (.a11yHint, .zh): return "若快捷键无响应，请在系统设置中为 Pulse 开启辅助功能权限。"
        case (.kindPermission, .en): return "Permission"
        case (.kindPermission, .zh): return "需要授权"
        case (.kindInput, .en): return "Input"
        case (.kindInput, .zh): return "等待输入"
        case (.kindWaiting, .en): return "Waiting"
        case (.kindWaiting, .zh): return "等待中"
        case (.idleWord, .en): return "idle"
        case (.idleWord, .zh): return "空闲"
        case (.processDetected, .en): return "Process detected"
        case (.processDetected, .zh): return "检测到进程"
        case (.processWord, .en): return "process"
        case (.processWord, .zh): return "进程"
        case (.about, .en): return "About"
        case (.about, .zh): return "关于"
        case (.tagline, .en): return "Status lamp for coding agents"
        case (.tagline, .zh): return "编码 Agent 状态灯"
        case (.build, .en): return "Build"
        case (.build, .zh): return "构建"
        case (.devBuild, .en): return "dev build"
        case (.devBuild, .zh): return "开发构建"
        case (.copyDiagnostics, .en): return "Copy diagnostics"
        case (.copyDiagnostics, .zh): return "复制诊断信息"
        case (.copied, .en): return "Copied"
        case (.copied, .zh): return "已复制"
        case (.versionStale, .en): return "stale bundle"
        case (.versionStale, .zh): return "版本不一致"
        case (.versionMismatchHint, .en):
            return "Binary reports %@ but the bundle says %@ — repackage with PulseBar/Scripts/package.sh."
        case (.versionMismatchHint, .zh):
            return "程序版本为 %@，但 app 包标记为 %@ — 请用 PulseBar/Scripts/package.sh 重新打包。"
        // Relative wait durations — English units leaked into the zh tray before 0.21.1.
        case (.durNow, .en): return "now"
        case (.durNow, .zh): return "刚刚"
        case (.durSec, .en): return "%ds"
        case (.durSec, .zh): return "%d 秒"
        case (.durMin, .en): return "%dm"
        case (.durMin, .zh): return "%d 分"
        case (.durHour, .en): return "%dh"
        case (.durHour, .zh): return "%d 小时"
        case (.notificationsSection, .en): return "Notifications"
        case (.notificationsSection, .zh): return "通知"
        case (.notifyDenied, .en): return "Notifications are turned off for Pulse — these switches cannot fire."
        case (.notifyDenied, .zh): return "系统已关闭 Pulse 的通知权限，下面的开关不会生效。"
        case (.openNotificationSettings, .en): return "Open System Settings"
        case (.openNotificationSettings, .zh): return "打开系统设置"
        case (.muteAgents, .en): return "Mute agents"
        case (.muteAgents, .zh): return "静音 Agent"
        case (.muteHint, .en): return "Muted agents still appear in the tray; they just stop sending notifications."
        case (.muteHint, .zh): return "被静音的 Agent 仍会出现在列表中，只是不再发送通知。"
        case (.uninstallHooks, .en): return "Remove hooks"
        case (.uninstallHooks, .zh): return "移除连接"
        case (.revealShortcut, .en): return "Reveal Pulse"
        case (.revealShortcut, .zh): return "唤出 Pulse"
        case (.hotkeyTaken, .en): return "Another app already owns this shortcut — pick a different one."
        case (.hotkeyTaken, .zh): return "该快捷键已被其他应用占用，请换一个。"
        case (.recentWaits, .en): return "Recent waits"
        case (.recentWaits, .zh): return "最近的等待"
        case (.clearHistory, .en): return "Clear history"
        case (.clearHistory, .zh): return "清空记录"
        case (.waitedFor, .en): return "waited %@"
        case (.waitedFor, .zh): return "等待 %@"
        case (.cappedSessions, .en): return "%d more session(s) not shown"
        case (.cappedSessions, .zh): return "另有 %d 个会话未显示"
        case (.emptyHint, .en):
            return "Pulse lights up when a coding agent is running or needs you. Install hooks so Claude/Codex can report Waiting."
        case (.emptyHint, .zh):
            return "有编码 Agent 在跑或在等你时，Pulse 才会亮。安装 hooks 后 Claude/Codex 才能上报「需要你」。"
        case (.checkForUpdates, .en): return "Check for updates"
        case (.checkForUpdates, .zh): return "检查更新"
        case (.checkNow, .en): return "Check now"
        case (.checkNow, .zh): return "立即检查"
        case (.openRelease, .en): return "Open release"
        case (.openRelease, .zh): return "打开发布页"
        case (.updateIdle, .en): return "Not checked"
        case (.updateIdle, .zh): return "未检查"
        case (.updateChecking, .en): return "Checking…"
        case (.updateChecking, .zh): return "检查中…"
        case (.updateCurrent, .en): return "Up to date"
        case (.updateCurrent, .zh): return "已是最新"
        case (.updateAvailable, .en): return "Update available: %@"
        case (.updateAvailable, .zh): return "有新版本：%@"
        case (.updateFailed, .en): return "Check failed"
        case (.updateFailed, .zh): return "检查失败"
        case (.probeEvery, .en): return "every %ds"
        case (.probeEvery, .zh): return "每 %d 秒"
        case (.probeParked, .en): return "paused (display off)"
        case (.probeParked, .zh): return "已暂停（屏幕关闭）"
        case (.probePaused, .en): return "live updates off"
        case (.probePaused, .zh): return "实时更新已关闭"
        }
    }

    /// `CaseIterable` so tests can assert every key resolves in both languages
    /// and that format specifiers match (a mismatched %d crashes String(format:)).
    enum Key: CaseIterable {
        case noAgents, noAgentsDetected, needsYou, waitingN, runningN, running1
        case recent1, recentN, recent, idleWord
        case justNow, notYet, cantRefresh, andMore, showLess
        case refresh, refreshing, clearWaiting, settings, quit
        case focusTerminal, focusTTY, focusWarp, openInTerminal, openFolder, dismissWait
        case general, liveUpdates, notifications, notifyWaiting, launchAtLogin, language
        case quietHours, quietHoursHint, quietStart, quietEnd
        case waitingSignals, hooksHint, installHooks, attentionBridgeHint, shortcuts, hotkeyHint, a11yHint
        case agents, waiting, running, idleNotify, settingsTitle
        case hooksNudge, waitingSignalNudge, hooksUnknown, hooksMissing, hooksInstalledBoth
        case hooksInstalledClaude, hooksInstalledCodex, hooksFailed
        case kindPermission, kindInput, kindWaiting
        case activityPrefix, signalHooks, signalPending
        case processDetected, processWord
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
    }
}
