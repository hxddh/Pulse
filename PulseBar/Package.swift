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
        .executableTarget(
            name: "PulseBar",
            dependencies: ["PulseCore"],
            path: "Sources/PulseBar",
            resources: [
                .copy("Resources/pulse_hook.py"),
                .copy("Resources/install_hooks.py"),
                .copy("Resources/AgentIcons"),
                .copy("Resources/Brand"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        // The merge logic in StatusStore is the most regression-prone part of
        // the product and had no coverage at all before 0.22.
        .testTarget(
            name: "PulseBarTests",
            dependencies: ["PulseBar", "PulseCore"],
            path: "Tests/PulseBarTests",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)
