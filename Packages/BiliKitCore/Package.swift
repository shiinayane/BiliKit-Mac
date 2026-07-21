// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BiliKitCore",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "BiliModels", targets: ["BiliModels"]),
        .library(name: "BiliApplication", targets: ["BiliApplication"]),
        .library(name: "BiliNetworking", targets: ["BiliNetworking"]),
        .library(name: "BiliAPI", targets: ["BiliAPI"]),
        .library(name: "BiliPlayback", targets: ["BiliPlayback"]),
        .library(name: "BiliGuestFeature", targets: ["BiliGuestFeature"]),
        .executable(name: "BiliAPIProbe", targets: ["BiliAPIProbe"]),
        .executable(name: "BiliPlaybackProbe", targets: ["BiliPlaybackProbe"]),
    ],
    targets: [
        .target(name: "BiliModels"),
        .target(
            name: "BiliApplication",
            dependencies: ["BiliModels"]
        ),
        .target(name: "BiliNetworking"),
        .target(
            name: "BiliAPI",
            dependencies: ["BiliApplication", "BiliModels", "BiliNetworking"]
        ),
        .target(
            name: "BiliPlayback",
            dependencies: ["BiliApplication", "BiliModels", "BiliNetworking"]
        ),
        .target(
            name: "BiliGuestFeature",
            dependencies: ["BiliApplication", "BiliModels"]
        ),
        .executableTarget(
            name: "BiliAPIProbe",
            dependencies: ["BiliAPI", "BiliNetworking"]
        ),
        .executableTarget(
            name: "BiliPlaybackProbe",
            dependencies: ["BiliAPI", "BiliModels", "BiliPlayback"]
        ),
        .testTarget(
            name: "BiliModelsTests",
            dependencies: ["BiliModels"]
        ),
        .testTarget(
            name: "BiliApplicationTests",
            dependencies: ["BiliApplication", "BiliModels"]
        ),
        .testTarget(
            name: "BiliNetworkingTests",
            dependencies: ["BiliNetworking"]
        ),
        .testTarget(
            name: "BiliAPITests",
            dependencies: ["BiliAPI", "BiliModels", "BiliNetworking"],
            resources: [
                .copy("Fixtures"),
            ]
        ),
        .testTarget(
            name: "BiliPlaybackTests",
            dependencies: ["BiliModels", "BiliNetworking", "BiliPlayback"],
            resources: [
                .copy("Fixtures"),
            ]
        ),
        .testTarget(
            name: "BiliGuestFeatureTests",
            dependencies: ["BiliApplication", "BiliGuestFeature", "BiliModels"]
        ),
    ]
)
