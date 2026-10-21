import Foundation

/// Single source of truth for the product version.
///
/// `semver` is the truth; `scripts/version_check.py` keeps the CHANGELOG and
/// the README badge from drifting away from it. Build metadata (commit, date)
/// is injected into `Info.plist` by `PulseBar/Scripts/package.sh`, so a `swift
/// run` build honestly reports itself as `dev` instead of faking a release id.
enum PulseVersion {
    /// The bundle identifier (`package.sh` writes it into `Info.plist`,
    /// `package_check.py` holds the two to each other). Every other
    /// reverse-DNS name Pulse uses — its queues, the reopen notification —
    /// is derived from it.
    static let bundleID = "io.github.hxddh.pulse"

    static let semver = "33.0.0"

    enum Channel {
        /// Packaged Pulse.app whose bundle version matches this binary.
        case release
        /// `swift run` / unpackaged — no build metadata.
        case dev
        /// Packaged, but Info.plist disagrees with the compiled semver.
        case mismatch(bundle: String)
    }

    private static func plist(_ key: String) -> String? {
        guard let raw = Bundle.main.infoDictionary?[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `CFBundleShortVersionString` of the running bundle, when packaged.
    static var bundleVersion: String? { plist("CFBundleShortVersionString") }

    /// Short git sha stamped at package time (`dev` when unpackaged).
    static var commit: String { plist("PulseGitCommit") ?? "dev" }

    /// ISO date stamped at package time (empty when unpackaged).
    static var buildDate: String { plist("PulseBuildDate") ?? "" }

    /// `stable` (notarized — `package.sh` stamps it only after stapler
    /// validates) / `preview` (every other packaged build: ad-hoc or not
    /// notarized) / `dev` (unpackaged). An unnotarized build is never stable.
    static var distributionChannel: String {
        plist("PulseDistributionChannel") ?? (bundleVersion == nil ? "dev" : "preview")
    }

    /// Stapler success stamp from `package.sh`. Absent or false → not Gatekeeper-ready.
    static var isNotarized: Bool {
        (plist("PulseNotarized") ?? "false").lowercased() == "true"
    }

    static var channel: Channel {
        guard let bundle = bundleVersion else { return .dev }
        return bundle == semver ? .release : .mismatch(bundle: bundle)
    }

    /// Compact badge for tray footer / logs: `x.y.z`, `x.y.z-dev`, `x.y.z≠<bundle>`.
    static var short: String {
        switch channel {
        case .release: return semver
        case .dev: return "\(semver)-dev"
        case .mismatch(let bundle): return "\(semver)≠\(bundle)"
        }
    }

    /// `Pulse x.y.z` — About heading.
    static var about: String { "Pulse \(short)" }

    /// Second About line: `<sha> · <date>`. Empty when there is nothing honest to show.
    static var buildLine: String {
        var bits: [String] = []
        if commit != "dev" { bits.append(commit) }
        if !buildDate.isEmpty { bits.append(buildDate) }
        return bits.joined(separator: " · ")
    }

    /// One line that fully identifies this build — logs and bug reports.
    static var fingerprint: String {
        let build = buildLine
        return build.isEmpty ? "Pulse \(short)" : "Pulse \(short) (\(build))"
    }
}
