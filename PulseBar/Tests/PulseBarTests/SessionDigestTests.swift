import Darwin
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

    // MARK: - Growth rate: moving, or merely touched

    /// 2.1: mtime answers "was this touched" and nothing else. Two agents,
    /// one taking on 60 KB a minute and one that appended a line an hour ago,
    /// look identical to it. A rate separates them.
    private func rated(previousSize: Int, size: Int, gapMs: Int64) -> SessionDigest {
        var digest = SessionDigest(path: "/tmp/t.jsonl")
        digest.previousSize = previousSize
        digest.size = size
        digest.previousFoldedMs = now
        digest.lastFoldedMs = now + gapMs
        return digest
    }

    func testGrowthRateIsBytesPerMinuteBetweenTwoFolds() {
        XCTAssertEqual(rated(previousSize: 1_000, size: 61_000, gapMs: 60_000).bytesPerMinute, 60_000)
        XCTAssertEqual(rated(previousSize: 0, size: 30_000, gapMs: 120_000).bytesPerMinute, 15_000)
        XCTAssertEqual(rated(previousSize: 20_000, size: 20_000, gapMs: 60_000).bytesPerMinute, 0,
                       "a file that did not grow has no growth rate")
    }

    /// The failure this bound exists to prevent: two folds 40 ms apart turn
    /// 4 KB into megabytes per minute — a number about the scan cadence, not
    /// about the session.
    func testTooShortAGapIsRefusedRatherThanExtrapolated() {
        XCTAssertEqual(rated(previousSize: 0, size: 4_096, gapMs: 40).bytesPerMinute, 0)
        XCTAssertEqual(
            rated(previousSize: 0, size: 4_096, gapMs: SessionDigest.minRateWindowMs - 1).bytesPerMinute,
            0
        )
        XCTAssertEqual(
            rated(previousSize: 0, size: 4_096, gapMs: SessionDigest.minRateWindowMs).bytesPerMinute,
            49_152,
            "at the boundary it answers, and the answer is arithmetic"
        )
    }

    /// Compaction is routine, and a file that shrank has not grown by a
    /// negative amount — it has stopped being measurable.
    func testACompactedFileReportsNoRate() {
        XCTAssertEqual(rated(previousSize: 900_000, size: 12_000, gapMs: 60_000).bytesPerMinute, 0)
    }

    func testOneFoldIsOnePointAndCannotBeARate() {
        var digest = SessionDigest(path: "/tmp/t.jsonl")
        digest.size = 50_000
        digest.lastFoldedMs = now
        XCTAssertEqual(digest.bytesPerMinute, 0, "0 means not known, never means stopped")
    }

    /// A backwards clock or a single huge write must not produce a headline
    /// figure — and must not trap on the Double→Int conversion either.
    func testTheReportedRateIsClamped() {
        let absurd = rated(
            previousSize: 0, size: Int.max / 2, gapMs: SessionDigest.minRateWindowMs
        )
        XCTAssertEqual(absurd.bytesPerMinute, SessionDigest.maxBytesPerMinute)
    }

    /// End to end, against a file that really grows: the previous pass's
    /// numbers are stored *before* the new ones overwrite them, and only on a
    /// pass that actually folded bytes.
    func testGrowthRateComesFromTwoFoldsOfARealFile() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        // Padded so the first write is already past the 4 KB head hash: below
        // that, growing the file also changes its head, which is a rewrite as
        // far as continuity is concerned.
        let line = #"{"type":"tool_use","name":"Bash","pad":"\#(String(repeating: "x", count: 256))"}"#
        // Appended, never rewritten: `write(atomically:)` renames a fresh file
        // into place, which is a new inode — continuity would call that a
        // rewritten transcript and correctly start over, testing nothing.
        try append(Array(repeating: line, count: 30), to: url)
        let firstSize = try fileSize(url)

        let first = try XCTUnwrap(
            SessionDigestEngine.advance(nil, url: url, size: firstSize, nowMs: now)
        )
        XCTAssertEqual(first.previousFoldedMs, 0, "the first fold has nothing to compare against")
        XCTAssertEqual(first.bytesPerMinute, 0)

        try append(Array(repeating: line, count: 40), to: url)
        let secondSize = try fileSize(url)
        XCTAssertGreaterThan(secondSize, firstSize)

        let second = try XCTUnwrap(
            SessionDigestEngine.advance(first, url: url, size: secondSize, nowMs: now + 60_000)
        )
        XCTAssertEqual(second.previousSize, firstSize)
        XCTAssertEqual(second.previousFoldedMs, now)
        XCTAssertEqual(second.bytesPerMinute, secondSize - firstSize, "one minute of growth")

        // Nothing new: no fold, so the measured window is not stretched.
        XCTAssertNil(
            SessionDigestEngine.advance(second, url: url, size: secondSize, nowMs: now + 600_000)
        )
    }

    private func fileSize(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    /// Extend the same file in place, the way a vendor extends a transcript.
    private func append(_ lines: [String], to url: URL) throws {
        let text = lines.joined(separator: "\n") + "\n"
        guard FileManager.default.fileExists(atPath: url.path) else {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    // MARK: - What is kept on disk

    /// Swift's synthesized decoder throws on a missing key even when the
    /// property has a default, and `load()` turns a throw into an empty
    /// store. Without a tolerant decoder, adding `previousSize` would have
    /// silently discarded every digest on disk and re-read every transcript
    /// from byte zero — a regression nothing in the UI would show.
    func testADigestWrittenBeforeGrowthRateExistedStillDecodes() throws {
        let json = """
        {"path":"/tmp/old.jsonl","fileID":"1.2","headHash":"abc","offset":120,
         "size":120,"records":9,"toolCounts":{"Bash":3},"recentTools":["Bash"],
         "errors":1,"tokensIn":40,"tokensOut":8,
         "firstFoldedMs":1700000000000,"lastFoldedMs":1700000060000}
        """
        let digest = try JSONDecoder().decode(SessionDigest.self, from: Data(json.utf8))
        XCTAssertEqual(digest.records, 9)
        XCTAssertEqual(digest.toolCounts["Bash"], 3)
        XCTAssertTrue(digest.caughtUp)
        XCTAssertEqual(digest.previousSize, 0)
        XCTAssertEqual(digest.previousFoldedMs, 0)
        XCTAssertEqual(digest.bytesPerMinute, 0, "unknown, not invented")
    }

    /// The same file one level up: a store from an older build keeps all of
    /// its entries rather than being thrown away whole.
    func testAnOlderStoreFileIsKeptRatherThanDiscarded() throws {
        let json = """
        {"entries":{"/tmp/a.jsonl":{"path":"/tmp/a.jsonl","offset":10,"size":10,"records":2},
                    "/tmp/b.jsonl":{"path":"/tmp/b.jsonl"}}}
        """
        let store = try JSONDecoder().decode(SessionDigestStore.self, from: Data(json.utf8))
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.entries["/tmp/a.jsonl"]?.records, 2)
        XCTAssertEqual(store.entries["/tmp/b.jsonl"]?.records, 0)
    }

    func testTheNewFieldsSurviveARoundTrip() throws {
        var digest = SessionDigest(path: "/tmp/t.jsonl")
        digest.size = 90_000
        digest.previousSize = 30_000
        digest.previousFoldedMs = now
        digest.lastFoldedMs = now + 60_000
        digest.recentTools = ["Bash", "Edit"]
        let data = try JSONEncoder().encode(digest)
        let decoded = try JSONDecoder().decode(SessionDigest.self, from: data)
        XCTAssertEqual(decoded, digest)
        XCTAssertEqual(decoded.bytesPerMinute, 60_000)
    }

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

    // MARK: - 2.2 · the last block is not exempt from the half-record rule

    /// Regression (B-10 / `H-M4`): the comment promised "Never fold a half
    /// written record" and the code exempted the last block from it.
    ///
    /// `size` is stat'd before the read. A writer that splits one long record
    /// across two `write` calls leaves the file ending mid-record at exactly
    /// that size, so the fold "reached the end of the file" and swallowed the
    /// fragment: the front half counted as one record now, the back half as
    /// another record next pass. `records` is reported as an exact number, so
    /// this was a wrong number that never corrected itself.
    func testTheClaimedEndOfAFileIsNotProofItsTailIsWhole() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let whole = #"{"type":"user"}"# + "\n" + #"{"type":"assistant"}"# + "\n"
        let halfRecord = #"{"type":"tool_use","na"#
        try (whole + halfRecord).write(to: url, atomically: true, encoding: .utf8)

        // What the caller measured a moment ago, before the writer appended
        // the last few bytes. `advance` reads exactly that much and therefore
        // believes it is standing at the end of the file.
        let staleSize = whole.utf8.count + halfRecord.utf8.count - 4
        let digest = try XCTUnwrap(
            SessionDigestEngine.advance(nil, url: url, size: staleSize, nowMs: now)
        )
        XCTAssertEqual(digest.records, 2, "the half record waits for its other half")
        XCTAssertEqual(digest.offset, whole.utf8.count, "stop at the last newline")
        XCTAssertFalse(digest.caughtUp, "and say so, rather than claim a total")
    }

    /// The exception the rule keeps, because it can be proved rather than
    /// assumed: a transcript whose final record carries no trailing newline is
    /// complete when the descriptor says the file has not moved since the
    /// caller measured it.
    func testAFinalRecordWithoutANewlineIsFoldedWhenTheFileHasStoppedMoving() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let text = #"{"type":"user"}"# + "\n" + #"{"type":"assistant"}"#
        try text.write(to: url, atomically: true, encoding: .utf8)

        let digest = try XCTUnwrap(
            SessionDigestEngine.advance(nil, url: url, size: text.utf8.count, nowMs: now)
        )
        XCTAssertEqual(digest.records, 2, "nothing was appended while this ran")
        XCTAssertTrue(digest.caughtUp)
    }

    /// The descriptor check narrows the race; it does not close it. A writer
    /// that finished its first `write` before the caller stat'd and its second
    /// after the descriptor was asked leaves a file that has *not* moved and a
    /// tail that is still half a record. Only the shape of the tail can tell
    /// those apart.
    func testATornRecordIsNotCountedEvenWhenTheFileHasStoppedMoving() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let whole = #"{"type":"user"}"# + "\n"
        let torn = #"{"type":"tool_use","na"#
        try (whole + torn).write(to: url, atomically: true, encoding: .utf8)

        // Truthful size, settled file — and still not a record.
        let digest = try XCTUnwrap(
            SessionDigestEngine.advance(
                nil, url: url, size: whole.utf8.count + torn.utf8.count, nowMs: now
            )
        )
        XCTAssertEqual(digest.records, 1, "half a JSON record is not a record")
        XCTAssertEqual(digest.offset, whole.utf8.count)
        XCTAssertFalse(digest.caughtUp, "not caught up beats a count that is one too high")
    }

    /// A transcript that was never JSON has no shape to check. Refusing its
    /// last line would leave it permanently short of caught up over a
    /// distinction nothing on disk can settle.
    func testAPlainTextTailIsStillTakenAtFaceValue() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let text = "started the run\nstill going"
        try text.write(to: url, atomically: true, encoding: .utf8)

        let digest = try XCTUnwrap(
            SessionDigestEngine.advance(nil, url: url, size: text.utf8.count, nowMs: now)
        )
        XCTAssertEqual(digest.records, 2)
        XCTAssertTrue(digest.caughtUp)
    }

    func testWholenessIsJudgedOnlyForWhatClaimedToBeARecord() {
        XCTAssertTrue(SessionDigestFold.isWholeRecord(Array(#"{"a":1}"#.utf8)))
        XCTAssertTrue(SessionDigestFold.isWholeRecord(Array(#"[1,2]"#.utf8)))
        XCTAssertFalse(SessionDigestFold.isWholeRecord(Array(#"{"a":1"#.utf8)))
        XCTAssertFalse(SessionDigestFold.isWholeRecord(Array(#"{"#.utf8)))
        XCTAssertTrue(SessionDigestFold.isWholeRecord(Array("plain text".utf8)))
        XCTAssertTrue(SessionDigestFold.isWholeRecord(Array("".utf8)), "nothing to disbelieve")
        XCTAssertTrue(
            SessionDigestFold.isWholeRecord(Array(("  " + #"{"a":1}"# + "  ").utf8)),
            "surrounding whitespace is not a tear"
        )
    }

    // MARK: - 2.2 · private before it exists, not private afterwards

    /// Regression (B-13): the store wrote with `write(to:.atomic)` and only
    /// then chmod'd to 0600. The temporary file that atomic write creates
    /// takes the process umask — 0644 on a stock Mac — so the digest was
    /// readable by every other local account for the whole write and rename.
    ///
    /// The final mode alone cannot tell the two implementations apart, which
    /// is why the store hands the temporary file's path to a test seam: the
    /// assertion is about the mode the bytes were *born* with.
    func testTheDigestIsPrivateBeforeItsBytesExist() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-digest-perm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session-digests.json")

        // The condition the old code lost under: nothing masked off for it.
        let previousMask = umask(0)
        defer { umask(previousMask) }

        var temporaryModes: [Int] = []
        SessionDigestStore.inspectTemporaryFileForTesting = { path in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            temporaryModes.append((attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1)
        }
        SessionDigestStore.pathOverride = url
        defer {
            SessionDigestStore.inspectTemporaryFileForTesting = nil
            SessionDigestStore.pathOverride = nil
        }

        var store = SessionDigestStore()
        var entry = SessionDigest(path: "/tmp/private.jsonl")
        entry.records = 3
        entry.lastFoldedMs = now
        store.entries["/tmp/private.jsonl"] = entry
        store.save()

        XCTAssertEqual(temporaryModes, [0o600], "0600 at creation, not after the bytes are visible")
        let published = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((published[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path),
            ["session-digests.json"],
            "the temporary file is renamed into place, never left behind"
        )
        XCTAssertEqual(SessionDigestStore.load().entries["/tmp/private.jsonl"]?.records, 3)
    }
}
