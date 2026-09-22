// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "IslandKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "IslandKit", targets: ["IslandKit"]),
        .executable(name: "island", targets: ["island"]),
        .executable(name: "island-check", targets: ["island-check"]),
    ],
    targets: [
        .target(name: "IslandKit"),
        .executableTarget(name: "island", dependencies: ["IslandKit"]),
        .executableTarget(name: "island-check", dependencies: ["IslandKit"]),
        .testTarget(name: "IslandKitTests", dependencies: ["IslandKit"]),
    ]
)
