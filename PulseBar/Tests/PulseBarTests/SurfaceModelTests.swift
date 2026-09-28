import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest
@testable import PulseManaged
@testable import PulseRespond

/// 15.0 · Witness — the product's rules asserted on the surface values the
/// Workbench renders (and `SurfaceCapture` photographs), not on the store
/// behind them: dispatch order is the only order, only a current pass on
/// unchanged code reads as passed, and a Mission without a ruler never
/// offers a verdict.
final class SurfaceModelTests: XCTestCase {

    private func missions(_ lang: ResolvedLanguage) -> [MissionBoard] {
        SurfaceFixtures.all(lang: lang).compactMap {
            if case .mission(let board) = $0.value { return board } else { return nil }
        }
    }

    private func proofs(_ lang: ResolvedLanguage) -> [ProofCardModel] {
        SurfaceFixtures.all(lang: lang).compactMap {
            if case .proof(let model) = $0.value { return model } else { return nil }
        }
    }

    // MARK: - The fixture list the capture script reads

    func testTheCaptureScriptsNamesAreTheFixtures() {
        XCTAssertEqual(SurfaceFixtures.all(lang: .en).map(\.name), SurfaceFixtures.names)
        XCTAssertEqual(Set(SurfaceFixtures.names).count, SurfaceFixtures.names.count)
    }

    // MARK: - Only a current pass reads as passed

    func testOnlyACurrentPassEverGetsThePassedTone() {
        let outcomes: [AcceptanceEvidence.Outcome] = [.passed, .failed, .timedOut, .couldNotRun, .invalidatedDuringRun, .interrupted]
        let judgements: [EvidenceStanding] = [.passing, .stale, .measuring, .unverified, .notPassing]
        for lang in [ResolvedLanguage.en, .zh] {
            for outcome in outcomes {
                var evidence = SurfaceFixtures.evidence(.passed, "c", root: "/r")
                evidence.outcome = outcome
                for judged in judgements {
                    let cell = SurfaceLabels.check(.evidence(judged, evidence), lang: lang)
                    XCTAssertEqual(cell.tone == .passed, judged == .passing, "\(outcome) judged \(judged)")
                    let single = SurfaceLabels.evidence(evidence, standing: judged, lang: lang)
                    XCTAssertEqual(single.tone == .passed, judged == .passing, "\(outcome) judged \(judged)")
                }
            }
            for standing in [Mission.CheckStanding.notRun, .notInContract, .running] {
                XCTAssertNotEqual(SurfaceLabels.check(standing, lang: lang).tone, .passed)
            }
        }
    }

    func testEveryPassedCellInEveryFixtureIsBackedByACurrentPass() {
        // The fixtures hold exactly two current passes: the first Candidate's
        // `swift test` and the working copy's `swift test`.
        let board = SurfaceFixtures.missionCompare(lang: .en)
        let passed = board.columns.flatMap { column in
            column.cells.enumerated().filter { $0.element.tone == .passed }.map { "\(column.id):\(board.checks[$0.offset])" }
        }
        XCTAssertEqual(passed, ["a1:swift test"])
        XCTAssertEqual(SurfaceFixtures.proofResults(lang: .en).lines.filter { $0.cell.tone == .passed }.map(\.command), ["swift test"])
        XCTAssertTrue(SurfaceFixtures.proofRunning(lang: .en).lines.allSatisfy { $0.cell.tone != .passed },
                      "a pass the code has not been measured against is not a pass yet")
    }

    func testAPassOnCodeThatChangedSinceReadsStale() throws {
        let board = SurfaceFixtures.missionCompare(lang: .en)
        let second = try XCTUnwrap(board.columns.first { $0.id == "a2" })
        XCTAssertEqual(second.cells.first, CheckCell(text: L10n.t(.managedRunCheckStale, .en), tone: .warn))
        XCTAssertEqual(second.cells.last?.tone, .warn, "exit 2 is a failure")
    }

    // MARK: - Side by side, never judged

    func testColumnsAreDispatchOrderThenJoinOrderAndNothingElse() {
        let board = SurfaceFixtures.missionCompare(lang: .en)
        XCTAssertEqual(board.columns.map(\.id), ["a1", "a2", "x-codex"])
        XCTAssertEqual(board.columns.map(\.title), (1...3).map { String(format: L10n.t(.missionCandidate, .en), $0) })
        XCTAssertEqual(SurfaceFixtures.missionLegacyCrowded(lang: .en).columns.map(\.id), ["c1", "c2", "c3", "c4"])
    }

    func testEvidenceNeverReordersTheColumns() {
        // Reverse which Candidate passed: the order must not follow.
        let check = Mission.Check(id: "c", command: "swift test")
        var mission = Mission.Model(id: "m", repoRoot: "/r", goal: "A", checks: [check], createdMs: SurfaceFixtures.t0)
        let first = SurfaceFixtures.candidate("s1", mission: mission, revision: 1, status: .idle)
        let second = SurfaceFixtures.candidate("s2", mission: mission, revision: 1, status: .idle)
        mission.candidateIDs = ["s1", "s2"]
        for winner in [first.root, second.root] {
            let board = MissionBoard.make(MissionBoard.Input(
                mission: mission, candidates: [first, second], currentCandidateID: "s1",
                lifecycle: .ready, lang: .en,
                evidence: { $0 == winner ? [SurfaceFixtures.evidence(.passed, "c", root: $0)] : [SurfaceFixtures.evidence(.failed, "c", root: $0, exit: 1)] },
                judge: SurfaceFixtures.judge(current: [first.root: SurfaceFixtures.fingerprint, second.root: SurfaceFixtures.fingerprint])
            ))
            XCTAssertEqual(board.columns.map(\.id), ["s1", "s2"])
        }
    }

    func testChoosingMarksOneColumnAndNothingElseStandsOut() {
        let board = SurfaceFixtures.missionCompare(lang: .en)
        XCTAssertEqual(board.columns.filter(\.chosen).map(\.id), ["a2"])
        XCTAssertEqual(board.columns.filter(\.isCurrent).map(\.id), ["a2"])
        XCTAssertNil(board.columns.first { $0.id == "a2" }?.selectionKey, "the current Candidate is already open")
        XCTAssertEqual(board.columns.first { $0.id == "a1" }?.selectionKey, "managed|a1")
        XCTAssertEqual(board.columns.first { $0.id == "x-codex" }?.selectionKey, "codex|s-9")
    }

    func testAnOlderCandidateIsNeverHeldToANewerRuler() {
        let board = SurfaceFixtures.missionCompare(lang: .en)
        let first = board.columns[0]
        XCTAssertFalse(first.revisionNote.isEmpty)
        XCTAssertEqual(first.cells[1].text, L10n.t(.missionCheckNotInContract, .en))
        XCTAssertTrue(board.columns[1].revisionNote.isEmpty)
    }

    func testAnExternalCandidateSaysWhereItCameFrom() {
        let external = SurfaceFixtures.missionCompare(lang: .en).columns[2]
        XCTAssertEqual(external.externalID, "x-codex")
        XCTAssertTrue(external.externalNote.contains("Codex"))
        XCTAssertTrue(external.session.hasPrefix("Codex"))
        XCTAssertEqual(external.changes, "+64 −12")
        XCTAssertEqual(external.cells[0].text, L10n.t(.missionCheckNotRun, .en))
        XCTAssertEqual(external.cells[1].text, L10n.t(.managedRunCheckInterrupted, .en))
    }

    func testAMissionWithoutARulerOffersNoVerdict() {
        let board = SurfaceFixtures.missionNoChecks(lang: .zh)
        XCTAssertNotNil(board.noChecksWarning)
        XCTAssertFalse(board.canRunChecks)
        XCTAssertTrue(board.columns.allSatisfy { $0.cells.isEmpty })
        XCTAssertNil(SurfaceFixtures.missionCompare(lang: .zh).noChecksWarning)
    }

    func testChecksCannotStartUnderARunningTurn() {
        XCTAssertFalse(SurfaceFixtures.missionLegacyCrowded(lang: .en).canRunChecks,
                       "the fourth Candidate's turn is still changing its code")
        XCTAssertNotNil(SurfaceFixtures.missionLegacyCrowded(lang: .en).legacyNote)
    }

    // MARK: - The working-copy card

    func testTheOptInStateOffersOnlyTheMissionsThatCanBeJoined() {
        let card = SurfaceFixtures.proofEmpty(lang: .en)
        XCTAssertTrue(card.lines.isEmpty)
        XCTAssertFalse(card.canRun, "no checks, nothing to run")
        XCTAssertNil(card.joined)
        XCTAssertEqual(card.joinable.map(\.id), ["m-new", "m-old"], "newest first, archived left out")
    }

    func testAJoinedWorkingCopyCanLeaveAndJoinsNothingElse() {
        let card = SurfaceFixtures.proofResults(lang: .en)
        XCTAssertEqual(card.joined, .init(missionID: "m-new", title: "Fix the flaky login test", externalID: "x-here"))
        XCTAssertTrue(card.joinable.isEmpty)
        XCTAssertEqual(card.savedChecksText, "swift test\nmake lint\n./scripts/e2e.sh --headless\nnpm run typecheck")
        XCTAssertEqual(card.lines.map(\.cell.text), [
            L10n.t(.missionCheckPassed, .en),
            String(format: L10n.t(.missionCheckFailed, .en), 1),
            L10n.t(.managedRunCheckStale, .en),
            L10n.t(.missionCheckNotRun, .en),
        ])
    }

    func testABusyCardCannotStartASecondRun() {
        let card = SurfaceFixtures.proofRunning(lang: .en)
        XCTAssertTrue(card.busy)
        XCTAssertFalse(card.canRun)
        XCTAssertEqual(card.lines.map(\.cell.text), [
            L10n.t(.missionCheckRunning, .en),
            L10n.t(.managedRunCheckMeasuring, .en),
            L10n.t(.managedRunCheckTimeout, .en),
        ])
    }

    // MARK: - Both languages

    func testEveryFixtureSpeaksBothLanguages() {
        for lang in [ResolvedLanguage.en, .zh] {
            for board in missions(lang) {
                XCTAssertFalse(board.lifecycle.isEmpty)
                XCTAssertTrue(board.columns.allSatisfy { !$0.title.isEmpty && !$0.session.isEmpty })
                XCTAssertTrue(board.columns.allSatisfy { $0.cells.count == board.checks.count })
            }
            for card in proofs(lang) {
                XCTAssertTrue(card.lines.allSatisfy { !$0.cell.text.isEmpty })
            }
        }
        XCTAssertNotEqual(SurfaceFixtures.missionCompare(lang: .zh).columns[0].title,
                          SurfaceFixtures.missionCompare(lang: .en).columns[0].title)
    }
}
