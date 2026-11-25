// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ReleaseDesk",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "ReleaseDesk", targets: ["ReleaseDesk"]),
        .executable(name: "rdesk", targets: ["rdesk"]),
        .library(name: "ReleaseKit", targets: ["ReleaseKit"]),
    ],
    targets: [
        // Store APIs, credentials, workspace and the release pipeline. No UI.
        .target(name: "ReleaseKit"),
        // The SwiftUI app.
        .executableTarget(
            name: "ReleaseDesk",
            dependencies: ["ReleaseKit"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        // A small command line front end over ReleaseKit, for scripts and checks.
        .executableTarget(name: "rdesk", dependencies: ["ReleaseKit"]),
        .testTarget(name: "ReleaseKitTests", dependencies: ["ReleaseKit"]),
    ]
)
