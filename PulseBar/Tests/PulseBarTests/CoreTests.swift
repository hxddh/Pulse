import Foundation
import Darwin
import AppKit
import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

// Core: the agent catalog, bounded IO, and the agent processes (libproc).

/// 12.0 · the roster is one table, and the table is whole.
final class AgentCatalogTests: XCTestCase {
    func testEveryAgentHasExactlyOneSpecInDeclarationOrder() {
        XCTAssertEqual(AgentCatalog.all.map(\.id), AgentID.allCases,
                       "catalog order is process-rule precedence; it must follow the enum")
        for id in AgentID.allCases {
            XCTAssertEqual(id.spec.id, id)
        }
    }

    func testMonogramsAreUnique() {
        let monograms = AgentCatalog.all.map(\.monogram)
        XCTAssertEqual(Set(monograms).count, monograms.count)
    }

    func testAliasesNeverShadowAnotherAgent() {
        var seen: [String: AgentID] = [:]
        for spec in AgentCatalog.all {
            for alias in spec.aliases {
                XCTAssertNil(AgentID(rawValue: alias), "\(alias) is already a raw value")
                XCTAssertNil(seen[alias], "\(alias) names two agents")
                seen[alias] = spec.id
            }
        }
    }

    func testEverySpellingResolves() {
        for spec in AgentCatalog.all {
            XCTAssertEqual(AgentCatalog.agent(named: spec.id.rawValue), spec.id)
            for alias in spec.aliases {
                XCTAssertEqual(AgentCatalog.agent(named: alias), spec.id)
            }
        }
        XCTAssertNil(AgentCatalog.agent(named: "not-an-agent"))
    }

    /// 24.0 (Exact): the owner's roster, and nothing else.
    func testRosterIsTheSevenSupportedAgents() {
        XCTAssertEqual(
            AgentID.allCases.map(\.rawValue),
            ["claude", "codex", "cursor", "pi", "gemini", "copilot", "opencode"]
        )
        XCTAssertEqual(Set(AgentID.priority), Set(AgentID.allCases))
        XCTAssertEqual(AgentCatalog.agent(named: "cursor-agent"), .cursor, "the CLI is Cursor")
        XCTAssertEqual(AgentCatalog.agent(named: "cursor_agent"), .cursor)
    }

    /// 24.0: Waiting by evidence — only a vendor hook that reports a block.
    func testWaitingComesOnlyFromAVendorBlockEvent() {
        let reportsBlocks: Set<AgentID> = [.claude, .gemini, .copilot, .opencode, .pi]
        for id in AgentID.allCases {
            XCTAssertEqual(id.waitingSource == .hooks, reportsBlocks.contains(id), id.rawValue)
        }
        // Codex's PermissionRequest fires before its own auto-review;
        // Cursor has no observe-only block event.
        XCTAssertEqual(AgentID.codex.waitingSource, .none)
        XCTAssertEqual(AgentID.cursor.waitingSource, .none)
        XCTAssertEqual(AgentID.waitingNoneAgents, [.codex, .cursor])
    }

    /// 24.0: every agent's hook is the vendor's documented, non-blocking one.
    func testEveryHookContractIsObserveOnly() {
        for spec in AgentCatalog.all {
            let names = spec.hooks.events.map(\.name)
            XCTAssertFalse(names.isEmpty, spec.id.rawValue)
            XCTAssertEqual(Set(names).count, names.count, "\(spec.id.rawValue) lists an event twice")
            for name in names {
                XCTAssertFalse(HookContract.gatingEvents.contains(name), "\(spec.id.rawValue) installs gating \(name)")
            }
            XCTAssertFalse(spec.hooks.path.hasPrefix("/"), "hook paths are home-relative")
            XCTAssertTrue(spec.hooks.path.hasPrefix(spec.hooks.home + "/"), "\(spec.id.rawValue) writes inside its vendor directory")
        }
        XCTAssertFalse(AgentID.codex.spec.hooks.events.contains { $0.name == "PermissionRequest" })
        XCTAssertFalse(AgentID.claude.spec.hooks.events.contains { $0.name == "PreToolUse" })
        XCTAssertFalse(AgentID.cursor.spec.hooks.events.contains { $0.name.hasPrefix("before") })
    }
}

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
    }

    func testDoesNotBlockOnAFIFO() throws {
        let fifo = directory.appendingPathComponent("fifo.json")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let started = Date()
        XCTAssertNil(SafeRead.regularFile(atPath: fifo.path, limit: 256 * 1024))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testAnEmptyRegularFileIsEmptyNotMissing() throws {
        let url = directory.appendingPathComponent("empty")
        try Data().write(to: url)
        XCTAssertEqual(SafeRead.regularFile(atPath: url.path, limit: 16), Data())
    }
}

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

/// Every brand source uses different transparent padding. The row should align
/// the visible mark, not the arbitrary file canvas.
final class AgentIconAlignmentTests: XCTestCase {
    func testEveryAgentIconHasAConsistentOpticalBox() {
        for agent in AgentID.allCases {
            guard let bounds = AgentIcon.alphaBounds(in: AgentIcon.image(for: agent)) else {
                return XCTFail("\(agent.displayName) icon rendered blank")
            }
            XCTAssertGreaterThanOrEqual(max(bounds.width, bounds.height), 49, agent.displayName)
            XCTAssertLessThanOrEqual(max(bounds.width, bounds.height), 54, agent.displayName)
            XCTAssertEqual(bounds.midX, 32, accuracy: 1.5, agent.displayName)
            XCTAssertEqual(bounds.midY, 32, accuracy: 1.5, agent.displayName)
        }
    }
}

/// 24.0 · agent processes, from the kernel's table: which command line is
/// which agent (shared with the hook's pid lookup), how a wrapper and its
/// child become one family, and the handles Focus reads off the parent
/// chain. Pure: the table is injected.
final class AgentProcessesTests: XCTestCase {
    func testEverySupportedAgentHasACanonicalProcessSignature() {
        let samples: [(AgentID, String)] = [
            (.claude, "/Users/me/.local/bin/claude"),
            (.codex, "/opt/homebrew/bin/codex app-server"),
            (.cursor, "/Applications/Cursor.app/Contents/MacOS/Cursor"),
            (.pi, "pi"),
            (.gemini, "/opt/homebrew/bin/node /opt/homebrew/bin/gemini"),
            (.copilot, "/opt/homebrew/bin/copilot"),
            (.opencode, "opencode"),
        ]

        XCTAssertEqual(samples.count, AgentID.allCases.count)
        XCTAssertEqual(Set(samples.map(\.0)), Set(AgentID.allCases))
        for (agent, argv) in samples {
            XCTAssertEqual(AgentProcesses.match(args: argv), agent, "\(agent.displayName): \(argv)")
        }
    }

    /// 24.0: the IDE and the `cursor-agent` CLI are one agent.
    func testCursorAgentCLIIsCursor() {
        XCTAssertEqual(AgentProcesses.match(args: "/Users/me/.local/bin/cursor-agent"), .cursor)
        XCTAssertEqual(AgentProcesses.match(args: "node /Users/me/.local/share/cursor-agent/versions/1/index.js"), .cursor)
    }

    func testShortAgentNamesDoNotReintroduceKnownFalsePositives() {
        let falsePositives = [
            "/usr/bin/pip install pulse",
            "/usr/local/bin/pip3",
            "/usr/sbin/pihole",
            "/System/Library/PrivateFrameworks/AMPDevices.framework/AMPDeviceDiscoveryAgent",
            "/opt/android/droidcam",
            "/opt/android/cmdline-tools",
        ]
        for argv in falsePositives {
            XCTAssertNil(AgentProcesses.match(args: argv), argv)
        }
        XCTAssertNil(
            AgentProcesses.match(args: "/Users/me/.local/bin/cursor-agent worker start --worker-dir /Users/me/code/Pulse"),
            "Cursor's persistent worker is infrastructure, not a session"
        )
        XCTAssertNil(
            AgentProcesses.match(args: "Cursor --type=renderer --app-path=/Applications/Cursor.app/Contents/Resources/app"),
            "Cursor helper processes must not inflate the process rows"
        )
    }

    private func proc(_ pid: Int32, _ ppid: Int32, _ args: String, tty: String = "") -> AgentProcesses.Proc {
        AgentProcesses.Proc(pid: pid, ppid: ppid, args: args, tty: tty, startedMs: 1_800_000_000_000)
    }

    /// `codex` (the npm wrapper) runs the native `codex`: one family, keyed
    /// by the top-most, holding both pids — the hook names the child.
    func testAWrapperAndItsChildAreOneFamily() throws {
        let table = [
            proc(100, 50, "/bin/zsh -l", tty: "ttys004"),
            proc(200, 100, "/opt/homebrew/bin/node /opt/homebrew/bin/codex"),
            proc(201, 200, "/opt/homebrew/lib/node_modules/@openai/codex/vendor/codex/codex"),
        ]
        let hits = AgentProcesses.hits(in: table, cwd: { _ in "/Users/me/code/app" })
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hit.agent, .codex)
        XCTAssertEqual(hit.pid, 200)
        XCTAssertEqual(hit.family, [200, 201])
        XCTAssertEqual(hit.tty, "ttys004", "the nearest real terminal up the chain")
        XCTAssertEqual(hit.cwd, "/Users/me/code/app")
    }

    func testTwoSessionsOfOneAgentAreTwoProcesses() {
        let table = [
            proc(300, 1, "/Users/me/.local/bin/claude"),
            proc(301, 1, "/Users/me/.local/bin/claude --resume"),
        ]
        XCTAssertEqual(AgentProcesses.hits(in: table, cwd: { _ in "" }).map(\.pid), [300, 301])
    }

    func testTheParentChainSaysWarpAndTheHostApp() throws {
        let warp = [
            proc(10, 1, "/Applications/Warp.app/Contents/MacOS/stable"),
            proc(11, 10, "/bin/zsh"),
            proc(12, 11, "/Users/me/.local/bin/claude"),
        ]
        XCTAssertTrue(try XCTUnwrap(AgentProcesses.hits(in: warp, cwd: { _ in "" }).first).viaWarp)
        let ide = [
            proc(20, 1, "/Applications/Visual Studio Code.app/Contents/MacOS/Electron"),
            proc(21, 20, "/bin/zsh"),
            proc(22, 21, "/opt/homebrew/bin/copilot"),
        ]
        XCTAssertEqual(try XCTUnwrap(AgentProcesses.hits(in: ide, cwd: { _ in "" }).first).hostApp, .vsCode)
    }

    func testWorkingDirectoryFilterRejectsInfrastructurePaths() {
        XCTAssertEqual(AgentProcesses.usefulWorkingDirectory("/"), "")
        XCTAssertEqual(AgentProcesses.usefulWorkingDirectory("/Applications/Pulse.app"), "")
        XCTAssertEqual(AgentProcesses.usefulWorkingDirectory(FileManager.default.homeDirectoryForCurrentUser.path), "")
        XCTAssertEqual(AgentProcesses.usefulWorkingDirectory("/Users/me/code/Pulse"), "/Users/me/code/Pulse")
        XCTAssertEqual(AgentProcesses.usefulWorkingDirectory("/Users/me/Documents/Work (old)"), "/Users/me/Documents/Work (old)")
    }

    func testLivenessNeedsNoSignal() {
        XCTAssertTrue(AgentProcesses.isAlive(ProcessInfo.processInfo.processIdentifier))
        XCTAssertFalse(AgentProcesses.isAlive(999_999))
        XCTAssertFalse(AgentProcesses.isAlive(0))
    }

    /// The real table: this test process is in it, and it is no agent.
    func testTheScanReadsTheTableAndFindsNoAgentInATestRunner() throws {
        let table = try XCTUnwrap(AgentProcesses.processTable())
        XCTAssertTrue(table.contains { $0.pid == ProcessInfo.processInfo.processIdentifier })
    }
}

/// Is the prompt already in front of the user? The hook receiver records the
/// answer in attention column 8 (`front`), so a blocked prompt already on
/// screen gets no banner. The walk is pure: the parent lookup is injected.
final class PromptVisibilityTests: XCTestCase {

    // MARK: - Is the prompt in front of the user?

    /// app 4321 → shell 900 → agent 500 → this hook 100.
    private let chain: [Int32: Int32] = [100: 500, 500: 900, 900: 4321, 4321: 1]

    func testTheFrontmostTerminalIsRecognisedThroughTheWholeChain() {
        XCTAssertEqual(
            PromptVisibility.isAncestor(4321, of: 100, parentOf: { self.chain[$0] }),
            true
        )
    }

    func testAnUnrelatedFrontmostAppIsNotAnAncestor() {
        // Zoom is in front; the agent's terminal is somewhere behind it.
        XCTAssertEqual(
            PromptVisibility.isAncestor(7777, of: 100, parentOf: { self.chain[$0] }),
            false,
            "the walk reached launchd without meeting it"
        )
    }

    func testADetachedChainReachingLaunchdIsUnknownNotFalse() {
        // hook 100 → agent 500 → shell 900 → tmux server 950 → launchd.
        // The terminal the user reads it in is not on this chain at all, so
        // reaching launchd proves nothing about whether they are looking.
        let tmux: [Int32: Int32] = [100: 500, 500: 900, 900: 950, 950: 1]
        XCTAssertNil(
            PromptVisibility.isAncestor(4321, of: 100, parentOf: { tmux[$0] }, isApp: { _ in false })
        )
    }

    func testAChainThroughAnAppReachingLaunchdIsFalse() {
        XCTAssertEqual(
            PromptVisibility.isAncestor(7777, of: 100, parentOf: { self.chain[$0] }, isApp: { $0 == 4321 }),
            false
        )
    }

    func testAProcessIsItsOwnAncestor() {
        XCTAssertEqual(
            PromptVisibility.isAncestor(100, of: 100, parentOf: { self.chain[$0] }),
            true
        )
    }

    func testAnUnreadableLinkIsUnknownNotFalse() {
        // "Could not tell" must never be spent as proof the user is looking
        // elsewhere — that would freeze an agent in front of a present user.
        XCTAssertNil(PromptVisibility.isAncestor(4321, of: 100, parentOf: { _ in nil }))
    }

    func testACycleTerminatesAsUnknown() {
        let loop: [Int32: Int32] = [100: 200, 200: 300, 300: 100]
        XCTAssertNil(PromptVisibility.isAncestor(4321, of: 100, parentOf: { loop[$0] }))
    }

    func testAChainTooLongToBeRealIsUnknown() {
        // Every parent is one lower, so the walk never reaches 1 and never
        // repeats: only the depth bound can stop it.
        XCTAssertNil(
            PromptVisibility.isAncestor(4321, of: 5000, parentOf: { $0 - 1 })
        )
    }

    func testNoFrontmostAppMeansUnknown() {
        XCTAssertNil(
            PromptVisibility.promptIsFrontmost(
                selfPID: 100, frontmost: nil, parentOf: { self.chain[$0] }
            )
        )
        XCTAssertNil(
            PromptVisibility.promptIsFrontmost(
                selfPID: 100, frontmost: 0, parentOf: { self.chain[$0] }
            )
        )
    }

    func testPromptVisibilityUsesTheChain() {
        XCTAssertEqual(
            PromptVisibility.promptIsFrontmost(
                selfPID: 100, frontmost: 4321, parentOf: { self.chain[$0] }, isApp: { $0 == 4321 }
            ),
            true
        )
        XCTAssertEqual(
            PromptVisibility.promptIsFrontmost(
                selfPID: 100, frontmost: 7777, parentOf: { self.chain[$0] }, isApp: { $0 == 4321 }
            ),
            false
        )
    }

    /// The real reader, against this very process. It must not crash, must not
    /// hang, and must agree with `getppid()`.
    func testTheRealParentLookupAgreesWithTheKernel() throws {
        let parent = try XCTUnwrap(PromptVisibility.parentPID(of: getpid()))
        XCTAssertEqual(parent, getppid())
    }
}

/// 2.3 — the defects a fresh audit at the 2.2 baseline turned up.
///
/// Each of these is a place where the code said something it had not
/// measured, dropped work it had been asked to do, or let a click reach
/// nothing without saying so.
final class PrivateFileTests: XCTestCase {
    // MARK: D-4 · the files carrying the user's words are private

    func testAPrivateFileIsSixHundredBeforeItsBytesExist() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-private-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("ledger.json")
        var temporaryModes: [Int] = []
        PrivateFile.inspectTemporaryFileForTesting = { path in
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            if let mode = (attrs?[.posixPermissions] as? NSNumber)?.intValue {
                temporaryModes.append(mode)
            }
        }
        defer {
            PrivateFile.inspectTemporaryFileForTesting = nil
            try? FileManager.default.removeItem(at: directory)
        }

        XCTAssertTrue(PrivateFile.write(Data("hello".utf8), to: url))
        XCTAssertEqual(temporaryModes, [0o600], "0600 at creation, not after the bytes are visible")
        let published = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((published[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path),
            ["ledger.json"],
            "the temporary file is renamed into place, never left behind"
        )
    }

    func testAnOlderWorldReadableFileIsBroughtDown() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-tighten-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("attention.tsv")
        // What every install made before this rule has on disk.
        XCTAssertTrue(FileManager.default.createFile(
            atPath: url.path,
            contents: Data("# pulse-attention v2\n".utf8),
            attributes: [.posixPermissions: 0o644]
        ))

        let fd = url.path.withCString { open($0, O_RDWR) }
        XCTAssertGreaterThanOrEqual(fd, 0)
        PrivateFile.tighten(fileDescriptor: fd)
        close(fd)

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}

/// 0.99 Quiet Data — what Pulse writes down, and whether it says so.
///
/// 0.90–0.97 made the display honest and 0.98 made the collector honest. These
/// cover the surface neither of them touched: the bytes that outlive the scan.
final class DebugLogKeyTests: XCTestCase {
    // MARK: - The debug log keeps the project name off disk

    /// A row key used to fall back to the workspace leaf, so it could be a
    /// directory name from the user's disk (23.0 hashes it — `RowIdentity`).
    func testDebugLogKeyDropsTheProjectNameButStaysCorrelatable() {
        let key = DebugLog.key("claude|SecretProject")
        XCTAssertFalse(key.contains("SecretProject"))
        XCTAssertTrue(key.hasPrefix("claude|"))
        XCTAssertEqual(key, DebugLog.key("claude|SecretProject"), "stable across calls")
        XCTAssertNotEqual(key, DebugLog.key("claude|OtherProject"))
    }

    func testDebugLogKeyLeavesAKeylessStringAlone() {
        XCTAssertEqual(DebugLog.key("manual"), "manual")
    }
}

/// 0.99.2 Live Wire — the rest of the path 0.99.1 只修了一半.
///
/// 0.99.1 fixed how `lsof` output is parsed. These cover what happens to that
/// output afterwards: the gate that decided whether to keep it at all, the
/// subprocess wrapper underneath, and the code downstream that had never once
/// run with a working directory in hand.
final class ProcessTerminationTests: XCTestCase {
    // MARK: - The subprocess wrapper under it

    /// `lsof` on a dead network mount is the textbook child that ignores
    /// SIGTERM. The wrapper must come back with a verdict rather than asking a
    /// still-running process for an exit status it does not have.
    func testAChildThatIgnoresSigtermStillReturnsAVerdict() throws {
        let result = try XCTUnwrap(
            ProcessIO.run(
                executable: "/bin/sh",
                arguments: ["-c", "trap '' TERM; sleep 5"],
                timeout: 0.4
            ),
            "a timeout is a result, not a missing answer"
        )
        XCTAssertTrue(result.timedOut)
        XCTAssertNotEqual(result.status, 0, "a killed child never exited cleanly")
    }

    func testAnOrdinaryChildKeepsItsExitStatus() throws {
        let ok = try XCTUnwrap(
            ProcessIO.run(executable: "/bin/sh", arguments: ["-c", "printf hello"], timeout: 5)
        )
        XCTAssertFalse(ok.timedOut)
        XCTAssertEqual(ok.status, 0)
        XCTAssertEqual(String(data: ok.stdout, encoding: .utf8), "hello")

        let failed = try XCTUnwrap(
            ProcessIO.run(executable: "/bin/sh", arguments: ["-c", "exit 3"], timeout: 5)
        )
        XCTAssertFalse(failed.timedOut)
        XCTAssertEqual(failed.status, 3, "a non-zero exit is information, not a failure to run")
    }
}
