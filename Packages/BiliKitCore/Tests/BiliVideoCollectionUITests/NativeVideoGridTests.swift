import AppKit
import BiliUI
import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import BiliVideoCollectionUI

/// 原生网格的更新计划（含锚点接替与差异动画规则）、回顶握手、滚动坐标换算、预备区域、悬停与卡片页脚宽度契约。
@Suite(.timeLimit(.minutes(1)))
struct NativeVideoGridTests {
    @Test
    func updatePlanDescribesAppendReloadAndRemovalWithoutFullReloadContract() {
        let plan = NativeVideoGridUpdatePlan(
            previousIDs: ["BV-a", "BV-b", "BV-remove"],
            previousContents: [
                "BV-a": "old",
                "BV-b": "same",
                "BV-remove": "gone"
            ],
            updatedIDs: ["BV-a", "BV-b", "BV-new"],
            updatedContents: [
                "BV-a": "updated",
                "BV-b": "same",
                "BV-new": "inserted"
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
        #expect(!append.restoresViewportAnchor)
        #expect(append.insertedIDs == ["BV-c"])
        #expect(append.changedExistingIDs.isEmpty)
        #expect(appendWithReload.isStrictTailAppend)
        #expect(!appendWithReload.restoresViewportAnchor)
        #expect(appendWithReload.changedExistingIDs == ["BV-b"])
        #expect(!reorder.isStrictTailAppend)
        #expect(reorder.restoresViewportAnchor)
    }

    @Test
    func replacementKeepsAnchorOnlyWhileAnchorCardRemains() {
        let refresh = Self.plan(from: ["BV-a", "BV-b", "BV-c"], to: ["BV-new", "BV-a"])

        let keptAnchor = NativeVideoGridViewportAnchor(id: "BV-a", offsetFromViewportTop: 0)
        let replacedAnchor = NativeVideoGridViewportAnchor(id: "BV-c", offsetFromViewportTop: 0)

        #expect(refresh.retainedAnchor(keptAnchor) == keptAnchor)
        #expect(refresh.retainedAnchor(replacedAnchor) == nil)
    }

    @Test
    func removalHandsTheAnchorToTheNextRemainingCardAtTheSameDistance() {
        let previous = ["BV-a", "BV-b", "BV-c", "BV-d", "BV-e"]
        let anchor = NativeVideoGridViewportAnchor(id: "BV-b", offsetFromViewportTop: 37)

        let single = Self.plan(from: previous, to: ["BV-a", "BV-c", "BV-d", "BV-e"])
        let mergedRemovals = Self.plan(from: previous, to: ["BV-a", "BV-d", "BV-e"])
        let removalThroughTheEnd = Self.plan(from: previous, to: ["BV-a"])
        let removalAndInsertion = Self.plan(from: previous, to: ["BV-a", "BV-c", "BV-new"])
        let removalAndReorder = Self.plan(from: previous, to: ["BV-c", "BV-a", "BV-d", "BV-e"])

        #expect(
            single.retainedAnchor(anchor) == .init(id: "BV-c", offsetFromViewportTop: 37)
        )
        #expect(
            mergedRemovals.retainedAnchor(anchor)
                == .init(id: "BV-d", offsetFromViewportTop: 37)
        )
        #expect(removalThroughTheEnd.retainedAnchor(anchor) == nil)
        #expect(removalAndInsertion.retainedAnchor(anchor) == nil)
        #expect(removalAndReorder.retainedAnchor(anchor) == nil)
    }

    @Test
    func differencesAnimateOnlyForLaidOutNonAppendChangesWithoutReducedMotion() {
        let removal = Self.plan(from: ["BV-a", "BV-b"], to: ["BV-b"])
        let replacement = Self.plan(from: ["BV-a", "BV-b"], to: ["BV-c", "BV-d"])
        let append = Self.plan(from: ["BV-a", "BV-b"], to: ["BV-a", "BV-b", "BV-c"])
        let unchanged = Self.plan(from: ["BV-a", "BV-b"], to: ["BV-a", "BV-b"])

        #expect(removal.animatesDifferences(isLaidOut: true, reducesMotion: false))
        #expect(replacement.animatesDifferences(isLaidOut: true, reducesMotion: false))
        #expect(!removal.animatesDifferences(isLaidOut: true, reducesMotion: true))
        #expect(!removal.animatesDifferences(isLaidOut: false, reducesMotion: false))
        #expect(!append.animatesDifferences(isLaidOut: true, reducesMotion: false))
        #expect(!unchanged.animatesDifferences(isLaidOut: true, reducesMotion: false))
    }

    private static func plan(
        from previous: [String],
        to updated: [String]
    )
        -> NativeVideoGridUpdatePlan
    {
        NativeVideoGridUpdatePlan(
            previousIDs: previous,
            previousContents: Dictionary(uniqueKeysWithValues: previous.map { ($0, "same") }),
            updatedIDs: updated,
            updatedContents: Dictionary(uniqueKeysWithValues: updated.map { ($0, "same") })
        )
    }

    @Test
    func scrollResetGateConsumesEachRequestIdentityOnlyOnce() {
        var gate = NativeVideoGridScrollResetGate(initialRequestID: 7)

        let sameInitialRequest = gate.consume(7)
        let nextRequest = gate.consume(8)
        let repeatedNextRequest = gate.consume(8)
        let laterRequest = gate.consume(9)

        #expect(!sameInitialRequest)
        #expect(nextRequest)
        #expect(!repeatedNextRequest)
        #expect(laterRequest)
    }

    @Test
    func scrollResetStateKeepsUnacknowledgedRequestAcrossGridRecreation() {
        var state = NativeVideoGridScrollResetState()

        state.request()
        #expect(state.requestID == 1)
        #expect(state.acknowledgedRequestID == 0)

        var recreatedGate = NativeVideoGridScrollResetGate(
            initialRequestID: state.acknowledgedRequestID
        )
        let recreatedGridConsumesPendingRequest = recreatedGate.consume(
            state.requestID
        )
        #expect(recreatedGridConsumesPendingRequest)
        state.acknowledgedRequestID = state.requestID

        var laterGate = NativeVideoGridScrollResetGate(
            initialRequestID: state.acknowledgedRequestID
        )
        let laterGridReplaysAcknowledgedRequest = laterGate.consume(
            state.requestID
        )
        #expect(!laterGridReplaysAcknowledgedRequest)
    }

    /// 纵向 toolbar inset（网格）与横向侧栏 inset（shelf）共用同一逻辑坐标换算。
    @Test(arguments: [
        (physical: CGFloat(-52), inset: CGFloat(52), logical: CGFloat(0)),
        (physical: 0, inset: 52, logical: 52),
        (physical: -320, inset: 320, logical: 0),
        (physical: 160, inset: 320, logical: 480)
    ])
    func logicalScrollOffsetIncludesLeadingInset(
        _ sample: (physical: CGFloat, inset: CGFloat, logical: CGFloat)
    ) {
        #expect(
            NativeVideoScrollCoordinateSpace.logicalOffset(
                physicalOffset: sample.physical,
                leadingInset: sample.inset
            ) == sample.logical
        )
        #expect(
            NativeVideoScrollCoordinateSpace.physicalOffset(
                logicalOffset: sample.logical,
                leadingInset: sample.inset
            ) == sample.physical
        )
    }

    @Test
    func maximumLogicalScrollOffsetIncludesBothInsets() {
        #expect(
            NativeVideoScrollCoordinateSpace.maximumLogicalOffset(
                documentLength: 2_686,
                viewportLength: 1_050,
                leadingInset: 52,
                trailingInset: 0
            ) == 1_688
        )
        #expect(
            NativeVideoScrollCoordinateSpace.maximumLogicalOffset(
                documentLength: 1_472,
                viewportLength: 900,
                leadingInset: 320,
                trailingInset: 0
            ) == 892
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
    func scrollBindingBridgeDistinguishesEchoFromExternalTopRequest() {
        var bridge = NativeVideoScrollBindingBridge(initialOffsetY: 1_200)

        #expect(bridge.takeExternalRequest(1_200) == nil)
        bridge.markSynchronized(1_500)
        #expect(bridge.takeExternalRequest(1_500) == nil)
        #expect(bridge.takeExternalRequest(0) == 0)
        #expect(bridge.takeExternalRequest(0) == nil)
    }

    /// 网格刚把位置同步出去时，同一轮更新里交回的旧值不算新请求；binding 赶上新值后旧值才重新算请求。
    @Test
    func scrollBindingBridgeIgnoresTheValueItJustReplaced() {
        var bridge = NativeVideoScrollBindingBridge(initialOffsetY: 3_066)

        bridge.markSynchronized(0)
        #expect(bridge.takeExternalRequest(3_066) == nil)
        #expect(bridge.takeExternalRequest(0) == nil)
        #expect(bridge.takeExternalRequest(3_066) == 3_066)
    }

    /// 程序回到顶部后、用户再次滚动前保持置顶；滚动代次前进后置顶失效。
    @Test
    func topPinHoldsOnlyUntilTheUserScrollsAgain() {
        var pin = NativeVideoGridTopPin()
        #expect(!pin.keepsTop(atScrollGeneration: 0))

        pin.pin(atScrollGeneration: 3)

        #expect(pin.keepsTop(atScrollGeneration: 3))
        #expect(!pin.keepsTop(atScrollGeneration: 4))
    }

    /// 视野底边离内容底部不足 `nearEndViewportMultiple` 屏时请求下一页，与可见卡片无关；首行之上的附加视图与末行之下的
    /// 悬浮控件让出的高度计入内容底部。
    @Test
    func nearEndTriggersWithinTheNearEndMultipleOfTheContentBottom() {
        let width: CGFloat = 1_080
        let viewportHeight: CGFloat = 800
        let contentHeight = CardGridGeometry.video.contentHeight(for: width, itemCount: 100)
        let threshold =
            contentHeight - viewportHeight * CardGridGeometry.nearEndViewportMultiple

        #expect(
            !CardGridGeometry.video.isNearEnd(
                itemCount: 100,
                width: width,
                visibleMaximumY: threshold,
                viewportHeight: viewportHeight,
                extraHeight: 0
            )
        )
        #expect(
            CardGridGeometry.video.isNearEnd(
                itemCount: 100,
                width: width,
                visibleMaximumY: threshold + 1,
                viewportHeight: viewportHeight,
                extraHeight: 0
            )
        )
        #expect(
            !CardGridGeometry.video.isNearEnd(
                itemCount: 100,
                width: width,
                visibleMaximumY: threshold + 1,
                viewportHeight: viewportHeight,
                extraHeight: 120
            )
        )
        #expect(
            CardGridGeometry.video.isNearEnd(
                itemCount: 100,
                width: width,
                visibleMaximumY: threshold + 121,
                viewportHeight: viewportHeight,
                extraHeight: 120
            )
        )
        #expect(
            !CardGridGeometry.video.isNearEnd(
                itemCount: 0,
                width: width,
                visibleMaximumY: 10_000,
                viewportHeight: viewportHeight,
                extraHeight: 0
            )
        )
    }

    /// 顶部附加视图占住首行上方的空间：宿主贴着内容顶端、高度就是给定的高度，首行从它下面开始。
    @Test
    @MainActor
    func topAccessorySitsAboveTheFirstRow() async throws {
        let harness = try await GridHarness(
            scrollerStyle: .overlay,
            decorations: NativeVideoGridDecorations(
                topAccessory: NativeVideoGridTopAccessory(
                    height: 112,
                    content: AnyView(Text("头部"))
                ),
                scrollToTopLabel: nil
            )
        )
        let host = try #require(
            harness.collectionView.subviews.first { $0 is NSHostingView<AnyView> }
        )
        let firstCard = try #require(
            harness.collectionView.collectionViewLayout?
                .layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame
        )

        #expect(host.frame.minY == 0)
        #expect(host.frame.height == 112)
        #expect(firstCard.minY >= host.frame.maxY, "\(harness.diagnostics)")
    }

    /// 预备区域是视野上下各 `preparedViewportMultiple` 屏，夹在内容范围内；某一侧余量少于
    /// `preparedRefreshViewportMultiple` 屏时才刷新，已到内容边缘的一侧不算不足。
    @Test
    func preparedContentKeepsAMarginAroundTheVisibleRect() {
        let bounds = NSRect(x: 0, y: 0, width: 1_000, height: 20_000)
        let visible = NSRect(x: 0, y: 8_000, width: 1_000, height: 800)
        let margin = visible.height * CardGridGeometry.preparedViewportMultiple
        let slack = visible.height * CardGridGeometry.preparedRefreshViewportMultiple
        let target = visible.insetBy(dx: 0, dy: -margin)

        #expect(
            CardGridGeometry.preparedContentRect(visible: visible, bounds: bounds) == target
        )
        let atTop = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        #expect(
            CardGridGeometry.preparedContentRect(visible: atTop, bounds: bounds)
                == NSRect(x: 0, y: 0, width: 1_000, height: atTop.height + margin)
        )
        #expect(
            !CardGridGeometry.needsPreparedContentRefresh(
                prepared: target,
                visible: visible,
                bounds: bounds
            )
        )
        var shortBelow = target
        shortBelow.size.height = visible.maxY + slack - 1 - target.minY
        #expect(
            CardGridGeometry.needsPreparedContentRefresh(
                prepared: shortBelow,
                visible: visible,
                bounds: bounds
            )
        )
        var shortAbove = target
        shortAbove.origin.y = visible.minY - slack + 1
        shortAbove.size.height = target.maxY - shortAbove.minY
        #expect(
            CardGridGeometry.needsPreparedContentRefresh(
                prepared: shortAbove,
                visible: visible,
                bounds: bounds
            )
        )
        #expect(
            CardGridGeometry.needsPreparedContentRefresh(
                prepared: .zero,
                visible: visible,
                bounds: bounds
            )
        )
        // 视野已到内容底部：下方没有可准备的内容，不算余量不足。
        let bottom = NSRect(x: 0, y: bounds.maxY - 800, width: 1_000, height: 800)
        #expect(
            !CardGridGeometry.needsPreparedContentRefresh(
                prepared: CardGridGeometry.preparedContentRect(
                    visible: bottom,
                    bounds: bounds
                ),
                visible: bottom,
                bounds: bounds
            )
        )
    }

    @Test
    @MainActor
    func hoverTrackerDropsCardThatEndsDisplayingBeforeReuse() {
        let tracker = NativeVideoHoverTracker()
        let hovered = NativeVideoCollectionItem()
        let other = NativeVideoCollectionItem()
        tracker.setHoveredItem(hovered)

        tracker.itemDidEndDisplaying(other)
        #expect(tracker.hoveredItem === hovered)

        tracker.itemDidEndDisplaying(hovered)
        #expect(tracker.hoveredItem == nil)
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
    func historyFooterReservesMeasuredWidthWithoutTruncatingTime() {
        let measured = NativeVideoCardTextLayout.singleLineWidth(
            "12月31日 19:59",
            font: .preferredFont(forTextStyle: .body)
        )
        let widths = NativeVideoCardLayout.footerWidths(
            contentWidth: 300,
            leadingInset: 0,
            trailingIntrinsicWidth: measured,
            showsTrailing: true
        )

        #expect(widths.trailing == measured)
        #expect(widths.leading + widths.trailing + NativeVideoCardLayout.footerSpacing == 300)
    }

    @Test
    func recommendationCapsulePreservesUploaderFooterWidth() {
        let widths = NativeVideoCardLayout.recommendationFooterWidths(
            contentWidth: 224,
            leadingInset: 44,
            capsuleIntrinsicWidth: 500
        )

        #expect(
            widths.leading
                >= NativeVideoCardLayout.recommendationFooterMinimumLeadingWidth
        )
        #expect(
            widths.leading + widths.trailing
                + NativeVideoCardTextLayout.recommendationCapsuleSpacing
                == 180
        )
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
}
