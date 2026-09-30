import Foundation
import AppKit
@testable import PulseApp

/// Preview fixtures — the QA driver's visual contract, not in the shipping app.
@MainActor
extension StatusStore {
    /// Deterministic visual contract for compact/crowded tray QA.
    ///
    /// `PulseQA --tray-fixture=<fixture>` only; the shipping app does not
    /// contain it. It hosts the real TrayPanel and catches
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
            value.project = AgentRow.shortProject(cwd)
            value.source = source
            value.liveProcess = live
            value.state = live ? .running : .recent
            value.lastEventMs = now - Int64(ageMinutes * 60 * 1000)
            value.startedMs = now - 54 * 60 * 1000
            return value
        }

        if name.hasPrefix("status-") {
            // Compact status fixtures used to only stamp glance/header and left
            // `rows` empty, so `--capture-tray-panel` still showed whatever live
            // sessions (or nothing) were present. Inject one concrete row so
            // visual QA exercises the real tray layout for that lamp state.
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
            setCachedAll([fixtureRow])

            var snap = PulseSnapshot()
            switch name {
            case "status-running":
                snap.glance = .running
            case "status-stalled":
                snap.glance = .stalled
            case "status-waiting":
                snap.glance = .waiting
                snap.title = "1 · 8m"
            case "status-turn":
                // A finished turn is grey, even while its process lives.
                snap.glance = .idle
            default:
                snap.glance = .idle
            }
            snap.headerTitle = name
            snap.counts = TrayState.Counts(rows: [fixtureRow])
            snap.lamp = LampFace.glance(snap.glance)
            snap.tooltip = TrayState.lampSentence(TrayState.lampRule(counts: TrayState.Counts(rows: [fixtureRow]), glance: snap.glance), lang: lang)
            snap.accessibilityLabel = tr(snap.glance.accessibilityKey)
            snap.rows = [fixtureRow]
            snap.totalCount = 1
            snap.updatedAt = Date()
            snapshot = snap
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
            setCachedAll([codex, pi, cursor])
            hooksStatus = .all
            snapshot = PulseSnapshot(
                glance: .running,
                title: "",
                tooltip: TrayState.lampSentence(TrayState.lampRule(counts: TrayState.Counts(rows: cachedAll), glance: .running), lang: lang),
                accessibilityLabel: tr(.a11yRunning),
                headerTitle: "2 running",
                rows: cachedAll,
                counts: TrayState.Counts(rows: cachedAll),
                lamp: LampFace.glance(.running),
                totalCount: cachedAll.count,
                updatedAt: Date()
            )
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
        setCachedAll(rows)

        var snap = PulseSnapshot()
        snap.glance = .waiting
        snap.lamp = LampFace.glance(.waiting)
        let blockedCount = rows.filter { $0.isBlocked }.count
        snap.title = "\(blockedCount) · 8m"
        snap.tooltip = TrayState.lampSentence(TrayState.lampRule(counts: TrayState.Counts(rows: rows), glance: .waiting), lang: lang)
        snap.accessibilityLabel = tr(.a11yWaiting)
        snap.rows = rows
        snap.totalCount = rows.count
        snap.counts = TrayState.Counts(rows: rows)
        snap.headerTitle = snap.counts.summary(lang)
        snap.updatedAt = Date()
        snapshot = snap
    }
}
