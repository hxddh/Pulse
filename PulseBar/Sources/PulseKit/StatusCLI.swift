import Foundation

/// Read-only CLI status output for terminal workflows (`pulse-hook --status`),
/// supporting plain text, JSON (for Raycast / SketchyBar / scripts), and tmux
/// status-line formatting.
///
/// Reads only the local `BookSnapshot` and `EventLog` tail — zero network,
/// zero daemon startup, and no raw prompt text in default output.
package enum StatusCLI {
    package enum Format: String, Equatable, Sendable {
        case plain
        case json
        case tmux
    }

    /// Reconstruct the current `TrayState` from `snapshotURL` (optional) and
    /// `logURL`, verifying process liveness for recorded PIDs.
    package static func loadState(
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        logURL: URL? = nil,
        snapshotURL: URL? = nil,
        isAlive: (Int32) -> Bool = AgentProcesses.isAlive
    ) -> TrayState {
        var book = SessionBook()
        var cursor: EventLog.Cursor? = nil
        if let snapshot = BookSnapshot.load(at: snapshotURL) {
            book = snapshot.book
            cursor = snapshot.cursor
        }
        if let chunk = EventLog.read(at: logURL, after: cursor) {
            for record in chunk.unapplied(after: cursor) {
                book.apply(record, nowMs: nowMs)
            }
        }
        book.endSessions(whosePidIsDead: isAlive)
        book.settleHeldTurns(nowMs: nowMs)
        book.prune(nowMs: nowMs)
        return TrayState.project(book: book, processes: [], context: TrayState.Context(nowMs: nowMs))
    }

    /// Format `state` for stdout in `format`. Pure.
    package static func render(_ state: TrayState, format: Format, nowMs: Int64) -> String {
        switch format {
        case .plain:
            return renderPlain(state, nowMs: nowMs)
        case .tmux:
            return renderTmux(state)
        case .json:
            return renderJSON(state, nowMs: nowMs)
        }
    }

    private static func renderPlain(_ state: TrayState, nowMs: Int64) -> String {
        let c = state.snapshot.counts
        var parts: [String] = []
        if c.blocked > 0 { parts.append("waiting=\(c.blocked)") }
        if c.running > 0 { parts.append("running=\(c.running)") }
        if c.stalled > 0 { parts.append("stalled=\(c.stalled)") }
        if c.yourTurn > 0 { parts.append("done=\(c.yourTurn)") }
        if c.recent > 0 { parts.append("recent=\(c.recent)") }
        if !state.conflicts.isEmpty {
            let uniqueFiles = Set(state.conflicts.values.flatMap { $0.map(\.path) }).count
            parts.append("conflicts=\(uniqueFiles)")
        }
        let header = parts.isEmpty ? "idle" : parts.joined(separator: " ")
        let waiting = state.rows.filter(\.isBlocked)
        guard !waiting.isEmpty else { return header }
        var lines = [header]
        for row in waiting {
            var cols = [row.agent.rawValue]
            if !row.project.isEmpty { cols.append(row.project) }
            if !row.branch.isEmpty { cols.append("(\(row.branch))") }
            if let since = row.wait?.sinceMs, since > 0 {
                cols.append(L10n.duration(Double(max(0, nowMs - since)) / 1000.0, .en))
            }
            lines.append("  " + cols.joined(separator: "  "))
        }
        return lines.joined(separator: "\n")
    }

    private static func renderTmux(_ state: TrayState) -> String {
        let c = state.snapshot.counts
        var segments: [String] = []
        if c.blocked > 0 { segments.append("#[fg=red]● \(c.blocked)#[default]") }
        if c.stalled > 0 { segments.append("#[fg=yellow]◐ \(c.stalled)#[default]") }
        if c.running > 0 { segments.append("#[fg=green]○ \(c.running)#[default]") }
        if c.yourTurn > 0 { segments.append("#[fg=colour245]✓ \(c.yourTurn)#[default]") }
        if !state.conflicts.isEmpty {
            let uniqueFiles = Set(state.conflicts.values.flatMap { $0.map(\.path) }).count
            segments.append("#[fg=yellow]⚠ \(uniqueFiles)#[default]")
        }
        return segments.joined(separator: " ")
    }

    private static func renderJSON(_ state: TrayState, nowMs: Int64) -> String {
        let c = state.snapshot.counts
        let uniqueConflicts = Set(state.conflicts.values.flatMap { $0.map(\.path) }).count
        let sessions: [[String: Any]] = state.rows.map { row in
            var entry: [String: Any] = [
                "agent": row.agent.rawValue,
                "status": statusName(row.status),
                "project": row.project,
                "branch": row.branch,
                "live": row.liveProcess,
            ]
            if let since = row.wait?.sinceMs, since > 0 {
                entry["waitSeconds"] = max(0, Int((nowMs - since) / 1000))
            }
            if !row.conflictingFiles.isEmpty {
                entry["conflictingFiles"] = row.conflictingFiles
            }
            return entry
        }
        let payload: [String: Any] = [
            "lamp": state.snapshot.lamp.rawValue,
            "counts": [
                "blocked": c.blocked,
                "running": c.running,
                "stalled": c.stalled,
                "yourTurn": c.yourTurn,
                "processOnly": c.processOnly,
                "recent": c.recent,
            ],
            "conflicts": uniqueConflicts,
            "sessions": sessions,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func statusName(_ status: AgentRow.Status) -> String {
        switch status {
        case .needsYou: return "waiting"
        case .running(stalled: true): return "stalled"
        case .running(stalled: false): return "running"
        case .yourTurn: return "done"
        case .processOnly: return "process_only"
        case .recent: return "recent"
        }
    }
}
