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
        // 12.3 · Harvest; 24.0: the event sources — the attention file and
        // the activity spool the hooks write, the process table (libproc),
        // and the bounded read of one known transcript. It sees the catalog
        // and the kernel, never the store or the UI; the app reads what it
        // returns. (The name stays; the file-scraping collector is gone.)
        .target(
            name: "PulseHarvest",
            dependencies: ["PulseCore"],
            path: "Sources/PulseHarvest",
            swiftSettings: productSettings
        ),
        // 22.0 removed PulseManaged (sessions Pulse ran itself) and 23.0
        // removed PulseRespond (answering permission requests). A status
        // lamp watches orchestrators; it is not one.
        .executableTarget(
            name: "PulseBar",
            dependencies: ["PulseCore", "PulseHarvest"],
            path: "Sources/PulseBar",
            resources: [
                .copy("Resources/AgentIcons"),
                .copy("Resources/Brand"),
            ],
            // 12.4: every target is warning-free under complete concurrency
            // checking, and stays that way — the same rule as PulseCore.
            swiftSettings: productSettings
        ),
        // The session reducer and its projection are the most
        // regression-prone part of the product.
        .testTarget(
            name: "PulseBarTests",
            dependencies: ["PulseBar", "PulseCore", "PulseHarvest"],
            path: "Tests/PulseBarTests"
            // 19.0: the tests are in the Swift 6 mode too. An XCTestCase
            // subclass cannot be `@MainActor` (its superclass is not), so
            // the main-actor suites isolate their test methods instead; new
            // suites are Swift Testing (`import Testing`).
        ),
    ]
)
