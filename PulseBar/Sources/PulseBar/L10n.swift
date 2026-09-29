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
        case .waitingN: return "waiting"
        case .runningN: return "running"
        case .recent1: return "1 recent"
        case .recentN: return "recent"
        case .justNow: return "just now"
        case .notYet: return "not yet"
        case .cantRefresh: return "Can't refresh"
        case .andMore: return "and %d more…"
        case .showLess: return "Show less"
        case .refresh: return "Refresh"
        case .clearWaiting: return "Clear waiting"
        case .settings: return "Settings…"
        case .quit: return "Quit Pulse"
        case .focusTerminal: return "Focus terminal"
        case .general: return "General"
        case .agentDataAccess: return "Read app data for richer details"
        case .agentDataAccessHint:
            return "Off by default. Enables deeper Cursor/VS Code/Warp scans and may ask macOS for cross-app data access."
        case .agentDataAccessSkipHint: return "If skipped, Pulse still reads process and unprotected session evidence; no prompt is shown."
        case .notifyWaiting: return "Notify on new Waiting"
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
        case .signalHooks: return "hook report"
        case .signalPending: return "session record"
        case .launchAtLogin: return "Launch at login"
        case .language: return "Language"
        case .waitingSignals: return "Waiting signals"
        case .hooksHint:
            return "Install Claude/Codex hooks so Pulse can show permission, input waits, and subagent lifecycle. Native — no Python required."
        case .installHooks: return "Install hooks"
        case .testWaitingSignal: return "Test connection"
        case .hookTestIdle: return "Not tested"
        case .hookTestRunning: return "Testing…"
        case .hookTestPassed: return "Connection passed"
        case .hookTestFailed: return "Connection failed"
        case .shortcuts: return "Shortcuts"
        case .globalShortcutHint: return "Off by default. Enabling it registers a system-wide key and may require macOS Automation access on unsigned builds."
        case .agents: return "Agent"
        case .running: return "Running"
        case .settingsTitle: return "Pulse Settings"
        case .recent: return "Recent"
        case .dismissWait: return "Dismiss"
        case .focusFailed: return "Could not open it — that window may be gone. Rescanning."
        case .hooksNudge: return "Install hooks for Claude and Codex to see their exact requests and \"your turn\""
        case .waitingSignalNudge:
            return "An agent is running that cannot tell Pulse it needs you — see how to connect it"
        case .hooksUnknown: return "Not checked"
        case .hooksMissing: return "Not installed"
        case .hooksInstalledBoth: return "Installed · Claude + Codex"
        case .hooksInstalledClaude: return "Installed · Claude"
        case .hooksInstalledCodex: return "Installed · Codex"
        case .hooksFailed: return "Failed"
        case .kindPermission: return "Permission"
        case .kindInput: return "Input"
        case .kindWaiting: return "Waiting"
        case .idleWord: return "idle"
        case .processDetected: return "Process detected"
        case .processCount: return "%d processes"
        case .limitedData: return "Process only"
        case .sessionEvidence: return "Session"
        case .cacheEvidence: return "Local cache"
        case .terminalSession: return "Terminal session running"
        case .appSession: return "Agent app running"
        case .processAge: return "Process started %@ ago"
        case .activityChanged: return "Changed · %@"
        case .newErrors: return "%d new errors"
        case .newFiles: return "%d more files"
        case .progressAdvanced: return "Progress moved to %d/%d"
        case .modelCallChanged: return "New model call"
        case .toolChanged: return "Tool changed"
        case .phaseChanged: return "Phase changed"
        case .taskChanged: return "Goal changed"
        case .signalProgress: return "Progress %d/%d"
        case .signalErrors: return "+%d errors"
        case .signalFiles: return "+%d files"
        case .signalModel: return "Model call"
        case .signalTool: return "Tool"
        case .signalPhase: return "Phase"
        case .signalTask: return "Goal"
        case .signalCompleted: return "Complete"
        case .signalFailed: return "Failed"
        case .signalCancelled: return "Cancelled"
        case .terminalDetectedNoDetails: return "Terminal session running · activity feed unavailable"
        case .appDetectedNoDetails: return "Agent app running · session feed unavailable"
        case .lastAction: return "Last action: %@"
        case .lastActive: return "Last active %@"
        case .latestCallTokens: return "Latest model call · %@ input · %@ output"
        case .reportedTokens: return "Agent reported · %@ input · %@ output"
        case .latestCallTokensIn: return "Latest model call · %@ input"
        case .latestCallTokensOut: return "Latest model call · %@ output"
        case .reportedTokensIn: return "Agent reported · %@ input"
        case .reportedTokensOut: return "Agent reported · %@ output"
        case .compactTokensIn: return "↑%@"
        case .compactTokensOut: return "↓%@"
        case .compactTokens: return "↑%@ ↓%@"
        case .subagentsActive: return "%d of %d subagents active"
        case .subagentsObserved: return "%d subagents observed"
        case .subChipActive: return "sub %d↑"
        case .subChipObserved: return "sub %d"
        case .actionPlanning: return "Planning"
        case .actionCommand: return "Terminal command"
        case .actionEditing: return "Editing files"
        case .actionImage: return "Reviewing image"
        case .actionResearch: return "Research"
        case .actionReading: return "Reading files"
        case .actionAutomation: return "Automation"
        case .setupWaitingSignals: return "Connect “needs you”…"
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
        case .uninstallHooks: return "Remove hooks"
        case .revealShortcut: return "Reveal Pulse"
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
        case .a11yUnknown: return "unknown"
        case .a11yPresent: return "present"
        case .a11yIdle: return "Idle"
        case .a11yRunning: return "Running"
        case .a11yStalled: return "Stalled"
        case .a11yWaiting: return "Needs attention"
        case .a11yError: return "Cannot refresh"
        case .sectionNeedsYou: return "Needs you"
        case .sectionRunning: return "Running"
        case .sectionStalled: return "Stalled"
        case .sectionRecent: return "Recent"
        case .jumpToOldest: return "Jump to longest wait"
        case .moreActions: return "More actions"
        case .acrossProjects: return "across %d projects"
        case .agoFormat: return "%@ ago"
        case .noActivityYet: return "no activity yet"
        case .stalled: return "Stalled"
        case .stalledFor: return "No activity for %@"
        case .supportHealth: return "Health…"
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
        case .supportAction: return "last action"
        case .supportModel: return "model"
        case .supportEvidence: return "evidence"
        case .session: return "session"
        case .detailTool: return "tool"
        case .detailSkill: return "skill"
        case .detailPhase: return "phase"
        case .detailOutcome: return "outcome"
        case .detailEvidence: return "evidence"
        case .detailErrors: return "errors"
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
        case .supportDepthCacheThin: return "Only part of a cache could be read"
        case .supportDepthCachePartial: return "Depth: cache facts (Limited)"
        case .supportDepthWaitingNone: return "Waiting unavailable — Attention bridge"
        case .supportSharedCursor: return "Cursor Agent shares this adapter"
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
        case .supportSearch: return "Search Agents"
        case .supportFilterAll: return "All"
        case .supportNoFilterResults: return "No Agents match this filter"
        case .supportNeedsAction: return "Needs action"
        case .supportLimited: return "Limited"
        case .supportAvailable: return "Available"
        case .supportNotInstalled: return "Not installed"
        case .supportNoRecentSession: return "No recent session"
        case .supportPermissionDenied: return "Permission denied"
        case .supportUnscanned: return "Unscanned"
        // Order: available, needs action, limited, not installed, no recent
        // session, permission denied, unscanned.
        case .supportSummaryLine:
            return "Available %d · Needs action %d · Limited %d · Not installed %d · No recent session %d · Permission denied %d · Unscanned %d"
        case .supportNeedsActionCount: return "Action · %d"
        case .supportLimitedCount: return "Limited · %d"
        case .supportAvailableCount: return "Available · %d"
        case .supportNotInstalledCount: return "Not installed · %d"
        case .supportNoRecentCount: return "No recent · %d"
        case .supportPermissionDeniedCount: return "Permission · %d"
        case .supportUnscannedCount: return "Unscanned · %d"
        case .supportUsefulCoverage: return "%d/%d useful signals"
        case .supportRetry: return "Retry scan"
        case .supportRunAgent: return "Run this agent once"
        case .supportEnableData: return "Turn on app data reading"
        case .supportAdapterDiagnostics: return "Reading diagnostics"
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
        case .supportCopySafeReport: return "Copy safe report"
        case .exportSafeReport: return "Export safe report…"
        case .supportCopyShapeReport: return "Copy vendor shape"
        case .cpuFact: return "CPU %d%%"
        case .stalledButComputing: return "Quiet transcript, busy process — computing"
        case .evidenceCPU: return "Compute"
        case .evidenceCPUUnknown: return "Not sampled yet — two ticks are needed before this is an answer."
        case .evidenceCPUHint: return "Busy with a quiet transcript is thinking, not stuck."
        case .evidenceMemory: return "Resident memory"
        case .supportShapeReading: return "Reading sessions…"
        case .supportShapeHint: return "Key names and value kinds only — never your text. Share it to get a parsing bug fixed."
        case .notifFocus: return "Go look"
        case .waitingSummaryTitle: return "%d agents need your attention"
        case .searchNoResults: return "No sessions match this search"
        case .updatePreview: return "Preview build · ad-hoc signed · not notarized"
        case .updateSignedUnnotarized: return "Developer ID signed · not notarized · Gatekeeper may block"
        case .qualityReasonProcessOnly: return "Only process evidence is available"
        case .qualityReasonCache: return "Vendor cache did not emit this field"
        case .qualityReasonCacheThin: return "Thin cache index — only partial facts available"
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
        case .trayScanIncomplete: return "The last read did not finish · open Health"
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
        case .currentStepFact: return "Step · %@"
        case .supportYield: return "Measured facts: %@"
        case .supportYieldDrifted:
            return "Structured adapter yielded rows but no core facts — the vendor format may have drifted"
        case .signalVendor: return "Claude reports"
        case .whyVendor: return "Red: Claude itself reports this session is waiting for %@"
        case .whyHook: return "Red: %@'s hook reported %@, %@"
        case .whyHookFront: return " — its window was in front, so no banner"
        case .whyPending: return "Red: %@'s session log shows it stopped at %@"
        case .whyTurn: return "Your turn: %@'s hook reported the turn ended, %@ — focus it or reply to clear"
        case .whyTimeline: return "What this session did"
        case .whyNoHistory: return "Nothing recorded for this session yet"
        case .doctorRun: return "Run self-check"
        case .doctorHint: return "Reads the Claude and Codex hook files and logs on this Mac, runs claude agents --json once, and says which contracts are proven here. Writes nothing; the copied report has no paths, prompts or session ids."
        case .yourTurn: return "Your turn"
        case .turnCount: return "%d your turn"
        case .jumpToTurn: return "Go to the next finished session"
        case .shortcutOff: return "Off"
        case .settingsHooksTitle: return "Claude & Codex hooks"
        case .settingsHooksTest: return "Test the connection"
        case .settingsPaneDataHeader: return "What Pulse may read"
        case .settingsPaneControlHeader: return "What Pulse may do"
        case .healthOpen: return "Open Health…"
        case .healthTitle: return "Health"
        case .healthSettingsHint: return "Self-check, what Pulse can read for each agent, and a report to copy."
        case .healthAgentsHeading: return "What Pulse can read, per agent"
        case .healthHideReport: return "Hide the report"
        case .healthShowReport: return "Show the report here"
        case .healthReport: return "Report"
        case .healthRunCheck: return "Run"
        case .healthRunAgain: return "Run again"
        case .doctorCopyReport: return "Copy self-check"
        case .lastReadJustNow: return "Read just now"
        case .lastReadAgo: return "Read %@ ago"
        case .readsLastHour: return "%d reads in the last hour"
        case .readsLastHourAvg: return "%d reads in the last hour, %d ms each"
        case .processOnlyHint: return "Only a running process was seen. Health shows what Pulse can read for this agent."
        case .cantRefreshHint: return "Pulse could not read processes or sessions on its last try. Retry, or open Health to see which reader failed."
        case .setupNotifications: return "Notifications"
        case .setupNotificationsDetail: return "So an agent that needs you can reach you while the tray is closed."
        case .setupHooksDetail: return "Optional. Adds the exact permission text and \"your turn\" for Claude Code and Codex."
        case .setupAppDataDetail: return "Optional. Cursor, VS Code and other editor agents keep their sessions in data macOS protects."
        case .setupReview: return "Review…"
        case .setupOtherAgents: return "Using another agent? See how it can tell Pulse it needs you…"
        case .whyProcessOnly: return "Only %@'s process is visible; there is no session file Pulse can read. Health shows why."
        case .whyStalled: return "No new activity for %@ — past your %d-minute stall threshold."
        case .whyStalledNoRule: return "No new activity for %@."
        case .whyStalledUnknown: return "Running, but Pulse has no clock for its activity."
        case .whyOutcome: return "The session's last run ended: %@."
        case .whyErrors: return "The agent reported %d error(s) in this session."
        case .inspectorHowPulseSees: return "How Pulse reads this session"
        case .updateFailedBadFeed: return "Update feed address is invalid"
        case .updateFailedNetwork: return "Could not reach GitHub"
        case .updateFailedHTTP: return "GitHub answered %d"
        case .updateFailedBadResponse: return "GitHub's answer was not a release"
        case .updateFailedNoTag: return "The latest release has no version tag"
        case .staleHidden: return "%d older session(s) not shown (%@)"
        case .waitingBannerFailed: return "macOS did not show the last “needs you” banner — check Notifications"
        case .lampRuleBlocked: return "Red: an agent is waiting on you."
        case .lampRuleStalled: return "Orange: a running session has gone quiet past your stall threshold."
        case .lampRuleThin: return "Orange: something is running that Pulse can only see as a process."
        case .lampRuleRunning: return "Green: agents are working and nothing needs you."
        case .lampRuleTurn: return "Grey: a turn ended — your move when you are ready."
        case .lampRuleRecent: return "Grey: nothing running; recent sessions are listed."
        case .lampRuleIdle: return "Grey: no coding agent is running."
        case .lampRuleCantRefresh: return "Orange: Pulse could not read processes or sessions on its last try."
        case .lampLeftStale: return "%d older not shown"
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
        case .muteAgent: return "Mute %@"
        case .unmuteAgent: return "Unmute %@"
        case .detailLastWords: return "Last words"
        case .detailPlanHeading: return "Plan"
        case .detailNotificationHeading: return "Notification"
        case .detailBack: return "Back"
        case .detailLastHour: return "Last hour:"
        case .detailMinutesIn: return "%d min %@"
        case .filterMatches: return "%d matches"
        case .trayKeyHints: return "↑↓ select · ↩ focus · → details · ⌫ dismiss · type to filter"
        case .setupTerminalFocus: return "Jump to the exact terminal tab"
        case .setupTerminalFocusDetail: return "So ↩ lands in the tab that is waiting. macOS asks once for Automation access."
        case .setupTurnOn: return "Turn on"
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
        case .explainStalled: return "No new output for %@ — past your %d-minute stall threshold"
        case .explainStalledNoRule: return "No new output for %@"
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
        case .doctorClaudeHooks: return "Claude hooks installed"
        case .doctorClaudeFired: return "Claude hooks reach Pulse"
        case .doctorCodexHooks: return "Codex hooks installed"
        case .doctorCodexFired: return "Codex hooks reach Pulse"
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
        case .doctorInstallHooks: return "Settings → Waiting signals → Install hooks"
        case .doctorReinstallHooks: return "Reinstall hooks from Settings to pick up this version's events"
        case .doctorMissing: return "Missing: %@"
        case .doctorAllEvents: return "All %d events, questions included"
        case .doctorNeverFired: return "No hook event recorded in the last day"
        case .doctorUseOnceCodex: return "Finish one Codex turn; if nothing arrives, run /hooks in Codex and trust Pulse's hooks"
        case .doctorUseOnceClaude: return "Finish one Claude turn, then run the self-check again"
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
        case .doctorCodexPermissionHook: return "A PermissionRequest hook is installed; it fires before Codex's own review and would show waits that are not real"
        case .doctorNotifyOnly: return " (the older notify hook is present)"
        case .doctorCodexNeedsTrust: return "Stop and UserPromptSubmit are installed; whether Codex trusts them only shows once one fires"
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
        case .recent1: return "1 个最近会话"
        case .recentN: return "最近"
        case .justNow: return "刚刚"
        case .notYet: return "尚未更新"
        case .cantRefresh: return "无法刷新"
        case .andMore: return "另有 %d 个…"
        case .showLess: return "收起"
        case .refresh: return "刷新"
        case .clearWaiting: return "清除等待"
        case .settings: return "偏好设置…"
        case .quit: return "退出 Pulse"
        case .focusTerminal: return "聚焦终端"
        case .general: return "通用"
        case .agentDataAccess: return "读取应用数据以展示更多详情"
        case .agentDataAccessHint: return "默认关闭。开启后会深入扫描 Cursor / VS Code / Warp，macOS 可能会请求访问其他应用的数据。"
        case .agentDataAccessSkipHint: return "跳过后仍会读取进程和未受保护的会话证据；不会弹出权限请求。"
        case .notifyWaiting: return "新的「需要你」时通知"
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
        case .signalHooks: return "Hook 报告"
        case .signalPending: return "会话记录"
        case .launchAtLogin: return "登录时启动"
        case .language: return "语言"
        case .waitingSignals: return "等待信号"
        case .hooksHint: return "安装 Claude/Codex hooks 后，Pulse 才能显示权限、输入等待与 subagent 生命周期。原生通路，无需 Python。"
        case .installHooks: return "安装连接"
        case .testWaitingSignal: return "测试连接"
        case .hookTestIdle: return "尚未测试"
        case .hookTestRunning: return "测试中…"
        case .hookTestPassed: return "连接测试通过"
        case .hookTestFailed: return "连接测试失败"
        case .shortcuts: return "快捷键"
        case .globalShortcutHint: return "默认关闭。启用后会注册系统级快捷键，未签名版本可能触发 macOS 自动化权限请求。"
        case .agents: return "Agent"
        case .running: return "运行中"
        case .settingsTitle: return "Pulse 偏好设置"
        case .recent: return "最近"
        case .dismissWait: return "忽略等待"
        case .focusFailed: return "没能打开 —— 那个窗口可能已经不在了，正在重扫"
        case .hooksNudge: return "为 Claude 和 Codex 安装 hooks，就能看到确切的请求内容和「轮到你」"
        case .waitingSignalNudge:
            return "有个 Agent 在运行，但它没法告诉 Pulse「需要你」—— 看看怎么接上"
        case .hooksUnknown: return "未检查"
        case .hooksMissing: return "未安装"
        case .hooksInstalledBoth: return "已安装 · Claude + Codex"
        case .hooksInstalledClaude: return "已安装 · Claude"
        case .hooksInstalledCodex: return "已安装 · Codex"
        case .hooksFailed: return "失败"
        case .kindPermission: return "需要授权"
        case .kindInput: return "等待输入"
        case .kindWaiting: return "等待中"
        case .idleWord: return "空闲"
        case .processDetected: return "检测到进程"
        case .processCount: return "%d 个进程"
        case .limitedData: return "仅进程"
        case .sessionEvidence: return "结构化会话"
        case .cacheEvidence: return "本地缓存"
        case .terminalSession: return "终端会话正在运行"
        case .appSession: return "Agent 应用正在运行"
        case .processAge: return "进程始于%@前"
        case .activityChanged: return "刚刚变化 · %@"
        case .newErrors: return "新增 %d 个错误"
        case .newFiles: return "新增 %d 个文件"
        case .progressAdvanced: return "进度推进至 %d/%d"
        case .modelCallChanged: return "新的模型调用"
        case .toolChanged: return "工具已切换"
        case .phaseChanged: return "阶段已变化"
        case .taskChanged: return "目标已更新"
        case .signalProgress: return "进度 %d/%d"
        case .signalErrors: return "+%d 个错误"
        case .signalFiles: return "+%d 个文件"
        case .signalModel: return "模型调用"
        case .signalTool: return "工具"
        case .signalPhase: return "阶段"
        case .signalTask: return "目标"
        case .signalCompleted: return "已完成"
        case .signalFailed: return "失败"
        case .signalCancelled: return "已取消"
        case .terminalDetectedNoDetails: return "终端会话正在运行 · 暂无活动数据"
        case .appDetectedNoDetails: return "Agent 应用正在运行 · 暂无会话数据"
        case .lastAction: return "最近动作：%@"
        case .lastActive: return "最近活动：%@"
        case .latestCallTokens: return "最近一次模型调用 · 输入 %@ · 输出 %@"
        case .reportedTokens: return "Agent 上报 · 输入 %@ · 输出 %@"
        case .latestCallTokensIn: return "最近一次模型调用 · 输入 %@"
        case .latestCallTokensOut: return "最近一次模型调用 · 输出 %@"
        case .reportedTokensIn: return "Agent 上报 · 输入 %@"
        case .reportedTokensOut: return "Agent 上报 · 输出 %@"
        case .compactTokensIn: return "↑%@"
        case .compactTokensOut: return "↓%@"
        case .compactTokens: return "↑%@ ↓%@"
        case .subagentsActive: return "%d / %d 个 subagent 活跃"
        case .subagentsObserved: return "已观测 %d 个 subagent"
        case .subChipActive: return "子任务 %d↑"
        case .subChipObserved: return "子任务 %d"
        case .actionPlanning: return "规划"
        case .actionCommand: return "执行命令"
        case .actionEditing: return "编辑文件"
        case .actionImage: return "查看图片"
        case .actionResearch: return "检索资料"
        case .actionReading: return "读取文件"
        case .actionAutomation: return "自动化操作"
        case .setupWaitingSignals: return "接入「需要你」…"
        case .about: return "关于"
        case .tagline: return "编码 Agent 状态灯"
        case .build: return "构建"
        case .runningFrom: return "运行位置"
        case .devBuild: return "开发构建"
        case .copyDiagnostics: return "复制诊断信息"
        case .copied: return "已复制"
        case .versionStale: return "版本不一致"
        case .versionMismatchHint: return "程序版本为 %@，但 app 包标记为 %@ — 请用 PulseBar/Scripts/package.sh 重新打包。"
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
        case .uninstallHooks: return "移除连接"
        case .revealShortcut: return "唤出 Pulse"
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
        case .a11yUnknown: return "未知"
        case .a11yPresent: return "有"
        case .a11yIdle: return "空闲"
        case .a11yRunning: return "运行中"
        case .a11yStalled: return "已停滞"
        case .a11yWaiting: return "需要你处理"
        case .a11yError: return "无法刷新"
        case .sectionNeedsYou: return "需要你"
        case .sectionRunning: return "运行中"
        case .sectionStalled: return "停滞"
        case .sectionRecent: return "最近"
        case .jumpToOldest: return "跳到等待最久的"
        case .moreActions: return "更多操作"
        case .acrossProjects: return "%d 个项目"
        case .agoFormat: return "%@前"
        case .noActivityYet: return "暂无动静"
        case .stalled: return "停滞"
        case .stalledFor: return "已 %@ 无活动"
        case .supportHealth: return "健康检查…"
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
        case .supportAction: return "最近动作"
        case .supportModel: return "模型"
        case .supportEvidence: return "证据"
        case .session: return "会话"
        case .detailTool: return "工具"
        case .detailSkill: return "技能"
        case .detailPhase: return "阶段"
        case .detailOutcome: return "结果"
        case .detailEvidence: return "证据"
        case .detailErrors: return "错误"
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
        case .supportWaitingNoneDetail: return "不能主动报告「需要你」—— 可以通过 Attention 桥接入"
        case .supportDepthSession: return "深度：会话记录"
        case .supportDepthCacheThin: return "只读到部分缓存"
        case .supportDepthCachePartial: return "深度：缓存事实（有限）"
        case .supportDepthWaitingNone: return "不能报告「需要你」—— 可通过 Attention 桥接入"
        case .supportSharedCursor: return "Cursor Agent 与此适配器共用"
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
        case .supportSearch: return "搜索 Agent"
        case .supportFilterAll: return "全部"
        case .supportNoFilterResults: return "当前筛选条件下没有 Agent"
        case .supportNeedsAction: return "需要处理"
        case .supportLimited: return "信息受限"
        case .supportAvailable: return "可用"
        case .supportNotInstalled: return "未安装"
        case .supportNoRecentSession: return "无近期会话"
        case .supportPermissionDenied: return "权限不足"
        case .supportUnscanned: return "未扫描"
        case .supportSummaryLine:
            return "可用 %d · 需要处理 %d · 信息受限 %d · 未安装 %d · 无近期会话 %d · 权限不足 %d · 未扫描 %d"
        case .supportNeedsActionCount: return "待处理 · %d"
        case .supportLimitedCount: return "受限 · %d"
        case .supportAvailableCount: return "可用 · %d"
        case .supportNotInstalledCount: return "未安装 · %d"
        case .supportNoRecentCount: return "无近期 · %d"
        case .supportPermissionDeniedCount: return "权限 · %d"
        case .supportUnscannedCount: return "未扫描 · %d"
        case .supportUsefulCoverage: return "有效信号 %d/%d"
        case .supportRetry: return "重新扫描"
        case .supportRunAgent: return "先运行一次这个 Agent"
        case .supportEnableData: return "开启应用数据读取"
        case .supportAdapterDiagnostics: return "读取诊断"
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
        case .supportCopySafeReport: return "复制安全报告"
        case .exportSafeReport: return "导出安全报告…"
        case .supportCopyShapeReport: return "复制厂商格式"
        case .cpuFact: return "CPU %d%%"
        case .stalledButComputing: return "记录不动，进程在跑 —— 它在算"
        case .evidenceCPU: return "计算量"
        case .evidenceCPUUnknown: return "还没采到 —— 要两拍才能得出答案，不是 0。"
        case .evidenceCPUHint: return "在算但记录不动 = 在想，不是卡住。"
        case .evidenceMemory: return "常驻内存"
        case .supportShapeReading: return "正在读会话…"
        case .supportShapeHint: return "只有键名与值的类型，不含你的任何文字。发它就能修解析。"
        case .notifFocus: return "去看看"
        case .waitingSummaryTitle: return "%d 个 Agent 需要你处理"
        case .searchNoResults: return "没有匹配的会话"
        case .updatePreview: return "预览版 · ad-hoc 签名 · 未公证"
        case .updateSignedUnnotarized: return "已用 Developer ID 签名 · 未公证 · Gatekeeper 可能拦截"
        case .qualityReasonProcessOnly: return "目前只有进程证据"
        case .qualityReasonCache: return "厂商缓存未写出该字段"
        case .qualityReasonCacheThin: return "只读到部分缓存 —— 事实不全"
        case .qualityReasonNotEmitted: return "本地会话记录中没有该字段"
        case .qualityReasonWaitingNoDetail: return "正在等待，但没有详细原因"
        case .qualityReasonScanTimeout: return "读取本地数据超时"
        case .qualityNextOpenAgent: return "打开该 Agent 查看完整会话"
        case .qualityNextWaitCache: return "继续使用该 Agent，等待本地缓存补齐"
        case .qualityNextAttentionBridge: return "接入 Attention 桥，才能报告「需要你」"
        case .qualityNextRetryScan: return "在支持健康度中重试扫描"
        case .supportFailureTimelineEntry: return "最近失败 · %@ · %@前"
        case .qualityConfidenceHigh: return "高可信"
        case .qualityConfidenceMedium: return "中等可信"
        case .qualityConfidenceLow: return "低可信"
        case .trayScanIncomplete: return "上次读取没有完成 · 打开健康检查"
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
        case .currentStepFact: return "当前步骤 · %@"
        case .supportYield: return "实测事实：%@"
        case .supportYieldDrifted:
            return "声明结构化、本拍有行却零核心事实 —— 厂商格式可能已漂移"
        case .signalVendor: return "Claude 自报"
        case .whyVendor: return "红灯：Claude 自己报告这个会话在等「%@」"
        case .whyHook: return "红灯：%@ 的 hook 报告了「%@」· %@"
        case .whyHookFront: return " —— 当时提示窗口就在最前，所以没有通知"
        case .whyPending: return "红灯：%@ 的会话记录显示它停在「%@」上"
        case .whyTurn: return "轮到你：%@ 的 hook 报告回合结束 · %@ —— 聚焦或回复它即消失"
        case .whyTimeline: return "这个会话的经过"
        case .whyNoHistory: return "这个会话还没有记录"
        case .doctorRun: return "运行自检"
        case .doctorHint: return "读取这台 Mac 上 Claude 与 Codex 的 hook 文件和记录，运行一次 claude agents --json，说明哪些约定在这里已被证实。不写任何东西；复制出的报告不含路径、提示词或会话 id。"
        case .yourTurn: return "轮到你"
        case .turnCount: return "%d 轮到你"
        case .jumpToTurn: return "跳到做完的会话"
        case .shortcutOff: return "关闭"
        case .settingsHooksTitle: return "Claude 与 Codex 的 hooks"
        case .settingsHooksTest: return "测试连接"
        case .settingsPaneDataHeader: return "Pulse 可以读取的内容"
        case .settingsPaneControlHeader: return "Pulse 可以做的事"
        case .healthOpen: return "打开健康检查…"
        case .healthTitle: return "健康检查"
        case .healthSettingsHint: return "自检、每个 Agent 能读到什么，以及可复制的报告。"
        case .healthAgentsHeading: return "每个 Agent：Pulse 能读到什么"
        case .healthHideReport: return "收起报告"
        case .healthShowReport: return "在此显示报告"
        case .healthReport: return "报告"
        case .healthRunCheck: return "运行"
        case .healthRunAgain: return "重新运行"
        case .doctorCopyReport: return "复制自检结果"
        case .lastReadJustNow: return "刚刚读取"
        case .lastReadAgo: return "%@前读取"
        case .readsLastHour: return "过去一小时读取 %d 次"
        case .readsLastHourAvg: return "过去一小时读取 %d 次，每次 %d 毫秒"
        case .processOnlyHint: return "只看到一个运行中的进程。「健康检查」里能看到 Pulse 对这个 Agent 能读到什么。"
        case .cantRefreshHint: return "Pulse 上一次没能读取进程和会话。可以重试，或打开「健康检查」看是哪一路读取失败。"
        case .setupNotifications: return "通知"
        case .setupNotificationsDetail: return "面板关着的时候，需要你的 Agent 也能提醒到你。"
        case .setupHooksDetail: return "可选。为 Claude Code 和 Codex 增加确切的权限请求内容和「轮到你」。"
        case .setupAppDataDetail: return "可选。Cursor、VS Code 等编辑器里的 Agent 把会话存在 macOS 保护的数据里。"
        case .setupReview: return "查看…"
        case .setupOtherAgents: return "用的是其他 Agent？看看它如何告诉 Pulse「需要你」…"
        case .whyProcessOnly: return "只能看到 %@ 的进程，没有 Pulse 能读的会话文件。「健康检查」里有原因。"
        case .whyStalled: return "已经 %@ 没有新动静 —— 超过你设的 %d 分钟停滞阈值。"
        case .whyStalledNoRule: return "已经 %@ 没有新动静。"
        case .whyStalledUnknown: return "在运行，但 Pulse 读不到它的活动时间。"
        case .whyOutcome: return "这个会话上一次运行的结果：%@。"
        case .whyErrors: return "Agent 在这个会话里报告了 %d 个错误。"
        case .inspectorHowPulseSees: return "Pulse 如何读取这个会话"
        case .updateFailedBadFeed: return "更新源地址无效"
        case .updateFailedNetwork: return "无法连接 GitHub"
        case .updateFailedHTTP: return "GitHub 返回 %d"
        case .updateFailedBadResponse: return "GitHub 返回的不是发布信息"
        case .updateFailedNoTag: return "最新发布没有版本标签"
        case .staleHidden: return "%d 个较早的会话未显示（%@）"
        case .waitingBannerFailed: return "macOS 没有显示上一条「需要你」的通知 —— 请检查通知设置"
        case .lampRuleBlocked: return "红：有 Agent 在等你。"
        case .lampRuleStalled: return "橙：有会话运行中但超过停滞阈值没有动静。"
        case .lampRuleThin: return "橙：有 Agent 在运行，但 Pulse 只看到进程。"
        case .lampRuleRunning: return "绿：Agent 在工作，没有需要你的事。"
        case .lampRuleTurn: return "灰：有回合结束了，轮到你（不急）。"
        case .lampRuleRecent: return "灰：没有在运行的；列出的是最近的会话。"
        case .lampRuleIdle: return "灰：没有在运行的编码 Agent。"
        case .lampRuleCantRefresh: return "橙：Pulse 上一次没能读取进程和会话。"
        case .lampLeftStale: return "%d 个较早的未显示"
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
        case .muteAgent: return "静音 %@"
        case .unmuteAgent: return "取消静音 %@"
        case .detailLastWords: return "最后说的话"
        case .detailPlanHeading: return "计划"
        case .detailNotificationHeading: return "通知"
        case .detailBack: return "返回"
        case .detailLastHour: return "最近一小时："
        case .detailMinutesIn: return "%d 分钟 %@"
        case .filterMatches: return "%d 个匹配"
        case .trayKeyHints: return "↑↓ 选择 · ↩ 聚焦 · → 详情 · ⌫ 忽略 · 直接打字筛选"
        case .setupTerminalFocus: return "跳到确切的终端标签页"
        case .setupTerminalFocusDetail: return "这样按 ↩ 就会落到正在等你的那个标签页。macOS 会请求一次「自动化」权限。"
        case .setupTurnOn: return "开启"
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
        case .explainStalled: return "已经 %@ 没有新输出——超过你设的 %d 分钟停滞阈值"
        case .explainStalledNoRule: return "已经 %@ 没有新输出"
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
        case .doctorClaudeHooks: return "Claude hooks 已安装"
        case .doctorClaudeFired: return "Claude hooks 到达 Pulse"
        case .doctorCodexHooks: return "Codex hooks 已安装"
        case .doctorCodexFired: return "Codex hooks 到达 Pulse"
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
        case .doctorInstallHooks: return "设置 → 等待信号 → 安装 hooks"
        case .doctorReinstallHooks: return "在设置里重新安装 hooks，以获得这一版的事件"
        case .doctorMissing: return "缺少：%@"
        case .doctorAllEvents: return "全部 %d 个事件，含提问"
        case .doctorNeverFired: return "最近一天没有记录到 hook 事件"
        case .doctorUseOnceCodex: return "在 Codex 里完成一轮；若仍没有，在 Codex 里运行 /hooks 并信任 Pulse 的 hooks"
        case .doctorUseOnceClaude: return "在 Claude 里完成一轮后再自检一次"
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
        case .doctorCodexPermissionHook: return "装了 PermissionRequest hook；它在 Codex 自己审批之前触发，会显示并不存在的等待"
        case .doctorNotifyOnly: return "（仍有旧的 notify hook）"
        case .doctorCodexNeedsTrust: return "Stop 与 UserPromptSubmit 已安装；Codex 是否信任它们，要等触发一次才知道"
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
        }
    }

    /// `CaseIterable` so tests can assert every key resolves in both languages
    /// and that format specifiers match (a mismatched %d crashes String(format:)).
    enum Key: CaseIterable {
        case noAgents, noAgentsDetected, needsYou, waitingN, runningN
        case recent1, recentN, recent, idleWord
        case justNow, notYet, cantRefresh, andMore, showLess
        case refresh, clearWaiting, settings, quit
        case focusTerminal, focusTTY, focusWarp, focusHostWorkspace, focusHostApp, focusOpenTray, dismissWait
        case focusFailed
        case allowTerminalAutomation, allowTerminalAutomationHint
        case supportFocusNone, supportFocusWarp, supportFocusHostWorkspace, supportFocusHost, supportFocusTTY, supportFocusTTYNeedsOptIn
        case supportDepthSession, supportDepthCacheThin, supportDepthCachePartial, supportDepthWaitingNone
        case general, agentDataAccess, agentDataAccessHint, agentDataAccessSkipHint, notifyWaiting, launchAtLogin, language
        case waitingSignals, hooksHint, installHooks, testWaitingSignal
        case hookTestIdle, hookTestRunning, hookTestPassed, hookTestFailed
        case shortcuts, globalShortcutHint
        case agents, running, settingsTitle
        case hooksNudge, waitingSignalNudge, hooksUnknown, hooksMissing, hooksInstalledBoth
        case hooksInstalledClaude, hooksInstalledCodex, hooksFailed
        case kindPermission, kindInput, kindWaiting
        case signalHooks, signalPending
        case processDetected, processCount
        case limitedData, sessionEvidence, cacheEvidence, terminalSession, appSession, processAge
        case activityChanged, newErrors, newFiles, progressAdvanced, modelCallChanged
        case toolChanged, phaseChanged, taskChanged
        case signalProgress, signalErrors, signalFiles, signalModel, signalTool, signalPhase, signalTask
        case signalCompleted, signalFailed, signalCancelled
        case terminalDetectedNoDetails, appDetectedNoDetails
        case lastAction, lastActive, latestCallTokens, reportedTokens, compactTokens
        case latestCallTokensIn, latestCallTokensOut
        case reportedTokensIn, reportedTokensOut
        case compactTokensIn, compactTokensOut
        case subagentsActive, subagentsObserved, subChipActive, subChipObserved
        case actionPlanning, actionCommand, actionEditing, actionImage
        case actionResearch, actionReading, actionAutomation, setupWaitingSignals
        case about, tagline, build, runningFrom, devBuild, copyDiagnostics, copied
        case versionStale, versionMismatchHint
        case cancel
        case durNow, durSec, durMin, durHour
        case notificationsSection, notifyNotConfigured, waitingNotifyNotConfigured
        case enableNotifications, notifyDenied, notifyDeniedPersistentHint, waitingNotifyDenied, openNotificationSettings
        case uninstallHooks
        case revealShortcut, hotkeyTaken
        case cappedSessions, emptyHint
        case checkForUpdates, checkNow, openRelease
        case updateIdle, updateChecking, updateCurrent, updateCurrentPrerelease, updateCurrentStable
        case updateAvailable, updateFailed
        case probeEvery, probeParked
        case a11yIdle, a11yRunning, a11yStalled, a11yWaiting, a11yError
        case a11yUnknown, a11yPresent
        case sectionNeedsYou, sectionRunning, sectionStalled, sectionRecent
        case jumpToOldest
        case moreActions
        case acrossProjects, agoFormat
        case noActivityYet
        case stalled, stalledFor
        case supportHealth, supportScanIncomplete, supportScanIncompleteTimeout
        case supportNotDetected, supportStructured, supportCache, supportProcess, supportDetected
        case supportGoal, supportWorkspace, supportActivity, supportProgress, supportAction, supportModel, supportEvidence, session
        case detailTool, detailSkill, detailPhase, detailOutcome, detailEvidence, detailErrors
        case supportResources, supportObservedSignals, supportNoObservedSignals, skillFact, supportLastRead, supportMissing
        case supportMissingFeed, supportMissingGoal, supportMissingWorkspace
        case supportMissingWaiting
        case supportWaitingHooks, supportWaitingHarvest, supportWaitingNone, supportWaitingNoneDetail, supportSharedCursor
        case supportLastSignal, supportDetectedExecutable, supportDetectedPath, supportFactCoverage
        case supportCollectorObserved
        case supportCollectorSourceAbsent, supportCollectorSourceAbsentDetail
        case supportCollectorPrivacyLimited, supportCollectorPrivacyLimitedDetail
        case supportCollectorNoSessions, supportCollectorNoSessionsDetail
        case supportCollectorPermission, supportCollectorPermissionDetail
        case supportCollectorSchema, supportCollectorSchemaDetail
        case supportCollectorFailed, supportCollectorFailedDetail
        case supportCollectorUnscanned, supportCollectorUnscannedDetail
        case supportSearch
        case supportFilterAll, supportNoFilterResults
        case supportNeedsAction, supportLimited, supportAvailable, supportNotInstalled, supportNoRecentSession, supportPermissionDenied, supportUnscanned
        case supportSummaryLine
        case supportNeedsActionCount, supportLimitedCount, supportAvailableCount, supportNotInstalledCount, supportNoRecentCount, supportPermissionDeniedCount, supportUnscannedCount, supportUsefulCoverage
        case supportRetry, supportRunAgent, supportEnableData, supportAdapterDiagnostics, supportCopySafeReport, exportSafeReport
        case supportExplainFiles, supportExplainFacts, supportExplainTruncated
        case supportExplainHero, supportExplainEmpty
        case supportEmptyNoSource, supportEmptyDeadline, supportEmptyNoReadableFile
        case supportEmptyNoParsableRecord, supportEmptyNoDisplaySignal, supportEmptyNoUserGoal
        case supportOriginChrome, supportOriginFallbackText, supportOriginCacheTitle
        case supportOriginToolTitle, supportOriginUserPrompt, supportOriginSessionName
        case supportCopyShapeReport, supportShapeReading, supportShapeHint
        case cpuFact, evidenceCPU, evidenceCPUUnknown, evidenceCPUHint, evidenceMemory
        case stalledButComputing
        case notifFocus
        case recordsSuffix, sessionAge, waitingSummaryTitle, searchNoResults
        case updatePreview, updateSignedUnnotarized
        case qualityReasonProcessOnly, qualityReasonCache, qualityReasonCacheThin, qualityReasonNotEmitted, qualityReasonWaitingNoDetail
        case qualityReasonScanTimeout
        case qualityNextOpenAgent, qualityNextWaitCache, qualityNextAttentionBridge, qualityNextRetryScan
        case supportFailureTimelineEntry
        case qualityConfidenceHigh, qualityConfidenceMedium, qualityConfidenceLow
        case phaseResponding, phaseTurnComplete, phaseWaitingPermission, phasePlanning, phaseWorking, phaseTesting
        case phaseBuilding, phasePublishing
        case nowActivity, outcomeActivity
        case modelFact, errorFactOne, errorsFact, outcomeFailed, outcomeCancelled
        case filesFact, contextFact, progressFact, turnsFact
        case currentStepFact
        case supportYield, supportYieldDrifted
        case trayScanIncomplete
        case yourTurn, turnCount, jumpToTurn
        case whyHook, whyHookFront, whyPending, whyTurn, whyVendor, signalVendor
        case whyTimeline, whyNoHistory
        case doctorRun, doctorHint
        case shortcutOff
        case settingsHooksTitle
        case settingsHooksTest
        case settingsPaneDataHeader
        case settingsPaneControlHeader
        case healthOpen
        case healthTitle
        case healthSettingsHint
        case healthAgentsHeading
        case healthHideReport
        case healthShowReport
        case healthReport
        case healthRunCheck
        case healthRunAgain
        case doctorCopyReport
        case lastReadJustNow
        case lastReadAgo
        case readsLastHour
        case readsLastHourAvg
        case processOnlyHint
        case cantRefreshHint
        case setupNotifications
        case setupNotificationsDetail
        case setupHooksDetail
        case setupAppDataDetail
        case setupReview
        case setupOtherAgents
        case whyProcessOnly
        case whyStalled
        case whyStalledNoRule
        case whyStalledUnknown
        case whyOutcome
        case whyErrors
        case inspectorHowPulseSees
        case updateFailedBadFeed
        case updateFailedNetwork
        case updateFailedHTTP
        case updateFailedBadResponse
        case updateFailedNoTag
        case staleHidden
        case waitingBannerFailed
        case lampRuleBlocked
        case lampRuleStalled
        case lampRuleThin
        case lampRuleRunning
        case lampRuleTurn
        case lampRuleRecent
        case lampRuleIdle
        case lampRuleCantRefresh
        case lampLeftStale
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
        case muteAgent
        case unmuteAgent
        case detailLastWords
        case detailPlanHeading
        case detailNotificationHeading
        case detailBack
        case detailLastHour
        case detailMinutesIn
        case filterMatches
        case trayKeyHints
        case setupTerminalFocus
        case setupTerminalFocusDetail
        case setupTurnOn
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
        case explainStalledNoRule
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
        case doctorClaudeHooks
        case doctorClaudeFired
        case doctorCodexHooks
        case doctorCodexFired
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
        case doctorUseOnceClaude
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
        case doctorCodexPermissionHook
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
