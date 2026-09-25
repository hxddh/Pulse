import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest
@testable import PulseRespond

/// 12.0 · the roster is one table, and the table is whole.
final class AgentCatalogTests: XCTestCase {
    func testEveryAgentHasExactlyOneSpecInDeclarationOrder() {
        XCTAssertEqual(AgentCatalog.all.map(\.id), AgentID.allCases,
                       "catalog order is process-rule precedence; it must follow the enum")
        for id in AgentID.allCases {
            XCTAssertEqual(id.spec.id, id)
        }
    }

    func testMonogramsAreUnique() {
        let monograms = AgentCatalog.all.map(\.monogram)
        XCTAssertEqual(Set(monograms).count, monograms.count)
    }

    func testAliasesNeverShadowAnotherAgent() {
        var seen: [String: AgentID] = [:]
        for spec in AgentCatalog.all {
            for alias in spec.aliases {
                XCTAssertNil(AgentID(rawValue: alias), "\(alias) is already a raw value")
                XCTAssertNil(seen[alias], "\(alias) names two agents")
                seen[alias] = spec.id
            }
        }
    }

    func testEverySpellingResolves() {
        for spec in AgentCatalog.all {
            XCTAssertEqual(AgentCatalog.agent(named: spec.id.rawValue), spec.id)
            for alias in spec.aliases {
                XCTAssertEqual(AgentCatalog.agent(named: alias), spec.id)
            }
        }
        XCTAssertNil(AgentCatalog.agent(named: "not-an-agent"))
    }

    func testOnlyCursorAgentHasNoCollectorOfItsOwn() {
        let without = AgentCatalog.all.filter { $0.harvestRoots.isEmpty }.map(\.id)
        XCTAssertEqual(without, [.cursorAgent])
    }

    func testTranscriptPolicyKeepsPiReadingIdleFiles() {
        XCTAssertFalse(AgentID.pi.spec.transcripts.skipsStaleFiles)
        XCTAssertTrue(AgentID.pi.spec.transcripts.allowsBoundedLargeFiles)
        XCTAssertTrue(AgentID.claude.spec.transcripts.skipsStaleFiles)
        XCTAssertFalse(AgentID.cursor.spec.transcripts.allowsBoundedLargeFiles)
    }

    func testOnlyClaudeReachesTheDecisionPoint() {
        XCTAssertEqual(AgentCatalog.all.filter { $0.respondReach == .hookSite }.map(\.id), [.claude])
    }

    // MARK: - 12.1 · the walk is data

    func testEveryCollectorHasAPlaceOnTheFixtureWall() {
        // Agents with a hand-written fixture in NativeHarvestSelfTest, plus
        // Cursor Agent, which has no collector of its own.
        let handWritten: Set<AgentID> = [.cursor, .cursorAgent, .grok, .pi, .opencode, .warpAgent]
        for spec in AgentCatalog.all where !handWritten.contains(spec.id) {
            XCTAssertNotNil(spec.walk.fixturePath, "\(spec.id.rawValue) has no generic fixture")
        }
    }

    func testDatabaseAdaptersAreWhereTheyWere() {
        XCTAssertEqual(AgentID.cursor.spec.walk.database, .cursor)
        XCTAssertEqual(AgentID.opencode.spec.walk.database, .openCode)
        XCTAssertEqual(AgentID.warpAgent.spec.walk.database, .warp)
        XCTAssertEqual(AgentID.pi.spec.walk.database, .pi)
        XCTAssertEqual(AgentID.grok.spec.walk.database, .grok)
        XCTAssertEqual(AgentCatalog.all.filter { $0.walk.database != nil }.count, 5)
        XCTAssertTrue(DatabaseAdapter.pi.runsAfterTranscripts)
        XCTAssertFalse(DatabaseAdapter.pi.failsOnUnreadableFile)
        XCTAssertTrue(DatabaseAdapter.cursor.extensions.contains("vscdb"))
    }

    func testTranscriptSelection() {
        XCTAssertFalse(AgentID.grok.spec.walk.transcripts.admits("/users/me/.grok/sessions/a.jsonl"))
        XCTAssertTrue(AgentID.pi.spec.walk.transcripts.admits("/users/me/.pi/agent/sessions/x.jsonl"))
        XCTAssertFalse(AgentID.pi.spec.walk.transcripts.admits("/users/me/.pi/context-mode/cache.json"))
        XCTAssertFalse(AgentID.gemini.spec.walk.transcripts.admits("/users/me/.gemini/tmp/x/src/main.json"))
        XCTAssertTrue(AgentID.claude.spec.walk.transcripts.admits("/anything"))
    }

    func testReadWindowsKeepTheirVendorSizes() {
        XCTAssertEqual(AgentID.codex.spec.walk.windowBytes, 8_000_000)
        XCTAssertEqual(AgentID.codex.spec.walk.deadlineSeconds, 1.2)
        XCTAssertEqual(AgentID.pi.spec.walk.windowBytes, 496_000)
        XCTAssertEqual(AgentID.pi.spec.walk.headBytes, 96_000)
        XCTAssertEqual(AgentID.claude.spec.walk.windowBytes, 1_000_000)
        XCTAssertEqual(AgentID.grok.spec.walk.maxFileBytes, 16 * 1024 * 1024)
        XCTAssertEqual(AgentCatalog.all.filter(\.walk.dropsContinuationPrompts).count, 11)
    }
}
