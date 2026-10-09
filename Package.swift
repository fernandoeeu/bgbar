// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "BGBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BGBar",
            path: "Sources/BGBar"
        ),
        .testTarget(name: "BGBarTests", dependencies: ["BGBar"], path: "Tests/BGBarTests"),
    ]
)
