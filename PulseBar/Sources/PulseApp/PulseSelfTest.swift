import Foundation

/// `PulseBar --selftest`: prove the packaged app can find its own resources.
///
/// Every static check of the `.app` encodes an assumption about *where* the
/// runtime looks, and such an assumption has been wrong before: a resource
/// bundle packaged where the SwiftPM accessor never looks passes every
/// structural check, and the app still dies on launch.
///
/// So this asks the only question that matters, from inside the real bundle,
/// using the real lookup code: can it resolve the resources? It deliberately
/// runs before any AppKit initialisation, so it works on a headless CI runner
/// with no WindowServer.
enum PulseSelfTest {
    /// Resources the app cannot do its job without.
    private static let required: [(name: String, ext: String, dir: String?)] = [
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

        print(ok ? "selftest PASSED" : "selftest FAILED")
        return ok
    }
}
