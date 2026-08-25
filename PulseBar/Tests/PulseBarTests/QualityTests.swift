import XCTest
@testable import PulseBar

/// 2.9 Quality — second-grade freshness, and the measurement measuring itself.
///
/// The hook has stood in the vendor's event stream since 1.0, but only for
/// waits. These tests hold the new deal for activity events: state not
/// ledger, never a wait, present tense only inside the live window — and the
/// yield rules that stop "the agent is idle" and "Pulse stopped seeing" from
/// wearing the same clothes.
final class QualityTests: XCTestCase {

    private let now: Int64 = 1_800_000_000_000
    private var wallNow: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-activity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ActivitySpool.directoryOverride = directory
    }

    override func tearDownWithError() throws {
        ActivitySpool.directoryOverride = nil
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - The receiver's side: what an event becomes on disk

    func testAPreToolUseEventBecomesAStateFileAndNeverAttention() throws {
        let stdin = #"""
        {"hook_event_name":"PreToolUse","session_id":"sess-a","tool_name":"Edit",
         "tool_input":{"file_path":"/repo/src/Main.swift"},"cwd":"/repo"}
        """#
        _ = PulseHookReceiver.run(arguments: ["--hook", "claude", "activity"], stdin: stdin)
        let events = ActivitySpool.readEvents(nowMs: wallNow)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(event.agent, "claude")
        XCTAssertEqual(event.session, "sess-a")
        XCTAssertEqual(event.event, "tool")
        XCTAssertEqual(event.tool, "Edit")
        XCTAssertEqual(event.target, "/repo/src/Main.swift")
        let url = directory.appendingPathComponent("claude-sess-a.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testTheEventNameAloneDispatchesWithoutAKindArgument() throws {
        let stdin = #"{"hook_event_name":"UserPromptSubmit","session_id":"sess-b","prompt":"Fix the login bug\nsecond line"}"#
        _ = PulseHookReceiver.run(arguments: ["--hook", "claude"], stdin: stdin)
        let event = try XCTUnwrap(ActivitySpool.readEvents(nowMs: wallNow).first)
        XCTAssertEqual(event.event, "prompt")
        XCTAssertEqual(event.prompt, "Fix the login bug second line")
        XCTAssertEqual(event.tool, "")
    }

    func testLatestEventWinsBecauseActivityIsAStateNotALedger() throws {
        for (kind, body) in [
            ("activity", #"{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"Edit","tool_input":{"file_path":"/a"}}"#),
            ("activity", #"{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"Bash","tool_input":{"command":"swift test"}}"#),
        ] {
            _ = PulseHookReceiver.run(arguments: ["--hook", "claude", kind], stdin: body)
        }
        let events = ActivitySpool.readEvents(nowMs: wallNow)
        XCTAssertEqual(events.count, 1, "one session, one state file")
        XCTAssertEqual(events.first?.tool, "Bash")
    }

    func testASessionlessEventWritesNothing() {
        _ = PulseHookReceiver.run(
            arguments: ["--hook", "claude", "activity"],
            stdin: #"{"hook_event_name":"PreToolUse","tool_name":"Bash"}"#
        )
        XCTAssertTrue(ActivitySpool.readEvents(nowMs: wallNow).isEmpty)
    }

    func testSecretsNeverReachTheSpool() throws {
        let stdin = #"{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"Bash","tool_input":{"command":"deploy with Bearer abc123secretvalue"}}"#
        _ = PulseHookReceiver.run(arguments: ["--hook", "claude", "activity"], stdin: stdin)
        let event = try XCTUnwrap(ActivitySpool.readEvents(nowMs: wallNow).first)
        XCTAssertFalse(event.target.contains("abc123secretvalue"), event.target)
    }

    // MARK: - The reader's side: identity and age

    func testABodyThatDisagreesWithItsFilenameIsRefused() throws {
        let body: [String: Any] = [
            "v": 1, "agent": "claude", "session": "other",
            "event": "tool", "tool": "Edit", "target": "", "prompt": "",
            "cwd": "", "ts_ms": wallNow,
        ]
        try JSONSerialization.data(withJSONObject: body)
            .write(to: directory.appendingPathComponent("claude-sess-x.json"))
        XCTAssertTrue(ActivitySpool.readEvents(nowMs: wallNow).isEmpty,
                      "the filename decides who this is; a disagreeing body is somebody being clever")
    }

    func testAnAncientEventIsNotServedAndAFutureStampIsClamped() throws {
        _ = ActivitySpool.write(ActivitySpool.Event(
            agent: "claude", session: "old", event: "tool",
            tool: "Edit", target: "", prompt: "", cwd: "",
            tsMs: wallNow - ActivitySpool.maxAgeMs - 60_000
        ))
        XCTAssertTrue(ActivitySpool.readEvents(nowMs: wallNow).isEmpty)

        _ = ActivitySpool.write(ActivitySpool.Event(
            agent: "claude", session: "future", event: "tool",
            tool: "Edit", target: "", prompt: "", cwd: "",
            tsMs: wallNow + 10 * 60 * 1000
        ))
        let event = try XCTUnwrap(ActivitySpool.readEvents(nowMs: wallNow).first)
        XCTAssertLessThanOrEqual(event.tsMs, wallNow,
                                 "the writer is this machine — a future stamp is a broken clock")
    }

    // MARK: - The builder's side: what an event may become

    private func build(
        harvest: [ActivityHarvest.Row] = [],
        activity: [ActivitySpool.Event] = []
    ) -> [AgentRow] {
        SnapshotBuilder.build(
            SnapshotBuilder.Input(harvest: harvest, activity: activity),
            previous: SnapshotBuilder.Previous(),
            context: SnapshotBuilder.Context(
                nowMs: now,
                terminal: TerminalFocus.Environment(
                    warpRunning: false, ttyHostRunning: false, allowTTYAutomation: false
                ),
                lang: .en
            )
        ).rows
    }

    private func harvestRow(session: String = "sess-a") -> ActivityHarvest.Row {
        var row = ActivityHarvest.Row(
            id: .claude, task: "Fix the auth module", project: "repo",
            cwd: "/work/repo", skill: ""
        )
        row.sessionID = session
        row.harvestMs = now - 60_000
        row.evidence = .session
        return row
    }

    private func toolEvent(session: String = "sess-a", tsMs: Int64? = nil) -> ActivitySpool.Event {
        ActivitySpool.Event(
            agent: "claude", session: session, event: "tool",
            tool: "Edit", target: "/work/repo/src/Main.swift", prompt: "",
            cwd: "/work/repo", tsMs: tsMs ?? now - 5_000
        )
    }

    func testAFreshEventPutsThePresentTenseOnTheRow() throws {
        let rows = build(harvest: [harvestRow()], activity: [toolEvent()])
        let row = try XCTUnwrap(rows.first { $0.sessionID == "sess-a" })
        XCTAssertEqual(row.liveTool, "Edit")
        XCTAssertEqual(row.liveTarget, "/work/repo/src/Main.swift")
        XCTAssertEqual(row.liveAtMs, now - 5_000)
        XCTAssertGreaterThanOrEqual(row.activityChangedMs, now - 5_000,
                                    "the event is live-signal evidence, on the live-signal clock")
    }

    func testAPromptEventClearsTheToolBecauseTheTurnEnded() throws {
        var prompt = toolEvent()
        prompt.event = "prompt"
        prompt.tsMs = now - 1_000
        let rows = build(harvest: [harvestRow()], activity: [prompt])
        let row = try XCTUnwrap(rows.first { $0.sessionID == "sess-a" })
        XCTAssertEqual(row.liveTool, "")
        XCTAssertEqual(row.liveAtMs, now - 1_000)
    }

    func testAnEventNeverCreatesARowAndNeverAWait() {
        let alone = build(activity: [toolEvent(session: "nobody-home")])
        XCTAssertTrue(alone.isEmpty, "an event without a row has no other evidence — no row")
        let rows = build(harvest: [harvestRow()], activity: [toolEvent()])
        XCTAssertFalse(rows.contains(where: \.waiting), "activity must never become Waiting")
    }

    func testAFutureEventStampIsClampedByTheBuilderToo() throws {
        let rows = build(harvest: [harvestRow()], activity: [toolEvent(tsMs: now + 600_000)])
        let row = try XCTUnwrap(rows.first { $0.sessionID == "sess-a" })
        XCTAssertLessThanOrEqual(row.liveAtMs, now)
    }

    // MARK: - The story: present tense only for second-grade evidence

    @MainActor
    private func liveRow(ageMs: Int64) -> AgentRow {
        var row = AgentRow(rowKey: "claude|s1", agent: .claude)
        row.task = "Fix the auth module"
        row.liveProcess = true
        row.harvestMs = wallNow
        row.liveTool = "Edit"
        row.liveTarget = "/work/repo/src/Main.swift"
        row.liveAtMs = wallNow - ageMs
        return row
    }

    @MainActor
    func testTheStorySpeaksPresentTenseOnlyInsideTheLiveWindow() {
        let store = StatusStore()
        store.language = .en
        let fresh = store.rowStoryLine(liveRow(ageMs: 10_000))
        XCTAssertTrue(fresh.contains("Edit"), fresh)
        XCTAssertTrue(fresh.contains("Main.swift"), "a path shows as its leaf: \(fresh)")
        XCTAssertFalse(fresh.contains("/work/repo"), "never the whole path on a row: \(fresh)")

        let stale = store.rowStoryLine(liveRow(ageMs: ActivitySpool.liveWindowMs + 30_000))
        XCTAssertFalse(stale.contains("Main.swift"),
                       "past the window the polled story takes back over: \(stale)")
    }

    // MARK: - Yield: the measurement measuring itself

    func testFactClassesNameWhatActuallyCameOut() {
        var row = ActivityHarvest.Row(id: .claude, task: "t", project: "", cwd: "/w", skill: "")
        row.tool = "Edit"
        row.tokensIn = 100
        row.planStep = "Running the gates"
        let classes = ActivityHarvest.factClasses(of: [row])
        XCTAssertTrue(classes.isSuperset(of: ["task", "tool", "tokens", "plan", "workspace"]))
        XCTAssertFalse(classes.contains("word"))
        XCTAssertTrue(ActivityHarvest.factClasses(of: []).isEmpty)
    }

    func testDriftIsStructuredRowsWithZeroCoreFacts() {
        var health = ActivityHarvest.CollectorHealth(
            id: .claude, state: .observed, durationMs: 1, rowCount: 2,
            sourcePresent: true, errorKind: ""
        )
        XCTAssertTrue(health.looksDrifted, "rows with no core facts from a structured adapter is drift")
        health.factClasses = ["task"]
        XCTAssertFalse(health.looksDrifted)
        health.factClasses = []
        health.state = .noSessions
        XCTAssertFalse(health.looksDrifted, "no rows is idleness, not drift")
        var thin = health
        thin.id = .replit
        thin.state = .observed
        XCTAssertFalse(thin.looksDrifted, "a best-effort adapter never promised core facts")
    }

    @MainActor
    func testTheSupportLineSaysDriftOutLoudAndYieldQuietly() {
        let store = StatusStore()
        store.language = .en
        var item = AgentSupportHealth(
            agent: .claude, collectorState: .observed, collectorDurationMs: 1,
            collectorRows: 1, sourcePresent: true, collectorErrorKind: "",
            processDetected: false, processEvidence: nil, evidence: .session,
            lastSuccessfulReadMs: 0, lastWaitingSignalMs: 0,
            hasGoal: true, hasWorkspace: true, hasActivity: true,
            hasProgress: true, waitingSignalReady: true
        )
        item.factClasses = ["task", "tool", "tokens"]
        let quiet = store.supportYieldDetail(item)
        XCTAssertTrue(quiet.contains("task"), quiet)
        item.looksDrifted = true
        XCTAssertTrue(store.supportYieldDetail(item).contains("drift"),
                      store.supportYieldDetail(item))
    }
}
