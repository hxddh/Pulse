import Foundation
import XCTest
@testable import PulseBar

final class SingleInstanceGuardTests: XCTestCase {
    func testTwoCopiesShareOneOwnerAcrossBundlePaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-single-instance-\(UUID().uuidString)", isDirectory: true)
        let lock = root.appendingPathComponent("Pulse.instance.lock")
        defer { try? FileManager.default.removeItem(at: root) }

        var owner: SingleInstanceGuard? = SingleInstanceGuard(lockURL: lock)
        let contender = SingleInstanceGuard(lockURL: lock)
        XCTAssertTrue(owner?.acquire() == true)
        XCTAssertFalse(contender.acquire(), "a second packaged copy must not own another status item")

        owner = nil
        XCTAssertTrue(contender.acquire(), "the kernel lock must recover when the owner exits")
    }
}
