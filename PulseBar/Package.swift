// swift-tools-version: 5.9
// Requires a Swift 5.10 compiler: PulseCore uses `nonisolated(unsafe)`.
import PackageDescription

let package = Package(
    name: "PulseBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PulseBar", targets: ["PulseBar"]),
    ],
    targets: [
        // 12.0 · the kernel. Foundation only — no AppKit, no SwiftUI, no
        // StatusStore — so the compiler, not a review, keeps the facts Pulse
        // stands behind (evidence, code identity, bounded and link-safe IO,
        // process supervision, transcript parsing, probe cadence) free of UI
        // and app state. Checked under complete concurrency checking.
        .target(
            name: "PulseCore",
            path: "Sources/PulseCore",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                // 12.1: zero warnings, and it stays that way. A concurrency
                // warning here is a data race the compiler already found.
                .unsafeFlags(["-warnings-as-errors"]),
            ]
        ),
        // 12.3 · Respond: the permission contract and the verdict spool.
        // Foundation (+ CoreGraphics for the presence probe) over PulseCore;
        // no AppKit, no StatusStore, so the rules that decide whether a
        // verdict may be written cannot reach UI state.
        .target(
            name: "PulseRespond",
            dependencies: ["PulseCore"],
            path: "Sources/PulseRespond",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        // 12.3 · Harvest: the native collector — the scan, the walk, the
        // vendor dialects, SQLite adapters, the process probe and the
        // attention spool. It sees the catalog and the kernel, never the
        // store or the UI; the app reads what it returns.
        .target(
            name: "PulseHarvest",
            dependencies: ["PulseCore"],
            path: "Sources/PulseHarvest",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "PulseBar",
            dependencies: ["PulseCore", "PulseRespond", "PulseHarvest"],
            path: "Sources/PulseBar",
            resources: [
                .copy("Resources/pulse_hook.py"),
                .copy("Resources/install_hooks.py"),
                .copy("Resources/AgentIcons"),
                .copy("Resources/Brand"),
            ],
            // 12.3: the app target is checked under complete concurrency
            // checking too. Unlike PulseCore it is not warning-free yet, so
            // warnings stay warnings here and `scripts/concurrency_ratchet.py`
            // (CI job "Concurrency ratchet") holds the count to a baseline
            // that may only go down.
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        // The merge logic in StatusStore is the most regression-prone part of
        // the product and had no coverage at all before 0.22.
        .testTarget(
            name: "PulseBarTests",
            dependencies: ["PulseBar", "PulseCore", "PulseRespond", "PulseHarvest"],
            path: "Tests/PulseBarTests",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)
