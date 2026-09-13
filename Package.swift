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
        .package(url: "https://github.com/royalapplications/royalvnc.git", revision: "0a76294a7cdc8616b2eea5fba958415e544ed34b"),
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
            // libtailview_rdp.dylib: cargo build --manifest-path core/rdp/Cargo.toml [--release]
            linkerSettings: [
                .unsafeFlags([
                    "-L\(Context.packageDirectory)/core/rdp/target/release",
                    "-L\(Context.packageDirectory)/core/rdp/target/debug",
                    "-Xlinker", "-weak-ltailview_rdp",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "\(Context.packageDirectory)/core/rdp/target/release",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "\(Context.packageDirectory)/core/rdp/target/debug",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path",
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
        .testTarget(name: "TailviewRDPTests", dependencies: ["TailviewRDP"]),
    ]
)
