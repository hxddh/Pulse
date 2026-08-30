import XCTest
@testable import PulseBar

final class ProcessIOTests: XCTestCase {
    func testLargeStdoutAndStderrAreDrainedWithoutDeadlock() {
        let result = ProcessIO.run(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "yes x | head -c 200000; yes y | head -c 200000 >&2",
            ],
            timeout: 2.0
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.status, 0)
        XCTAssertFalse(result?.timedOut ?? true)
        XCTAssertEqual(result?.stdout.count, 200000)
        XCTAssertEqual(result?.stderr.count, 200000)
    }

    func testHungProcessIsTerminatedByDeadline() {
        let result = ProcessIO.run(
            executable: "/bin/sleep",
            arguments: ["5"],
            timeout: 0.1
        )

        XCTAssertNotNil(result)
        XCTAssertTrue(result?.timedOut ?? false)
    }

    func testCurrentDirectoryIsSetWithoutAQuotedCdPrefix() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse process cwd \(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = ProcessIO.run(
            executable: "/bin/pwd",
            arguments: [],
            currentDirectory: directory.path,
            timeout: 1
        )
        let reportedPath = String(decoding: result?.stdout ?? Data(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(result?.status, 0)
        XCTAssertEqual(URL(fileURLWithPath: reportedPath).lastPathComponent, directory.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reportedPath))
    }
}
