import SwiftUI
import AppKit
import Darwin

enum AppServices {
    @MainActor static let store = StatusStore()
}

/// Explicit entry point so `--selftest` can answer before AppKit starts —
/// `App.main()` connects to the WindowServer, which a CI runner may not have.
@main
enum PulseBarMain {
    private static var instanceGuard: SingleInstanceGuard?

    static func main() {
        if let dmg = CommandLine.arguments.first(where: { $0.hasPrefix("--install-update=") }),
           let target = CommandLine.arguments.first(where: { $0.hasPrefix("--install-target=") }),
           let parent = CommandLine.arguments.first(where: { $0.hasPrefix("--install-parent-pid=") }),
           let pid = pid_t(String(parent.dropFirst("--install-parent-pid=".count))) {
            do {
                try UpdateInstaller.runHelper(
                    dmgURL: URL(fileURLWithPath: String(dmg.dropFirst("--install-update=".count))),
                    targetApp: URL(fileURLWithPath: String(target.dropFirst("--install-target=".count))),
                    parentPID: pid
                )
                exit(0)
            } catch {
                fputs("Pulse update failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--selftest") {
            exit(PulseSelfTest.run() ? 0 : 1)
        }
        if CommandLine.arguments.contains("--hook") {
            // Native Waiting path for Claude/Codex — no Python. Always exit 0
            // so vendor hooks never block the agent process.
            var stdinText = ""
            // Vendors pipe JSON on stdin. Never read when attached to a TTY —
            // that would block the menu-bar binary until EOF.
            if isatty(STDIN_FILENO) == 0,
               let data = try? FileHandle.standardInput.readToEnd(),
               let text = String(data: data, encoding: .utf8) {
                stdinText = text
            }
            exit(Int32(PulseHookReceiver.run(arguments: CommandLine.arguments, stdin: stdinText)))
        }
        if CommandLine.arguments.contains("--harvest-test") {
            let started = Date()
            // Match the menu-bar store: App Data grants live in settings.txt.
            // Ignoring that file made A/B harvest dumps always look process-only.
            let settings = PulseSettings.loadFromDisk()
            let agentsLabel = settings.allowAppData
                ? "all"
                : (settings.appDataAgents.isEmpty
                    ? "none"
                    : settings.appDataAgents.map(\.rawValue).sorted().joined(separator: ","))
            let result = ActivityHarvest.scan(
                allowAppData: settings.allowAppData,
                appDataAgents: settings.appDataAgents
            )
            print(
                "harvest rows=\(result.rows.count) adapters=\(result.health.count) "
                    + "unreliable=\(result.unreliable) "
                    + "complete=\(result.complete) "
                    + "appData=\(settings.allowAppData ? 1 : 0) "
                    + "agents=\(agentsLabel) "
                    + "elapsed=\(String(format: "%.3f", Date().timeIntervalSince(started)))s"
            )
            if CommandLine.arguments.contains("--harvest-dump") {
                for health in result.health.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
                    print("  health \(health.id.rawValue)=\(health.state.rawValue) rows=\(health.rowCount) source=\(health.sourcePresent) duration_ms=\(health.durationMs) error=\(health.errorKind)")
                    if let row = result.rows.first(where: { $0.id == health.id }) {
                        let title = row.task.isEmpty ? "<no title>" : row.task
                        let action = row.tool.isEmpty ? "-" : row.tool
                        print("    sample \(title) · \(row.cwd) · action=\(action) · evidence=\(row.evidence.rawValue)")
                    }
                }
                if CommandLine.arguments.contains("--harvest-dump-all") {
                    for row in result.rows {
                        print("    row \(row.id.rawValue) sid=\(row.sessionID) task=\(row.task) cwd=\(row.cwd) tool=\(row.tool) model=\(row.model) phase=\(row.phase) outcome=\(row.outcome) tokens=\(row.tokensIn)/\(row.tokensOut) files=\(row.files) errors=\(row.errors) context=\(row.contextPercent) progress=\(row.progressDone)/\(row.progressTotal) records=\(row.records) evidence=\(row.evidence.rawValue)")
                    }
                }
            }
            exit(result.unreliable ? 1 : 0)
        }
        if CommandLine.arguments.contains("--native-fixture-test") {
            exit(NativeHarvestSelfTest.run() ? 0 : 1)
        }
        if Bundle.main.bundleURL.pathExtension == "app" {
            _ = UpdateInstaller.recoverIfNeeded(at: Bundle.main.bundleURL)
        }
        let guardLock = SingleInstanceGuard()
        guard guardLock.acquire() else {
            Task { @MainActor in
                SingleInstanceGuard.activateExistingCopy()
                exit(0)
            }
            RunLoop.main.run()
            return
        }
        instanceGuard = guardLock
        // AppKit-only run loop — no SwiftUI `Settings { EmptyView() }` scene.
        // That scene was a lifecycle anchor and became a blank Settings window
        // on Finder/Spotlight reopen after update (0.56.1 workaround). Real
        // settings stay in SettingsWindowController.
        let app = NSApplication.shared
        let delegate = AppDelegate()
        retainedAppDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// Retained for the process lifetime — NSApplication does not keep a strong
    /// reference to its delegate.
    private static var retainedAppDelegate: AppDelegate?
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Visual QA captures must represent the first completed scan, not the
    /// transient launch state where every adapter is still `unscanned`.
    /// ActivityHarvest has a 6s hard deadline, so 6.8s covers either a
    /// completed scan or its honest timeout result.
    private static let captureDelay: TimeInterval = 6.8

    /// Windows Pulse intentionally owns. Orphan titled windows without these
    /// ids are closed as defense-in-depth (should not appear without a Settings scene).
    private static let ownedWindowIDs: Set<String> = [
        "pulse-settings",
        "pulse-support-coverage",
        "pulse-agent-detail",
        "pulse-tray-preview",
    ]

    private var statusPanel: StatusPanelController?
    private var activationObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Activation policy is also set before run(); keep accessory here so
        // CLI/QA relaunch paths stay consistent.
        NSApp.setActivationPolicy(.accessory)
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            PulseNotify.refreshAuthorization()
            self?.dismissPhantomSettingsWindows()
        }
        if CommandLine.arguments.contains("--appearance=dark") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        } else if CommandLine.arguments.contains("--appearance=light") {
            NSApp.appearance = NSAppearance(named: .aqua)
        }
        if CommandLine.arguments.contains("--language=zh") {
            AppServices.store.language = .zh
        } else if CommandLine.arguments.contains("--language=en") {
            AppServices.store.language = .en
        }
        let panel = StatusPanelController(store: AppServices.store)
        statusPanel = panel
        StatusPanelController.shared = panel
        panel.install()
        if let fixture = CommandLine.arguments.first(where: { $0.hasPrefix("--tray-fixture=") }) {
            AppServices.store.installPreviewFixture(
                String(fixture.dropFirst("--tray-fixture=".count))
            )
        } else {
            AppServices.store.start()
        }
        if CommandLine.arguments.contains("--open-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                AppServices.store.openSettings()
            }
        }
        if let focus = CommandLine.arguments.first(where: { $0.hasPrefix("--open-settings-agent=") }) {
            let raw = String(focus.dropFirst("--open-settings-agent=".count))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                AppServices.store.openSettings(focusAppDataFor: AgentID(rawValue: raw))
            }
        }
        if CommandLine.arguments.contains("--open-support-health") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                AppServices.store.openSupportHealth()
            }
        }
        // This opt-in QA surface hosts the exact TrayPanel view in a normal
        // window so layout and accessibility regressions are testable without
        // Screen Recording or UI automation permissions.
        if CommandLine.arguments.contains("--open-tray-preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                TrayPreviewWindowController.shared.show(store: AppServices.store)
            }
        }
        if CommandLine.arguments.contains("--open-tray-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                StatusPanelController.shared?.show()
            }
        }
        if let capture = CommandLine.arguments.first(where: { $0.hasPrefix("--capture-tray-panel=") }) {
            let path = String(capture.dropFirst("--capture-tray-panel=".count))
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.captureDelay) {
                StatusPanelController.shared?.capture(to: URL(fileURLWithPath: path))
            }
        }
        if let capture = CommandLine.arguments.first(where: { $0.hasPrefix("--capture-status-item=") }) {
            let path = String(capture.dropFirst("--capture-status-item=".count))
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.captureDelay) {
                StatusPanelController.shared?.captureStatusItem(to: URL(fileURLWithPath: path))
            }
        }
        if let capture = CommandLine.arguments.first(where: { $0.hasPrefix("--capture-support-health=") }) {
            let path = String(capture.dropFirst("--capture-support-health=".count))
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.captureDelay) {
                SupportCoverageWindowController.shared.capture(
                    store: AppServices.store,
                    to: URL(fileURLWithPath: path)
                )
            }
        }
        if let capture = CommandLine.arguments.first(where: { $0.hasPrefix("--capture-settings=") }) {
            let path = String(capture.dropFirst("--capture-settings=".count))
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.captureDelay) {
                SettingsWindowController.shared.capture(
                    store: AppServices.store,
                    to: URL(fileURLWithPath: path)
                )
            }
        }
        // Post-update Launch Services reopen can surface the EmptyView Settings
        // scene before we refuse it — sweep once on the next runloop turn.
        DispatchQueue.main.async { [weak self] in
            self?.dismissPhantomSettingsWindows()
        }
    }

    /// Finder / Spotlight reopen must not invent windows. Tray is user-driven.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        dismissPhantomSettingsWindows()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Defense-in-depth: close titled windows that are not Pulse-owned.
    /// After removing the SwiftUI Settings scene this should be a no-op.
    private func dismissPhantomSettingsWindows() {
        for window in NSApp.windows {
            if let id = window.identifier?.rawValue, Self.ownedWindowIDs.contains(id) {
                continue
            }
            if window.styleMask.contains(.borderless) { continue }
            if window.level != .normal { continue }
            guard window.styleMask.contains(.titled) else { continue }
            if window.identifier == nil {
                window.close()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        GlobalHotKey.uninstall()
        statusPanel?.uninstall()
        AppServices.store.markCleanShutdown()
    }
}

// MARK: - Glance

// SwiftUI views only ever run on the main actor, but only `body` is
// implicitly isolated — helper computed properties are not, so calling
// StatusStore's @MainActor methods from them is an error. Annotate the
// whole view rather than sprinkling MainActor.assumeIsolated.
@MainActor
struct MenuBarLabel: View {
    let snapshot: PulseSnapshot
    /// Dips once when a *new* wait arrives, then holds steady.
    ///
    /// This used to breathe forever while anything was waiting. A permanent
    /// animation in the menu bar is noise: it draws the eye every time it
    /// crosses zero, says nothing new after the first second, and — because it
    /// looks identical at 30 seconds and 40 minutes — competes with the one
    /// signal that does carry urgency, the elapsed time beside it.
    @State private var flash = false
    @State private var flashTask: Task<Void, Never>?

    private var waitingCount: Int { snapshot.sectionTotals[.needsYou] ?? 0 }

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: PulseBrand.menuIcon(for: snapshot.glance))
                .resizable()
                .renderingMode(.template)
                .frame(width: 14, height: 14)
                .foregroundStyle(snapshot.glance.lampColor)
                .opacity(flash ? 0.4 : 1.0)
                .accessibilityLabel(snapshot.accessibilityLabel)
            if snapshot.glance != .idle, !snapshot.title.isEmpty {
                Text(snapshot.title)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(snapshot.glance.lampColor)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .help(snapshot.tooltip)
        .onChange(of: waitingCount) { old, new in
            guard new > old else { return }
            flashTask?.cancel()
            flashTask = Task { @MainActor in
                withAnimation(.easeOut(duration: 0.10)) { flash = true }
                try? await Task.sleep(nanoseconds: 110_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.45)) { flash = false }
            }
        }
    }
}

// MARK: - Tray chrome

enum TrayChrome {
    /// 360 lost the end of most session titles: after the 12pt accent gutter,
    /// the 18pt icon, and the status chip, a row title had ~230pt — roughly
    /// thirty characters, where a real task name is fifty. A menu-bar panel at
    /// 400 is still narrow next to the calendar and reminder popovers people
    /// already run, and it is forty characters instead of thirty.
    static let width: CGFloat = 448
    static let padX: CGFloat = 16
    /// Shared identity grid for rows and project/status headings. Keeping the
    /// columns explicit prevents a section marker from drifting away from the
    /// lamp it explains when the grouping mode changes.
    static let rowLeadingInset: CGFloat = 14
    static let iconColumnWidth: CGFloat = 18
    static let iconToIdentityGap: CGFloat = 11
    static let identityLampSize: CGFloat = 6
    static let identityLampToNameGap: CGFloat = 6
    static let rowIdentityStart: CGFloat =
        rowLeadingInset + iconColumnWidth + iconToIdentityGap
    static let rowNameStart: CGFloat =
        rowIdentityStart + identityLampSize + identityLampToNameGap
    /// Section headers keep their title on the same column as Agent names.
    /// The accent marker starts where a row's lamp starts, not in the old
    /// disclosure-column centre.
    static let sectionAccentPrefix: CGFloat = rowIdentityStart - padX
    /// The heading's first item plus its 9pt inter-item gap must land on the
    /// same name column as a row (icon → lamp → name). Derive it from the
    /// actual row grid instead of letting a future icon-size tweak drift the
    /// heading independently.
    static let sectionHeaderLeadWidth: CGFloat =
        rowNameStart - padX - 9
    /// One hit target for every compact header action. SF Symbols have
    /// different intrinsic boxes; the shared frame aligns their visible
    /// centres and keeps the title on the same row.
    static let headerControlSize: CGFloat = 28
    static let waitAccent = GlanceKind.waiting.lampColor
    static let runAccent = GlanceKind.running.lampColor

}

private struct StatusChip: View {
    enum Kind { case waiting, running, recent, process, snoozed }

    let kind: Kind
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(background, in: Capsule(style: .continuous))
    }

    private var foreground: Color {
        switch kind {
        case .waiting: return TrayChrome.waitAccent
        case .running: return TrayChrome.runAccent
        case .process: return Color.secondary.opacity(0.9)
        case .recent: return Color.secondary.opacity(0.85)
        // Still the waiting colour, drained. Snoozed is a waiting row that
        // agreed to be quiet, not a different kind of thing.
        case .snoozed: return TrayChrome.waitAccent.opacity(0.6)
        }
    }

    private var background: Color {
        switch kind {
        case .waiting: return TrayChrome.waitAccent.opacity(0.16)
        case .running: return TrayChrome.runAccent.opacity(0.12)
        case .process: return Color.primary.opacity(0.05)
        case .recent: return Color.primary.opacity(0.04)
        case .snoozed: return TrayChrome.waitAccent.opacity(0.08)
        }
    }
}

// MARK: - Tray panel

/// Measured height of the row list, so the panel is sized by its content
/// instead of by arithmetic.
private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// One heading per tray section: "Needs you · 2".
private struct SectionHeader: View {
    let title: String
    let count: Int
    let accent: Bool
    /// Non-nil turns the heading into the group's disclosure control.
    var collapsed: Bool?
    /// Who is in the group, shown while it is folded away — a count alone
    /// answers "how many" and not "which", and folded is exactly when the
    /// rows are not there to answer it.
    var summary: String = ""
    var toggle: (() -> Void)?
    /// False when `summary` already names every row in the group.
    var showCount = true

    var body: some View {
        let line = HStack(spacing: 9) {
            if collapsed == nil, accent {
                // Project headings with a waiting row use the same lamp column
                // as their child rows. The title still starts at the shared
                // rowNameStart, so the marker is no longer stranded at x=85.
                ZStack(alignment: .leading) {
                    Color.clear
                    Circle()
                        .fill(TrayChrome.waitAccent)
                        .frame(
                            width: TrayChrome.identityLampSize,
                            height: TrayChrome.identityLampSize
                        )
                        .offset(x: TrayChrome.sectionAccentPrefix)
                }
                .frame(width: TrayChrome.sectionHeaderLeadWidth, height: 14, alignment: .center)
            } else {
                Group {
                    if let collapsed {
                        Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .opacity(0.6)
                    } else {
                        Color.clear
                    }
                }
                // Reserve the disclosure column even for a non-foldable group.
                // The row identity now has an icon, a status lamp, and two small
                // gaps before its name. Match that optical start here so section
                // headings do not appear to drift left of every agent name.
                // The lead width plus the 9pt gap keeps the heading on the
                // exact same baseline column as the row identity text.
                .frame(width: TrayChrome.sectionHeaderLeadWidth, height: 14, alignment: .center)
            }
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            // "No project 2 Pi · Amp" — two names and a 2. The count only
            // earns its place when the names do not already give it.
            if showCount {
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .opacity(0.7)
                    .foregroundStyle(accent ? TrayChrome.waitAccent : Color.secondary)
            }
            if !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 11))
                    .opacity(0.55)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, TrayChrome.padX)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)

        if let toggle {
            Button(action: toggle) { line.contentShape(Rectangle()) }
                .buttonStyle(.plain)
        } else {
            line
        }
    }
}

@MainActor
struct TrayPanel: View {
    @ObservedObject var store: StatusStore
    @State fileprivate var measuredHeight: CGFloat = 0
    /// Folding is opt-in and per-panel. A fresh glance shows every row; the
    /// header must never claim five sessions while the list silently shows one.
    @State fileprivate var folded: Set<String> = []
    @State fileprivate var query = ""
    @State fileprivate var searchActive = false
    @State fileprivate var filterPhase = ""
    @State fileprivate var filterOutcome = ""
    @State fileprivate var filterAgentRaw = ""

    /// Row key the keyboard has selected, if any.
    @State fileprivate var selectedKey: String?
    @FocusState fileprivate var listFocused: Bool

    fileprivate func toggleFold(_ id: String) {
        // A panel that repaints itself every couple of seconds cannot afford
        // hard cuts: a block of rows appearing instantly is indistinguishable
        // from a reorder, and you re-read the whole list to find out which it
        // was. Short and flat — this is a menu-bar panel, not a launch screen.
        withAnimation(.easeOut(duration: 0.16)) {
            if folded.contains(id) { folded.remove(id) } else { folded.insert(id) }
        }
    }

    /// Rows in the order the keyboard walks them: what is actually on screen,
    /// so a folded group is skipped rather than silently selected.
    fileprivate func visibleRows(_ groups: [RowGroup]) -> [AgentRow] {
        groups.flatMap { group -> [AgentRow] in
            if group.foldable && TrayFold.isCollapsed(group.id, manuallyFolded: folded) { return [] }
            return group.rows
        }
    }

    fileprivate func moveSelection(_ delta: Int, in groups: [RowGroup]) {
        let rows = visibleRows(groups)
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.rowKey == selectedKey }
        let next: Int
        if let current {
            next = min(max(current + delta, 0), rows.count - 1)
        } else {
            next = delta > 0 ? 0 : rows.count - 1
        }
        selectedKey = rows[next].rowKey
    }

    fileprivate func activateSelection(_ groups: [RowGroup]) {
        guard let key = selectedKey,
              let row = visibleRows(groups).first(where: { $0.rowKey == key }) else { return }
        store.primaryAction(row)
    }

    /// Go-Look Closure: apply a one-shot reveal from notify / hotkey / jump.
    fileprivate func applyPendingReveal(in groups: [RowGroup]) {
        guard let key = store.pendingRevealRowKey, !key.isEmpty else { return }
        // Clear filters so the target row is not hidden by search.
        query = ""
        searchActive = false
        filterPhase = ""
        filterOutcome = ""
        filterAgentRaw = ""
        if let group = groups.first(where: { $0.rows.contains(where: { $0.rowKey == key }) }),
           group.foldable {
            folded.remove(group.id)
        }
        // Expand the glance if the target sits past the default window.
        if !store.snapshot.rows.contains(where: { $0.rowKey == key }),
           store.allRowsForDisplay.contains(where: { $0.rowKey == key }),
           !store.showAllAgents {
            store.toggleShowAllAgents()
        }
        selectedKey = key
        listFocused = true
        store.clearPendingRevealRowKey()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if searchActive || !query.isEmpty || hasSessionFilters {
                VStack(alignment: .leading, spacing: 6) {
                    TextField(store.tr(.searchSessions), text: $query)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                    if hasSessionFilters || !query.isEmpty {
                        HStack(spacing: 6) {
                            Text(String(format: store.tr(.allSessionsCount), store.allRowsForDisplay.count))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                            Spacer(minLength: 0)
                            if hasSessionFilters {
                                Button(store.tr(.filterClear)) {
                                    filterPhase = ""
                                    filterOutcome = ""
                                    filterAgentRaw = ""
                                }
                                .font(.system(size: 10.5))
                                .buttonStyle(.plain)
                            }
                        }
                        sessionFilterBar
                    }
                }
                .padding(.horizontal, TrayChrome.padX)
                .padding(.bottom, 8)
            }
            missedNotice
            maintenanceNotice

            if filteredRows.isEmpty {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !hasSessionFilters {
                    emptyState
                } else {
                    ContentUnavailableView(store.tr(.searchNoResults), systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 26)
                }
            } else {
                agentList
            }
        }
        .frame(width: TrayChrome.width)
        // StatusPanelController owns the rounded material surface. Content is
        // transparent and pinned to that surface's exact bounds: one owner,
        // one rect, no extra top or bottom inset.
        // Visibility is owned by StatusPanelController. A hosting view appears
        // when the hidden panel is constructed, not when the user opens it;
        // tying cadence to SwiftUI onAppear left the app in its 2 s foreground
        // probe mode permanently.
    }

    private var header: some View {
        // No lamp here.
        //
        // The menu-bar mark sits about 40px above this line, same shape, same
        // colour, driven by the same `glance`. The header's job is to say what
        // the rows cannot; repeating the thing the user just clicked on is the
        // opposite. The status word keeps the glance colour, which is the part
        // that carried information.
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 10) {
                HStack(spacing: 6) {
                    if store.isRefreshing {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    // Bigger, because it is now the only thing in the header.
                    // Dropping the 18pt mark was right — it restated the lamp
                    // the user had just clicked — but the padding stayed, and
                    // a 13pt label alone in a 40pt band reads as a leftover.
                    if store.isRefreshing {
                        Text(store.tr(.refreshing))
                            .foregroundStyle(.secondary)
                    } else if headerStates.isEmpty {
                        Text(headerTitle)
                            .foregroundStyle(store.snapshot.glance.lampColor)
                    } else {
                        ForEach(Array(headerStates.enumerated()), id: \.element.0) { index, item in
                            if index > 0 {
                                Text("·").foregroundStyle(.tertiary)
                            }
                            Text("\(item.1) \(headerLabel(item.0))")
                                .foregroundStyle(headerColor(item.0))
                                .monospacedDigit()
                        }
                    }
                }
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .lineLimit(1)
                Spacer(minLength: 0)

                HStack(alignment: .center, spacing: 4) {
                    TrayIconAction(
                        systemImage: "arrow.clockwise",
                        help: store.tr(.refresh),
                        shortcut: "r"
                    ) {
                        store.refresh(reason: "manual")
                    }
                    .disabled(store.isRefreshing)

                    Menu {
                        if store.needsWaitingSignalNudge {
                            Button(store.tr(.setupWaitingSignals)) {
                                store.openSettings(
                                    focusWaitingSignals: true,
                                    focusWaitingAgent: store.firstLiveWaitingNoneAgent
                                )
                            }
                            Divider()
                        }
                        if store.snapshot.rows.contains(where: \.waiting) {
                            Button(store.tr(.jumpToOldest)) { store.focusOldestWait() }
                            Button(store.tr(.clearWaiting)) { store.clearWaiting() }
                            Divider()
                        }
                        Button(store.tr(.searchSessions)) { searchActive = true }
                            .keyboardShortcut("f", modifiers: .command)
                        if !query.isEmpty {
                            Button(store.tr(.clearSearch)) { query = "" }
                        }
                        Button(store.tr(.supportHealth)) { store.openSupportHealth() }
                        Button(store.tr(.settings)) { store.openSettings() }
                            .keyboardShortcut(",", modifiers: .command)
                        Button("\(store.tr(.copyDiagnostics)) · \(PulseVersion.about)") {
                            store.copyDiagnostics()
                        }
                        Divider()
                        Button(store.tr(.quit)) { store.quit() }
                            .keyboardShortcut("q", modifiers: .command)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(
                                width: TrayChrome.headerControlSize,
                                height: TrayChrome.headerControlSize,
                                alignment: .center
                            )
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(
                        width: TrayChrome.headerControlSize,
                        height: TrayChrome.headerControlSize,
                        alignment: .center
                    )
                    .help(store.tr(.moreActions))
                    .accessibilityLabel(store.tr(.moreActions))
                }
                .frame(height: TrayChrome.headerControlSize, alignment: .center)
            }

            if !store.isRefreshing, !headerDetail.isEmpty {
                Text(headerDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, TrayChrome.padX)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private var headerTitle: String {
        let t = store.snapshot.headerTitle
        return t.isEmpty ? store.snapshot.header : t
    }

    private var headerDetail: String {
        store.snapshot.headerDetail
    }

    private var headerStates: [(TraySection, Int)] {
        TraySection.allCases.compactMap { section in
            let count = filteredRows.filter { $0.section == section }.count
            return count > 0 ? (section, count) : nil
        }
    }

    private var hasSessionFilters: Bool {
        !filterPhase.isEmpty || !filterOutcome.isEmpty || !filterAgentRaw.isEmpty
    }

    private var sessionFilterBar: some View {
        HStack(spacing: 6) {
            filterMenu(
                title: store.tr(.agents),
                selection: $filterAgentRaw,
                options: Array(Set(store.allRowsForDisplay.map(\.agent.rawValue))).sorted()
            )
            filterMenu(
                title: store.tr(.filterPhase),
                selection: $filterPhase,
                options: Array(Set(store.allRowsForDisplay.map(\.phase).filter { !$0.isEmpty })).sorted()
            )
            filterMenu(
                title: store.tr(.filterOutcome),
                selection: $filterOutcome,
                options: Array(Set(store.allRowsForDisplay.map(\.outcome).filter { !$0.isEmpty })).sorted()
            )
        }
    }

    private func filterMenu(title: String, selection: Binding<String>, options: [String]) -> some View {
        Menu {
            Button(store.tr(.supportFilterAll)) { selection.wrappedValue = "" }
            ForEach(options, id: \.self) { option in
                Button(option) { selection.wrappedValue = option }
            }
        } label: {
            Text(selection.wrappedValue.isEmpty ? title : "\(title): \(selection.wrappedValue)")
                .font(.system(size: 10.5))
                .lineLimit(1)
        }
    }

    private var filteredRows: [AgentRow] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [AgentRow]
        if text.isEmpty && !hasSessionFilters {
            base = store.snapshot.rows
        } else {
            // Search/filter walk the full retain index (up to 500/agent), not
            // the twelve-row glance window.
            base = store.allRowsForDisplay
        }
        return base.filter { row in
            if !filterAgentRaw.isEmpty, row.agent.rawValue != filterAgentRaw { return false }
            if !filterPhase.isEmpty, row.phase != filterPhase { return false }
            if !filterOutcome.isEmpty, row.outcome != filterOutcome { return false }
            guard !text.isEmpty else { return true }
            return [
                row.agent.displayName, row.agent.rawValue, row.task, row.project,
                row.cwd, row.sessionID, row.tool, row.skill, row.phase,
                row.outcome, row.model, row.mode,
            ].contains { $0.localizedCaseInsensitiveContains(text) }
        }
    }

    private func headerLabel(_ section: TraySection) -> String {
        switch section {
        case .needsYou: return store.tr(.waitingN)
        case .running: return store.tr(.runningN)
        case .stalled: return store.tr(.sectionStalled).lowercased()
        case .recent: return store.tr(.recentN)
        }
    }

    private func headerColor(_ section: TraySection) -> Color {
        switch section {
        case .needsYou: return GlanceKind.waiting.lampColor
        case .running: return GlanceKind.running.lampColor
        case .stalled: return GlanceKind.stalled.lampColor
        case .recent: return .secondary
        }
    }

    /// The panel only ever showed the present moment. Coming back to it, the
    /// first question is what happened while you were gone.
    @ViewBuilder
    private var missedNotice: some View {
        if store.missedWhileAway > 0 {
            Button { store.clearMissedWhileAway() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 11))
                    Text(String(format: store.tr(.whileAway), store.missedWhileAway))
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, TrayChrome.padX)
                .padding(.bottom, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else if let incomplete = store.trayScanIncompleteNotice {
            Button { store.openSupportHealth() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.system(size: 11))
                    Text(store.tr(.trayScanIncomplete))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .opacity(0.55)
                }
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .padding(.horizontal, TrayChrome.padX)
                .padding(.bottom, 10)
                .contentShape(Rectangle())
                .accessibilityLabel(incomplete)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var maintenanceNotice: some View {
        if let notice = store.maintenanceNoticeText {
            Button { store.performMaintenanceNoticeAction() } label: {
                HStack(spacing: 7) {
                    Image(systemName: store.waitingNotificationNeedsSetup
                        ? "bell.badge"
                        : "exclamationmark.circle")
                        .font(.system(size: 11, weight: .medium))
                    Text(notice)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .opacity(0.55)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(store.waitingNotificationNeedsSetup ? .red : .orange)
                .padding(.horizontal, TrayChrome.padX)
                .padding(.bottom, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(store.tr(.settings))
        }
    }

    /// Empty is the first thing most people see. Say what Pulse is waiting for
    /// and give the one action that makes Waiting work, instead of a dead end.
    private var emptyState: some View {
        VStack(spacing: 10) {
            PulseMarkView(size: 40, tone: Color.secondary.opacity(0.45))
            Text(store.tr(.noAgentsDetected))
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(store.tr(.emptyHint))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(store.tr(.setupWaitingSignals)) {
                store.openSettings(focusWaitingSignals: true)
            }
            .buttonStyle(.link)
            .font(.system(size: 11, weight: .medium))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 20)
    }

    /// A tray group: heading, count, and its rows.
    fileprivate struct RowGroup: Identifiable {
        var id: String
        var title: String
        var count: Int
        var accent: Bool
        var rows: [AgentRow]
        /// The heading is a location, so rows underneath must not repeat it.
        var statesPath = false
        /// The heading doubles as a disclosure control when the user chooses
        /// to fold the otherwise-visible rows.
        var foldable = false
        /// Not a project — the bucket for rows that have no location at all.
        var isBucket = false
    }

    /// A heading earns its line only when it separates things.
    fileprivate func showHeading(_ group: RowGroup, of groups: [RowGroup]) -> Bool {
        guard groups.count > 1 else { return false }
        // Grouping by project produced "~/Documents/Cursor 1" over exactly one
        // row whose own second line said "~/Documents/Cursor". Two lines, one
        // fact, and a whole row of height spent on it.
        if group.rows.count == 1 { return false }
        return true
    }

    /// Sentinel for "this row has no location", kept out of the localized
    /// strings so the grouping key does not change with the language.
    fileprivate static let bucketKey = "\u{0}no-project"

    /// Rows grouped under a heading.
    ///
    /// The list was sorted by urgency but rendered as one flat stack, so five
    /// rows read as five equals. A heading costs one line and answers "which of
    /// these actually need me" before any row is read.
    ///
    /// Grouping by project is the alternative for people running several repos
    /// at once; a project containing a wait sorts first, so the urgent case
    /// still surfaces without reading every heading.
    fileprivate var groupedRows: [RowGroup] {
        let rows = filteredRows
        switch store.trayGrouping {
        case .status:
            let present = TraySection.allCases.filter { s in rows.contains { $0.section == s } }
            return present.map { section in
                let group = rows.filter { $0.section == section }
                return RowGroup(
                    id: "s\(section.rawValue)",
                    title: store.tr(section.titleKey),
                    count: group.count,
                    accent: section == .needsYou,
                    rows: group,
                    foldable: TrayFold.foldable(
                        section: section,
                        groupCount: present.count,
                        rowCount: group.count,
                        totalRows: rows.count
                    )
                )
            }
        case .project:
            var order: [String] = []
            var byProject: [String: [AgentRow]] = [:]
            for row in rows {
                // Key on the real location. Falling back to the agent name made
                // headings that restated the row beneath them ("Amp 1" over a
                // row whose only content was Amp).
                let path = row.displayPath
                // Home is not a project; everything without a real location
                // shares one bucket instead of inventing names for it.
                let key = path.isEmpty ? Self.bucketKey : path
                if byProject[key] == nil { order.append(key) }
                byProject[key, default: []].append(row)
            }
            // Projects with something waiting float up; ties keep row order.
            let ranked = order.enumerated().sorted { a, b in
                let aWait = byProject[a.element]?.contains(where: \.waiting) ?? false
                let bWait = byProject[b.element]?.contains(where: \.waiting) ?? false
                if aWait != bWait { return aWait && !bWait }
                return a.offset < b.offset
            }
            return ranked.map { entry in
                let group = byProject[entry.element] ?? []
                let hasWaiting = group.contains(where: \.waiting)
                let bucket = entry.element == Self.bucketKey
                return RowGroup(
                    id: "p\(entry.element)",
                    title: bucket ? store.tr(.noProject) : entry.element,
                    count: group.count,
                    accent: hasWaiting,
                    rows: group,
                    statesPath: true,
                    // Project grouping exists for people running several repos,
                    // and was the one mode where nothing folded: a flat list of
                    // every project, however many. A project with a wait in it
                    // is never folded away.
                    foldable: TrayFold.foldableProject(
                        hasWaiting: hasWaiting,
                        groupCount: ranked.count,
                        rowCount: group.count,
                        totalRows: rows.count
                    ),
                    isBucket: bucket
                )
            }
        }
    }

    private var agentList: some View {
        // Height comes from the content now. It used to be a hand-summed
        // estimate (44 + 20 - 4 + 14 + 28 + 8) that any font or spacing change
        // silently invalidated — the panel and its contents disagreed and there
        // was no way to notice except by looking.
        // 420 pt regularly orphaned the next group heading at the bottom
        // ("Recent 1" with no row), which reads like missing data rather than
        // scrollable content. The wait row is intentionally information-rich
        // (reason, signal, age, and two actions), so a short cap cut the next
        // session in half even when only seven rows existed. Keep the default
        // glance tall enough for complete rows; scrolling remains the guard
        // for large workspaces.
        let cap: CGFloat = store.showAllAgents ? 700 : 660

        let groups = groupedRows
        return VStack(spacing: 0) {
            ScrollViewReader { scrollProxy in
                ScrollView {
                // Not pinned.
                //
                // A pinned heading has to be opaque so rows can scroll under
                // it, and every opaque thing laid over the panel's material
                // compounds with it into a lighter band — which is what both
                // 0.27.1 and 0.27.2 showed, whichever material was used. A
                // panel that caps at a handful of rows gains nothing from
                // sticky headings, and un-pinning removes the band by
                // construction rather than by picking a better shade.
                // At most twelve rows are visible. A LazyVStack inside a
                // ScrollView reports the viewport proposal rather than its
                // materialised content height on some macOS builds, pinning
                // the list to the 420 pt cap and leaving a large empty tail.
                // A regular stack is cheap at this scale and measures exactly.
                VStack(spacing: 0) {
                    ForEach(groups) { group in
                        Section {
                            // No rules between rows: whitespace already
                            // separates them, and a line every 56pt turns a
                            // short list into a table.
                            if !(group.foldable && TrayFold.isCollapsed(group.id, manuallyFolded: folded)) {
                                ForEach(group.rows) { row in
                                    AgentRowButton(
                                        row: row,
                                        store: store,
                                        pathInHeading: group.statesPath && showHeading(group, of: groups),
                                        selected: selectedKey == row.rowKey,
                                        compact: filteredRows.count >= TrayFold.crowdedFrom
                                    )
                                    .id(row.rowKey)
                                    .transition(.opacity)
                                }
                            }
                        } header: {
                            // A lone heading restates the panel header directly
                            // above it — "2 running / Cursor · Amp" followed by
                            // "Running 2". Headings earn their line only when
                            // there is more than one group to tell apart, and a
                            // heading over a single row is just that row's own
                            // path on a line of its own.
                            if showHeading(group, of: groups) {
                                let isFolded = group.foldable
                                    && TrayFold.isCollapsed(group.id, manuallyFolded: folded)
                                SectionHeader(
                                    title: group.title,
                                    count: group.count,
                                    accent: group.accent,
                                    collapsed: group.foldable ? isFolded : nil,
                                    summary: isFolded ? TrayFold.summary(group.rows) : "",
                                    toggle: group.foldable ? { toggleFold(group.id) } : nil,
                                    showCount: !(isFolded && TrayFold.summaryNamesEveryRow(group.rows))
                                )
                            }
                        }
                    }
                }
                // Rows fade rather than pop. A list that rebuilds itself every
                // two seconds otherwise makes "a session appeared" and "the
                // order changed" look identical.
                .animation(.easeOut(duration: 0.16), value: store.snapshot.rows.map(\.rowKey))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                    }
                )
                }
                .scrollIndicators(.visible)
                .frame(height: min(max(measuredHeight, 56), cap))
                .onPreferenceChange(ContentHeightKey.self) { measuredHeight = $0 }
                // Do not paint a bottom fade over the material. It reads as a
                // second horizontal chrome band on a short popover and was the
                // same visual failure as the old system container bars. The
                // native scroll indicator already communicates overflow without
                // introducing another surface or stealing contrast from the
                // final row.
                // The panel is usually summoned by a shortcut, so the hand is
                // already on the keyboard; finishing with the mouse is the awkward
                // part. Arrow keys walk the visible rows, Return focuses the
                // terminal, Escape gives up.
                .focusable()
                // Keep arrow/Return navigation without drawing AppKit's blue
                // focus ring around the ScrollView. The rounded panel clips
                // that ring into a stray horizontal blue rule and two edge
                // fragments, which looks like broken panel chrome.
                .focusEffectDisabled()
                .focused($listFocused)
                .onAppear { listFocused = true }
                .onKeyPress(.downArrow) { moveSelection(1, in: groups); return .handled }
                .onKeyPress(.upArrow) { moveSelection(-1, in: groups); return .handled }
                .onKeyPress(.return) { activateSelection(groups); return .handled }
                .onKeyPress(.escape) { selectedKey = nil; return .handled }
                .onKeyPress(.space) {
                    // Space folds whichever group owns the selection — the fold
                    // control is a heading, and headings are not in the tab order.
                    guard let key = selectedKey,
                          let group = groups.first(where: { g in
                              g.foldable && g.rows.contains { $0.rowKey == key }
                          })
                    else { return .ignored }
                    toggleFold(group.id)
                    return .handled
                }
                .onChange(of: selectedKey) { _, key in
                    guard let key else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        scrollProxy.scrollTo(key, anchor: .center)
                    }
                }
                .onAppear { applyPendingReveal(in: groups) }
                .onChange(of: store.pendingRevealRowKey) { _, _ in
                    applyPendingReveal(in: groups)
                }
            }

            if !query.isEmpty || hasSessionFilters {
                EmptyView()
            } else if store.snapshot.hiddenCount > 0 {
                overflowButton(
                    String(format: store.tr(.andMore), store.snapshot.hiddenCount)
                ) { store.toggleShowAllAgents() }
            } else if store.showAllAgents, store.snapshot.totalCount > SnapshotBuilder.maxVisibleRows {
                overflowButton(store.tr(.showLess)) { store.toggleShowAllAgents() }
            }

            // Sessions beyond the per-agent cap: say so rather than pretend
            // they do not exist. Always show the searchable total when expanded.
            if query.isEmpty, !hasSessionFilters {
                if store.snapshot.cappedSessions > 0 {
                    Text(String(format: store.tr(.cappedSessions), store.snapshot.cappedSessions))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, TrayChrome.padX)
                        .padding(.bottom, 4)
                }
                if store.snapshot.totalCount > SnapshotBuilder.maxVisibleRows {
                    Text(String(format: store.tr(.allSessionsCount), store.snapshot.totalCount))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, TrayChrome.padX)
                        .padding(.bottom, 8)
                }
            }
        }
    }

    private func overflowButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, TrayChrome.padX)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

}

// MARK: - Agent row

/// Give the whole row button semantics only when it can complete a real
/// navigation task. Observational rows remain readable content; they no longer
/// advertise a click that either did nothing or merely opened Finder.
private struct ConditionalRowButton<Content: View>: View {
    let actionable: Bool
    let action: () -> Void
    let content: Content

    init(
        actionable: Bool,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.actionable = actionable
        self.action = action
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if actionable {
            Button(action: action) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }
}

@MainActor
private struct AgentRowButton: View {
    let row: AgentRow
    /// Must be observed, not merely held.
    ///
    /// This was `let store: StatusStore`. The row's body reads `store.tr(...)`
    /// for its title and badge, but a plain `let` does not subscribe: when the
    /// language changed, `TrayPanel` re-rendered while every row kept the same
    /// `row` value and the same store *reference*, so SwiftUI saw identical
    /// inputs and skipped the child entirely. The result was a panel whose
    /// chrome was English and whose rows were still Chinese.
    @ObservedObject var store: StatusStore
    /// True when a project heading directly above already states this path, so
    /// the row must not repeat it. 0.25 wrote the rule "a fact appears once,
    /// row > heading > header" and then applied it only to the panel header —
    /// grouped by project, every path was printed twice.
    ///
    /// Declared after `store` because the memberwise initialiser takes
    /// arguments in declaration order, and the call site passes it last.
    var pathInHeading = false
    /// True when keyboard navigation has this row selected.
    var selected = false
    /// Preserve the core hierarchy when the list is crowded; only secondary
    /// execution context is sacrificed.
    var compact = false
    @State private var hovering = false

    private var highlight: Color {
        if selected { return Color.primary.opacity(0.10) }
        return hovering ? Color.primary.opacity(0.055) : .clear
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Keep the row action and its overflow menu as sibling controls.
            // Nesting Menu inside Button made a click on “…” bubble into the
            // primary focus action on macOS, especially when the menu was
            // revealed by keyboard focus rather than hover.
            ZStack(alignment: .topTrailing) {
                ConditionalRowButton(
                    actionable: row.canFocusTerminal,
                    action: { store.primaryAction(row) }
                ) {
                    HStack(
                        alignment: .top,
                        spacing: TrayChrome.iconToIdentityGap
                    ) {
                        // The icon and identity line share the same top edge.
                        // A former 3pt optical nudge made the icon visibly sink
                        // below the lamp/name line, especially in CJK mode.
                        AgentIconView(id: row.agent)

                        VStack(alignment: .leading, spacing: 2) {
                            // Agent identity is text, not an icon-recognition
                            // quiz. With the full 33-agent roster (ten of them
                            // Pulse-made), an
                            // icon alone cannot answer "which agent?".
                            HStack(
                                alignment: .center,
                                spacing: TrayChrome.identityLampToNameGap
                            ) {
                                Circle()
                                    .fill(statusIndicatorColor)
                                    .frame(
                                        width: TrayChrome.identityLampSize,
                                        height: TrayChrome.identityLampSize
                                    )
                                    // Reserve a stable identity-line slot so
                                    // the lamp stays optically centred while
                                    // the Agent/source labels vary in font.
                                    .frame(width: TrayChrome.identityLampSize, height: 18)
                                    .accessibilityHidden(true)
                                Text(row.agent.displayName)
                                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.secondary)
                                if let sourceLabel {
                                    Text(sourceLabel)
                                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                                        // Evidence labels are important state,
                                        // not decorative metadata. Tertiary
                                        // contrast made Privacy-limited and
                                        // Local cache disappear in light mode.
                                        .foregroundStyle(.secondary.opacity(0.78))
                                }
                                Spacer(minLength: 6)
                                statusChip
                            }

                            // Encoding 3 of 3: a real session is semibold, a
                            // bare process is not. The title no longer competes
                            // horizontally with age, state and the menu.
                            Text(heroTitle)
                                .font(.system(
                                    size: 13,
                                    weight: row.isProcessOnly ? .regular : .semibold,
                                    design: .rounded
                                ))
                                .foregroundStyle(.primary)
                                // Keep two lines for real session titles even when
                                // the list is crowded — the title tail is the
                                // identifying half. Process-only stays one line.
                                .lineLimit(row.isProcessOnly ? 1 : 2)
                                .fixedSize(horizontal: false, vertical: true)

                            // 0.91 Row Story — one sentence: what / why on tray.
                            if !storyLine.isEmpty {
                                Text(storyLine)
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(.primary.opacity(0.82))
                                    .lineLimit(compact ? 1 : 2)
                                    .truncationMode(.tail)
                            }

                            if !contextLine.isEmpty {
                                Text(contextLine)
                                    .font(.system(size: 10.75))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(compact ? 1 : 2)
                                    .truncationMode(.middle)
                            }

                            // Motion only — Now / Changed / stalled age.
                            if !signalLine.isEmpty {
                                Text(signalLine)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }

                            // EXPERIENCE 观测行: model · tokens · progress — default,
                            // never Details-only. Disappears when empty (0.80).
                            if !observationLine.isEmpty {
                                Text(observationLine)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .lineLimit(compact ? 1 : 2)
                                    .truncationMode(.tail)
                            }

                            // Waiting rows get a third line, because the actual
                            // question is the entire point of the product.
                            if let detail = store.localizedWaitDetail(row) {
                                Text(Self.truncate(detail, 78))
                                    .font(.system(size: 11))
                                    .foregroundStyle(TrayChrome.waitAccent)
                                    .lineLimit(2)
                            }

                        }
                    }
                    .padding(.trailing, hasSecondaryActions ? TrayChrome.headerControlSize + 4 : 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, TrayChrome.rowLeadingInset)
                    .padding(.trailing, TrayChrome.padX)
                    .padding(.vertical, compact ? 5 : (row.isProcessOnly ? 6 : 7))
                    // The wait gutter overlays its own inset and never
                    // participates in layout. Waiting and non-waiting identity
                    // columns therefore remain exactly aligned.
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(accentFill)
                            .frame(width: accentWidth)
                            .padding(.leading, 6)
                            .padding(.vertical, 4)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityText)
                .accessibilityHint(
                    row.isProcessOnly
                        ? store.tr(.supportHealth)
                        : (row.canFocusTerminal ? store.primaryActionTitle(row) : "")
                )

                if hasSecondaryActions {
                    secondaryActionsMenu
                        .opacity(hovering || selected ? 1 : 0)
                        .allowsHitTesting(hovering || selected)
                        .accessibilityHidden(false)
                        .padding(.top, 6)
                        .padding(.trailing, TrayChrome.padX)
                }
            }

            // Actions stay visible where they are urgent, and appear on hover
            // everywhere else. Showing them on every row cost ~28pt each and
            // was the main reason only three agents fit in the panel.
            if showActions {
                HStack(spacing: 16) {
                    if row.waiting {
                        Button(store.tr(.dismissWait)) { store.dismissWaiting(row) }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11, weight: .medium))
                        // A countdown you cannot stop is a worse deal than no
                        // countdown, so the same button undoes it.
                        Button(row.isSnoozed ? store.tr(.snoozed) : store.tr(.snooze)) {
                            if row.isSnoozed { store.unsnooze(row) } else { store.snooze(row) }
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11, weight: .medium))
                    }
                    if row.canFocusTerminal {
                        Button(store.focusActionTitle(row)) { store.focusTerminal(row) }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11, weight: .medium))
                    }
                    if row.isProcessOnly {
                        Button(store.tr(.supportHealth)) { store.openSupportHealth() }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11, weight: .medium))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 48)
                .padding(.trailing, TrayChrome.padX)
                .padding(.bottom, 8)
            }
        }
        // Inset rounded, not a full-bleed rectangle.
        //
        // Every native macOS list — Mail, the Finder sidebar, Notification
        // Centre — insets its hover and selection fill and rounds it. A
        // full-width square block that runs into both edges is the web
        // convention, and in a menu-bar panel it is the single easiest thing to
        // read as "not a Mac app".
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(highlight)
                .padding(.horizontal, 6)
        )
        .onHover { hovering = $0 }
        .contextMenu {
            secondaryActionItems
        }
    }

    /// The gutter is the loudest thing in the row, so a snoozed wait must not
    /// keep it. Everything else about the row stays put — the point is that it
    /// is still there, just not shouting.
    private var accentFill: Color {
        guard row.waiting else { return .clear }
        return row.isSnoozed ? TrayChrome.waitAccent.opacity(0.28) : TrayChrome.waitAccent
    }

    private var accentWidth: CGFloat {
        guard row.waiting else { return 0 }
        if row.isSnoozed { return 3 }
        return row.isUrgentWait ? 6 : 3
    }

    private var metrics: String { store.rowMetrics(row) }
    private var nowLine: String { store.rowNowLine(row) }
    private var activityChange: String { store.rowActivityChange(row) }
    private var observationLine: String { store.rowObservationLine(row) }
    private var signalLine: String { store.rowSignalLine(row) }
    private var storyLine: String { store.rowStoryLine(row) }
    private var sourceLabel: String? {
        switch row.observationSource {
        // A real session is the normal case. Labelling every healthy row
        // "Session" adds no distinction; only degraded evidence needs a tag.
        case .session: return nil
        case .cache:
            if row.quality.isLimited {
                return store.observationQualitySummary(row)
            }
            return store.tr(.cacheEvidence)
        case .process:
            // Prefer the quality envelope: what is missing, why, and next step.
            // Never leave a bare "Process only" / "Limited data" with no path.
            return store.observationQualitySummary(row)
        }
    }

    private var showActions: Bool {
        row.waiting || hovering
    }

    private var hasSecondaryActions: Bool {
        row.waiting || row.canFocusTerminal || row.isProcessOnly
    }

    /// A compact per-session lamp makes the state of every visible Agent
    /// scannable without opening Support Health. It is deliberately derived
    /// only from facts already present on the row: red = waiting/error, orange
    /// = limited or stalled, green = live with session evidence, gray = recent
    /// or unknown.
    private var statusIndicatorColor: Color {
        if row.waiting { return GlanceKind.waiting.lampColor }
        let outcome = row.outcome.lowercased()
        if row.isStalled || row.errors > 0
            || outcome.contains("fail") || outcome.contains("cancel") {
            return GlanceKind.error.lampColor
        }
        // A process is liveness evidence, not a session feed. Keep its lamp
        // orange so the tray agrees with Support Health's Limited disposition
        // instead of visually claiming that the row is fully observed.
        if row.isProcessOnly { return .orange }
        if row.liveProcess || row.isExplicitlyRunningPhase || row.subRunning > 0 {
            return GlanceKind.running.lampColor
        }
        return GlanceKind.idle.lampColor
    }

    /// Always-present action access for keyboard and VoiceOver users.
    ///
    /// Hover actions remain a fast pointer path, but are no longer the only
    /// route to focus or waiting controls.
    private var secondaryActionsMenu: some View {
        Menu {
            secondaryActionItems
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 20)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.08 : 0.045))
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(store.tr(.moreActions))
    }

    @ViewBuilder
    private var secondaryActionItems: some View {
        Button(store.tr(.details)) { store.openAgentDetail(row) }
        if row.waiting {
            Button(store.tr(.dismissWait)) { store.dismissWaiting(row) }
            Button(row.isSnoozed ? store.tr(.snoozed) : store.tr(.snooze)) {
                if row.isSnoozed { store.unsnooze(row) } else { store.snooze(row) }
            }
        }
        if row.canFocusTerminal {
            Button(store.focusActionTitle(row)) { store.focusTerminal(row) }
        }
        if row.isProcessOnly {
            Button(store.tr(.supportHealth)) { store.openSupportHealth() }
        }
    }

    /// Session title is the row hero; process-only rows de-rank to a status phrase.
    private var heroTitle: String {
        if row.waiting {
            if let t = row.usefulTask { return Self.truncate(t, Self.heroLimit) }
            let short = AgentRow.shortProject(row.project)
            if !short.isEmpty { return short }
            return store.tr(.needsYou)
        }
        if row.isProcessOnly {
            return row.canFocusTerminal
                ? store.tr(.terminalDetectedNoDetails)
                : store.tr(.appDetectedNoDetails)
        }
        if let t = row.usefulTask {
            return Self.truncate(t, Self.heroLimit)
        }
        // Humanize the live tool — never show update_plan / Bash raw.
        if let toolTitle = store.heroToolTitle(row) {
            return Self.truncate(toolTitle, Self.heroLimit)
        }
        let short = AgentRow.shortProject(row.project)
        if !short.isEmpty { return short }
        // Agent product name is already on the identity line — do not reuse it
        // as the hero (EXPERIENCE: no agent-as-hero).
        return row.canFocusTerminal ? store.tr(.terminalSession) : store.tr(.appSession)
    }

    /// Second line: where this session is, and how long since it moved.
    ///
    /// It used to be `Agent · project`, which restated the icon and — when the
    /// folder happened to match the agent — printed "Cursor · Cursor". The two
    /// facts a row could never state were *where* and *how long*; both were
    /// collected all along.
    private var contextLine: String {
        return store.rowContextLine(row, omitPath: pathInHeading)
    }

    /// Only abnormal states get a badge.
    ///
    /// Running was announced three times over — panel header, section header,
    /// and a green pill on every row. Running with a live session is the
    /// ordinary case, and the ordinary case does not need saying: **no badge
    /// means running**.
    @ViewBuilder
    private var statusChip: some View {
        if row.isSnoozed {
            // The row keeps its place and says why it is quiet. Hiding it would
            // make "Later" a button people are afraid to press.
            StatusChip(kind: .snoozed, label: store.snoozeLabel(row))
        } else if row.waiting {
            let kind = row.waitKind.isEmpty
                ? store.tr(.needsYou)
                : store.localizedWaitKind(row.waitKind)
            let dur = store.waitDurationLabel(row)
            StatusChip(
                kind: .waiting,
                label: dur.isEmpty ? kind : "\(kind) · \(dur)"
            )
        } else if row.isStalled {
            // Live for twenty minutes with nothing happening. Never surfaced
            // before, and it looked exactly like a healthy session.
            StatusChip(kind: .process, label: store.tr(.stalled))
        } else if row.subRunning > 0 {
            StatusChip(kind: .running, label: "sub \(row.subRunning)↑")
        } else if row.subTotal > 0 {
            StatusChip(kind: .running, label: "sub \(row.subTotal)")
        } else if row.isRecentOnly {
            StatusChip(kind: .recent, label: store.tr(.recent))
        }
        // Live with a session and nothing unusual: no badge.
    }

    private var accessibilityText: String {
        var parts = [heroTitle, row.agent.displayName]
        let state: String
        if row.waiting {
            state = row.waitKind.isEmpty ? store.tr(.needsYou) : store.localizedWaitKind(row.waitKind)
        } else if row.isProcessOnly {
            state = store.tr(.limitedData)
        } else if row.isStalled {
            state = store.tr(.stalled)
        } else if row.isRecentOnly {
            state = store.tr(.recent)
        } else {
            state = store.tr(.running)
        }
        parts.append(state)
        if !storyLine.isEmpty { parts.append(storyLine) }
        if !contextLine.isEmpty { parts.append(contextLine) }
        // Canonical dynamic summary — do not also append activityChange +
        // metrics; that duplicated Context / Changed facts for VoiceOver.
        if !signalLine.isEmpty { parts.append(signalLine) }
        if !observationLine.isEmpty, observationLine != signalLine {
            parts.append(observationLine)
        }
        if row.waiting {
            let line = store.localizedWaitLine(row)
            if !line.isEmpty { parts.append(line) }
        }
        return parts.joined(separator: ", ")
    }

    /// Hard ceiling on the row hero, in characters.
    ///
    /// It is a guard against a pathological title, not the thing that shapes
    /// the row — two lines at 400pt hold roughly eighty, so at 96 SwiftUI's
    /// own wrapping decides where the line ends and this only stops a title
    /// that would take the whole panel. It used to be 72, which is under what
    /// the panel can show: the string was cut before it was ever laid out.
    static let heroLimit = 96

    private static func truncate(_ s: String, _ n: Int) -> String {
        guard s.count > n else { return s }
        let cut = String(s.prefix(n - 1))
        // Cutting mid-word ("Review repository for bugs a…") reads as damage.
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > n / 2 {
            return String(cut[..<space]) + "…"
        }
        return cut + "…"
    }
}

/// Compact icon action for the tray's single action bar.
private struct TrayIconAction: View {
    let systemImage: String
    let help: String
    var shortcut: Character? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .frame(
                    width: TrayChrome.headerControlSize,
                    height: TrayChrome.headerControlSize,
                    alignment: .center
                )
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hovering ? Color.primary.opacity(0.08) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .modifier(OptionalShortcut(shortcut: shortcut))
    }
}

private struct OptionalShortcut: ViewModifier {
    let shortcut: Character?
    func body(content: Content) -> some View {
        if let shortcut {
            content.keyboardShortcut(KeyEquivalent(shortcut), modifiers: .command)
        } else {
            content
        }
    }
}

// MARK: - Settings


@MainActor
struct SettingsView: View {
    @ObservedObject var store: StatusStore
    @State private var confirmDuplicateRemoval = false

    var body: some View {
        Form {
            generalSection
            notificationsSection
            waitingSignalsSection
            shortcutsSection
            if !store.waitHistory.isEmpty { historySection }
            aboutSection
        }
        .formStyle(.grouped)
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            store.hooksStatus = HooksSupport.probeStatus()
            store.refreshInstallTruth()
            PulseNotify.refreshAuthorization()
        }
        .alert(
            store.tr(.removeDuplicateApps),
            isPresented: $confirmDuplicateRemoval
        ) {
            Button(store.tr(.cancel), role: .cancel) {}
            Button(store.tr(.moveToTrash), role: .destructive) {
                store.recycleDuplicateApps()
            }
        } message: {
            Text(String(
                format: store.tr(.removeDuplicateAppsConfirm),
                store.installReport.removableDuplicates.count
            ))
        }
    }

    // MARK: General

    private var generalSection: some View {
        Section(store.tr(.general)) {
            Toggle(store.tr(.liveUpdates), isOn: $store.autoProbe)
                .onChange(of: store.autoProbe) { _, _ in store.saveSettings() }
            Toggle(store.tr(.agentDataAccess), isOn: Binding(
                get: { store.allowAppData },
                set: { store.setAllAppDataAccess($0) }
            ))
            Text(store.tr(.agentDataAccessHint))
                .font(.caption)
                .foregroundStyle(.secondary)
            DisclosureGroup(
                isExpanded: Binding(
                    get: { store.settingsExpandAppDataScopes },
                    set: { store.settingsExpandAppDataScopes = $0 }
                ),
                content: {
                Text(store.tr(.agentDataAccessScopeHint))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(store.tr(.agentDataAccessSkipHint))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                ForEach(store.protectedAppDataAgents, id: \.self) { agent in
                    Toggle(isOn: Binding(
                        get: { store.allowAppData || store.appDataAgents.contains(agent) },
                        set: { enabled in store.setAppDataAccess(for: agent, enabled: enabled) }
                    )) {
                        HStack(spacing: 6) {
                            AgentIconView(id: agent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.displayName)
                                Text(String(format: store.tr(.agentDataAccessAgentDetail), agent.displayName, store.appDataScopeDescription(for: agent)))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .disabled(store.allowAppData)
                    .listRowBackground(
                        store.settingsFocusAppDataAgent == agent
                            ? Color.accentColor.opacity(0.12)
                            : Color.clear
                    )
                }
            },
                label: { Text(store.tr(.agentDataAccessScopes)) }
            )
            Toggle(store.tr(.launchAtLogin), isOn: $store.launchAtLogin)
                .onChange(of: store.launchAtLogin) { _, _ in store.saveSettings() }
            Picker(store.tr(.language), selection: $store.language) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.menuLabel).tag(lang)
                }
            }
            .onChange(of: store.language) { _, _ in store.saveSettings() }
            Picker(store.tr(.groupingLabel), selection: $store.trayGrouping) {
                ForEach(TrayGrouping.allCases) { mode in
                    Text(store.tr(mode.labelKey)).tag(mode)
                }
            }
            .onChange(of: store.trayGrouping) { _, _ in store.saveSettings() }
            // Twenty minutes was compiled in and fits nobody in particular: a
            // long build is not stalled at twenty, a short exchange is stuck
            // well before it. "Never" has to be reachable too — on a machine
            // that runs hour-long jobs the badge is pure noise.
            Picker(store.tr(.stallAfter), selection: $store.stallMinutes) {
                Text(store.tr(.stallOff)).tag(0)
                ForEach([5, 10, 20, 30, 60], id: \.self) { m in
                    Text(String(format: store.tr(.minutesShort), m)).tag(m)
                }
            }
            .onChange(of: store.stallMinutes) { _, _ in store.saveSettings() }
            Picker(store.tr(.snooze), selection: $store.snoozeMinutes) {
                ForEach([5, 10, 30, 60], id: \.self) { m in
                    Text(String(format: store.tr(.minutesShort), m)).tag(m)
                }
            }
            .onChange(of: store.snoozeMinutes) { _, _ in store.saveSettings() }
        }
    }

    // MARK: Notifications

    private var notificationsSection: some View {
        Section(store.tr(.notificationsSection)) {
            if store.notifyAuthorized == nil {
                Label(store.tr(.notifyNotConfigured), systemImage: "bell.badge")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(store.tr(.enableNotifications)) {
                    store.requestNotificationAuthorization()
                }
            } else if store.notifyAuthorized == false {
                // A denied prompt used to leave these toggles reading "on"
                // while nothing could ever fire.
                Label(store.tr(.notifyDenied), systemImage: "bell.slash")
                    .font(.caption)
                    .foregroundStyle(GlanceKind.error.lampColor)
                Text(store.tr(.notifyDeniedPersistentHint))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(store.tr(.openNotificationSettings)) {
                    store.openSystemNotificationSettings()
                }
            }
            notificationToggle(
                store.tr(.notifications),
                preference: \StatusStore.notifyOnIdle
            )
            notificationToggle(
                store.tr(.notifyWaiting),
                preference: \StatusStore.notifyOnWaiting
            )
            notificationToggle(
                store.tr(.playSound),
                preference: \StatusStore.playSoundOnWaiting
            )

            Toggle(store.tr(.quietHours), isOn: $store.quietHoursEnabled)
                .onChange(of: store.quietHoursEnabled) { _, _ in store.saveSettings() }
            if store.quietHoursEnabled {
                Text(store.tr(.quietHoursHint))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                MinutePicker(
                    label: store.tr(.quietStart),
                    minutes: $store.quietStartMinute
                ) { store.saveSettings() }
                MinutePicker(
                    label: store.tr(.quietEnd),
                    minutes: $store.quietEndMinute
                ) { store.saveSettings() }
            }

            if !mutableAgents.isEmpty {
                DisclosureGroup(store.tr(.muteAgents)) {
                    Text(store.tr(.muteHint))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    ForEach(mutableAgents, id: \.self) { agent in
                        Toggle(isOn: Binding(
                            get: { store.mutedAgents.contains(agent) },
                            set: { _ in store.toggleMute(agent) }
                        )) {
                            HStack(spacing: 6) {
                                AgentIconView(id: agent)
                                Text(agent.displayName)
                            }
                        }
                    }
                }
            }
        }
    }

    /// The stored preference can remain enabled while macOS has denied or not
    /// configured notification access. Showing that raw value as an enabled
    /// switch is misleading: the user sees "on" beside copy saying it cannot
    /// fire. Render the effective value instead; once permission is granted,
    /// the saved preference comes back without being silently discarded.
    private func notificationToggle(
        _ title: String,
        preference: ReferenceWritableKeyPath<StatusStore, Bool>
    ) -> some View {
        Toggle(title, isOn: Binding(
            get: { store.notifyAuthorized == true && store[keyPath: preference] },
            set: { enabled in
                guard store.notifyAuthorized == true else { return }
                store[keyPath: preference] = enabled
                store.saveSettings()
            }
        ))
        .tint(store.notifyAuthorized == true ? .accentColor : .gray)
        .disabled(store.notifyAuthorized != true)
    }

    /// Agents worth offering a mute for: whatever Pulse has actually seen,
    /// plus anything already muted so the switch never disappears.
    private var mutableAgents: [AgentID] {
        var seen = Set(store.snapshot.rows.map(\.agent))
        seen.formUnion(store.mutedAgents)
        return seen.sorted {
            (AgentID.priority.firstIndex(of: $0) ?? 999) < (AgentID.priority.firstIndex(of: $1) ?? 999)
        }
    }

    // MARK: Waiting signals

    private var waitingSignalsSection: some View {
        Section(store.tr(.waitingSignals)) {
            if store.settingsFocusWaitingSignals {
                Label(store.attentionBridgeFocusHintText(), systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text(store.waitingReachStepsText())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(store.tr(.ensurePulseHook)) {
                        store.ensurePulseHookLauncher()
                    }
                    Text(
                        store.pulseHookLauncherReady
                            ? store.tr(.pulseHookReady)
                            : store.tr(.pulseHookMissing)
                    )
                    .font(.caption2)
                    .foregroundStyle(store.pulseHookLauncherReady ? Color.secondary : Color.orange)
                }
                Text(store.tr(.ensurePulseHookHint))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(store.tr(.hooksHint))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button(store.tr(.installHooks)) { store.installHooks() }
                if store.hooksInstalled {
                    Button(store.tr(.uninstallHooks), role: .destructive) {
                        store.uninstallHooks()
                    }
                }
            }
            Text(store.hooksStatus.label(lang: store.lang))
                .font(.caption2)
                .foregroundStyle(store.hooksInstalled ? Color.secondary : Color.orange)
            HStack {
                Button(store.tr(.testWaitingSignal)) { store.runHookSelfTest() }
                    .disabled(!store.hooksInstalled || store.hookSelfTestResult == .running)
                Text(store.hookSelfTestText)
                    .font(.caption2)
                    .foregroundStyle(hookTestColor)
                    .lineLimit(1)
            }
            Text(store.attentionBridgeHintText())
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !store.settingsFocusWaitingSignals {
                Button(store.tr(.ensurePulseHook)) {
                    store.ensurePulseHookLauncher()
                }
                .font(.caption)
            }
            Button(store.tr(.revealAttentionFolder)) {
                store.revealAttentionBridgeFolder()
            }
            .font(.caption)
            Button(store.tr(.revealAttentionBridgeKit)) {
                store.revealAttentionBridgeKit()
            }
            .font(.caption)
            if let agent = store.settingsFocusWaitingAgent {
                Button(String(format: store.tr(.attentionBridgeWriteSampleFocused), agent.displayName)) {
                    store.writeAttentionBridgeSample(for: agent)
                }
                .font(.caption)
                Button(
                    store.didCopyAttentionRaise
                        ? store.tr(.attentionRaiseCopied)
                        : store.tr(.copyAttentionRaiseCommand)
                ) {
                    store.copyAttentionRaiseCommand(for: agent)
                }
                .font(.caption)
            }
            Button(store.tr(.attentionBridgeWriteSample)) {
                store.writeAttentionBridgeSample()
            }
            .font(.caption)
            Button(store.tr(.attentionBridgeClearSample)) {
                store.clearAttentionBridgeSample()
            }
            .font(.caption)
            Text(store.attentionBridgeWriteSampleHintText())
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { store.refreshPulseHookLauncherStatus() }
    }

    private var hookTestColor: Color {
        switch store.hookSelfTestResult {
        case .failed: return .red
        case .passed: return GlanceKind.running.lampColor
        case .idle, .running: return .secondary
        }
    }

    // MARK: Shortcuts

    private var shortcutsSection: some View {
        Section(store.tr(.shortcuts)) {
            Picker(store.tr(.revealShortcut), selection: $store.hotkey) {
                ForEach(HotkeyChoice.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .disabled(!store.hotkeyEnabled)
            .onChange(of: store.hotkey) { _, choice in
                store.hotkeyEnabled = choice != .off
                store.saveSettings()
            }
            Toggle(store.tr(.globalShortcut), isOn: $store.hotkeyEnabled)
                .onChange(of: store.hotkeyEnabled) { _, _ in
                    store.saveSettings()
                }
            Text(store.tr(.globalShortcutHint))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if store.hotkeyEnabled, store.hotkey != .off, !store.hotkeyRegistered {
                // Previously this failure was invisible and the hint blamed
                // Accessibility, which was usually the wrong culprit.
                Label(store.tr(.hotkeyTaken), systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(GlanceKind.error.lampColor)
            }
            Text(store.tr(.hotkeyHint))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(store.tr(.a11yHint))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Toggle(store.tr(.allowTerminalAutomation), isOn: $store.allowTerminalAutomation)
                .onChange(of: store.allowTerminalAutomation) { _, _ in
                    store.saveSettings()
                    store.refresh(reason: "terminalAutomation")
                }
            Text(store.tr(.allowTerminalAutomationHint))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Wait history

    private var historySection: some View {
        Section(store.tr(.recentWaits)) {
            // One line, not a dashboard: how often today's work was actually
            // interrupted, and for how long on average.
            if let summary = store.interruptionsTodayLine {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(store.waitHistory) { entry in
                HStack(alignment: .top, spacing: 8) {
                    AgentIconView(id: entry.agent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title.isEmpty ? entry.agent.displayName : entry.title)
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                        Text(store.historyDetail(entry))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
            }
            Button(store.tr(.clearHistory)) { store.clearWaitHistory() }
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section(store.tr(.about)) {
            Button(store.tr(.supportHealth)) {
                store.openSupportHealth()
            }
            HStack(spacing: 10) {
                PulseMarkView(size: 22, tone: .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(PulseVersion.about)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text(store.tr(.tagline))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if PulseVersion.distributionChannel == "preview" {
                        Text(store.tr(.updatePreview))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    } else if PulseVersion.distributionChannel == "signed" {
                        Text(store.tr(.updateSignedUnnotarized))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 4)
            }
            LabeledContent(store.tr(.build)) {
                Text(buildText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            LabeledContent(store.tr(.runningFrom)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.installReport.runningURL.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if let current = store.installReport.copies.first(where: \.isCurrent) {
                        Text(installKindLabel(current.kind))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            if store.isVersionMismatch, let bundle = PulseVersion.bundleVersion {
                Text(String(format: store.tr(.versionMismatchHint), PulseVersion.semver, bundle))
                    .font(.caption2)
                    .foregroundStyle(GlanceKind.error.lampColor)
            }
            if !store.installReport.duplicates.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        String(
                            format: store.tr(.duplicateAppsFound),
                            store.installReport.duplicates.count
                        ),
                        systemImage: "square.on.square"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    ForEach(store.installReport.aboutVisibleDuplicates) { copy in
                        Text("\(copy.version) · \(copy.url.path)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if store.installReport.aboutHiddenDuplicateCount > 0 {
                        Text(
                            String(
                                format: store.tr(.duplicateAppsMore),
                                store.installReport.aboutHiddenDuplicateCount
                            )
                        )
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                    if !store.installReport.removableDuplicates.isEmpty {
                        Button(store.tr(.removeDuplicateApps)) {
                            confirmDuplicateRemoval = true
                        }
                        .font(.caption)
                    }
                    if store.installReport.hasOtherRunningCopy {
                        Text(store.tr(.duplicateAppRunning))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Toggle(store.tr(.checkForUpdates), isOn: $store.updateCheckEnabled)
                .onChange(of: store.updateCheckEnabled) { _, _ in store.saveSettings() }
            HStack {
                Text(store.updateStatusText)
                    .font(.caption2)
                    .foregroundStyle(store.updateAvailableURL == nil ? .secondary : GlanceKind.running.lampColor)
                Spacer(minLength: 4)
                if let url = store.updateAvailableURL {
                    if store.updateCanVerifyDownload {
                        Button(store.tr(.downloadAndVerify)) {
                            store.downloadAndVerifyUpdate()
                        }
                        .font(.caption)
                        .disabled(
                            store.updateDownloadStatus == .downloading
                                || store.updateDownloadStatus == .verifying
                                || store.updateDownloadStatus == .installing
                        )
                    } else {
                        Button(store.tr(.openRelease)) { NSWorkspace.shared.open(url) }
                            .font(.caption)
                    }
                } else {
                    Button(store.tr(.checkNow)) { store.checkForUpdatesNow() }
                        .font(.caption)
                }
            }
            if let download = store.updateDownloadStatusText {
                Text(download)
                    .font(.caption2)
                    .foregroundStyle(
                        {
                            if case .failed = store.updateDownloadStatus { return Color.red }
                            if case .ready = store.updateDownloadStatus {
                                return GlanceKind.running.lampColor
                            }
                            return Color.secondary
                        }()
                    )
            }
            if case .ready = store.updateDownloadStatus, store.updateCanInstallInPlace {
                Button(store.tr(.installUpdate)) { store.installVerifiedUpdate() }
                    .font(.caption)
            } else if case .ready = store.updateDownloadStatus, !store.updateCanInstallInPlace {
                Text(store.tr(.updateInstallRequiresNotarized))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button(store.didCopyDiagnostics ? store.tr(.copied) : store.tr(.copyDiagnostics)) {
                store.copyDiagnostics()
            }
        }
    }

    /// `a1b2c3d · 2026-07-27`, or an honest `dev build` when unpackaged.
    private var buildText: String {
        let line = PulseVersion.buildLine
        return line.isEmpty ? store.tr(.devBuild) : line
    }

    private func installKindLabel(_ kind: InstallTruth.CopyKind) -> String {
        switch kind {
        case .currentInstalled: return store.tr(.runningFrom)
        case .buildArtifact: return store.tr(.installCopyBuildArtifact)
        case .rollback: return store.tr(.installCopyRollback)
        case .orphanDuplicate: return store.tr(.duplicateAppsFound).replacingOccurrences(of: "%d", with: "1")
        }
    }

}

@MainActor
struct SupportCoverageView: View {
    @ObservedObject var store: StatusStore
    @State private var query = ""
    // Support coverage is an inspection surface, not an alert inbox. Starting
    // on Observed keeps the first scan useful while “All” remains the explicit
    // path for auditing every covered adapter, including missing local sources.
    // The full roster is the product contract. Start on All so an adapter
    // without local evidence is visible with a concrete reason instead of
    // disappearing behind an Observed-only filter.
    @State private var filter: SupportFilter = .all
    @State private var showSafeReport = false

    enum SupportFilter: String, CaseIterable, Identifiable {
        case needsAction
        case limited
        case available
        case notInstalled
        case noRecentSession
        case permissionDenied
        case unscanned
        case all

        var id: String { rawValue }
    }

    private var filtered: [AgentSupportHealth] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.supportHealth
            .filter { item in
                switch filter {
                case .needsAction: return item.disposition == .needsAction
                case .limited: return item.disposition == .limited
                case .available: return item.disposition == .available
                case .notInstalled: return item.disposition == .notInstalled
                case .noRecentSession: return item.disposition == .noRecentSession
                case .permissionDenied: return item.disposition == .permissionDenied
                case .unscanned: return item.disposition == .unscanned
                case .all:
                    return true
                }
            }
            .filter {
                text.isEmpty
                    || $0.agent.displayName.localizedCaseInsensitiveContains(text)
                    || store.supportEvidenceLabel($0).localizedCaseInsensitiveContains(text)
                    || store.supportHealthDetail($0).localizedCaseInsensitiveContains(text)
            }
            .sorted {
                let left = severity($0.disposition)
                let right = severity($1.disposition)
                if left != right { return left > right }
                let lp = AgentID.priority.firstIndex(of: $0.agent) ?? 999
                let rp = AgentID.priority.firstIndex(of: $1.agent) ?? 999
                return lp < rp
            }
    }

    private func severity(_ disposition: SupportDisposition) -> Int {
        switch disposition {
        case .needsAction: return 7
        case .permissionDenied: return 6
        case .limited: return 5
        case .unscanned: return 4
        case .noRecentSession: return 3
        case .notInstalled: return 2
        case .available: return 1
        }
    }

    private func filterLabel(_ filter: SupportFilter) -> String {
        switch filter {
        case .needsAction:
            return String(format: store.tr(.supportNeedsActionCount), needsActionCount)
        case .limited:
            return String(format: store.tr(.supportLimitedCount), limitedCount)
        case .available:
            return String(format: store.tr(.supportAvailableCount), availableCount)
        case .notInstalled:
            return String(format: store.tr(.supportNotInstalledCount), notInstalledCount)
        case .noRecentSession:
            return String(format: store.tr(.supportNoRecentCount), noRecentCount)
        case .permissionDenied:
            return String(format: store.tr(.supportPermissionDeniedCount), permissionDeniedCount)
        case .unscanned:
            return String(format: store.tr(.supportUnscannedCount), unscannedCount)
        case .all: return store.tr(.supportFilterAll)
        }
    }

    private var needsActionCount: Int {
        store.supportHealth.filter { $0.disposition == .needsAction }.count
    }
    private var limitedCount: Int {
        store.supportHealth.filter { $0.disposition == .limited }.count
    }
    private var availableCount: Int {
        store.supportHealth.filter { $0.disposition == .available }.count
    }
    private var notInstalledCount: Int {
        store.supportHealth.filter { $0.disposition == .notInstalled }.count
    }
    private var noRecentCount: Int {
        store.supportHealth.filter { $0.disposition == .noRecentSession }.count
    }
    private var permissionDeniedCount: Int {
        store.supportHealth.filter { $0.disposition == .permissionDenied }.count
    }
    private var unscannedCount: Int {
        store.supportHealth.filter { $0.disposition == .unscanned }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(store.tr(.supportHealth))
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text(store.tr(.supportHealthHint))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let privacy = store.privacyBannerText {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Label(
                            privacy,
                            systemImage: "lock"
                        )
                        .foregroundStyle(.orange)
                        Spacer(minLength: 8)
                        Button(store.tr(.settings)) {
                            store.openSettings(focusAppDataFor: store.firstPrivacyLimitedAgent)
                        }
                        .buttonStyle(.borderless)
                    }
                    .font(.caption)
                }
                if let incomplete = store.scanIncompleteBannerText {
                    HStack(spacing: 8) {
                        Label(incomplete, systemImage: "clock.badge.exclamationmark")
                            .foregroundStyle(.orange)
                        Spacer(minLength: 8)
                        Button(store.tr(.supportRetry)) {
                            store.refresh(reason: "support-retry")
                        }
                        .buttonStyle(.borderless)
                    }
                    .font(.caption)
                }
                HStack(spacing: 12) {
                    Label(
                        String(format: store.tr(.supportNeedsActionCount), needsActionCount),
                        systemImage: "exclamationmark.triangle"
                    )
                    Label(
                        String(format: store.tr(.supportLimitedCount), limitedCount),
                        systemImage: "info.circle"
                    )
                    Label(
                        String(format: store.tr(.supportAvailableCount), availableCount),
                        systemImage: "checkmark.circle"
                    )
                    Label(
                        String(format: store.tr(.supportNotInstalledCount), notInstalledCount),
                        systemImage: "square.dashed"
                    )
                    Label(
                        String(format: store.tr(.supportPermissionDeniedCount), permissionDeniedCount),
                        systemImage: "lock"
                    )
                    Spacer()
                    Button(store.tr(.supportSafeReport)) { showSafeReport.toggle() }
                        .buttonStyle(.borderless)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(summaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("", selection: $filter) {
                    ForEach(SupportFilter.allCases) {
                        Text(filterLabel($0)).tag($0)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 240, alignment: .leading)
                .labelsHidden()
                if showSafeReport {
                    VStack(alignment: .trailing, spacing: 6) {
                        ScrollView {
                            Text(store.safeSupportReport())
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 108)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.primary.opacity(0.045))
                        )
                        HStack(spacing: 10) {
                            Button(store.tr(.exportSafeReport)) { store.exportSafeSupportReport() }
                            Button(
                                store.didCopyDiagnostics ? store.tr(.copied) : store.tr(.supportCopySafeReport)
                            ) { store.copySafeSupportReport() }
                        }
                    }
                }
            }
            .padding(20)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { item in
                        SupportHealthRow(item: item, store: store)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                        if item.id != filtered.last?.id {
                            Divider().padding(.leading, 54)
                        }
                    }
                }
            }
            .overlay {
                if filtered.isEmpty {
                    ContentUnavailableView(
                        store.tr(.supportNoFilterResults),
                        systemImage: "line.3.horizontal.decrease.circle"
                    )
                }
            }
        }
        .frame(minWidth: 580, minHeight: 280)
        .background(Color(nsColor: .windowBackgroundColor))
        .searchable(text: $query, prompt: store.tr(.supportSearch))
    }

    private var summaryLine: String {
        let usable = availableCount
        switch store.lang {
        case .zh:
            return "可用 \(usable) · 需要处理 \(needsActionCount) · 信息受限 \(limitedCount) · 未安装 \(notInstalledCount) · 无近期会话 \(noRecentCount) · 权限不足 \(permissionDeniedCount) · 未扫描 \(unscannedCount)"
        case .en:
            return "Available \(usable) · Needs action \(needsActionCount) · Limited \(limitedCount) · Not installed \(notInstalledCount) · No recent session \(noRecentCount) · Permission denied \(permissionDeniedCount) · Unscanned \(unscannedCount)"
        }
    }
}

@MainActor
struct SupportHealthRow: View {
    let item: AgentSupportHealth
    @ObservedObject var store: StatusStore
    @State private var diagnosticsExpanded = true

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .padding(.top, 6)
                .accessibilityHidden(true)
            AgentIconView(id: item.agent)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(item.agent.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    Text(dispositionLabel)
                        .font(.caption)
                        .foregroundStyle(statusLabelColor)
                    Text(store.supportEvidenceLabel(item))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Text(store.supportFocusDetail(item))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(store.supportDepthDetail(item))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if item.isObserved {
                    HStack(spacing: 6) {
                        SupportFactPill(
                            label: store.tr(.supportGoal),
                            present: item.hasGoal
                        )
                        SupportFactPill(
                            label: store.tr(.supportWorkspace),
                            present: item.hasWorkspace
                        )
                        SupportFactPill(
                            label: store.tr(.supportActivity),
                            present: item.hasActivity
                        )
                        SupportFactPill(
                            label: store.tr(.supportProgress),
                            present: item.hasProgress
                        )
                        Text(String(
                            format: store.tr(.supportUsefulCoverage),
                            item.usefulFactCount,
                            item.usefulFactTotal
                        ))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    }
                    .font(.caption)

                    HStack(spacing: 6) {
                        SupportFactPill(
                            label: store.tr(.supportAction),
                            present: item.hasActionSignal
                        )
                        SupportFactPill(
                            label: store.tr(.supportModel),
                            present: item.hasModelSignal
                        )
                        SupportFactPill(
                            label: store.tr(.supportResources),
                            present: item.hasResourceSignal
                        )
                    }
                    .font(.caption)

                    let observed = store.supportObservedDetail(item)
                    Text(observed.isEmpty ? store.tr(.supportNoObservedSignals) : observed)
                        .font(.caption)
                        .foregroundStyle(observed.isEmpty ? .tertiary : .secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                } else if item.privacyLimited
                    || item.disposition == .limited
                    || item.disposition == .unscanned
                    || item.disposition == .permissionDenied
                {
                    // Capability gaps stay visible when the adapter has not
                    // produced a row — otherwise Support Health collapses to
                    // disposition labels alone.
                    HStack(spacing: 6) {
                        SupportFactPill(label: store.tr(.supportGoal), present: false)
                        SupportFactPill(label: store.tr(.supportWorkspace), present: false)
                        SupportFactPill(label: store.tr(.supportActivity), present: false)
                        SupportFactPill(label: store.tr(.supportProgress), present: false)
                    }
                    .font(.caption)
                }

                let timeline = store.supportTimelineDetail(item)
                if !timeline.isEmpty {
                    Text(timeline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if item.collectorErrorKind == "native_timeout" {
                    Label(store.tr(.qualityReasonScanTimeout), systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if let missing = store.supportMissingDetail(item) {
                    Label(missing, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if item.repair != .none {
                    Button(repairLabel) {
                        switch item.repair {
                        case .installHooks: store.installHooks()
                        case .retry: store.refresh(reason: "support-retry")
                        case .openSettings: store.openSettings(focusAppDataFor: item.agent)
                        case .runAgent: store.focusAgent(idRaw: item.agent.rawValue)
                        case .openAttentionBridge:
                            store.openSettings(
                                focusWaitingSignals: true,
                                focusWaitingAgent: item.agent
                            )
                        case .none: break
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }

                // `repair` is the actionable primary path. Privacy-limited and
                // retryable rows used to render the same action a second time
                // through `nextActionLabel`, which made Support Health read as
                // duplicated and visually noisy. Keep one action per row; the
                // detail/diagnostics disclosure still carries the full reason.
                if item.repair == .none, let action = nextActionLabel {
                    if item.privacyLimited {
                        Button(action) { store.openSettings(focusAppDataFor: item.agent) }
                            .buttonStyle(.link)
                            .font(.caption)
                    } else if [.failed, .permissionDenied, .schemaMismatch, .unscanned].contains(item.collectorState) {
                        Button(action) { store.refresh(reason: "support-retry-\(item.agent.rawValue)") }
                            .buttonStyle(.link)
                            .font(.caption)
                    } else if item.agent.harvestSource == .bestEffortCache,
                              item.evidence == .cache || item.evidence == .process {
                        Label(action, systemImage: "arrow.right.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Label(action, systemImage: "arrow.right.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let failure = store.supportFailureTimelineDetail(item) {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                DisclosureGroup(isExpanded: $diagnosticsExpanded) {
                    Text(store.supportAdapterDetail(item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 3)
                } label: {
                    Text(store.tr(.supportAdapterDiagnostics))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(item.agent.displayName), \(store.supportEvidenceLabel(item)), "
                + store.supportHealthDetail(item)
        )
    }

    private var statusLabelColor: Color {
        switch item.disposition {
        case .needsAction: return .red
        case .limited: return .orange
        case .available: return GlanceKind.running.lampColor
        case .notInstalled, .noRecentSession, .unscanned: return .secondary.opacity(0.65)
        case .permissionDenied: return .purple
        }
    }

    private var statusColor: Color {
        switch item.disposition {
        case .needsAction: return .red
        case .limited: return .orange
        case .available: return GlanceKind.running.lampColor
        case .notInstalled, .noRecentSession, .unscanned: return .gray
        case .permissionDenied: return .purple
        }
    }

    private var dispositionLabel: String {
        switch item.disposition {
        case .needsAction: return store.tr(.supportNeedsAction)
        case .limited: return store.tr(.supportLimited)
        case .available: return store.tr(.supportAvailable)
        case .notInstalled: return store.tr(.supportNotInstalled)
        case .noRecentSession: return store.tr(.supportNoRecentSession)
        case .permissionDenied: return store.tr(.supportPermissionDenied)
        case .unscanned: return store.tr(.supportUnscanned)
        }
    }

    private var repairLabel: String {
        switch item.repair {
        case .installHooks: return store.tr(.installHooks)
        case .retry: return store.tr(.supportRetry)
        case .openSettings: return store.tr(.supportEnableData)
        case .runAgent: return store.tr(.supportRunAgent)
        case .openAttentionBridge: return store.tr(.setupWaitingSignals)
        case .none: return ""
        }
    }

    private var nextActionLabel: String? {
        if item.privacyLimited { return store.tr(.supportEnableData) }
        switch item.collectorState {
        case .failed, .schemaMismatch, .unscanned:
            return store.tr(.supportRetry)
        case .permissionDenied:
            return store.tr(.supportEnableData)
        case .sourceAbsent, .noSessions, .noRecentData:
            return item.isObserved ? nil : store.tr(.supportRunAgent)
        case .observed:
            if item.agent.harvestSource == .bestEffortCache,
               item.disposition == .limited,
               !item.privacyLimited {
                return store.tr(.qualityNextWaitCache)
            }
            return nil
        }
    }
}

private struct SupportFactPill: View {
    let label: String
    let present: Bool

    var body: some View {
        Label(
            label,
            systemImage: present ? "checkmark.circle.fill" : "circle"
        )
        .foregroundStyle(present ? Color.secondary : Color.secondary.opacity(0.5))
        .labelStyle(.titleAndIcon)
    }
}

/// Hour+minute picker backed by minutes-since-midnight.
/// Quiet hours were whole-hour only, so 22:30 was not expressible.
private struct MinutePicker: View {
    let label: String
    @Binding var minutes: Int
    let onCommit: () -> Void

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                Picker("", selection: hourBinding) {
                    ForEach(0..<24, id: \.self) { h in
                        Text(String(format: "%02d", h)).tag(h)
                    }
                }
                .labelsHidden()
                .frame(width: 62)
                Text(":")
                Picker("", selection: minuteBinding) {
                    ForEach([0, 15, 30, 45], id: \.self) { m in
                        Text(String(format: "%02d", m)).tag(m)
                    }
                }
                .labelsHidden()
                .frame(width: 62)
            }
        }
    }

    private var hourBinding: Binding<Int> {
        Binding(
            get: { min(23, max(0, minutes / 60)) },
            set: { minutes = $0 * 60 + (minutes % 60); onCommit() }
        )
    }

    private var minuteBinding: Binding<Int> {
        Binding(
            get: {
                let m = minutes % 60
                // Snap a legacy/odd value onto the nearest offered step.
                return [0, 15, 30, 45].min(by: { abs($0 - m) < abs($1 - m) }) ?? 0
            },
            set: { minutes = (minutes / 60) * 60 + $0; onCommit() }
        )
    }
}
