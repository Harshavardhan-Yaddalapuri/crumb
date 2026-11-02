// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Crumb",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CrumbCore"),
        .testTarget(name: "CrumbCoreTests", dependencies: ["CrumbCore"]),
    ]
)
