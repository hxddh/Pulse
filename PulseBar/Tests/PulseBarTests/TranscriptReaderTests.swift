import XCTest
@testable import PulseBar

/// 4.0-α — the transcript the workbench renders is parsed by shape, bounded
/// at every edge, and sanitized per entry. These tests pin each rule with
/// vendor-real line shapes; the file-window behaviour runs against a real
/// temporary file at the bottom.
final class TranscriptReaderTests: XCTestCase {

    private func parse(_ lines: [String], truncatedHead: Bool = false) -> TranscriptReader.Excerpt {
        TranscriptReader.parse(
            data: Data((lines.joined(separator: "\n") + "\n").utf8),
            truncatedHead: truncatedHead
        )
    }

    // MARK: - Claude-family shapes

    func testAClaudeUserTurnAndAssistantReplyComeOutInOrder() {
        let excerpt = parse([
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"fix the bug"}]},"timestamp":"2026-08-26T02:00:01.000Z"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Looking at it."}]}}"#,
        ])
        XCTAssertEqual(excerpt.entries.map(\.kind), [.user, .agent])
        XCTAssertEqual(excerpt.entries[0].text, "fix the bug")
        XCTAssertEqual(excerpt.entries[0].tsMs, 1_787_709_601_000)
        XCTAssertEqual(excerpt.entries[1].text, "Looking at it.")
        XCTAssertEqual(excerpt.unparsedLines, 0)
    }

    func testAPlainStringContentIsStillAMessage() {
        let excerpt = parse([
            #"{"type":"user","message":{"role":"user","content":"just a string"}}"#,
        ])
        XCTAssertEqual(excerpt.entries.first?.text, "just a string")
    }

    func testAToolUseBlockBecomesAToolEntryWithItsTarget() {
        let excerpt = parse([
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/repo/Main.swift"}}]}}"#,
        ])
        XCTAssertEqual(excerpt.entries.count, 1)
        XCTAssertEqual(excerpt.entries[0].kind, .tool)
        XCTAssertEqual(excerpt.entries[0].toolName, "Edit")
        XCTAssertEqual(excerpt.entries[0].text, "/repo/Main.swift")
    }

    func testAFailedToolResultSurvivesEvenWhenSilentSuccessesAreDropped() {
        let excerpt = parse([
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"","is_error":false}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"compile failed","is_error":true}]}}"#,
        ])
        XCTAssertEqual(excerpt.entries.count, 1)
        XCTAssertTrue(excerpt.entries[0].isError)
        XCTAssertEqual(excerpt.entries[0].text, "compile failed")
    }

    func testAToolResultWithBlockContentReadsItsTextBlock() {
        let excerpt = parse([
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":[{"type":"text","text":"3 files changed"}]}]}}"#,
        ])
        XCTAssertEqual(excerpt.entries.first?.text, "3 files changed")
    }

    // MARK: - Codex shapes

    func testCodexEventMessagesMapToBothSpeakers() {
        let excerpt = parse([
            #"{"type":"event_msg","payload":{"type":"user_message","message":"run the tests"}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"They pass."}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","count":512}}"#,
        ])
        XCTAssertEqual(excerpt.entries.map(\.kind), [.user, .agent])
        XCTAssertEqual(excerpt.unparsedLines, 0, "bookkeeping is not an unrecognized line")
    }

    func testACodexResponseItemUnwrapsToItsInnerMessage() {
        let excerpt = parse([
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}}"#,
        ])
        XCTAssertEqual(excerpt.entries.first?.kind, .agent)
        XCTAssertEqual(excerpt.entries.first?.text, "done")
    }

    // MARK: - Generic shape and the honest counters

    func testAGenericRoleContentRecordParses() {
        let excerpt = parse([#"{"role":"user","content":"hello"}"#])
        XCTAssertEqual(excerpt.entries.first?.kind, .user)
    }

    func testANonJSONLineIsCountedNeverGuessedAt() {
        let excerpt = parse([
            "not json at all",
            #"{"role":"user","content":"real"}"#,
        ])
        XCTAssertEqual(excerpt.unparsedLines, 1)
        XCTAssertEqual(excerpt.entries.count, 1)
    }

    func testATornFirstLineIsSkippedInATruncatedWindow() {
        let excerpt = parse([
            #"ext":"the back half of a record"}]}}"#,
            #"{"role":"user","content":"whole"}"#,
        ], truncatedHead: true)
        XCTAssertEqual(excerpt.entries.count, 1)
        XCTAssertEqual(excerpt.entries[0].text, "whole")
        XCTAssertEqual(excerpt.unparsedLines, 0, "the torn half is skipped, not counted against the file")
        XCTAssertTrue(excerpt.truncatedHead)
    }

    func testTheEntryCapKeepsTheNewestAndSaysSo() {
        let lines = (0..<(TranscriptReader.maxEntries + 20)).map {
            #"{"role":"user","content":"m\#($0)"}"#
        }
        let excerpt = parse(lines)
        XCTAssertTrue(excerpt.entriesCapped)
        XCTAssertEqual(excerpt.entries.count, TranscriptReader.maxEntries)
        XCTAssertEqual(excerpt.entries.last?.text, "m\(TranscriptReader.maxEntries + 19)")
        XCTAssertEqual(excerpt.entries.first?.text, "m20", "the oldest fall off the front")
    }

    func testEveryRenderedStringPassesTheSanitizer() {
        let excerpt = parse([
            #"{"role":"assistant","content":"the key is sk-proj-abcdefghijklmnop123456"}"#,
        ])
        let text = excerpt.entries.first?.text ?? ""
        XCTAssertFalse(text.contains("sk-proj-abcdefghijklmnop123456"))
        XCTAssertTrue(text.contains(ContentSanitizer.replacement))
    }

    func testAnOverlongEntryIsBoundedWithAVisibleEllipsis() {
        let long = String(repeating: "a", count: TranscriptReader.maxEntryChars + 500)
        let excerpt = parse([#"{"role":"user","content":"\#(long)"}"#])
        let text = excerpt.entries.first?.text ?? ""
        XCTAssertEqual(text.count, TranscriptReader.maxEntryChars + 1)
        XCTAssertTrue(text.hasSuffix("…"))
    }

    func testANumericSecondsTimestampBecomesMilliseconds() {
        let excerpt = parse([#"{"role":"user","content":"x","timestamp":1787709601}"#])
        XCTAssertEqual(excerpt.entries.first?.tsMs, 1_787_709_601_000)
    }

    // MARK: - The real file window

    func testReadingARealFileReportsItsSizesAndTailTruncation() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-transcript-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        // Enough lines to exceed the tail window, so the head must be cut
        // and the reader must say so.
        let filler = String(repeating: "x", count: 400)
        var lines: [String] = []
        for index in 0..<2000 {
            lines.append(#"{"role":"user","content":"\#(filler) \#(index)"}"#)
        }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        XCTAssertGreaterThan(data.count, TranscriptReader.tailWindowBytes)
        try data.write(to: url)

        let excerpt = try XCTUnwrap(TranscriptReader.read(path: url.path))
        XCTAssertTrue(excerpt.truncatedHead)
        XCTAssertEqual(excerpt.fileBytes, data.count)
        XCTAssertLessThanOrEqual(excerpt.windowBytes, TranscriptReader.tailWindowBytes)
        XCTAssertEqual(excerpt.entries.count, TranscriptReader.maxEntries)
        XCTAssertTrue(excerpt.entries.last?.text.hasSuffix("1999") ?? false,
                      "the tail of the file is the tail of the view")
    }

    func testAMissingFileIsNilNotAnEmptyExcerpt() {
        XCTAssertNil(TranscriptReader.read(path: "/nonexistent/pulse-\(UUID().uuidString).jsonl"))
        XCTAssertNil(TranscriptReader.read(path: ""))
    }

    func testASmallFileIsReadWholeWithNothingCut() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-transcript-small-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"role":"user","content":"only line"}"#.utf8).write(to: url)
        let excerpt = try XCTUnwrap(TranscriptReader.read(path: url.path))
        XCTAssertFalse(excerpt.truncatedHead)
        XCTAssertEqual(excerpt.entries.count, 1)
    }
}
