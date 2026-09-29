import Foundation
import Testing
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest
@testable import PulseManaged
@testable import PulseRespond

/// 19.0 · the cards under a row, as values. The product's rules for the
/// surfaces where the user acts, asserted on the model rather than on a
/// running app.
@Suite("Row cards")
struct RowCardModelTests {
    let now: Int64 = 1_800_000_000_000
    var narrator: RowNarrator { RowNarrator(lang: .en, nowMs: now) }

    func waitingRow(managed: Bool = false) -> AgentRow {
        var row = AgentRow(rowKey: "claude|s1", agent: .claude)
        row.sessionID = "s1"
        row.waiting = true
        row.waitKind = "Permission"
        if managed { row.managedID = "m1" }
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

    // MARK: - Managed asks and the reply

    @Test func aTruncatedManagedAskWithdrawsAllowAndSaysWhy() throws {
        let ask = ManagedPermission.Request(id: "a1", managedID: "m1", toolName: "Bash", inputJSON: "{}", truncated: true, createdMs: now)
        let card = RowCardModel.make(.init(row: waitingRow(managed: true), narrator: narrator, permissions: [ask], managedStatus: .running))
        let permission = try #require(card.permissions.first)
        #expect(!permission.canOfferAllow)
        #expect(permission.truncatedNote != nil)
        #expect(card.hasAsks)
    }

    @Test(arguments: [
        (ManagedSession.Status.interrupted, true, true),
        (.failed("boom"), true, true),
        (.idle, false, true),
        (.cancelled, false, true),
        (.running, false, false),
        (.queued, false, false),
    ])
    func aDeadTurnIsANeedsYouState(status: ManagedSession.Status, recovery: Bool, field: Bool) throws {
        var row = waitingRow(managed: true)
        row.waiting = false
        let card = RowCardModel.make(.init(row: row, narrator: narrator, managedStatus: status))
        #expect(card.needsRecovery == recovery)
        #expect(try #require(card.reply).showsField == field)
        #expect(card.hasAsks == recovery)
    }

    @Test func anObservedRowHasNoReplyBoxAndNoConversation() {
        var row = waitingRow()
        row.waiting = false
        let card = RowCardModel.make(.init(
            row: row, narrator: narrator, managedStatus: .idle,
            managedEntries: [.init(kind: .agent, text: "hello")]
        ))
        #expect(card.reply == nil)
        #expect(card.entries.isEmpty)
        #expect(!card.hasAsks)
    }

    @Test func theAmbientConversationIsTheLastFiveMoves() {
        let entries = (1...8).map { TranscriptReader.Entry(kind: .agent, text: "move \($0)") }
        let card = RowCardModel.make(.init(row: waitingRow(managed: true), narrator: narrator, managedStatus: .idle, managedEntries: entries))
        #expect(card.entries.map(\.text) == ["move 4", "move 5", "move 6", "move 7", "move 8"])
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
            for permission in model.permissions {
                #expect(permission.canOfferAllow == (permission.truncatedNote == nil), "\(fixture.name)")
            }
        }
        #expect(cards == 6)
    }
}
