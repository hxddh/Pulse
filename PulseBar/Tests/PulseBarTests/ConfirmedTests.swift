import XCTest
@testable import PulseBar

/// 2.5 Confirmed — the verdict's fate stops being a statement about Pulse.
///
/// Until now a decided row said "verdict written", which is true of three
/// completely different outcomes: the agent took it, nobody took it in time,
/// or it was taken and the vendor ignored it. The first two are separable
/// from a file fact, because `claimVerdict` collects a verdict by renaming it
/// to `<id>.json.used` **before** reading it. The third needs evidence this
/// project does not have yet, and is deliberately not guessed at.
final class ConfirmedTests: XCTestCase {

    private let now: Int64 = 1_800_000_000_000
    private var base: URL!
    private var root: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-confirmed-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("respond.d", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        RespondSpool.rootOverride = root
    }

    override func tearDownWithError() throws {
        RespondSpool.rootOverride = nil
        try? FileManager.default.removeItem(at: base)
    }

    private func verdictsDirectory() throws -> URL {
        let url = root.appendingPathComponent("verdicts", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func writeVerdictFile(id: String, expiresAtMs: Int64) throws -> URL {
        let url = try verdictsDirectory().appendingPathComponent("\(id).json")
        let object: [String: Any] = [
            "v": 1, "request_id": id, "digest": "d", "agent": "claude", "host": "thismac",
            "allow": false, "decided_at_ms": now, "expires_at_ms": expiresAtMs, "hmac": "00",
        ]
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        return url
    }

    // MARK: - The fate is read, never inferred

    func testAVerdictNobodyHasTakenYetIsWaiting() throws {
        try writeVerdictFile(id: "toolu_a", expiresAtMs: now + 60_000)
        XCTAssertEqual(
            RespondSpool.localVerdictFate(requestID: "toolu_a", nowMs: now),
            .waiting
        )
    }

    func testTheClaimRenameIsTheReceipt() throws {
        let url = try writeVerdictFile(id: "toolu_b", expiresAtMs: now + 60_000)
        // Exactly what claimVerdict does before it reads a single byte.
        try FileManager.default.moveItem(
            at: url,
            to: url.deletingLastPathComponent().appendingPathComponent("toolu_b.json.used")
        )
        XCTAssertEqual(
            RespondSpool.localVerdictFate(requestID: "toolu_b", nowMs: now),
            .taken,
            "the agent took it — this is the fact the row exists to report"
        )
    }

    func testAVerdictPastItsDeadlineIsExpiredNotWaiting() throws {
        try writeVerdictFile(id: "toolu_c", expiresAtMs: now - 1)
        XCTAssertEqual(
            RespondSpool.localVerdictFate(requestID: "toolu_c", nowMs: now),
            .expired,
            "nobody came for it, so the vendor's own prompt already happened"
        )
    }

    func testNothingOnDiskIsUnknownNotTaken() {
        XCTAssertEqual(
            RespondSpool.localVerdictFate(requestID: "toolu_missing", nowMs: now),
            .unknown,
            "an absent file is not a receipt"
        )
    }

    func testAFreshVerdictOutranksAnOlderUsedRemnant() throws {
        // `.used` remnants live for an hour, so a second request that reuses
        // an id would otherwise read as already taken before anyone touched it.
        let directory = try verdictsDirectory()
        try Data("{}".utf8).write(to: directory.appendingPathComponent("toolu_d.json.used"))
        try writeVerdictFile(id: "toolu_d", expiresAtMs: now + 60_000)
        XCTAssertEqual(
            RespondSpool.localVerdictFate(requestID: "toolu_d", nowMs: now),
            .waiting
        )
    }

    func testAnUnparseableVerdictIsWaitingRatherThanExpired() throws {
        let directory = try verdictsDirectory()
        try Data("not json".utf8).write(to: directory.appendingPathComponent("toolu_e.json"))
        XCTAssertEqual(
            RespondSpool.localVerdictFate(requestID: "toolu_e", nowMs: now),
            .waiting,
            "a file we cannot date has not been shown to be late"
        )
    }

    // MARK: - What the row is allowed to say

    @MainActor
    private func store() -> StatusStore {
        let store = StatusStore()
        store.language = .en
        return store
    }

    private func row(_ key: String = "claude|s1") -> AgentRow {
        var row = AgentRow(rowKey: key, agent: .claude)
        row.waiting = true
        return row
    }

    @MainActor
    func testARowWithNoVerdictSaysNothing() {
        XCTAssertNil(store().respondFateNote(row()))
    }

    @MainActor
    func testALocalVerdictReportsEachFateInWords() {
        let s = store()
        let subject = row()
        for (fate, key) in [
            (RespondSpool.VerdictFate.waiting, L10n.Key.respondWaitingNote),
            (.taken, .respondTakenNote),
            (.expired, .respondExpiredUnclaimedNote),
        ] {
            s.respondDecided[subject.rowKey] = StatusStore.DecidedVerdict(
                requestID: "toolu_a", isLocal: true, decidedAtMs: now, allow: false, fate: fate
            )
            XCTAssertEqual(s.respondFateNote(subject), s.tr(key), "\(fate)")
        }
    }

    /// The rule this version is built on, applied to itself: a remote
    /// verdict's claim happens on the other machine, and whether the rename
    /// ever comes back depends on a sync tool Pulse does not control. So the
    /// remote row keeps saying the one thing that is true of it.
    @MainActor
    func testARemoteVerdictNeverClaimsToKnowItWasTaken() {
        let s = store()
        let subject = row()
        s.respondDecided[subject.rowKey] = StatusStore.DecidedVerdict(
            requestID: "toolu_a", isLocal: false, decidedAtMs: now, allow: false, fate: .waiting
        )
        XCTAssertEqual(s.respondFateNote(subject), s.tr(.respondSentNote))
    }

    @MainActor
    func testEveryFateSentenceIsRealCopyInBothLanguages() {
        for key in [
            L10n.Key.respondWaitingNote, .respondTakenNote, .respondExpiredUnclaimedNote,
        ] {
            XCTAssertFalse(L10n.t(key, .en).isEmpty, "\(key)")
            XCTAssertFalse(L10n.t(key, .zh).isEmpty, "\(key)")
            XCTAssertNotEqual(L10n.t(key, .en), L10n.t(key, .zh), "\(key)")
        }
    }
}
