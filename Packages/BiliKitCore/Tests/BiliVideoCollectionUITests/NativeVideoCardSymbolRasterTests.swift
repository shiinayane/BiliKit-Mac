import AppKit
import Testing

@testable import BiliVideoCollectionUI

/// 卡片 SF Symbol（指标图标与占位图）按 backing scale 栅格化成位图，同一组参数再次取用的是缓存里的同一张，
/// 不同外观各画一张。
struct NativeVideoCardSymbolRasterTests {
    @Test @MainActor
    func rasterMatchesBackingScaleAndIsReusedFromCache() throws {
        let appearance = try #require(NSAppearance(named: .aqua))
        let scale: CGFloat = 2
        let play = try #require(
            NativeVideoCardSymbolRasterizer.raster(
                named: "play.fill",
                pointSize: 11,
                weight: .medium,
                scale: scale,
                appearance: appearance
            )
        )

        #expect(play.image.width == Int(ceil(play.size.width * scale)))
        #expect(play.image.height == Int(ceil(play.size.height * scale)))

        let cachedPlay = try #require(
            NativeVideoCardSymbolRasterizer.raster(
                named: "play.fill",
                pointSize: 11,
                weight: .medium,
                scale: scale,
                appearance: appearance
            )
        )
        #expect(cachedPlay.image === play.image)
    }

    @Test @MainActor
    func placeholderIsCachedPerAppearance() throws {
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        let scale: CGFloat = 2
        let placeholder = try #require(
            NativeVideoCardSymbolRasterizer.placeholder(
                named: "photo",
                color: .tertiaryLabelColor,
                scale: scale,
                appearance: light
            )
        )

        #expect(placeholder.image.width == Int(ceil(placeholder.size.width * scale)))
        let cached = try #require(
            NativeVideoCardSymbolRasterizer.placeholder(
                named: "photo",
                color: .tertiaryLabelColor,
                scale: scale,
                appearance: light
            )
        )
        #expect(cached.image === placeholder.image)
        let darkPlaceholder = try #require(
            NativeVideoCardSymbolRasterizer.placeholder(
                named: "photo",
                color: .tertiaryLabelColor,
                scale: scale,
                appearance: dark
            )
        )
        #expect(darkPlaceholder.image !== placeholder.image)
    }
}
