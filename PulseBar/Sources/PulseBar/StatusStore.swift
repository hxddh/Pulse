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
    @Published var trayGrouping: TrayGrouping = .status
    @Published var playSoundOnWaiting = false
    /// False when the system refused the shortcut (another app owns it).
    @Published private(set) var hotkeyRegistered = true
    @Published var updateCheckEnabled = true
    @Published var updateStatus: UpdateCheck.Status = .idle
    /// Notification authorization — a denied prompt used to fail silently.
    @Published private(set) var notifyAuthorized: Bool?
    /// Waits that have already been resolved, newest first (P1-H).
    @Published private(set) var waitHistory: [ResolvedWait] = []
    /// Waits that ended while the tray was closed — "what did I miss?".
    @Published private(set) var missedWhileAway = 0
    /// When the tray was last dismissed, for the missed-wait count.
    private var trayClosedAt: Date?

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

    /// Resolved waits kept for the Settings history list.
    static let maxWaitHistory = 12

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
    /// Rolling scan counters, so the energy claim can be checked, not believed.
    private var probeStats = ProbeStats()
    /// When the timer parked, for the parked-duration counter.
    private var parkedSince: Date?
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
            "cadence: \(probeIntervalDescription) · \(probeStats.summary(now: Date()))",
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
        // Coming back to the tray, the first question is what was missed. The
        // panel only ever showed the present moment.
        if let closed = trayClosedAt {
            missedWhileAway = waitHistory.filter { $0.resolvedAt > closed }.count
        }
        rescheduleTimer()
        refresh(reason: "trayOpen")
    }

    func trayDidDisappear() {
        trayOpen = false
        trayClosedAt = Date()
        rescheduleTimer()
    }

    /// Acknowledge the "while you were away" line.
    func clearMissedWhileAway() {
        missedWhileAway = 0
    }

    /// Current cadence, for Settings/diagnostics ("probing every 5s").
    var probeIntervalDescription: String {
        guard autoProbe else { return tr(.probePaused) }
        guard let interval = currentInterval else { return tr(.probeParked) }
        return String(format: tr(.probeEvery), Int(interval.rounded()))
    }

    /// Close an open parked span. Switching live updates off is *not* parking —
    /// settling here too keeps a week with probing disabled out of the parked
    /// counter, which would otherwise swallow it whole on the next unpark.
    private func settleParked() {
        guard let since = parkedSince else { return }
        probeStats.addParked(Date().timeIntervalSince(since))
        parkedSince = nil
    }

    private func rescheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard autoProbe else {
            settleParked()
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
            if parkedSince == nil { parkedSince = Date() }
            DebugLog.write("probe parked (display asleep / locked)")
            return
        }
        settleParked()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            // Bind before the Task: the timer block is @Sendable, and referencing
            // the captured `weak self` var from inside a Task is not allowed.
            guard let store = self else { return }
            Task { @MainActor in
                guard store.autoProbe else { return }
                store.refresh(reason: "timer")
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
        // `Task` inherits this class's main-actor isolation, so the assignment
        // lands on main while the blocking Python run stays off it.
        Task { [weak self] in
            let status = await Task.detached(priority: .userInitiated) {
                HooksSupport.install()
            }.value
            self?.hooksStatus = status
        }
    }

    func uninstallHooks() {
        hooksStatus = .unknown
        Task { [weak self] in
            let status = await Task.detached(priority: .userInitiated) {
                HooksSupport.uninstall()
            }.value
            self?.hooksStatus = status
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
            var harvestMs: Int?
            if why == "skipped" {
                outcome = .skipped
            } else {
                let h0 = Date()
                let (rows, unreliable) = ActivityHarvest.scan()
                harvestMs = Int(Date().timeIntervalSince(h0) * 1000)
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
                    harvestMs: harvestMs,
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
        harvestMs: Int? = nil,
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

        // Resolve which harvest rows this scan should use, and remember them.
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

        let now = Date()
        probeStats.record(
            ProbeStats.Sample(at: now, harvested: harvestMs != nil, harvestMs: harvestMs)
        )
        let result = SnapshotBuilder.build(
            SnapshotBuilder.Input(
                procs: procs,
                harvest: acts,
                harvestUnreliable: harvestUnreliable,
                attention: attention
            ),
            previous: SnapshotBuilder.Previous(rows: cachedAll, waitingKeys: knownWaitingKeys),
            context: SnapshotBuilder.Context(
                nowMs: Int64(now.timeIntervalSince1970 * 1000),
                terminal: TerminalFocus.Environment.current(),
                lang: lang,
                dismissedPendingKeys: dismissedPendingKeys,
                showAllAgents: showAllAgents
            )
        )

        for note in result.debugNotes { DebugLog.write(note) }
        dismissedPendingKeys.subtract(result.clearedPendingKeys)
        cachedAll = result.rows
        showAllAgents = result.showAllAgents
        knownWaitingKeys = result.waitingKeys

        var snap = result.snapshot
        snap.updatedAt = now

        // Notification policy lives here; the builder only reports the edges.
        let quiet = isInQuietHours()
        if notifyOnIdle, !quiet, result.wentIdle {
            PulseNotify.postIdle(title: "Pulse", body: tr(.idleNotify))
        }
        // Waiting edges stay available even during quiet hours (when enabled).
        // Skip the first scan so launch doesn't flood for already-waiting rows.
        if notifyOnWaiting, waitingNotifySeeded,
           let waiting = result.newlyWaiting.first(where: { !mutedAgents.contains($0.agent) }) {
            PulseNotify.postWaiting(
                title: notificationTitle(waiting),
                body: notificationBody(waiting),
                agent: waiting.agent.rawValue,
                session: waiting.sessionID,
                rowKey: waiting.rowKey
            )
            // Opt-in, and deliberately quiet: Tink, not an alert tone. Muting an
            // agent silences this too, same as the banner.
            if playSoundOnWaiting {
                NSSound(named: NSSound.Name("Tink"))?.play()
            }
        }
        if !waitingNotifySeeded {
            waitingNotifySeeded = true
        }

        recordResolvedWaits(result.resolvedWaits, at: now)

        snapshot = snap
        if clearRefreshing { isRefreshing = false }

        let previousActivity = activity
        activity = result.activity
        // Only re-arm when the cadence tier actually moved — a timer rebuilt on
        // every tick never fires at its own interval.
        if previousActivity != activity || timer == nil {
            rescheduleTimer()
        }

        DebugLog.write(
            "apply #\(ticket) rows=\(snap.rows.count)/\(snap.totalCount) glance=\(snap.glance) " +
            "activity=\(activity) wait=\(result.waitingKeys.count) " +
            "every=\(currentInterval.map { String(Int($0)) } ?? "parked")"
        )
    }

    private func applyRowWindow() {
        var snap = snapshot
        SnapshotBuilder.window(
            rows: cachedAll,
            showAll: showAllAgents,
            maxVisible: SnapshotBuilder.maxVisibleRows,
            into: &snap
        )
        snapshot = snap
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
    /// pinged me while I was away" has an answer. The builder decides *which*
    /// waits resolved; this only records them.
    private func recordResolvedWaits(_ resolved: [AgentRow], at now: Date) {
        guard !resolved.isEmpty else { return }
        for row in resolved {
            waitHistory.insert(
                ResolvedWait(
                    rowKey: row.rowKey,
                    agent: row.agent,
                    title: row.usefulTask ?? AgentRow.shortProject(row.project),
                    kind: row.waitKind,
                    project: AgentRow.shortProject(row.project.isEmpty ? row.cwd : row.project),
                    resolvedAt: now,
                    waitedSeconds: row.waitAgeSeconds
                ),
                at: 0
            )
        }
        if waitHistory.count > Self.maxWaitHistory {
            waitHistory = Array(waitHistory.prefix(Self.maxWaitHistory))
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

    /// The row that has been blocked longest, if any.
    ///
    /// Rows arrive sorted oldest-wait-first, so this is the top of the list —
    /// but the lookup does not rely on that, because a caller reaching for
    /// "the most urgent thing" should not silently depend on sort order.
    var oldestWait: AgentRow? {
        cachedAll
            .filter { $0.waiting && $0.waitSinceMs > 0 }
            .min { $0.waitSinceMs < $1.waitSinceMs }
            ?? cachedAll.first(where: \.waiting)
    }

    /// Focus the longest-outstanding wait. One step from "something needs me"
    /// to the terminal tab it is blocked in.
    func focusOldestWait() {
        guard let row = oldestWait else { return }
        DebugLog.write("jump to oldest wait \(row.rowKey)")
        primaryAction(row)
    }

    /// "Today: 4 interruptions, 6m average wait" — built from the wait history
    /// already kept for the Settings list. A single line, not a dashboard:
    /// `EXPERIENCE.md` rules out a stats panel and this does not become one.
    var interruptionsTodayLine: String? {
        let calendar = Calendar.current
        let today = waitHistory.filter { calendar.isDateInToday($0.resolvedAt) }
        guard !today.isEmpty else { return nil }
        let mean = today.reduce(0.0) { $0 + $1.waitedSeconds } / Double(today.count)
        return String(
            format: tr(.interruptionsToday),
            today.count,
            durationLabel(seconds: mean)
        )
    }

    /// "12m ago" for a row's last activity, or "no activity yet".
    func lastActivityLabel(_ row: AgentRow) -> String {
        guard row.harvestMs > 0 else { return "" }
        let secs = row.lastActivitySeconds
        // "54s ago" reads as precision the number does not have — the panel
        // rescans every few seconds and nobody acts on the difference between
        // 40 and 54 seconds. Below a minute it is simply recent.
        if secs < 60 { return tr(.durNow) }
        return String(format: tr(.agoFormat), durationLabel(seconds: secs))
    }

    /// Second line of a row: where it is, and how long since it moved.
    ///
    /// Both facts were collected from the start and never shown. The line used
    /// to repeat the agent name that the icon already carries.
    func rowContextLine(_ row: AgentRow, omitPath: Bool = false) -> String {
        var bits: [String] = []
        let path = row.displayPath
        if !path.isEmpty, !omitPath { bits.append(path) }
        let ago = lastActivityLabel(row)
        if !ago.isEmpty { bits.append(ago) }
        // With neither, fall back to naming the agent rather than an empty line.
        if bits.isEmpty { return row.isProcessOnly ? "" : row.agent.displayName }
        return bits.joined(separator: " · ")
    }

    /// Human wait age in the resolved language (`2 分` / `2m`).
    func waitDurationLabel(_ row: AgentRow) -> String {
        guard row.waitSinceMs > 0 else { return "" }
        return durationLabel(seconds: row.waitAgeSeconds)
    }

    func durationLabel(seconds ago: Double) -> String {
        DurationFormat.label(seconds: ago, lang: lang)
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

    /// Snapshot of the settings the store currently holds.
    var currentSettings: PulseSettings {
        PulseSettings(
            autoProbe: autoProbe,
            notifyOnIdle: notifyOnIdle,
            notifyOnWaiting: notifyOnWaiting,
            quietHoursEnabled: quietHoursEnabled,
            quietStartMinute: quietStartMinute,
            quietEndMinute: quietEndMinute,
            launchAtLogin: launchAtLogin,
            language: language,
            updateCheckEnabled: updateCheckEnabled,
            hotkey: hotkey,
            mutedAgents: mutedAgents,
            trayGrouping: trayGrouping,
            playSoundOnWaiting: playSoundOnWaiting
        )
    }

    func apply(_ s: PulseSettings) {
        autoProbe = s.autoProbe
        notifyOnIdle = s.notifyOnIdle
        notifyOnWaiting = s.notifyOnWaiting
        quietHoursEnabled = s.quietHoursEnabled
        quietStartMinute = s.quietStartMinute
        quietEndMinute = s.quietEndMinute
        launchAtLogin = s.launchAtLogin
        language = s.language
        updateCheckEnabled = s.updateCheckEnabled
        hotkey = s.hotkey
        mutedAgents = s.mutedAgents
        trayGrouping = s.trayGrouping
        playSoundOnWaiting = s.playSoundOnWaiting
    }

    func loadSettings() {
        guard let text = try? String(contentsOf: settingsURL(), encoding: .utf8) else {
            appliedLaunchAtLogin = launchAtLogin
            return
        }
        let parsed = PulseSettings.parse(text)
        apply(parsed)
        DebugLog.write("settings \(parsed.debugDescription)")
        // Launchd already reflects the persisted value at load; don't re-run it.
        appliedLaunchAtLogin = launchAtLogin
    }

    func saveSettings() {
        let dir = settingsURL().deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        quietStartMinute = PulseSettings.clampMinute(quietStartMinute)
        quietEndMinute = PulseSettings.clampMinute(quietEndMinute)
        try? currentSettings.serialized().write(to: settingsURL(), atomically: true, encoding: .utf8)
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

    func isInQuietHours(now: Date = Date()) -> Bool {
        currentSettings.isInQuietHours(now: now)
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
