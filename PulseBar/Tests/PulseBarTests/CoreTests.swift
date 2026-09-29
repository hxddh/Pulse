import Foundation
import Darwin
import AppKit
import XCTest
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

// Core: the agent catalog, bounded IO, processes and the probe's parsers.

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

    func testOnlyCursorAgentHasNoCollectorOfItsOwn() {
        let without = AgentCatalog.all.filter { $0.harvestRoots.isEmpty }.map(\.id)
        XCTAssertEqual(without, [.cursorAgent])
    }

    func testTranscriptPolicyKeepsPiReadingIdleFiles() {
        XCTAssertFalse(AgentID.pi.spec.transcripts.skipsStaleFiles)
        XCTAssertTrue(AgentID.pi.spec.transcripts.allowsBoundedLargeFiles)
        XCTAssertTrue(AgentID.claude.spec.transcripts.skipsStaleFiles)
        XCTAssertFalse(AgentID.cursor.spec.transcripts.allowsBoundedLargeFiles)
    }

    /// 23.0: an agent whose on-disk format is `unverified` in
    /// docs/vendor-formats.json does not infer Waiting from its harvest.
    func testUnverifiedFormatsInferNoWaiting() {
        let unverified: [AgentID] = [
            .cursor, .cursorAgent, .amp, .amazonQ, .cascade, .windsurf,
            .augment, .zedAgent, .kiro, .droid, .commandCode,
        ]
        for id in unverified {
            XCTAssertEqual(id.waitingSource, .none, id.rawValue)
        }
    }

    // MARK: - 12.1 · the walk is data

    func testEveryCollectorHasAPlaceOnTheFixtureWall() {
        // Agents with a hand-written fixture in NativeHarvestSelfTest, plus
        // Cursor Agent, which has no collector of its own.
        let handWritten: Set<AgentID> = [.cursor, .cursorAgent, .grok, .pi, .opencode, .warpAgent, .goose]
        for spec in AgentCatalog.all where !handWritten.contains(spec.id) {
            XCTAssertNotNil(spec.walk.fixturePath, "\(spec.id.rawValue) has no generic fixture")
        }
    }

    func testDatabaseAdaptersAreWhereTheyWere() {
        XCTAssertEqual(AgentID.cursor.spec.walk.database, .cursor)
        XCTAssertEqual(AgentID.opencode.spec.walk.database, .openCode)
        XCTAssertEqual(AgentID.warpAgent.spec.walk.database, .warp)
        XCTAssertEqual(AgentID.pi.spec.walk.database, .pi)
        XCTAssertEqual(AgentID.goose.spec.walk.database, .goose)
        XCTAssertEqual(AgentID.grok.spec.walk.database, .grok)
        // 20.0: Goose's sessions.db and Kilo 7.x's OpenCode-schema kilo.db.
        XCTAssertEqual(AgentID.kilo.spec.walk.database, .openCode)
        XCTAssertEqual(AgentCatalog.all.filter { $0.walk.database != nil }.count, 7)
        XCTAssertTrue(DatabaseAdapter.pi.runsAfterTranscripts)
        XCTAssertFalse(DatabaseAdapter.pi.failsOnUnreadableFile)
        XCTAssertTrue(DatabaseAdapter.cursor.extensions.contains("vscdb"))
    }

    func testTranscriptSelection() {
        XCTAssertFalse(AgentID.grok.spec.walk.transcripts.admits("/users/me/.grok/sessions/a.jsonl"))
        XCTAssertTrue(AgentID.pi.spec.walk.transcripts.admits("/users/me/.pi/agent/sessions/x.jsonl"))
        XCTAssertFalse(AgentID.pi.spec.walk.transcripts.admits("/users/me/.pi/context-mode/cache.json"))
        XCTAssertFalse(AgentID.gemini.spec.walk.transcripts.admits("/users/me/.gemini/tmp/x/src/main.json"))
        XCTAssertTrue(AgentID.claude.spec.walk.transcripts.admits("/anything"))
    }

    func testReadWindowsKeepTheirVendorSizes() {
        XCTAssertEqual(AgentID.codex.spec.walk.windowBytes, 8_000_000)
        XCTAssertEqual(AgentID.codex.spec.walk.deadlineSeconds, 1.2)
        XCTAssertEqual(AgentID.pi.spec.walk.windowBytes, 496_000)
        XCTAssertEqual(AgentID.pi.spec.walk.headBytes, 96_000)
        XCTAssertEqual(AgentID.claude.spec.walk.windowBytes, 1_000_000)
        XCTAssertEqual(AgentID.grok.spec.walk.maxFileBytes, 16 * 1024 * 1024)
        // 20.0: Goose is read from its database, not transcripts.
        XCTAssertEqual(AgentCatalog.all.filter(\.walk.dropsContinuationPrompts).count, 10)
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

/// `ps` parsing and the harvest-skip fingerprint.
final class ProcessProbeTests: XCTestCase {
    func testEverySupportedAgentHasACanonicalProcessSignature() {
        let samples: [(AgentID, String)] = [
            (.claude, "/Users/me/.local/bin/claude"),
            (.codex, "/opt/homebrew/bin/codex app-server"),
            (.cursor, "/Applications/Cursor.app/Contents/MacOS/Cursor"),
            (.cursorAgent, "/Users/me/.local/bin/cursor-agent"),
            (.antigravity, "/Users/me/.local/bin/agy"),
            (.grok, "/Users/me/.grok/bin/grok"),
            (.pi, "pi"),
            (.amp, "amp"),
            (.aider, "aider"),
            (.gemini, "gemini"),
            (.copilot, "/opt/homebrew/bin/copilot"),
            (.opencode, "opencode"),
            (.goose, "goose"),
            (.openhands, "openhands"),
            (.cline, "/tmp/saoudrizwan.claude-dev/cline"),
            (.roo, "roo"),
            (.continue_, "continue"),
            (.amazonQ, "/opt/homebrew/bin/q chat"),
            (.cascade, "/tmp/cascade-agent"),
            (.windsurf, "/Applications/Windsurf.app/Contents/MacOS/Windsurf"),
            (.augment, "augment"),
            (.zedAgent, "/tmp/zed-agent"),
            (.trae, "/tmp/trae-agent"),
            (.warpAgent, "/tmp/warp-agent"),
            (.devin, "devin"),
            (.kiro, "kiro"),
            (.junie, "junie"),
            (.kilo, "kilo"),
            (.replit, "replit"),
            (.droid, "droid"),
            (.commandCode, "cmd"),
            (.kimi, "kimi"),
            (.zcode, "/Applications/ZCode.app/Contents/MacOS/ZCode"),
        ]

        XCTAssertEqual(samples.count, AgentID.allCases.count)
        XCTAssertEqual(Set(samples.map(\.0)), Set(AgentID.allCases))
        for (agent, argv) in samples {
            XCTAssertEqual(ProcessProbe.match(args: argv), agent, "\(agent.displayName): \(argv)")
        }
    }

    func testProcessMatchExplainsRuleWithoutKeepingArgv() {
        XCTAssertEqual(
            ProcessProbe.matchEvidence(args: "/Applications/Antigravity.app/Contents/MacOS/Antigravity")?.evidence,
            .pathSignature
        )
        XCTAssertEqual(ProcessProbe.matchEvidence(args: "amp")?.evidence, .executable)
        XCTAssertEqual(
            ProcessProbe.match(args: "⌘ Command Code · rustji COLORTERM=truecolor"),
            .commandCode,
            "process titles rewritten by Node must still identify Command Code"
        )
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
            XCTAssertNil(ProcessProbe.match(args: argv), argv)
        }
        XCTAssertNil(
            ProcessProbe.match(args: "/Users/me/.local/bin/cursor-agent worker start --worker-dir /Users/me/code/Pulse"),
            "Cursor's persistent worker is infrastructure until a composer session provides activity"
        )
        XCTAssertNil(
            ProcessProbe.match(args: "Cursor --type=renderer --app-path=/Applications/Cursor.app/Contents/Resources/app"),
            "Cursor helper processes must not inflate the GUI fallback count"
        )
    }

    func testParsesProcessElapsedTimeWithoutCallingItSessionAge() {
        XCTAssertEqual(ProcessProbe.parseElapsed("04:12"), 252)
        XCTAssertEqual(ProcessProbe.parseElapsed("02:04:12"), 7_452)
        XCTAssertEqual(ProcessProbe.parseElapsed("3-02:04:12"), 266_652)
        XCTAssertEqual(ProcessProbe.parseElapsed("not-a-time"), 0)
    }

    func testSignatureIsOrderIndependent() {
        let a = ProcessProbe.Hit(id: .claude, count: 1, viaWarp: false, pid: 10)
        let b = ProcessProbe.Hit(id: .codex, count: 2, viaWarp: false, pid: 20)
        XCTAssertEqual(ProcessProbe.signature([a, b]), ProcessProbe.signature([b, a]))
    }

    func testSignatureChangesWhenTheAgentSetChanges() {
        let a = ProcessProbe.Hit(id: .claude, count: 1, viaWarp: false, pid: 10)
        let more = ProcessProbe.Hit(id: .claude, count: 2, viaWarp: false, pid: 10)
        XCTAssertNotEqual(ProcessProbe.signature([a]), ProcessProbe.signature([more]))
        XCTAssertNotEqual(ProcessProbe.signature([a]), ProcessProbe.signature([]))
    }

    func testWorkingDirectoryParserKeepsEachPidAttachedToItsCwd() {
        let output = """
        p101
        fcwd
        n/Users/me/code/Pulse
        p202
        fcwd
        n/Users/me/code/Other
        """
        XCTAssertEqual(ProcessProbe.parseWorkingDirectories(output)[101], "/Users/me/code/Pulse")
        XCTAssertEqual(ProcessProbe.parseWorkingDirectories(output)[202], "/Users/me/code/Other")
    }

    /// The shape `lsof` actually emits when the `f` field is not requested.
    ///
    /// This is the regression that shipped: the fixture above was written by
    /// hand with an `fcwd` line, the parser required it, and `-Fpn` never sent
    /// one — so every real lookup returned nothing, the caller read that as
    /// "lsof unavailable", and no process row ever recovered a workspace.
    func testWorkingDirectoryParserHandlesOutputWithoutTheFieldDescriptor() {
        let output = """
        p4432
        n/Users/me/code/Pulse
        """
        XCTAssertEqual(ProcessProbe.parseWorkingDirectories(output)[4432], "/Users/me/code/Pulse")
    }

    /// A process whose cwd lsof could not read must not inherit the next
    /// process's path.
    func testWorkingDirectoryParserDoesNotLeakAPathToTheNextPid() {
        let output = """
        p101
        p202
        n/Users/me/code/Other
        """
        XCTAssertNil(ProcessProbe.parseWorkingDirectories(output)[101])
        XCTAssertEqual(ProcessProbe.parseWorkingDirectories(output)[202], "/Users/me/code/Other")
    }

    /// With the `f` field present, a non-cwd descriptor's path is not a cwd.
    func testWorkingDirectoryParserIgnoresNonCwdDescriptors() {
        let output = """
        p101
        f3
        n/Users/me/some/open/file.txt
        fcwd
        n/Users/me/code/Pulse
        """
        XCTAssertEqual(ProcessProbe.parseWorkingDirectories(output)[101], "/Users/me/code/Pulse")
    }

    func testWorkingDirectoryFilterRejectsInfrastructurePaths() {
        XCTAssertEqual(ProcessProbe.usefulWorkingDirectory("/"), "")
        XCTAssertEqual(ProcessProbe.usefulWorkingDirectory("/Applications/Pulse.app"), "")
        XCTAssertEqual(ProcessProbe.usefulWorkingDirectory("/Users/me/code/Pulse"), "/Users/me/code/Pulse")
    }
}

/// The process table, parsed. 23.0 dropped the CPU and memory columns
/// (nothing rendered them); what is left identifies an agent process.
final class ProcessProbeParseTests: XCTestCase {
    /// Real `ps -axo pid=,ppid=,tty=,etime=,args=` output, columns padded the
    /// way `ps` pads them.
    private let psOutput = """
          4432   4401 ttys003      02:04:12 node /Users/me/.local/bin/claude --model opus --resume
          9001      1 ??         5-00:00:00 /Applications/Pulse.app/Contents/MacOS/Pulse --serve
          3 fields only
        """

    func testProcessLinesKeepArgumentsWhole() {
        let procs = ProcessProbe.parseProcessLines(psOutput)
        XCTAssertEqual(procs.count, 2, "a line without every column is dropped, not half-read")

        let claude = procs[0]
        XCTAssertEqual(claude.pid, 4432)
        XCTAssertEqual(claude.ppid, 4401)
        XCTAssertEqual(claude.tty, "ttys003")
        XCTAssertEqual(claude.elapsedSeconds, 7_452, accuracy: 0.0001)
        XCTAssertEqual(
            claude.args,
            "node /Users/me/.local/bin/claude --model opus --resume",
            "args is the last column precisely because it contains spaces"
        )

        let pulse = procs[1]
        XCTAssertEqual(pulse.pid, 9001)
        XCTAssertEqual(pulse.tty, "??")
        XCTAssertEqual(pulse.elapsedSeconds, 432_000, accuracy: 0.0001)
        XCTAssertEqual(pulse.args, "/Applications/Pulse.app/Contents/MacOS/Pulse --serve")
    }

    /// The fingerprint answers "did the process set change" — the same set
    /// twice is the same string.
    func testTheFingerprintIsTheProcessSet() {
        let one = ProcessProbe.Hit(id: .claude, count: 1, viaWarp: false, pid: 10)
        let two = ProcessProbe.Hit(id: .codex, count: 2, viaWarp: false, pid: 11)
        XCTAssertEqual(ProcessProbe.signature([one, two]), ProcessProbe.signature([two, one]))
        XCTAssertNotEqual(ProcessProbe.signature([one]), ProcessProbe.signature([one, two]))
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

/// 0.99.2 Live Wire — the rest of the path 0.99.1 只修了一半.
///
/// 0.99.1 fixed how `lsof` output is parsed. These cover what happens to that
/// output afterwards: the gate that decided whether to keep it at all, the
/// subprocess wrapper underneath, and the code downstream that had never once
/// run with a working directory in hand.
final class LsofBackoffTests: XCTestCase {
    // MARK: - lsof exits 1 while still answering

    /// Measured, not assumed: with one live and one dead PID, `lsof -Ffpn -a
    /// -d cwd -p <live>,<dead>` prints the live process and exits **1**.
    /// Requiring status 0 threw the live answer away.
    func testAnExitCodeOfOneStillCarriesEveryResolvedProcess() {
        let output = """
        p101
        fcwd
        n/Users/me/code/Pulse
        """
        let resolved = ProcessProbe.workingDirectories(
            from: ProcessProbe.Invocation(stdout: output, status: 1)
        )
        XCTAssertEqual(resolved[101], "/Users/me/code/Pulse", "status 1 is not a reason to discard a path")

        // Same bytes, clean exit — the status must make no difference at all.
        XCTAssertEqual(
            resolved,
            ProcessProbe.workingDirectories(
                from: ProcessProbe.Invocation(stdout: output, status: 0)
            )
        )
        XCTAssertTrue(ProcessProbe.workingDirectories(from: nil).isEmpty)
    }

    /// The batch is one PID per agent. A finished agent must not cost every
    /// other agent five minutes of workspace.
    func testADeadProcessAloneDoesNotArmTheBackoff() {
        let deadPid = 999_999
        XCTAssertFalse(ProcessProbe.processExists(deadPid), "pid must be absent for this test")
        XCTAssertFalse(
            ProcessProbe.shouldBackOff(
                ProcessProbe.Invocation(stdout: "", status: 1), pids: [deadPid]
            ),
            "an exited process explains the silence by itself"
        )
    }

    /// Silence about a process that is demonstrably alive is the case backoff
    /// exists for — a denied or unusable lookup.
    func testSilenceAboutALiveProcessStillArmsTheBackoff() {
        let livePid = Int(ProcessInfo.processInfo.processIdentifier)
        XCTAssertTrue(ProcessProbe.processExists(livePid))
        XCTAssertTrue(
            ProcessProbe.shouldBackOff(
                ProcessProbe.Invocation(stdout: "", status: 1), pids: [livePid]
            )
        )
    }

    func testAFailedLaunchAlwaysArmsTheBackoff() {
        XCTAssertTrue(ProcessProbe.shouldBackOff(nil, pids: [999_999]))
    }

    /// Exit 0 with nothing to say is not a PID that vanished; it is a tool
    /// that answered and told us nothing.
    func testACleanButEmptyAnswerArmsTheBackoff() {
        XCTAssertTrue(
            ProcessProbe.shouldBackOff(
                ProcessProbe.Invocation(stdout: "", status: 0), pids: [999_999]
            )
        )
    }
}

/// 0.98 Ground Truth — the collector can be held to account.
///
/// Every test here runs the real `NativeActivityHarvest.scan` against real
/// files at real paths. They cover the four things that made 0.96.1 through
/// 0.97.2 ship green with a wrong tray hero, plus the counting and fairness
/// defects found beside them.
final class CommandSearchPathTests: XCTestCase {

    private func makeHome(_ label: String) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-ground-truth-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func write(_ text: String, to home: URL, _ relative: String) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Installed is not the same as running

    /// A menu-bar app launched by Finder/launchd inherits
    /// `/usr/bin:/bin:/usr/sbin:/sbin`, so an agent installed in `~/.local/bin`
    /// used to report `source_absent` ("not installed") instead of
    /// `no_sessions` ("installed, nothing running").
    func testInstalledCLIIsFoundUnderLaunchdMinimalPath() throws {
        let home = try makeHome("path")
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let tool = bin.appendingPathComponent("pulse-fixture-cli")
        try "#!/bin/sh\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: tool.path
        )

        let launchdPath = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        XCTAssertTrue(
            NativeActivityHarvest.executableExists(
                "pulse-fixture-cli", home: home, environment: launchdPath
            )
        )
        XCTAssertFalse(
            NativeActivityHarvest.executableExists(
                "pulse-fixture-not-installed", home: home, environment: launchdPath
            )
        )
    }

    func testCommandSearchPathsCoverTheCommonInstallRoots() {
        let home = URL(fileURLWithPath: "/Users/fixture")
        let paths = NativeActivityHarvest.commandSearchPaths(
            home: home,
            environment: ["PATH": "/usr/bin:/bin"]
        )
        XCTAssertTrue(paths.contains("/opt/homebrew/bin"))
        XCTAssertTrue(paths.contains("/usr/local/bin"))
        XCTAssertTrue(paths.contains("/Users/fixture/.local/bin"))
        XCTAssertTrue(paths.contains("/Users/fixture/.bun/bin"))
        XCTAssertEqual(paths.count, Set(paths).count, "search paths are de-duplicated")
    }
}

/// Regressions for two defects found by reading 0.99.0.
///
/// Both had the same shape: something that looked verified was not. One test
/// asserted a tool's output format the tool does not produce; one dictionary
/// assumed keys could not collide when two independent lists fed it.
final class LsofWorkspaceTests: XCTestCase {

    // MARK: - lsof workspace recovery

    /// The end-to-end shape: a real `-Ffpn -a -d cwd` reply for two processes,
    /// one of which lsof could not resolve.
    func testRealLsofReplyYieldsAWorkspacePerResolvableProcess() {
        let output = """
        p101
        fcwd
        n/Users/me/code/Pulse
        p202
        fcwd
        n/Users/me/code/Other
        p303
        fcwd
        n/Users/me/code/Locked (readlink: Permission denied)
        """
        let parsed = ProcessProbe.parseWorkingDirectories(output)
        XCTAssertEqual(parsed[101], "/Users/me/code/Pulse")
        XCTAssertEqual(parsed[202], "/Users/me/code/Other")
        XCTAssertEqual(
            ProcessProbe.usefulWorkingDirectory(parsed[303] ?? ""), "",
            "an lsof error annotation is not a workspace"
        )
    }

    func testUnreadableDirectoryAnnotationIsRejected() {
        XCTAssertEqual(
            ProcessProbe.usefulWorkingDirectory("/Users/me/x (readlink: Permission denied)"),
            ""
        )
        XCTAssertEqual(
            ProcessProbe.usefulWorkingDirectory("/Users/me/x (stat: No such file or directory)"),
            ""
        )
        XCTAssertEqual(
            ProcessProbe.usefulWorkingDirectory("/Users/me/code/Pulse"),
            "/Users/me/code/Pulse"
        )
    }

    /// A directory whose name simply contains a parenthesis is still a
    /// workspace — the annotation check is anchored, not a blanket ban.
    func testAnOrdinaryDirectoryWithParenthesesIsStillAWorkspace() {
        XCTAssertFalse(ProcessProbe.isLsofErrorAnnotated("/Users/me/Documents/Work (old)"))
        XCTAssertEqual(
            ProcessProbe.usefulWorkingDirectory("/Users/me/Documents/Work (old)"),
            "/Users/me/Documents/Work (old)"
        )
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
