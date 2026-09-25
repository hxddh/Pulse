import XCTest
@testable import PulseBar
@testable import PulseCore

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
}
