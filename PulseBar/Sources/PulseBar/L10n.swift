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
        case .agentDataAccess: return "Read app data for richer details"
        case .agentDataAccessHint:
            return "Off by default. Enables deeper Cursor/VS Code/Warp scans and may ask macOS for cross-app data access."
        case .agentDataAccessSkipHint: return "If skipped, Pulse still reads process and unprotected session evidence; no prompt is shown."
        case .notifyWaiting: return "Notify when an agent needs me"
        case .focusTTY: return "Go to Terminal tab"
        case .focusWarp: return "Go to Warp (app)"
        case .focusHostWorkspace: return "Go to the workspace in %@"
        case .focusHostApp: return "Go to %@ (app)"
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
        case .signalHooks: return "hook report"
        case .signalPending: return "session record"
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
        case .processCount: return "%d processes"
        case .terminalSession: return "Terminal session running"
        case .appSession: return "Agent app running"
        case .processAge: return "Process started %@ ago"
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
        case .cappedSessions: return "%d more session(s) not shown"
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
        case .probeEvery: return "every %ds"
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
        case .noActivityYet: return "no activity yet"
        case .stalled: return "Stalled"
        case .stalledFor: return "No activity for %@"
        case .supportScanIncomplete:
            return "Scan incomplete · previous adapter results retained"
        case .supportScanIncompleteTimeout:
            return "Scan timed out on some adapters · partial results retained"
        case .supportNotDetected: return "Not detected"
        case .supportStructured: return "Structured session"
        case .supportCache: return "Local cache"
        case .supportProcess: return "Process only"
        case .supportDetected: return "Detected"
        case .supportGoal: return "goal"
        case .supportWorkspace: return "workspace"
        case .supportActivity: return "activity"
        case .supportProgress: return "execution signal"
        case .supportObservedSignals: return "Observed: %@"
        case .supportLastRead: return "read %@ ago"
        case .supportMissing: return "missing: %@"
        case .supportMissingFeed: return "activity feed"
        case .supportMissingGoal: return "goal"
        case .supportMissingWorkspace: return "workspace"
        case .supportMissingWaiting: return "Waiting hook not ready"
        case .supportWaitingHooks: return "Waiting route: hooks"
        case .supportWaitingNoneDetail:
            return "No native Waiting path — use the Attention bridge"
        case .supportDepthSession: return "Depth: session transcript"
        case .supportDepthCacheThin: return "Only part of a cache could be read"
        case .supportDepthCachePartial: return "Depth: cache facts (Limited)"
        case .supportDepthWaitingNone: return "Waiting unavailable — Attention bridge"
        case .supportSharedCursor: return "The Cursor IDE and the cursor-agent CLI are one agent"
        case .supportLastSignal: return "signal %@ ago"
        case .supportDetectedExecutable: return "detected by executable"
        case .supportDetectedPath: return "detected by path signature"
        case .supportFactCoverage: return "%d/%d useful signals"
        case .supportCollectorObserved: return "adapter read %d row(s) in %d ms"
        case .supportCollectorSourceAbsent: return "Source not found"
        case .supportCollectorSourceAbsentDetail: return "no local session source or CLI found"
        case .supportCollectorPrivacyLimited: return "Privacy-limited"
        case .supportCollectorPrivacyLimitedDetail:
            return "deep app-data scan is off; enable it in Settings for richer details"
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
        case .supportNeedsAction: return "Needs action"
        case .supportLimited: return "Limited"
        case .supportAvailable: return "Available"
        case .supportNotInstalled: return "Not installed"
        case .supportNoRecentSession: return "No recent session"
        case .supportPermissionDenied: return "Permission denied"
        case .supportUnscanned: return "Unscanned"
        case .supportRetry: return "Retry scan"
        case .supportEnableData: return "Turn on app data reading"
        case .supportExplainFiles: return "read %d files"
        case .supportExplainFacts: return "%d facts"
        case .supportExplainTruncated: return "window truncated — counts are floors"
        case .supportExplainHero: return "headline from %@"
        case .supportExplainEmpty: return "no headline: %@"
        case .supportEmptyNoSource: return "this agent's store is not on this Mac"
        case .supportEmptyDeadline: return "the scan hit its deadline before finishing"
        case .supportEmptyNoReadableFile: return "no file could be opened"
        case .supportEmptyNoParsableRecord: return "files were read but no record parsed"
        case .supportEmptyNoDisplaySignal: return "records parsed but none carried a displayable signal"
        case .supportEmptyNoUserGoal: return "records parsed but none contained a user goal"
        case .supportOriginChrome: return "a vendor placeholder"
        case .supportOriginFallbackText: return "free text"
        case .supportOriginCacheTitle: return "a cache title"
        case .supportOriginToolTitle: return "a tool label"
        case .supportOriginUserPrompt: return "a user turn"
        case .supportOriginSessionName: return "a name you gave the session"
        case .supportCopyShapeReport: return "Copy vendor shape"
        case .notifFocus: return "Go"
        case .waitingSummaryTitle: return "%d agents need your attention"
        case .searchNoResults: return "No sessions match “%@”"
        case .updatePreview: return "Preview build · ad-hoc signed · not notarized"
        case .updateSignedUnnotarized: return "Developer ID signed · not notarized · Gatekeeper may block"
        case .qualityReasonScanTimeout: return "Adapter timed out while reading local data"
        case .supportFailureTimelineEntry: return "Last failure · %@ · %@ ago"
        case .trayScanIncomplete: return "The last read did not finish"
        case .modelFact: return "Model %@"
        case .errorFactOne: return "1 failure"
        case .errorsFact: return "%d failures"
        case .progressFact: return "%d/%d complete"
        case .supportYield: return "Measured facts: %@"
        case .supportYieldDrifted:
            return "Structured adapter yielded rows but no core facts — the vendor format may have drifted"
        case .signalVendor: return "Claude reports"
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
        case .readsLastHour: return "%d reads in the last hour"
        case .readsLastHourAvg: return "%d reads in the last hour, %d ms each"
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
        case .detailPlanHeading: return "Plan"
        case .detailNotificationHeading: return "Notification"
        case .detailBack: return "Back"
        case .detailMinutesIn: return "%@ %d min"
        case .filterMatches: return "%d matches"
        case .trayKeyHints: return "↑↓ select   ↩ go   → details   ⌘D dismiss   ⌘M mute   esc close"
        case .activityLeft: return "left the list"
        case .activityFromSession: return "session record"
        case .activityFromProcess: return "process only"
        case .activityHeading: return "Activity"
        case .activityEmpty: return "Nothing recorded yet. State changes and banners appear here as they happen."
        case .activityAllAgents: return "All agents"
        case .explainHook: return "%@'s hook reported %@ %@"
        case .explainHookFront: return " — its window was in front, so no banner"
        case .explainPending: return "%@'s session file shows %@, first seen %@"
        case .explainVendor: return "Claude itself reports %@, first seen %@"
        case .explainTurn: return "%@'s hook reported the turn ended %@ — focus it or reply to clear"
        case .explainProcessOnly: return "Seen only as a process — no session data"
        case .explainStalled: return "No new output for %@"
        case .explainStalledUnknown: return "Running, but Pulse has no clock for its activity"
        case .explainErrors: return "The agent reported %d error(s) in this session"
        case .explainRunning: return "%@ changed %@"
        case .explainRunningNoClock: return "A live process, and no clock for its activity yet"
        case .explainRecent: return "No live process; last activity %@"
        case .explainRecentNoClock: return "No live process"
        case .explainKindPermission: return "a permission request"
        case .explainKindInput: return "a question"
        case .explainKindWaiting: return "that it is waiting"
        case .sourceSession: return "Session file"
        case .sourceCache: return "App data"
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
        case .doctorCodexRollout: return "Codex session log format"
        case .doctorReading: return "Session formats read in full"
        case .doctorNoSessions: return "No session files read this run"
        case .doctorCoverageGap: return "%@: %d session(s), %d with a title"
        case .doctorCoverageGapWords: return ", %d with last words"
        case .doctorCoverageFine: return "%d session(s) from %d agent(s), titles and words where the format carries them"
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
        case .doctorNoCLI: return "No claude executable found where Pulse looks"
        case .doctorCLIOnPath: return "Install Claude Code's CLI, or ignore this if you only use hooks"
        case .doctorAgentsTimedOut: return "Timed out after 3 s"
        case .doctorAgentsFailed: return "Exited with status %d — this Claude may predate the command"
        case .doctorUpdateClaude: return "Update Claude Code; hooks keep working meanwhile"
        case .doctorAgentsUnreadable: return "Answered %d bytes Pulse cannot read as the documented shape"
        case .doctorReportShape: return "Copy this report into an issue — the shape changed"
        case .doctorAgentsParsed: return "Read %d session(s), %d waiting"
        case .doctorGatingHook: return "A Pulse entry sits on %@, which can gate the agent or fake a wait; reinstall hooks to remove it"
        case .doctorNotifyOnly: return " (the older notify hook is present)"
        case .doctorCodexNeedsTrust: return "Pulse's hooks are installed; whether Codex trusts them only shows once one fires"
        case .doctorCodexTrust: return "Run /hooks in Codex once and trust Pulse's entries"
        case .doctorNoRollout: return "No session log in the last week to look at"
        case .doctorRolloutLegacy: return "Classic event lines — parsed"
        case .doctorRolloutPaginated: return "Paginated turn items — parsed (18.0)"
        case .doctorRolloutMixed: return "Both formats in one log — parsed"
        case .doctorRolloutUnknown: return "The newest log has neither format Pulse reads"
        case .doctorCompressed: return " · %d compressed older log(s) left alone"
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
        case .settingsDataSection: return "Data access"
        case .settingsUpdatesSection: return "Updates"
        case .detailLastMessage: return "Last message"
        case .detailErrorHeading: return "Error"
        case .detailSession: return "Session"
        case .detailWaitSignal: return "Wait signal"
        case .detailGo: return "Go"
        case .detailGoNone: return "No way to reach it — observed only"
        case .detailProcess: return "Process"
        case .detailLastChange: return "Last change"
        case .detailMoreSessions: return "Sessions not listed"
        case .detailDiagnostics: return "How Pulse reads this session"
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
        case .agentDataAccess: return "读取应用数据以展示更多详情"
        case .agentDataAccessHint: return "默认关闭。开启后会深入扫描 Cursor / VS Code / Warp，macOS 可能会请求访问其他应用的数据。"
        case .agentDataAccessSkipHint: return "跳过后仍会读取进程和未受保护的会话证据；不会弹出权限请求。"
        case .notifyWaiting: return "Agent 需要我时通知"
        case .focusTTY: return "前往终端标签页"
        case .focusWarp: return "前往 Warp（应用）"
        case .focusHostWorkspace: return "前往 %@ 中的工作区"
        case .focusHostApp: return "前往 %@（应用）"
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
        case .signalHooks: return "Hook 报告"
        case .signalPending: return "会话记录"
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
        case .processCount: return "%d 个进程"
        case .terminalSession: return "终端会话正在运行"
        case .appSession: return "Agent 应用正在运行"
        case .processAge: return "进程始于%@前"
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
        case .cappedSessions: return "另有 %d 个会话未显示"
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
        case .probeEvery: return "每 %d 秒"
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
        case .noActivityYet: return "暂无动静"
        case .stalled: return "停滞"
        case .stalledFor: return "已 %@ 无活动"
        case .supportScanIncomplete: return "扫描未完成 · 保留了上一次的读取结果"
        case .supportScanIncompleteTimeout: return "部分读取超时 · 保留了已读到的结果"
        case .supportNotDetected: return "未检测到"
        case .supportStructured: return "结构化会话"
        case .supportCache: return "本地缓存"
        case .supportProcess: return "仅进程"
        case .supportDetected: return "已检测"
        case .supportGoal: return "目标"
        case .supportWorkspace: return "工作区"
        case .supportActivity: return "活动"
        case .supportProgress: return "执行信号"
        case .supportObservedSignals: return "已观测：%@"
        case .supportLastRead: return "%@前读取"
        case .supportMissing: return "缺少：%@"
        case .supportMissingFeed: return "活动数据"
        case .supportMissingGoal: return "目标"
        case .supportMissingWorkspace: return "工作区"
        case .supportMissingWaiting: return "等待 hook 尚未就绪"
        case .supportWaitingHooks: return "等待通路：hooks"
        case .supportWaitingNoneDetail: return "不能主动报告「需要你」—— 可以通过 Attention 桥接入"
        case .supportDepthSession: return "深度：会话记录"
        case .supportDepthCacheThin: return "只读到部分缓存"
        case .supportDepthCachePartial: return "深度：缓存事实（有限）"
        case .supportDepthWaitingNone: return "不能报告「需要你」—— 可通过 Attention 桥接入"
        case .supportSharedCursor: return "Cursor IDE 与 cursor-agent 命令行是同一个 Agent"
        case .supportLastSignal: return "%@前收到信号"
        case .supportDetectedExecutable: return "通过可执行程序检测"
        case .supportDetectedPath: return "通过路径特征检测"
        case .supportFactCoverage: return "有效信号 %d/%d"
        case .supportCollectorObserved: return "读到 %d 行 · %d 毫秒"
        case .supportCollectorSourceAbsent: return "未发现数据源"
        case .supportCollectorSourceAbsentDetail: return "未发现本地会话数据或 CLI"
        case .supportCollectorPrivacyLimited: return "隐私受限"
        case .supportCollectorPrivacyLimitedDetail:
            return "深度应用数据扫描已关闭；可在设置中开启以获取更多详情"
        case .supportCollectorNoSessions: return "暂无可用会话"
        case .supportCollectorNoSessionsDetail: return "数据源存在 · 暂无可用会话 · %d 毫秒"
        case .supportCollectorPermission: return "无读取权限"
        case .supportCollectorPermissionDetail: return "无法读取本地数据源"
        case .supportCollectorSchema: return "数据格式已变化"
        case .supportCollectorSchemaDetail: return "本地数据存在，但 Pulse 认不出它的格式"
        case .supportCollectorFailed: return "读取失败"
        case .supportCollectorFailedDetail: return "读取失败：%@"
        case .supportCollectorUnscanned: return "未完成扫描"
        case .supportCollectorUnscannedDetail: return "最近一次扫描中，这一路读取没有完成"
        case .supportNeedsAction: return "需要处理"
        case .supportLimited: return "信息受限"
        case .supportAvailable: return "可用"
        case .supportNotInstalled: return "未安装"
        case .supportNoRecentSession: return "无近期会话"
        case .supportPermissionDenied: return "权限不足"
        case .supportUnscanned: return "未扫描"
        case .supportRetry: return "重新扫描"
        case .supportEnableData: return "开启应用数据读取"
        case .supportExplainFiles: return "读了 %d 个文件"
        case .supportExplainFacts: return "解析出 %d 条事实"
        case .supportExplainTruncated: return "窗口被截断 —— 上面的计数只是下限"
        case .supportExplainHero: return "标题来自%@"
        case .supportExplainEmpty: return "没有标题：%@"
        case .supportEmptyNoSource: return "这台 Mac 上没有它的数据目录"
        case .supportEmptyDeadline: return "还没读完就到了扫描时限"
        case .supportEmptyNoReadableFile: return "一个文件都没能打开"
        case .supportEmptyNoParsableRecord: return "文件读到了，但没解析出记录"
        case .supportEmptyNoDisplaySignal: return "记录解析出来了，但没有一条带可显示的信号"
        case .supportEmptyNoUserGoal: return "记录解析出来了，但里面没有用户的目标"
        case .supportOriginChrome: return "厂商占位文案"
        case .supportOriginFallbackText: return "自由文本"
        case .supportOriginCacheTitle: return "缓存标题"
        case .supportOriginToolTitle: return "工具标签"
        case .supportOriginUserPrompt: return "一次用户提问"
        case .supportOriginSessionName: return "你给这场会话起的名字"
        case .supportCopyShapeReport: return "复制厂商格式"
        case .notifFocus: return "前往"
        case .waitingSummaryTitle: return "%d 个 Agent 需要你"
        case .searchNoResults: return "没有匹配「%@」的会话"
        case .updatePreview: return "预览版 · ad-hoc 签名 · 未公证"
        case .updateSignedUnnotarized: return "已用 Developer ID 签名 · 未公证 · Gatekeeper 可能拦截"
        case .qualityReasonScanTimeout: return "读取本地数据超时"
        case .supportFailureTimelineEntry: return "最近失败 · %@ · %@前"
        case .trayScanIncomplete: return "上次读取没有完成"
        case .modelFact: return "模型 %@"
        case .errorFactOne: return "1 项失败"
        case .errorsFact: return "%d 项失败"
        case .progressFact: return "完成 %d/%d"
        case .supportYield: return "实测事实：%@"
        case .supportYieldDrifted:
            return "声明结构化、本拍有行却零核心事实 —— 厂商格式可能已漂移"
        case .signalVendor: return "Claude 自报"
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
        case .readsLastHour: return "过去一小时读取 %d 次"
        case .readsLastHourAvg: return "过去一小时读取 %d 次，每次 %d 毫秒"
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
        case .detailPlanHeading: return "计划"
        case .detailNotificationHeading: return "通知"
        case .detailBack: return "返回"
        case .detailMinutesIn: return "%@ %d 分钟"
        case .filterMatches: return "%d 个匹配"
        case .trayKeyHints: return "↑↓ 选择   ↩ 前往   → 详情   ⌘D 忽略   ⌘M 静音   esc 关闭"
        case .activityLeft: return "离开了列表"
        case .activityFromSession: return "会话记录"
        case .activityFromProcess: return "仅进程"
        case .activityHeading: return "动态"
        case .activityEmpty: return "还没有记录。状态变化和通知会在发生时出现在这里。"
        case .activityAllAgents: return "全部 Agent"
        case .explainHook: return "%@ 的 hook 报告了%@ · %@"
        case .explainHookFront: return " —— 当时提示窗口就在最前，所以没有通知"
        case .explainPending: return "%@ 的会话文件显示%@ · 首次看到于%@"
        case .explainVendor: return "Claude 自己报告了%@ · 首次看到于%@"
        case .explainTurn: return "%@ 的 hook 报告回合结束 · %@ —— 聚焦或回复它即消失"
        case .explainProcessOnly: return "只看到进程——没有会话数据"
        case .explainStalled: return "已经 %@ 没有新输出"
        case .explainStalledUnknown: return "在运行，但 Pulse 读不到它的活动时间"
        case .explainErrors: return "Agent 在这个会话里报告了 %d 个错误"
        case .explainRunning: return "%@更新于%@"
        case .explainRunningNoClock: return "进程在运行，还读不到它的活动时间"
        case .explainRecent: return "没有在运行的进程；最近活动 %@"
        case .explainRecentNoClock: return "没有在运行的进程"
        case .explainKindPermission: return "权限请求"
        case .explainKindInput: return "一个问题"
        case .explainKindWaiting: return "在等待"
        case .sourceSession: return "会话文件"
        case .sourceCache: return "应用数据"
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
        case .doctorCodexRollout: return "Codex 会话记录格式"
        case .doctorReading: return "会话格式读全了"
        case .doctorNoSessions: return "本次运行没有读到会话文件"
        case .doctorCoverageGap: return "%@：%d 个会话，%d 个有标题"
        case .doctorCoverageGapWords: return "，%d 个有最后一句话"
        case .doctorCoverageFine: return "%d 个会话，来自 %d 个 Agent，格式里有的标题与话都读到了"
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
        case .doctorNoCLI: return "在 Pulse 查找的位置没有 claude 可执行文件"
        case .doctorCLIOnPath: return "安装 Claude Code 命令行；只用 hooks 可忽略"
        case .doctorAgentsTimedOut: return "3 秒超时"
        case .doctorAgentsFailed: return "退出码 %d——这版 Claude 可能还没有这个命令"
        case .doctorUpdateClaude: return "升级 Claude Code；在此之前 hooks 照常工作"
        case .doctorAgentsUnreadable: return "返回了 %d 字节，不是 Pulse 认识的格式"
        case .doctorReportShape: return "把这份报告贴进 issue——格式变了"
        case .doctorAgentsParsed: return "读到 %d 个会话，其中 %d 个在等"
        case .doctorGatingHook: return "Pulse 的条目挂在 %@ 上，它可能拦住 Agent 或造成假的等待；重新安装 hooks 即可移除"
        case .doctorNotifyOnly: return "（仍有旧的 notify hook）"
        case .doctorCodexNeedsTrust: return "Pulse 的 hooks 已安装；Codex 是否信任它们，要等触发一次才知道"
        case .doctorCodexTrust: return "在 Codex 里运行一次 /hooks 并信任 Pulse 的条目"
        case .doctorNoRollout: return "最近一周没有可查看的会话记录"
        case .doctorRolloutLegacy: return "经典事件行——可解析"
        case .doctorRolloutPaginated: return "分页 turn 条目——可解析（18.0）"
        case .doctorRolloutMixed: return "同一记录里两种格式——都可解析"
        case .doctorRolloutUnknown: return "最新的记录两种格式都不是"
        case .doctorCompressed: return " · %d 个压缩的旧记录不读"
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
        case .settingsDataSection: return "数据访问"
        case .settingsUpdatesSection: return "更新"
        case .detailLastMessage: return "最后的消息"
        case .detailErrorHeading: return "错误"
        case .detailSession: return "会话"
        case .detailWaitSignal: return "等待信号"
        case .detailGo: return "前往"
        case .detailGoNone: return "无法前往 —— 仅观测"
        case .detailProcess: return "进程"
        case .detailLastChange: return "最后变化"
        case .detailMoreSessions: return "未列出的会话"
        case .detailDiagnostics: return "Pulse 如何读取这个会话"
        }
    }

    /// `CaseIterable` so tests can assert every key resolves in both languages
    /// and that format specifiers match (a mismatched %d crashes String(format:)).
    enum Key: CaseIterable {
        case noAgents, noAgentsDetected, needsYou, waitingN, runningN
        case recent1, recentN, recent
        case justNow, notYet, andMore, showLess
        case settings, quit
        case focusTTY, focusWarp, focusHostWorkspace, focusHostApp, focusOpenTray, dismissWait
        case focusFailed
        case allowTerminalAutomation, allowTerminalAutomationHint
        case supportFocusNone, supportFocusWarp, supportFocusHostWorkspace, supportFocusHost, supportFocusTTY, supportFocusTTYNeedsOptIn
        case supportDepthSession, supportDepthCacheThin, supportDepthCachePartial, supportDepthWaitingNone
        case general, agentDataAccess, agentDataAccessHint, agentDataAccessSkipHint, notifyWaiting, launchAtLogin, language
        case hooksHint, installHooks, testWaitingSignal
        case hookTestIdle, hookTestRunning, hookTestPassed, hookTestFailed
        case shortcuts
        case running, settingsTitle
        case hooksNudge, hooksUnknown, hooksMissing, hooksInstalledCount
        case hooksFailed
        case kindPermission, kindInput, kindWaiting
        case signalHooks, signalPending
        case processCount
        case terminalSession, appSession, processAge
        case terminalDetectedNoDetails, appDetectedNoDetails
        case setupWaitingSignals
        case copied
        case versionMismatchHint
        case durNow, durSec, durMin, durHour
        case notificationsSection, notifyNotConfigured
        case enableNotifications, notifyDenied, openNotificationSettings
        case uninstallHooks
        case revealShortcut, hotkeyTaken
        case cappedSessions, emptyHint
        case checkForUpdates, checkNow, openRelease
        case updateIdle, updateChecking, updateCurrent, updateCurrentPrerelease, updateCurrentStable
        case updateAvailable, updateFailed
        case probeEvery, probeParked
        case a11yIdle, a11yRunning, a11yStalled, a11yWaiting
        case sectionNeedsYou, sectionRunning, sectionStalled, sectionRecent
        case moreActions
        case agoFormat
        case noActivityYet
        case stalled, stalledFor
        case supportScanIncomplete, supportScanIncompleteTimeout
        case supportNotDetected, supportStructured, supportCache, supportProcess, supportDetected
        case supportGoal, supportWorkspace, supportActivity, supportProgress
        case supportObservedSignals, supportLastRead, supportMissing
        case supportMissingFeed, supportMissingGoal, supportMissingWorkspace
        case supportMissingWaiting
        case supportWaitingHooks, supportWaitingNoneDetail, supportSharedCursor
        case supportLastSignal, supportDetectedExecutable, supportDetectedPath, supportFactCoverage
        case supportCollectorObserved
        case supportCollectorSourceAbsent, supportCollectorSourceAbsentDetail
        case supportCollectorPrivacyLimited, supportCollectorPrivacyLimitedDetail
        case supportCollectorNoSessions, supportCollectorNoSessionsDetail
        case supportCollectorPermission, supportCollectorPermissionDetail
        case supportCollectorSchema, supportCollectorSchemaDetail
        case supportCollectorFailed, supportCollectorFailedDetail
        case supportCollectorUnscanned, supportCollectorUnscannedDetail
        case supportNeedsAction, supportLimited, supportAvailable, supportNotInstalled, supportNoRecentSession, supportPermissionDenied, supportUnscanned
        case supportRetry, supportEnableData
        case supportExplainFiles, supportExplainFacts, supportExplainTruncated
        case supportExplainHero, supportExplainEmpty
        case supportEmptyNoSource, supportEmptyDeadline, supportEmptyNoReadableFile
        case supportEmptyNoParsableRecord, supportEmptyNoDisplaySignal, supportEmptyNoUserGoal
        case supportOriginChrome, supportOriginFallbackText, supportOriginCacheTitle
        case supportOriginToolTitle, supportOriginUserPrompt, supportOriginSessionName
        case supportCopyShapeReport
        case notifFocus
        case waitingSummaryTitle, searchNoResults
        case updatePreview, updateSignedUnnotarized
        case qualityReasonScanTimeout
        case supportFailureTimelineEntry
        case modelFact, errorFactOne, errorsFact
        case progressFact
        case supportYield, supportYieldDrifted
        case trayScanIncomplete
        case yourTurn
        case signalVendor
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
        case readsLastHour
        case readsLastHourAvg
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
        case detailPlanHeading
        case detailNotificationHeading
        case detailBack
        case detailMinutesIn
        case filterMatches
        case trayKeyHints
        case activityLeft
        case activityFromSession
        case activityFromProcess
        case activityHeading
        case activityEmpty
        case activityAllAgents
        case explainHook
        case explainHookFront
        case explainPending
        case explainVendor
        case explainTurn
        case explainProcessOnly
        case explainStalled
        case explainStalledUnknown
        case explainErrors
        case explainRunning
        case explainRunningNoClock
        case explainRecent
        case explainRecentNoClock
        case explainKindPermission
        case explainKindInput
        case explainKindWaiting
        case sourceSession
        case sourceCache
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
        case doctorCodexRollout
        case doctorReading
        case doctorNoSessions
        case doctorCoverageGap
        case doctorCoverageGapWords
        case doctorCoverageFine
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
        case doctorNoCLI
        case doctorCLIOnPath
        case doctorAgentsTimedOut
        case doctorAgentsFailed
        case doctorUpdateClaude
        case doctorAgentsUnreadable
        case doctorReportShape
        case doctorAgentsParsed
        case doctorGatingHook
        case doctorNotifyOnly
        case doctorCodexNeedsTrust
        case doctorCodexTrust
        case doctorNoRollout
        case doctorRolloutLegacy
        case doctorRolloutPaginated
        case doctorRolloutMixed
        case doctorRolloutUnknown
        case doctorCompressed
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
        case settingsDataSection
        case settingsUpdatesSection
        case detailLastMessage
        case detailErrorHeading
        case detailSession
        case detailWaitSignal
        case detailGo
        case detailGoNone
        case detailProcess
        case detailLastChange
        case detailMoreSessions
        case detailDiagnostics
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
