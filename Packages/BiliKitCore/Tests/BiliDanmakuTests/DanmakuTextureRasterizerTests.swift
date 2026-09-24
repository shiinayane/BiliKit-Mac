import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

@Suite
struct DanmakuTextureRasterizerTests {
    @Test
    func styleFallsBackToDefaultsForNonFiniteInputs() {
        let nonfinite = CoreAnimationDanmakuStyle(
            fontScale: .nan,
            fontWeight: .regular,
            shadowBlurRadius: .infinity
        )

        #expect(nonfinite.fontScale == 1)
        #expect(nonfinite.shadowBlurRadius == 1)
    }

    @Test
    func unionOuterRingDoesNotEnterFillAndMapsHalfPointAtOneAndTwoX() {
        let alpha: [UInt8] = [
            0, 0, 0, 0, 0,
            0, 0, 0, 0, 0,
            0, 0, 255, 0, 0,
            0, 0, 0, 0, 0,
            0, 0, 0, 0, 0
        ]
        let oneX = DanmakuTextureRasterizer.outerRing(
            alpha: alpha,
            width: 5,
            height: 5,
            radiusPixels: 0.5
        )
        let twoX = DanmakuTextureRasterizer.outerRing(
            alpha: alpha,
            width: 5,
            height: 5,
            radiusPixels: 1
        )

        #expect(oneX[2 * 5 + 2] == 0)
        #expect(twoX[2 * 5 + 2] == 0)
        #expect(oneX[2 * 5 + 1] == 128)
        #expect(twoX[2 * 5 + 1] == 255)
        #expect(oneX[1 * 5 + 1] == 128)
        #expect(twoX[1 * 5 + 1] == 255)

        let adjacent: [UInt8] = [
            0, 0, 0, 0, 0,
            0, 255, 255, 255, 0,
            0, 0, 0, 0, 0
        ]
        let union = DanmakuTextureRasterizer.outerRing(
            alpha: adjacent,
            width: 5,
            height: 3,
            radiusPixels: 1
        )
        #expect(union[1 * 5 + 1] == 0)
        #expect(union[1 * 5 + 2] == 0)
        #expect(union[1 * 5 + 3] == 0)
    }

    @Test
    func onePointTentShadowIsZeroOffsetAndSymmetricAtOneAndTwoX() {
        let source: [UInt8] = [
            0, 0, 0, 0, 0,
            0, 0, 0, 0, 0,
            0, 0, 255, 0, 0,
            0, 0, 0, 0, 0,
            0, 0, 0, 0, 0
        ]
        let oneX = DanmakuTextureRasterizer.tentBlur(
            alpha: source,
            width: 5,
            height: 5,
            radius: 1
        )
        let twoX = DanmakuTextureRasterizer.tentBlur(
            alpha: source,
            width: 5,
            height: 5,
            radius: 2
        )

        #expect(oneX[2 * 5 + 1] == oneX[2 * 5 + 3])
        #expect(oneX[1 * 5 + 2] == oneX[3 * 5 + 2])
        #expect(twoX[2 * 5] == twoX[2 * 5 + 4])
        #expect(twoX[2] == twoX[4 * 5 + 2])
        #expect(twoX[2 * 5 + 2] > twoX[2 * 5 + 1])
        #expect(twoX[2 * 5 + 1] > twoX[2 * 5])
    }

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
            style: CoreAnimationDanmakuStyle = .production,
            backingScale: Double = 2
        ) throws -> DanmakuTextureCacheKey {
            try #require(
                DanmakuTextureRasterizer.key(
                    event: event,
                    style: style,
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
                    weight: 1
                )
            ),
            try key(
                baseEvent,
                style: CoreAnimationDanmakuStyle(
                    fontScale: 1.5,
                    fontWeight: .bold,
                    shadowBlurRadius: 4
                )
            ),
            try key(baseEvent, backingScale: 1),
            try key(
                fixtureEvent(id: "key-color", mode: .top, colorRGB: 0x204060, fontSize: 25)
            ),
            try key(
                fixtureEvent(id: "key-size", mode: .top, colorRGB: 0xFFFFFF, fontSize: 36)
            )
        ]

        for variant in variants {
            #expect(variant != base)
        }
    }

    @Test
    func byteBoundedCacheUsesLRUAndRejectsOversizedItems() throws {
        let limits = DanmakuTextureLRUCache.Limits(
            maximumItemCost: 64,
            maximumTotalCost: 96
        )
        let cache = DanmakuTextureLRUCache(limits: limits)
        let first = textureKey(text: "first")
        let second = textureKey(text: "second")
        let third = textureKey(text: "third")
        let payload = fixtureTexturePayload(byteCost: 48)

        let insertedFirst = cache.insert(payload, for: first)
        let insertedSecond = cache.insert(payload, for: second)
        let firstHit = cache.value(for: first)
        let insertedThird = cache.insert(payload, for: third)
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
        let insertedOversized = cache.insert(
            fixtureTexturePayload(byteCost: 68),
            for: second
        )
        #expect(!insertedOversized)
        #expect(cache.totalCost == 96)
        cache.removeAll()
        #expect(cache.totalCost == 0)
    }

    private func textureKey(text: String) -> DanmakuTextureCacheKey {
        DanmakuTextureCacheKey(
            text: text,
            fontSize: 25,
            colorRGB: 0xFFFFFF,
            fontWeight: .semibold,
            fontScale: 1,
            backingScale: 2,
            shadowRadiusPoints: 1
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
    )
}
