// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tailview",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TailviewCore", targets: ["TailviewCore"]),
        .executable(name: "Tailview", targets: ["Tailview"]),
    ],
    targets: [
        .target(name: "TailviewCore"),
        .executableTarget(name: "Tailview", dependencies: ["TailviewCore"]),
        .testTarget(name: "TailviewCoreTests", dependencies: ["TailviewCore"]),
    ]
)
