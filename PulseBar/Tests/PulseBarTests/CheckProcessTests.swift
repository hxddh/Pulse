import XCTest
@testable import PulseBar

/// A user's acceptance check: output kept from the end, and nothing it
/// started outlives it.
final class CheckProcessTests: XCTestCase {
    func testOutputKeepsTheTailWhereTheVerdictIs() throws {
        let result = try XCTUnwrap(ProcessIO.runCheck(
            command: "i=0; while [ $i -lt 2000 ]; do echo noise-$i; i=$((i+1)); done; echo FINAL-SUMMARY",
            currentDirectory: NSTemporaryDirectory(),
            timeout: 30,
            outputLimit: 1024
        ))
        XCTAssertEqual(result.status, 0)
        XCTAssertLessThanOrEqual(result.stdout.count, 1024)
        XCTAssertTrue(String(decoding: result.stdout, as: UTF8.self).contains("FINAL-SUMMARY"))
    }

    func testExitStatusAndStderrAreReported() throws {
        let result = try XCTUnwrap(ProcessIO.runCheck(
            command: "echo broken >&2; exit 3",
            currentDirectory: NSTemporaryDirectory(),
            timeout: 30,
            outputLimit: 1024
        ))
        XCTAssertEqual(result.status, 3)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "broken\n")
    }

    func testRunsInTheRequestedDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-check-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try XCTUnwrap(ProcessIO.runCheck(
            command: "pwd -P", currentDirectory: directory.path, timeout: 30, outputLimit: 1024
        ))
        // `pwd -P` prints /private/var/…; Foundation spells the same place
        // /var/…. Compare the directories, not the spellings.
        let reported = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        XCTAssertEqual(
            URL(fileURLWithPath: reported).resolvingSymlinksInPath().path,
            directory.resolvingSymlinksInPath().path
        )
    }

    func testTimeoutKillsTheWholeGroupNotOnlyTheShell() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-check-orphan-\(UUID())")
        defer { try? FileManager.default.removeItem(at: marker) }
        // The background child would write the marker after the deadline if
        // it survived the shell.
        let started = Date()
        let result = try XCTUnwrap(ProcessIO.runCheck(
            command: "(sleep 3; touch '\(marker.path)') & sleep 30",
            currentDirectory: NSTemporaryDirectory(),
            timeout: 1,
            outputLimit: 1024
        ))
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        Thread.sleep(forTimeInterval: 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testWaitStatusDecoding() {
        XCTAssertEqual(ProcessIO.decodeWaitStatus(0), 0)
        XCTAssertEqual(ProcessIO.decodeWaitStatus(3 << 8), 3)
        XCTAssertEqual(ProcessIO.decodeWaitStatus(9), 137)
    }
}
