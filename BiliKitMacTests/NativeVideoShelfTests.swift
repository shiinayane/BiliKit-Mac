import AppKit
import BiliBrowseFeature
import Foundation
import Testing

@testable import BiliKit

struct NativeVideoShelfTests {
    @Test
    @MainActor
    func fixedGeometryPreservesInsetPeekAndNarrowWindowCapacity() {
        #expect(NativeVideoShelfGeometry.cardWidth == 224)
        #expect(NativeVideoShelfGeometry.cardHeight == 210)
        #expect(NativeVideoShelfGeometry.contentInset == 40)
        #expect(NativeVideoShelfGeometry.bottomInset == 22)
        #expect(NativeVideoShelfGeometry.viewportHeight == 232)
        #expect(NativeVideoShelfGeometry.pageCapacity(viewportWidth: 784) == 3)
        #expect(NativeVideoShelfGeometry.pageCapacity(viewportWidth: 260) == 1)
        #expect(NativeVideoShelfGeometry.offset(for: 3) == 720)
        #expect(NativeVideoShelfGeometry.nearestIndex(offset: 370, itemCount: 8) == 2)
        #expect(NativeVideoShelfGeometry.documentWidth(itemCount: 0) == 0)
        #expect(NativeVideoShelfGeometry.documentWidth(itemCount: 3) == 784)
    }

    @Test
    func insetAwareScrollCoordinatesPreserveLogicalPosition() {
        #expect(
            NativeVideoShelfScrollCoordinates.logicalOffsetX(
                physicalOffsetX: -320,
                leadingInset: 320
            ) == 0
        )
        #expect(
            NativeVideoShelfScrollCoordinates.physicalOffsetX(
                logicalOffsetX: 480,
                leadingInset: 320
            ) == 160
        )
        #expect(
            NativeVideoShelfScrollCoordinates.maximumLogicalOffsetX(
                documentWidth: 1_472,
                viewportWidth: 900,
                leadingInset: 320,
                trailingInset: 0
            ) == 892
        )
    }

    @Test
    @MainActor
    func shelfKeepsHorizontalGesturesAndLeavesVerticalForwardingToItsAncestor() {
        let scrollView = NativeVideoShelfScrollView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 232)
        )
        scrollView.install(collectionView: NSCollectionView())
        scrollView.layoutSubtreeIfNeeded()

        #expect(scrollView.usesPredominantAxisScrolling)
        #expect(scrollView.automaticallyAdjustsContentInsets)
        #expect(!scrollView.wantsForwardedScrollEvents(for: .vertical))
        #expect(!scrollView.wantsForwardedScrollEvents(for: .horizontal))
        #expect(scrollView.hasHorizontalScroller)
        #expect(scrollView.horizontalScroller is NativeVideoShelfHiddenScroller)
        #expect(
            NativeVideoShelfHiddenScroller.scrollerWidth(
                for: .regular,
                scrollerStyle: .legacy
            ) == 0
        )
        #expect(!scrollView.hasVerticalScroller)
        #expect(scrollView.verticalScroller == nil)

        let buttons = scrollView.subviews.compactMap { $0 as? NativeVideoShelfPageButton }
            .sorted { $0.frame.minX < $1.frame.minX }
        #expect(buttons.count == 2)
        if #available(macOS 26.0, *) {
            #expect(buttons.allSatisfy { $0.bezelStyle == .glass })
        } else {
            #expect(buttons.allSatisfy { $0.bezelStyle == .circular })
        }

        scrollView.updatePageAvailability(canGoBackward: true, canGoForward: true)
        #expect(buttons.allSatisfy { $0.isHidden })

        scrollView.updatePointerInside(true)
        #expect(buttons.allSatisfy { !$0.isHidden })
        #expect(buttons.allSatisfy { $0.isEnabled })

        scrollView.updatePageAvailability(canGoBackward: false, canGoForward: true)
        #expect(buttons.allSatisfy { !$0.isHidden })
        #expect(!buttons[0].isEnabled)
        #expect(buttons[1].isEnabled)

        scrollView.updatePointerInside(false)
        #expect(buttons.allSatisfy { $0.isHidden })
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func viewportAndInsetNotificationsAreDeferredBeyondTheCurrentLayoutPass() async {
        let scrollView = NativeVideoShelfScrollView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 232)
        )
        scrollView.install(collectionView: NSCollectionView())
        let (notifications, continuation) = AsyncStream<Void>.makeStream()
        var notificationCount = 0
        scrollView.onViewportLayout = {
            notificationCount += 1
            continuation.yield()
        }
        var iterator = notifications.makeAsyncIterator()

        scrollView.layoutSubtreeIfNeeded()

        #expect(notificationCount == 0)
        _ = await iterator.next()
        #expect(notificationCount == 1)

        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(
            top: 0,
            left: 120,
            bottom: 0,
            right: 0
        )
        scrollView.layout()

        #expect(notificationCount == 1)
        _ = await iterator.next()
        continuation.finish()
        #expect(notificationCount == 2)
        scrollView.reset()
    }

    @Test
    @MainActor
    func teardownClearsAnyFirstResponderInsideTheShelf() {
        let scrollView = NativeVideoShelfScrollView()
        let focusView = NativeVideoShelfFocusViewForTesting()
        scrollView.addSubview(focusView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView

        #expect(window.makeFirstResponder(focusView))
        #expect(window.firstResponder === focusView)

        scrollView.clearFirstResponderIfNeeded()

        #expect(window.firstResponder !== focusView)
        window.contentView = NSView()
    }

    @Test
    @MainActor
    func keyboardActivationResolvesStableIDWithoutVisibleItemInstance() {
        let selected = NativeVideoShelfCollectionView.selectedItemID(
            selectionIndexPaths: [IndexPath(item: 7, section: 0)],
            itemIDAtIndex: { index in index == 7 ? "BV-stable" : nil }
        )

        #expect(selected == "BV-stable")
    }

    @Test
    @MainActor
    func collectionClearsKeyboardAppearanceWhenFocusLeavesShelf() {
        let collection = NativeVideoShelfCollectionView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 220)
        )
        let replacement = ShelfFocusableTestView(
            frame: NSRect(x: 0, y: 230, width: 20, height: 20)
        )
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 260))
        content.addSubview(collection)
        content.addSubview(replacement)
        let window = NSWindow(
            contentRect: content.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = content

        #expect(window.makeFirstResponder(collection))
        #expect(collection.showsKeyboardSelection)
        #expect(window.makeFirstResponder(replacement))
        #expect(!collection.showsKeyboardSelection)

        window.contentView = NSView()
    }

    @Test
    @MainActor
    func sameContentIdentityReloadsChangedCardWithoutResettingTheShelf() {
        let old = presentation(id: "BV-a", title: "旧标题")
        let updated = presentation(id: "BV-a", title: "新标题")
        let stable = presentation(id: "BV-b", title: "不变")
        let plan = NativeVideoShelfUpdatePlan(
            previousContentIdentity: "BV-parent",
            updatedContentIdentity: "BV-parent",
            previousIDs: [old.id, stable.id],
            previousContents: [old.id: old, stable.id: stable],
            updatedIDs: [updated.id, stable.id],
            updatedContents: [updated.id: updated, stable.id: stable]
        )

        #expect(!plan.identityChanged)
        #expect(plan.changedExistingIDs == ["BV-a"])
    }

    @Test
    @MainActor
    func contentReplacementRequiresIdentityDiffAndLeadingResetContract() {
        let old = presentation(id: "BV-a", title: "A")
        let updated = presentation(id: "BV-b", title: "B")
        let plan = NativeVideoShelfUpdatePlan(
            previousContentIdentity: "BV-parent-a",
            updatedContentIdentity: "BV-parent-b",
            previousIDs: [old.id],
            previousContents: [old.id: old],
            updatedIDs: [updated.id],
            updatedContents: [updated.id: updated]
        )

        #expect(plan.identityChanged)
        #expect(plan.changedExistingIDs.isEmpty)
        #expect(NativeVideoShelfGeometry.offset(for: 0) == 0)
    }

    @Test
    @MainActor
    func relatedAdapterUsesTheSharedCardSlotsAndRealAccessibilityHelp() {
        let related = RelatedVideoCardPresentation(
            bvid: "BV-related",
            title: "推荐标题",
            coverURL: URL(string: "https://example.com/cover.webp"),
            ownerName: "作者",
            viewCountText: "1.2 万",
            danmakuCountText: "345",
            durationText: "03:21",
            accessibilityLabel: "推荐标题，作者，1.2 万播放，345弹幕，时长03:21"
        )

        let native = RelatedNativeShelfView.makePresentations([related]).first

        #expect(native?.id == related.bvid)
        #expect(native?.showsAvatar == false)
        #expect(native?.coverMetrics.map(\.text) == ["1.2 万", "345"])
        #expect(native?.coverTrailingText == "03:21")
        #expect(native?.footerLeadingText == "作者")
        #expect(native?.footerTrailingText == nil)
        #expect(native?.accessibilityLabel == related.accessibilityLabel)
        #expect(native?.accessibilityHelp == "播放并替换当前视频")
    }

    @Test
    func explicitImageOwnerShutdownRejectsFutureRequests() async {
        let owner = NativeVideoImagePipelineOwner()
        let pipeline = owner.pipeline

        owner.shutdown()
        let result = await pipeline.image(
            for: URL(string: "https://i.example/after-shelf-teardown.webp")!,
            variant: .cover
        )

        #expect(result == nil)
    }

    @MainActor
    private func presentation(
        id: String,
        title: String
    ) -> NativeVideoCardPresentation {
        NativeVideoCardPresentation(
            id: id,
            title: title,
            coverURL: nil,
            avatarURL: nil,
            showsAvatar: false,
            footerLeadingText: "作者",
            accessibilityLabel: title
        )
    }
}

@MainActor
private final class NativeVideoShelfFocusViewForTesting: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
private final class ShelfFocusableTestView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
