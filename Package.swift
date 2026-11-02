// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Crumb",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "CrumbCore"),
        .executableTarget(name: "Crumb", dependencies: ["CrumbCore"]),
        .testTarget(name: "CrumbCoreTests", dependencies: ["CrumbCore"]),
    ]
)
