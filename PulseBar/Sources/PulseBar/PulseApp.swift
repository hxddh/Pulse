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
    static let width: CGFloat = 360
    static let padX: CGFloat = 14
    static let waitAccent = GlanceKind.waiting.lampColor
    static let runAccent = GlanceKind.running.lampColor
}

private struct StatusChip: View {
    enum Kind { case waiting, running, recent, process }

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
        }
    }

    private var background: Color {
        switch kind {
        case .waiting: return TrayChrome.waitAccent.opacity(0.16)
        case .running: return TrayChrome.runAccent.opacity(0.12)
        case .process: return Color.primary.opacity(0.05)
        case .recent: return Color.primary.opacity(0.04)
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

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
            Text("\(count)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .opacity(0.7)
            Spacer(minLength: 0)
        }
        .foregroundStyle(accent ? TrayChrome.waitAccent : Color.secondary)
        .padding(.horizontal, TrayChrome.padX)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thickMaterial)
    }
}

@MainActor
struct TrayPanel: View {
    @ObservedObject var store: StatusStore
    @State fileprivate var measuredHeight: CGFloat = 0

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
        // Tray visibility drives the probe cadence — fast while being read,
        // slow (or parked) when nobody is looking.
        .onAppear { store.trayDidAppear() }
        .onDisappear { store.trayDidDisappear() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            PulseMarkView(
                size: 18,
                tone: store.snapshot.glance.lampColor
            )
            .padding(.top, 1)

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
            return TraySection.allCases.compactMap { section in
                let group = rows.filter { $0.section == section }
                guard !group.isEmpty else { return nil }
                return RowGroup(
                    id: "s\(section.rawValue)",
                    title: store.tr(section.titleKey),
                    count: store.snapshot.sectionTotals[section] ?? group.count,
                    accent: section == .needsYou,
                    rows: group
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
                return RowGroup(
                    id: "p\(entry.element)",
                    title: entry.element,
                    count: group.count,
                    accent: group.contains(where: \.waiting),
                    rows: group,
                    statesPath: true
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
                            ForEach(group.rows) { row in
                                AgentRowButton(
                                    row: row,
                                    store: store,
                                    pathInHeading: group.statesPath && showHeading(group, of: groups)
                                )
                            }
                        } header: {
                            // A lone heading restates the panel header directly
                            // above it — "2 running / Cursor · Amp" followed by
                            // "Running 2". Headings earn their line only when
                            // there is more than one group to tell apart, and a
                            // heading over a single row is just that row's own
                            // path on a line of its own.
                            if showHeading(group, of: groups) {
                                SectionHeader(
                                    title: group.title,
                                    count: group.count,
                                    accent: group.accent
                                )
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                    }
                )
            }
            .frame(height: min(max(measuredHeight, 56), cap))
            .onPreferenceChange(ContentHeightKey.self) { measuredHeight = $0 }

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
    @State private var hovering = false
    @State private var expanded = false

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
                        .fill(row.waiting ? TrayChrome.waitAccent : Color.clear)
                        .frame(width: row.waiting ? (row.isUrgentWait ? 6 : 3) : 0)
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
                                    .lineLimit(1)
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
        .background(hovering ? Color.primary.opacity(0.045) : Color.clear)
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

    private var showActions: Bool {
        row.waiting || hovering || expanded
    }

    /// Session title is the row hero; process-only rows de-rank to a status phrase.
    private var heroTitle: String {
        if row.waiting {
            if let t = row.usefulTask { return Self.truncate(t, 72) }
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
            return Self.truncate(t, 72)
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
        if row.waiting {
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
