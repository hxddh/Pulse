import Foundation
import Testing
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

/// 18.0 · Claude's own report of who is waiting (`claude agents --json`).
@Suite("Claude agents probe")
struct ClaudeAgentsProbeTests {
    let now: Int64 = 1_800_000_000_000

    // MARK: - Parse

    @Test func aTopLevelArrayOrAWrappedListParses() throws {
        let array = #"[{"sessionId":"s1","pid":4242,"cwd":"/p","status":"waiting","waitingFor":"permission prompt","kind":"interactive"}]"#
        let wrapped = #"{"agents":[{"sessionId":"s2","pid":7,"cwd":"/q","status":"busy"}]}"#
        #expect(try #require(ClaudeAgentsProbe.parse(Data(array.utf8))).first?.waitingFor == "permission prompt")
        #expect(try #require(ClaudeAgentsProbe.parse(Data(wrapped.utf8))).first?.sessionID == "s2")
        #expect(ClaudeAgentsProbe.parse(Data("Unknown command: agents".utf8)) == nil, "an older claude is no answer, not an empty fleet")
    }

    @Test(arguments: [
        ("waiting", "permission prompt", AttentionKind?.some(.permission)),
        ("waiting", "sandbox request", .some(.permission)),
        ("waiting", "input needed", .some(.question)),
        ("waiting", "dialog open", .some(.waiting)),
        ("blocked", "worker request", .some(.waiting)),
        ("busy", "permission prompt", nil),
        ("idle", "", nil),
    ])
    func onlyAWaitingStatusIsAWait(status: String, waitingFor: String, expected: AttentionKind?) {
        #expect(ClaudeAgentsProbe.kind(status: status, waitingFor: waitingFor) == expected)
    }

    @Test func aWaitKeepsTheTimePulseFirstSawIt() {
        let agent = ClaudeAgentsProbe.Agent(sessionID: "s1", pid: 1, cwd: "/p", status: "waiting", waitingFor: "permission prompt")
        let first = ClaudeAgentsProbe.waits([agent], previous: [], nowMs: now)
        let later = ClaudeAgentsProbe.waits([agent], previous: first, nowMs: now + 60_000)
        #expect(later.first?.sinceMs == now, "the vendor gives no stamp; the wait's age must not reset every sample")
    }

    // MARK: - The ration

    @Test func itRunsOnlyWhereItAddsSomethingAndNotTooOften() {
        var state = ClaudeAgentsProbe.State()
        #expect(!ClaudeAgentsProbe.shouldRun(state: state, nowMs: now, claudeLive: false, hooksInstalled: false))
        #expect(!ClaudeAgentsProbe.shouldRun(state: state, nowMs: now, claudeLive: true, hooksInstalled: true),
                "the hooks already say it, sooner")
        #expect(ClaudeAgentsProbe.shouldRun(state: state, nowMs: now, claudeLive: true, hooksInstalled: false))
        state.lastRunMs = now
        #expect(!ClaudeAgentsProbe.shouldRun(state: state, nowMs: now + 5_000, claudeLive: true, hooksInstalled: false))
        #expect(ClaudeAgentsProbe.shouldRun(state: state, nowMs: now + ClaudeAgentsProbe.minIntervalMs, claudeLive: true, hooksInstalled: false))
    }

    @Test func repeatedFailuresBackOffAndClearTheWaits() {
        var state = ClaudeAgentsProbe.State()
        state.waits = [ClaudeAgentsProbe.Wait(sessionID: "s1", pid: 1, cwd: "", kind: .permission, reason: "", sinceMs: now)]
        for index in 0..<ClaudeAgentsProbe.failuresBeforeBackoff {
            ClaudeAgentsProbe.record(nil, into: &state, nowMs: now + Int64(index))
        }
        #expect(state.waits.isEmpty, "no answer is never 'still waiting'")
        #expect(state.disabledUntilMs > now)
        #expect(!ClaudeAgentsProbe.shouldRun(state: state, nowMs: now + ClaudeAgentsProbe.minIntervalMs * 2, claudeLive: true, hooksInstalled: false))
    }

    // MARK: - Into the tray

    private func build(_ waits: [ClaudeAgentsProbe.Wait], attention: [AttentionReader.Entry] = [], dismissed: Set<String> = []) -> SnapshotBuilder.Result {
        let row = ActivityHarvest.Row(
            id: .claude, task: "Fix the login flow", project: "p", cwd: "/p", skill: "", tool: "",
            harvestMs: now - 30_000, subRunning: 0, subTotal: 0, sessionID: "s1", evidence: .session
        )
        return SnapshotBuilder.build(
            SnapshotBuilder.Input(harvest: [row], attention: attention, vendorWaits: waits),
            previous: .init(),
            context: SnapshotBuilder.Context(
                nowMs: now,
                terminal: TerminalFocus.Environment(warpRunning: false, ttyHostRunning: false),
                lang: .en,
                maxSessionsPerAgent: SnapshotBuilder.maxSessionsPerAgent,
                maxVisibleRows: SnapshotBuilder.maxVisibleRows,
                dismissedPendingKeys: dismissed,
                showAllAgents: false,
                stalledSeconds: AgentRow.stalledSeconds
            )
        )
    }

    private var permissionWait: ClaudeAgentsProbe.Wait {
        ClaudeAgentsProbe.Wait(sessionID: "s1", pid: 0, cwd: "/p", kind: .permission, reason: "permission prompt", sinceMs: now - 90_000)
    }

    @Test func aVendorReportedWaitLightsTheLampAndSaysSo() throws {
        let r = build([permissionWait])
        let row = try #require(r.rows.first)
        #expect(row.isBlocked)
        #expect(row.wait?.kind == "Permission")
        #expect(row.wait?.signal == .vendor)
        #expect(row.wait?.sinceMs == now - 90_000)
        #expect(r.snapshot.glance == .waiting)
        let explain = Explain.make(row, lang: .en, nowMs: now)
        #expect(explain.why.hasPrefix("Claude itself"))
        #expect(explain.ask == "permission prompt", "Claude's own words are the ask")
    }

    @Test func aHookRaiseForTheSameSessionWins() throws {
        let hook = AttentionReader.Entry(id: .claude, kind: "Input", message: "Which DB?", tsMs: now - 1_000, session: "s1", cwd: "/p")
        let row = try #require(build([permissionWait], attention: [hook]).rows.first)
        #expect(row.wait?.signal == .hooks)
        #expect(row.wait?.kind == "Input")
    }

    @Test func aDismissedVendorWaitStaysQuietAndNoRowIsInvented() throws {
        let key = try #require(build([]).rows.first).rowKey
        let dismissed = try #require(build([permissionWait], dismissed: [key]).rows.first)
        #expect(!dismissed.isBlocked)
        var stranger = permissionWait
        stranger.sessionID = "someone-else"
        #expect(build([stranger]).rows.count == 1, "a report with no row has no other evidence")
        let strangerRow = try #require(build([stranger]).rows.first)
        #expect(!strangerRow.isBlocked)
    }
}
