// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PulseBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PulseBar", targets: ["PulseBar"]),
    ],
    targets: [
        .executableTarget(
            name: "PulseBar",
            path: "Sources/PulseBar",
            resources: [
                .copy("Resources/activity_scan.py"),
                .copy("Resources/pulse_hook.py"),
                .copy("Resources/install_hooks.py"),
                .copy("Resources/AgentIcons"),
                .copy("Resources/Brand"),
            ]
        ),
    ]
)
