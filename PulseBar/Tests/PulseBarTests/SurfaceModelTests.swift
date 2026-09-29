import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest
@testable import PulseRespond

/// 15.0 · Witness — the product's rules asserted on the surface values
/// `SurfaceCapture` photographs, not on the store behind them. 22.0 removed
/// the Workbench's Mission board and working-copy card; what remains are the
/// tray row, the cards under it, the Why card and the self-check.
final class SurfaceModelTests: XCTestCase {

    // MARK: - The fixture list the capture script reads

    func testTheCaptureScriptsNamesAreTheFixtures() {
        XCTAssertEqual(SurfaceFixtures.all(lang: .en).map(\.name), SurfaceFixtures.names)
        XCTAssertEqual(Set(SurfaceFixtures.names).count, SurfaceFixtures.names.count)
    }

    // MARK: - Allow only beside the full request

    func testNoRespondFixtureOffersAllowWithoutTheWholeRequest() {
        for lang in [ResolvedLanguage.en, .zh] {
            for fixture in SurfaceFixtures.all(lang: lang) {
                guard case .asks(let model) = fixture.value, let respond = model.respond else { continue }
                if respond.canOfferAllow {
                    XCTAssertFalse(respond.fullRequest.isEmpty, fixture.name)
                }
            }
            XCTAssertFalse(SurfaceFixtures.cardRespond(lang: lang, truncated: true).respond?.canOfferAllow ?? true)
        }
    }

    // MARK: - Both languages

    func testEveryFixtureSpeaksBothLanguages() {
        XCTAssertEqual(SurfaceFixtures.all(lang: .zh).map(\.name), SurfaceFixtures.names)
        XCTAssertNotEqual(SurfaceFixtures.cardRespond(lang: .zh).respond?.deny,
                          SurfaceFixtures.cardRespond(lang: .en).respond?.deny)
    }
}
