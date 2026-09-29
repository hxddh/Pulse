import Foundation
import AppKit

/// Preview fixtures — the CLI-only visual contract, never reachable from UI.
@MainActor
extension StatusStore {
    /// Deterministic visual contract for compact/crowded tray QA.
    ///
    /// This is command-line only (`--tray-fixture=<fixture>`) and never
    /// reachable from product UI. It hosts the real TrayPanel and catches
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
            source: RowSource = .session,
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
            value.harvestMs = now - Int64(ageMinutes * 60 * 1000)
            value.startedMs = now - 54 * 60 * 1000
            return value
        }

        if name.hasPrefix("status-") {
            // Compact status fixtures used to only stamp glance/header and left
            // `rows` empty, so `--capture-tray-panel` still showed whatever live
            // harvest (or nothing) was present. Inject one concrete row so
            // visual QA exercises the real tray layout for that lamp state.
            var fixtureRow = row(
                "status-fixture",
                .cursor,
                task: name == "status-waiting"
                    ? "Approve the packaging step"
                    : "Ship Signal Quality",
                cwd: "/Users/me/code/Pulse"
            )
            fixtureRow.model = "fixture-model"
            switch name {
            case "status-waiting":
                fixtureRow.state = .blocked(RowWait(
                    kind: "Permission",
                    ask: "Bash: ./scripts/release.sh 2.0.0 --commit",
                    sinceMs: now - 8 * 60 * 1000,
                    signal: .hooks
                ))
            case "status-stalled":
                fixtureRow.isStalled = true
                fixtureRow.harvestMs = now - 25 * 60 * 1000
            case "status-running":
                fixtureRow.planSteps = [
                    ActivityHarvest.PlanStep(text: "Read the collector", state: .done),
                    ActivityHarvest.PlanStep(text: "Run the fixtures", state: .current),
                ]
            case "status-turn":
                // 16.0: finished, unseen — a quiet count, not the red lamp.
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
                snap.sectionTotals[.running] = 1
            case "status-stalled":
                snap.glance = .stalled
                snap.sectionTotals[.stalled] = 1
            case "status-waiting":
                snap.glance = .waiting
                snap.title = "1 · 8m"
                snap.sectionTotals[.needsYou] = 1
            case "status-turn":
                // A finished turn is grey, even while its process lives.
                snap.glance = .idle
                snap.sectionTotals[.running] = 1
            default:
                snap.glance = .idle
            }
            snap.headerTitle = name
            snap.lamp = LampFace.glance(snap.glance)
            snap.tooltip = LampExplanation.make(rows: [fixtureRow], glance: snap.glance).sentence(lang)
            snap.accessibilityLabel = tr(snap.glance.accessibilityKey)
            snap.rows = [fixtureRow]
            snap.totalCount = 1
            snap.updatedAt = Date()
            snapshot = snap
            return
        }

        if name == "coverage" {
            var codex = row(
                "coverage-codex",
                .codex,
                task: "Ship runtime observability",
                cwd: "/Users/me/code/Pulse"
            )
            codex.model = "gpt-5"

            var amp = row(
                "coverage-amp",
                .amp,
                task: "",
                cwd: "",
                source: .process
            )
            amp.harvestMs = 0
            amp.state = .processOnly
            amp.startedMs = now - 60 * 60 * 1000

            let cursor = row(
                "coverage-cursor",
                .cursor,
                task: "Refine adapter coverage",
                cwd: "/Users/me/code/Client",
                source: .cache,
                live: false
            )
            setCachedAll([codex, amp, cursor])
            engine.processesByAgent = [
                .codex: ProcessFacts(evidence: .pathSignature, startedMs: now - 54 * 60 * 1000, count: 1),
                .amp: ProcessFacts(evidence: .executable, startedMs: now - 60 * 60 * 1000, count: 2),
            ]
            hooksStatus = .installedBoth
            previewWaitingEventTimes = [
                .claude: now - 48_000,
                .codex: now - 12_000,
            ]
            var health = Dictionary(
                uniqueKeysWithValues: AgentID.allCases.map { agent in
                    (
                        agent,
                        ActivityHarvest.CollectorHealth(
                            id: agent,
                            state: .sourceAbsent,
                            durationMs: 1,
                            rowCount: 0,
                            sourcePresent: false,
                            errorKind: ""
                        )
                    )
                }
            )
            health[.codex] = .init(
                    id: .codex,
                    state: .observed,
                    durationMs: 31,
                    rowCount: 1,
                    sourcePresent: true,
                    errorKind: ""
                )
            health[.amp] = .init(
                    id: .amp,
                    state: .noSessions,
                    durationMs: 4,
                    rowCount: 0,
                    sourcePresent: true,
                    errorKind: ""
                )
            health[.cursor] = .init(
                    id: .cursor,
                    state: .schemaMismatch,
                    durationMs: 18,
                    rowCount: 0,
                    sourcePresent: true,
                    errorKind: "JSONDecodeError"
                )
            health[.claude] = .init(
                    id: .claude,
                    state: .permissionDenied,
                    durationMs: 3,
                    rowCount: 0,
                    sourcePresent: true,
                    errorKind: "PermissionError"
                )
            engine.recordCollectorHealth(Array(health.values))
            engine.lastSuccessfulReadByAgent[.codex] = codex.harvestMs
            engine.lastSuccessfulReadByAgent[.cursor] = cursor.harvestMs
            snapshot = PulseSnapshot(
                glance: .running,
                title: "",
                tooltip: LampExplanation.make(rows: cachedAll, glance: .running).sentence(lang),
                accessibilityLabel: tr(.a11yRunning),
                headerTitle: "2 running",
                rows: cachedAll,
                sectionTotals: [.running: 2, .recent: 1],
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
            sinceMs: now - 8 * 60 * 1000,
            signal: .hooks
        ))

        var active = row(
            "codex-preview",
            .codex,
            task: "[hxddh/Pulse](https://github.com/hxddh/Pulse) Fix panel corners"
        )
        active.activityMs = now - 15_000
        active.model = "gpt-5"
        active.lastWord = "Corners now follow the panel radius; running the snapshot tests."

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
            let cache = row(
                "kiro-preview",
                .kiro,
                task: "Audit settings copy",
                cwd: "/Users/me/code/Docs",
                source: .cache,
                live: false,
                ageMinutes: 6
            )
            var process = row(
                "replit-preview",
                .replit,
                task: "",
                cwd: "",
                source: .process,
                ageMinutes: 0
            )
            process.harvestMs = 0
            process.state = .processOnly
            process.startedMs = now - 70 * 60 * 1000
            var sub = row(
                "claude-sub-preview",
                .claude,
                task: "Run collector fixtures",
                cwd: "/Users/me/code/Pulse"
            )
            sub.model = "claude-sonnet-4"
            rows += [cache, process, sub]
        }
        rows.sort { $0.section.rawValue < $1.section.rawValue }
        setCachedAll(rows)

        var snap = PulseSnapshot()
        snap.glance = .waiting
        snap.lamp = LampFace.glance(.waiting)
        let blockedCount = rows.filter { $0.isBlocked }.count
        snap.title = "\(blockedCount) · 8m"
        snap.tooltip = LampExplanation.make(rows: rows, glance: .waiting).sentence(lang)
        snap.accessibilityLabel = tr(.a11yWaiting)
        snap.rows = rows
        snap.totalCount = rows.count
        snap.sectionTotals = Dictionary(
            uniqueKeysWithValues: TraySection.allCases.map { section in
                (section, rows.filter { $0.section == section }.count)
            }
        )
        let bits = TraySection.allCases.compactMap { section -> String? in
            let count = snap.sectionTotals[section] ?? 0
            guard count > 0 else { return nil }
            return "\(count) \(tr(section.titleKey).lowercased())"
        }
        snap.headerTitle = bits.joined(separator: " · ")
        snap.updatedAt = Date()
        snapshot = snap
    }
}
