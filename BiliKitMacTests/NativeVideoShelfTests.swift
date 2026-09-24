import AppKit
import Foundation
import Testing

@testable import BiliKit

struct NativeVideoShelfTests {
    @Test
    @MainActor
    func pagingGeometryPreservesPeekAndNarrowWindowCapacity() {
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
