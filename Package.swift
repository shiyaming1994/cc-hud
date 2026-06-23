// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "cc-hud",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "CCHudCore"),
        .executableTarget(name: "cc-hud-emit", dependencies: ["CCHudCore"], path: "Sources/cc-hud-emit"),
        .executableTarget(name: "CCHud", dependencies: ["CCHudCore"], path: "Sources/CCHud"),
        .testTarget(name: "CCHudCoreTests", dependencies: ["CCHudCore"]),
    ]
)
