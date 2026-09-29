import Foundation
import SQLite3
import Testing
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

/// Clarity fixes — each test pins one defect found by reading the code: the
/// value the user would have seen, before and after.
@MainActor
@Suite("Clarity fixes", .serialized)
struct ClarityFixTests {
    let now: Int64 = 1_800_000_000_000
    static let minute: Int64 = 60_000

    // MARK: - Harness

    final class Home {
        let url: URL
        init() {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("pulse-clarity-\(UUID().uuidString)", isDirectory: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }

        @discardableResult
        func write(_ relative: String, _ text: String, modified: Date? = nil) throws -> URL {
            let file = url.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
            if let modified {
                try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
            }
            return file
        }

        func database(_ relative: String, _ statements: [String]) throws {
            let file = url.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            var db: OpaquePointer?
            guard sqlite3_open(file.path, &db) == SQLITE_OK, let db else { throw CocoaError(.fileWriteUnknown) }
            defer { sqlite3_close(db) }
            for sql in statements {
                guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                    throw NSError(domain: "clarity", code: 1, userInfo: [NSLocalizedDescriptionKey: sql])
                }
            }
        }

        func rows(_ id: AgentID) -> [ActivityHarvest.Row] {
            NativeActivityHarvest.scan(
                allowAppData: true, appDataAgents: [id], home: url, agentFilter: [id]
            ).rows.filter { $0.id == id }
        }
    }

    func session(_ id: AgentID, _ sessionID: String, skill: String = "", ageMs: Int64 = 70_000) -> ActivityHarvest.Row {
        ActivityHarvest.Row(
            id: id, task: "Fix the login flow", project: "p", cwd: "/p", skill: skill,
            tool: "", harvestMs: now - ageMs, subRunning: 0, subTotal: 0, sessionID: sessionID,
            evidence: .session
        )
    }

    func build(
        procs: [ProcessProbe.Hit] = [],
        harvest: [ActivityHarvest.Row] = [],
        attention: [AttentionReader.Entry] = [],
        vendorWaits: [ClaudeAgentsProbe.Wait] = [],
        dismissed: Set<String> = []
    ) -> SnapshotBuilder.Result {
        var input = SnapshotBuilder.Input(procs: procs, harvest: harvest, attention: attention)
        input.vendorWaits = vendorWaits
        return SnapshotBuilder.build(
            input,
            previous: .init(),
            context: SnapshotBuilder.Context(
                nowMs: now,
                terminal: TerminalFocus.Environment(warpRunning: false, ttyHostRunning: false),
                lang: .en,
                dismissedPendingKeys: dismissed
            )
        )
    }

    func turn(session: String, ago: Int64 = 2_000) -> [AttentionReader.Entry] {
        let line = ["claude", "turn", "\(now - ago)", "", session, "/p", "", ""].joined(separator: "\t")
        return AttentionReader.parse(AttentionProtocol.header + line + "\n", nowMs: now)
    }

    // MARK: - 1 · a dismissed vendor wait stays dismissed

    @Test func aDismissedVendorWaitIsNotReleasedWhileClaudeStillReportsIt() throws {
        let wait = ClaudeAgentsProbe.Wait(
            sessionID: "s1", pid: 0, cwd: "/p", kind: .permission, reason: "permission prompt", sinceMs: now
        )
        let raised = build(harvest: [session(.claude, "s1")], vendorWaits: [wait])
        let firstWaiting = raised.rows.first { $0.isBlocked }
        let key = try #require(firstWaiting).rowKey

        let dismissed = build(harvest: [session(.claude, "s1")], vendorWaits: [wait], dismissed: [key])
        let dismissedRow = dismissed.rows.first { $0.rowKey == key }
        #expect(dismissedRow?.isBlocked == false)
        #expect(!dismissed.clearedPendingKeys.contains(key), "releasing it here relit the lamp on the next scan")

        let moved = build(harvest: [session(.claude, "s1")], dismissed: [key])
        #expect(moved.clearedPendingKeys.contains(key), "once Claude stops reporting it, the tombstone may go")
    }

    // MARK: - 6 · a failed probe run is no answer

    @Test func aFailedAgentsRunKeepsTheLastAnswer() {
        var state = ClaudeAgentsProbe.State()
        let wait = ClaudeAgentsProbe.Wait(sessionID: "s1", pid: 1, cwd: "", kind: .permission, reason: "", sinceMs: now)
        state.waits = [wait]
        ClaudeAgentsProbe.record(nil, into: &state, nowMs: now)
        #expect(state.waits == [wait], "one timeout must not blink a real wait off")
        ClaudeAgentsProbe.record([], into: &state, nowMs: now + 20_000)
        #expect(state.waits.isEmpty, "a successful empty answer clears")
    }

    // MARK: - 2 · the stop grace is a function of the two lines

    @Test func theStopGraceDoesNotDependOnWhenTheFileIsRead() {
        let raise = now - 10 * Self.minute
        let text = [
            ["claude", "permission", "\(raise)", "Bash: npm test", "s1", "/p", "", ""],
            ["claude", "stop", "\(raise + 1_000)", "", "s1", "", "", ""],
        ].map { $0.joined(separator: "\t") }.joined(separator: "\n") + "\n"
        let soon = AttentionReader.parse(text, nowMs: raise + 2_000)
        let later = AttentionReader.parse(text, nowMs: now)
        let soonKinds = soon.map { $0.kind }
        let laterKinds = later.map { $0.kind }
        #expect(soonKinds == ["Permission"])
        #expect(laterKinds == soonKinds, "re-reading ten minutes later flipped the verdict")
    }

    // MARK: - 3 / 19 · walks skip what is read another way

    @Test func claudeSubagentTranscriptsNeverSpeakForTheParent() throws {
        let home = Home()
        let project = ".claude/projects/-Users-me-app"
        let base = Date().addingTimeInterval(-120)
        try home.write("\(project)/sess-1.jsonl", [
            #"{"type":"user","sessionId":"sess-1","cwd":"/Users/me/app","message":{"role":"user","content":"Add an offline queue for login"}}"#,
            #"{"type":"assistant","sessionId":"sess-1","cwd":"/Users/me/app","message":{"role":"assistant","content":[{"type":"text","text":"The queue drains on reconnect."}]}}"#,
        ].joined(separator: "\n") + "\n", modified: base)
        try home.write("\(project)/sess-1/subagents/agent-a1.jsonl", [
            #"{"type":"user","isSidechain":true,"sessionId":"sess-1","cwd":"/Users/me/app","message":{"role":"user","content":"Search the repo for retry helpers"}}"#,
            #"{"type":"assistant","isSidechain":true,"sessionId":"sess-1","cwd":"/Users/me/app","message":{"role":"assistant","content":[{"type":"text","text":"Found three helpers."}]}}"#,
        ].joined(separator: "\n") + "\n")
        let rows = home.rows(.claude)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.lastWord == "The queue drains on reconnect.")
        #expect(row.task == "Add an offline queue for login")
        #expect(row.subTotal == 1, "still counted, by its own reader")
    }

    @Test func walksNameTheDirectoriesTheyLeaveToTheirReaders() {
        #expect(AgentID.claude.spec.walk.skippedDirectoryNames.contains("subagents"))
        #expect(AgentID.openhands.spec.walk.skippedDirectoryNames.contains("events"))
    }

    // MARK: - 4 · Pi follows the active branch

    static let piPath = "/h/.pi/agent/sessions/--Users-me-app--/2026-09-29T10-00-00-000Z_0199a1b2-c3d4-7e5f-8a6b-7c8d9e0f1a2b.jsonl"
    static let piHeader = #"{"type":"session","version":3,"id":"0199a1b2-c3d4-7e5f-8a6b-7c8d9e0f1a2b","timestamp":"2026-09-29T10:00:00.000Z","cwd":"/Users/me/app"}"#

    static func piMessage(_ id: String, parent: String?, role: String, _ text: String, second: Int) -> String {
        let parentJSON = parent.map { "\"\($0)\"" } ?? "null"
        return #"{"type":"message","id":"\#(id)","parentId":\#(parentJSON),"timestamp":"2026-09-29T10:00:\#(String(format: "%02d", second)).000Z","message":{"role":"\#(role)","content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    @Test func piLastWordFollowsTheBranchTheUserIsOn() throws {
        let text = [
            Self.piHeader,
            Self.piMessage("a1", parent: nil, role: "user", "Add an offline queue for login", second: 1),
            Self.piMessage("b1", parent: "a1", role: "assistant", "Two ways to do it.", second: 2),
            Self.piMessage("c1", parent: "b1", role: "user", "Try the first way", second: 3),
            Self.piMessage("d1", parent: "c1", role: "assistant", "The first way broke login.", second: 4),
            // /tree back to b1 and continue from there.
            Self.piMessage("e1", parent: "b1", role: "user", "Try the second way", second: 5),
        ].joined(separator: "\n")
        let fact = try #require(NativeActivityHarvest.parsePiFacts(text, path: Self.piPath).first)
        #expect(fact.lastWord == "Two ways to do it.", "the abandoned branch's reply is not this session's last word")
    }

    @Test func piTitleComesFromTheActiveBranch() throws {
        let text = [
            Self.piHeader,
            Self.piMessage("a1", parent: nil, role: "user", "Rewrite the parser", second: 1),
            Self.piMessage("b1", parent: "a1", role: "assistant", "Started on the parser.", second: 2),
            Self.piMessage("c1", parent: nil, role: "user", "Add an offline queue for login", second: 3),
            Self.piMessage("d1", parent: "c1", role: "assistant", "Queue added.", second: 4),
        ].joined(separator: "\n")
        let fact = try #require(NativeActivityHarvest.parsePiFacts(text, path: Self.piPath).first)
        #expect(fact.task == "Add an offline queue for login")
        #expect(fact.lastWord == "Queue added.")
    }

    @Test func piAcceptsWhatTheWindowCutAwayFrom() throws {
        let text = [
            Self.piHeader,
            Self.piMessage("a1", parent: nil, role: "user", "Add an offline queue for login", second: 1),
            // …the middle of the file is outside the read window…
            Self.piMessage("z9", parent: "y8", role: "assistant", "Queue added.", second: 9),
        ].joined(separator: "\n")
        let fact = try #require(NativeActivityHarvest.parsePiFacts(text, path: Self.piPath).first)
        #expect(fact.task == "Add an offline queue for login", "a broken chain cannot place the head, so it is kept")
        #expect(fact.lastWord == "Queue added.")
    }

    // MARK: - 5 · a turn marks a session, never a bare process

    /// 23.0: a process-only row is not a session a hook can speak for, and a
    /// turn with no session row makes none — so the process stays a process.
    @Test func aTurnNeverLandsOnAProcessOnlyRow() throws {
        let hit = ProcessProbe.Hit(id: .claude, count: 1, viaWarp: false, pid: 4242)
        let r = build(procs: [hit], attention: turn(session: "s-turn"))
        let row = try #require(r.rows.first)
        #expect(r.rows.count == 1)
        #expect(row.isProcessOnly)
        #expect(!row.isYourTurn)
    }

    @Test func aPrefixMatchedTurnIsClearedUnderTheFilesSpelling() throws {
        let r = build(harvest: [session(.claude, "sess-full")], attention: turn(session: "sess-full-123"))
        let row = try #require(r.rows.first)
        #expect(row.isYourTurn)
        #expect(row.sessionID == "sess-full")
        #expect(row.doneSession == "sess-full-123", "a done under the row's id would clear nothing")
    }

    // MARK: - 7 · merge takes "now" from the newer fragment

    @Test func mergeTakesNowFactsFromTheNewerFragmentWhateverTheOrder() throws {
        var newer = NativeActivityHarvest.Fact()
        newer.sessionID = "s1"
        newer.activityMs = now
        newer.tool = "Bash"
        newer.model = "model-new"
        newer.mode = "plan"
        newer.tokensIn = 10
        newer.planStep = "Running the gates"
        newer.progressDone = 3
        newer.progressTotal = 4
        newer.lastErrorText = "exit 2"
        var older = NativeActivityHarvest.Fact()
        older.sessionID = "s1"
        older.activityMs = now - 10 * Self.minute
        older.tool = "Read"
        older.model = "model-old"
        older.mode = "code"
        older.tokensIn = 99
        older.planStep = "Fixing the parser"
        older.progressDone = 1
        older.progressTotal = 9
        older.lastErrorText = "exit 1"

        let merged = try #require(NativeActivityHarvest.merge([newer, older]).first)
        #expect(merged.tool == "Bash")
        #expect(merged.model == "model-new")
        #expect(merged.mode == "plan")
        #expect(merged.tokensIn == 10)
        #expect(merged.planStep == "Running the gates")
        #expect(merged.progressDone == 3 && merged.progressTotal == 4, "one plan, not one list's count with another's step")
        #expect(merged.lastErrorText == "exit 2")
    }

    // MARK: - 8 · Pi's event count is not plan progress

    @Test func piEventCountIsNotAProgressBar() throws {
        let home = Home()
        try home.database(".pi/agent/sessions/sessions.db", [
            "CREATE TABLE session_meta (session_id TEXT, project_dir TEXT, started_at TEXT, last_event_at TEXT, event_count INTEGER);",
            "CREATE TABLE session_events (id INTEGER PRIMARY KEY, session_id TEXT, type TEXT, category TEXT, data TEXT, project_dir TEXT, created_at TEXT, bytes_returned INTEGER);",
            "INSERT INTO session_meta VALUES ('pi-count', '/Users/me/app', '1700000000', '1700000100', 412);",
        ])
        let row = try #require(home.rows(.pi).first)
        #expect(row.progressTotal == 0)
        #expect(row.progressDone == 0)
    }

    // MARK: - 9 · the tab search activates only on a match

    @Test(arguments: [TerminalFocus.terminalTabScript(tty: "ttys003"), TerminalFocus.iTermTabScript(tty: "ttys003")])
    func aTabSearchActivatesOnlyOnAMatch(script: String) throws {
        let match = try #require(script.range(of: "if ttyName contains"))
        let activate = try #require(script.range(of: "activate"))
        #expect(activate.lowerBound > match.upperBound, "activating before the search brought an unrelated window forward")
    }

    // MARK: - 10 / 21 · update checks

    @Test func aFailedUpdateCheckRetriesWithinTheHourAndSuccessWaitsADay() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(UpdateCheck.isDue(now: t0, lastSuccess: nil, lastAttempt: nil))
        #expect(!UpdateCheck.isDue(now: t0.addingTimeInterval(30 * 60), lastSuccess: nil, lastAttempt: t0))
        #expect(UpdateCheck.isDue(now: t0.addingTimeInterval(61 * 60), lastSuccess: nil, lastAttempt: t0),
                "one offline launch used to silence the check for a day")
        #expect(!UpdateCheck.isDue(now: t0.addingTimeInterval(23 * 3600), lastSuccess: t0, lastAttempt: t0))
        #expect(UpdateCheck.isDue(now: t0.addingTimeInterval(25 * 3600), lastSuccess: t0, lastAttempt: t0))
    }

    @Test func updateFailuresAreTypedForTheSurface() throws {
        let url = try #require(URL(string: "https://example.com/feed"))
        let busy = HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)
        #expect(UpdateCheck.interpret(data: Data(), response: busy, error: nil) == .failed(.http(503)))
        #expect(UpdateCheck.interpret(data: Data(#"{"tag_name":""}"#.utf8), response: nil, error: nil) == .failed(.noTag))
        #expect(UpdateCheck.Failure.http(503).detail == "HTTP 503")
    }

    // MARK: - 12 · a summary banner's click is audited on every wait it counted

    @Test func aSummaryBannerStandsForEveryWait() {
        #expect(PulseNotify.bannerWaitIDs(["a|1", "b|1", "c|1", "b|1", ""]) == ["a|1", "b|1", "c|1"])
        #expect(PulseNotify.bannerWaitIDs(["solo|1"]) == ["solo|1"])
        #expect(PulseNotify.bannerWaitIDs([]).isEmpty)
    }

    // MARK: - 13 / 14 · jumping to a wait

    func waitingRow(_ key: String, _ agent: AgentID, session: String = "", since: Int64) -> AgentRow {
        var row = AgentRow(rowKey: key, agent: agent)
        row.sessionID = session
        row.state = .blocked(RowWait(kind: "Permission", sinceMs: since, signal: .hooks))
        return row
    }

    /// 23.0: the jump takes the first wait in the builder's order, which
    /// lists the oldest first.
    @Test func theJumpGoesToTheFirstListedWait() {
        let oldest = waitingRow("a", .claude, since: now - 10 * Self.minute)
        let newer = waitingRow("b", .codex, since: now - Self.minute)
        #expect(StatusStore.firstWaitingRow(in: [oldest, newer])?.rowKey == "a")
        #expect(StatusStore.firstWaitingRow(in: []) == nil)
    }

    @Test func aBannerClickStaysInsideItsAgentAndNeedsAUniquePrefix() {
        let codex = waitingRow("codex|s1", .codex, session: "s1-abc", since: now)
        let claudeA = waitingRow("claude|a", .claude, session: "sess-1", since: now)
        let claudeB = waitingRow("claude|b", .claude, session: "sess-12", since: now)
        #expect(StatusStore.focusTarget(in: [codex, claudeA], idRaw: "claude", session: "s1-abc", rowKey: "")?.rowKey == "claude|a",
                "another agent's session is not a match; the agent's own waiting row is")
        #expect(StatusStore.focusTarget(in: [claudeA, claudeB], idRaw: "claude", session: "sess-1", rowKey: "")?.rowKey == "claude|a",
                "exact wins")
        #expect(StatusStore.focusTarget(in: [claudeB], idRaw: "claude", session: "sess-123", rowKey: "")?.rowKey == "claude|b")
        let ambiguous = StatusStore.focusTarget(in: [claudeA, claudeB], idRaw: "claude", session: "sess-1234", rowKey: "")
        #expect(ambiguous?.rowKey == "claude|a", "two prefixes: no session match, fall back to the agent's first wait")
    }

    // MARK: - 15 · coalesced events get a trailing fire

    @Test func aCoalescedEventIsDeliveredAtTheEndOfTheWindow() {
        var throttle = CoalescingThrottle(window: 0.35)
        #expect(throttle.event(at: 10.0) == .fire)
        #expect(throttle.event(at: 10.1) == .armTrailing, "the second event used to be dropped")
        #expect(throttle.event(at: 10.2) == .absorbed)
        #expect(abs(throttle.trailingDelay(at: 10.2) - 0.2) < 0.001)
        throttle.trailingFired(at: 10.4)
        #expect(throttle.event(at: 10.5) == .armTrailing)
        #expect(throttle.event(at: 11.0) == .absorbed, "the armed trailing fire carries it")
        throttle.trailingFired(at: 11.0)
        #expect(throttle.event(at: 11.5) == .fire)
    }

    // MARK: - 16 · a scan that finds the same world writes no log

    @Test func reconcilingTheSameWaitsIsNotADurableChange() {
        let row = waitingRow("claude|s1", .claude, session: "s1", since: now)
        var log = SessionLog()
        log.reconcileWaits(rows: [row], released: [], nowMs: now)
        let before = log
        let again = log.reconcileWaits(rows: [row], released: [], nowMs: now + 3_000)
        #expect(!again)
        #expect(log.hasSameDurableState(as: before))
        log.reconcileWaits(rows: [], released: [], nowMs: now + 6_000)
        #expect(!log.hasSameDurableState(as: before), "a resolved wait is a change")
    }

    // MARK: - 17 · one bad byte never erases the attention file

    @Test func anInvalidByteDoesNotEraseOpenWaits() throws {
        let home = Home()
        let file = home.url.appendingPathComponent("attention.tsv")
        try FileManager.default.createDirectory(at: home.url, withIntermediateDirectories: true)
        var bytes = Data(AttentionIO.header.utf8)
        bytes.append(Data("claude\tpermission\t\(now)\tBash: npm test\ts1\t/p\t\t\n".utf8))
        bytes.append(Data([0x63, 0x6f, 0xff, 0x0a]))
        try bytes.write(to: file)
        AttentionIO.pathOverride = file
        defer { AttentionIO.pathOverride = nil }

        AttentionIO.appendRawLine("codex\tdone\t\(now)\t\ts2\t\t\t")
        let written = try Data(contentsOf: file)
        let text = String(decoding: written, as: UTF8.self)
        #expect(text.contains("claude\tpermission"), "the rewrite used to start from an empty decode")
        #expect(text.contains("codex\tdone"))
    }

    // MARK: - 18 · old Goose sessions are not decoded message by message

    @Test func gooseReadsRecentMessagesOnlyForRecentSessions() {
        #expect(NativeActivityHarvest.gooseReadsRecentMessages(updatedMs: now - Self.minute, nowMs: now))
        #expect(!NativeActivityHarvest.gooseReadsRecentMessages(updatedMs: now - 73 * 60 * Self.minute, nowMs: now))
        #expect(NativeActivityHarvest.gooseReadsRecentMessages(updatedMs: 0, nowMs: now), "unknown is read, not assumed old")
    }

    @Test func anOldGooseSessionKeepsItsTitleWithoutAnOldAsk() throws {
        let home = Home()
        let ask = #"[{"type":"actionRequired","data":{"actionType":"elicitation","id":"e1","message":"Which database?","requested_schema":{}}}]"#
        try home.database(".local/share/goose/sessions/sessions.db", [
            "CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '', session_type TEXT NOT NULL DEFAULT 'user', working_dir TEXT NOT NULL, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, accumulated_input_tokens INTEGER, accumulated_output_tokens INTEGER, model_config_json TEXT, archived_at TIMESTAMP, parent_session_id TEXT);",
            "CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, message_id TEXT, session_id TEXT NOT NULL, role TEXT NOT NULL, content_json TEXT NOT NULL, created_timestamp INTEGER NOT NULL, timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP, tokens INTEGER, metadata_json TEXT);",
            "INSERT INTO sessions (id, name, working_dir, updated_at) VALUES ('old_1', 'CLI Session', '/Users/me/app', datetime('now', '-10 days'));",
            "INSERT INTO messages (message_id, session_id, role, content_json, created_timestamp) VALUES ('m1', 'old_1', 'user', '[{\"type\":\"text\",\"text\":\"Migrate the database\"}]', 1700000000);",
            "INSERT INTO messages (message_id, session_id, role, content_json, created_timestamp) VALUES ('m2', 'old_1', 'assistant', '\(ask)', 1700000001);",
        ])
        let row = try #require(home.rows(.goose).first)
        #expect(row.task == "Migrate the database")
        #expect(row.skill != "pending")
    }

    // MARK: - 20 · an old file ask with nothing alive is not red

    @Test func aStaleFilePendingWithNoProcessIsNotRed() throws {
        let stale = build(harvest: [session(.cline, "cl-1", skill: "pending", ageMs: 31 * Self.minute)])
        #expect(stale.rows.first?.isBlocked == false)

        let alive = build(
            procs: [ProcessProbe.Hit(id: .cline, count: 1, viaWarp: false, pid: 77)],
            harvest: [session(.cline, "cl-1", skill: "pending", ageMs: 31 * Self.minute)]
        )
        #expect(alive.rows.first?.isBlocked == true, "a live process keeps the vendor's own ask red")

        let recent = build(harvest: [session(.cline, "cl-1", skill: "pending", ageMs: 5 * Self.minute)])
        #expect(recent.rows.first?.isBlocked == true)
    }
}
