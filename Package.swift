// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tailview",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TailviewCore", targets: ["TailviewCore"]),
        .executable(name: "Tailview", targets: ["Tailview"]),
    ],
    dependencies: [
        .package(url: "https://github.com/royalapplications/royalvnc.git", branch: "main"),
    ],
    targets: [
        .target(name: "TailviewCore"),
        .target(
            name: "TailviewVNC",
            dependencies: [
                "TailviewCore",
                .product(name: "RoyalVNCKit", package: "royalvnc"),
            ]
        ),
        .executableTarget(name: "Tailview", dependencies: ["TailviewCore", "TailviewVNC"]),
        .testTarget(
            name: "TailviewCoreTests",
            dependencies: ["TailviewCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
