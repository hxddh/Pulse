import XCTest
import AppKit
@testable import PulseBar

/// VoiceOver must speak the interface language, not English.
final class AccessibilityLocalizationTests: XCTestCase {
    func testGlanceStatesHaveDistinctLocalizedLabels() {
        for glance in [GlanceKind.idle, .running, .stalled, .waiting, .error] {
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
            terminal: .init(warpRunning: false, ttyHostRunning: false),
            lang: .zh
        )
        let result = SnapshotBuilder.build(.init(), previous: .init(), context: ctx)
        XCTAssertEqual(result.snapshot.accessibilityLabel, L10n.t(.a11yIdle, .zh))
    }

    func testStatusBarIconsKeepTheirTrafficLightColour() {
        var rgba: Set<String> = []
        for glance in [GlanceKind.idle, .running, .stalled, .waiting] {
            let icon = PulseBrand.statusBarIcon(for: glance)
            XCTAssertFalse(icon.isTemplate, "\(glance) would be flattened to monochrome")
            XCTAssertEqual(icon.size, NSSize(width: 16, height: 16))
            let color = PulseBrand.statusColor(for: glance)
                .usingColorSpace(.deviceRGB) ?? PulseBrand.statusColor(for: glance)
            rgba.insert(
                String(
                    format: "%.3f,%.3f,%.3f,%.3f",
                    color.redComponent,
                    color.greenComponent,
                    color.blueComponent,
                    color.alphaComponent
                )
            )
        }
        XCTAssertEqual(rgba.count, 4, "red, green, grey and orange must remain distinct")
    }
}
