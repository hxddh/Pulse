import Foundation
import Testing
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

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

    // MARK: - The detail card

    @Test func aRowWithoutAPlanHasNoPlanSection() {
        let card = RowCardModel.make(.init(row: waitingRow(), narrator: narrator))
        #expect(card.plan == nil)
        #expect(card.rowKey == "claude|s1")
    }

    @Test func thePanoramaCarriesNoEmptyLines() {
        let card = RowCardModel.make(.init(row: waitingRow(), narrator: narrator))
        let empty = card.panorama.filter { $0.isEmpty }
        #expect(empty.isEmpty)
    }
}
