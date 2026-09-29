import Darwin
import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest
@testable import PulseRespond

/// Files a sync tool may have planted: only regular files are read, and never
/// past the bound.
final class SafeReadTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-saferead-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testReadsARegularFileWithinTheBound() throws {
        let url = directory.appendingPathComponent("request.json")
        try Data("{}".utf8).write(to: url)
        XCTAssertEqual(SafeRead.regularFile(atPath: url.path, limit: 16), Data("{}".utf8))
    }

    func testRefusesAFileOverTheBound() throws {
        let url = directory.appendingPathComponent("big")
        try Data(repeating: 1, count: 17).write(to: url)
        XCTAssertNil(SafeRead.regularFile(atPath: url.path, limit: 16))
    }

    func testDoesNotFollowASymlinkToAnEndlessDevice() throws {
        let link = directory.appendingPathComponent("zero.json")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/dev/zero")
        XCTAssertNil(SafeRead.regularFile(atPath: link.path, limit: 256 * 1024))
        XCTAssertNil(SafeRead.regularFileTail(atPath: link.path, limit: 256 * 1024))
    }

    func testDoesNotBlockOnAFIFO() throws {
        let fifo = directory.appendingPathComponent("fifo.json")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let started = Date()
        XCTAssertNil(SafeRead.regularFile(atPath: fifo.path, limit: 256 * 1024))
        XCTAssertNil(SafeRead.regularFileTail(atPath: fifo.path, limit: 256 * 1024))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testTailKeepsTheNewestBytes() throws {
        let url = directory.appendingPathComponent("inbox.tsv")
        try Data("old\nnew\n".utf8).write(to: url)
        let tail = try XCTUnwrap(SafeRead.regularFileTail(atPath: url.path, limit: 4))
        XCTAssertEqual(tail.data, Data("new\n".utf8))
        XCTAssertTrue(tail.truncated)
        let whole = try XCTUnwrap(SafeRead.regularFileTail(atPath: url.path, limit: 64))
        XCTAssertEqual(whole.data, Data("old\nnew\n".utf8))
        XCTAssertFalse(whole.truncated)
    }

    func testAnEmptyRegularFileIsEmptyNotMissing() throws {
        let url = directory.appendingPathComponent("empty")
        try Data().write(to: url)
        XCTAssertEqual(SafeRead.regularFile(atPath: url.path, limit: 16), Data())
    }
}
