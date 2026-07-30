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

    func testStatusBarIconsKeepTheirTrafficLightColourAcrossAppearances() throws {
        let original = NSAppearance.current
        defer { NSAppearance.current = original }

        let appearances: [NSAppearance.Name] = [
            .aqua,
            .darkAqua,
            .accessibilityHighContrastAqua,
            .accessibilityHighContrastDarkAqua,
        ]
        for appearanceName in appearances {
            NSAppearance.current = try XCTUnwrap(NSAppearance(named: appearanceName))
            var rgba: Set<String> = []
            for glance in [GlanceKind.idle, .running, .stalled, .waiting] {
                let icon = PulseBrand.statusBarIcon(for: glance)
                XCTAssertFalse(
                    icon.isTemplate,
                    "\(glance) would be flattened to monochrome in \(appearanceName.rawValue)"
                )
                XCTAssertEqual(icon.size, NSSize(width: 16, height: 16))
                let bitmap = try XCTUnwrap(
                    icon.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
                )
                var visiblePixels = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide
                    where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.08 {
                        visiblePixels += 1
                    }
                }
                XCTAssertGreaterThan(
                    visiblePixels,
                    8,
                    "\(glance) disappeared in \(appearanceName.rawValue)"
                )

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
            XCTAssertEqual(
                rgba.count,
                4,
                "red, green, grey and orange merged in \(appearanceName.rawValue)"
            )
        }
    }
}
