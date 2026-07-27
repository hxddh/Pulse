import XCTest
@testable import PulseBar

/// Resource loading must never be able to kill the app.
///
/// Every release from 0.21 to 0.23.0 shipped a DMG that crashed on launch:
/// `package.sh` built a malformed resource bundle, `Bundle(url:)` returned nil,
/// and the compiler-generated `Bundle.module` accessor called `fatalError()`
/// while drawing the menu bar icon. `swift test` was green the whole time,
/// because tests never load the packaged bundle.
///
/// These do not prove the DMG is correct — only `scripts/package_check.py`,
/// which reads the built .app, can do that. What they pin is the part that
/// belongs in the app: a resource that cannot be found degrades instead of
/// trapping.
final class ResourceLookupTests: XCTestCase {

    func testResolvingTheBundleDoesNotTrap() {
        // The assertion is that this line returns at all. Under `swift test`
        // the bundle may or may not be present; either answer is acceptable,
        // a crash is not.
        _ = PulseResources.bundle
    }

    func testMissingResourceReturnsNilRatherThanTrapping() {
        XCTAssertNil(PulseResources.url(forResource: "definitely-not-here", withExtension: "png"))
        XCTAssertNil(
            PulseResources.url(
                forResource: "definitely-not-here",
                withExtension: "png",
                subdirectory: "AgentIcons"
            )
        )
    }

    func testLookupIsStableAcrossCalls() {
        // `bundle` is a `static let`; a second call must not re-run resolution
        // and must not trap on the way through.
        let first = PulseResources.bundle?.bundleURL
        let second = PulseResources.bundle?.bundleURL
        XCTAssertEqual(first, second)
    }
}

/// Duration wording moved off `StatusStore` so `SnapshotBuilder` — which is
/// pure and has no store — could put the elapsed wait in the menu bar.
final class DurationFormatTests: XCTestCase {
    func testUnitsCrossOverAtTheRightPlaces() {
        XCTAssertEqual(DurationFormat.label(seconds: 2, lang: .en), "now")
        XCTAssertEqual(DurationFormat.label(seconds: 42, lang: .en), "42s")
        XCTAssertEqual(DurationFormat.label(seconds: 600, lang: .en), "10m")
        XCTAssertEqual(DurationFormat.label(seconds: 7200, lang: .en), "2h")
    }

    func testChineseDiffersFromEnglish() {
        XCTAssertNotEqual(
            DurationFormat.label(seconds: 600, lang: .zh),
            DurationFormat.label(seconds: 600, lang: .en)
        )
    }
}

/// Ten minutes is where a wait stops being ordinary. It is the only place in
/// the row where "longer" becomes "louder".
final class WaitUrgencyTests: XCTestCase {
    private func waitingRow(ageSeconds: Double) -> AgentRow {
        var row = AgentRow(rowKey: "k", agent: .claude)
        row.waiting = true
        row.waitSinceMs = Int64((Date().timeIntervalSince1970 - ageSeconds) * 1000)
        return row
    }

    func testShortWaitIsNotUrgent() {
        XCTAssertFalse(waitingRow(ageSeconds: 60).isUrgentWait)
    }

    func testLongWaitIsUrgent() {
        XCTAssertTrue(waitingRow(ageSeconds: 1200).isUrgentWait)
    }

    func testNonWaitingRowIsNeverUrgent() {
        var row = waitingRow(ageSeconds: 9999)
        row.waiting = false
        XCTAssertFalse(row.isUrgentWait)
    }

    func testUnknownStartIsNotUrgent() {
        var row = waitingRow(ageSeconds: 1200)
        row.waitSinceMs = 0
        XCTAssertFalse(row.isUrgentWait, "no timestamp must not read as an old wait")
    }
}
