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

    enum Status: Equatable {
        case idle
        case checking
        /// Running the newest published version.
        case current
        case available(version: String, url: String)
        case failed(String)
    }

    /// Default feed; override with `PulseUpdateFeed` in Info.plist.
    private static let defaultFeed = "https://api.github.com/repos/hxddh/Pulse/releases/latest"
    private static let minInterval: TimeInterval = 24 * 60 * 60

    private var lastCheck: Date?
    private var inFlight = false

    private var feedURL: URL? {
        let raw = (Bundle.main.infoDictionary?["PulseUpdateFeed"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: raw?.isEmpty == false ? raw! : Self.defaultFeed)
    }

    /// Called at launch and whenever settings change.
    func startIfEnabled(store: StatusStore) {
        guard store.updateCheckEnabled else {
            store.updateStatus = .idle
            return
        }
        if let last = lastCheck, Date().timeIntervalSince(last) < Self.minInterval { return }
        check(store: store, force: false)
    }

    func check(store: StatusStore, force: Bool) {
        guard !inFlight else { return }
        guard force || store.updateCheckEnabled else { return }
        guard let url = feedURL else {
            store.updateStatus = .failed("bad feed url")
            return
        }
        inFlight = true
        lastCheck = Date()
        store.updateStatus = .checking

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Pulse/\(PulseVersion.semver)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, error in
            let result = Self.interpret(data: data, response: response, error: error)
            Task { @MainActor in
                self.inFlight = false
                store.updateStatus = result
                DebugLog.write("updateCheck \(result)")
            }
        }.resume()
    }

    nonisolated static func interpret(
        data: Data?,
        response: URLResponse?,
        error: Error?
    ) -> Status {
        if let error { return .failed(error.localizedDescription) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return .failed("HTTP \(http.statusCode)")
        }
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failed("bad response")
        }
        let tag = (object["tag_name"] as? String) ?? ""
        let page = (object["html_url"] as? String) ?? ""
        let latest = normalize(tag)
        guard !latest.isEmpty else { return .failed("no tag") }
        return isNewer(latest, than: PulseVersion.semver)
            ? .available(version: latest, url: page)
            : .current
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
