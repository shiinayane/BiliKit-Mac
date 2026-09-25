import AppKit
import Testing

@testable import BiliKit

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
}
