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
        case .details: return "Details"
        case .quit: return "Quit Pulse"
        case .focusTerminal: return "Focus terminal"
        case .general: return "General"
        case .liveUpdates: return "Live updates"
        case .agentDataAccess: return "Read app data for richer details"
        case .agentDataAccessHint:
            return "Off by default. Enables deeper Cursor/VS Code/Warp scans and may ask macOS for cross-app data access."
        case .agentDataAccessScopes: return "Choose data sources"
        case .agentDataAccessScopeHint: return "Only selected agents receive deeper app-data reads. Pulse never asks on launch."
        case .agentDataAccessAgentDetail: return "%@ reads %@ for task, model, workspace, progress and Waiting details."
        case .agentDataAccessSkipHint: return "If skipped, Pulse still reads process and unprotected session evidence; no prompt is shown."
        case .notifications: return "Notify when idle"
        case .notifyWaiting: return "Notify on new Waiting"
        case .quietHours: return "Quiet hours (idle only)"
        case .quietHoursHint:
            return "Waiting notifications still fire. Equal start/end disables quiet hours. The window may wrap past midnight."
        case .quietStart: return "From"
        case .quietEnd: return "Until"
        case .focusTTY: return "Focus Terminal tab"
        case .focusWarp: return "Focus Warp (app)"
        case .focusHostWorkspace: return "Open workspace in %@"
        case .focusHostApp: return "Focus %@ (app)"
        case .focusOpenTray: return "Open Pulse tray"
        case .allowTerminalAutomation: return "Allow Terminal / iTerm tab focus"
        case .allowTerminalAutomationHint:
            return "Off by default. When on, Focus may ask macOS for Automation access to select the matching tab. Warp and IDE hosts never need this."
        case .supportFocusNone: return "Focus: observation only"
        case .supportFocusWarp: return "Focus: Warp (app)"
        case .supportFocusHostWorkspace: return "Focus: %@ workspace"
        case .supportFocusHost: return "Focus: %@ (app)"
        case .supportFocusTTY: return "Focus: Terminal tab"
        case .supportFocusTTYNeedsOptIn: return "Focus: Terminal tab (enable in Shortcuts)"
        case .attentionBridgeWriteSample: return "Write sample Waiting"
        case .attentionBridgeWriteSampleHint:
            return "Appends Attention bridge lines for all six Waiting-none Agents (Replit, Devin, Warp Agent, Trae, Antigravity, Junie). Does not expand the Claude/Codex hook installer."
        case .attentionBridgeClearSample: return "Clear sample Waiting"
        case .activityPrefix: return "Doing"
        case .signalHooks: return "hooks"
        case .signalPending: return "pending"
        case .attentionBridgeHint:
            return "Opaque agents (Replit, Devin, Warp Agent, Trae, Antigravity, Junie) have no native Waiting path — write attention.tsv via the Attention bridge (docs/attention-bridge.md). Hook installer stays Claude/Codex only."
        case .attentionBridgeFocusHint:
            return "Attention bridge — write attention.tsv for Waiting on agents without a native signal"
        case .revealAttentionFolder: return "Reveal Attention folder"
        case .launchAtLogin: return "Launch at login"
        case .language: return "Language"
        case .waitingSignals: return "Waiting signals"
        case .hooksHint:
            return "Install Claude/Codex hooks so Pulse can show permission, input waits, and subagent lifecycle."
        case .installHooks: return "Install hooks"
        case .testWaitingSignal: return "Test connection"
        case .hookTestIdle: return "Not tested"
        case .hookTestRunning: return "Testing…"
        case .hookTestPassed: return "Connection passed"
        case .hookTestFailed: return "Connection failed"
        case .shortcuts: return "Shortcuts"
        case .globalShortcut: return "Enable global shortcut"
        case .globalShortcutHint: return "Off by default. Enabling it registers a system-wide key and may require macOS Automation access on unsigned builds."
        case .hotkeyHint: return "Tap a notification to focus the waiting agent."
        case .agents: return "Agents"
        case .running: return "Running"
        case .idleNotify: return "All coding agents idle"
        case .settingsTitle: return "Pulse Settings"
        case .recent: return "Recent"
        case .dismissWait: return "Dismiss"
        case .hooksNudge: return "Install hooks so Claude/Codex can signal Waiting"
        case .waitingSignalNudge:
            return "Live agent has no Waiting path — open Waiting signals for the Attention bridge"
        case .hooksUnknown: return "Not checked"
        case .hooksMissing: return "Not installed"
        case .hooksInstalledBoth: return "Installed · Claude + Codex"
        case .hooksInstalledClaude: return "Installed · Claude"
        case .hooksInstalledCodex: return "Installed · Codex"
        case .hooksFailed: return "Failed"
        case .a11yHint: return "The shortcut opens Pulse directly and requires no Accessibility permission."
        case .kindPermission: return "Permission"
        case .kindInput: return "Input"
        case .kindWaiting: return "Waiting"
        case .idleWord: return "idle"
        case .processDetected: return "Process detected"
        case .processWord: return "process"
        case .processCount: return "%d processes"
        case .limitedData: return "Process only"
        case .sessionEvidence: return "Session"
        case .cacheEvidence: return "Local cache"
        case .terminalSession: return "Terminal session running"
        case .appSession: return "Agent app running"
        case .activityUnavailable: return "Activity feed unavailable"
        case .processAge: return "Process started %@ ago"
        case .activityChanged: return "Changed · %@"
        case .newErrors: return "%d new errors"
        case .newFiles: return "%d more files"
        case .progressAdvanced: return "Progress moved to %d/%d"
        case .modelCallChanged: return "New model call"
        case .signalProgress: return "Progress %d/%d"
        case .signalErrors: return "+%d errors"
        case .signalFiles: return "+%d files"
        case .signalModel: return "Model call"
        case .signalCompleted: return "Complete"
        case .signalFailed: return "Failed"
        case .signalCancelled: return "Cancelled"
        case .terminalDetectedNoDetails: return "Terminal session running · activity feed unavailable"
        case .appDetectedNoDetails: return "Agent app running · session feed unavailable"
        case .lastAction: return "Last action: %@"
        case .lastActive: return "Last active %@"
        case .latestCallTokens: return "Latest model call · %@ input · %@ output"
        case .reportedTokens: return "Agent reported · %@ input · %@ output"
        case .compactTokens: return "↑%@ ↓%@"
        case .subagentsActive: return "%d of %d subagents active"
        case .subagentsObserved: return "%d subagents observed"
        case .actionPlanning: return "Planning"
        case .actionCommand: return "Terminal command"
        case .actionEditing: return "Editing files"
        case .actionImage: return "Reviewing image"
        case .actionResearch: return "Research"
        case .actionReading: return "Reading files"
        case .actionAutomation: return "Automation"
        case .setupWaitingSignals: return "Set up Waiting signals…"
        case .about: return "About"
        case .tagline: return "Status lamp for coding agents"
        case .build: return "Build"
        case .runningFrom: return "Running from"
        case .devBuild: return "dev build"
        case .copyDiagnostics: return "Copy diagnostics"
        case .copied: return "Copied"
        case .versionStale: return "stale bundle"
        case .versionMismatchHint:
            return "Binary reports %@ but the bundle says %@ — repackage with PulseBar/Scripts/package.sh."
        case .duplicateAppsFound: return "%d other Pulse app(s) found"
        case .duplicateAppsMore: return "and %d more"
        case .duplicateAppRunning: return "Another copy is running; quit it before removal."
        case .removeDuplicateApps: return "Remove older copies…"
        case .removeDuplicateAppsConfirm:
            return "Move %d non-running Pulse app(s) to the Trash? The currently running app is kept."
        case .moveToTrash: return "Move to Trash"
        case .cancel: return "Cancel"
        case .durNow: return "now"
        case .durSec: return "%ds"
        case .durMin: return "%dm"
        case .durHour: return "%dh"
        case .notificationsSection: return "Notifications"
        case .notifyNotConfigured: return "Notifications are not enabled yet. Pulse will not ask until you choose Enable."
        case .waitingNotifyNotConfigured: return "Waiting alert is off — enable notifications"
        case .enableNotifications: return "Enable notifications"
        case .notifyDenied: return "Notifications are turned off for Pulse — these switches cannot fire."
        case .waitingNotifyDenied: return "Waiting alerts are blocked — open System Settings"
        case .notifyDeniedPersistentHint:
            return "Waiting alerts cannot fire until System Settings allows notifications for Pulse."
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
            return "Pulse reads local session and process evidence. Hooks are optional and only add a richer Waiting signal."
        case .checkForUpdates: return "Check for updates"
        case .checkNow: return "Check now"
        case .openRelease: return "Open release"
        case .downloadAndVerify: return "Download & verify"
        case .updateDownloading: return "Downloading installer…"
        case .updateVerifying: return "Verifying SHA-256…"
        case .updateVerified: return "Verified · installer opened"
        case .updateVerifiedOpenOnly: return "Verified · open the DMG to install (this build is not Gatekeeper-ready)"
        case .updateVerifyFailed: return "Installer verification failed"
        case .updateIdle: return "Not checked"
        case .updateChecking: return "Checking…"
        case .updateCurrent: return "Up to date"
        case .updateCurrentPrerelease:
            return "Up to date on the preview channel (unsigned)"
        case .updateCurrentStable:
            return "Up to date on stable (excludes prereleases; notarization may lag)"
        case .updateAvailable: return "Update available: %@"
        case .updateFailed: return "Check failed"
        case .probeEvery: return "every %ds"
        case .probeParked: return "paused (display off)"
        case .probePaused: return "live updates off"
        case .a11yIdle: return "Idle"
        case .a11yRunning: return "Running"
        case .a11yStalled: return "Stalled"
        case .a11yWaiting: return "Needs attention"
        case .a11yError: return "Cannot refresh"
        case .sectionNeedsYou: return "Needs you"
        case .sectionRunning: return "Running"
        case .sectionStalled: return "Stalled"
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
        case .noProject: return "Workspace unknown"
        case .stalled: return "Stalled"
        case .stalledFor: return "No activity for %@"
        case .supportHealth: return "Agent support health"
        case .supportHealthHint:
            return "Observed runtime evidence, not marketing coverage. Missing facts stay explicit."
        case .supportScanIncomplete:
            return "Scan incomplete · previous adapter results retained"
        case .supportScanIncompleteTimeout:
            return "Scan timed out on some adapters · partial results retained"
        case .supportNoneObserved: return "No Agent evidence observed in the latest scan."
        case .supportAllAgents: return "Other %d supported Agents"
        case .supportNotDetected: return "Not detected"
        case .supportStructured: return "Structured session"
        case .supportCache: return "Local cache"
        case .supportProcess: return "Process only"
        case .supportDetected: return "Detected"
        case .supportGoal: return "goal"
        case .supportWorkspace: return "workspace"
        case .supportActivity: return "activity"
        case .supportProgress: return "execution signal"
        case .supportAction: return "last action"
        case .supportModel: return "model"
        case .supportEvidence: return "evidence"
        case .session: return "session"
        case .detailTool: return "tool"
        case .detailSkill: return "skill"
        case .detailPhase: return "phase"
        case .detailOutcome: return "outcome"
        case .detailEvidence: return "evidence"
        case .detailFiles: return "files"
        case .detailErrors: return "errors"
        case .detailContext: return "context"
        case .supportResources: return "resources"
        case .supportObservedSignals: return "Observed: %@"
        case .supportNoObservedSignals: return "No usable session signals yet"
        case .skillFact: return "Workflow %@"
        case .supportLastRead: return "read %@ ago"
        case .supportMissing: return "missing: %@"
        case .supportMissingFeed: return "activity feed"
        case .supportMissingGoal: return "goal"
        case .supportMissingWorkspace: return "workspace"
        case .supportMissingWaiting: return "Waiting hook not ready"
        case .supportWaitingHooks: return "Waiting route: hooks"
        case .supportWaitingHarvest: return "Waiting route: session data"
        case .supportWaitingNone: return "Waiting unavailable"
        case .supportWaitingNoneDetail:
            return "No native Waiting path — use the Attention bridge"
        case .supportDepthSession: return "Depth: session transcript"
        case .supportDepthCache: return "Depth: cache / index (Limited)"
        case .supportDepthWaitingNone: return "Waiting unavailable — Attention bridge"
        case .supportSharedCursor: return "Cursor Agent shares this adapter"
        case .supportLastSignal: return "signal %@ ago"
        case .supportDetectedExecutable: return "detected by executable"
        case .supportDetectedPath: return "detected by path signature"
        case .supportFactCoverage: return "%d/%d useful signals"
        case .supportCollectorObserved: return "adapter read %d row(s) in %d ms"
        case .supportCollectorNoData: return "No recent data"
        case .supportCollectorNoDataDetail: return "adapter healthy · %d ms"
        case .supportCollectorSourceAbsent: return "Source not found"
        case .supportCollectorSourceAbsentDetail: return "no local session source or CLI found"
        case .supportCollectorPrivacyLimited: return "Privacy-limited"
        case .supportCollectorPrivacyLimitedDetail:
            return "deep app-data scan is off; enable it in Settings for richer details"
        case .supportCollectorPrivacyLimitedScoped:
            return "%d agent data source(s) enabled · %d still privacy-limited"
        case .supportCollectorNoSessions: return "No usable session"
        case .supportCollectorNoSessionsDetail: return "source present · no usable session · %d ms"
        case .supportCollectorPermission: return "Permission denied"
        case .supportCollectorPermissionDetail: return "local source could not be read"
        case .supportCollectorSchema: return "Data format changed"
        case .supportCollectorSchemaDetail: return "local source exists but its format was not recognized"
        case .supportCollectorFailed: return "Adapter error"
        case .supportCollectorFailedDetail: return "adapter error: %@"
        case .supportCollectorUnscanned: return "Not scanned"
        case .supportCollectorUnscannedDetail: return "adapter did not finish in the latest scan"
        case .supportObservedCount: return "Observed · %d"
        case .supportIssueCount: return "%d issue(s)"
        case .supportAdapterIssueCount: return "%d adapter issue(s)"
        case .supportInformationGapCount: return "%d information gap(s)"
        case .supportFilterIssuesCount: return "Issues · %d"
        case .supportSearch: return "Search Agents"
        case .supportFilterIssues: return "Issues"
        case .supportFilterRunning: return "Running"
        case .supportFilterInstalled: return "Installed"
        case .supportFilterNoData: return "No data"
        case .supportFilterAll: return "All"
        case .supportNoFilterResults: return "No Agents match this filter"
        case .supportNeedsAction: return "Needs action"
        case .supportLimited: return "Limited"
        case .supportHealthy: return "Healthy"
        case .supportUnavailable: return "Not observed"
        case .supportAvailable: return "Available"
        case .supportNotInstalled: return "Not installed"
        case .supportNoRecentSession: return "No recent session"
        case .supportPermissionDenied: return "Permission denied"
        case .supportUnscanned: return "Unscanned"
        case .supportNeedsActionCount: return "Action · %d"
        case .supportLimitedCount: return "Limited · %d"
        case .supportHealthyCount: return "Healthy · %d"
        case .supportUnavailableCount: return "Not observed · %d"
        case .supportAvailableCount: return "Available · %d"
        case .supportNotInstalledCount: return "Not installed · %d"
        case .supportNoRecentCount: return "No recent · %d"
        case .supportPermissionDeniedCount: return "Permission · %d"
        case .supportUnscannedCount: return "Unscanned · %d"
        case .supportUsefulCoverage: return "%d/%d useful signals"
        case .supportRetry: return "Retry scan"
        case .supportRunAgent: return "Run this agent once"
        case .supportEnableData: return "Choose its data source"
        case .supportAdapterDiagnostics: return "Adapter diagnostics"
        case .supportSafeReport: return "Preview safe report"
        case .supportCopySafeReport: return "Copy safe report"
        case .exportSafeReport: return "Export safe report…"
        case .snooze: return "Later"
        case .snoozed: return "snoozed"
        case .snoozedFor: return "Later · %@ left"
        case .stallAfter: return "Call it stalled after"
        case .stallOff: return "Never"
        case .minutesShort: return "%d min"
        case .notifFocus: return "Focus"
        case .waitingSummaryTitle: return "%d agents need your attention"
        case .waitingSummaryBody: return "Open Pulse to review all waiting sessions."
        case .searchSessions: return "Search sessions, projects, agents"
        case .searchNoResults: return "No sessions match this search"
        case .clearSearch: return "Clear search"
        case .installUpdate: return "Install verified update"
        case .updateInstalling: return "Installing update…"
        case .updateInstallFailed: return "Update install failed"
        case .updateInstallRequiresNotarized:
            return "In-place install needs a notarized stable build — open the DMG instead"
        case .updatePreview: return "Preview build · ad-hoc signed · not notarized"
        case .updateSignedUnnotarized: return "Developer ID signed · not notarized · Gatekeeper may block"
        case .recoveredAfterCrash:
            return "Pulse recovered after an unclean exit (force quit cannot be told apart from a crash)"
        case .recoveredAfterForceQuit: return "Pulse recovered after a force quit"
        case .recoveredAfterSystemRestart: return "Pulse restarted after a system reboot"
        case .qualityReasonProcessOnly: return "Only process evidence is available"
        case .qualityReasonCache: return "Vendor cache did not emit this field"
        case .qualityReasonNotEmitted: return "Not present in the local session record"
        case .qualityReasonWaitingNoDetail: return "Waiting without a detailed reason"
        case .qualityReasonScanTimeout: return "Adapter timed out while reading local data"
        case .qualityNextOpenAgent: return "Open the agent to see full session detail"
        case .qualityNextWaitCache: return "Keep using the agent so its local cache fills in"
        case .qualityNextAttentionBridge: return "Set up the Attention bridge for Waiting"
        case .qualityNextRetryScan: return "Retry the scan from Support Health"
        case .supportFailureTimelineEntry: return "Last failure · %@ · %@ ago"
        case .qualityConfidenceHigh: return "High confidence"
        case .qualityConfidenceMedium: return "Medium confidence"
        case .qualityConfidenceLow: return "Low confidence"
        case .trayScanIncomplete: return "Scan incomplete · open Support Health"
        case .allSessionsCount: return "All %d sessions"
        case .filterPhase: return "Phase"
        case .filterOutcome: return "Result"
        case .filterClear: return "Clear filters"
        case .waitingTimeline: return "Waiting timeline"
        case .waitingQueuedAt: return "Queued"
        case .waitingNotifiedAt: return "Notified"
        case .waitingAcknowledgedAt: return "Acknowledged"
        case .waitingSnoozedUntil: return "Snoozed until"
        case .waitingResolvedAt: return "Resolved"
        case .waitingNotifyPending: return "Notification pending"
        case .installCopyBuildArtifact: return "Development build"
        case .installCopyRollback: return "Rollback copy"
        case .recordsSuffix: return " events"
        case .sessionAge: return "Started %@ ago"
        case .phaseResponding: return "Responding"
        case .phaseTurnComplete: return "Turn complete"
        case .phaseWaitingPermission: return "Waiting for permission"
        case .phasePlanning: return "Planning"
        case .phaseWorking: return "Working"
        case .phaseTesting: return "Testing"
        case .phaseBuilding: return "Building"
        case .phasePublishing: return "Publishing"
        case .nowActivity: return "Now · %@"
        case .outcomeActivity: return "Outcome · %@"
        case .modelFact: return "Model %@"
        case .errorFactOne: return "1 failure"
        case .errorsFact: return "%d failures"
        case .outcomeFailed: return "Failed"
        case .outcomeCancelled: return "Cancelled"
        case .filesFact: return "%d files touched"
        case .contextFact: return "Context %d%%"
        case .progressFact: return "%d/%d complete"
        case .turnsFact: return "%d turns"
        }
    }

    /// 简体中文文案。
    private static func zh(_ key: Key) -> String {
        switch key {
        case .noAgents: return "当前没有编码 Agent"
        case .noAgentsDetected: return "未检测到编码 Agent"
        case .needsYou: return "需要你处理"
        case .waitingN: return "待处理"
        case .runningN: return "运行"
        case .running1: return "1 个运行中"
        case .recent1: return "1 个最近会话"
        case .recentN: return "最近"
        case .justNow: return "刚刚"
        case .notYet: return "尚未更新"
        case .cantRefresh: return "无法刷新"
        case .andMore: return "另有 %d 个…"
        case .showLess: return "收起"
        case .refresh: return "刷新"
        case .refreshing: return "刷新中…"
        case .clearWaiting: return "清除等待"
        case .settings: return "偏好设置…"
        case .details: return "详情"
        case .quit: return "退出 Pulse"
        case .focusTerminal: return "聚焦终端"
        case .general: return "通用"
        case .liveUpdates: return "实时更新"
        case .agentDataAccess: return "读取应用数据以展示更多详情"
        case .agentDataAccessHint: return "默认关闭。开启后会深入扫描 Cursor / VS Code / Warp，macOS 可能会请求访问其他应用的数据。"
        case .agentDataAccessScopes: return "选择数据来源"
        case .agentDataAccessScopeHint: return "只有选中的 Agent 会读取更深层的应用数据。Pulse 不会在启动时索要权限。"
        case .agentDataAccessAgentDetail: return "%@ 会读取 %@，用于展示任务、模型、工作区、进度和 Waiting 详情。"
        case .agentDataAccessSkipHint: return "跳过后仍会读取进程和未受保护的会话证据；不会弹出权限请求。"
        case .notifications: return "全部空闲时通知"
        case .notifyWaiting: return "新的「需要你」时通知"
        case .quietHours: return "安静时段（仅抑制空闲通知）"
        case .quietHoursHint: return "Waiting 通知仍会发送。起止相同时安静时段不生效。时段可跨午夜。"
        case .quietStart: return "开始"
        case .quietEnd: return "结束"
        case .focusTTY: return "聚焦终端标签"
        case .focusWarp: return "聚焦 Warp（应用）"
        case .focusHostWorkspace: return "在 %@ 打开工作区"
        case .focusHostApp: return "聚焦 %@（应用）"
        case .focusOpenTray: return "打开 Pulse 托盘"
        case .allowTerminalAutomation: return "允许聚焦 Terminal / iTerm 标签"
        case .allowTerminalAutomationHint:
            return "默认关闭。开启后，聚焦时 macOS 可能请求自动化权限以选中对应标签。Warp 与 IDE 宿主不需要此项。"
        case .supportFocusNone: return "聚焦：仅观测"
        case .supportFocusWarp: return "聚焦：Warp（应用）"
        case .supportFocusHostWorkspace: return "聚焦：%@ 工作区"
        case .supportFocusHost: return "聚焦：%@（应用）"
        case .supportFocusTTY: return "聚焦：终端标签"
        case .supportFocusTTYNeedsOptIn: return "聚焦：终端标签（在快捷键中开启）"
        case .attentionBridgeWriteSample: return "写入样本 Waiting"
        case .attentionBridgeWriteSampleHint:
            return "为全部六个无 Waiting 路径的 Agent（Replit、Devin、Warp Agent、Trae、Antigravity、Junie）追加 Attention 桥样本。不会把 hook 安装器扩到 Claude/Codex 以外。"
        case .attentionBridgeClearSample: return "清除样本 Waiting"
        case .activityPrefix: return "刚才"
        case .signalHooks: return "hooks"
        case .signalPending: return "pending"
        case .attentionBridgeHint:
            return "无原生 Waiting 路径的 Agent（Replit、Devin、Warp Agent、Trae、Antigravity、Junie）请写入 attention.tsv（见 docs/attention-bridge.md）。hooks 安装器仍只覆盖 Claude / Codex。"
        case .attentionBridgeFocusHint:
            return "Attention 桥 — 为无原生 Waiting 信号的 Agent 写入 attention.tsv"
        case .revealAttentionFolder: return "打开 Attention 文件夹"
        case .launchAtLogin: return "登录时启动"
        case .language: return "语言"
        case .waitingSignals: return "等待信号"
        case .hooksHint: return "安装 Claude/Codex hooks 后，Pulse 才能显示权限、输入等待与 subagent 生命周期。"
        case .installHooks: return "安装连接"
        case .testWaitingSignal: return "测试连接"
        case .hookTestIdle: return "尚未测试"
        case .hookTestRunning: return "测试中…"
        case .hookTestPassed: return "连接测试通过"
        case .hookTestFailed: return "连接测试失败"
        case .shortcuts: return "快捷键"
        case .globalShortcut: return "启用全局快捷键"
        case .globalShortcutHint: return "默认关闭。启用后会注册系统级快捷键，未签名版本可能触发 macOS 自动化权限请求。"
        case .hotkeyHint: return "点击通知即可聚焦等待中的 Agent。"
        case .agents: return "Agents"
        case .running: return "运行中"
        case .idleNotify: return "所有编码 Agent 已空闲"
        case .settingsTitle: return "Pulse 偏好设置"
        case .recent: return "最近"
        case .dismissWait: return "忽略等待"
        case .hooksNudge: return "安装 hooks 后，Claude/Codex 才能点亮「需要你」"
        case .waitingSignalNudge:
            return "有 Agent 在跑但无 Waiting 路径 — 打开「等待信号」查看 Attention 桥"
        case .hooksUnknown: return "未检查"
        case .hooksMissing: return "未安装"
        case .hooksInstalledBoth: return "已安装 · Claude + Codex"
        case .hooksInstalledClaude: return "已安装 · Claude"
        case .hooksInstalledCodex: return "已安装 · Codex"
        case .hooksFailed: return "失败"
        case .a11yHint: return "快捷键会直接打开 Pulse，无需辅助功能权限。"
        case .kindPermission: return "需要授权"
        case .kindInput: return "等待输入"
        case .kindWaiting: return "等待中"
        case .idleWord: return "空闲"
        case .processDetected: return "检测到进程"
        case .processWord: return "进程"
        case .processCount: return "%d 个进程"
        case .limitedData: return "仅进程"
        case .sessionEvidence: return "结构化会话"
        case .cacheEvidence: return "本地缓存"
        case .terminalSession: return "终端会话正在运行"
        case .appSession: return "Agent 应用正在运行"
        case .activityUnavailable: return "暂无活动数据"
        case .processAge: return "进程始于%@前"
        case .activityChanged: return "刚刚变化 · %@"
        case .newErrors: return "新增 %d 个错误"
        case .newFiles: return "新增 %d 个文件"
        case .progressAdvanced: return "进度推进至 %d/%d"
        case .modelCallChanged: return "新的模型调用"
        case .signalProgress: return "进度 %d/%d"
        case .signalErrors: return "+%d 个错误"
        case .signalFiles: return "+%d 个文件"
        case .signalModel: return "模型调用"
        case .signalCompleted: return "已完成"
        case .signalFailed: return "失败"
        case .signalCancelled: return "已取消"
        case .terminalDetectedNoDetails: return "终端会话正在运行 · 暂无活动数据"
        case .appDetectedNoDetails: return "Agent 应用正在运行 · 暂无会话数据"
        case .lastAction: return "最近动作：%@"
        case .lastActive: return "最近活动：%@"
        case .latestCallTokens: return "最近一次模型调用 · 输入 %@ · 输出 %@"
        case .reportedTokens: return "Agent 上报 · 输入 %@ · 输出 %@"
        case .compactTokens: return "↑%@ ↓%@"
        case .subagentsActive: return "%d / %d 个 subagent 活跃"
        case .subagentsObserved: return "已观测 %d 个 subagent"
        case .actionPlanning: return "规划"
        case .actionCommand: return "执行命令"
        case .actionEditing: return "编辑文件"
        case .actionImage: return "查看图片"
        case .actionResearch: return "检索资料"
        case .actionReading: return "读取文件"
        case .actionAutomation: return "自动化操作"
        case .setupWaitingSignals: return "设置 Waiting 信号…"
        case .about: return "关于"
        case .tagline: return "编码 Agent 状态灯"
        case .build: return "构建"
        case .runningFrom: return "运行位置"
        case .devBuild: return "开发构建"
        case .copyDiagnostics: return "复制诊断信息"
        case .copied: return "已复制"
        case .versionStale: return "版本不一致"
        case .versionMismatchHint: return "程序版本为 %@，但 app 包标记为 %@ — 请用 PulseBar/Scripts/package.sh 重新打包。"
        case .duplicateAppsFound: return "发现另外 %d 个 Pulse 应用"
        case .duplicateAppsMore: return "另有 %d 个"
        case .duplicateAppRunning: return "另一个副本正在运行，退出后才能移除。"
        case .removeDuplicateApps: return "移除旧副本…"
        case .removeDuplicateAppsConfirm: return "将 %d 个未运行的 Pulse 应用移到废纸篓？当前正在运行的应用会保留。"
        case .moveToTrash: return "移到废纸篓"
        case .cancel: return "取消"
        case .durNow: return "刚刚"
        case .durSec: return "%d 秒"
        case .durMin: return "%d 分"
        case .durHour: return "%d 小时"
        case .notificationsSection: return "通知"
        case .notifyNotConfigured: return "通知尚未启用。点击“启用通知”后 Pulse 才会请求权限。"
        case .waitingNotifyNotConfigured: return "需要你处理 · 通知未启用"
        case .enableNotifications: return "启用通知"
        case .notifyDenied: return "系统已关闭 Pulse 的通知权限，下面的开关不会生效。"
        case .waitingNotifyDenied: return "需要你处理 · 通知已被系统关闭"
        case .notifyDeniedPersistentHint:
            return "在系统设置允许 Pulse 通知之前，Waiting 提醒无法送达。"
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
        case .emptyHint: return "Pulse 会读取本地会话和进程证据。hooks 不是必需项，只会额外增强 Waiting 信号。"
        case .checkForUpdates: return "检查更新"
        case .checkNow: return "立即检查"
        case .openRelease: return "打开发布页"
        case .downloadAndVerify: return "下载并校验"
        case .updateDownloading: return "正在下载安装包…"
        case .updateVerifying: return "正在校验 SHA-256…"
        case .updateVerified: return "校验通过 · 已打开安装包"
        case .updateVerifiedOpenOnly: return "校验通过 · 请打开 DMG 安装（当前构建未通过 Gatekeeper）"
        case .updateVerifyFailed: return "安装包校验失败"
        case .updateIdle: return "未检查"
        case .updateChecking: return "检查中…"
        case .updateCurrent: return "已是最新"
        case .updateCurrentPrerelease: return "已是最新（preview 通道 · 未签名公证）"
        case .updateCurrentStable:
            return "已是最新（stable 不含 prerelease；公证前能力可能仍在预发布）"
        case .updateAvailable: return "有新版本：%@"
        case .updateFailed: return "检查失败"
        case .probeEvery: return "每 %d 秒"
        case .probeParked: return "已暂停（屏幕关闭）"
        case .probePaused: return "实时更新已关闭"
        case .a11yIdle: return "空闲"
        case .a11yRunning: return "运行中"
        case .a11yStalled: return "已停滞"
        case .a11yWaiting: return "需要你处理"
        case .a11yError: return "无法刷新"
        case .sectionNeedsYou: return "需要你"
        case .sectionRunning: return "运行中"
        case .sectionStalled: return "停滞"
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
        case .noProject: return "工作区未知"
        case .stalled: return "停滞"
        case .stalledFor: return "已 %@ 无活动"
        case .supportHealth: return "Agent 支持健康度"
        case .supportHealthHint: return "展示本机实际观测证据，而非静态支持名单；缺失信息会明确标出。"
        case .supportScanIncomplete: return "扫描未完成 · 已保留上一次适配器结果"
        case .supportScanIncompleteTimeout: return "部分适配器超时 · 已保留部分结果"
        case .supportNoneObserved: return "最近一次扫描未观测到 Agent 证据。"
        case .supportAllAgents: return "其他 %d 个已支持 Agent"
        case .supportNotDetected: return "未检测到"
        case .supportStructured: return "结构化会话"
        case .supportCache: return "本地缓存"
        case .supportProcess: return "仅进程"
        case .supportDetected: return "已检测"
        case .supportGoal: return "目标"
        case .supportWorkspace: return "工作区"
        case .supportActivity: return "活动"
        case .supportProgress: return "执行信号"
        case .supportAction: return "最近动作"
        case .supportModel: return "模型"
        case .supportEvidence: return "证据"
        case .session: return "会话"
        case .detailTool: return "工具"
        case .detailSkill: return "技能"
        case .detailPhase: return "阶段"
        case .detailOutcome: return "结果"
        case .detailEvidence: return "证据"
        case .detailFiles: return "文件"
        case .detailErrors: return "错误"
        case .detailContext: return "上下文"
        case .supportResources: return "资源"
        case .supportObservedSignals: return "已观测：%@"
        case .supportNoObservedSignals: return "尚未观测到可用会话信号"
        case .skillFact: return "工作流 %@"
        case .supportLastRead: return "%@前读取"
        case .supportMissing: return "缺少：%@"
        case .supportMissingFeed: return "活动数据"
        case .supportMissingGoal: return "目标"
        case .supportMissingWorkspace: return "工作区"
        case .supportMissingWaiting: return "等待 hook 尚未就绪"
        case .supportWaitingHooks: return "等待通路：hooks"
        case .supportWaitingHarvest: return "等待通路：会话数据"
        case .supportWaitingNone: return "等待：不可用"
        case .supportWaitingNoneDetail: return "无原生 Waiting 路径 — 请用 Attention 桥"
        case .supportDepthSession: return "深度：会话笔录"
        case .supportDepthCache: return "深度：缓存 / 索引（有限）"
        case .supportDepthWaitingNone: return "Waiting 不可用 — Attention 桥"
        case .supportSharedCursor: return "Cursor Agent 与此适配器共用"
        case .supportLastSignal: return "%@前收到信号"
        case .supportDetectedExecutable: return "通过可执行程序检测"
        case .supportDetectedPath: return "通过路径特征检测"
        case .supportFactCoverage: return "有效信号 %d/%d"
        case .supportCollectorObserved: return "适配器读取 %d 行 · %d 毫秒"
        case .supportCollectorNoData: return "暂无近期数据"
        case .supportCollectorNoDataDetail: return "适配器正常 · %d 毫秒"
        case .supportCollectorSourceAbsent: return "未发现数据源"
        case .supportCollectorSourceAbsentDetail: return "未发现本地会话数据或 CLI"
        case .supportCollectorPrivacyLimited: return "隐私受限"
        case .supportCollectorPrivacyLimitedDetail:
            return "深度应用数据扫描已关闭；可在设置中开启以获取更多详情"
        case .supportCollectorPrivacyLimitedScoped:
            return "已开启 %d 个数据源 · 仍有 %d 个隐私受限"
        case .supportCollectorNoSessions: return "暂无可用会话"
        case .supportCollectorNoSessionsDetail: return "数据源存在 · 暂无可用会话 · %d 毫秒"
        case .supportCollectorPermission: return "无读取权限"
        case .supportCollectorPermissionDetail: return "无法读取本地数据源"
        case .supportCollectorSchema: return "数据格式已变化"
        case .supportCollectorSchemaDetail: return "本地数据存在，但当前适配器无法识别其格式"
        case .supportCollectorFailed: return "适配器异常"
        case .supportCollectorFailedDetail: return "适配器异常：%@"
        case .supportCollectorUnscanned: return "未完成扫描"
        case .supportCollectorUnscannedDetail: return "最近一次扫描中适配器未执行完成"
        case .supportObservedCount: return "已观测 · %d"
        case .supportIssueCount: return "%d 个问题"
        case .supportAdapterIssueCount: return "%d 个适配器异常"
        case .supportInformationGapCount: return "%d 个信息缺口"
        case .supportFilterIssuesCount: return "问题 · %d"
        case .supportSearch: return "搜索 Agent"
        case .supportFilterIssues: return "问题"
        case .supportFilterRunning: return "运行中"
        case .supportFilterInstalled: return "已安装"
        case .supportFilterNoData: return "无数据"
        case .supportFilterAll: return "全部"
        case .supportNoFilterResults: return "当前筛选条件下没有 Agent"
        case .supportNeedsAction: return "需要处理"
        case .supportLimited: return "信息受限"
        case .supportHealthy: return "观测健康"
        case .supportUnavailable: return "尚未观测"
        case .supportAvailable: return "可用"
        case .supportNotInstalled: return "未安装"
        case .supportNoRecentSession: return "无近期会话"
        case .supportPermissionDenied: return "权限不足"
        case .supportUnscanned: return "未扫描"
        case .supportNeedsActionCount: return "待处理 · %d"
        case .supportLimitedCount: return "受限 · %d"
        case .supportHealthyCount: return "健康 · %d"
        case .supportUnavailableCount: return "尚未观测 · %d"
        case .supportAvailableCount: return "可用 · %d"
        case .supportNotInstalledCount: return "未安装 · %d"
        case .supportNoRecentCount: return "无近期 · %d"
        case .supportPermissionDeniedCount: return "权限 · %d"
        case .supportUnscannedCount: return "未扫描 · %d"
        case .supportUsefulCoverage: return "有效信号 %d/%d"
        case .supportRetry: return "重新扫描"
        case .supportRunAgent: return "先运行一次这个 Agent"
        case .supportEnableData: return "选择它的数据来源"
        case .supportAdapterDiagnostics: return "适配器诊断"
        case .supportSafeReport: return "预览安全报告"
        case .supportCopySafeReport: return "复制安全报告"
        case .exportSafeReport: return "导出安全报告…"
        case .snooze: return "稍后"
        case .snoozed: return "已稍后"
        case .snoozedFor: return "已稍后 · 剩 %@"
        case .stallAfter: return "多久算停滞"
        case .stallOff: return "不判定"
        case .minutesShort: return "%d 分钟"
        case .notifFocus: return "去看看"
        case .waitingSummaryTitle: return "%d 个 Agent 需要你处理"
        case .waitingSummaryBody: return "打开 Pulse 查看全部等待中的会话。"
        case .searchSessions: return "搜索会话、项目或 Agent"
        case .searchNoResults: return "没有匹配的会话"
        case .clearSearch: return "清除搜索"
        case .installUpdate: return "安装已校验更新"
        case .updateInstalling: return "正在安装更新…"
        case .updateInstallFailed: return "更新安装失败"
        case .updateInstallRequiresNotarized:
            return "就地安装需要已公证的 stable 构建 — 请打开 DMG 安装"
        case .updatePreview: return "预览版 · ad-hoc 签名 · 未公证"
        case .updateSignedUnnotarized: return "已用 Developer ID 签名 · 未公证 · Gatekeeper 可能拦截"
        case .recoveredAfterCrash:
            return "Pulse 已从上次异常退出中恢复（强制退出与崩溃无法区分）"
        case .recoveredAfterForceQuit: return "Pulse 已从强制退出中恢复"
        case .recoveredAfterSystemRestart: return "系统重启后 Pulse 已重新启动"
        case .qualityReasonProcessOnly: return "目前只有进程证据"
        case .qualityReasonCache: return "厂商缓存未写出该字段"
        case .qualityReasonNotEmitted: return "本地会话记录中没有该字段"
        case .qualityReasonWaitingNoDetail: return "正在等待，但没有详细原因"
        case .qualityReasonScanTimeout: return "读取本地数据时适配器超时"
        case .qualityNextOpenAgent: return "打开该 Agent 查看完整会话"
        case .qualityNextWaitCache: return "继续使用该 Agent，等待本地缓存补齐"
        case .qualityNextAttentionBridge: return "设置 Attention 桥以获得 Waiting"
        case .qualityNextRetryScan: return "在支持健康度中重试扫描"
        case .supportFailureTimelineEntry: return "最近失败 · %@ · %@前"
        case .qualityConfidenceHigh: return "高可信"
        case .qualityConfidenceMedium: return "中等可信"
        case .qualityConfidenceLow: return "低可信"
        case .trayScanIncomplete: return "扫描未完成 · 打开支持健康度"
        case .allSessionsCount: return "全部 %d 个会话"
        case .filterPhase: return "阶段"
        case .filterOutcome: return "结果"
        case .filterClear: return "清除筛选"
        case .waitingTimeline: return "等待时间线"
        case .waitingQueuedAt: return "已排队"
        case .waitingNotifiedAt: return "已通知"
        case .waitingAcknowledgedAt: return "已确认"
        case .waitingSnoozedUntil: return "已稍后至"
        case .waitingResolvedAt: return "已解决"
        case .waitingNotifyPending: return "通知待发送"
        case .installCopyBuildArtifact: return "开发构建"
        case .installCopyRollback: return "回滚副本"
        case .recordsSuffix: return " 条事件"
        case .sessionAge: return "始于%@前"
        case .phaseResponding: return "正在响应"
        case .phaseTurnComplete: return "本轮已完成"
        case .phaseWaitingPermission: return "等待权限"
        case .phasePlanning: return "正在规划"
        case .phaseWorking: return "正在执行"
        case .phaseTesting: return "正在测试"
        case .phaseBuilding: return "正在构建"
        case .phasePublishing: return "正在发布"
        case .nowActivity: return "当前 · %@"
        case .outcomeActivity: return "结果 · %@"
        case .modelFact: return "模型 %@"
        case .errorFactOne: return "1 项失败"
        case .errorsFact: return "%d 项失败"
        case .outcomeFailed: return "执行失败"
        case .outcomeCancelled: return "已取消"
        case .filesFact: return "涉及 %d 个文件"
        case .contextFact: return "上下文 %d%%"
        case .progressFact: return "完成 %d/%d"
        case .turnsFact: return "%d 轮"
        }
    }

    /// `CaseIterable` so tests can assert every key resolves in both languages
    /// and that format specifiers match (a mismatched %d crashes String(format:)).
    enum Key: CaseIterable {
        case noAgents, noAgentsDetected, needsYou, waitingN, runningN, running1
        case recent1, recentN, recent, idleWord
        case justNow, notYet, cantRefresh, andMore, showLess
        case refresh, refreshing, clearWaiting, settings, quit
        case focusTerminal, focusTTY, focusWarp, focusHostWorkspace, focusHostApp, focusOpenTray, dismissWait, details
        case allowTerminalAutomation, allowTerminalAutomationHint
        case supportFocusNone, supportFocusWarp, supportFocusHostWorkspace, supportFocusHost, supportFocusTTY, supportFocusTTYNeedsOptIn
        case supportDepthSession, supportDepthCache, supportDepthWaitingNone
        case attentionBridgeWriteSample, attentionBridgeWriteSampleHint, attentionBridgeClearSample
        case general, liveUpdates, agentDataAccess, agentDataAccessHint, agentDataAccessScopes, agentDataAccessScopeHint, agentDataAccessAgentDetail, agentDataAccessSkipHint, notifications, notifyWaiting, launchAtLogin, language
        case quietHours, quietHoursHint, quietStart, quietEnd
        case waitingSignals, hooksHint, installHooks, testWaitingSignal
        case hookTestIdle, hookTestRunning, hookTestPassed, hookTestFailed
        case attentionBridgeHint, attentionBridgeFocusHint, revealAttentionFolder
        case shortcuts, hotkeyHint, globalShortcut, globalShortcutHint, a11yHint
        case agents, running, idleNotify, settingsTitle
        case hooksNudge, waitingSignalNudge, hooksUnknown, hooksMissing, hooksInstalledBoth
        case hooksInstalledClaude, hooksInstalledCodex, hooksFailed
        case kindPermission, kindInput, kindWaiting
        case activityPrefix, signalHooks, signalPending
        case processDetected, processWord, processCount
        case limitedData, sessionEvidence, cacheEvidence, terminalSession, appSession, activityUnavailable, processAge
        case activityChanged, newErrors, newFiles, progressAdvanced, modelCallChanged
        case signalProgress, signalErrors, signalFiles, signalModel, signalCompleted, signalFailed, signalCancelled
        case terminalDetectedNoDetails, appDetectedNoDetails
        case lastAction, lastActive, latestCallTokens, reportedTokens, compactTokens
        case subagentsActive, subagentsObserved
        case actionPlanning, actionCommand, actionEditing, actionImage
        case actionResearch, actionReading, actionAutomation, setupWaitingSignals
        case about, tagline, build, runningFrom, devBuild, copyDiagnostics, copied
        case versionStale, versionMismatchHint, duplicateAppsFound, duplicateAppsMore, duplicateAppRunning
        case removeDuplicateApps, removeDuplicateAppsConfirm, moveToTrash, cancel
        case durNow, durSec, durMin, durHour
        case notificationsSection, notifyNotConfigured, waitingNotifyNotConfigured
        case enableNotifications, notifyDenied, notifyDeniedPersistentHint, waitingNotifyDenied, openNotificationSettings
        case muteAgents, muteHint, uninstallHooks
        case revealShortcut, hotkeyTaken
        case recentWaits, clearHistory, waitedFor, cappedSessions, emptyHint
        case checkForUpdates, checkNow, openRelease, downloadAndVerify
        case updateDownloading, updateVerifying, updateVerified, updateVerifiedOpenOnly, updateVerifyFailed
        case updateIdle, updateChecking, updateCurrent, updateCurrentPrerelease, updateCurrentStable
        case updateAvailable, updateFailed
        case probeEvery, probeParked, probePaused
        case a11yIdle, a11yRunning, a11yStalled, a11yWaiting, a11yError
        case sectionNeedsYou, sectionRunning, sectionStalled, sectionRecent
        case groupByAgent, groupByProject, groupingLabel
        case jumpToOldest, interruptionsToday, playSound
        case waitedLongest, moreActions
        case acrossProjects, agoFormat, whileAway, noActivityYet
        case noProject, stalled, stalledFor
        case supportHealth, supportHealthHint, supportScanIncomplete, supportScanIncompleteTimeout, supportNoneObserved, supportAllAgents
        case supportNotDetected, supportStructured, supportCache, supportProcess, supportDetected
        case supportGoal, supportWorkspace, supportActivity, supportProgress, supportAction, supportModel, supportEvidence, session
        case detailTool, detailSkill, detailPhase, detailOutcome, detailEvidence, detailFiles, detailErrors, detailContext
        case supportResources, supportObservedSignals, supportNoObservedSignals, skillFact, supportLastRead, supportMissing
        case supportMissingFeed, supportMissingGoal, supportMissingWorkspace
        case supportMissingWaiting
        case supportWaitingHooks, supportWaitingHarvest, supportWaitingNone, supportWaitingNoneDetail, supportSharedCursor
        case supportLastSignal, supportDetectedExecutable, supportDetectedPath, supportFactCoverage
        case supportCollectorObserved, supportCollectorNoData, supportCollectorNoDataDetail
        case supportCollectorSourceAbsent, supportCollectorSourceAbsentDetail
        case supportCollectorPrivacyLimited, supportCollectorPrivacyLimitedDetail, supportCollectorPrivacyLimitedScoped
        case supportCollectorNoSessions, supportCollectorNoSessionsDetail
        case supportCollectorPermission, supportCollectorPermissionDetail
        case supportCollectorSchema, supportCollectorSchemaDetail
        case supportCollectorFailed, supportCollectorFailedDetail
        case supportCollectorUnscanned, supportCollectorUnscannedDetail
        case supportObservedCount, supportIssueCount, supportAdapterIssueCount
        case supportInformationGapCount, supportFilterIssuesCount, supportSearch
        case supportFilterIssues, supportFilterRunning, supportFilterInstalled
        case supportFilterNoData, supportFilterAll, supportNoFilterResults
        case supportNeedsAction, supportLimited, supportHealthy, supportUnavailable, supportAvailable, supportNotInstalled, supportNoRecentSession, supportPermissionDenied, supportUnscanned
        case supportNeedsActionCount, supportLimitedCount, supportHealthyCount, supportUnavailableCount, supportAvailableCount, supportNotInstalledCount, supportNoRecentCount, supportPermissionDeniedCount, supportUnscannedCount, supportUsefulCoverage
        case supportRetry, supportRunAgent, supportEnableData, supportAdapterDiagnostics, supportSafeReport, supportCopySafeReport, exportSafeReport
        case snooze, snoozed, snoozedFor, stallAfter, stallOff, minutesShort, notifFocus
        case recordsSuffix, sessionAge, waitingSummaryTitle, waitingSummaryBody, searchSessions, searchNoResults, clearSearch
        case installUpdate, updateInstalling, updateInstallFailed, updateInstallRequiresNotarized
        case updatePreview, updateSignedUnnotarized, recoveredAfterCrash
        case recoveredAfterForceQuit, recoveredAfterSystemRestart
        case qualityReasonProcessOnly, qualityReasonCache, qualityReasonNotEmitted, qualityReasonWaitingNoDetail
        case qualityReasonScanTimeout
        case qualityNextOpenAgent, qualityNextWaitCache, qualityNextAttentionBridge, qualityNextRetryScan
        case supportFailureTimelineEntry
        case qualityConfidenceHigh, qualityConfidenceMedium, qualityConfidenceLow
        case allSessionsCount, filterPhase, filterOutcome, filterClear
        case waitingTimeline, waitingQueuedAt, waitingNotifiedAt, waitingAcknowledgedAt
        case waitingSnoozedUntil, waitingResolvedAt, waitingNotifyPending
        case installCopyBuildArtifact, installCopyRollback
        case phaseResponding, phaseTurnComplete, phaseWaitingPermission, phasePlanning, phaseWorking, phaseTesting
        case phaseBuilding, phasePublishing
        case nowActivity, outcomeActivity
        case modelFact, errorFactOne, errorsFact, outcomeFailed, outcomeCancelled
        case filesFact, contextFact, progressFact, turnsFact
        case trayScanIncomplete
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
