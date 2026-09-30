import Foundation

/// Asks GitHub Releases whether a newer Pulse exists.
///
/// A menu bar app that never checks stays on whatever version it was first
/// installed at, forever. This is deliberately minimal: no download, no
/// installer, no background daemon — one request at most once a day, a line
/// saying which version exists, and a button that opens its release page.
@MainActor
final class UpdateCheck {
    static let shared = UpdateCheck()

    struct ReleaseInfo: Equatable {
        var version: String
        var pageURL: String
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
        guard store.settings.updateCheckEnabled else {
            // Scan-quiet: Observation announces every assignment, equal or not.
            store.landUpdateStatus(.idle)
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
        guard force || store.settings.updateCheckEnabled else { return }
        guard let url = feedURL else {
            let next = Self.resolve(previous: store.updateStatus, result: .failed(.badFeed), manual: force)
            store.landUpdateStatus(next)
            return
        }
        inFlight = true
        lastAttempt = Date()
        // Only a manual check shows `.checking`; a background one leaves the
        // known answer on screen and resolves against it.
        if force { store.landUpdateStatus(.checking) }

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
                store.landUpdateStatus(next)
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
        let isPrerelease = (object["prerelease"] as? Bool) ?? false
        // Stable builds must not auto-offer a prerelease; preview builds may.
        if isPrerelease && !preferPrerelease {
            return .current
        }
        let latest = normalize(tag)
        guard !latest.isEmpty else { return .failed(.noTag) }
        guard isNewer(latest, than: PulseVersion.semver) else { return .current }

        let release = ReleaseInfo(version: latest, pageURL: page)
        return .available(release)
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
}
