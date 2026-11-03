import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

@Suite
struct DanmakuTextureRasterizerTests {
    @Test
    func cacheKeyChangesWithEveryVisualInput() throws {
        let baseEvent = fixtureEvent(
            id: "key",
            mode: .top,
            colorRGB: 0xFFFFFF,
            fontSize: 25
        )
        func key(
            _ event: DanmakuEvent,
            backingScale: Double = 2
        ) throws -> DanmakuTextureCacheKey {
            try #require(
                DanmakuTextureRasterizer.key(
                    event: event,
                    backingScale: backingScale
                )
            )
        }
        let base = try key(baseEvent)
        let variants = [
            try key(
                DanmakuEvent(
                    id: "key-2",
                    timeSeconds: 1,
                    mode: .top,
                    text: "different",
                    fontSize: 25,
                    colorRGB: 0xFFFFFF,
                    colorStyle: .solid,
                    weight: 1,
                    isHighLike: false,
                    isUploader: false
                )
            ),
            try key(baseEvent, backingScale: 1),
            try key(
                fixtureEvent(id: "key-color", mode: .top, colorRGB: 0x204060, fontSize: 25)
            ),
            try key(
                fixtureEvent(id: "key-size", mode: .top, colorRGB: 0xFFFFFF, fontSize: 36)
            ),
            try key(
                fixtureEvent(
                    id: "key-up",
                    mode: .top,
                    colorRGB: 0xFFFFFF,
                    fontSize: 25,
                    isUploader: true
                )
            ),
            try key(
                fixtureEvent(
                    id: "key-like",
                    mode: .top,
                    colorRGB: 0xFFFFFF,
                    fontSize: 25,
                    isHighLike: true,
                    isUploader: false
                )
            )
        ]

        for variant in variants {
            #expect(variant != base)
        }
    }

    /// 车道布局只测量、不栅格化，得到的尺寸必须与在屏纹理逐像素一致，否则滚动速度与追尾判断会漂移。
    @Test(arguments: [1.0, 2.0, 3.0])
    func measurementMatchesTheRasterizedTexture(backingScale: Double) throws {
        let events = [
            fixtureEvent(id: "mixed", mode: .scrolling, fontSize: 25),
            fixtureEvent(id: "small", mode: .top, colorRGB: 0x204060, fontSize: 18),
            fixtureEvent(id: "like-small", mode: .scrolling, fontSize: 18, isHighLike: true),
            fixtureEvent(id: "uploader", mode: .scrolling, fontSize: 25, isUploader: true),
            fixtureEvent(
                id: "like",
                mode: .scrolling,
                colorRGB: 0x204060,
                fontSize: 25,
                isHighLike: true,
                isUploader: false
            ),
            DanmakuEvent(
                id: "vip",
                timeSeconds: 1,
                mode: .bottom,
                text: "大会员 VIP",
                fontSize: 36,
                colorRGB: 0x00FF00,
                colorStyle: .vipGradient,
                weight: 1,
                isHighLike: true,
                isUploader: false
            )
        ]
        var cache = DanmakuTextMeasurementCache()
        for event in events {
            let key = try #require(
                DanmakuTextureRasterizer.key(event: event, backingScale: backingScale)
            )
            let texture = try #require(DanmakuTextureRasterizer.rasterize(key: key))
            #expect(cache.metrics(for: event, backingScale: backingScale) == texture.metrics)
        }
    }

    /// 高赞图标与 UP 主的标签和黑底画在同一张纹理里：只加宽纹理，不撑高行高，同字号的车道高度不变。
    @Test(arguments: [Decoration.highLike, .uploader], DanmakuEvent.supportedFontSizes.sorted())
    func decorationWidensWithoutChangingHeight(decoration: Decoration, fontSize: Double) throws {
        func texture(decorated: Bool) throws -> DanmakuTexturePayload {
            let event = fixtureEvent(
                id: "decorated",
                mode: .scrolling,
                fontSize: fontSize,
                isHighLike: decorated && decoration == .highLike,
                isUploader: decorated && decoration == .uploader
            )
            let key = try #require(DanmakuTextureRasterizer.key(event: event, backingScale: 2))
            return try #require(DanmakuTextureRasterizer.rasterize(key: key))
        }
        let plain = try texture(decorated: false)
        let decorated = try texture(decorated: true)
        #expect(decorated.widthPixels > plain.widthPixels)
        #expect(decorated.heightPixels == plain.heightPixels)
    }

    /// 只加宽、不加高的两种纹理装饰。
    enum Decoration: Sendable {
        case highLike
        case uploader
    }

    /// 大会员彩色弹幕：缓存键与普通弹幕区分，填充固定为白色、不随事件颜色变化。
    @Test
    func vipGradientKeyIsDistinctAndAlwaysWhite() throws {
        func event(_ style: DanmakuColorStyle, colorRGB: UInt32) -> DanmakuEvent {
            DanmakuEvent(
                id: "vip",
                timeSeconds: 1,
                mode: .scrolling,
                text: "彩色弹幕",
                fontSize: 25,
                colorRGB: colorRGB,
                colorStyle: style,
                weight: 1,
                isHighLike: false,
                isUploader: false
            )
        }
        let solid = try #require(
            DanmakuTextureRasterizer.key(event: event(.solid, colorRGB: 0xFFFFFF), backingScale: 2)
        )
        let vip = try #require(
            DanmakuTextureRasterizer.key(
                event: event(.vipGradient, colorRGB: 0xFFFFFF),
                backingScale: 2
            )
        )
        let tintedVIP = try #require(
            DanmakuTextureRasterizer.key(
                event: event(.vipGradient, colorRGB: 0x204060),
                backingScale: 2
            )
        )

        #expect(vip != solid)
        #expect(tintedVIP == vip)
        #expect(vip.colorRGB == DanmakuTextureRasterizer.vipGradientFillRGB)
    }

    /// 渐变两端与中点落在采样色标上，超出文字范围时取端点。
    @Test
    func vipGradientColorFollowsTheSampledStops() {
        let stops = DanmakuTextureRasterizer.vipGradientStops
        func same(
            _ lhs: (red: UInt8, green: UInt8, blue: UInt8),
            _ rhs: (red: UInt8, green: UInt8, blue: UInt8)
        ) -> Bool {
            lhs.red == rhs.red && lhs.green == rhs.green && lhs.blue == rhs.blue
        }

        #expect(same(DanmakuTextureRasterizer.vipGradientColor(at: 0), stops[0]))
        #expect(same(DanmakuTextureRasterizer.vipGradientColor(at: -1), stops[0]))
        #expect(same(DanmakuTextureRasterizer.vipGradientColor(at: 0.5), stops[2]))
        #expect(same(DanmakuTextureRasterizer.vipGradientColor(at: 1), stops[stops.count - 1]))
        #expect(same(DanmakuTextureRasterizer.vipGradientColor(at: 2), stops[stops.count - 1]))
    }

    /// 彩色弹幕的描边左段偏粉、右段偏蓝；同样文字的普通白色弹幕没有彩色像素。
    @Test
    func vipGradientOutlineRunsFromPinkOnTheLeftToBlueOnTheRight() throws {
        func texture(_ style: DanmakuColorStyle) throws -> DanmakuTexturePayload {
            let key = DanmakuTextureCacheKey(
                text: "一二三四五六七八",
                fontSize: 25,
                isHighLike: false,
                isUploader: false,
                colorRGB: 0xFFFFFF,
                colorStyle: style,
                backingScale: 2
            )
            return try #require(DanmakuTextureRasterizer.rasterize(key: key))
        }
        /// 某一段列里所有像素的红减蓝之和；白字与深色阴影的红蓝相等，只有渐变描边贡献差值。
        func redMinusBlue(_ payload: DanmakuTexturePayload, columns: Range<Int>) -> Int {
            let bytes = [UInt8](payload.pixels)
            var total = 0
            for row in 0..<payload.heightPixels {
                for column in columns {
                    let offset = row * payload.bytesPerRow + column * 4
                    total += Int(bytes[offset]) - Int(bytes[offset + 2])
                }
            }
            return total
        }
        let vip = try texture(.vipGradient)
        let solid = try texture(.solid)
        let quarter = vip.widthPixels / 4

        #expect(redMinusBlue(vip, columns: 0..<quarter) > 0)
        #expect(redMinusBlue(vip, columns: (vip.widthPixels - quarter)..<vip.widthPixels) < 0)
        #expect(redMinusBlue(solid, columns: 0..<solid.widthPixels) == 0)
    }

    /// 纹理按像素字节判等：同一 key 各栅格化一次得到不同的 `CGImage` 对象，但两者相等；像素不同则不等。
    @Test
    func payloadsCompareByPixelBytes() throws {
        let key = textureKey(text: "awsl")
        let first = try #require(DanmakuTextureRasterizer.rasterize(key: key))
        let second = try #require(DanmakuTextureRasterizer.rasterize(key: key))
        let other = try #require(DanmakuTextureRasterizer.rasterize(key: textureKey(text: "awsm")))

        #expect(first.image !== second.image)
        #expect(first == second)
        #expect(first != other)
        #expect(first.byteCost == first.pixels.count)
        #expect(first.byteCost == first.bytesPerRow * first.heightPixels)
    }

    @Test
    @MainActor
    func byteBoundedCacheUsesLRUAndRejectsOversizedItems() throws {
        let limits = CostBoundedLRUCacheLimits(
            maximumItemCost: 64,
            maximumTotalCost: 96
        )
        let cache = CostBoundedLRUCache<DanmakuTextureCacheKey, DanmakuTexturePayload>(
            limits: limits
        )
        let first = textureKey(text: "first")
        let second = textureKey(text: "second")
        let third = textureKey(text: "third")
        let payload = fixtureTexturePayload(byteCost: 48)

        let insertedFirst = cache.insert(payload, cost: payload.byteCost, for: first)
        let insertedSecond = cache.insert(payload, cost: payload.byteCost, for: second)
        let firstHit = cache.value(for: first)
        let insertedThird = cache.insert(payload, cost: payload.byteCost, for: third)
        let evictedSecond = cache.value(for: second)
        let retainedFirst = cache.value(for: first)
        let retainedThird = cache.value(for: third)
        #expect(insertedFirst)
        #expect(insertedSecond)
        #expect(firstHit == payload)
        #expect(insertedThird)
        #expect(evictedSecond == nil)
        #expect(retainedFirst == payload)
        #expect(retainedThird == payload)
        #expect(cache.totalCost == 96)
        let oversized = fixtureTexturePayload(byteCost: 68)
        let insertedOversized = cache.insert(oversized, cost: oversized.byteCost, for: second)
        #expect(!insertedOversized)
        #expect(cache.totalCost == 96)
        cache.removeAll()
        #expect(cache.totalCost == 0)
    }

    private func textureKey(text: String) -> DanmakuTextureCacheKey {
        DanmakuTextureCacheKey(
            text: text,
            fontSize: 25,
            isHighLike: false,
            isUploader: false,
            colorRGB: 0xFFFFFF,
            colorStyle: .solid,
            backingScale: 2
        )
    }
}

func fixtureTexturePayload(byteCost: Int) -> DanmakuTexturePayload {
    DanmakuTexturePayload(
        pixels: Data(repeating: 1, count: byteCost),
        widthPixels: byteCost / 4,
        heightPixels: 1,
        bytesPerRow: byteCost,
        backingScale: 1
    )!
}
