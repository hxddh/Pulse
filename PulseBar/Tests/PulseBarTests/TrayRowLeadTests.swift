import XCTest
@testable import PulseBar

/// 7.0 (scene BL): the collapsed row's lead, pinned as a pure precedence
/// table. The one behavior this version changes — fresh words outrank the
/// static task title on live rows — and the two behaviors it must not
/// change: waiting rows and process-only rows keep their 2.x leads.
final class TrayRowLeadTests: XCTestCase {

    private func lead(
        waiting: Bool = false,
        isProcessOnly: Bool = false,
        canFocusTerminal: Bool = false,
        hasTask: Bool = false,
        hasProject: Bool = false,
        freshWords: Bool = false,
        hasToolTitle: Bool = false
    ) -> TrayRowLead.Source {
        TrayRowLead.source(
            waiting: waiting,
            isProcessOnly: isProcessOnly,
            canFocusTerminal: canFocusTerminal,
            hasTask: hasTask,
            hasProject: hasProject,
            freshWords: freshWords,
            hasToolTitle: hasToolTitle
        )
    }

    // MARK: - The 7.0 change: value first on live rows

    func testFreshWordsBeatTaskOnLiveRows() {
        XCTAssertEqual(
            lead(hasTask: true, hasProject: true, freshWords: true, hasToolTitle: true),
            .freshWords
        )
    }

    func testStaleWordsFallBackToTask() {
        XCTAssertEqual(
            lead(hasTask: true, hasProject: true, freshWords: false, hasToolTitle: true),
            .task
        )
    }

    func testLiveFallbackChain() {
        // task > toolTitle > project > terminal/app session.
        XCTAssertEqual(lead(hasProject: true, hasToolTitle: true), .toolTitle)
        XCTAssertEqual(lead(hasProject: true), .project)
        XCTAssertEqual(lead(canFocusTerminal: true), .terminalSession)
        XCTAssertEqual(lead(), .appSession)
    }

    // MARK: - Waiting rows: unchanged — the question, not the news

    func testWaitingIgnoresFreshWords() {
        // A waiting row's lead is what the user must recognize to answer;
        // fresh words never displace it.
        XCTAssertEqual(
            lead(waiting: true, hasTask: true, freshWords: true),
            .waitTask
        )
        XCTAssertEqual(
            lead(waiting: true, hasProject: true, freshWords: true),
            .waitProject
        )
        XCTAssertEqual(lead(waiting: true, freshWords: true), .needsYou)
    }

    // MARK: - Process-only rows: unchanged status phrases

    func testProcessOnlyIgnoresEverythingElse() {
        XCTAssertEqual(
            lead(isProcessOnly: true, canFocusTerminal: true,
                 hasTask: true, freshWords: true),
            .processTerminal
        )
        XCTAssertEqual(
            lead(isProcessOnly: true, hasTask: true, freshWords: true),
            .processApp
        )
    }

    func testWaitingOutranksProcessOnly() {
        XCTAssertEqual(lead(waiting: true, isProcessOnly: true), .needsYou)
    }
}
