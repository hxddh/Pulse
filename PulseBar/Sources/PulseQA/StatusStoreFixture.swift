import Foundation
import AppKit
@testable import PulseApp
@testable import PulseKit

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
        var facts: [SessionKey: SessionFacts] = [:]

        func row(
            _ id: String,
            _ agent: AgentID,
            task: String,
            cwd: String = "/Users/me/code/Pulse",
            live: Bool = true,
            ageMinutes: Int = 1
        ) -> AgentRow {
            var value = AgentRow(key: SessionKey(agent, id), status: live ? .running(stalled: false) : .recent(.atPrompt))
            value.session = id
            value.task = task
            value.cwd = cwd
            value.liveProcess = live
            facts[value.key] = SessionFacts(lastEventMs: now - Int64(ageMinutes * 60 * 1000))
            return value
        }

        func process(_ agent: AgentID, pid: Int32) -> AgentRow {
            var value = AgentRow(key: .process(agent, pid: pid), status: .processOnly)
            value.liveProcess = true
            value.pid = pid
            return value
        }

        if name.hasPrefix("status-") {
            // One concrete row, so visual QA exercises the real tray layout
            // for that lamp state.
            var fixtureRow = row(
                "status-fixture",
                // Only an agent that says a tool started can stall.
                name == "status-stalled" ? .pi : .cursor,
                task: name == "status-waiting"
                    ? "Approve the packaging step"
                    : "Ship Signal Quality",
                cwd: "/Users/me/code/Pulse"
            )
            switch name {
            case "status-waiting":
                fixtureRow.status = .needsYou(Block(
                    kind: .permission,
                    ask: "Bash: ./scripts/release.sh 2.0.0 --commit",
                    sinceMs: now - 8 * 60 * 1000
                ))
            case "status-stalled":
                fixtureRow.status = .running(stalled: true)
                facts[fixtureRow.key]?.lastEventMs = now - 25 * 60 * 1000
            case "status-running":
                facts[fixtureRow.key] = SessionFacts(
                    lastWords: "The fixtures pass.",
                    lastStep: SessionBook.Step(tool: "Bash", target: "swift test", ms: now - 60 * 1000),
                    turnStartMs: now - 14 * 60 * 1000,
                    lastEventMs: now - 60 * 1000
                )
            case "status-turn":
                // Finished, unseen — a quiet count, not the red lamp.
                fixtureRow.status = .yourTurn(sinceMs: now - 3 * 60 * 1000)
            default:
                fixtureRow.liveProcess = false
                fixtureRow.status = .recent(.atPrompt)
            }
            landFixture([fixtureRow], facts: facts, title: name == "status-waiting" ? "1 · 8m" : "")
            return
        }

        if name == "coverage" {
            let codex = row("coverage-codex", .codex, task: "Ship runtime observability", cwd: "/Users/me/code/Pulse")
            let pi = process(.pi, pid: 4101)
            let cursor = row("coverage-cursor", .cursor, task: "Refine adapter coverage", cwd: "/Users/me/code/Client", live: false)
            hooksStatus = .ready()
            hookInstalls = Dictionary(uniqueKeysWithValues: AgentID.allCases.map { ($0, Connection.Install.complete) })
            landFixture([codex, pi, cursor], facts: facts, title: "")
            return
        }

        var waiting = row("claude-preview", .claude, task: "Approve the release build")
        waiting.status = .needsYou(Block(
            kind: .permission,
            ask: "Bash: ./scripts/release.sh 2.0.0 --commit",
            sinceMs: now - 8 * 60 * 1000
        ))

        let active = row(
            "codex-preview",
            .codex,
            task: "[hxddh/Pulse](https://github.com/hxddh/Pulse) Fix panel corners"
        )
        facts[active.key] = SessionFacts(
            lastWords: "Corners now follow the panel radius.",
            lastStep: SessionBook.Step(tool: "Bash", target: "swift test --filter Snapshot", ms: now - 15_000),
            turnStartMs: now - 9 * 60 * 1000,
            lastEventMs: now - 60 * 1000,
            activityMs: now - 15_000
        )

        var stalled = row("pi-preview", .pi, task: "Check the process detector", cwd: "", ageMinutes: 32)
        stalled.status = .running(stalled: true)

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
                "opencode-preview",
                .opencode,
                task: "Audit settings copy",
                cwd: "/Users/me/code/Docs",
                live: false,
                ageMinutes: 6
            )
            let sub = row("claude-sub-preview", .claude, task: "Run collector fixtures", cwd: "/Users/me/code/Pulse")
            rows += [quiet, process(.copilot, pid: 4102), sub]
        }
        rows.sort { $0.rank < $1.rank }
        landFixture(rows, facts: facts, title: "\(rows.filter(\.isBlocked).count) · 8m")
    }

    /// The fixture's rows on screen, with the lamp, the tooltip and the
    /// counts the projection would give them, and their sessions' facts.
    private func landFixture(_ rows: [AgentRow], facts: [SessionKey: SessionFacts], title: String) {
        self.rows = rows
        fixtureFacts = facts
        let counts = TrayState.Counts(rows: rows)
        let rule = TrayState.lampRule(counts: counts)
        var snap = PulseSnapshot(counts: counts, projected: true)
        snap.lamp = Lamp(rule)
        snap.title = title
        snap.tooltip = TrayState.lampSentence(rule, lang: lang)
        snap.accessibilityLabel = snap.lamp.isGrey ? tr(rule.accessibilityKey) : snap.tooltip
        snapshot = snap
    }
}
