// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BiliKitCore",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "BiliModels", targets: ["BiliModels"]),
        .library(name: "BiliNetworking", targets: ["BiliNetworking"]),
        .library(name: "BiliPlayback", targets: ["BiliPlayback"]),
        .executable(name: "BiliPlaybackProbe", targets: ["BiliPlaybackProbe"]),
    ],
    targets: [
        .target(name: "BiliModels"),
        .target(name: "BiliNetworking"),
        .target(
            name: "BiliPlayback",
            dependencies: ["BiliModels", "BiliNetworking"]
        ),
        .executableTarget(
            name: "BiliPlaybackProbe",
            dependencies: ["BiliModels", "BiliPlayback"]
        ),
        .testTarget(
            name: "BiliModelsTests",
            dependencies: ["BiliModels"]
        ),
        .testTarget(
            name: "BiliNetworkingTests",
            dependencies: ["BiliNetworking"]
        ),
        .testTarget(
            name: "BiliPlaybackTests",
            dependencies: ["BiliModels", "BiliNetworking", "BiliPlayback"],
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
