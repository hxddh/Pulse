import XCTest
@testable import PulseBar

/// 1.1 Full Transcript — reading the part of a session Pulse never saw.
///
/// The collector reads head 64 KB plus a tail of every transcript, from
/// scratch, on every scan. Under a megabyte that is the whole file; over it,
/// the middle is invisible **permanently**, and `records` reports unknown
/// because a truncated window cannot count. Observation quality was therefore
/// worst on exactly the long sessions that most need watching.
final class SessionDigestTests: XCTestCase {

    private let now: Int64 = 1_800_000_000_000

    override func setUp() {
        super.setUp()
        HarvestDigests.resetForTesting()
    }

    private func fold(_ lines: [String], into digest: inout SessionDigest) {
        let text = lines.joined(separator: "\n")
        SessionDigestFold.fold(&digest, lines: text.split(separator: "\n", omittingEmptySubsequences: false), nowMs: now)
    }

    // MARK: - Counting

    func testEveryRecordIsCountedIncludingOnesNoParserUnderstands() {
        var digest = SessionDigest(path: "/tmp/t.jsonl")
        fold([
            #"{"type":"user"}"#,
            #"{"type":"assistant"}"#,
            "not json at all",
            #"{"type":"whatever_the_vendor_adds_next"}"#,
        ], into: &digest)
        XCTAssertEqual(digest.records, 4, "a record Pulse cannot read is still a record")
    }

    func testBlankLinesAreNotRecords() {
        var digest = SessionDigest(path: "/tmp/t.jsonl")
        fold([#"{"type":"user"}"#, "", "   ", #"{"type":"user"}"#], into: &digest)
        XCTAssertEqual(digest.records, 2)
    }

    func testFoldingTwiceContinuesRatherThanRestarts() {
        var digest = SessionDigest(path: "/tmp/t.jsonl")
        fold([#"{"type":"user"}"#], into: &digest)
        fold([#"{"type":"assistant"}"#], into: &digest)
        XCTAssertEqual(digest.records, 2, "the whole point is that earlier bytes are not re-read")
    }

    // MARK: - Tools, errors, tokens

    func testToolNamesAndCountsSurviveTheWholeFile() {
        var digest = SessionDigest(path: "/tmp/t.jsonl")
        fold([
            #"{"type":"tool_use","name":"Bash"}"#,
            #"{"type":"tool_use","name":"Edit"}"#,
            #"{"type":"tool_use","name":"Bash"}"#,
            #"{"message":{"content":[{"type":"tool_use","name":"Read"}]}}"#,
        ], into: &digest)
        XCTAssertEqual(digest.toolCounts["Bash"], 2)
        XCTAssertEqual(digest.toolCounts["Edit"], 1)
        XCTAssertEqual(digest.toolCounts["Read"], 1, "nested tool records count too")
        XCTAssertEqual(digest.recentTools, ["Bash", "Edit", "Bash", "Read"])
    }

    /// The tool's name is a vendor token. What it was about to run is the
    /// user's business and must not reach disk.
    func testOnlyIdentifierShapedToolNamesAreStored() {
        XCTAssertEqual(SessionDigestFold.sanitizedToolName("Bash"), "Bash")
        XCTAssertEqual(SessionDigestFold.sanitizedToolName("mcp__github__get"), "mcp__github__get")
        XCTAssertNil(SessionDigestFold.sanitizedToolName("rm -rf /Users/me/secret"))
        XCTAssertNil(SessionDigestFold.sanitizedToolName(String(repeating: "x", count: 40)))
        XCTAssertNil(SessionDigestFold.sanitizedToolName(""))
    }

    func testAFreeTextNameIsNotMistakenForATool() {
        var digest = SessionDigest(path: "/tmp/t.jsonl")
        fold([#"{"type":"tool_use","name":"please delete /etc/hosts"}"#], into: &digest)
        XCTAssertTrue(digest.toolCounts.isEmpty)
        XCTAssertEqual(digest.records, 1, "still a record, just not a tool")
    }

    func testErrorsAndTokensAccumulateAcrossTheFile() {
        var digest = SessionDigest(path: "/tmp/t.jsonl")
        fold([
            #"{"type":"tool_result","is_error":true}"#,
            #"{"type":"error"}"#,
            #"{"message":{"usage":{"input_tokens":100,"output_tokens":20}}}"#,
            #"{"message":{"usage":{"input_tokens":50,"output_tokens":5}}}"#,
        ], into: &digest)
        XCTAssertEqual(digest.errors, 2)
        XCTAssertEqual(digest.tokensIn, 150)
        XCTAssertEqual(digest.tokensOut, 25)
    }

    func testStoredToolNamesAreBounded() {
        var digest = SessionDigest(path: "/tmp/t.jsonl")
        let lines = (0..<(SessionDigest.maxToolNames + 40)).map {
            #"{"type":"tool_use","name":"Tool\#($0)"}"#
        }
        fold(lines, into: &digest)
        XCTAssertLessThanOrEqual(digest.toolCounts.count, SessionDigest.maxToolNames)
        XCTAssertLessThanOrEqual(digest.recentTools.count, SessionDigest.maxRecentTools)
    }

    /// The fact a window can never produce: an agent going round in circles.
    func testARepeatedToolIsVisible() throws {
        var digest = SessionDigest(path: "/tmp/t.jsonl")
        fold(Array(repeating: #"{"type":"tool_use","name":"Edit"}"#, count: 4), into: &digest)
        let repeated = try XCTUnwrap(digest.repeatedTool)
        XCTAssertEqual(repeated.name, "Edit")
        XCTAssertEqual(repeated.count, 4)
    }

    func testAlternatingToolsAreNotALoop() {
        var digest = SessionDigest(path: "/tmp/t.jsonl")
        fold([
            #"{"type":"tool_use","name":"Edit"}"#,
            #"{"type":"tool_use","name":"Bash"}"#,
            #"{"type":"tool_use","name":"Edit"}"#,
            #"{"type":"tool_use","name":"Bash"}"#,
        ], into: &digest)
        XCTAssertNil(digest.repeatedTool)
    }

    // MARK: - Continuity: compaction is routine, not an error

    func testAGrowingFileIsContinued() {
        var digest = SessionDigest(path: "/tmp/t.jsonl")
        digest.offset = 100
        digest.records = 4
        digest.headHash = "abc"
        digest.fileID = "1.2"
        XCTAssertEqual(
            SessionDigestFold.continuity(digest, size: 300, headHash: "abc", fileID: "1.2"),
            .appended
        )
    }

    func testAShrunkFileStartsOver() {
        var digest = SessionDigest(path: "/tmp/t.jsonl")
        digest.offset = 900
        digest.records = 40
        XCTAssertEqual(
            SessionDigestFold.continuity(digest, size: 100, headHash: "abc", fileID: ""),
            .rewritten,
            "Claude compacts and Pi keeps a retained tail — normal, not a failure"
        )
    }

    /// The case no offset or size check would catch.
    func testAFileRewrittenInPlaceAtTheSameSizeStartsOver() {
        var digest = SessionDigest(path: "/tmp/t.jsonl")
        digest.offset = 200
        digest.records = 9
        digest.headHash = "old"
        XCTAssertEqual(
            SessionDigestFold.continuity(digest, size: 200, headHash: "new", fileID: ""),
            .rewritten
        )
    }

    func testARecycledPathIsNotTheSameFile() {
        var digest = SessionDigest(path: "/tmp/t.jsonl")
        digest.offset = 200
        digest.records = 9
        digest.fileID = "1.55"
        digest.headHash = "same"
        XCTAssertEqual(
            SessionDigestFold.continuity(digest, size: 400, headHash: "same", fileID: "1.99"),
            .rewritten
        )
    }

    func testNothingNewIsNothingToDo() {
        var digest = SessionDigest(path: "/tmp/t.jsonl")
        digest.offset = 300
        digest.records = 12
        digest.headHash = "abc"
        XCTAssertEqual(
            SessionDigestFold.continuity(digest, size: 300, headHash: "abc", fileID: ""),
            .unchanged
        )
    }

    // MARK: - Reading a real file, in pieces

    private func write(_ lines: [String], to url: URL) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-digest-\(UUID().uuidString).jsonl")
    }

    /// The invariant the whole design rests on: reading a file in slices must
    /// produce exactly what reading it in one go produces.
    func testCatchingUpInSlicesEqualsReadingItAtOnce() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = (0..<400).map { #"{"type":"tool_use","name":"Bash","i":\#($0)}"# }
        try write(lines, to: url)
        let size = Int((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
        XCTAssertGreaterThan(size, 0)

        var sliced: SessionDigest?
        var passes = 0
        while passes < 200 {
            passes += 1
            guard let next = SessionDigestEngine.advance(
                sliced, url: url, size: size, nowMs: now, maxBytes: 700
            ) else { break }
            sliced = next
            if next.caughtUp { break }
        }
        let whole = try XCTUnwrap(
            SessionDigestEngine.advance(nil, url: url, size: size, nowMs: now, maxBytes: 50_000_000)
        )
        let partial = try XCTUnwrap(sliced)
        XCTAssertTrue(partial.caughtUp)
        XCTAssertEqual(partial.records, whole.records)
        XCTAssertEqual(partial.records, lines.count)
        XCTAssertEqual(partial.toolCounts, whole.toolCounts)
        XCTAssertEqual(partial.offset, whole.offset)
    }

    /// A transcript is appended to while Pulse reads it. Counting a half
    /// written record would put a wrong number on a row that never corrects.
    func testAPartialTrailingRecordIsNotCounted() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let complete = #"{"type":"user"}"# + "\n" + #"{"type":"assistant"}"# + "\n"
        let partial = #"{"type":"tool_use","na"#
        try (complete + partial).write(to: url, atomically: true, encoding: .utf8)
        let full = complete.utf8.count + partial.utf8.count

        // Claim the file is still growing, so the tail is not treated as final.
        let digest = try XCTUnwrap(
            SessionDigestEngine.advance(nil, url: url, size: full + 50, nowMs: now)
        )
        XCTAssertEqual(digest.records, 2)
        XCTAssertEqual(digest.offset, complete.utf8.count, "stop at the last newline")
        XCTAssertFalse(digest.caughtUp)
    }

    func testProgressIsHonestWhileCatchingUp() {
        var digest = SessionDigest(path: "/tmp/t.jsonl")
        digest.size = 1000
        digest.offset = 250
        XCTAssertEqual(digest.progressPercent, 25)
        XCTAssertFalse(digest.caughtUp)
        digest.offset = 1000
        XCTAssertTrue(digest.caughtUp)
        XCTAssertEqual(digest.progressPercent, 100)
    }

    // MARK: - What is kept on disk

    func testStaleDigestsArePrunedAndTheStoreIsBounded() {
        var store = SessionDigestStore()
        let day: Int64 = 24 * 60 * 60 * 1000
        var fresh = SessionDigest(path: "/tmp/fresh.jsonl")
        fresh.lastFoldedMs = now - day
        var stale = SessionDigest(path: "/tmp/stale.jsonl")
        stale.lastFoldedMs = now - Int64(SessionDigestStore.retentionDays) * day - 1
        store.entries = ["fresh": fresh, "stale": stale]
        store.prune(nowMs: now)
        XCTAssertEqual(Array(store.entries.keys), ["fresh"])

        for index in 0..<(SessionDigestStore.maxEntries + 30) {
            var entry = SessionDigest(path: "/tmp/\(index).jsonl")
            entry.lastFoldedMs = now - Int64(index)
            store.entries["k\(index)"] = entry
        }
        store.prune(nowMs: now)
        XCTAssertLessThanOrEqual(store.entries.count, SessionDigestStore.maxEntries)
    }

    func testTheSupportSummarySaysNothingWhenThereIsNothing() {
        XCTAssertEqual(HarvestDigests.summary, "none")
    }
}
