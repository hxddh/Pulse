// swift-tools-version: 6.2
// Xcode 26 / Swift 6.2. Every target is in the Swift 6 language mode
// (complete concurrency checking is the language, not a flag); every product
// target treats every warning as an error through the supported setting
// rather than `unsafeFlags`.
import PackageDescription

let strict: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "PulseBar",
    platforms: [.macOS(.v14)],
    products: [
        // The shipping app. `package.sh` builds this product alone.
        .executable(name: "PulseBar", targets: ["PulseBar"]),
        // The QA driver: fixtures and captures. Debug configuration only
        // (`swift build --product PulseQA`); never packaged.
        .executable(name: "PulseQA", targets: ["PulseQA"]),
    ],
    targets: [
        // The kernel. Foundation only — no AppKit, no SwiftUI, no
        // UserNotifications, no store — so the compiler, not a review, keeps
        // it free of UI and app state: the agent adapters (`Agents/`), the
        // protocol and the event log, the hook receiver and installer, the
        // process table (libproc), the session book and the tray projection,
        // every surface model, the copy. Its members are `package`: the app,
        // the QA driver and the tests are its only clients.
        .target(
            name: "PulseKit",
            path: "Sources/PulseKit",
            swiftSettings: strict
        ),
        // The app: the engine (scan, watchers), the store, the notifier,
        // terminal focus, the status item, every view. A library, so the
        // shipping executable and the QA driver link the same code.
        // It owns the resources, found through `PulseResources` (it resolves
        // `PulseBar_PulseApp.bundle` without trapping; the generated accessor
        // is never used — `gates.sh` greps for it).
        .target(
            name: "PulseApp",
            dependencies: ["PulseKit"],
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
        // reaches the app's internals through `@testable import PulseApp`
        // (and `PulseKit`), so it builds in the debug configuration only;
        // release builds name `--product PulseBar`.
        .executableTarget(
            name: "PulseQA",
            dependencies: ["PulseApp", "PulseKit"],
            path: "Sources/PulseQA",
            swiftSettings: strict
        ),
        // The session reducer and its projection are the most
        // regression-prone part of the product. Swift 6 mode like the rest,
        // but not warnings-as-errors. The main-actor XCTest suites isolate their test methods (an
        // `XCTestCase` subclass cannot be `@MainActor`); new suites are Swift
        // Testing. The QA fixtures are tested too, so the suite links
        // `PulseQA` as a testable executable.
        .testTarget(
            name: "PulseBarTests",
            dependencies: ["PulseApp", "PulseQA", "PulseKit"],
            path: "Tests/PulseBarTests"
        ),
    ]
)
