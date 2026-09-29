import Foundation
import Testing
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest

/// 19.0 · the self-check's judgement. It may only say what the facts show:
/// installed is not proven, silence is not success, and nothing it copies
/// identifies a person, a project or a session.
@Suite("Self-check")
struct DoctorTests {
    let now: Int64 = 1_800_000_000_000

    func healthy() -> DoctorModel.Facts {
        var f = DoctorModel.Facts()
        f.channel = "preview"
        f.macOS = "26.0.0"
        f.nowMs = now
        f.claudeInstalled = true
        f.claudeHookEvents = Set(DoctorModel.claudeEvents)
        f.claudeNotificationMatcher = "permission_prompt|idle_prompt|agent_needs_input|elicitation_dialog"
        f.claudeAgents = .parsed(sessions: 2, waiting: 1)
        f.lastFire = ["claude": .init(kind: "turn", tsMs: now - 5 * 60_000), "codex": .init(kind: "turn", tsMs: now - 60 * 60_000)]
        f.codexInstalled = true
        f.codexHookEvents = Set(DoctorModel.codexEvents)
        f.codexRollout = .paginated
        f.respondEnabled = true
        f.respondWritten = 2
        f.respondTaken = 1
        f.readCoverage = ["claude": .init(name: "Claude", sessions: 3, withTask: 3, withLastWord: 2)]
        return f
    }

    func verdict(_ facts: DoctorModel.Facts, _ id: String) -> DoctorModel.Verdict? {
        DoctorModel.evaluate(facts, lang: .en).checks.first { $0.id == id }?.verdict
    }

    @Test func aHealthyMacProvesEveryContract() {
        let report = DoctorModel.evaluate(healthy(), lang: .en)
        for check in report.checks where check.id != "codex-hooks" {
            #expect(check.verdict == .works, "\(check.id): \(check.detail)")
        }
        // The file cannot say Codex trusts it; the fired event is the proof.
        #expect(verdict(healthy(), "codex-hooks") == .unproven)
        #expect(verdict(healthy(), "codex-fired") == .works)
    }

    @Test func anAgentThatIsNotInstalledIsNotAFailure() {
        var f = healthy()
        f.claudeInstalled = false
        f.claudeHookEvents = []
        f.claudeAgents = .noCLI
        f.codexInstalled = false
        #expect(verdict(f, "claude-hooks") == .absent)
        #expect(verdict(f, "claude-agents") == .absent)
        #expect(verdict(f, "codex-hooks") == .absent)
        #expect(verdict(f, "claude-fired") == nil)
        #expect(verdict(f, "codex-rollout") == nil)
    }

    @Test func aMissingEventOrMatcherTokenIsNamed() throws {
        var f = healthy()
        f.claudeHookEvents.remove("StopFailure")
        f.claudeNotificationMatcher = "permission_prompt|idle_prompt"
        let check = try #require(DoctorModel.evaluate(f, lang: .en).checks.first { $0.id == "claude-hooks" })
        #expect(check.verdict == .attention)
        #expect(check.detail.contains("StopFailure"))
        #expect(check.detail.contains("elicitation_dialog"))
        #expect(!check.next.isEmpty)
    }

    @Test func aCodexPermissionHookIsFlagged() {
        var f = healthy()
        f.codexHookEvents.insert("PermissionRequest")
        f.codexPermissionHook = true
        #expect(verdict(f, "codex-hooks") == .attention)
    }

    @Test func silenceIsNotSuccess() {
        var f = healthy()
        f.lastFire = [:]
        #expect(verdict(f, "claude-fired") == .unproven)
        #expect(verdict(f, "codex-fired") == .unproven)
        f.lastFire = ["claude": .init(kind: "turn", tsMs: now - DoctorModel.staleFireMs - 1)]
        #expect(verdict(f, "claude-fired") == .unproven, "a hook that fired last month proves little about today")
    }

    @Test(arguments: [
        (DoctorModel.AgentsAnswer.parsed(sessions: 0, waiting: 0), DoctorModel.Verdict.works),
        (.failed(exitStatus: 1, timedOut: false), .attention),
        (.failed(exitStatus: 0, timedOut: true), .attention),
        (.unreadable(bytes: 40), .attention),
        (.noCLI, .attention),
    ])
    func claudeAgentsAnswers(answer: DoctorModel.AgentsAnswer, expected: DoctorModel.Verdict) {
        var f = healthy()
        f.claudeAgents = answer
        #expect(verdict(f, "claude-agents") == expected)
    }

    // MARK: - 20.0 · reading less

    @Test func aFormatThatReadsNothingIsFlaggedByName() throws {
        var f = healthy()
        f.readCoverage["gemini"] = .init(name: "Gemini", sessions: 4, withTask: 4, withLastWord: 0)
        let check = try #require(DoctorModel.evaluate(f, lang: .en).checks.first { $0.id == "reading" })
        #expect(check.verdict == .attention)
        #expect(check.detail.contains("Gemini"))
        #expect(!check.detail.contains("Claude"))
    }

    @Test func aFormatWithoutWordsIsNotAskedForThem() {
        var f = healthy()
        f.readCoverage["cline"] = .init(name: "Cline", sessions: 5, withTask: 5, withLastWord: 0, expectsLastWord: false)
        #expect(verdict(f, "reading") == .works)
    }

    @Test func oneSessionProvesNothingEitherWay() {
        var f = healthy()
        f.readCoverage["goose"] = .init(name: "Goose", sessions: 1, withTask: 0, withLastWord: 0)
        #expect(verdict(f, "reading") == .works)
        f.readCoverage = [:]
        #expect(verdict(f, "reading") == .absent)
    }

    @Test func fewerThanHalfIsUnproven() {
        var f = healthy()
        f.readCoverage["pi"] = .init(name: "Pi", sessions: 6, withTask: 6, withLastWord: 2)
        #expect(verdict(f, "reading") == .unproven)
    }

    @Test func respondIsProvenOnlyByAClaimedVerdict() {
        var f = healthy()
        #expect(verdict(f, "respond") == .works)
        f.respondTaken = 0
        #expect(verdict(f, "respond") == .attention, "written and never claimed")
        f.respondWritten = 0
        #expect(verdict(f, "respond") == .unproven)
        f.respondEnabled = false
        #expect(verdict(f, "respond") == .absent)
    }

    @Test(arguments: [
        ("", DoctorModel.RolloutShape.none),
        (#"{"type":"event_msg","payload":{"type":"user_message","message":"x"}}"#, .legacy),
        (#"{"type":"event_msg","payload":{"type":"item_completed","item":{}}}"#, .paginated),
        (#"{"type":"event_msg","payload":{"type":"agent_message"}}"# + "\n" + #"{"type":"event_msg","payload":{"type":"item_completed"}}"#, .mixed),
        (#"{"type":"something_else"}"#, .unknown),
    ])
    func rolloutShapes(text: String, expected: DoctorModel.RolloutShape) {
        #expect(DoctorProbe.rolloutShape(text) == expected)
    }

    @Test func onlyPulseEntriesCount() throws {
        let json = #"""
        {"hooks":{
          "Stop":[{"hooks":[{"type":"command","command":"/Users/me/Library/Application Support/Pulse/pulse-hook claude stop"}]}],
          "PreToolUse":[{"hooks":[{"type":"command","command":"mytool --hook-dir x"}]}],
          "Notification":[{"matcher":"permission_prompt|elicitation_dialog","hooks":[{"type":"command","command":"pulse-hook claude"}]}]
        }}
        """#
        let table = try #require(DoctorProbe.hookTable(Data(json.utf8)))
        let found = DoctorProbe.pulseEvents(table)
        #expect(found.events == ["Stop", "Notification"])
        #expect(found.notificationMatcher == "permission_prompt|elicitation_dialog")
        #expect(DoctorProbe.hookTable(Data("not json".utf8)) == nil)
    }

    @Test(arguments: [ResolvedLanguage.en, .zh])
    func theCopiedReportCarriesNoHomePath(lang: ResolvedLanguage) {
        var report = DoctorModel.evaluate(healthy(), lang: lang)
        report.checks[0].detail += " /Users/alice/code/secret-project"
        let text = DoctorModel.text(report)
        #expect(!text.contains("alice"))
        #expect(!text.contains("/Users/"))
        #expect(text.hasPrefix("Pulse "))
    }
}
