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
        .target(
            name: "tailview_rdpFFI",
            path: "Sources/TailviewRDP/Generated",
            sources: ["empty.c"],
            publicHeadersPath: ".",
            linkerSettings: [
                .unsafeFlags([
                    "-L\(Context.packageDirectory)/core/rdp/target/debug",
                    "-Xlinker", "-weak-ltailview_rdp",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "\(Context.packageDirectory)/core/rdp/target/debug",
                ])
            ]
        ),
        .target(
            name: "TailviewRDP",
            dependencies: ["TailviewCore", "tailview_rdpFFI"],
            exclude: [
                "Generated/empty.c",
                "Generated/module.modulemap",
                "Generated/tailview_rdpFFI.h",
            ]
        ),
        .executableTarget(name: "Tailview", dependencies: ["TailviewCore", "TailviewVNC", "TailviewRDP"]),
        .testTarget(
            name: "TailviewCoreTests",
            dependencies: ["TailviewCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
