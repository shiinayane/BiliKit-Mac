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
        .library(name: "BiliAuth", targets: ["BiliAuth"]),
        .library(name: "BiliAPI", targets: ["BiliAPI"]),
        .library(name: "BiliPlayback", targets: ["BiliPlayback"]),
        .library(name: "BiliBrowseFeature", targets: ["BiliBrowseFeature"]),
        .library(name: "BiliAuthFeature", targets: ["BiliAuthFeature"]),
        .library(name: "BiliLibraryFeature", targets: ["BiliLibraryFeature"]),
        .executable(name: "BiliAPIProbe", targets: ["BiliAPIProbe"]),
        .executable(name: "BiliAuthProbe", targets: ["BiliAuthProbe"]),
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
            name: "BiliAuth",
            dependencies: ["BiliApplication", "BiliNetworking"]
        ),
        .target(
            name: "BiliAPI",
            dependencies: ["BiliApplication", "BiliModels", "BiliNetworking"]
        ),
        .target(
            name: "BiliPlayback",
            dependencies: ["BiliApplication", "BiliModels", "BiliNetworking"]
        ),
        .target(
            name: "BiliBrowseFeature",
            dependencies: ["BiliApplication", "BiliModels"]
        ),
        .target(
            name: "BiliAuthFeature",
            dependencies: ["BiliApplication"]
        ),
        .target(
            name: "BiliLibraryFeature",
            dependencies: ["BiliApplication", "BiliModels"]
        ),
        .executableTarget(
            name: "BiliAPIProbe",
            dependencies: ["BiliAPI", "BiliNetworking"]
        ),
        .executableTarget(
            name: "BiliAuthProbe",
            dependencies: ["BiliAuth"]
        ),
        .executableTarget(
            name: "BiliPlaybackProbe",
            dependencies: [
                "BiliAPI",
                "BiliApplication",
                "BiliModels",
                "BiliPlayback",
            ]
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
            name: "BiliAuthTests",
            dependencies: ["BiliAuth", "BiliNetworking"],
            resources: [
                .copy("Fixtures"),
            ]
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
            dependencies: [
                "BiliApplication",
                "BiliModels",
                "BiliNetworking",
                "BiliPlayback",
            ],
            resources: [
                .copy("Fixtures"),
            ]
        ),
        .testTarget(
            name: "BiliBrowseFeatureTests",
            dependencies: ["BiliApplication", "BiliBrowseFeature", "BiliModels"]
        ),
        .testTarget(
            name: "BiliAuthFeatureTests",
            dependencies: ["BiliApplication", "BiliAuthFeature"]
        ),
        .testTarget(
            name: "BiliLibraryFeatureTests",
            dependencies: ["BiliApplication", "BiliLibraryFeature", "BiliModels"]
        ),
    ]
)
