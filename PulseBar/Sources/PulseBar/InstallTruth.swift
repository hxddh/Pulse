import AppKit
import Foundation

/// Runtime installation truth for a menu-bar app that is easy to leave running
/// from an old copy.
///
/// The update feed can say "current" while the user is actually looking at a
/// different Pulse.app. Keep the running bundle, every discoverable app copy,
/// and other live bundle paths separate so Settings can explain that state
/// without guessing.
enum InstallTruth {
    struct Copy: Identifiable, Equatable {
        var url: URL
        var version: String
        var commit: String
        var isRunning: Bool
        var isCurrent: Bool

        var id: String { url.resolvingSymlinksInPath().path }
    }

    struct Report: Equatable {
        var runningURL: URL
        var copies: [Copy]
        var inspectedAt: Date

        var duplicates: [Copy] { copies.filter { !$0.isCurrent } }
        var removableDuplicates: [Copy] {
            let currentVersion = copies.first(where: \.isCurrent)?.version ?? PulseVersion.semver
            return duplicates.filter {
                !$0.isRunning
                    && $0.version != "unknown"
                    && !UpdateCheck.isNewer($0.version, than: currentVersion)
            }
        }
        var hasOtherRunningCopy: Bool {
            duplicates.contains(where: \.isRunning)
        }

        static var empty: Report {
            Report(
                runningURL: Bundle.main.bundleURL,
                copies: [],
                inspectedAt: .distantPast
            )
        }
    }

    static let bundleIdentifier = "com.pulse.app"

    static func inspect() -> Report {
        let fm = FileManager.default
        let current = Bundle.main.bundleURL.resolvingSymlinksInPath()
        // Ask LaunchServices only for Pulse's own bundle identifier. This is
        // narrower than enumerating every process, avoids the protected app
        // data path that caused the privacy prompt, and still keeps duplicate
        // cleanup safe when another copy is actually running.
        let runningPaths = Set(
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .compactMap { $0.bundleURL?.resolvingSymlinksInPath().path }
        ).union([current.path])
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]

        var urls: [URL] = []
        var seen = Set<String>()
        func include(_ url: URL) {
            let resolved = url.resolvingSymlinksInPath()
            guard seen.insert(resolved.path).inserted else { return }
            guard bundleIdentifier(at: resolved) == bundleIdentifier else { return }
            urls.append(resolved)
        }

        include(current)
        for root in roots {
            guard let children = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for child in children where child.pathExtension.lowercased() == "app" {
                include(child)
            }
        }
        let copies = urls.map { url in
            let info = infoDictionary(at: url)
            return Copy(
                url: url,
                version: (info?["CFBundleShortVersionString"] as? String) ?? "unknown",
                commit: (info?["PulseGitCommit"] as? String) ?? "",
                isRunning: runningPaths.contains(url.path),
                isCurrent: url.path == current.path
            )
        }.sorted {
            if $0.isCurrent != $1.isCurrent { return $0.isCurrent && !$1.isCurrent }
            return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
        return Report(runningURL: current, copies: copies, inspectedAt: Date())
    }

    @MainActor
    static func recycle(_ copies: [Copy], completion: @escaping ([URL]) -> Void) {
        let targets = copies.filter { !$0.isCurrent && !$0.isRunning }.map(\.url)
        guard !targets.isEmpty else {
            completion([])
            return
        }
        NSWorkspace.shared.recycle(targets) { _, error in
            Task { @MainActor in
                if let error {
                    DebugLog.write("duplicate recycle failed \(error.localizedDescription)")
                    completion([])
                } else {
                    DebugLog.write("duplicate recycle count=\(targets.count)")
                    completion(targets)
                }
            }
        }
    }

    private static func infoDictionary(at appURL: URL) -> [String: Any]? {
        let url = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any]
        else { return nil }
        return object
    }

    private static func bundleIdentifier(at appURL: URL) -> String? {
        infoDictionary(at: appURL)?["CFBundleIdentifier"] as? String
    }
}
