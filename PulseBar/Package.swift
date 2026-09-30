// swift-tools-version: 6.2
// Xcode 26 / Swift 6.2. Every target is in the Swift 6 language mode
// (complete concurrency checking is the language, not a flag) and treats
// every warning as an error through the supported setting rather than
// `unsafeFlags`.
import PackageDescription

let strict: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "PulseBar",
    platforms: [.macOS(.v14)],
    products: [
        // The shipping app. `PulseQA` is not a product: it is built only by
        // the QA scripts, in the debug configuration.
        .executable(name: "PulseBar", targets: ["PulseBar"]),
    ],
    targets: [
        // The kernel. Foundation only — no AppKit, no SwiftUI, no store — so
        // the compiler, not a review, keeps the catalog, bounded and
        // link-safe IO, process supervision and the cadence free of UI and
        // app state.
        .target(
            name: "PulseCore",
            path: "Sources/PulseCore",
            swiftSettings: strict
        ),
        // The event sources: the attention file and the activity spool the
        // hooks write, the process table (libproc), row identity and the
        // bounded read of one known transcript. It sees the kernel, never the
        // store or the UI.
        .target(
            name: "PulseHarvest",
            dependencies: ["PulseCore"],
            path: "Sources/PulseHarvest",
            swiftSettings: strict
        ),
        // The app: the session book, the tray projection, the store, the
        // notifier, the hook receiver and installer, every view. A library,
        // so the shipping executable and the QA driver link the same code.
        .target(
            name: "PulseApp",
            dependencies: ["PulseCore", "PulseHarvest"],
            path: "Sources/PulseApp",
            resources: [
                .copy("Resources/AgentIcons"),
                .copy("Resources/Brand"),
            ],
            swiftSettings: strict
        ),
        // The shipping executable: `PulseBarMain.main()` and nothing else.
        .executableTarget(
            name: "PulseBar",
            dependencies: ["PulseApp"],
            path: "Sources/PulseBar",
            swiftSettings: strict
        ),
        // The QA driver: surface fixtures, tray fixtures and captures. It
        // reaches the app's internals through `@testable import PulseApp`,
        // so it builds in the debug configuration only
        // (`swift build --product PulseQA`); release builds name
        // `--product PulseBar`.
        .executableTarget(
            name: "PulseQA",
            dependencies: ["PulseApp", "PulseCore", "PulseHarvest"],
            path: "Sources/PulseQA",
            swiftSettings: strict
        ),
        // The session reducer and its projection are the most
        // regression-prone part of the product. Swift 6 mode like the rest;
        // not warnings-as-errors — the tests exercise deprecated AppKit on
        // purpose (appearances) and must build on every SDK CI meets. The
        // main-actor XCTest suites isolate their test methods (an
        // `XCTestCase` subclass cannot be `@MainActor`); new suites are
        // Swift Testing.
        .testTarget(
            name: "PulseBarTests",
            dependencies: ["PulseApp", "PulseQA", "PulseCore", "PulseHarvest"],
            path: "Tests/PulseBarTests"
        ),
    ]
)
