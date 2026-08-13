import AppKit
import BiliBrowseFeature
import BiliLibraryFeature
import BiliModels
import CoreGraphics
import Foundation
import Testing

@testable import BiliKit

struct PopularNativeGridTests {
    @Test
    func updatePlanDescribesAppendReloadAndRemovalWithoutFullReloadContract() {
        let plan = NativeVideoGridUpdatePlan(
            previousIDs: ["BV-a", "BV-b", "BV-remove"],
            previousContents: [
                "BV-a": "old",
                "BV-b": "same",
                "BV-remove": "gone",
            ],
            updatedIDs: ["BV-a", "BV-b", "BV-new"],
            updatedContents: [
                "BV-a": "updated",
                "BV-b": "same",
                "BV-new": "inserted",
            ]
        )

        #expect(plan.identityChanged)
        #expect(plan.insertedIDs == ["BV-new"])
        #expect(plan.removedIDs == ["BV-remove"])
        #expect(plan.changedExistingIDs == ["BV-a"])
        #expect(!plan.isStrictTailAppend)
    }

    @Test
    func unchangedIdentityReloadsOnlyChangedExistingCard() {
        let plan = NativeVideoGridUpdatePlan(
            previousIDs: ["BV-a", "BV-b"],
            previousContents: ["BV-a": "old", "BV-b": "same"],
            updatedIDs: ["BV-a", "BV-b"],
            updatedContents: ["BV-a": "new", "BV-b": "same"]
        )

        #expect(!plan.identityChanged)
        #expect(plan.insertedIDs.isEmpty)
        #expect(plan.removedIDs.isEmpty)
        #expect(plan.changedExistingIDs == ["BV-a"])
        #expect(!plan.isStrictTailAppend)
    }

    @Test
    func strictTailAppendPreservesExistingGeometryWithoutReorder() {
        let append = NativeVideoGridUpdatePlan(
            previousIDs: ["BV-a", "BV-b"],
            previousContents: ["BV-a": "same", "BV-b": "same"],
            updatedIDs: ["BV-a", "BV-b", "BV-c"],
            updatedContents: ["BV-a": "same", "BV-b": "same", "BV-c": "inserted"]
        )
        let appendWithReload = NativeVideoGridUpdatePlan(
            previousIDs: ["BV-a", "BV-b"],
            previousContents: ["BV-a": "same", "BV-b": "old"],
            updatedIDs: ["BV-a", "BV-b", "BV-c"],
            updatedContents: ["BV-a": "same", "BV-b": "new", "BV-c": "inserted"]
        )
        let reorder = NativeVideoGridUpdatePlan(
            previousIDs: ["BV-a", "BV-b"],
            previousContents: ["BV-a": "same", "BV-b": "same"],
            updatedIDs: ["BV-b", "BV-a", "BV-c"],
            updatedContents: ["BV-a": "same", "BV-b": "same", "BV-c": "inserted"]
        )

        #expect(append.isStrictTailAppend)
        #expect(!append.animatesDifferences)
        #expect(!append.restoresViewportAnchor)
        #expect(append.insertedIDs == ["BV-c"])
        #expect(append.changedExistingIDs.isEmpty)
        #expect(appendWithReload.isStrictTailAppend)
        #expect(!appendWithReload.animatesDifferences)
        #expect(!appendWithReload.restoresViewportAnchor)
        #expect(appendWithReload.changedExistingIDs == ["BV-b"])
        #expect(!reorder.isStrictTailAppend)
        #expect(reorder.animatesDifferences)
        #expect(reorder.restoresViewportAnchor)
    }

    @Test
    func responsiveGeometryPreservesPopularGridContract() {
        #expect(NativeVideoGridGeometry.columnCount(for: 760) == 2)
        #expect(NativeVideoGridGeometry.columnCount(for: 1_080) == 4)
        #expect(NativeVideoGridGeometry.columnCount(for: 1_600) == 5)
        #expect(NativeVideoGridGeometry.topContentPadding == 0)
        #expect(!NativeVideoGridGeometry.isRenderableViewport(width: 0))
        #expect(!NativeVideoGridGeometry.isRenderableViewport(width: 69))
        #expect(NativeVideoGridGeometry.isRenderableViewport(width: 70))
        #expect(NativeVideoGridGeometry.isRenderableViewport(width: 760))

        let size = NativeVideoGridGeometry.itemSize(for: 1_080)
        #expect(size.width == 243)
        #expect(size.height == 220)
        #expect(
            NativeVideoGridGeometry.contentHeight(
                for: 1_080,
                itemCount: 50
            ) == 3_220
        )

        for provisionalWidth in [CGFloat.zero, 1, 48, 67] {
            let provisionalSize = NativeVideoGridGeometry.itemSize(
                for: provisionalWidth
            )
            #expect(provisionalSize.width >= 1)
            #expect(provisionalSize.height >= 84)
        }
    }

    @Test
    func nearEndGateRequiresEdgeAndRearmsOnlyForNewTail() {
        var gate = NativeVideoGridNearEndGate()
        let first = NativeVideoGridTailState(
            canLoadMore: true,
            tailIdentity: "tail-1",
            isLoading: false
        )

        let outside = gate.update(isInsideThreshold: false, state: first)
        let firstEntry = gate.update(isInsideThreshold: true, state: first)
        let repeatedEntry = gate.update(isInsideThreshold: true, state: first)
        let leftThreshold = gate.update(isInsideThreshold: false, state: first)
        let sameTailReentry = gate.update(isInsideThreshold: true, state: first)
        let loading = gate.update(
            isInsideThreshold: true,
            state: NativeVideoGridTailState(
                canLoadMore: true,
                tailIdentity: "tail-1",
                isLoading: true
            )
        )
        let rearmed = gate.update(
            isInsideThreshold: true,
            state: NativeVideoGridTailState(
                canLoadMore: true,
                tailIdentity: "tail-2",
                isLoading: false
            )
        )
        let ended = gate.update(isInsideThreshold: true, state: .end)

        #expect(!outside)
        #expect(firstEntry)
        #expect(!repeatedEntry)
        #expect(!leftThreshold)
        #expect(!sameTailReentry)
        #expect(!loading)
        #expect(rearmed)
        #expect(!ended)
    }

    @Test
    func anchorRetentionPreservesItemOffsetAndClampsBounds() {
        #expect(
            NativeVideoGridAnchorRetention.targetOffsetY(
                itemOriginY: 1_200,
                offsetFromViewportTop: 40,
                maximumOffsetY: 2_000
            ) == 1_160
        )
        #expect(
            NativeVideoGridAnchorRetention.targetOffsetY(
                itemOriginY: 2_400,
                offsetFromViewportTop: 20,
                maximumOffsetY: 2_000
            ) == 2_000
        )
        #expect(
            NativeVideoGridAnchorRetention.targetOffsetY(
                itemOriginY: 10,
                offsetFromViewportTop: 40,
                maximumOffsetY: 2_000
            ) == 0
        )
    }

    @Test
    func scrollRetentionKeepsLastObservedOffsetForSurfaceTeardown() {
        var retention = NativeVideoScrollOffsetRetention(initialOffsetY: -10)
        #expect(retention.offsetY == 0)
        #expect(retention.takePendingPersistence() == nil)

        for offset in stride(from: CGFloat(10), through: 1_240, by: 10) {
            retention.record(offset)
        }

        #expect(retention.offsetY == 1_240)
        #expect(retention.takePendingPersistence() == 1_240)
        #expect(retention.takePendingPersistence() == nil)

        retention.record(1_240.4)
        #expect(retention.takePendingPersistence() == nil)
        retention.record(1_300)
        retention.markPersisted(1_300)
        #expect(retention.takePendingPersistence() == nil)
    }

    @Test
    func nearEndGeometryUsesViewportBoundaryWithoutVisibleItemEnumeration() {
        let width: CGFloat = 1_080
        let triggerOriginY =
            CGFloat(23)
            * (NativeVideoGridGeometry.itemSize(for: width).height
                + NativeVideoGridGeometry.verticalSpacing)

        #expect(
            !NativeVideoGridGeometry.isNearEnd(
                itemCount: 100,
                width: width,
                visibleMaximumY: triggerOriginY
            )
        )
        #expect(
            NativeVideoGridGeometry.isNearEnd(
                itemCount: 100,
                width: width,
                visibleMaximumY: triggerOriginY + 1
            )
        )
        #expect(
            !NativeVideoGridGeometry.isNearEnd(
                itemCount: 0,
                width: width,
                visibleMaximumY: 10_000
            )
        )
    }

    @Test
    func operationEpochRejectsSupersededSnapshotCompletion() {
        var epoch = NativeVideoGridOperationEpoch()
        let first = epoch.advance()
        let second = epoch.advance()

        #expect(!epoch.accepts(first))
        #expect(epoch.accepts(second))
    }

    @Test
    func imageApplicationGateRejectsCancellationAndLateCoverOrAvatarReuse() {
        let current = NativeVideoReuseIdentity(itemID: "BV-current", generation: 8)
        #expect(
            NativeVideoImageApplicationGate.accepts(
                currentIdentity: current,
                resultIdentity: current,
                isCancelled: false
            )
        )
        #expect(
            !NativeVideoImageApplicationGate.accepts(
                currentIdentity: current,
                resultIdentity: current,
                isCancelled: true
            )
        )
        #expect(
            !NativeVideoImageApplicationGate.accepts(
                currentIdentity: current,
                resultIdentity: NativeVideoReuseIdentity(
                    itemID: "BV-current",
                    generation: 7
                ),
                isCancelled: false
            )
        )
        #expect(
            !NativeVideoImageApplicationGate.accepts(
                currentIdentity: current,
                resultIdentity: NativeVideoReuseIdentity(
                    itemID: "BV-old",
                    generation: 8
                ),
                isCancelled: false
            )
        )
    }

    @Test
    func imagePipelineBoundsResponseAndDecodedCache() throws {
        #expect(NativeVideoImagePipeline.acceptsExpectedLength(-1))
        #expect(
            NativeVideoImagePipeline.acceptsExpectedLength(
                Int64(NativeVideoImagePipeline.maximumResponseBytes)
            )
        )
        #expect(
            !NativeVideoImagePipeline.acceptsExpectedLength(
                Int64(NativeVideoImagePipeline.maximumResponseBytes + 1)
            )
        )

        var countBoundCache = NativeVideoImageCache(
            countLimit: 2,
            costLimit: 1_024
        )
        let image = try #require(makeImage(width: 4, height: 4))
        countBoundCache.insert(image, for: imageKey("1"))
        countBoundCache.insert(image, for: imageKey("2"))
        countBoundCache.insert(image, for: imageKey("3"))
        #expect(countBoundCache.count == 2)
        #expect(countBoundCache.totalCost <= 1_024)

        var costBoundCache = NativeVideoImageCache(
            countLimit: 10,
            costLimit: 100
        )
        costBoundCache.insert(image, for: imageKey("a"))
        costBoundCache.insert(image, for: imageKey("b"))
        #expect(costBoundCache.totalCost <= 100)
        #expect(costBoundCache.count <= 1)
    }

    @Test
    func imageVariantsUseDistinctDecodeBoundsAndCacheIdentities() throws {
        #expect(NativeVideoImageVariant.cover.maximumDecodedPixelSize == 640)
        #expect(NativeVideoImageVariant.avatar.maximumDecodedPixelSize == 96)

        let url = try #require(URL(string: "https://i.example/shared.webp"))
        let coverKey = NativeVideoImageKey(url: url, variant: .cover)
        let avatarKey = NativeVideoImageKey(url: url, variant: .avatar)
        let cover = try #require(makeImage(width: 8, height: 4))
        let avatar = try #require(makeImage(width: 4, height: 4))
        var cache = NativeVideoImageCache(countLimit: 2, costLimit: 1_024)

        cache.insert(cover, for: coverKey)
        cache.insert(avatar, for: avatarKey)

        #expect(cache.count == 2)
        #expect(cache.image(for: coverKey)?.width == 8)
        #expect(cache.image(for: avatarKey)?.width == 4)
    }

    @Test
    func imageVariantsEnforceDecodedPixelBounds() throws {
        let source = try #require(makeImage(width: 1_000, height: 1_000))
        let data = try #require(
            NSBitmapImageRep(cgImage: source).representation(
                using: .png,
                properties: [:]
            )
        )
        let cover = try #require(
            NativeVideoImagePipeline.decodeImage(data, variant: .cover)
        )
        let avatar = try #require(
            NativeVideoImagePipeline.decodeImage(data, variant: .avatar)
        )

        #expect(max(cover.width, cover.height) == 640)
        #expect(max(avatar.width, avatar.height) == 96)
    }

    @Test
    func threeScreenHistoryImageWorkingSetIncludesOverscanWithinCurrentBounds() throws {
        var cache = NativeVideoImageCache(
            countLimit: NativeVideoImagePipeline.cacheCountLimit,
            costLimit: NativeVideoImagePipeline.cacheCostLimit
        )
        let cover = try #require(makeImage(width: 640, height: 360))
        let avatar = try #require(makeImage(width: 96, height: 96))

        for index in 0..<64 {
            cache.insert(cover, for: imageKey("cover-\(index)", variant: .cover))
            cache.insert(avatar, for: imageKey("avatar-\(index)", variant: .avatar))
        }

        #expect(cache.count == 128)
        #expect(cache.totalCost <= NativeVideoImagePipeline.cacheCostLimit)
        #expect(cache.image(for: imageKey("cover-0", variant: .cover)) != nil)
        #expect(cache.image(for: imageKey("avatar-0", variant: .avatar)) != nil)
    }

    @Test
    func imagePipelineShutdownRejectsFutureRequestsBeforeTouchingSession() async {
        let pipeline = NativeVideoImagePipeline()
        pipeline.shutdown()

        let result = await pipeline.image(
            for: URL(string: "https://i.example/after-shutdown.webp")!,
            variant: .cover
        )

        #expect(result == nil)
    }

    @Test
    func imageSessionGateSerializesRegistrationAndInvalidation() {
        let gate = NativeVideoImageSessionGate()
        let session = URLSession(configuration: .ephemeral)
        var registrationCount = 0

        #expect(gate.register { registrationCount += 1 })
        gate.invalidate(session)
        #expect(!gate.register { registrationCount += 1 })
        #expect(registrationCount == 1)
    }

    @Test
    func releasingImageOwnerSynchronouslyInvalidatesRetainedPipeline() async {
        var owner: NativeVideoImagePipelineOwner? = NativeVideoImagePipelineOwner()
        weak var weakOwner = owner
        let pipeline = owner!.pipeline

        owner = nil
        let result = await pipeline.image(
            for: URL(string: "https://i.example/after-owner-release.webp")!,
            variant: .cover
        )

        #expect(weakOwner == nil)
        #expect(result == nil)
    }

    @Test
    func imageResponseAccumulatorRejectsChunkBeforeExceedingBound() {
        var accumulator = NativeVideoImageResponseAccumulator(maximumBytes: 8)

        let acceptedFirst = accumulator.append(Data(repeating: 1, count: 6))
        let rejectedOverflow = accumulator.append(Data(repeating: 2, count: 3))
        #expect(accumulator.data.count == 6)
        let acceptedBoundary = accumulator.append(Data(repeating: 3, count: 2))

        #expect(acceptedFirst)
        #expect(!rejectedOverflow)
        #expect(acceptedBoundary)
        #expect(accumulator.data.count == 8)
    }

    @Test @MainActor
    func popularMappingKeepsStableBVIDAndCurrentSlots() throws {
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

        let content = try #require(
            PopularNativeGridView.makePresentations([video]).first
        )
        #expect(content.id == "BV-stable")
        #expect(content.title == "原生卡片")
        #expect(content.coverURL?.absoluteString.hasSuffix("@640w_360h_1c.webp") == true)
        #expect(content.avatarURL?.absoluteString.hasSuffix("@96w_96h_1c.webp") == true)
        #expect(content.coverMetrics.map(\.text) == ["1.2万", "67"])
        #expect(content.coverTrailingText == "2:05")
        #expect(content.showsAvatar)
        #expect(content.accessibilityLabel.contains("时长 2:05"))
    }

    @Test @MainActor
    func searchMappingKeepsStableBVIDAndFeatureFormattedSlots() throws {
        let video = SearchVideo(
            bvid: "BV-search-stable",
            title: "搜索原生卡片",
            coverURL: URL(string: "https://i0.hdslb.com/search.jpg"),
            owner: VideoOwner(
                id: 2,
                name: "搜索作者",
                avatarURL: URL(string: "https://i1.hdslb.com/avatar.jpg")
            ),
            statistics: VideoStatistics(
                viewCount: 23_456,
                danmakuCount: 89,
                likeCount: 10
            ),
            durationSeconds: 185,
            publishedAt: Date(timeIntervalSince1970: 0)
        )

        let featurePresentation = SearchVideoCardPresentation(video: video)
        let content = SearchNativeGridView.makePresentation(featurePresentation)

        #expect(content.id == "BV-search-stable")
        #expect(content.title == "搜索原生卡片")
        #expect(content.coverURL?.absoluteString.hasSuffix("@640w_360h_1c.webp") == true)
        #expect(content.avatarURL?.absoluteString.hasSuffix("@96w_96h_1c.webp") == true)
        #expect(content.coverMetrics.map(\.text) == ["2.3万", "89"])
        #expect(content.coverTrailingText == "3:05")
        #expect(content.footerLeadingText.contains("搜索作者"))
        #expect(content.accessibilityLabel.contains("时长 3:05"))
    }

    @Test @MainActor
    func historyAdapterConsumesOnlyFormattedPresentationSlots() {
        let history = WatchHistoryCardPresentation(
            item: WatchHistoryItem(
                bvid: "BV-history",
                title: "历史卡片",
                coverURL: nil,
                owner: VideoOwner(id: 9, name: "作者"),
                progressSeconds: 12,
                durationSeconds: 120,
                viewedAt: .now
            )
        )

        let content = HistoryNativeGridView.makePresentation(history)

        #expect(content.id == "BV-history")
        #expect(content.title == "历史卡片")
        #expect(content.coverMetrics.isEmpty)
        #expect(content.coverTrailingText == "0:12/2:00")
        #expect(content.footerLeadingText == "作者")
        #expect(!content.showsAvatar)
        #expect(content.accessibilityLabel == history.accessibilityLabel)
    }

    @Test @MainActor
    func historyFooterUsesAppKitFittingWidthWithoutTruncatingTime() throws {
        let field = NSTextField(labelWithString: "12月31日 19:59")
        field.font = .preferredFont(forTextStyle: .body)
        field.lineBreakMode = .byTruncatingTail
        let measured = NativeVideoCardLayout.measuredSingleLineWidth(field)
        let widths = NativeVideoCardLayout.footerWidths(
            contentWidth: 300,
            leadingInset: 0,
            trailingIntrinsicWidth: measured,
            showsTrailing: true
        )
        let cell = try #require(field.cell)
        let expansion = cell.expansionFrame(
            withFrame: NSRect(x: 0, y: 0, width: widths.trailing, height: 21),
            in: field
        )

        #expect(widths.trailing == measured)
        #expect(expansion.isEmpty)
        #expect(widths.leading + widths.trailing + NativeVideoCardLayout.footerSpacing == 300)
    }

    @Test
    func footerTrailingWidthCacheMeasuresOnlyWhenTextChanges() {
        var cache = NativeVideoSingleLineWidthCache()
        var measurements = 0

        let first = cache.width(for: "今天 19:59") {
            measurements += 1
            return 80
        }
        let repeated = cache.width(for: "今天 19:59") {
            measurements += 1
            return 999
        }
        let changed = cache.width(for: "12月31日 19:59") {
            measurements += 1
            return 100
        }
        cache.reset()
        let afterReset = cache.width(for: "12月31日 19:59") {
            measurements += 1
            return 101
        }

        #expect(first == 80)
        #expect(repeated == 80)
        #expect(changed == 100)
        #expect(afterReset == 101)
        #expect(measurements == 3)
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

    private func imageKey(
        _ path: String,
        variant: NativeVideoImageVariant = .cover
    ) -> NativeVideoImageKey {
        NativeVideoImageKey(
            url: URL(fileURLWithPath: "/native-video-cache/\(path)"),
            variant: variant
        )
    }
}
