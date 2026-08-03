import AppKit
import SwiftUI

/// A focused, evidence-first inspector for one concrete session.
///
/// The tray stays scan-friendly; this surface is where the complete operational
/// picture belongs. Raw tool/skill identifiers are deliberately behind a
/// disclosure so they remain available for debugging without becoming the
/// primary user-facing meaning.
@MainActor
final class AgentDetailWindowController: NSObject, NSWindowDelegate {
    static let shared = AgentDetailWindowController()

    private var window: NSWindow?
    private var hosting: NSHostingController<AgentDetailView>?

    func show(store: StatusStore, row: AgentRow) {
        if let window, let hosting {
            hosting.rootView = AgentDetailView(store: store, rowKey: row.rowKey)
            window.title = "\(row.agent.displayName) · \(store.tr(.details))"
            present(window)
            return
        }
        let host = NSHostingController(rootView: AgentDetailView(store: store, rowKey: row.rowKey))
        let win = NSWindow(contentViewController: host)
        win.title = "\(row.agent.displayName) · \(store.tr(.details))"
        win.identifier = NSUserInterfaceItemIdentifier("pulse-agent-detail")
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.setContentSize(NSSize(width: 620, height: 560))
        win.contentMinSize = NSSize(width: 520, height: 420)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        hosting = host
        window = win
        present(win)
    }

    private func present(_ window: NSWindow) {
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        SettingsPresenter.restoreAccessoryIfNeeded()
    }
}

@MainActor
struct AgentDetailView: View {
    @ObservedObject var store: StatusStore
    let rowKey: String

    private var row: AgentRow? {
        store.snapshot.rows.first(where: { $0.rowKey == rowKey })
    }

    var body: some View {
        Group {
            if let row {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        identity(row)
                        if row.waiting { waitingCard(row) }
                        facts(row)
                        rawEvidence(row)
                        actions(row)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView(
                    store.tr(.noActivityYet),
                    systemImage: "clock.arrow.circlepath",
                    description: Text(store.tr(.supportNoObservedSignals))
                )
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func identity(_ row: AgentRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AgentIconView(id: row.agent)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.usefulTask ?? row.agent.displayName)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .lineLimit(3)
                Text("\(row.agent.displayName) · \(statusLabel(row))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !row.displayPath.isEmpty {
                    Text(row.displayPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer()
        }
    }

    private func waitingCard(_ row: AgentRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(store.tr(.needsYou), systemImage: "bell.badge.fill")
                .font(.headline)
                .foregroundStyle(GlanceKind.waiting.lampColor)
            Text(store.notificationBody(row))
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            Text(store.localizedWaitLine(row))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(GlanceKind.waiting.lampColor.opacity(0.10))
        )
    }

    private func facts(_ row: AgentRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.tr(.supportHealth))
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                fact(store.tr(.lastActive), value: store.lastActivityLabel(row))
                fact(store.tr(.lastAction), value: row.tool.isEmpty ? "—" : store.detailLastAction(row))
                fact(store.tr(.supportModel), value: row.model.isEmpty ? "—" : row.model)
                fact(store.tr(.supportProgress), value: progress(row))
                fact(store.tr(.supportResources), value: resources(row))
                fact(store.tr(.supportEvidence), value: evidence(row))
                fact(store.tr(.session), value: row.sessionID.isEmpty ? "—" : short(row.sessionID))
            }
        }
    }

    private func fact(_ label: String, value: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value)
                .font(.callout)
                .textSelection(.enabled)
        }
    }

    private func rawEvidence(_ row: AgentRow) -> some View {
        DisclosureGroup(store.tr(.supportAdapterDiagnostics)) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(store.tr(.detailTool)): \(row.tool.isEmpty ? "—" : row.tool)")
                Text("\(store.tr(.detailSkill)): \(row.skill.isEmpty ? "—" : row.skill)")
                Text("\(store.tr(.detailPhase)): \(row.phase.isEmpty ? "—" : row.phase)")
                Text("\(store.tr(.detailOutcome)): \(row.outcome.isEmpty ? "—" : row.outcome)")
                Text("\(store.tr(.detailEvidence)): \(row.observationSource.rawValue)")
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding(.top, 6)
        }
        .font(.subheadline)
    }

    private func actions(_ row: AgentRow) -> some View {
        HStack(spacing: 12) {
            if row.canFocusTerminal {
                Button(store.focusActionTitle(row)) { store.focusTerminal(row) }
            }
            if row.waiting {
                Button(store.tr(.dismissWait)) { store.dismissWaiting(row) }
                Button(row.isSnoozed ? store.tr(.snoozed) : store.tr(.snooze)) {
                    row.isSnoozed ? store.unsnooze(row) : store.snooze(row)
                }
            }
            Button(store.tr(.supportHealth)) { store.openSupportHealth() }
        }
        .buttonStyle(.bordered)
    }

    private func statusLabel(_ row: AgentRow) -> String {
        if row.waiting { return store.tr(.needsYou) }
        if row.isStalled { return store.tr(.stalled) }
        if row.isRecentOnly { return store.tr(.recent) }
        return store.tr(.running)
    }

    private func progress(_ row: AgentRow) -> String {
        if row.progressTotal > 0 { return "\(row.progressDone)/\(row.progressTotal)" }
        if row.progressDone > 0 { return "\(row.progressDone)" }
        return row.phase.isEmpty ? "—" : row.phase
    }

    private func resources(_ row: AgentRow) -> String {
        var bits: [String] = []
        if row.tokensIn > 0 || row.tokensOut > 0 { bits.append("↑\(AgentRow.compactToken(row.tokensIn)) ↓\(AgentRow.compactToken(row.tokensOut))") }
        if row.files > 0 { bits.append("\(row.files) \(store.tr(.detailFiles))") }
        if row.errors > 0 { bits.append("\(row.errors) \(store.tr(.detailErrors))") }
        if row.contextPercent > 0 { bits.append("\(store.tr(.detailContext)) \(row.contextPercent)%") }
        return bits.isEmpty ? "—" : bits.joined(separator: " · ")
    }

    private func evidence(_ row: AgentRow) -> String {
        switch row.observationSource {
        case .session: return store.tr(.supportStructured)
        case .cache: return store.tr(.supportCache)
        case .process: return store.tr(.supportProcess)
        }
    }

    private func short(_ raw: String) -> String {
        raw.count <= 28 ? raw : String(raw.prefix(12)) + "…" + String(raw.suffix(10))
    }
}
