import Foundation
import AppKit

@MainActor
final class StatusStore: ObservableObject {
    @Published private(set) var snapshot = PulseSnapshot()
    @Published var autoProbe = true
    @Published var notifyOnIdle = true
    @Published var notifyOnWaiting = true
    /// Quiet hours suppress idle notify only; Waiting edges still fire when notifyOnWaiting.
    @Published var quietHoursEnabled = false
    /// Minutes since midnight — whole hours were too coarse for a 22:30 bedtime.
    @Published var quietStartMinute: Int = 22 * 60
    @Published var quietEndMinute: Int = 8 * 60
    @Published var launchAtLogin = false
    @Published var language: AppLanguage = .auto
    @Published var hooksStatus: HooksSupport.Status = .unknown
    @Published var showAllAgents = false
    @Published private(set) var isRefreshing = false
    /// Transient "Copied" confirmation on the diagnostics button.
    @Published private(set) var didCopyDiagnostics = false
    /// Agents the user muted — no notifications, still shown in the tray.
    @Published var mutedAgents: Set<AgentID> = []
    @Published var hotkey: HotkeyChoice = .commandShiftP
    /// False when the system refused the shortcut (another app owns it).
    @Published private(set) var hotkeyRegistered = true
    @Published var updateCheckEnabled = true
    @Published var updateStatus: UpdateCheck.Status = .idle
    /// Notification authorization — a denied prompt used to fail silently.
    @Published private(set) var notifyAuthorized: Bool?
    /// Waits that have already been resolved, newest first (P1-H).
    @Published private(set) var waitHistory: [ResolvedWait] = []

    /// A Waiting row that is no longer waiting — "did I miss something?".
    struct ResolvedWait: Identifiable, Equatable {
        var id: String { "\(rowKey)|\(Int(resolvedAt.timeIntervalSince1970))" }
        var rowKey: String
        var agent: AgentID
        var title: String
        var kind: String
        var project: String
        var resolvedAt: Date
        var waitedSeconds: Double
    }

    /// Sessions kept per agent. Was hardcoded to 2, which made the third
    /// concurrent Claude invisible with no hint that anything was dropped.
    static let maxSessionsPerAgent = 4
    /// Rows shown before the "and N more" fold.
    static let maxVisibleRows = 5

    private var timer: Timer?
    private var cachedAll: [AgentRow] = []
    private var lastGoodHarvest: [ActivityHarvest.Row] = []
    private let powerMonitor = PowerMonitor()
    /// Tray panel is on screen — worth probing faster while the user reads it.
    private var trayOpen = false
    private var activity: ProbeSchedule.Activity = .empty
    private var currentInterval: TimeInterval?
    /// Live-process fingerprint; a change forces a harvest even off-cadence.
    private var lastProcessSignature = ""
    private var ticksSinceHarvest = Int.max
    /// Last value actually pushed to launchd — avoids re-running launchctl
    /// (two synchronous subprocesses) on every settings write.
    private var appliedLaunchAtLogin: Bool?
    private var knownWaitingKeys: Set<String> = []
    /// First apply seeds waiting keys without firing edge notifications.
    private var waitingNotifySeeded = false
    /// Soft-dismissed Cursor harvest pending until skill clears.
    private var dismissedPendingKeys: Set<String> = []
    private let attentionWatcher = AttentionWatcher()
    private let scanQueue = DispatchQueue(label: "com.pulse.scan", qos: .userInitiated)
    private var scanTicket: UInt64 = 0
    private var lastAppliedTicket: UInt64 = 0
    private var scanInFlight = false
    private var pendingRefreshReason: String?
    private let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var lang: ResolvedLanguage { language.resolved }

    func tr(_ key: L10n.Key) -> String { L10n.t(key, lang) }

    /// Claude/Codex live but hooks not wired — tray nudge only.
    var needsHooksNudge: Bool {
        guard hooksStatus == .missing || hooksStatus == .unknown else { return false }
        return cachedAll.contains {
            $0.liveProcess && ($0.agent == .claude || $0.agent == .codex)
        }
    }

    /// Live agent with no Waiting path (not hooks-dependent) — one-line honesty, not a HUD.
    var needsWaitingSignalNudge: Bool {
        if needsHooksNudge { return false }
        return cachedAll.contains {
            $0.liveProcess && $0.agent.waitingSource == .none && !$0.waiting
        }
    }

    /// Packaged bundle version disagrees with the compiled semver — usually a
    /// stale `Pulse.app` next to a fresh build. Worth saying out loud.
    var isVersionMismatch: Bool {
        if case .mismatch = PulseVersion.channel { return true }
        return false
    }

    /// Everything a bug report needs, in one paste.
    func diagnosticsText() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var lines: [String] = [
            PulseVersion.fingerprint,
            "channel: \(isVersionMismatch ? "mismatch" : (PulseVersion.bundleVersion == nil ? "dev" : "release"))",
            "macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "lang: \(language.rawValue) · autoProbe: \(autoProbe)",
            "hooks: \(hooksStatus.label(lang: lang))",
            "glance: \(snapshot.glance) · rows: \(snapshot.rows.count)/\(snapshot.totalCount)",
        ]
        if let err = snapshot.probeError { lines.append("probeError: \(err)") }
        for row in cachedAll.prefix(8) {
            lines.append(
                "  \(row.agent.rawValue) waiting=\(row.waiting) live=\(row.liveProcess) "
                    + "signal=\(row.waitSignal?.rawValue ?? "-") sub=\(row.subRunning)/\(row.subTotal)"
            )
        }
        return lines.joined(separator: "\n")
    }

    func copyDiagnostics() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(diagnosticsText(), forType: .string)
        didCopyDiagnostics = true
        DebugLog.write("diagnostics copied")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            self?.didCopyDiagnostics = false
        }
    }

    func start() {
        DebugLog.write("start begin \(PulseVersion.fingerprint)")
        HooksSupport.seedAssets()
        hooksStatus = HooksSupport.probeStatus()
        loadSettings()
        applyHotkey()
        PulseNotify.configure { [weak self] granted in
            Task { @MainActor in
                self?.notifyAuthorized = granted
                DebugLog.write("notify authorization granted=\(granted)")
            }
        }
        refresh(reason: "start")
        rescheduleTimer()
        attentionWatcher.start { [weak self] in
            Task { @MainActor in
                self?.refresh(reason: "attention")
            }
        }
        powerMonitor.start { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.rescheduleTimer()
                // Coming back from sleep/lock: catch up immediately.
                if !self.powerMonitor.state.parked { self.refresh(reason: "wake") }
            }
        }
        UpdateCheck.shared.startIfEnabled(store: self)
        DebugLog.write("start armed auto=\(autoProbe)")
    }

    /// launchctl unload+load are two blocking subprocesses; never run them on
    /// the main thread, and never run them when nothing changed.
    private func applyLaunchAtLoginIfChanged() {
        guard appliedLaunchAtLogin != launchAtLogin else { return }
        appliedLaunchAtLogin = launchAtLogin
        let enabled = launchAtLogin
        DispatchQueue.global(qos: .utility).async {
            LoginItem.setEnabled(enabled)
        }
    }

    /// Tray panel appeared — probe faster while the user is looking at it.
    func trayDidAppear() {
        trayOpen = true
        rescheduleTimer()
        refresh(reason: "trayOpen")
    }

    func trayDidDisappear() {
        trayOpen = false
        rescheduleTimer()
    }

    /// Current cadence, for Settings/diagnostics ("probing every 5s").
    var probeIntervalDescription: String {
        guard autoProbe else { return tr(.probePaused) }
        guard let interval = currentInterval else { return tr(.probeParked) }
        return String(format: tr(.probeEvery), Int(interval.rounded()))
    }

    private func rescheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard autoProbe else {
            currentInterval = nil
            return
        }
        let interval = ProbeSchedule.interval(
            activity: activity,
            power: powerMonitor.state,
            trayOpen: trayOpen
        )
        currentInterval = interval
        guard let interval else {
            DebugLog.write("probe parked (display asleep / locked)")
            return
        }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.autoProbe else { return }
                self.refresh(reason: "timer")
            }
        }
        // Let the system coalesce wakeups — meaningful battery win for a
        // background poller that does not need millisecond precision.
        t.tolerance = interval * 0.2
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    func installHooks() {
        hooksStatus = .unknown
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let status = HooksSupport.install()
            Task { @MainActor in
                self?.hooksStatus = status
            }
        }
    }

    func uninstallHooks() {
        hooksStatus = .unknown
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let status = HooksSupport.uninstall()
            Task { @MainActor in
                self?.hooksStatus = status
            }
        }
    }

    var hooksInstalled: Bool {
        switch hooksStatus {
        case .installedBoth, .installedClaude, .installedCodex: return true
        case .unknown, .missing, .failed: return false
        }
    }

    /// Notification permission lives in System Settings, not in Pulse.
    func openSystemNotificationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
        if let url { NSWorkspace.shared.open(url) }
    }

    func checkForUpdatesNow() {
        UpdateCheck.shared.check(store: self, force: true)
    }

    var updateStatusText: String {
        switch updateStatus {
        case .idle: return tr(.updateIdle)
        case .checking: return tr(.updateChecking)
        case .current: return tr(.updateCurrent)
        case .available(let version, _): return String(format: tr(.updateAvailable), version)
        case .failed(let message): return "\(tr(.updateFailed)) · \(message)"
        }
    }

    var updateAvailableURL: URL? {
        if case .available(_, let raw) = updateStatus, !raw.isEmpty {
            return URL(string: raw)
        }
        return nil
    }

    /// `Permission · waited 4 分 · Pulse` for the resolved-wait list.
    func historyDetail(_ entry: ResolvedWait) -> String {
        var bits: [String] = []
        if !entry.kind.isEmpty { bits.append(localizedWaitKind(entry.kind)) }
        if entry.waitedSeconds >= 1 {
            bits.append(String(format: tr(.waitedFor), durationLabel(seconds: entry.waitedSeconds)))
        }
        if !entry.project.isEmpty { bits.append(entry.project) }
        bits.append(relative(entry.resolvedAt))
        return bits.joined(separator: " · ")
    }

    func toggleShowAllAgents() {
        showAllAgents.toggle()
        applyRowWindow()
    }

    func refresh() {
        refresh(reason: "manual")
    }

    func refresh(reason: String) {
        if scanInFlight {
            pendingRefreshReason = reason
            DebugLog.write("refresh coalesce pending=\(reason)")
            return
        }
        scanInFlight = true
        scanTicket &+= 1
        let ticket = scanTicket
        let showSpinner = reason == "manual" || reason == "start"
        if showSpinner {
            isRefreshing = true
        }
        DebugLog.write("refresh enqueue #\(ticket) reason=\(reason)")

        // Harvest is a Python fork walking dozens of trees; probe is one `ps`.
        // Only pay for harvest when something plausibly changed.
        let forceHarvest = reason != "timer"
        let priorSignature = lastProcessSignature
        let ticks = ticksSinceHarvest
        let everyN = ProbeSchedule.harvestEveryNTicks(activity: activity, trayOpen: trayOpen)

        scanQueue.async {
            let t0 = Date()
            let procs = ProcessProbe.scan()
            let signature = ProcessProbe.signature(procs)

            let why: String
            if forceHarvest {
                why = "forced"
            } else if signature != priorSignature {
                why = "procChanged"
            } else if ticks >= everyN {
                why = "cadence"
            } else {
                why = "skipped"
            }

            let outcome: HarvestOutcome
            if why == "skipped" {
                outcome = .skipped
            } else {
                let (rows, unreliable) = ActivityHarvest.scan()
                outcome = unreliable ? .failed : .fresh(rows)
            }

            let attention = AttentionReader.load()
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            DebugLog.write(
                "scan done #\(ticket) \(ms)ms harvest=\(why) procs=\(procs.count) " +
                "att=\(attention.count) procIds=\(procs.map(\.id.rawValue).joined(separator: ","))"
            )
            DispatchQueue.main.async {
                AppServices.store.applyScan(
                    procs: procs,
                    harvest: outcome,
                    processSignature: signature,
                    attention: attention,
                    ticket: ticket,
                    clearRefreshing: showSpinner
                )
            }
        }
    }

    fileprivate func finishScanFlight() {
        scanInFlight = false
        if let pending = pendingRefreshReason {
            pendingRefreshReason = nil
            refresh(reason: pending)
        }
    }

    /// What the background scan managed to get from `activity_scan.py`.
    enum HarvestOutcome {
        /// Ran and produced rows (possibly partial after a timeout).
        case fresh([ActivityHarvest.Row])
        /// Deliberately not run this tick — cached rows are still current.
        case skipped
        /// Ran and failed; cached rows may be stale.
        case failed
    }

    fileprivate func applyScan(
        procs: [ProcessProbe.Hit],
        harvest: HarvestOutcome,
        processSignature: String,
        attention: [AttentionReader.Entry],
        ticket: UInt64,
        clearRefreshing: Bool = false
    ) {
        defer { finishScanFlight() }

        if ticket < lastAppliedTicket {
            DebugLog.write("apply skip stale #\(ticket) lastApplied=\(lastAppliedTicket)")
            if clearRefreshing { isRefreshing = false }
            return
        }
        lastAppliedTicket = ticket
        lastProcessSignature = processSignature

        let previousLampBusy = cachedAll.contains { $0.waiting || $0.liveProcess || $0.subRunning > 0 }
        let previousWaitingKeys = knownWaitingKeys
        // Captured before `cachedAll` is replaced — wait history needs the old titles.
        let previousRows = cachedAll

        let acts: [ActivityHarvest.Row]
        switch harvest {
        case .fresh(let rows):
            acts = rows
            lastGoodHarvest = rows
            ticksSinceHarvest = 0
        case .skipped:
            // Cached rows are at most a couple of ticks old — keep them whole,
            // pending included, or Waiting would flicker off between harvests.
            acts = lastGoodHarvest
            ticksSinceHarvest = ticksSinceHarvest == Int.max ? 1 : ticksSinceHarvest + 1
        case .failed:
            // Keep last good shape, but never freeze Needs-you on stale pending.
            acts = lastGoodHarvest.map { row in
                guard row.skill == "pending" else { return row }
                var cleared = row
                cleared.skill = ""
                return cleared
            }
            ticksSinceHarvest = 0
            DebugLog.write("harvest unreliable → reuse \(acts.count) cached rows (pending stripped)")
        }
        let harvestUnreliable: Bool = {
            if case .failed = harvest { return true }
            return false
        }()

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        var rowsByKey: [String: AgentRow] = [:]
        var liveHits: [AgentID: ProcessProbe.Hit] = [:]
        var perAgentSessionCount: [AgentID: Int] = [:]
        var droppedSessionsByAgent: [AgentID: Int] = [:]

        for hit in procs {
            // Prefer richer hit if duplicate agent ids appear.
            if let existing = liveHits[hit.id] {
                if existing.tty.isEmpty, !hit.tty.isEmpty { liveHits[hit.id] = hit }
            } else {
                liveHits[hit.id] = hit
            }
        }
        // cursor_agent live counts as Cursor live for merge.
        if let agentHit = liveHits[.cursorAgent] {
            if var cursor = liveHits[.cursor] {
                cursor.count = max(cursor.count, agentHit.count)
                if cursor.tty.isEmpty { cursor.tty = agentHit.tty }
                if cursor.pid == 0 { cursor.pid = agentHit.pid }
                cursor.viaWarp = cursor.viaWarp || agentHit.viaWarp
                liveHits[.cursor] = cursor
            } else {
                var mapped = agentHit
                mapped.id = .cursor
                liveHits[.cursor] = mapped
            }
            liveHits.removeValue(forKey: .cursorAgent)
        }

        for act in acts {
            var agentID = act.id
            if agentID == .cursorAgent { agentID = .cursor }

            let live = liveHits[agentID] != nil
            if !live, !ActivityHarvest.isFresh(act, nowMs: nowMs), act.subRunning == 0 {
                DebugLog.write("drop stale harvest \(agentID.rawValue) hm=\(act.harvestMs)")
                continue
            }

            let count = perAgentSessionCount[agentID, default: 0]
            if count >= Self.maxSessionsPerAgent {
                // Don't drop it silently — the tray says how many were held back.
                droppedSessionsByAgent[agentID, default: 0] += 1
                continue
            }

            let key = ActivityHarvest.sessionKey(
                id: agentID,
                sessionID: act.sessionID,
                project: act.project,
                cwd: act.cwd
            )
            // Avoid colliding keys when second session lacks project — uniquify.
            var finalKey = key
            if rowsByKey[finalKey] != nil, rowsByKey[finalKey]?.sessionID != act.sessionID || act.sessionID.isEmpty {
                finalKey = "\(key)#\(count + 1)"
            }

            var row = rowsByKey[finalKey] ?? AgentRow(rowKey: finalKey, agent: agentID)
            if !act.sessionID.isEmpty { row.sessionID = act.sessionID }
            if !act.task.isEmpty { row.task = act.task }
            if !act.project.isEmpty { row.project = act.project }
            if !act.cwd.isEmpty { row.cwd = act.cwd }
            if !act.tool.isEmpty { row.tool = act.tool }
            if !act.skill.isEmpty { row.skill = act.skill }
            if act.tokensIn > 0 { row.tokensIn = act.tokensIn }
            if act.tokensOut > 0 { row.tokensOut = act.tokensOut }
            if act.harvestMs > 0 { row.harvestMs = act.harvestMs }
            if act.subTotal > 0 {
                row.subRunning = act.subRunning
                row.subTotal = act.subTotal
            }
            row.processCount = max(row.processCount, 1)

            // Harvest pending (Cursor / OpenCode / Gemini / Codex / …) → Waiting.
            if act.skill == "pending", ActivityHarvest.isFresh(act, nowMs: nowMs) {
                if !dismissedPendingKeys.contains(finalKey) {
                    row.waiting = true
                    row.waitKind = "Input"
                    row.waitSignal = .pending
                    row.waitSinceMs = act.harvestMs > 0 ? act.harvestMs : nowMs
                }
            } else {
                dismissedPendingKeys.remove(finalKey)
            }

            rowsByKey[finalKey] = row
            perAgentSessionCount[agentID] = count + 1
        }

        // Attach live process to at most one session row per agent (no smear).
        for (agentID, hit) in liveHits {
            let keys = rowsByKey.keys.filter { rowsByKey[$0]?.agent == agentID }
            if keys.isEmpty {
                let key = agentID.rawValue
                var row = AgentRow(rowKey: key, agent: agentID)
                row.liveProcess = true
                row.processCount = hit.count
                row.viaWarp = hit.viaWarp
                row.pid = hit.pid
                row.tty = hit.tty
                rowsByKey[key] = row
                continue
            }
            let bestKey = keys.max { a, b in
                let ra = rowsByKey[a]!, rb = rowsByKey[b]!
                if ra.waiting != rb.waiting { return !ra.waiting && rb.waiting }
                if ra.harvestMs != rb.harvestMs { return ra.harvestMs < rb.harvestMs }
                return a < b
            }!
            for key in keys {
                guard var row = rowsByKey[key] else { continue }
                if key == bestKey {
                    row.liveProcess = true
                    row.processCount = max(row.processCount, hit.count)
                    row.viaWarp = hit.viaWarp || row.viaWarp
                    if hit.pid != 0 { row.pid = hit.pid }
                    if !hit.tty.isEmpty { row.tty = hit.tty }
                } else {
                    row.liveProcess = false
                    // Don't inherit ×N on sibling sessions.
                    row.processCount = max(row.processCount, 1)
                }
                rowsByKey[key] = row
            }
        }

        // Hooks attention — prefer session / cwd match, else best row for agent.
        for att in attention {
            if let targetKey = matchAttentionRow(att, in: rowsByKey) {
                guard var best = rowsByKey[targetKey] else { continue }
                best.waiting = true
                best.waitKind = att.kind
                best.waitSignal = .hooks
                best.waitMessage = att.message
                best.waitSinceMs = att.tsMs
                if best.sessionID.isEmpty, !att.session.isEmpty { best.sessionID = att.session }
                if best.cwd.isEmpty, !att.cwd.isEmpty { best.cwd = att.cwd }
                best.processCount = max(best.processCount, 1)
                rowsByKey[targetKey] = best
                continue
            }
            let key: String = {
                if !att.session.isEmpty {
                    return ActivityHarvest.sessionKey(id: att.id, sessionID: att.session, project: "", cwd: att.cwd)
                }
                return att.id.rawValue
            }()
            var row = AgentRow(rowKey: key, agent: att.id)
            row.sessionID = att.session
            row.cwd = att.cwd
            row.project = AgentRow.shortProject(att.cwd)
            row.waiting = true
            row.waitKind = att.kind
            row.waitSignal = .hooks
            row.waitMessage = att.message
            row.waitSinceMs = att.tsMs
            row.processCount = max(row.processCount, 1)
            rowsByKey[key] = row
        }

        var all = Array(rowsByKey.values).filter { $0.processCount > 0 || $0.waiting || $0.subRunning > 0 }

        // Resolve focus once per scan. Doing this per row inside the SwiftUI body
        // meant enumerating running apps and stat-ing the disk on every redraw.
        let terminalEnv = TerminalFocus.Environment.current()
        let fm = FileManager.default
        for i in all.indices {
            let row = all[i]
            let folderPath = row.cwd.isEmpty ? row.project : row.cwd
            let cwdExists = !row.cwd.isEmpty && fm.fileExists(atPath: row.cwd)
            all[i].canOpenFolder = !folderPath.isEmpty && fm.fileExists(atPath: folderPath)
            all[i].focusTier = TerminalFocus.focusTier(
                tty: row.tty,
                viaWarp: row.viaWarp,
                cwdExists: cwdExists,
                env: terminalEnv
            )
        }

        // Waiting → titled sessions → live process → recent; agent priority last.
        all.sort { a, b in
            if a.waiting != b.waiting { return a.waiting && !b.waiting }
            if a.hasSessionTitle != b.hasSessionTitle { return a.hasSessionTitle && !b.hasSessionTitle }
            if a.liveProcess != b.liveProcess { return a.liveProcess && !b.liveProcess }
            if (a.subRunning > 0) != (b.subRunning > 0) { return a.subRunning > 0 && b.subRunning == 0 }
            let ra = AgentID.priority.firstIndex(of: a.agent) ?? 999
            let rb = AgentID.priority.firstIndex(of: b.agent) ?? 999
            return ra < rb
        }
        // Attribute held-back sessions to that agent's top row, so the badge
        // appears once rather than on every sibling session.
        var creditedAgents: Set<AgentID> = []
        for i in all.indices {
            let agent = all[i].agent
            guard let dropped = droppedSessionsByAgent[agent], dropped > 0 else { continue }
            if creditedAgents.insert(agent).inserted {
                all[i].hiddenSessions = dropped
            }
        }

        cachedAll = all
        if showAllAgents, all.count <= Self.maxVisibleRows {
            showAllAgents = false
        }

        let waitingCount = all.filter(\.waiting).count
        let liveRunning = all.filter { !$0.waiting && ($0.liveProcess || $0.subRunning > 0) }.count
        let recentOnly = all.filter { !$0.waiting && !$0.liveProcess && $0.subRunning == 0 }.count
        knownWaitingKeys = Set(all.filter(\.waiting).map(\.rowKey))

        var snap = PulseSnapshot()
        snap.totalCount = all.count
        snap.updatedAt = Date()
        applyRows(into: &snap)

        // Header answers only "N need you / N running"; row detail carries the rest.
        let rel = relative(snap.updatedAt)

        if all.isEmpty, harvestUnreliable, liveHits.isEmpty {
            snap.glance = .error
            snap.title = "!"
            snap.tooltip = tr(.cantRefresh)
            snap.headerTitle = tr(.cantRefresh)
            snap.headerDetail = ""
            snap.header = tr(.cantRefresh)
            snap.probeError = "probe+harvest unavailable"
        } else if waitingCount > 0 {
            snap.glance = .waiting
            let waitingRows = all.filter(\.waiting)
            let nameBits = waitingRows.prefix(3).map(\.agent.displayName)
            let nameJoin = nameBits.joined(separator: " · ")
            if waitingCount == 1, let w = waitingRows.first {
                snap.title = "\(w.agent.displayName)…"
                snap.tooltip = "\(tr(.needsYou)) · \(w.agent.displayName)"
                snap.headerTitle = tr(.needsYou)
            } else {
                snap.title = "\(waitingCount)"
                snap.tooltip = "\(tr(.needsYou)): \(nameJoin)"
                snap.headerTitle = "\(waitingCount) \(tr(.waitingN))"
            }
            snap.headerDetail = rel
            snap.header = "\(snap.headerTitle) · \(snap.headerDetail)"
        } else if liveRunning > 0 {
            snap.glance = .running
            let liveRows = all.filter { !$0.waiting && ($0.liveProcess || $0.subRunning > 0) }
            let liveNames = liveRows.prefix(3).map(\.agent.displayName).joined(separator: " · ")
            if liveRunning == 1 {
                snap.title = liveRows[0].agent.displayName
                snap.tooltip = "\(liveRows[0].agent.displayName) \(tr(.running))"
                snap.headerTitle = tr(.running1)
            } else {
                snap.title = "\(liveRunning)"
                snap.tooltip = "\(liveRunning) \(tr(.runningN)): \(liveNames)"
                snap.headerTitle = "\(liveRunning) \(tr(.runningN))"
            }
            snap.headerDetail = rel
            snap.header = "\(snap.headerTitle) · \(snap.headerDetail)"
        } else if recentOnly > 0 {
            snap.glance = .idle
            snap.title = ""
            snap.tooltip = "Pulse · \(recentOnly) \(tr(.recentN))"
            if recentOnly == 1 {
                snap.headerTitle = tr(.recent1)
            } else {
                snap.headerTitle = "\(recentOnly) \(tr(.recentN))"
            }
            snap.headerDetail = rel
            snap.header = "\(snap.headerTitle) · \(snap.headerDetail)"
        } else {
            snap.glance = .idle
            snap.title = ""
            snap.tooltip = "Pulse · \(tr(.idleWord))"
            snap.headerTitle = tr(.noAgents)
            snap.headerDetail = ""
            snap.header = tr(.noAgents)
        }

        let nowLampBusy = all.contains { $0.waiting || $0.liveProcess || $0.subRunning > 0 }
        let quiet = isInQuietHours()
        if notifyOnIdle, !quiet, previousLampBusy, !nowLampBusy {
            PulseNotify.postIdle(title: "Pulse", body: tr(.idleNotify))
        }
        // Waiting edges stay available even during quiet hours (when enabled).
        // Skip the first scan so launch doesn't flood for already-waiting rows.
        if notifyOnWaiting, waitingCount > 0, waitingNotifySeeded {
            let newcomers = knownWaitingKeys.subtracting(previousWaitingKeys)
            let candidates = all.filter { newcomers.contains($0.rowKey) && !mutedAgents.contains($0.agent) }
            if let waiting = candidates.first {
                PulseNotify.postWaiting(
                    title: notificationTitle(waiting),
                    body: notificationBody(waiting),
                    agent: waiting.agent.rawValue,
                    session: waiting.sessionID,
                    rowKey: waiting.rowKey
                )
            }
        }
        if !waitingNotifySeeded {
            waitingNotifySeeded = true
        }

        recordResolvedWaits(previous: previousRows, current: all)

        snapshot = snap
        if clearRefreshing { isRefreshing = false }

        let previousActivity = activity
        if waitingCount > 0 {
            activity = .waiting
        } else if liveRunning > 0 {
            activity = .running
        } else if recentOnly > 0 {
            activity = .recent
        } else {
            activity = .empty
        }
        // Only re-arm when the cadence tier actually moved — a timer rebuilt on
        // every tick never fires at its own interval.
        if previousActivity != activity || timer == nil {
            rescheduleTimer()
        }

        DebugLog.write(
            "apply #\(ticket) rows=\(snap.rows.count)/\(snap.totalCount) glance=\(snap.glance) " +
            "live=\(liveRunning) recent=\(recentOnly) wait=\(waitingCount) " +
            "activity=\(activity) every=\(currentInterval.map { String(Int($0)) } ?? "parked")"
        )
    }

    private func applyRowWindow() {
        var snap = snapshot
        applyRows(into: &snap)
        snapshot = snap
    }

    private func applyRows(into snap: inout PulseSnapshot) {
        if showAllAgents || cachedAll.count <= Self.maxVisibleRows {
            snap.rows = cachedAll
            snap.hiddenCount = 0
        } else {
            snap.rows = Array(cachedAll.prefix(Self.maxVisibleRows))
            snap.hiddenCount = cachedAll.count - Self.maxVisibleRows
        }
        snap.totalCount = cachedAll.count
        // Sessions dropped by the per-agent cap are separate from folded rows.
        snap.cappedSessions = cachedAll.reduce(0) { $0 + $1.hiddenSessions }
    }

    /// `Claude · Pulse` — who and where, so the banner is actionable at a glance.
    func notificationTitle(_ row: AgentRow) -> String {
        let project = AgentRow.shortProject(row.project.isEmpty ? row.cwd : row.project)
        return project.isEmpty
            ? row.agent.displayName
            : "\(row.agent.displayName) · \(project)"
    }

    /// `Permission · Approve shell command` — the reason, not just "Needs you".
    /// The old body was the glance tooltip, which never said what was wanted.
    func notificationBody(_ row: AgentRow) -> String {
        var bits: [String] = [
            row.waitKind.isEmpty ? tr(.needsYou) : localizedWaitKind(row.waitKind)
        ]
        let msg = row.waitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !msg.isEmpty {
            bits.append(msg.count > 120 ? String(msg.prefix(119)) + "…" : msg)
        } else if let task = row.usefulTask {
            bits.append(task.count > 120 ? String(task.prefix(119)) + "…" : task)
        }
        return bits.joined(separator: " · ")
    }

    /// Keep a short trail of waits that already cleared, so "I think something
    /// pinged me while I was away" has an answer.
    private func recordResolvedWaits(previous: [AgentRow], current: [AgentRow]) {
        let stillWaiting = Set(current.filter(\.waiting).map(\.rowKey))
        let now = Date()
        var added = false
        for row in previous where row.waiting && !stillWaiting.contains(row.rowKey) {
            let entry = ResolvedWait(
                rowKey: row.rowKey,
                agent: row.agent,
                title: row.usefulTask ?? AgentRow.shortProject(row.project),
                kind: row.waitKind,
                project: AgentRow.shortProject(row.project.isEmpty ? row.cwd : row.project),
                resolvedAt: now,
                waitedSeconds: row.waitAgeSeconds
            )
            waitHistory.insert(entry, at: 0)
            added = true
        }
        if added, waitHistory.count > 12 {
            waitHistory = Array(waitHistory.prefix(12))
        }
    }

    func clearWaitHistory() {
        waitHistory = []
    }

    func clearWaiting() {
        AttentionIO.clearAll()
        for row in cachedAll where row.waiting {
            dismissedPendingKeys.insert(row.rowKey)
        }
        refresh(reason: "clearWaiting")
    }

    func localizedWaitKind(_ kind: String) -> String {
        switch kind {
        case "Permission": return tr(.kindPermission)
        case "Input": return tr(.kindInput)
        case "Waiting": return tr(.kindWaiting)
        case "": return tr(.needsYou)
        default: return kind
        }
    }

    /// Human wait age in the resolved language (`2 分` / `2m`).
    func waitDurationLabel(_ row: AgentRow) -> String {
        guard row.waitSinceMs > 0 else { return "" }
        return durationLabel(seconds: row.waitAgeSeconds)
    }

    func durationLabel(seconds ago: Double) -> String {
        if ago < 5 { return tr(.durNow) }
        if ago < 60 { return String(format: tr(.durSec), Int(ago)) }
        if ago < 3600 { return String(format: tr(.durMin), Int(ago / 60)) }
        return String(format: tr(.durHour), Int(ago / 3600))
    }

    /// Rebuild wait detail under the badge: duration · signal · message (kind lives in the badge).
    /// Returns nil when there is nothing beyond the badge label.
    func localizedWaitDetail(_ row: AgentRow) -> String? {
        guard row.waiting else { return nil }
        var head: [String] = []
        let dur = waitDurationLabel(row)
        if !dur.isEmpty { head.append(dur) }
        if let sig = row.waitSignal {
            head.append(sig == .hooks ? tr(.signalHooks) : tr(.signalPending))
        }
        let headText = head.joined(separator: " · ")
        let msg = row.waitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !msg.isEmpty {
            if headText.isEmpty { return "↳ \(msg)" }
            return "↳ \(headText): \(msg)"
        }
        if headText.isEmpty { return nil }
        return "↳ \(headText)"
    }

    /// Full wait line (kind + detail) — used by glance / a11y.
    func localizedWaitLine(_ row: AgentRow) -> String {
        guard row.waiting else { return "" }
        let kind = row.waitKind.isEmpty ? tr(.needsYou) : localizedWaitKind(row.waitKind)
        if let detail = localizedWaitDetail(row) {
            // detail already has ↳ — splice kind after arrow when present
            let rest = String(detail.dropFirst(2)) // drop "↳ "
            return "↳ \(kind) · \(rest)"
        }
        return "↳ \(kind)"
    }

    func focusActionTitle(_ row: AgentRow) -> String {
        switch row.focusTier {
        case .tty: return tr(.focusTTY)
        case .warp: return tr(.focusWarp)
        case .openCwd: return tr(.openInTerminal)
        case .none: return tr(.focusTerminal)
        }
    }

    func dismissWaiting(_ row: AgentRow) {
        AttentionIO.appendDone(agent: row.agent, session: row.sessionID)
        if row.skill == "pending" {
            dismissedPendingKeys.insert(row.rowKey)
        }
        refresh(reason: "dismissWaiting")
    }

    /// Match attention to an existing harvest/process row.
    private func matchAttentionRow(
        _ att: AttentionReader.Entry,
        in rowsByKey: [String: AgentRow]
    ) -> String? {
        let candidates = rowsByKey.values.filter { $0.agent == att.id }
        guard !candidates.isEmpty else { return nil }

        if !att.session.isEmpty {
            // `rowKey` elides long session ids (prefix…suffix), so a full id can
            // never be a substring of it — that check silently never matched.
            // Compare session ids directly, both directions for truncated forms.
            if let hit = candidates.first(where: {
                guard !$0.sessionID.isEmpty else { return false }
                return $0.sessionID == att.session
                    || att.session.hasPrefix($0.sessionID)
                    || $0.sessionID.hasPrefix(att.session)
            }) {
                return hit.rowKey
            }
        }
        if !att.cwd.isEmpty {
            if let hit = candidates.first(where: {
                !$0.cwd.isEmpty && (
                    $0.cwd == att.cwd
                        || $0.cwd.hasPrefix(att.cwd)
                        || att.cwd.hasPrefix($0.cwd)
                )
            }) {
                return hit.rowKey
            }
            let want = AgentRow.shortProject(att.cwd)
            if !want.isEmpty, let hit = candidates.first(where: {
                AgentRow.shortProject($0.project) == want || AgentRow.shortProject($0.cwd) == want
            }) {
                return hit.rowKey
            }
        }
        var ranked = candidates
        ranked.sort { a, b in
            if a.liveProcess != b.liveProcess { return a.liveProcess && !b.liveProcess }
            return a.harvestMs > b.harvestMs
        }
        return ranked.first?.rowKey
    }

    func primaryAction(_ row: AgentRow) {
        if row.canFocusTerminal {
            if TerminalFocus.focus(row: row) { return }
        }
        openProject(row)
    }

    func focusTerminal(_ row: AgentRow) {
        _ = TerminalFocus.focus(row: row)
    }

    func focusFirstWaiting() {
        if let row = cachedAll.first(where: \.waiting) ?? snapshot.rows.first(where: \.waiting) {
            if row.canFocusTerminal, TerminalFocus.focus(row: row) { return }
            openProject(row)
            return
        }
        TrayReveal.show()
    }

    func focusAgent(idRaw: String, session: String = "", rowKey: String = "") {
        if !rowKey.isEmpty, let row = cachedAll.first(where: { $0.rowKey == rowKey }) {
            if row.canFocusTerminal, TerminalFocus.focus(row: row) { return }
            openProject(row)
            return
        }
        if !session.isEmpty, let row = cachedAll.first(where: {
            !$0.sessionID.isEmpty && ($0.sessionID == session || session.hasPrefix($0.sessionID))
        }) {
            if row.canFocusTerminal, TerminalFocus.focus(row: row) { return }
            openProject(row)
            return
        }
        guard let id = ActivityHarvest.mapAgent(idRaw) else {
            focusFirstWaiting()
            return
        }
        if let row = cachedAll.first(where: { $0.agent == id && $0.waiting })
            ?? cachedAll.first(where: { $0.agent == id }) {
            if row.canFocusTerminal, TerminalFocus.focus(row: row) { return }
            openProject(row)
            return
        }
        TrayReveal.show()
    }

    func openProject(_ row: AgentRow) {
        let path = row.cwd.isEmpty ? row.project : row.cwd
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }

    func openSettings() {
        SettingsWindowController.shared.show(store: self)
    }

    func quit() {
        attentionWatcher.stop()
        GlobalHotKey.uninstall()
        NSApp.terminate(nil)
    }

    private func relative(_ date: Date) -> String {
        if date == .distantPast { return tr(.notYet) }
        let ago = Date().timeIntervalSince(date)
        if ago < 5 { return tr(.justNow) }
        relativeFormatter.locale = lang == .zh ? Locale(identifier: "zh-Hans") : Locale(identifier: "en_US")
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func settingsURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pulse/settings.txt")
    }

    func loadSettings() {
        guard let text = try? String(contentsOf: settingsURL(), encoding: .utf8) else {
            appliedLaunchAtLogin = launchAtLogin
            return
        }
        // Pre-0.22 wrote whole hours; keep reading them so nobody loses a window.
        var legacyStartHour: Int?
        var legacyEndHour: Int?

        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let on = !(parts[1] == "0" || parts[1] == "false")
            switch parts[0] {
            case "auto": autoProbe = on
            case "notify": notifyOnIdle = on
            case "notifyWaiting": notifyOnWaiting = on
            case "quiet": quietHoursEnabled = on
            case "quietStart": legacyStartHour = Int(parts[1])
            case "quietEnd": legacyEndHour = Int(parts[1])
            case "quietStartMin": quietStartMinute = Int(parts[1]) ?? quietStartMinute
            case "quietEndMin": quietEndMinute = Int(parts[1]) ?? quietEndMinute
            case "login": launchAtLogin = on
            case "updates": updateCheckEnabled = on
            case "hotkey": hotkey = HotkeyChoice(rawValue: parts[1]) ?? .commandShiftP
            case "mute":
                mutedAgents = Set(
                    parts[1].split(separator: ",")
                        .compactMap { AgentID(rawValue: String($0)) }
                )
            case "lang":
                language = AppLanguage(rawValue: parts[1]) ?? .auto
            default: break
            }
        }
        // Only migrate when the file predates the minute-precision keys.
        if !text.contains("quietStartMin"), let h = legacyStartHour { quietStartMinute = h * 60 }
        if !text.contains("quietEndMin"), let e = legacyEndHour { quietEndMinute = e * 60 }
        quietStartMinute = Self.clampMinute(quietStartMinute)
        quietEndMinute = Self.clampMinute(quietEndMinute)

        DebugLog.write(
            "settings auto=\(autoProbe) notifyIdle=\(notifyOnIdle) notifyWait=\(notifyOnWaiting) " +
            "quiet=\(quietHoursEnabled) \(quietStartMinute)-\(quietEndMinute) lang=\(language.rawValue) " +
            "login=\(launchAtLogin) hotkey=\(hotkey.rawValue) muted=\(mutedAgents.count) updates=\(updateCheckEnabled)"
        )
        // Launchd already reflects the persisted value at load; don't re-run it.
        appliedLaunchAtLogin = launchAtLogin
    }

    static func clampMinute(_ m: Int) -> Int { min(24 * 60 - 1, max(0, m)) }

    func saveSettings() {
        let dir = settingsURL().deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        quietStartMinute = Self.clampMinute(quietStartMinute)
        quietEndMinute = Self.clampMinute(quietEndMinute)
        let muted = mutedAgents.map(\.rawValue).sorted().joined(separator: ",")
        let body = """
            auto=\(autoProbe ? 1 : 0)
            notify=\(notifyOnIdle ? 1 : 0)
            notifyWaiting=\(notifyOnWaiting ? 1 : 0)
            quiet=\(quietHoursEnabled ? 1 : 0)
            quietStartMin=\(quietStartMinute)
            quietEndMin=\(quietEndMinute)
            lang=\(language.rawValue)
            login=\(launchAtLogin ? 1 : 0)
            updates=\(updateCheckEnabled ? 1 : 0)
            hotkey=\(hotkey.rawValue)
            mute=\(muted)
            """
        try? body.write(to: settingsURL(), atomically: true, encoding: .utf8)
        applyLaunchAtLoginIfChanged()
        applyHotkey()
        UpdateCheck.shared.startIfEnabled(store: self)
        rescheduleTimer()
        refresh(reason: "saveSettings")
    }

    /// Re-register the global shortcut and report honestly when the system
    /// refuses (another app already owns the combination).
    func applyHotkey() {
        hotkeyRegistered = GlobalHotKey.install(choice: hotkey)
        if hotkey != .off, !hotkeyRegistered {
            DebugLog.write("hotkey \(hotkey.rawValue) registration FAILED — likely taken")
        }
    }

    func toggleMute(_ agent: AgentID) {
        if mutedAgents.contains(agent) {
            mutedAgents.remove(agent)
        } else {
            mutedAgents.insert(agent)
        }
        saveSettings()
    }

    /// Quiet window may wrap midnight (e.g. 22:30 → 08:00). Equal start/end = disabled.
    func isInQuietHours(now: Date = Date()) -> Bool {
        guard quietHoursEnabled else { return false }
        let start = Self.clampMinute(quietStartMinute)
        let end = Self.clampMinute(quietEndMinute)
        if start == end { return false }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: now)
        let minute = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        if start < end {
            return minute >= start && minute < end
        }
        return minute >= start || minute < end
    }
}

enum DebugLog {
    static let path: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pulse/debug.log")
    }()
    private static var previousPath: URL {
        path.deletingLastPathComponent().appendingPathComponent("debug.log.1")
    }
    /// Pulse writes ~5 lines every probe tick; without a cap the log grows
    /// unbounded (tens of MB per day). Roll at 2 MB, keep one generation.
    private static let maxBytes: UInt64 = 2 * 1024 * 1024
    private static let lock = NSLock()
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static var bytesWritten: UInt64 = 0
    private static var sizeKnown = false

    static func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        let dir = path.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        if !sizeKnown {
            let attrs = try? fm.attributesOfItem(atPath: path.path)
            bytesWritten = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
            sizeKnown = true
        }

        let line = "\(stamp.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if bytesWritten + UInt64(data.count) > maxBytes, fm.fileExists(atPath: path.path) {
            try? fm.removeItem(at: previousPath)
            try? fm.moveItem(at: path, to: previousPath)
            bytesWritten = 0
        }

        if fm.fileExists(atPath: path.path),
           let handle = try? FileHandle(forWritingTo: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: path, options: .atomic)
        }
        bytesWritten += UInt64(data.count)
    }
}

enum LoginItem {
    static func setEnabled(_ enabled: Bool) {
        let label = "com.pulse.app"
        let home = FileManager.default.homeDirectoryForCurrentUser
        let plist = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        if enabled {
            var appPath = Bundle.main.bundleURL.path
            if !appPath.hasSuffix(".app") {
                appPath = Bundle.main.executableURL?.path
                    ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/PulseBar").path
                let xml = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0"><dict>
                  <key>Label</key><string>\(label)</string>
                  <key>ProgramArguments</key><array><string>\(appPath)</string></array>
                  <key>RunAtLoad</key><true/>
                </dict></plist>
                """
                try? FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? xml.write(to: plist, atomically: true, encoding: .utf8)
            } else {
                let xml = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0"><dict>
                  <key>Label</key><string>\(label)</string>
                  <key>ProgramArguments</key><array>
                    <string>/usr/bin/open</string>
                    <string>-a</string>
                    <string>\(appPath)</string>
                  </array>
                  <key>RunAtLoad</key><true/>
                </dict></plist>
                """
                try? FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? xml.write(to: plist, atomically: true, encoding: .utf8)
            }
            _ = shell("/bin/launchctl", ["unload", "-w", plist.path])
            _ = shell("/bin/launchctl", ["load", "-w", plist.path])
        } else {
            _ = shell("/bin/launchctl", ["unload", "-w", plist.path])
            try? FileManager.default.removeItem(at: plist)
        }
    }

    private static func shell(_ path: String, _ args: [String]) -> Int32 {
        let t = Process()
        t.executableURL = URL(fileURLWithPath: path)
        t.arguments = args
        let out = Pipe()
        let err = Pipe()
        t.standardOutput = out
        t.standardError = err
        do {
            try t.run()
            _ = out.fileHandleForReading.readDataToEndOfFile()
            _ = err.fileHandleForReading.readDataToEndOfFile()
            t.waitUntilExit()
            return t.terminationStatus
        } catch {
            return -1
        }
    }
}
