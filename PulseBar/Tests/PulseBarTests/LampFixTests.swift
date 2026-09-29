import Foundation
import Testing
@testable import PulseBar
@testable import PulseCore
@testable import PulseHarvest
@testable import PulseRespond

/// 22.x · Lamp fixes — each pins one defect with the pure function that
/// decides it.
@Suite("Lamp fixes")
struct LampFixTests {

    // MARK: - Background update checks keep a known answer

    private static let release = UpdateCheck.ReleaseInfo(
        version: "99.0.0",
        pageURL: "https://example.invalid/r",
        assetURL: "",
        assetName: "",
        assetBytes: 0,
        sha256: ""
    )

    @Test func aBackgroundFailureKeepsAnAvailableUpdate() {
        let previous = UpdateCheck.Status.available(Self.release)
        let next = UpdateCheck.resolve(previous: previous, result: .failed(.network("offline")), manual: false)
        #expect(next == previous)
    }

    @Test func aBackgroundFailureKeepsUpToDate() {
        let next = UpdateCheck.resolve(previous: .current, result: .failed(.http(503)), manual: false)
        #expect(next == .current)
    }

    @Test func aManualFailureIsShown() {
        let next = UpdateCheck.resolve(previous: .current, result: .failed(.http(503)), manual: true)
        #expect(next == .failed(.http(503)))
    }

    @Test func aBackgroundAnswerStillReplacesTheStatus() {
        let next = UpdateCheck.resolve(previous: .current, result: .available(Self.release), manual: false)
        #expect(next == .available(Self.release))
    }

    // MARK: - Download failures are typed

    @Test func aDownloadWithoutAFileIsANetworkFailure() {
        let failure = UpdateCheck.DownloadFailure.classify(hasFile: false, response: nil, error: nil)
        #expect(failure == .network("download failed"))
    }

    @Test func aNon2xxDownloadIsAnHTTPFailure() throws {
        let url = try #require(URL(string: "https://example.invalid/pulse.dmg"))
        let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)
        let failure = UpdateCheck.DownloadFailure.classify(hasFile: true, response: response, error: nil)
        #expect(failure == .http(404))
    }

    @Test func anUnexpectedContentTypeIsAVerificationFailure() throws {
        let url = try #require(URL(string: "https://example.invalid/pulse.dmg"))
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"]
        )
        let failure = UpdateCheck.DownloadFailure.classify(hasFile: true, response: response, error: nil)
        #expect(failure == .verification("missing or unexpected installer content type"))
    }

    @Test func aDiskImageResponseGoesOnToVerification() throws {
        let url = try #require(URL(string: "https://example.invalid/pulse.dmg"))
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/octet-stream"]
        )
        let failure = UpdateCheck.DownloadFailure.classify(hasFile: true, response: response, error: nil)
        #expect(failure == nil)
    }

    @MainActor
    @Test func aNetworkFailureIsNotCalledAVerificationFailure() {
        let store = StatusStore()
        let verify = store.tr(.updateVerifyFailed)
        let http = store.updateDownloadFailureText(.http(404))
        let network = store.updateDownloadFailureText(.network("offline"))
        let digest = store.updateDownloadFailureText(.verification("SHA-256 verification failed"))
        #expect(!http.contains(verify))
        #expect(!network.contains(verify))
        #expect(digest.contains(verify))
    }

    // MARK: - "Don't suggest hooks" persists

    @Test func hooksNudgeOffRoundTrips() {
        var settings = PulseSettings()
        settings.hooksNudgeOff = true
        let reparsed = PulseSettings.parse(settings.serialized())
        #expect(reparsed.hooksNudgeOff)
        #expect(!PulseSettings.parse("auto=1\n").hooksNudgeOff)
    }

    @MainActor
    @Test func anUninstalledChoiceSilencesTheHooksNudge() {
        let store = StatusStore()
        store.installPreviewFixture("waiting")
        store.notifyAuthorized = true
        #expect(store.needsHooksNudge)
        store.hooksNudgeOff = true
        #expect(!store.needsHooksNudge)
    }

    // MARK: - Codex hooks.json counts as installed

    @Test func codexHooksJSONAloneCountsAsInstalled() {
        let hooks = #"{"hooks":{"Stop":[{"hooks":[{"command":"/x/pulse-hook --agent codex"}]}]}}"#
        #expect(HooksSupport.codexHooked(configTOML: nil, hooksJSON: hooks))
        #expect(HooksSupport.codexHooked(configTOML: "notify = [\"/x/pulse-hook\"]", hooksJSON: nil))
        #expect(!HooksSupport.codexHooked(configTOML: "model = \"o3\"", hooksJSON: "{}"))
    }

    // MARK: - Expired Respond requests do not spend the read budget

    private func writeRequest(
        in directory: URL, name: String, expiresAtMs: Int64, now: Int64, modified: Date
    ) throws {
        let payload = #"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#
        let object: [String: Any] = [
            "v": 1,
            "request_id": name,
            "agent": "claude",
            "host": "devbox",
            "session": "s1",
            "cwd": "/w",
            "tool_name": "Bash",
            "raised_at_ms": NSNumber(value: now - 1_000),
            "expires_at_ms": NSNumber(value: expiresAtMs),
            "payload_b64": Data(payload.utf8).base64EncodedString(),
            "digest": RespondDigest.of(payload),
            "truncated": false,
        ]
        let url = directory.appendingPathComponent("\(name).json")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    @Test func aLiveRequestBehindManyExpiredOnesIsStillRead() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-lamp-requests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now: Int64 = 1_800_000_000_000
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // Expired leftovers sort first by name and are newer on disk.
        for index in 0..<(RespondSpool.maxFiles + 8) {
            try writeRequest(
                in: directory,
                name: String(format: "a-expired-%02d", index),
                expiresAtMs: now - 1,
                now: now,
                modified: base.addingTimeInterval(Double(100 + index))
            )
        }
        try writeRequest(
            in: directory, name: "z-live", expiresAtMs: now + 60_000, now: now, modified: base
        )
        let found = RespondSpool.readLocalRequests(nowMs: now, host: "devbox", in: directory)
        let ids = found.map(\.request.id)
        #expect(ids == ["z-live"])
    }

    // MARK: - Relative dates follow the app language

    @MainActor
    @Test func inspectorRelativeDatesUseTheAppLanguage() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ms = Int64((now.timeIntervalSince1970 - 3_600) * 1000)
        let en = SessionDiagnosticsCard.relativeText(ms: ms, now: now, lang: .en)
        let zh = SessionDiagnosticsCard.relativeText(ms: ms, now: now, lang: .zh)
        #expect(en.contains("ago"))
        #expect(zh.contains("前"))
    }

    // MARK: - The health line reads the last scan, not the last publish

    @Test func lastReadPrefersTheNewerScan() {
        let published = Date(timeIntervalSince1970: 1_000)
        let scanned = Date(timeIntervalSince1970: 1_050)
        #expect(StatusStore.lastReadDate(lastScanAt: scanned, snapshotUpdatedAt: published) == scanned)
        #expect(StatusStore.lastReadDate(lastScanAt: nil, snapshotUpdatedAt: published) == published)
        #expect(StatusStore.lastReadDate(lastScanAt: nil, snapshotUpdatedAt: .distantPast) == nil)
        #expect(StatusStore.lastReadDate(lastScanAt: scanned, snapshotUpdatedAt: .distantPast) == scanned)
    }
}
