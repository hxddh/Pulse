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
            !assetURL.isEmpty && sha256.count == 64
        }
    }

    enum Status: Equatable {
        case idle
        case checking
        /// Running the newest published version.
        case current
        case available(ReleaseInfo)
        case failed(String)
    }

    enum DownloadStatus: Equatable {
        case idle
        case downloading
        case verifying
        case ready(URL)
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
        let body = (object["body"] as? String) ?? ""
        let latest = normalize(tag)
        guard !latest.isEmpty else { return .failed("no tag") }
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
    /// the installer. Pulse does not silently replace itself while releases are
    /// ad-hoc signed; the user still owns the final installation decision.
    func downloadAndOpen(store: StatusStore) {
        guard case .available(let release) = store.updateStatus,
              release.canVerifyDownload,
              let url = URL(string: release.assetURL)
        else {
            store.updateDownloadStatus = .failed("release has no verifiable DMG")
            return
        }
        store.updateDownloadStatus = .downloading
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        request.setValue("Pulse/\(PulseVersion.semver)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.downloadTask(with: request) { tempURL, response, error in
            guard let tempURL else {
                Task { @MainActor in
                    store.updateDownloadStatus = .failed(error?.localizedDescription ?? "download failed")
                }
                return
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                Task { @MainActor in
                    store.updateDownloadStatus = .failed("HTTP \(http.statusCode)")
                }
                return
            }
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
                let downloads = FileManager.default.urls(
                    for: .downloadsDirectory,
                    in: .userDomainMask
                ).first ?? FileManager.default.temporaryDirectory
                let name = release.assetName.isEmpty
                    ? "pulse-\(release.version)-macos.dmg"
                    : release.assetName
                let destination = downloads.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: tempURL, to: destination)
                Task { @MainActor in
                    store.updateDownloadStatus = .ready(destination)
                    NSWorkspace.shared.open(destination)
                }
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
                Task { @MainActor in
                    store.updateDownloadStatus = .failed(error.localizedDescription)
                }
            }
        }.resume()
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

    private nonisolated static func sha256(in body: String) -> String {
        let pattern = #"(?i)(?:sha[- ]?256[^0-9a-f]{0,24})?([0-9a-f]{64})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: body,
                range: NSRange(body.startIndex..., in: body)
              ),
              let range = Range(match.range(at: 1), in: body)
        else { return "" }
        return String(body[range]).lowercased()
    }

    private enum DownloadError: LocalizedError {
        case size(expected: Int, actual: Int)
        case digest

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
