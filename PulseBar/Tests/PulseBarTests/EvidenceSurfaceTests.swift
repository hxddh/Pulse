import XCTest
@testable import PulseBar

/// 2.1 Evidence — the display layer for facts 1.1 computed and nobody saw.
///
/// The complaint was "not much useful information". The digest had the
/// information the whole time: an ordered tool timeline, session-wide token
/// totals, transcript growth, a real session start, and how much of the file
/// had actually been read. 1.2 spent the tray's spare capacity on the loop
/// signal and stopped there, because a flat four-fact cap was in the way.
///
/// Two things changed. The complete picture lands in Details, which is where
/// `EXPERIENCE.md` put complete evidence to begin with. And the tray row now
/// chooses facts by what each one carries, ordered by whether it moves —
/// because four facts that never change still cannot answer "is this getting
/// anywhere", which was the whole complaint.
///
/// These tests hold what those two surfaces can get wrong: saying something
/// the digest did not say, saying two true numbers in a way that makes them
/// look like a contradiction, and letting a fixed field order decide what a
/// person sees first.
final class EvidenceSurfaceTests: XCTestCase {

    private let now: Int64 = 1_800_000_000_000

    @MainActor
    private func store(_ lang: AppLanguage = .en) -> StatusStore {
        let store = StatusStore()
        store.language = lang
        return store
    }

    private func liveRow() -> AgentRow {
        var row = AgentRow(rowKey: "claude|s1", agent: .claude)
        row.task = "Fix the auth module"
        row.liveProcess = true
        row.harvestMs = Int64(Date().timeIntervalSince1970 * 1000)
        row.observationSource = .session
        return row
    }

    // MARK: - The timeline

    func testTimelineJoinsToolsInOrderWithArrows() {
        XCTAssertEqual(
            AgentRow.toolTimeline(["Read", "Edit", "Bash", "Edit"]),
            "Read → Edit → Bash → Edit"
        )
    }

    func testASingleToolIsStillATimeline() {
        XCTAssertEqual(AgentRow.toolTimeline(["Bash"]), "Bash")
    }

    func testNoToolsProducesNothingRatherThanAPlaceholder() {
        XCTAssertEqual(AgentRow.toolTimeline([]), "")
        XCTAssertEqual(AgentRow.toolTimeline(["", "   "]), "")
    }

    /// The end of the walk is the end you are standing on, so the front is what
    /// gets dropped — and the string has to admit it did.
    func testAnOverlongTimelineDropsTheOldestAndSaysSo() {
        let tools = (1...20).map { "T\($0)" }
        let line = AgentRow.toolTimeline(tools)
        XCTAssertTrue(line.hasPrefix("… → "), line)
        XCTAssertTrue(line.hasSuffix("T20"), line)
        XCTAssertFalse(line.contains("T8"), "the oldest entries are gone, not summarised")
        XCTAssertTrue(line.contains("T9"), "the newest 12 survive")
        XCTAssertEqual(
            line.components(separatedBy: " → ").count,
            AgentRow.maxTimelineTools + 1,
            "12 names plus the elision marker"
        )
    }

    func testExactlyTheLimitIsNotElided() {
        let tools = (1...AgentRow.maxTimelineTools).map { "T\($0)" }
        let line = AgentRow.toolTimeline(tools)
        XCTAssertFalse(line.contains("…"), line)
        XCTAssertTrue(line.hasPrefix("T1 → "), line)
    }

    @MainActor
    func testTheStoreRendersTheRowsOwnTimeline() {
        var row = liveRow()
        row.recentTools = ["Read", "Edit", "Bash"]
        XCTAssertEqual(store().evidenceTimeline(row), "Read → Edit → Bash")
        XCTAssertEqual(store().evidenceTimeline(liveRow()), "", "no tools, no line")
    }

    // MARK: - Two token numbers that are both true

    /// The 1.1 fork, made legible instead of hidden: session totals and the
    /// latest message are different measurements. Neither may overwrite or
    /// silently stand in for the other.
    @MainActor
    func testSessionTotalsAndLatestMessageTokensAreSeparateDisplayValues() {
        var row = liveRow()
        row.tokensIn = 1_200
        row.tokensOut = 300
        row.sessionTokensIn = 412_000
        row.sessionTokensOut = 98_500

        let s = store()
        let session = s.evidenceSessionTokens(row)
        XCTAssertTrue(session.contains("412k"), session)
        XCTAssertTrue(session.contains("98k"), session)
        XCTAssertFalse(session.contains("1.2k"), "the latest message is not the session total")

        // And the row still carries the per-message pair untouched.
        XCTAssertEqual(row.tokensIn, 1_200)
        XCTAssertEqual(row.tokensOut, 300)
    }

    @MainActor
    func testSessionTokensAreEmptyWhenTheDigestNeverCountedAny() {
        XCTAssertEqual(store().evidenceSessionTokens(liveRow()), "")
    }

    /// A page showing both numbers owes the reader the sentence that tells them
    /// apart. Without it, two disagreeing token counts read as a bug.
    @MainActor
    func testTheScopeNoteNamesBothMeasurements() {
        for lang in [AppLanguage.en, .zh] {
            let note = store(lang).tr(.evidenceSessionTokensHint)
            XCTAssertFalse(note.isEmpty)
            XCTAssertNotEqual(note, "evidenceSessionTokensHint")
        }
    }

    // MARK: - Transcript growth

    func testByteRateBucketsAcrossBKBAndMB() {
        XCTAssertEqual(AgentRow.compactBytes(840), "840 B")
        XCTAssertEqual(AgentRow.compactBytes(1_024), "1 KB")
        XCTAssertEqual(AgentRow.compactBytes(12_800), "12 KB")
        XCTAssertEqual(AgentRow.compactBytes(3_145_728), "3.0 MB")
    }

    /// Zero is "nobody measured", not "nothing is happening". Rendering it as
    /// `0 KB/min` would be the app inventing a claim about liveness.
    func testAnUnknownRateIsEmptyNotZero() {
        XCTAssertEqual(AgentRow.compactBytes(0), "")
        XCTAssertEqual(AgentRow.compactBytes(-5), "")
    }

    @MainActor
    func testTheRateLabelCarriesAPerMinuteUnitInBothLanguages() {
        var row = liveRow()
        row.bytesPerMinute = 12_800

        let english = store(.en).evidenceRate(row)
        XCTAssertTrue(english.contains("12 KB"), english)
        XCTAssertTrue(english.contains("/min"), english)

        let chinese = store(.zh).evidenceRate(row)
        XCTAssertTrue(chinese.contains("12 KB"), chinese)
        XCTAssertTrue(chinese.contains("分钟"), chinese)
    }

    @MainActor
    func testTheRateNoteExplainsPresenceAndAbsenceDifferently() {
        var moving = liveRow()
        moving.bytesPerMinute = 12_800
        let s = store()
        XCTAssertEqual(s.evidenceRate(liveRow()), "", "unknown renders as nothing, the cell shows —")
        XCTAssertNotEqual(
            s.evidenceRateNote(moving),
            s.evidenceRateNote(liveRow()),
            "'what this measures' and 'this was not measured' are different sentences"
        )
    }

    // MARK: - Session length

    @MainActor
    func testSessionLengthComesFromTheDigestStartAndDisappearsWhenUnknown() {
        var row = liveRow()
        row.sessionStartedMs = now - 2 * 60 * 60 * 1000
        XCTAssertFalse(store().evidenceSessionLength(row, nowMs: now).isEmpty)
        XCTAssertEqual(store().evidenceSessionLength(liveRow(), nowMs: now), "")
    }

    func testSessionDurationIsMeasuredFromTheDigestStartNotTheFileStamp() {
        var row = liveRow()
        row.startedMs = now - 60_000
        row.sessionStartedMs = now - 3_600_000
        XCTAssertEqual(row.sessionDurationSeconds(nowMs: now), 3_600, accuracy: 0.5)
        XCTAssertEqual(row.sessionAgeSeconds(nowMs: now), 60, accuracy: 0.5)
    }

    // MARK: - How much has actually been read

    @MainActor
    func testCaughtUpAndCatchingUpAreDifferentSentences() {
        var caught = liveRow()
        caught.recentTools = ["Edit"]
        caught.digestCaughtUp = true
        caught.digestProgressPercent = 100

        var behind = liveRow()
        behind.recentTools = ["Edit"]
        behind.digestCaughtUp = false
        behind.digestProgressPercent = 78

        let s = store()
        let done = s.evidenceReadState(caught)
        let partial = s.evidenceReadState(behind)
        XCTAssertFalse(done.isEmpty)
        XCTAssertFalse(partial.isEmpty)
        XCTAssertNotEqual(done, partial)
        XCTAssertTrue(partial.contains("78"), partial)
        XCTAssertFalse(done.contains("78"))

        XCTAssertFalse(s.evidenceCountsArePartial(caught))
        XCTAssertTrue(
            s.evidenceCountsArePartial(behind),
            "letting qualitative facts out early obliges the surface to say the counts are not totals"
        )
    }

    /// A cache-only row has no transcript to be behind on. `caughtUp == false`
    /// there means "no digest", and claiming "0% read" would be inventing state.
    @MainActor
    func testARowWithNoDigestSaysNothingAboutReadProgress() {
        let bare = liveRow()
        XCTAssertFalse(bare.hasSessionDigest)
        XCTAssertEqual(store().evidenceReadState(bare), "")
        XCTAssertFalse(store().evidenceCountsArePartial(bare))
    }

    @MainActor
    func testTheCardStaysAwayWhenThereIsNoEvidenceAtAll() {
        XCTAssertFalse(store().hasSessionEvidence(liveRow()), "no facts, no card")
        var some = liveRow()
        some.recentTools = ["Edit"]
        XCTAssertTrue(store().hasSessionEvidence(some))
    }

    // MARK: - The observation line picks facts by what they carry

    @MainActor
    func testTheRateFillsAThinObservationLine() {
        var row = liveRow()
        row.bytesPerMinute = 12_800
        let line = store().rowObservationLine(row)
        XCTAssertTrue(line.contains("12 KB"), line)
    }

    /// The rule the four-fact cap was hiding: a row full of facts that never
    /// move still cannot answer "is this getting anywhere". Whatever changes as
    /// work happens outranks whatever was fixed when the session opened.
    @MainActor
    func testDynamicFactsOutrankStandingOnes() {
        var row = liveRow()
        row.sessionErrors = 3          // fault
        row.progressDone = 2
        row.progressTotal = 5          // advance
        row.bytesPerMinute = 12_800    // motion
        row.tokensIn = 12_000
        row.tokensOut = 3_000          // motion
        row.contextPercent = 42        // reach
        row.model = "claude-opus"      // standing
        row.mode = "agent"             // standing

        let line = store().rowObservationLine(row)
        let parts = line.components(separatedBy: " · ")
        func at(_ needle: String) -> Int {
            parts.firstIndex { $0.contains(needle) } ?? -1
        }

        XCTAssertEqual(at("error"), 0, "a fault changes what you do next: \(line)")
        XCTAssertLessThan(at("2/5"), at("KB"), line)
        XCTAssertLessThan(at("KB"), at("↑"), "growth answers 'moving?' before size does: \(line)")
        XCTAssertLessThan(at("↑"), at("Context"), line)
        XCTAssertLessThan(at("Context"), at("Model"), "the model never advances: \(line)")
        XCTAssertGreaterThan(
            parts.count, 4,
            "the count follows the content, it is not rationed to four: \(line)"
        )
    }

    /// `EXPERIENCE.md`: a position that carries no information either gets real
    /// information or gets deleted. Zero is not a fact.
    @MainActor
    func testZeroAndUnknownFactsNeverAppear() {
        XCTAssertEqual(store().rowObservationLine(liveRow()), "", "nothing known, nothing said")

        var partial = liveRow()
        partial.tokensIn = 12_000
        let line = store().rowObservationLine(partial)
        XCTAssertTrue(line.contains("12k"), line)
        XCTAssertFalse(line.contains("Model"), "no model was reported: \(line)")
        XCTAssertFalse(line.contains("KB"), "no growth rate was measured: \(line)")
        XCTAssertFalse(line.contains("Context"), "context was never reported: \(line)")
        XCTAssertFalse(line.contains("events"), "zero records is not a record count: \(line)")
        XCTAssertFalse(line.contains("complete"), "zero progress is not progress: \(line)")
    }

    /// The one thing extra density must never buy: the same quantity said twice
    /// in two scopes. The cumulative total lives in Details, where a label
    /// disambiguates it — and where it stays clear of the no-cost-HUD rule.
    @MainActor
    func testTheRowNeverRestatesTheSessionTotalBesideTheLatestCall() {
        var row = liveRow()
        row.tokensIn = 12_000
        row.tokensOut = 3_000
        row.sessionTokensIn = 412_000
        row.sessionTokensOut = 98_500
        let line = store().rowObservationLine(row)
        XCTAssertTrue(line.contains("12k"), line)
        XCTAssertFalse(line.contains("412k"), "two token numbers on one line is ambiguity: \(line)")
    }

    /// A caveat is only information when there is something on the line for it
    /// to qualify.
    @MainActor
    func testTheCatchUpCaveatAppearsOnlyBesideCountsItQualifies() {
        var counted = liveRow()
        counted.sessionErrors = 3
        counted.digestProgressPercent = 78
        counted.digestCaughtUp = false
        let line = store().rowObservationLine(counted)
        XCTAssertTrue(line.contains("78"), line)
        XCTAssertEqual(
            line.components(separatedBy: " · ").count, 2,
            "the caveat must not carry a separator and split into two facts: \(line)"
        )

        var uncounted = liveRow()
        uncounted.model = "gpt-5"
        uncounted.digestProgressPercent = 40
        uncounted.digestCaughtUp = false
        let quiet = store().rowObservationLine(uncounted)
        XCTAssertFalse(quiet.contains("40"), "nothing here is a partial count: \(quiet)")
        XCTAssertTrue(quiet.contains("Model gpt 5"), quiet)
    }

    /// A rate on a stalled or finished session is history dressed as motion.
    @MainActor
    func testAStalledOrFinishedRowGetsNoRate() {
        var stalled = liveRow()
        stalled.bytesPerMinute = 12_800
        stalled.isStalled = true
        XCTAssertFalse(store().rowObservationLine(stalled).contains("KB"))

        var recent = liveRow()
        recent.bytesPerMinute = 12_800
        recent.liveProcess = false
        XCTAssertFalse(store().rowObservationLine(recent).contains("KB"))
    }

    @MainActor
    func testAWaitingRowStillCarriesNoObservationFactsAtAll() {
        var waiting = liveRow()
        waiting.bytesPerMinute = 12_800
        waiting.waiting = true
        waiting.waitKind = "Permission"
        XCTAssertEqual(store().rowObservationLine(waiting), "", "the question is the point")
    }

    // MARK: - Nothing ships untranslated

    func testEveryEvidenceKeyIsRealCopyInBothLanguages() {
        let keys: [L10n.Key] = [
            .evidenceHeading, .evidenceTimeline, .evidenceTimelineHint,
            .evidenceSessionTokens, .evidenceSessionTokensHint,
            .evidenceRate, .evidenceRatePerMinute, .evidenceRateHint,
            .evidenceRateUnknown, .evidenceRateFact, .evidenceSessionLength,
            .evidenceRead, .evidenceReadCaughtUp, .evidenceReadCatchingUp,
            .evidenceReadPartialHint, .evidenceReadCompact,
        ]
        for key in keys {
            let en = L10n.t(key, .en)
            let zh = L10n.t(key, .zh)
            XCTAssertFalse(en.isEmpty, "empty en for \(key)")
            XCTAssertFalse(zh.isEmpty, "empty zh for \(key)")
            XCTAssertNotEqual(en, "\(key)", "en for \(key) is the key name")
            XCTAssertNotEqual(zh, "\(key)", "zh for \(key) is the key name")
            XCTAssertNotEqual(zh, en, "zh for \(key) was never translated")
            XCTAssertEqual(
                en.components(separatedBy: "%@").count,
                zh.components(separatedBy: "%@").count,
                "%@ count differs for \(key)"
            )
            XCTAssertEqual(
                en.components(separatedBy: "%d").count,
                zh.components(separatedBy: "%d").count,
                "%d count differs for \(key)"
            )
        }
    }

    /// Vendor tool names are product identities, not copy — the same rule the
    /// tray follows for Agent names.
    @MainActor
    func testToolNamesAreNotTranslated() {
        var row = liveRow()
        row.recentTools = ["Read", "Edit", "Bash"]
        XCTAssertEqual(store(.zh).evidenceTimeline(row), "Read → Edit → Bash")
    }
}
