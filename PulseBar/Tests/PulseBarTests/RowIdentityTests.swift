import Foundation
import Testing
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

/// 23.0 · a row's key is decided once (`RowIdentity`) and never changes; a
/// process-only row never "upgrades" into a session — it disappears when a
/// session row for its agent exists. These replace the remap tests: there
/// is nothing left to remap.
@Suite("Row identity")
struct RowIdentityTests {
    let now: Int64 = 1_800_000_000_000
    let minute: Int64 = 60_000

    private var context: SnapshotBuilder.Context {
        SnapshotBuilder.Context(
            nowMs: now,
            terminal: TerminalFocus.Environment(warpRunning: false, ttyHostRunning: false),
            lang: .en
        )
    }

    private func hit(_ id: AgentID, pid: Int = 4242, cwd: String = "") -> ProcessProbe.Hit {
        var value = ProcessProbe.Hit(id: id, count: 1, viaWarp: false, pid: pid, tty: "ttys004")
        value.cwd = cwd
        return value
    }

    private func session(
        _ id: AgentID,
        _ sessionID: String,
        task: String = "Fix the login test",
        cwd: String = "/w/app",
        ageMs: Int64 = 30_000
    ) -> ActivityHarvest.Row {
        ActivityHarvest.Row(
            id: id, task: task, project: "", cwd: cwd, skill: "",
            harvestMs: now - ageMs, sessionID: sessionID, evidence: .session
        )
    }

    private func attention(
        _ id: AgentID, kind: String = "Permission", session: String = "", cwd: String = "", ageMs: Int64 = 5_000
    ) -> AttentionReader.Entry {
        AttentionReader.Entry(id: id, kind: kind, message: "Bash: npm test", tsMs: now - ageMs, session: session, cwd: cwd)
    }

    private func build(
        procs: [ProcessProbe.Hit] = [],
        harvest: [ActivityHarvest.Row] = [],
        attention: [AttentionReader.Entry] = [],
        previous: SnapshotBuilder.Previous = .init(),
        at nowMs: Int64? = nil
    ) -> SnapshotBuilder.Result {
        var ctx = context
        if let nowMs { ctx.nowMs = nowMs }
        return SnapshotBuilder.build(
            SnapshotBuilder.Input(procs: procs, harvest: harvest, attention: attention),
            previous: previous,
            context: ctx
        )
    }

    // MARK: - The keys

    @Test func eachKindOfRowHasItsOwnKey() {
        #expect(RowIdentity.session(agent: .claude, sessionID: "abc") == "claude|abc")
        #expect(RowIdentity.process(agent: .codex, pid: 7) == "codex|pid:7")
        #expect(RowIdentity.hook(agent: .claude, session: "abc", cwd: "/w") == "claude|abc",
                "a hook naming a session takes that session's key")
        let byFile = RowIdentity.session(agent: .gemini, sessionID: "", transcriptPath: "/Users/me/.gemini/chat.json")
        #expect(byFile.hasPrefix("gemini|file:"))
        #expect(!byFile.contains("/Users/me"), "a key never carries a path")
        #expect(RowIdentity.isProcessKey("codex|pid:7"))
        #expect(!RowIdentity.isProcessKey("codex|abc"))
    }

    @Test func theHashIsStableAcrossLaunches() {
        #expect(RowIdentity.stableHash("pulse") == "b3f797f2")
        #expect(RowIdentity.stableHash("c:/w/Repo/api") != RowIdentity.stableHash("c:/w/Repo/docs"))
    }

    @Test func cursorAgentSessionsAreKeyedAsCursor() {
        #expect(RowIdentity.session(agent: .cursorAgent, sessionID: "s") == "cursor|s")
    }

    // MARK: - (a) a process and a session of the same agent are one row

    @Test func aProcessAndASessionForTheSameAgentAndFolderAreOneRow() throws {
        let r = build(procs: [hit(.claude, cwd: "/w/app")], harvest: [session(.claude, "s1")])
        #expect(r.rows.count == 1)
        let row = try #require(r.rows.first)
        #expect(row.rowKey == "claude|s1", "the session row, never the process row")
        #expect(row.liveProcess)
        #expect(row.pid == 4242)
        #expect(row.state == .running)
    }

    @Test func aProcessAloneIsAnEphemeralProcessOnlyRow() throws {
        let r = build(procs: [hit(.claude, cwd: "/w/app")])
        let row = try #require(r.rows.first)
        #expect(row.rowKey == "claude|pid:4242")
        #expect(row.isProcessOnly)
        #expect(row.source == .process)
    }

    @Test func whenTheSessionAppearsTheProcessRowSimplyGoes() throws {
        let first = build(procs: [hit(.claude, cwd: "/w/app")])
        let second = build(
            procs: [hit(.claude, cwd: "/w/app")], harvest: [session(.claude, "s1")],
            previous: .init(rows: first.rows, waitingKeys: first.waitingKeys)
        )
        let keys = second.rows.map { $0.rowKey }
        #expect(keys == ["claude|s1"])
    }

    // MARK: - (b) a session row keeps its key as its facts change

    @Test func aSessionRowKeepsItsKeyAcrossScansAsFactsChange() throws {
        let a = build(harvest: [session(.claude, "s1", task: "First title", ageMs: 60_000)])
        var moved = session(.claude, "s1", task: "Renamed by the vendor", cwd: "/w/app/sub", ageMs: 1_000)
        moved.lastWord = "Done with step one."
        moved.errors = 2
        let b = build(procs: [hit(.claude)], harvest: [moved], previous: .init(rows: a.rows, waitingKeys: a.waitingKeys))
        let c = build(
            procs: [hit(.claude)], harvest: [moved], attention: [attention(.claude, session: "s1")],
            previous: .init(rows: b.rows, waitingKeys: b.waitingKeys)
        )
        let keyA = try #require(a.rows.first?.rowKey)
        let keyB = try #require(b.rows.first?.rowKey)
        let rowC = try #require(c.rows.first)
        #expect(keyA == "claude|s1")
        #expect(keyB == keyA)
        #expect(rowC.rowKey == keyA)
        #expect(rowC.isBlocked)
        let edges = c.newlyWaiting.map { $0.rowKey }
        #expect(edges == ["claude|s1"])
    }

    @Test func aHookWaitBeforeTheTranscriptKeepsItsKeyWhenTheTranscriptAppears() throws {
        let wait = attention(.claude, session: "s9", cwd: "/w/app")
        let first = build(procs: [hit(.claude)], attention: [wait])
        let hookRow = try #require(first.rows.first)
        #expect(hookRow.rowKey == "claude|s9")
        #expect(hookRow.source == .hooks)
        #expect(hookRow.liveProcess, "the process attaches to the hook row; no process-only twin")
        #expect(first.rows.count == 1)

        let second = build(
            procs: [hit(.claude)], harvest: [session(.claude, "s9")], attention: [wait],
            previous: .init(rows: first.rows, waitingKeys: first.waitingKeys)
        )
        let row = try #require(second.rows.first)
        #expect(second.rows.count == 1)
        #expect(row.rowKey == "claude|s9")
        #expect(row.source == .session)
        #expect(second.newlyWaiting.isEmpty, "the same wait under the same key is not a second edge")
        #expect(second.resolvedWaits.isEmpty)
    }

    // MARK: - (c) attention by folder attaches to the right session row

    @Test func attentionByFolderAttachesToTheSessionInThatFolder() throws {
        var api = session(.codex, "", task: "API work", cwd: "/w/api")
        api.startedMs = now - 30 * minute
        var docs = session(.codex, "", task: "Docs work", cwd: "/w/docs")
        docs.startedMs = now - 20 * minute
        let r = build(harvest: [api, docs], attention: [attention(.codex, cwd: "/w/docs")])
        #expect(r.rows.count == 2)
        let blocked = r.rows.filter { $0.isBlocked }
        let row = try #require(blocked.first)
        #expect(blocked.count == 1)
        #expect(row.task == "Docs work")
        #expect(row.rowKey == docs.rowKey)
    }

    @Test func aHookNamingAnotherSessionNeverLandsOnASiblingByFolder() throws {
        let r = build(
            harvest: [session(.claude, "s1", cwd: "/w/app")],
            attention: [attention(.claude, session: "s2", cwd: "/w/app")]
        )
        #expect(r.rows.count == 2)
        let sibling = try #require(r.rows.first { $0.rowKey == "claude|s1" })
        #expect(!sibling.isBlocked)
        let hook = try #require(r.rows.first { $0.rowKey == "claude|s2" })
        #expect(hook.isBlocked)
    }

    @Test func aHookWaitNeverLandsOnAProcessOnlyRow() throws {
        let r = build(procs: [hit(.codex, cwd: "/w/app")], attention: [attention(.codex, cwd: "/w/app")])
        #expect(r.rows.count == 1, "the process attaches to the hook row instead")
        let row = try #require(r.rows.first)
        #expect(row.isBlocked)
        #expect(!RowIdentity.isProcessKey(row.rowKey))
        #expect(row.rowKey.hasPrefix("codex|hook:"))
    }

    @Test func aTurnWithNoSessionRowMakesNoRow() {
        let r = build(attention: [attention(.claude, kind: "Turn", session: "s1")])
        #expect(r.rows.isEmpty)
    }
}
