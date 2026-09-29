import AppKit
import CryptoKit
import Foundation

/// Asks GitHub Releases whether a newer Pulse exists.
///
/// A menu bar app that never checks stays on whatever version it was first
/// installed at, forever. This is deliberately minimal: no auto-download, no
/// background daemon — one request at most once a day, and it says plainly
/// when it could not reach the network.
@MainActor
final class UpdateCheck {
    static let shared = UpdateCheck()

    struct ReleaseInfo: Equatable {
        var version: String
        var pageURL: String
        var assetURL: String
        var assetName: String
        var assetBytes: Int
        var sha256: String

        var canVerifyDownload: Bool {
            !assetURL.isEmpty
                && assetBytes > 0
                && sha256.count == 64
                && sha256.unicodeScalars.allSatisfy {
                    let value = $0.value
                    return (48...57).contains(value)
                        || (65...70).contains(value)
                        || (97...102).contains(value)
                }
        }
    }

    enum Status: Equatable {
        case idle
        case checking
        /// Running the newest published version.
        case current
        case available(ReleaseInfo)
        case failed(Failure)
    }

    /// Why a check did not produce an answer — typed so the surface can say
    /// it in the user's language. `detail` is the untranslated technical
    /// fact (a status code, the system's own error text) for the debug log
    /// and as the suffix after the localized reason.
    enum Failure: Equatable {
        /// The feed URL (Info.plist `PulseUpdateFeed`) does not parse.
        case badFeed
        /// The request never got an HTTP answer (offline, DNS, TLS, timeout).
        case network(String)
        /// GitHub answered with a non-2xx status.
        case http(Int)
        /// The body is not a release (or a list of releases).
        case badResponse
        /// The release has no usable tag.
        case noTag

        var detail: String {
            switch self {
            case .badFeed: return "bad feed url"
            case .network(let message): return message
            case .http(let code): return "HTTP \(code)"
            case .badResponse: return "bad response"
            case .noTag: return "no tag"
            }
        }
    }

    enum DownloadStatus: Equatable {
        case idle
        case downloading
        case verifying
        /// The verified DMG and the digest it was verified against — the
        /// install helper re-checks that digest right before it mounts.
        case ready(URL, sha256: String)
        case installing
        case failed(DownloadFailure)
    }

    /// Why a download, verification or install did not finish — typed like
    /// `Failure` so the surface says it in the user's language and never
    /// calls a network error a verification failure. `detail` is the
    /// untranslated technical fact for the debug log and the suffix.
    enum DownloadFailure: Equatable {
        /// The release names no DMG with a size and a SHA-256 to check.
        case noVerifiableAsset
        /// This Mac cannot run the release (macOS version or architecture).
        case unsupportedSystem(String)
        /// The download never got an HTTP answer.
        case network(String)
        /// The asset host answered with a non-2xx status.
        case http(Int)
        /// The bytes arrived but are not the published installer
        /// (content type, size, digest, or the mounted app's preflight).
        case verification(String)
        /// In-place install is reserved for notarized stable builds.
        case requiresNotarized
        /// Install asked for before a verified DMG was ready.
        case notReady
        /// Moving the DMG or launching the install helper failed.
        case install(String)

        var detail: String {
            switch self {
            case .noVerifiableAsset: return "release has no verifiable DMG"
            case .unsupportedSystem(let message): return message
            case .network(let message): return message
            case .http(let code): return "HTTP \(code)"
            case .verification(let message): return message
            case .requiresNotarized: return "in-place install requires a notarized stable build"
            case .notReady: return "download a verified DMG first"
            case .install(let message): return message
            }
        }

        /// Pure: the right failure for a finished download task, or nil when
        /// the response may go on to verification.
        static func classify(
            hasFile: Bool,
            response: URLResponse?,
            error: Error?
        ) -> DownloadFailure? {
            guard hasFile else {
                return .network(error?.localizedDescription ?? "download failed")
            }
            guard let http = response as? HTTPURLResponse else {
                return .verification("missing installer response headers")
            }
            guard (200..<300).contains(http.statusCode) else {
                return .http(http.statusCode)
            }
            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            guard contentType.contains("octet-stream") || contentType.contains("diskimage") else {
                return .verification("missing or unexpected installer content type")
            }
            return nil
        }
    }

    /// Default feed; override with `PulseUpdateFeed` in Info.plist.
    private static let defaultLatestFeed = "https://api.github.com/repos/hxddh/Pulse/releases/latest"
    private static let defaultReleasesFeed = "https://api.github.com/repos/hxddh/Pulse/releases?per_page=15"
    /// Nested, so not main-actor isolated: `isDue` is a pure function.
    enum Cadence {
        static let minInterval: TimeInterval = 24 * 60 * 60
        /// After a failed check: soon enough that a laptop back on the
        /// network learns about a release the same day, rare enough to be no
        /// load.
        static let retryInterval: TimeInterval = 60 * 60
    }

    /// The last check that got an answer. A failure never counts as a
    /// check — before, one offline launch silenced the next 24 hours.
    private var lastCheck: Date?
    /// The last attempt of any outcome, for the failure back-off.
    private var lastAttempt: Date?
    private var inFlight = false

    /// Pure: should a periodic caller start a check now?
    nonisolated static func isDue(now: Date, lastSuccess: Date?, lastAttempt: Date?) -> Bool {
        if let lastSuccess, now.timeIntervalSince(lastSuccess) < Cadence.minInterval { return false }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < Cadence.retryInterval { return false }
        return true
    }

    private var feedURL: URL? {
        if let raw = (Bundle.main.infoDictionary?["PulseUpdateFeed"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return URL(string: raw)
        }
        // Preview/signed builds use the releases list so they see every cut
        // (including when CI publishes unsigned builds as GitHub Latest).
        // Stable (notarized) stays on `/latest` and ignores prereleases.
        let raw = PulseVersion.prefersPrereleaseUpdates
            ? Self.defaultReleasesFeed
            : Self.defaultLatestFeed
        return URL(string: raw)
    }

    /// Called at launch, whenever settings change, and from the probe timer
    /// and wake path — so a Mac that stays up for weeks still hears about a
    /// release. Cheap when not due: one date comparison, no store write.
    func startIfEnabled(store: StatusStore) {
        guard store.updateCheckEnabled else {
            // Scan-quiet: Observation announces every assignment, equal or not.
            if store.updateStatus != .idle { store.updateStatus = .idle }
            return
        }
        guard Self.isDue(now: Date(), lastSuccess: lastCheck, lastAttempt: lastAttempt) else { return }
        check(store: store, force: false)
    }

    /// Pure: what the store shows after a check answers. A manual check
    /// (`force`) always shows its own result. A background check never
    /// replaces a known answer (`.available` / `.current`) with a failure —
    /// a laptop that was briefly offline must not lose the "update
    /// available" line it already had.
    nonisolated static func resolve(previous: Status, result: Status, manual: Bool) -> Status {
        guard !manual, case .failed = result else { return result }
        switch previous {
        case .available, .current: return previous
        case .idle, .checking, .failed: return result
        }
    }

    /// `force` is the manual check (`checkForUpdatesNow`): only it shows
    /// `.checking`; a background check changes the status only when the
    /// answer is worth showing (`resolve`).
    func check(store: StatusStore, force: Bool) {
        guard !inFlight else { return }
        guard force || store.updateCheckEnabled else { return }
        guard let url = feedURL else {
            let next = Self.resolve(previous: store.updateStatus, result: .failed(.badFeed), manual: force)
            if store.updateStatus != next { store.updateStatus = next }
            return
        }
        inFlight = true
        lastAttempt = Date()
        // Only a manual check shows `.checking`; a background one leaves the
        // known answer on screen and resolves against it.
        if force { store.updateStatus = .checking }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Pulse/\(PulseVersion.semver)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, error in
            let preferPrerelease = PulseVersion.prefersPrereleaseUpdates
            let result = Self.interpret(
                data: data,
                response: response,
                error: error,
                preferPrerelease: preferPrerelease
            )
            Task { @MainActor in
                self.inFlight = false
                if case .failed = result {} else { self.lastCheck = Date() }
                // A manual check that started from `.checking` resolves
                // straight to its result; `resolve` is pure either way.
                let next = Self.resolve(previous: store.updateStatus, result: result, manual: force)
                // Scan-quiet: Observation announces every assignment, equal or not.
                if store.updateStatus != next { store.updateStatus = next }
                DebugLog.write("updateCheck \(result)")
            }
        }.resume()
    }

    nonisolated static func interpret(
        data: Data?,
        response: URLResponse?,
        error: Error?,
        preferPrerelease: Bool = false
    ) -> Status {
        if let error { return .failed(.network(error.localizedDescription)) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return .failed(.http(http.statusCode))
        }
        guard let data else { return .failed(.badResponse) }

        let object: [String: Any]?
        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = dict
        } else if let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            // Releases list: pick the newest tag that matches this channel.
            object = list.first { entry in
                let pre = (entry["prerelease"] as? Bool) ?? false
                if preferPrerelease { return true }
                return !pre
            } ?? list.first
        } else {
            return .failed(.badResponse)
        }
        guard let object else { return .failed(.badResponse) }

        let tag = (object["tag_name"] as? String) ?? ""
        let page = (object["html_url"] as? String) ?? ""
        let body = (object["body"] as? String) ?? ""
        let isPrerelease = (object["prerelease"] as? Bool) ?? false
        // Stable builds must not auto-offer a prerelease; preview builds may.
        if isPrerelease && !preferPrerelease {
            return .current
        }
        let latest = normalize(tag)
        guard !latest.isEmpty else { return .failed(.noTag) }
        guard isNewer(latest, than: PulseVersion.semver) else { return .current }

        let assets = (object["assets"] as? [[String: Any]]) ?? []
        let dmg = assets.first { asset in
            ((asset["name"] as? String) ?? "").lowercased().hasSuffix(".dmg")
        }
        let release = ReleaseInfo(
            version: latest,
            pageURL: page,
            assetURL: (dmg?["browser_download_url"] as? String) ?? "",
            assetName: (dmg?["name"] as? String) ?? "",
            assetBytes: dmg?["size"] as? Int ?? 0,
            sha256: sha256(in: body)
        )
        return .available(release)
    }

    /// Download the published DMG, verify its release-note SHA-256, then open
    /// the installer. In-place replacement is reserved for Gatekeeper-ready
    /// (notarized stable) builds; preview/signed keep the user in charge of
    /// the final drag-install / Control-click Open path.
    func downloadAndOpen(store: StatusStore) {
        guard case .available(let release) = store.updateStatus,
              release.canVerifyDownload,
              let url = URL(string: release.assetURL)
        else {
            store.updateDownloadStatus = .failed(.noVerifiableAsset)
            return
        }
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 14 else {
            store.updateDownloadStatus = .failed(.unsupportedSystem("requires macOS 14 or newer"))
            return
        }
        #if arch(arm64)
        // Current Pulse distributions are intentionally Apple-silicon builds.
        // Refuse an ambiguous install path instead of downloading an artifact
        // that cannot launch on the current machine.
        #else
        store.updateDownloadStatus = .failed(.unsupportedSystem("this release targets Apple silicon"))
        return
        #endif
        store.updateDownloadStatus = .downloading
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        request.setValue("Pulse/\(PulseVersion.semver)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.downloadTask(with: request) { tempURL, response, error in
            if let failure = DownloadFailure.classify(
                hasFile: tempURL != nil,
                response: response,
                error: error
            ) {
                if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
                Task { @MainActor in
                    store.updateDownloadStatus = .failed(failure)
                }
                return
            }
            guard let tempURL else { return }
            Task { @MainActor in store.updateDownloadStatus = .verifying }
            do {
                let data = try Data(contentsOf: tempURL)
                if release.assetBytes > 0, data.count != release.assetBytes {
                    throw DownloadError.size(expected: release.assetBytes, actual: data.count)
                }
                let digest = SHA256.hash(data: data)
                    .map { String(format: "%02x", $0) }
                    .joined()
                guard digest.caseInsensitiveCompare(release.sha256) == .orderedSame else {
                    throw DownloadError.digest
                }
                try UpdateInstaller.preflight(
                    dmgURL: tempURL,
                    targetApp: Bundle.main.bundleURL
                )
                let downloads = FileManager.default.urls(
                    for: .downloadsDirectory,
                    in: .userDomainMask
                ).first ?? FileManager.default.temporaryDirectory
                let name = release.assetName.isEmpty
                    ? "pulse-\(release.version)-macos.dmg"
                    : release.assetName
                let destination = Self.nonDestructiveDestination(
                    base: downloads.appendingPathComponent(name)
                )
                try FileManager.default.moveItem(at: tempURL, to: destination)
                Task { @MainActor in
                    store.updateDownloadStatus = .ready(destination, sha256: digest.lowercased())
                    NSWorkspace.shared.open(destination)
                }
            } catch let failure as DownloadError {
                try? FileManager.default.removeItem(at: tempURL)
                let mapped = failure.failure
                Task { @MainActor in
                    store.updateDownloadStatus = .failed(mapped)
                }
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
                let message = error.localizedDescription
                Task { @MainActor in
                    store.updateDownloadStatus = .failed(.verification(message))
                }
            }
        }.resume()
    }

    /// Replace the running app through the same executable in helper mode. The
    /// helper waits for this process to exit, mounts the already verified DMG,
    /// and commits a recoverable transaction.
    ///
    /// Only notarized stable builds take this path. Ad-hoc / signed-unnotarized
    /// builds already opened the DMG in `downloadAndOpen`; pretending an
    /// in-place install is Gatekeeper-safe would lie about the channel.
    func installVerifiedUpdate(store: StatusStore) {
        guard PulseVersion.isGatekeeperReady else {
            store.updateDownloadStatus = .failed(.requiresNotarized)
            return
        }
        guard case .ready(let dmg, let digest) = store.updateDownloadStatus,
              Bundle.main.bundleURL.pathExtension == "app",
              let executable = Bundle.main.executableURL else {
            store.updateDownloadStatus = .failed(.notReady)
            return
        }
        let target = Bundle.main.bundleURL
        let helper = Process()
        helper.executableURL = executable
        helper.arguments = [
            "--install-update=\(dmg.path)",
            "--install-target=\(target.path)",
            "--install-parent-pid=\(ProcessInfo.processInfo.processIdentifier)",
            "--install-sha256=\(digest)",
        ]
        do {
            try helper.run()
            store.updateDownloadStatus = .installing
            // Mark intentional update replace so the next launch does not show
            // the unclean-exit recovery banner.
            store.markIntendedUpdateReplace()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.terminate(nil)
            }
        } catch {
            store.updateDownloadStatus = .failed(.install(error.localizedDescription))
        }
    }

    /// Never delete a previously downloaded installer behind the user's back.
    /// A suffix also makes concurrent update attempts recoverable instead of
    /// racing over the same destination path.
    nonisolated static func nonDestructiveDestination(base: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: base.path) else { return base }
        let stem = base.deletingPathExtension().lastPathComponent
        let ext = base.pathExtension
        for index in 1...99 {
            let name = "\(stem) (\(index)).\(ext)"
            let candidate = base.deletingLastPathComponent().appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return base.deletingLastPathComponent().appendingPathComponent("\(stem)-\(Int(Date().timeIntervalSince1970)).\(ext)")
    }

    /// `v0.22.0` / `0.22.0` → `0.22.0`.
    nonisolated static func normalize(_ tag: String) -> String {
        var s = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s = String(s.dropFirst()) }
        return s
    }

    /// Numeric semver compare — `0.9.0` must not beat `0.21.0`.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = parts(candidate)
        let b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private nonisolated static func parts(_ v: String) -> [Int] {
        // Drop any pre-release suffix: 0.22.0-beta.1 → 0.22.0
        let core = v.split(separator: "-", maxSplits: 1).first.map(String.init) ?? v
        return core.split(separator: ".").map { Int($0) ?? 0 }
    }

    /// The published digest, read from the release body's own verification
    /// block.
    ///
    /// The release body is the CHANGELOG section with a `### Download
    /// verification` block appended by `release.yml`. Scanning the whole body
    /// for "the first 64 hex characters" would let any unrelated hash that a
    /// future changelog entry happens to quote become the expected digest, and
    /// a good download would then fail verification. Anchor to the block that
    /// exists to carry it, and only fall back to a body-wide scan when the
    /// block is absent (older releases).
    private nonisolated static func sha256(in body: String) -> String {
        let verificationHeading = "### Download verification"
        if let blockStart = body.range(of: verificationHeading) {
            let block = String(body[blockStart.upperBound...])
            let digest = firstSHA256(in: block)
            if !digest.isEmpty { return digest }
        }
        return firstSHA256(in: body)
    }

    private nonisolated static func firstSHA256(in text: String) -> String {
        let pattern = #"(?i)(?:sha[- ]?256[^0-9a-f]{0,24})?([0-9a-f]{64})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              let range = Range(match.range(at: 1), in: text)
        else { return "" }
        return String(text[range]).lowercased()
    }

    private enum DownloadError: LocalizedError {
        case size(expected: Int, actual: Int)
        case digest

        var failure: DownloadFailure {
            .verification(errorDescription ?? "verification failed")
        }

        var errorDescription: String? {
            switch self {
            case .size(let expected, let actual):
                return "download size mismatch (\(actual)/\(expected))"
            case .digest:
                return "SHA-256 verification failed"
            }
        }
    }
}
