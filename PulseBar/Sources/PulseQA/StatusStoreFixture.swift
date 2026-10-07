import Foundation
import AppKit
@testable import PulseApp

/// Preview fixtures — the QA driver's visual contract, not in the shipping app.
@MainActor
extension StatusStore {
    /// Deterministic visual contract for compact/crowded tray QA.
    ///
    /// `PulseQA --tray-fixture=<fixture>` only; the shipping app does not
    /// contain it. It feeds the real tray and catches
    /// count, state, grouping, alignment and density regressions without
    /// depending on whichever Agents happen to be running on a test machine.
    func installPreviewFixture(_ name: String) {
        previewFixtureActive = true
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        func row(
            _ key: String,
            _ agent: AgentID,
            task: String,
            cwd: String = "/Users/me/code/Pulse",
            source: RowSource = .hooks,
            live: Bool = true,
            ageMinutes: Int = 1
        ) -> AgentRow {
            var value = AgentRow(rowKey: key, agent: agent)
            value.sessionID = key
            value.task = task
            value.cwd = cwd
            value.project = TitleHeuristics.shortProject(cwd)
            value.source = source
            value.liveProcess = live
            value.state = live ? .running : .recent
            value.lastEventMs = now - Int64(ageMinutes * 60 * 1000)
            value.startedMs = now - 54 * 60 * 1000
            return value
        }

        if name.hasPrefix("status-") {
            // One concrete row, so visual QA exercises the real tray layout
            // for that lamp state.
            var fixtureRow = row(
                "status-fixture",
                .cursor,
                task: name == "status-waiting"
                    ? "Approve the packaging step"
                    : "Ship Signal Quality",
                cwd: "/Users/me/code/Pulse"
            )
            switch name {
            case "status-waiting":
                fixtureRow.state = .blocked(RowWait(
                    kind: "Permission",
                    ask: "Bash: ./scripts/release.sh 2.0.0 --commit",
                    sinceMs: now - 8 * 60 * 1000
                ))
            case "status-stalled":
                fixtureRow.isStalled = true
                fixtureRow.lastEventMs = now - 25 * 60 * 1000
            case "status-running":
                fixtureRow.lastWord = "The fixtures pass."
                let step = SessionBook.Step(tool: "Bash", target: "swift test", ms: now - 60 * 1000)
                fixtureRow.recentSteps = [step]
                fixtureRow.lastStep = step
                fixtureRow.turnStartMs = now - 14 * 60 * 1000
            case "status-turn":
                // Finished, unseen — a quiet count, not the red lamp.
                fixtureRow.state = .yourTurn(sinceMs: now - 3 * 60 * 1000)
            default:
                fixtureRow.liveProcess = false
                fixtureRow.state = .recent
            }
            landFixture([fixtureRow], title: name == "status-waiting" ? "1 · 8m" : "")
            return
        }

        if name == "coverage" {
            let codex = row(
                "coverage-codex",
                .codex,
                task: "Ship runtime observability",
                cwd: "/Users/me/code/Pulse"
            )

            var pi = row(
                "coverage-pi",
                .pi,
                task: "",
                cwd: "",
                source: .process
            )
            pi.lastEventMs = 0
            pi.state = .processOnly
            pi.startedMs = now - 60 * 60 * 1000

            let cursor = row(
                "coverage-cursor",
                .cursor,
                task: "Refine adapter coverage",
                cwd: "/Users/me/code/Client",
                live: false
            )
            hooksStatus = .all
            landFixture([codex, pi, cursor], title: "")
            return
        }

        var waiting = row("claude-preview", .claude, task: "Approve the release build")
        waiting.state = .blocked(RowWait(
            kind: "Permission",
            ask: "Bash: ./scripts/release.sh 2.0.0 --commit",
            sinceMs: now - 8 * 60 * 1000
        ))

        var active = row(
            "codex-preview",
            .codex,
            task: "[hxddh/Pulse](https://github.com/hxddh/Pulse) Fix panel corners"
        )
        active.activityMs = now - 15_000
        active.lastWord = "Corners now follow the panel radius."
        active.recentSteps = [
            SessionBook.Step(tool: "Edit", target: "Sources/PulseApp/PulseTheme.swift", ms: now - 3 * 60 * 1000),
            SessionBook.Step(tool: "Bash", target: "swift test --filter Snapshot", ms: now - 15_000),
        ]
        active.lastStep = active.recentSteps.last
        active.turnStartMs = now - 9 * 60 * 1000

        var stalled = row(
            "pi-preview",
            .pi,
            task: "Check the process detector",
            cwd: "",
            ageMinutes: 32
        )
        stalled.isStalled = true

        let recent = row(
            "cursor-preview",
            .cursor,
            task: "Refine crowded tray alignment",
            cwd: "/Users/me/code/Design",
            live: false,
            ageMinutes: 4
        )

        var rows = [waiting, active, stalled, recent]
        if name != "compact" {
            let quiet = row(
                "gemini-preview",
                .gemini,
                task: "Audit settings copy",
                cwd: "/Users/me/code/Docs",
                live: false,
                ageMinutes: 6
            )
            var process = row(
                "copilot-preview",
                .copilot,
                task: "",
                cwd: "",
                source: .process,
                ageMinutes: 0
            )
            process.lastEventMs = 0
            process.state = .processOnly
            process.startedMs = now - 70 * 60 * 1000
            let sub = row(
                "claude-sub-preview",
                .claude,
                task: "Run collector fixtures",
                cwd: "/Users/me/code/Pulse"
            )
            rows += [quiet, process, sub]
        }
        rows.sort { $0.section.rawValue < $1.section.rawValue }
        landFixture(rows, title: "\(rows.filter(\.isBlocked).count) · 8m")
    }

    /// The fixture's rows on screen, with the lamp, the tooltip and the
    /// counts the projection would give them.
    private func landFixture(_ rows: [AgentRow], title: String) {
        cachedAll = rows
        let counts = TrayState.Counts(rows: rows)
        let rule = TrayState.lampRule(counts: counts)
        var snap = PulseSnapshot()
        snap.lamp = Lamp(rule)
        snap.title = title
        snap.tooltip = TrayState.lampSentence(rule, lang: lang)
        snap.accessibilityLabel = snap.lamp.isGrey ? tr(.a11yIdle) : snap.tooltip
        snap.rows = rows
        snap.counts = counts
        snap.updatedAt = Date()
        snapshot = snap
    }
}
