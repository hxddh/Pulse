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
    @Published var quietStartHour: Int = 22
    @Published var quietEndHour: Int = 8
    @Published var launchAtLogin = false
    @Published var language: AppLanguage = .auto
    @Published var hooksStatus: HooksSupport.Status = .unknown
    @Published var showAllAgents = false
    @Published private(set) var isRefreshing = false

    private var timer: Timer?
    private var cachedAll: [AgentRow] = []
    private var lastGoodHarvest: [ActivityHarvest.Row] = []
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

    func start() {
        DebugLog.write("start begin version=\(PulseVersion.semver)")
        HooksSupport.seedAssets()
        hooksStatus = HooksSupport.probeStatus()
        PulseNotify.configure()
        GlobalHotKey.install()
        loadSettings()
        refresh(reason: "start")
        rescheduleTimer(waiting: false)
        attentionWatcher.start { [weak self] in
            Task { @MainActor in
                self?.refresh(reason: "attention")
            }
        }
        DebugLog.write("start armed auto=\(autoProbe)")
    }

    private func rescheduleTimer(waiting: Bool) {
        timer?.invalidate()
        guard autoProbe else { return }
        let interval = waiting ? 1.5 : 3.0
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.autoProbe else { return }
                self.refresh(reason: "timer")
            }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func installHooks() {
        hooksStatus = .unknown
        DispatchQueue.global(qos: .userInitiated).async {
            let status = HooksSupport.install()
            DispatchQueue.main.async {
                AppServices.store.hooksStatus = status
            }
        }
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

        scanQueue.async {
            let t0 = Date()
            let procs = ProcessProbe.scan()
            let (harvestRows, unreliable) = ActivityHarvest.scan()
            let attention = AttentionReader.load()
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            DebugLog.write(
                "scan done #\(ticket) \(ms)ms procs=\(procs.count) acts=\(harvestRows.count) " +
                "unreliable=\(unreliable) att=\(attention.count) " +
                "procIds=\(procs.map(\.id.rawValue).joined(separator: ",")) " +
                "actIds=\(harvestRows.map(\.id.rawValue).joined(separator: ","))"
            )
            DispatchQueue.main.async {
                AppServices.store.applyScan(
                    procs: procs,
                    activities: harvestRows,
                    harvestUnreliable: unreliable,
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

    fileprivate func applyScan(
        procs: [ProcessProbe.Hit],
        activities: [ActivityHarvest.Row],
        harvestUnreliable: Bool,
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

        let previousLampBusy = cachedAll.contains { $0.waiting || $0.liveProcess || $0.subRunning > 0 }
        let previousWaitingKeys = knownWaitingKeys

        let acts: [ActivityHarvest.Row]
        if harvestUnreliable {
            // Keep last good shape, but never freeze Needs-you on stale pending.
            acts = lastGoodHarvest.map { row in
                guard row.skill == "pending" else { return row }
                var cleared = row
                cleared.skill = ""
                return cleared
            }
            DebugLog.write("harvest unreliable → reuse \(acts.count) cached rows (pending stripped)")
        } else {
            acts = activities
            lastGoodHarvest = activities
        }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        var rowsByKey: [String: AgentRow] = [:]
        var liveHits: [AgentID: ProcessProbe.Hit] = [:]
        var perAgentSessionCount: [AgentID: Int] = [:]

        for hit in procs where hit.id.isSurface {
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

        for act in acts where act.id.isSurface {
            var agentID = act.id
            if agentID == .cursorAgent { agentID = .cursor }

            let live = liveHits[agentID] != nil
            if !live, !ActivityHarvest.isFresh(act, nowMs: nowMs), act.subRunning == 0 {
                DebugLog.write("drop stale harvest \(agentID.rawValue) hm=\(act.harvestMs)")
                continue
            }

            let count = perAgentSessionCount[agentID, default: 0]
            if count >= 2 { continue }

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
        for (agentID, hit) in liveHits where agentID.isSurface {
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
        cachedAll = all
        if showAllAgents, all.count <= 4 {
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
            if !newcomers.isEmpty {
                let waiting = all.first(where: { newcomers.contains($0.rowKey) }) ?? all.first(where: \.waiting)
                PulseNotify.postWaiting(
                    title: "Pulse",
                    body: snap.tooltip,
                    agent: waiting?.agent.rawValue ?? "",
                    session: waiting?.sessionID ?? "",
                    rowKey: waiting?.rowKey ?? ""
                )
            }
        }
        if !waitingNotifySeeded {
            waitingNotifySeeded = true
        }

        snapshot = snap
        if clearRefreshing { isRefreshing = false }
        rescheduleTimer(waiting: waitingCount > 0)
        DebugLog.write(
            "apply #\(ticket) rows=\(snap.rows.count)/\(snap.totalCount) glance=\(snap.glance) " +
            "live=\(liveRunning) recent=\(recentOnly) wait=\(waitingCount) header=\(snap.header)"
        )
    }

    private func applyRowWindow() {
        var snap = snapshot
        applyRows(into: &snap)
        snapshot = snap
    }

    private func applyRows(into snap: inout PulseSnapshot) {
        if showAllAgents || cachedAll.count <= 4 {
            snap.rows = cachedAll
            snap.hiddenCount = 0
        } else {
            snap.rows = Array(cachedAll.prefix(4))
            snap.hiddenCount = cachedAll.count - 4
        }
        snap.totalCount = cachedAll.count
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

    /// Rebuild wait detail under the badge: duration · signal · message (kind lives in the badge).
    /// Returns nil when there is nothing beyond the badge label.
    func localizedWaitDetail(_ row: AgentRow) -> String? {
        guard row.waiting else { return nil }
        var head: [String] = []
        let dur = AgentRow.waitDurationLabel(sinceMs: row.waitSinceMs)
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
            if let hit = candidates.first(where: {
                $0.sessionID == att.session
                    || $0.rowKey.contains(att.session)
                    || (!$0.sessionID.isEmpty && att.session.contains($0.sessionID))
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
            $0.sessionID == session || $0.rowKey.contains(session)
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
        guard let text = try? String(contentsOf: settingsURL(), encoding: .utf8) else { return }
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let on = !(parts[1] == "0" || parts[1] == "false")
            switch parts[0] {
            case "auto": autoProbe = on
            case "notify": notifyOnIdle = on
            case "notifyWaiting": notifyOnWaiting = on
            case "quiet": quietHoursEnabled = on
            case "quietStart": quietStartHour = Int(parts[1]) ?? quietStartHour
            case "quietEnd": quietEndHour = Int(parts[1]) ?? quietEndHour
            case "login": launchAtLogin = on
            case "lang":
                language = AppLanguage(rawValue: parts[1]) ?? .auto
            default: break
            }
        }
        quietStartHour = min(23, max(0, quietStartHour))
        quietEndHour = min(23, max(0, quietEndHour))
        DebugLog.write(
            "settings auto=\(autoProbe) notifyIdle=\(notifyOnIdle) notifyWait=\(notifyOnWaiting) " +
            "quiet=\(quietHoursEnabled) \(quietStartHour)-\(quietEndHour) lang=\(language.rawValue) login=\(launchAtLogin)"
        )
        LoginItem.setEnabled(launchAtLogin)
    }

    func saveSettings() {
        let dir = settingsURL().deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let body = """
            auto=\(autoProbe ? 1 : 0)
            notify=\(notifyOnIdle ? 1 : 0)
            notifyWaiting=\(notifyOnWaiting ? 1 : 0)
            quiet=\(quietHoursEnabled ? 1 : 0)
            quietStart=\(quietStartHour)
            quietEnd=\(quietEndHour)
            lang=\(language.rawValue)
            login=\(launchAtLogin ? 1 : 0)
            """
        try? body.write(to: settingsURL(), atomically: true, encoding: .utf8)
        LoginItem.setEnabled(launchAtLogin)
        if autoProbe {
            rescheduleTimer(waiting: snapshot.glance == .waiting)
        } else {
            timer?.invalidate()
            timer = nil
        }
        refresh(reason: "saveSettings")
    }

    /// Quiet window may wrap midnight (e.g. 22→8). Equal start/end = disabled.
    func isInQuietHours(now: Date = Date()) -> Bool {
        guard quietHoursEnabled else { return false }
        if quietStartHour == quietEndHour { return false }
        let hour = Calendar.current.component(.hour, from: now)
        if quietStartHour < quietEndHour {
            return hour >= quietStartHour && hour < quietEndHour
        }
        return hour >= quietStartHour || hour < quietEndHour
    }
}

enum DebugLog {
    static let path: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pulse/debug.log")
    }()
    private static let lock = NSLock()

    static func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let dir = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: path.path),
           let handle = try? FileHandle(forWritingTo: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: path, options: .atomic)
        }
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
