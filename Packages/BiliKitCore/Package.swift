// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BiliKitCore",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "BiliModels", targets: ["BiliModels"]),
        .library(name: "BiliNetworking", targets: ["BiliNetworking"]),
        .library(name: "BiliPlayback", targets: ["BiliPlayback"]),
    ],
    targets: [
        .target(name: "BiliModels"),
        .target(name: "BiliNetworking"),
        .target(
            name: "BiliPlayback",
            dependencies: ["BiliModels", "BiliNetworking"]
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
