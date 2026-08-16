// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DanmakuLab",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "DanmakuLab", targets: ["DanmakuLab"])
    ],
    dependencies: [
        .package(path: "../../Packages/BiliKitCore")
    ],
    targets: [
        .target(
            name: "DanmakuLabCore",
            dependencies: [
                .product(name: "BiliApplication", package: "BiliKitCore"),
                .product(name: "BiliDanmaku", package: "BiliKitCore"),
                .product(name: "BiliModels", package: "BiliKitCore"),
            ]
        ),
        .executableTarget(
            name: "DanmakuLab",
            dependencies: [
                "DanmakuLabCore",
                .product(name: "BiliApplication", package: "BiliKitCore"),
                .product(name: "BiliDanmaku", package: "BiliKitCore"),
                .product(name: "BiliModels", package: "BiliKitCore"),
            ]
        ),
        .testTarget(
            name: "DanmakuLabCoreTests",
            dependencies: [
                "DanmakuLabCore",
                .product(name: "BiliApplication", package: "BiliKitCore"),
                .product(name: "BiliDanmaku", package: "BiliKitCore"),
                .product(name: "BiliModels", package: "BiliKitCore"),
            ]
        ),
    ]
)
