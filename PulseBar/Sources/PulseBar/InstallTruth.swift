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
        // Avoid cross-app process enumeration here. New macOS releases can
        // treat cross-app enumeration as protected data and repeatedly ask for
        // Automation access. The process list is enough for this diagnostic;
        // SingleInstanceGuard already guarantees only one Pulse copy owns the
        // runtime lock.
        let runningPaths = runningPulsePaths()
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

    private static func runningPulsePaths() -> Set<String> {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "args="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            // Drain the pipe before waiting. `ps` can emit enough argv data to
            // fill the pipe buffer; waiting first then blocks both processes
            // indefinitely on a large process list, freezing the tray when it
            // calls the duplicate-install diagnostic.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return [] }
            let text = String(data: data, encoding: .utf8) ?? ""
            var paths = Set<String>()
            for line in text.split(whereSeparator: \.isNewline) {
                guard let token = line.split(whereSeparator: \.isWhitespace)
                    .first(where: { $0.contains("/Contents/MacOS/PulseBar") }) else {
                    continue
                }
                let executable = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                let bundle = URL(fileURLWithPath: executable)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .resolvingSymlinksInPath()
                if bundle.pathExtension.lowercased() == "app" {
                    paths.insert(bundle.path)
                }
            }
            return paths
        } catch {
            return []
        }
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
