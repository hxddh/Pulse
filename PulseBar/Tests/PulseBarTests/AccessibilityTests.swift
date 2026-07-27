import XCTest
@testable import PulseBar

/// VoiceOver must speak the interface language, not English.
final class AccessibilityLocalizationTests: XCTestCase {
    func testGlanceStatesHaveDistinctLocalizedLabels() {
        for glance in [GlanceKind.idle, .running, .waiting, .error] {
            let en = L10n.t(glance.accessibilityKey, .en)
            let zh = L10n.t(glance.accessibilityKey, .zh)
            XCTAssertFalse(en.isEmpty)
            XCTAssertFalse(zh.isEmpty)
            XCTAssertNotEqual(en, zh, "\(glance) was not translated")
        }
    }

    func testSnapshotCarriesTheResolvedLabelSoTheViewNeedsNoLanguage() {
        let ctx = SnapshotBuilder.Context(
            nowMs: 1_700_000_000_000,
            terminal: .init(warpRunning: false, ttyHostRunning: false, anyTerminalInstalled: false),
            pathExists: { _ in false },
            lang: .zh
        )
        let result = SnapshotBuilder.build(.init(), previous: .init(), context: ctx)
        XCTAssertEqual(result.snapshot.accessibilityLabel, L10n.t(.a11yIdle, .zh))
    }
}
