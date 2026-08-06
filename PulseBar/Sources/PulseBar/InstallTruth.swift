import AppKit
import CoreServices
import Foundation

/// Runtime installation truth for a menu-bar app that is easy to leave running
/// from an old copy.
///
/// The update feed can say "current" while the user is actually looking at a
/// different Pulse.app. Keep the running bundle, every discoverable app copy,
/// and other live bundle paths separate so Settings can explain that state
/// without guessing.
enum InstallTruth {
    /// How many duplicate paths About lists before "and N more".
    static let aboutDuplicateLimit = 5
    enum CopyKind: String, Equatable {
        /// User-facing install under /Applications or ~/Applications.
        case currentInstalled
        /// zig-out, DerivedData, repo checkout, or other build output.
        case buildArtifact
        /// Transactional update rollback stash under Application Support.
        case rollback
        /// Another .app that is not the running copy and not a known artifact.
        case orphanDuplicate
    }

    struct Copy: Identifiable, Equatable {
        var url: URL
        var version: String
        var commit: String
        var isRunning: Bool
        var isCurrent: Bool
        var kind: CopyKind

        var id: String { url.resolvingSymlinksInPath().path }

        var isUserInstall: Bool {
            switch kind {
            case .currentInstalled, .orphanDuplicate: return true
            case .buildArtifact, .rollback: return false
            }
        }
    }

    struct Report: Equatable {
        var runningURL: URL
        var copies: [Copy]
        var inspectedAt: Date

        var duplicates: [Copy] {
            copies.filter { !$0.isCurrent && $0.isUserInstall }
        }
        /// First `aboutDuplicateLimit` duplicates for the About list.
        var aboutVisibleDuplicates: [Copy] {
            Array(duplicates.prefix(InstallTruth.aboutDuplicateLimit))
        }
        /// Count of duplicates not shown in About (0 when within the limit).
        var aboutHiddenDuplicateCount: Int {
            max(0, duplicates.count - InstallTruth.aboutDuplicateLimit)
        }
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
        var buildArtifacts: [Copy] {
            copies.filter { $0.kind == .buildArtifact }
        }
        var rollbackCopies: [Copy] {
            copies.filter { $0.kind == .rollback }
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

    static func classify(url: URL, isCurrent: Bool) -> CopyKind {
        let path = url.resolvingSymlinksInPath().path
        let lower = path.lowercased()
        if lower.contains("/library/application support/pulse/rollback") {
            return .rollback
        }
        if lower.contains("/zig-out/")
            || lower.contains("/deriveddata/")
            || lower.contains("/.build/")
            || lower.contains("/build/")
            || lower.hasSuffix("/package/pulse.app")
        {
            return .buildArtifact
        }
        let applications = "/applications/"
        let homeApps = (FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .resolvingSymlinksInPath().path + "/").lowercased()
        if lower.hasPrefix(applications) || lower.hasPrefix(homeApps) {
            return isCurrent ? .currentInstalled : .orphanDuplicate
        }
        if isCurrent { return .buildArtifact }
        return .orphanDuplicate
    }

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
        let home = fm.homeDirectoryForCurrentUser
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
            // Dropped DMGs often leave a copy on the Desktop or in Downloads;
            // one-level scan keeps cost bounded while catching the common orphans.
            home.appendingPathComponent("Desktop", isDirectory: true),
            home.appendingPathComponent("Downloads", isDirectory: true),
        ]
        let rollbackRoot = home
            .appendingPathComponent("Library/Application Support/Pulse/rollback", isDirectory: true)

        var urls: [URL] = []
        var seen = Set<String>()
        func include(_ url: URL) {
            let resolved = url.resolvingSymlinksInPath()
            guard seen.insert(resolved.path).inserted else { return }
            guard bundleIdentifier(at: resolved) == bundleIdentifier else { return }
            urls.append(resolved)
        }

        include(current)
        // Launch Services knows every registered copy, including paths outside
        // the shallow roots below (e.g. a leftover in ~/Projects).
        if let cfURLs = LSCopyApplicationURLsForBundleIdentifier(
            bundleIdentifier as CFString,
            nil
        )?.takeRetainedValue() as? [URL] {
            for url in cfURLs {
                include(url)
            }
        }
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
        if let rollbackChildren = try? fm.contentsOfDirectory(
            at: rollbackRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for child in rollbackChildren where child.pathExtension.lowercased() == "app" {
                include(child)
            }
        }

        let copies = urls.map { url -> Copy in
            let info = infoDictionary(at: url)
            let isCurrent = url.path == current.path
            return Copy(
                url: url,
                version: (info?["CFBundleShortVersionString"] as? String) ?? "unknown",
                commit: (info?["PulseGitCommit"] as? String) ?? "",
                isRunning: runningPaths.contains(url.path),
                isCurrent: isCurrent,
                kind: classify(url: url, isCurrent: isCurrent)
            )
        }.sorted {
            if $0.isCurrent != $1.isCurrent { return $0.isCurrent && !$1.isCurrent }
            return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
        return Report(runningURL: current, copies: copies, inspectedAt: Date())
    }

    @MainActor
    static func recycle(_ copies: [Copy], completion: @escaping ([URL]) -> Void) {
        // Never recycle build artifacts or rollback stashes from this path —
        // those are not user installs and may be needed for recovery.
        let targets = copies
            .filter { !$0.isCurrent && !$0.isRunning && $0.isUserInstall }
            .map(\.url)
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
