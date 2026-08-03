import Foundation

/// Optional command-runtime lookup used only by legacy integrations.
///
/// Pulse's activity harvest is Swift-native and does not need this resolver.
/// Claude/Codex hooks and the opt-in legacy Python adapter are still supported
/// when a user has Python installed, but they must never assume one particular
/// system path (or make a missing interpreter a launch failure).
enum RuntimeResolver {
    static func python3(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        includeFallbacks: Bool = true
    ) -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []

        if let explicit = environment["PULSE_PYTHON"],
           !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(explicit)
        }

        // AppKit applications do not inherit the user's interactive shell
        // PATH. Resolve every PATH entry explicitly, then check the common
        // arm64 / Intel framework locations as optional compatibility paths.
        let pathEntries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        candidates.append(contentsOf: pathEntries.map { "\($0)/python3" })
        if includeFallbacks {
            candidates.append(contentsOf: [
                "/opt/homebrew/bin/python3",
                "/usr/local/bin/python3",
                "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
            ])
        }

        var seen = Set<String>()
        return candidates
            .filter { seen.insert($0).inserted }
            .map { URL(fileURLWithPath: $0) }
            .first { fm.isExecutableFile(atPath: $0.path) }
    }
}
