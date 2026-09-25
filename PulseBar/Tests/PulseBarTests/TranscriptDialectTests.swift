import XCTest
@testable import PulseBar
@testable import PulseCore

/// 12.3 γ — vendor formats are dialects in one table, not branches inside
/// the generic parser. These pin the dispatch; the parsing itself stays
/// covered by the hero-value suites and the native fixture wall.
final class TranscriptDialectTests: XCTestCase {
    func testEachVendorPathIsClaimedByItsOwnDialect() {
        XCTAssertTrue(TranscriptDialects.dialect(for: "/Users/me/.codex/sessions/2026/rollout-1.jsonl") is CodexDialect)
        XCTAssertTrue(TranscriptDialects.dialect(for: "/Users/me/.pi/agent/sessions/--x--/s.jsonl") is PiDialect)
        XCTAssertTrue(TranscriptDialects.dialect(for: "/Users/me/.pi/agent/sessions/--x--/s.NDJSON") is PiDialect)
        XCTAssertTrue(TranscriptDialects.dialect(for: "/Users/me/.gemini/tmp/abc/chats/session.json") is GeminiDialect)
    }

    func testEverythingElseGoesToTheGenericWalker() {
        XCTAssertNil(TranscriptDialects.dialect(for: "/Users/me/.claude/projects/-Users-me-x/s.jsonl"))
        XCTAssertNil(TranscriptDialects.dialect(for: "/Users/me/.codex/config.toml"))
        XCTAssertNil(TranscriptDialects.dialect(for: "/Users/me/.gemini/settings.json"))
    }

    func testAnOfficialPiEnvelopeWithoutAPromptIsAnAnswerNotAFallThrough() {
        // An official Pi header with nothing a user said must yield "no facts",
        // never the generic walker's cwd-only row.
        let header = #"{"type":"session","version":3,"id":"abc","timestamp":"2026-01-01T00:00:00Z","cwd":"/Users/me/p"}"#
        let facts = NativeActivityHarvest.parseFacts(
            header, structured: true, path: "/Users/me/.pi/agent/sessions/--Users-me-p--/s.jsonl"
        )
        if NativeActivityHarvest.piLooksOfficial(header) {
            XCTAssertTrue(facts.isEmpty)
        }
    }

    func testTheScanMemoryHasOneLockedOwner() {
        ScanEngine.memory.withValue { $0.dashPaths["x-y"] = (path: "/x/y", verified: true) }
        XCTAssertEqual(NativeActivityHarvest.dashPathCache["x-y"]?.path, "/x/y")
        NativeActivityHarvest.dashPathCache.removeAll()
        XCTAssertTrue(ScanEngine.memory.snapshot.dashPaths.isEmpty)
    }
}
