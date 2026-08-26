import Foundation
import AppKit

/// 4.0-γ file split — Preview fixtures — CLI-only visual contract, never reachable from UI.
/// Behavior-frozen: every member moved verbatim from StatusStore.swift;
/// the full test suite is the contract that nothing changed.
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
            source: ObservationSource = .session,
            live: Bool = true,
            ageMinutes: Int = 1
        ) -> AgentRow {
            var value = AgentRow(rowKey: key, agent: agent)
            value.sessionID = key
            value.task = task
            value.cwd = cwd
            value.project = AgentRow.shortProject(cwd)
            value.observationSource = source
            value.liveProcess = live
            value.processCount = live ? 1 : 0
            value.harvestMs = now - Int64(ageMinutes * 60 * 1000)
            value.startedMs = now - 54 * 60 * 1000
            value.records = 126
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
            fixtureRow.phase = name == "status-waiting" ? "waiting" : "testing"
            fixtureRow.model = "fixture-model"
            fixtureRow.tool = name == "status-waiting" ? "" : "swift_test"
            switch name {
            case "status-waiting":
                fixtureRow.waiting = true
                fixtureRow.waitKind = "Permission"
                fixtureRow.waitMessage = "Bash: ./scripts/release.sh 2.0.0 --commit"
                fixtureRow.waitSignal = .hooks
                fixtureRow.waitSinceMs = now - 8 * 60 * 1000
            case "status-stalled":
                fixtureRow.isStalled = true
                fixtureRow.harvestMs = now - 25 * 60 * 1000
            case "status-running":
                fixtureRow.progressDone = 12
                fixtureRow.progressTotal = 31
            default:
                fixtureRow.liveProcess = false
                fixtureRow.processCount = 0
            }
            fixtureRow.refreshObservationQuality(privacyLimited: false)
            observedSessions.replaceSessions([fixtureRow])
            cachedAll = sessionSources.merged()

            var snap = PulseSnapshot()
            switch name {
            case "status-running":
                snap.glance = .running
                snap.title = "1"
                snap.sectionTotals[.running] = 1
            case "status-stalled":
                snap.glance = .stalled
                snap.title = "1"
                snap.sectionTotals[.stalled] = 1
            case "status-waiting":
                snap.glance = .waiting
                snap.title = "1"
                snap.sectionTotals[.needsYou] = 1
            default:
                snap.glance = .idle
            }
            snap.headerTitle = name
            snap.header = name
            snap.tooltip = name
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
            codex.phase = "testing"
            codex.progressDone = 26
            codex.progressTotal = 31
            codex.processEvidence = .pathSignature

            var amp = row(
                "coverage-amp",
                .amp,
                task: "",
                cwd: "",
                source: .process
            )
            amp.harvestMs = 0
            amp.records = 0
            amp.processStartedMs = now - 60 * 60 * 1000
            amp.processCount = 2
            amp.processEvidence = .executable

            var cursor = row(
                "coverage-cursor",
                .cursor,
                task: "Refine adapter coverage",
                cwd: "/Users/me/code/Client",
                source: .cache,
                live: false
            )
            cursor.phase = "completed"
            observedSessions.replaceSessions([codex, amp, cursor])
            cachedAll = sessionSources.merged()
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
            recordCollectorHealth(Array(health.values))
            lastSuccessfulReadByAgent[.codex] = codex.harvestMs
            lastSuccessfulReadByAgent[.cursor] = cursor.harvestMs
            snapshot = PulseSnapshot(
                glance: .running,
                title: "2",
                tooltip: "coverage",
                accessibilityLabel: tr(.a11yRunning),
                headerTitle: "2 running",
                headerDetail: "",
                header: "2 running",
                rows: cachedAll,
                sectionTotals: [.running: 2, .recent: 1],
                projectCount: 2,
                totalCount: cachedAll.count,
                updatedAt: Date()
            )
            return
        }

        var waiting = row("claude-preview", .claude, task: "Approve the release build")
        waiting.waiting = true
        waiting.waitKind = "Permission"
        waiting.waitMessage = "Bash: ./scripts/release.sh 2.0.0 --commit"
        waiting.waitSignal = .hooks
        waiting.waitSinceMs = now - 8 * 60 * 1000

        var active = row(
            "codex-preview",
            .codex,
            task: "[hxddh/Pulse](https://github.com/hxddh/Pulse) Fix panel corners"
        )
        active.phase = "testing"
        active.progressDone = 18
        active.progressTotal = 31
        active.activityChange = .progress(done: 18, total: 31)
        active.activityChangedMs = now - 15_000
        active.tool = "swift_test"
        active.model = "gpt-5"
        active.contextPercent = 42
        active.tokensIn = 12_400
        active.tokensOut = 860

        var stalled = row(
            "pi-preview",
            .pi,
            task: "Check the process detector",
            cwd: "",
            ageMinutes: 32
        )
        stalled.isStalled = true

        var recent = row(
            "cursor-preview",
            .cursor,
            task: "Refine crowded tray alignment",
            cwd: "/Users/me/code/Design",
            live: false,
            ageMinutes: 4
        )
        recent.phase = "turn_complete"

        var rows = [waiting, active, stalled, recent]
        if name != "compact" {
            var cache = row(
                "kiro-preview",
                .kiro,
                task: "Audit settings copy",
                cwd: "/Users/me/code/Docs",
                source: .cache,
                live: false,
                ageMinutes: 6
            )
            cache.phase = "completed"
            var process = row(
                "replit-preview",
                .replit,
                task: "",
                cwd: "",
                source: .process,
                ageMinutes: 0
            )
            process.harvestMs = 0
            process.records = 0
            process.processStartedMs = now - 70 * 60 * 1000
            process.processEvidence = .executable
            var sub = row(
                "claude-sub-preview",
                .claude,
                task: "Run collector fixtures",
                cwd: "/Users/me/code/Pulse"
            )
            sub.subRunning = 2
            sub.subTotal = 3
            sub.model = "claude-sonnet-4"
            sub.contextPercent = 68
            rows += [cache, process, sub]
        }
        trayGrouping = name == "project" ? .project : .status
        rows.sort { $0.section.rawValue < $1.section.rawValue }
        observedSessions.replaceSessions(rows)
        cachedAll = sessionSources.merged()

        var snap = PulseSnapshot()
        snap.glance = .waiting
        snap.title = "Claude · 8m"
        snap.tooltip = "Needs you · Claude"
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
        snap.header = snap.headerTitle
        snap.projectCount = Set(rows.map(\.displayPath).filter { !$0.isEmpty }).count
        snap.updatedAt = Date()
        snapshot = snap
    }

    /// launchctl unload+load are two blocking subprocesses; never run them on
}
