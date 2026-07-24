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
        .library(name: "BiliDanmaku", targets: ["BiliDanmaku"]),
        .library(name: "BiliBrowseFeature", targets: ["BiliBrowseFeature"]),
        .library(name: "BiliAuthFeature", targets: ["BiliAuthFeature"]),
        .library(name: "BiliLibraryFeature", targets: ["BiliLibraryFeature"]),
        .executable(name: "BiliAPIProbe", targets: ["BiliAPIProbe"]),
        .executable(name: "BiliAuthProbe", targets: ["BiliAuthProbe"]),
        .executable(name: "BiliPlaybackProbe", targets: ["BiliPlaybackProbe"]),
        .executable(name: "BiliDanmakuProbe", targets: ["BiliDanmakuProbe"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-protobuf.git",
            exact: "1.38.1"
        ),
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
            dependencies: [
                "BiliApplication",
                "BiliModels",
                "BiliNetworking",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            exclude: ["Remote/Protobuf/danmaku.proto"]
        ),
        .target(
            name: "BiliPlayback",
            dependencies: ["BiliApplication", "BiliModels", "BiliNetworking"]
        ),
        .target(
            name: "BiliDanmaku",
            dependencies: ["BiliApplication", "BiliModels"]
        ),
        .target(
            name: "BiliBrowseFeature",
            dependencies: ["BiliApplication", "BiliModels", "BiliUI"]
        ),
        .target(
            name: "BiliAuthFeature",
            dependencies: ["BiliApplication"]
        ),
        .target(
            name: "BiliLibraryFeature",
            dependencies: ["BiliApplication", "BiliModels", "BiliUI"]
        ),
        .target(name: "BiliUI"),
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
        .executableTarget(
            name: "BiliDanmakuProbe",
            dependencies: [
                "BiliAPI",
                "BiliApplication",
                "BiliDanmaku",
                "BiliModels",
                "BiliNetworking",
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
            name: "BiliDanmakuTests",
            dependencies: [
                "BiliApplication",
                "BiliDanmaku",
                "BiliModels",
            ]
        ),
        .testTarget(
            name: "BiliBrowseFeatureTests",
            dependencies: [
                "BiliApplication",
                "BiliBrowseFeature",
                "BiliModels",
                "BiliUI",
            ]
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
