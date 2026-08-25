import AppKit
import Testing

@testable import BiliKit

struct NativeVideoCardSymbolRasterTests {
    @Test @MainActor
    func coverSymbolsKeepIntrinsicCanvasAndBackingScale() throws {
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
        let bubble = try #require(
            NativeVideoCardSymbolRasterizer.raster(
                named: "text.bubble.fill",
                pointSize: 11,
                weight: .medium,
                scale: scale,
                appearance: appearance
            )
        )

        #expect(play.size.width < play.size.height)
        #expect(bubble.size.width > bubble.size.height)
        #expect(play.size != bubble.size)
        #expect(play.image.width == Int(ceil(play.size.width * scale)))
        #expect(play.image.height == Int(ceil(play.size.height * scale)))
        #expect(bubble.image.width == Int(ceil(bubble.size.width * scale)))
        #expect(bubble.image.height == Int(ceil(bubble.size.height * scale)))

        let playBounds = try #require(alphaBounds(of: play.image))
        let bubbleBounds = try #require(alphaBounds(of: bubble.image))
        #expect(playBounds.width > CGFloat(play.image.width) / 2)
        #expect(playBounds.height > CGFloat(play.image.height) / 2)
        #expect(bubbleBounds.width > CGFloat(bubble.image.width) / 2)
        #expect(bubbleBounds.height > CGFloat(bubble.image.height) / 2)

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
    func coverSymbolColorsKeepPlayWhiteAndBubbleDetailsDark() throws {
        let appearance = try #require(NSAppearance(named: .aqua))
        let play = try #require(
            NativeVideoCardSymbolRasterizer.raster(
                named: "play.fill",
                pointSize: 11,
                weight: .medium,
                scale: 4,
                appearance: appearance
            )
        )
        let bubble = try #require(
            NativeVideoCardSymbolRasterizer.raster(
                named: "text.bubble.fill",
                pointSize: 11,
                weight: .medium,
                scale: 4,
                appearance: appearance
            )
        )
        let playCounts = opaqueWhiteAndDarkPixelCounts(of: play.image)
        let bubbleCounts = opaqueWhiteAndDarkPixelCounts(of: bubble.image)

        #expect(playCounts.white > 0)
        #expect(playCounts.dark == 0)
        #expect(bubbleCounts.dark > 0)
        #expect(bubbleCounts.white > bubbleCounts.dark)
    }

    private func opaqueWhiteAndDarkPixelCounts(
        of image: CGImage
    ) -> (white: Int, dark: Int) {
        let representation = NSBitmapImageRep(cgImage: image)
        var whitePixelCount = 0
        var darkPixelCount = 0

        for y in 0..<representation.pixelsHigh {
            for x in 0..<representation.pixelsWide {
                guard let color = representation.colorAt(x: x, y: y),
                    color.alphaComponent >= 0.85
                else { continue }
                let brightness =
                    (color.redComponent + color.greenComponent + color.blueComponent) / 3
                if brightness >= 0.85 { whitePixelCount += 1 }
                if brightness <= 0.15 { darkPixelCount += 1 }
            }
        }
        return (whitePixelCount, darkPixelCount)
    }

    private func alphaBounds(of image: CGImage) -> CGRect? {
        let representation = NSBitmapImageRep(cgImage: image)
        var minX = representation.pixelsWide
        var minY = representation.pixelsHigh
        var maxX = -1
        var maxY = -1

        for y in 0..<representation.pixelsHigh {
            for x in 0..<representation.pixelsWide
            where (representation.colorAt(x: x, y: y)?.alphaComponent ?? 0) >= 0.05 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )
    }
}
