import Foundation

/// Locates the SwiftPM resource bundle without ever trapping.
///
/// The compiler-generated `Bundle.module` accessor ends in `fatalError()` when
/// it cannot open the bundle. That turns any packaging mistake into a launch
/// crash with no diagnostics: a `Contents/` directory inside the flat SwiftPM
/// bundle is enough for CFBundle to refuse it, and the app dies drawing its
/// menu bar icon — a bounce and nothing else.
///
/// A missing icon is not worth a crash. This resolves the same candidates and
/// returns nil, so callers fall through to `PulseBrand.fallbackDrawn` and the
/// monogram icons. `scripts/package_check.py` is what actually keeps the bundle
/// correct; this only decides how loudly it fails when something slips past.
enum PulseResources {
    private static let bundleName = "PulseBar_PulseApp.bundle"

    static let bundle: Bundle? = {
        var seen: Set<String> = []
        var roots: [URL] = []
        func consider(_ url: URL?) {
            guard let url, seen.insert(url.path).inserted else { return }
            roots.append(url)
        }

        // Packaged app: Pulse.app/Contents/Resources/. Dev (`swift run`): the
        // build directory, where SwiftPM leaves the bundle beside the binary.
        consider(Bundle.main.resourceURL)
        consider(Bundle.main.bundleURL)
        consider(Bundle.main.executableURL?.deletingLastPathComponent())
        // Test runners load the code from a bundle that is not `main`.
        consider(Bundle(for: BundleAnchor.self).resourceURL)
        consider(Bundle(for: BundleAnchor.self).bundleURL.deletingLastPathComponent())

        for root in roots {
            let candidate = root.appendingPathComponent(bundleName)
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            if let found = Bundle(url: candidate) {
                return found
            }
            DebugLog.write("resource bundle at \(candidate.path) exists but will not open")
        }
        DebugLog.write("resource bundle \(bundleName) not found — using drawn fallbacks")
        return nil
    }()

    /// `Bundle.module.url(forResource:withExtension:subdirectory:)`, minus the trap.
    static func url(forResource name: String, withExtension ext: String, subdirectory: String? = nil) -> URL? {
        bundle?.url(forResource: name, withExtension: ext, subdirectory: subdirectory)
    }

    /// Anchors `Bundle(for:)` to this module.
    private final class BundleAnchor {}
}
