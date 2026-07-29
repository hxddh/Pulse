import Foundation

/// `PulseBar --selftest`: prove the packaged app can find its own resources.
///
/// Every static check of the `.app` encodes an assumption about *where* the
/// runtime looks. That assumption is exactly what was wrong in 0.21–0.23.0:
/// `package.sh` put the resource bundle in `Contents/Resources/`, while the
/// SwiftPM accessor for an executable target only ever looked at the `.app`
/// root and the baked build path. The structure looked defensible; the app
/// still died on launch.
///
/// So this asks the only question that matters, from inside the real bundle,
/// using the real lookup code: can it resolve the resources? It deliberately
/// runs before any AppKit initialisation, so it works on a headless CI runner
/// with no WindowServer.
enum PulseSelfTest {
    /// Resources the app cannot do its job without.
    private static let required: [(name: String, ext: String, dir: String?)] = [
        ("activity_scan", "py", nil),
        ("pulse_hook", "py", nil),
        ("install_hooks", "py", nil),
        ("pulse-mark", "png", "Brand"),
        ("claude", "png", "AgentIcons"),
    ]

    static func run() -> Bool {
        var ok = true

        print("bundle path : \(Bundle.main.bundleURL.path)")
        print("resourceURL : \(Bundle.main.resourceURL?.path ?? "<nil>")")

        if let found = PulseResources.bundle {
            print("resources   : \(found.bundleURL.path)")
        } else {
            print("resources   : NOT FOUND")
            ok = false
        }

        for item in required {
            let url = PulseResources.url(forResource: item.name, withExtension: item.ext, subdirectory: item.dir)
            let label = [item.dir, "\(item.name).\(item.ext)"].compactMap { $0 }.joined(separator: "/")
            if let url, FileManager.default.fileExists(atPath: url.path) {
                print("  ok      \(label)")
            } else {
                print("  MISSING \(label)")
                ok = false
            }
        }

        // A packaged app must resolve its own script even when the build
        // checkout still exists on the same Mac. Otherwise this self-test
        // validates source, not the artifact users download.
        let appRoot = Bundle.main.bundleURL.path
        if let script = ActivityHarvest.selfTestScriptPath() {
            if script.hasPrefix(appRoot + "/") {
                print("  ok      harvest script → \(script)")
            } else {
                print("  MISSING packaged harvest resolution → \(script)")
                ok = false
            }
        } else {
            print("  MISSING harvest script")
            ok = false
        }

        // Also check the direct Contents/Resources fallback explicitly.
        if Bundle.main.bundleURL.pathExtension == "app" {
            let inApp = Bundle.main.resourceURL?.appendingPathComponent("activity_scan.py")
            if let inApp, FileManager.default.fileExists(atPath: inApp.path) {
                print("  ok      activity_scan.py in Contents/Resources")
            } else {
                print("  MISSING activity_scan.py in Contents/Resources — harvest would fail on a user machine")
                ok = false
            }
        }

        print(ok ? "selftest PASSED" : "selftest FAILED")
        return ok
    }
}
