import Foundation

/// 19.0 · the cards under a row — the store's side: `RowCardModel.make`
/// with the store's narrator.
@MainActor
extension StatusStore {
    func rowCardModel(_ row: AgentRow) -> RowCardModel {
        RowCardModel.make(RowCardModel.Input(
            row: row,
            narrator: narrator
        ))
    }
}
