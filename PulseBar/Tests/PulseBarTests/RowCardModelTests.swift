import Foundation
import Testing
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest
@testable import PulseRespond

/// 19.0 · the cards under a row, as values. The product's rules for the
/// surfaces where the user acts, asserted on the model rather than on a
/// running app.
@Suite("Row cards")
struct RowCardModelTests {
    let now: Int64 = 1_800_000_000_000
    var narrator: RowNarrator { RowNarrator(lang: .en, nowMs: now) }

    func waitingRow() -> AgentRow {
        var row = AgentRow(rowKey: "claude|s1", agent: .claude)
        row.sessionID = "s1"
        row.waiting = true
        row.waitKind = "Permission"
        return row
    }

    func inbound(full: String = #"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#, truncated: Bool = false) -> RespondSpool.InboundRequest {
        RespondSpool.InboundRequest(
            request: PermissionRequest(id: "toolu_1", agent: .claude, session: "s1", fullRequest: full, truncated: truncated),
            toolName: "Bash", expiresAtMs: now + 60_000
        )
    }

    // MARK: - Respond

    @Test func allowExistsOnlyBesideTheWholeRequest() throws {
        let whole = try #require(RowCardModel.make(.init(row: waitingRow(), narrator: narrator, inbound: inbound())).respond)
        #expect(whole.canOfferAllow)
        let cut = try #require(RowCardModel.make(.init(row: waitingRow(), narrator: narrator, inbound: inbound(truncated: true))).respond)
        #expect(!cut.canOfferAllow, "approving a truncated request is the blind approve")
        let empty = try #require(RowCardModel.make(.init(row: waitingRow(), narrator: narrator, inbound: inbound(full: "  "))).respond)
        #expect(!empty.canOfferAllow)
    }

    @Test func aVerdictCarriesTheRequestThatWasOnScreen() throws {
        let request = inbound()
        let card = try #require(RowCardModel.make(.init(row: waitingRow(), narrator: narrator, inbound: request)).respond)
        #expect(card.requestID == request.request.id)
        #expect(card.digest == request.request.digest)
        #expect(card.fullRequest == request.request.fullRequest, "the full text, never a summary")
    }

    @Test func aRowThatStoppedWaitingOffersNoVerdict() {
        var row = waitingRow()
        row.waiting = false
        #expect(RowCardModel.make(.init(row: row, narrator: narrator, inbound: inbound())).respond == nil)
    }

    @Test func aWrittenVerdictShowsItsFateInsteadOfButtons() throws {
        let card = try #require(RowCardModel.make(.init(row: waitingRow(), narrator: narrator, inbound: inbound(), fateNote: "taken")).respond)
        #expect(card.fateNote == "taken")
    }

    @Test func onlyAHeldRequestIsANeedsYouCard() {
        #expect(!RowCardModel.make(.init(row: waitingRow(), narrator: narrator)).hasAsks)
        #expect(RowCardModel.make(.init(row: waitingRow(), narrator: narrator, inbound: inbound())).hasAsks)
    }

    @Test func waitActionsExistOnlyForAWait() {
        #expect(RowCardModel.make(.init(row: waitingRow(), narrator: narrator)).waitActions.map(\.action) == [.dismiss, .snooze])
        var row = waitingRow()
        row.waiting = false
        #expect(RowCardModel.make(.init(row: row, narrator: narrator)).waitActions.isEmpty)
    }

    // MARK: - Fixtures

    @Test(arguments: [ResolvedLanguage.en, .zh])
    func everyCardFixtureKeepsTheRules(lang: ResolvedLanguage) {
        var cards = 0
        for fixture in SurfaceFixtures.all(lang: lang) {
            let model: RowCardModel
            switch fixture.value {
            case .asks(let m), .expanded(let m): model = m
            default: continue
            }
            cards += 1
            if let respond = model.respond {
                #expect(respond.canOfferAllow == !fixture.name.contains("truncated"), "\(fixture.name)")
            }
        }
        #expect(cards == 4)
    }
}
