import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

/// 15.0 · Witness — the product's rules asserted on the surface values
/// `SurfaceCapture` photographs, not on the store behind them. 23.0: the
/// tray row, header, notice and filter, the detail page, Settings,
/// Diagnostics and the self-check.
final class SurfaceModelTests: XCTestCase {

    // MARK: - The fixture list the capture script reads

    func testTheCaptureScriptsNamesAreTheFixtures() {
        XCTAssertEqual(SurfaceFixtures.all(lang: .en).map(\.name), SurfaceFixtures.names)
        XCTAssertEqual(Set(SurfaceFixtures.names).count, SurfaceFixtures.names.count)
    }

    // MARK: - Both languages

    private func firstMenuTitle(_ lang: ResolvedLanguage) -> String? {
        guard case .row(let model, _) = SurfaceFixtures.all(lang: lang).first?.value else { return nil }
        return model.menu.first?.title
    }

    func testEveryFixtureSpeaksBothLanguages() {
        XCTAssertEqual(SurfaceFixtures.all(lang: .zh).map(\.name), SurfaceFixtures.names)
        XCTAssertNotNil(firstMenuTitle(.en))
        XCTAssertNotEqual(firstMenuTitle(.zh), firstMenuTitle(.en))
    }
}
