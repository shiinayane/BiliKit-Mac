import BiliModels
import CoreGraphics
import Foundation
import Testing

@testable import BiliKit

struct PopularNativeGridTests {
    @Test
    func reorderedSnapshotReloadsChangedExistingIdentityOnly() {
        let plan = PopularNativeGridUpdatePlan(
            previousBVIDs: ["BV-a", "BV-b"],
            previousContents: ["BV-a": "old", "BV-b": "same"],
            updatedBVIDs: ["BV-b", "BV-a", "BV-new"],
            updatedContents: [
                "BV-b": "same",
                "BV-a": "updated",
                "BV-new": "inserted",
            ]
        )

        #expect(plan.identityChanged)
        #expect(plan.changedBVIDs == ["BV-a", "BV-new"])
        #expect(plan.snapshotReloadBVIDs == ["BV-a"])
    }

    @Test
    func scrollRetentionKeepsLastObservedOffsetForSurfaceTeardown() {
        var retention = PopularNativeScrollOffsetRetention(initialOffsetY: -10)
        #expect(retention.offsetY == 0)

        retention.record(1_240)
        #expect(retention.offsetY == 1_240)
    }

    @Test
    func responsiveGeometryPreservesPopularGridContract() {
        #expect(PopularNativeGridGeometry.columnCount(for: 760) == 2)
        #expect(PopularNativeGridGeometry.columnCount(for: 1_080) == 4)
        #expect(PopularNativeGridGeometry.columnCount(for: 1_600) == 5)
        #expect(PopularNativeGridGeometry.topContentPadding == 0)

        let size = PopularNativeGridGeometry.itemSize(for: 1_080)
        #expect(size.width == 243)
        #expect(size.height == 220)
        #expect(
            PopularNativeGridGeometry.contentHeight(
                for: 1_080,
                itemCount: 50
            ) == 3_220
        )
    }

    @Test
    func imageApplicationGateRejectsCancellationAndLateReuseResults() {
        let current = PopularNativeReuseIdentity(bvid: "BV-current", generation: 8)

        #expect(
            PopularNativeImageApplicationGate.accepts(
                currentIdentity: current,
                resultIdentity: current,
                isCancelled: false
            )
        )
        #expect(
            !PopularNativeImageApplicationGate.accepts(
                currentIdentity: current,
                resultIdentity: current,
                isCancelled: true
            )
        )
        #expect(
            !PopularNativeImageApplicationGate.accepts(
                currentIdentity: current,
                resultIdentity: PopularNativeReuseIdentity(
                    bvid: "BV-current",
                    generation: 7
                ),
                isCancelled: false
            )
        )
        #expect(
            !PopularNativeImageApplicationGate.accepts(
                currentIdentity: current,
                resultIdentity: PopularNativeReuseIdentity(
                    bvid: "BV-old",
                    generation: 8
                ),
                isCancelled: false
            )
        )
        #expect(
            !PopularNativeImageApplicationGate.accepts(
                currentIdentity: nil,
                resultIdentity: current,
                isCancelled: false
            )
        )
    }

    @Test
    func onlyNewlyLoadedImagesAnimate() {
        #expect(!PopularNativeImageLoadOrigin.memoryCache.shouldAnimate)
        #expect(PopularNativeImageLoadOrigin.network.shouldAnimate)
    }

    @Test @MainActor
    func cardMappingKeepsStableBVIDAndOptimizedImageURLs() {
        let video = PopularVideo(
            bvid: "BV-stable",
            title: "原生卡片",
            coverURL: URL(string: "https://i0.hdslb.com/a.jpg"),
            owner: VideoOwner(
                id: 1,
                name: "作者",
                avatarURL: URL(string: "https://i1.hdslb.com/b.jpg")
            ),
            statistics: VideoStatistics(
                viewCount: 12_345,
                danmakuCount: 67,
                likeCount: 8
            ),
            durationSeconds: 125,
            publishedAt: Date(timeIntervalSince1970: 0)
        )

        let content = PopularNativeCardContent(video: video)

        #expect(content.bvid == "BV-stable")
        #expect(content.title == "原生卡片")
        #expect(content.coverURL?.absoluteString.hasSuffix("@640w_360h_1c.webp") == true)
        #expect(content.avatarURL?.absoluteString.hasSuffix("@96w_96h_1c.webp") == true)
        #expect(content.viewCount == "1.2万")
        #expect(content.danmakuCount == "67")
        #expect(content.duration == "2:05")
    }

    @Test
    func decodedImageCacheHonorsCountAndBitmapCostLimits() throws {
        var countBoundCache = PopularNativeImageCache(
            countLimit: 2,
            costLimit: 1_024
        )
        let image = try #require(makeImage(width: 4, height: 4))
        countBoundCache.insert(image, for: URL(string: "https://i.example/1")!)
        countBoundCache.insert(image, for: URL(string: "https://i.example/2")!)
        countBoundCache.insert(image, for: URL(string: "https://i.example/3")!)
        #expect(countBoundCache.count == 2)
        #expect(countBoundCache.totalCost <= 1_024)

        var costBoundCache = PopularNativeImageCache(
            countLimit: 10,
            costLimit: 100
        )
        costBoundCache.insert(image, for: URL(string: "https://i.example/a")!)
        costBoundCache.insert(image, for: URL(string: "https://i.example/b")!)
        #expect(costBoundCache.totalCost <= 100)
        #expect(costBoundCache.count <= 1)
    }

    private func makeImage(width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        return context?.makeImage()
    }
}
