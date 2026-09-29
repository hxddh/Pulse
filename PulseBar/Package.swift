// swift-tools-version: 6.2
// 18.0: Xcode 26 / Swift 6.2. Every product target is in the Swift 6
// language mode (complete concurrency checking is the language, not a flag)
// and treats every warning as an error through the supported setting rather
// than `unsafeFlags`.
import PackageDescription

/// The rule since 12.1/12.4, now spelled the supported way.
let productSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
]

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
            // 12.1: zero warnings, and it stays that way. A concurrency
            // warning here is a data race the compiler already found.
            swiftSettings: productSettings
        ),
        // 12.3 · Respond: the permission contract and the verdict spool.
        // Foundation (+ CoreGraphics for the presence probe) over PulseCore;
        // no AppKit, no StatusStore, so the rules that decide whether a
        // verdict may be written cannot reach UI state.
        .target(
            name: "PulseRespond",
            dependencies: ["PulseCore"],
            path: "Sources/PulseRespond",
            swiftSettings: productSettings
        ),
        // 12.3 · Harvest: the native collector — the scan, the walk, the
        // vendor dialects, SQLite adapters, the process probe and the
        // attention spool. It sees the catalog and the kernel, never the
        // store or the UI; the app reads what it returns.
        .target(
            name: "PulseHarvest",
            dependencies: ["PulseCore"],
            path: "Sources/PulseHarvest",
            swiftSettings: productSettings,
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        // 12.3 · Managed: sessions Pulse runs itself — the runtime protocol
        // and the Claude runtime, the fleet, worktrees, the permission MCP
        // server, acceptance checks and workspace effect. It owns processes
        // and files, never the store or the UI.
        .target(
            name: "PulseManaged",
            dependencies: ["PulseCore"],
            path: "Sources/PulseManaged",
            swiftSettings: productSettings
        ),
        .executableTarget(
            name: "PulseBar",
            dependencies: ["PulseCore", "PulseRespond", "PulseHarvest", "PulseManaged"],
            path: "Sources/PulseBar",
            resources: [
                .copy("Resources/pulse_hook.py"),
                .copy("Resources/install_hooks.py"),
                .copy("Resources/AgentIcons"),
                .copy("Resources/Brand"),
            ],
            // 12.4: every target is warning-free under complete concurrency
            // checking, and stays that way — the same rule as PulseCore.
            swiftSettings: productSettings,
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        // The merge logic in StatusStore is the most regression-prone part of
        // the product and had no coverage at all before 0.22.
        .testTarget(
            name: "PulseBarTests",
            dependencies: ["PulseBar", "PulseCore", "PulseRespond", "PulseHarvest", "PulseManaged"],
            path: "Tests/PulseBarTests",
            // The XCTest suites predate Swift 6: twenty `@MainActor`
            // XCTestCase subclasses are an error in the Swift 6 mode. New
            // suites are Swift Testing (`import Testing`), which has no such
            // superclass; the XCTest suites move over as they are touched.
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)
