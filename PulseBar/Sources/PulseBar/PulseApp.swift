import SwiftUI
import AppKit

enum AppServices {
    @MainActor static let store = StatusStore()
}

/// Explicit entry point so `--selftest` can answer before AppKit starts —
/// `App.main()` connects to the WindowServer, which a CI runner may not have.
@main
enum PulseBarMain {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            exit(PulseSelfTest.run() ? 0 : 1)
        }
        PulseBarApp.main()
    }
}

struct PulseBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var store = AppServices.store

    var body: some Scene {
        MenuBarExtra {
            TrayPanel(store: store)
        } label: {
            MenuBarLabel(snapshot: store.snapshot)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppServices.store.start()
        if CommandLine.arguments.contains("--open-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                AppServices.store.openSettings()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotKey.uninstall()
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

private enum TrayChrome {
    /// 360 lost the end of most session titles: after the 12pt accent gutter,
    /// the 18pt icon, and the status chip, a row title had ~230pt — roughly
    /// thirty characters, where a real task name is fifty. A menu-bar panel at
    /// 400 is still narrow next to the calendar and reminder popovers people
    /// already run, and it is forty characters instead of thirty.
    static let width: CGFloat = 400
    static let padX: CGFloat = 14
    static let waitAccent = GlanceKind.waiting.lampColor
    static let runAccent = GlanceKind.running.lampColor

    /// The panel's own surface — opaque, and the only one.
    ///
    /// 0.27 screenshots showed the same panel turning blue over a blue
    /// wallpaper and flat grey over a dark desktop, because the content sat
    /// directly on the popover's vibrancy. Legibility became a function of the
    /// user's desktop picture: the green header read as green-on-saturated-blue
    /// in one and was nearly invisible in the other.
    ///
    /// Translucency is not worth that. An accent-coloured word has to be
    /// readable on every machine, and `windowBackgroundColor` already tracks
    /// light and dark on its own.
    static let surface = Color(nsColor: .windowBackgroundColor)
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
        let line = HStack(spacing: 6) {
            if let collapsed {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .opacity(0.6)
            }
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
            // "No project 2 Pi · Amp" — two names and a 2. The count only
            // earns its place when the names do not already give it.
            if showCount {
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .opacity(0.7)
            }
            if !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 11))
                    .opacity(0.55)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(accent ? TrayChrome.waitAccent : Color.secondary)
        .padding(.horizontal, TrayChrome.padX)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Same surface as the panel, not a material on top of it.
        //
        // `.thickMaterial` here made the heading the *brightest* block in the
        // panel — brighter than the rows it was separating, and carrying the
        // least important information on screen. It still has to be opaque,
        // because it is pinned and rows scroll underneath it; it just must not
        // be a different value.
        .background(TrayChrome.surface)

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
    /// Groups the user has opened. Foldable groups start closed, and the set
    /// is per-panel rather than persisted: reopening the tray is a new glance,
    /// and a glance should start at "what needs me", not at last time's
    /// bookkeeping.
    @State fileprivate var unfolded: Set<String> = []

    /// Row key the keyboard has selected, if any.
    @State fileprivate var selectedKey: String?
    @FocusState fileprivate var listFocused: Bool

    fileprivate func toggleFold(_ id: String) {
        // A panel that repaints itself every couple of seconds cannot afford
        // hard cuts: a block of rows appearing instantly is indistinguishable
        // from a reorder, and you re-read the whole list to find out which it
        // was. Short and flat — this is a menu-bar panel, not a launch screen.
        withAnimation(.easeOut(duration: 0.16)) {
            if unfolded.contains(id) { unfolded.remove(id) } else { unfolded.insert(id) }
        }
    }

    /// Rows in the order the keyboard walks them: what is actually on screen,
    /// so a folded group is skipped rather than silently selected.
    fileprivate func visibleRows(_ groups: [RowGroup]) -> [AgentRow] {
        groups.flatMap { group -> [AgentRow] in
            if group.foldable && !unfolded.contains(group.id) { return [] }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            missedNotice
            nudge
            Divider().opacity(0.4)

            if store.snapshot.rows.isEmpty {
                emptyState
            } else {
                agentList
            }

            Divider().opacity(0.4)
            actions
        }
        .frame(width: TrayChrome.width)
        // The window was drawing about 110pt taller than the panel, leaving a
        // band of bare window above and below it — visible as a different
        // surface in both screenshots, and confirmed as window rather than
        // content because clicking it dismisses the popover. Asking for the
        // ideal height makes the window size to what the panel actually draws
        // instead of to a stale or speculative measurement.
        .fixedSize(horizontal: false, vertical: true)
        .background(TrayChrome.surface)
        // Tray visibility drives the probe cadence — fast while being read,
        // slow (or parked) when nobody is looking.
        .onAppear { store.trayDidAppear() }
        .onDisappear { store.trayDidDisappear() }
    }

    private var header: some View {
        // No lamp here.
        //
        // The menu-bar mark sits about 40px above this line, same shape, same
        // colour, driven by the same `glance`. The header's job is to say what
        // the rows cannot; repeating the thing the user just clicked on is the
        // opposite. The status word keeps the glance colour, which is the part
        // that carried information.
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if store.isRefreshing {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(store.isRefreshing ? store.tr(.refreshing) : headerTitle)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(headerTitleColor)
                        .lineLimit(1)
                }
                if !store.isRefreshing, !headerDetail.isEmpty {
                    Text(headerDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, TrayChrome.padX)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var headerTitle: String {
        let t = store.snapshot.headerTitle
        return t.isEmpty ? store.snapshot.header : t
    }

    private var headerDetail: String {
        store.snapshot.headerDetail
    }

    private var headerTitleColor: Color {
        store.snapshot.glance.lampColor
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
        }
    }

    @ViewBuilder
    private var nudge: some View {
        if store.needsHooksNudge {
            Button { store.openSettings() } label: {
                Text(store.tr(.hooksNudge))
                    .font(.system(size: 11))
                    .foregroundStyle(TrayChrome.waitAccent.opacity(0.95))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, TrayChrome.padX)
                    .padding(.bottom, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else if store.needsWaitingSignalNudge {
            Text(store.tr(.waitingSignalNudge))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, TrayChrome.padX)
                .padding(.bottom, 10)
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
            if !store.hooksInstalled {
                Button(store.tr(.installHooks)) { store.installHooks() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .medium))
            }
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
        /// The heading doubles as a disclosure control and the rows start folded.
        var foldable = false
    }

    /// A heading earns its line only when it separates things.
    fileprivate func showHeading(_ group: RowGroup, of groups: [RowGroup]) -> Bool {
        guard groups.count > 1 else { return false }
        // Grouping by project produced "~/Documents/Cursor 1" over exactly one
        // row whose own second line said "~/Documents/Cursor". Two lines, one
        // fact, and a whole row of height spent on it.
        if group.statesPath && group.rows.count == 1 { return false }
        return true
    }

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
        let rows = store.snapshot.rows
        switch store.trayGrouping {
        case .status:
            let present = TraySection.allCases.filter { s in rows.contains { $0.section == s } }
            return present.map { section in
                let group = rows.filter { $0.section == section }
                return RowGroup(
                    id: "s\(section.rawValue)",
                    title: store.tr(section.titleKey),
                    count: store.snapshot.sectionTotals[section] ?? group.count,
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
                let key = path.isEmpty ? store.tr(.noProject) : path
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
                return RowGroup(
                    id: "p\(entry.element)",
                    title: entry.element,
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
                    )
                )
            }
        }
    }

    private var agentList: some View {
        // Height comes from the content now. It used to be a hand-summed
        // estimate (44 + 20 - 4 + 14 + 28 + 8) that any font or spacing change
        // silently invalidated — the panel and its contents disagreed and there
        // was no way to notice except by looking.
        let cap: CGFloat = store.showAllAgents ? 620 : 420

        let groups = groupedRows
        return VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(groups) { group in
                        Section {
                            // No rules between rows: whitespace already
                            // separates them, and a line every 56pt turns a
                            // short list into a table.
                            if !(group.foldable && !unfolded.contains(group.id)) {
                                ForEach(group.rows) { row in
                                    AgentRowButton(
                                        row: row,
                                        store: store,
                                        pathInHeading: group.statesPath && showHeading(group, of: groups),
                                        selected: selectedKey == row.rowKey
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
                                let folded = group.foldable && !unfolded.contains(group.id)
                                SectionHeader(
                                    title: group.title,
                                    count: group.count,
                                    accent: group.accent,
                                    collapsed: group.foldable ? folded : nil,
                                    summary: folded ? TrayFold.summary(group.rows) : "",
                                    toggle: group.foldable ? { toggleFold(group.id) } : nil,
                                    showCount: !(folded && TrayFold.summaryNamesEveryRow(group.rows))
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
            .frame(height: min(max(measuredHeight, 56), cap))
            .onPreferenceChange(ContentHeightKey.self) { measuredHeight = $0 }
            // The panel is usually summoned by a shortcut, so the hand is
            // already on the keyboard; finishing with the mouse is the awkward
            // part. Arrow keys walk the visible rows, Return focuses the
            // terminal, Escape gives up.
            .focusable()
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

            if store.snapshot.hiddenCount > 0 {
                overflowButton(
                    String(format: store.tr(.andMore), store.snapshot.hiddenCount)
                ) { store.toggleShowAllAgents() }
            } else if store.showAllAgents, store.snapshot.totalCount > SnapshotBuilder.maxVisibleRows {
                overflowButton(store.tr(.showLess)) { store.toggleShowAllAgents() }
            }

            // Sessions beyond the per-agent cap: say so rather than pretend
            // they do not exist.
            if store.snapshot.cappedSessions > 0 {
                Text(String(format: store.tr(.cappedSessions), store.snapshot.cappedSessions))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, TrayChrome.padX)
                    .padding(.bottom, 8)
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

    /// One bar, not five stacked rows.
    ///
    /// Five full-width menu items plus a version footer cost about 170pt of a
    /// 600pt panel — more than the two rows of content it was framing. Icons
    /// with tooltips carry the same actions in ~34pt, and the build badge rides
    /// along at the end where it was already meant to sit quietly.
    private var actions: some View {
        HStack(spacing: 2) {
            TrayIconAction(systemImage: "arrow.clockwise", help: store.tr(.refresh), shortcut: "r") {
                store.refresh(reason: "manual")
            }
            .disabled(store.isRefreshing)

            if store.snapshot.rows.contains(where: \.waiting) {
                TrayIconAction(
                    systemImage: "arrow.uturn.forward",
                    help: store.tr(.jumpToOldest),
                    shortcut: "j"
                ) { store.focusOldestWait() }
                TrayIconAction(systemImage: "checkmark.circle", help: store.tr(.clearWaiting)) {
                    store.clearWaiting()
                }
            }

            TrayIconAction(systemImage: "gearshape", help: store.tr(.settings), shortcut: ",") {
                store.openSettings()
            }
            TrayIconAction(systemImage: "power", help: store.tr(.quit), shortcut: "q") {
                store.quit()
            }

            Spacer(minLength: 6)

            Button { store.copyDiagnostics() } label: {
                HStack(spacing: 4) {
                    Text(store.didCopyDiagnostics ? store.tr(.copied) : PulseVersion.about)
                    if store.isVersionMismatch {
                        Text(store.tr(.versionStale))
                            .foregroundStyle(GlanceKind.error.lampColor)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(PulseVersion.fingerprint)
            .accessibilityLabel(PulseVersion.fingerprint)
        }
        .padding(.horizontal, TrayChrome.padX)
        .padding(.vertical, 8)
    }
}

// MARK: - Agent row

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
    @State private var hovering = false
    @State private var expanded = false

    private var highlight: Color {
        if selected { return Color.primary.opacity(0.10) }
        return hovering ? Color.primary.opacity(0.055) : .clear
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                store.primaryAction(row)
            } label: {
                HStack(alignment: .top, spacing: 0) {
                    // Encoding 1 of 3: does this need me, and has it been
                    // waiting a long time. Width is the *only* thing in the row
                    // that changes with age — everything else stays constant so
                    // the escalation actually reads as one.
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(accentFill)
                        .frame(width: accentWidth)
                        .padding(.vertical, 4)

                    HStack(alignment: .top, spacing: 10) {
                        AgentIconView(id: row.agent, waiting: row.waiting)
                            .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                // Encoding 3 of 3: a real session is semibold,
                                // a bare process is not.
                                Text(heroTitle)
                                    .font(.system(
                                        size: 13,
                                        weight: row.isProcessOnly ? .regular : .semibold,
                                        design: .rounded
                                    ))
                                    .foregroundStyle(.primary)
                                    // Width alone does not fix a fifty-character
                                    // title; it moves where the ellipsis lands.
                                    // A second line costs ~16pt on the rows that
                                    // need it and nothing on the rows that do
                                    // not, and the end of a task name is the
                                    // half that identifies it.
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 6)
                                statusChip
                            }

                            if !contextLine.isEmpty {
                                Text(contextLine)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
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
                    .padding(.leading, 12)
                    .padding(.trailing, TrayChrome.padX)
                    .padding(.vertical, 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
            .accessibilityHint(store.focusActionTitle(row))

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
                    if row.canOpenFolder {
                        Button(store.tr(.openFolder)) { store.openProject(row) }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11, weight: .medium))
                    }
                    Button(store.tr(.moreDetail)) { expanded.toggle() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 0)
                }
                .padding(.leading, 48)
                .padding(.trailing, TrayChrome.padX)
                .padding(.bottom, 8)
            }
            detailBlock
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
    }

    /// Inline detail, opened on demand.
    ///
    /// 0.24 pushed this into a tooltip, which cannot be selected, cannot be
    /// copied, and vanishes while being read.
    @ViewBuilder
    private var detailBlock: some View {
        if expanded {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(detailLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.leading, 48)
            .padding(.trailing, TrayChrome.padX)
            .padding(.bottom, 8)
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

    private var showActions: Bool {
        row.waiting || hovering || expanded
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
            // The agent name *is* the information here. Saying "Process
            // detected" as the title, "process" in the badge, and the agent
            // name on the line below states one fact three times.
            return row.agent.displayName
        }
        if let t = row.sessionDetail {
            // The prefix used to be added precisely when the row was *not*
            // live, so a row read "Doing · New Session" next to a "Recent"
            // badge — two contradictory claims about the same session.
            return Self.truncate(t, Self.heroLimit)
        }
        let short = AgentRow.shortProject(row.project)
        if !short.isEmpty { return short }
        return row.agent.displayName
    }

    /// Second line: where this session is, and how long since it moved.
    ///
    /// It used to be `Agent · project`, which restated the icon and — when the
    /// folder happened to match the agent — printed "Cursor · Cursor". The two
    /// facts a row could never state were *where* and *how long*; both were
    /// collected all along.
    private var contextLine: String {
        store.rowContextLine(row, omitPath: pathInHeading)
    }

    /// Everything the row does not show inline, revealed on demand.
    private var detailLines: [String] {
        var out: [String] = []
        let full = row.cwd.isEmpty ? row.project : row.cwd
        if !full.isEmpty, full != row.displayPath { out.append(full) }
        if let task = row.usefulTask, task != heroTitle { out.append(task) }
        var facts: [String] = [row.agent.displayName]
        if row.processCount > 1 { facts.append("×\(row.processCount)") }
        if row.viaWarp { facts.append("Warp") }
        if let sig = row.waitSignal {
            facts.append(sig == .hooks ? store.tr(.signalHooks) : store.tr(.signalPending))
        }
        out.append(facts.joined(separator: " · "))
        if let meta = row.metaLine { out.append(meta) }
        if let hint = row.shortSessionHint { out.append(hint) }
        return out
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
        } else if row.isProcessOnly {
            StatusChip(kind: .process, label: store.tr(.processWord))
        } else if row.isStalled {
            // Live for twenty minutes with nothing happening. Never surfaced
            // before, and it looked exactly like a healthy session.
            StatusChip(kind: .process, label: store.tr(.stalled))
        } else if row.subRunning > 0 {
            StatusChip(kind: .running, label: "sub \(row.subRunning)↑")
        } else if row.isRecentOnly {
            StatusChip(kind: .recent, label: store.tr(.recent))
        }
        // Live with a session and nothing unusual: no badge.
    }

    private var accessibilityText: String {
        var parts = [heroTitle, row.agent.displayName]
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
                .frame(width: 28, height: 22)
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

    var body: some View {
        Form {
            statusSection
            generalSection
            notificationsSection
            waitingSignalsSection
            shortcutsSection
            if !store.waitHistory.isEmpty { historySection }
            if !store.snapshot.rows.isEmpty { agentsSection }
            aboutSection
        }
        .formStyle(.grouped)
        .padding(8)
        .onAppear {
            store.hooksStatus = HooksSupport.probeStatus()
            PulseNotify.refreshAuthorization()
        }
    }

    // MARK: Context

    private var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                PulseMarkView(size: 28, tone: store.snapshot.glance.lampColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.snapshot.headerTitle.isEmpty
                          ? store.snapshot.header
                          : store.snapshot.headerTitle)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    if !store.snapshot.headerDetail.isEmpty {
                        Text(store.snapshot.headerDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 4)
                Text(store.probeIntervalDescription)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: General

    private var generalSection: some View {
        Section(store.tr(.general)) {
            Toggle(store.tr(.liveUpdates), isOn: $store.autoProbe)
                .onChange(of: store.autoProbe) { _, _ in store.saveSettings() }
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
            if store.notifyAuthorized == false {
                // A denied prompt used to leave these toggles reading "on"
                // while nothing could ever fire.
                Label(store.tr(.notifyDenied), systemImage: "bell.slash")
                    .font(.caption)
                    .foregroundStyle(GlanceKind.error.lampColor)
                Button(store.tr(.openNotificationSettings)) {
                    store.openSystemNotificationSettings()
                }
            }
            Toggle(store.tr(.notifications), isOn: $store.notifyOnIdle)
                .onChange(of: store.notifyOnIdle) { _, _ in store.saveSettings() }
                .disabled(store.notifyAuthorized == false)
            Toggle(store.tr(.notifyWaiting), isOn: $store.notifyOnWaiting)
            Toggle(store.tr(.playSound), isOn: $store.playSoundOnWaiting)
                .onChange(of: store.playSoundOnWaiting) { _, _ in store.saveSettings() }
                .onChange(of: store.notifyOnWaiting) { _, _ in store.saveSettings() }
                .disabled(store.notifyAuthorized == false)

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
                                AgentIconView(id: agent, waiting: false)
                                Text(agent.displayName)
                            }
                        }
                    }
                }
            }
        }
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
            Text(store.tr(.attentionBridgeHint))
                .font(.caption2)
                .foregroundStyle(.tertiary)
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
            .onChange(of: store.hotkey) { _, _ in store.saveSettings() }
            if store.hotkey != .off, !store.hotkeyRegistered {
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
                    AgentIconView(id: entry.agent, waiting: false)
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

    // MARK: Agents

    private var agentsSection: some View {
        Section(store.tr(.agents)) {
            ForEach(store.snapshot.rows) { row in
                HStack(alignment: .top, spacing: 8) {
                    AgentIconView(id: row.agent, waiting: row.waiting)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.titleLine)
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                        if let session = row.sessionDetail {
                            Text(session)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 4)
                    Text(Self.statusLabel(row: row, store: store))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(row.waiting ? GlanceKind.waiting.lampColor : Color.secondary)
                }
            }
            if store.snapshot.cappedSessions > 0 {
                Text(String(format: store.tr(.cappedSessions), store.snapshot.cappedSessions))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section(store.tr(.about)) {
            HStack(spacing: 10) {
                PulseMarkView(size: 22, tone: .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(PulseVersion.about)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text(store.tr(.tagline))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
            }
            LabeledContent(store.tr(.build)) {
                Text(buildText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if store.isVersionMismatch, let bundle = PulseVersion.bundleVersion {
                Text(String(format: store.tr(.versionMismatchHint), PulseVersion.semver, bundle))
                    .font(.caption2)
                    .foregroundStyle(GlanceKind.error.lampColor)
            }

            Toggle(store.tr(.checkForUpdates), isOn: $store.updateCheckEnabled)
                .onChange(of: store.updateCheckEnabled) { _, _ in store.saveSettings() }
            HStack {
                Text(store.updateStatusText)
                    .font(.caption2)
                    .foregroundStyle(store.updateAvailableURL == nil ? .secondary : GlanceKind.running.lampColor)
                Spacer(minLength: 4)
                if let url = store.updateAvailableURL {
                    Button(store.tr(.openRelease)) { NSWorkspace.shared.open(url) }
                        .font(.caption)
                } else {
                    Button(store.tr(.checkNow)) { store.checkForUpdatesNow() }
                        .font(.caption)
                }
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

    private static func statusLabel(row: AgentRow, store: StatusStore) -> String {
        if row.waiting {
            return row.waitKind.isEmpty ? store.tr(.needsYou) : store.localizedWaitKind(row.waitKind)
        }
        if row.liveProcess || row.subRunning > 0 {
            return store.tr(.running)
        }
        return store.tr(.recent)
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
