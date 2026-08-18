import AppKit
import Combine
import SwiftUI
import Testing

@testable import BiliKit

struct NativePlaybackDetailTests {
    @Test
    func replacementIdentityResetsOnlyBetweenTwoPresentedVideos() {
        #expect(
            !NativePlaybackDetailUpdatePlan(
                previousIdentity: nil,
                updatedIdentity: "BV-initial"
            ).resetsToLeading
        )
        #expect(
            NativePlaybackDetailUpdatePlan(
                previousIdentity: "BV-a",
                updatedIdentity: "BV-b"
            ).resetsToLeading
        )
        #expect(
            !NativePlaybackDetailUpdatePlan(
                previousIdentity: "BV-a",
                updatedIdentity: "BV-a"
            ).resetsToLeading
        )
        #expect(
            !NativePlaybackDetailUpdatePlan(
                previousIdentity: "BV-a",
                updatedIdentity: nil
            ).resetsToLeading
        )
    }

    @Test
    @MainActor
    func outerDetailOwnsOnlyVerticalScrollingWithoutHorizontalElasticity() {
        let hostingController = NSHostingController(
            rootView: Color.clear.frame(height: 1)
        )
        let root = NativePlaybackDetailRootView(
            hostingController: hostingController
        )
        let scrollView = root.scrollView

        #expect(scrollView.wantsForwardedScrollEvents(for: .vertical))
        #expect(!scrollView.wantsForwardedScrollEvents(for: .horizontal))
        #expect(scrollView.hasVerticalScroller)
        #expect(!scrollView.hasHorizontalScroller)
        #expect(scrollView.usesPredominantAxisScrolling)
        #expect(scrollView.horizontalScrollElasticity == .none)
        #expect(!scrollView.allowsMagnification)
        #expect(!scrollView.automaticallyAdjustsContentInsets)

        root.reset()
    }

    @Test
    @MainActor
    func outerDetailConsumesHorizontalScrollWithoutMovingItsDocument() throws {
        let hostingController = NSHostingController(
            rootView: Color.clear.frame(height: 1_200)
        )
        let root = NativePlaybackDetailRootView(
            hostingController: hostingController
        )
        root.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = root
        window.layoutIfNeeded()
        root.layoutSubtreeIfNeeded()
        let initialOrigin = root.scrollView.contentView.bounds.origin

        root.scrollView.scrollWheel(
            with: try makeScrollWheelEvent(deltaX: -80, deltaY: 0)
        )

        #expect(root.scrollView.contentView.bounds.origin == initialOrigin)
        root.reset()
        window.contentView = NSView()
    }

    @Test
    @MainActor
    func outerDetailUsesTheLocalViewportAcrossContinuousResize() {
        let hostingController = NSHostingController(
            rootView: Color.clear.frame(height: 1_200)
        )
        let root = NativePlaybackDetailRootView(
            hostingController: hostingController
        )
        root.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = root
        window.layoutIfNeeded()
        root.layoutSubtreeIfNeeded()

        for width in [640.0, 720.0, 800.0] {
            window.setContentSize(NSSize(width: width, height: 500))
            window.layoutIfNeeded()
            root.layoutSubtreeIfNeeded()

            #expect(abs(root.bounds.width - width) <= 0.5)
            #expect(abs(root.scrollView.contentSize.width - width) <= 0.5)
            #expect(
                abs((root.scrollView.documentView?.frame.width ?? 0) - width)
                    <= 0.5
            )
            #expect(
                abs(
                    (root.scrollView.documentView?.subviews.first?.frame.width ?? 0)
                        - width
                ) <= 0.5
            )
            #expect(abs(root.scrollView.contentView.bounds.origin.x) <= 0.5)
        }

        root.reset()
        window.contentView = NSView()
    }

    @Test
    @MainActor
    func rootLeadingResetAndTeardownAreExplicit() {
        let hostingController = NSHostingController(
            rootView: Color.clear.frame(height: 1_200)
        )
        let root = NativePlaybackDetailRootView(
            hostingController: hostingController
        )
        root.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = root
        window.layoutIfNeeded()
        root.layoutSubtreeIfNeeded()

        #expect((root.scrollView.documentView?.frame.height ?? 0) >= 1_199)

        root.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 180))
        root.scrollView.reflectScrolledClipView(root.scrollView.contentView)
        #expect(root.scrollView.documentVisibleRect.minY > 0)
        root.scrollToLeading()

        #expect(root.scrollView.documentVisibleRect.minY == 0)
        #expect(root.scrollView.documentView != nil)

        root.reset()

        #expect(root.scrollView.documentView == nil)
        window.contentView = NSView()
    }

    @Test
    @MainActor
    func documentHeightReflowsFromTheConstrainedViewportWidth() {
        let hostingController = NSHostingController(
            rootView: VStack(spacing: 0) {
                Color.black
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                Color.clear.frame(height: 100)
            }
        )
        let root = NativePlaybackDetailRootView(
            hostingController: hostingController
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = root
        window.layoutIfNeeded()
        root.layoutSubtreeIfNeeded()

        #expect((root.scrollView.documentView?.frame.height ?? 0) >= 549)

        window.setContentSize(NSSize(width: 640, height: 500))
        window.layoutIfNeeded()
        root.layoutSubtreeIfNeeded()

        let resizedHeight = root.scrollView.documentView?.frame.height ?? 0
        #expect(resizedHeight >= 499)
        #expect(resizedHeight < 549)

        root.reset()
        window.contentView = NSView()
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func hostedContentHeightChangeResizesDocumentWithoutRepresentableUpdate() async {
        let model = DynamicPlaybackDetailHeightModel(height: 700)
        let relay = NativePlaybackDetailContentSizeRelay()
        let generation = relay.beginContent()
        let hostingController = NSHostingController(
            rootView: NativePlaybackDetailMeasuredContent(
                content: DynamicPlaybackDetailHeightView(model: model),
                relay: relay,
                generation: generation
            )
        )
        hostingController.sizingOptions = []
        let root = NativePlaybackDetailRootView(
            hostingController: hostingController
        )
        relay.setHandler { [weak root] size in
            root?.hostedContentSizeDidChange(size)
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = root
        window.layoutIfNeeded()
        root.layoutSubtreeIfNeeded()

        #expect((root.scrollView.documentView?.frame.height ?? 0) >= 699)

        let (sizes, continuation) = AsyncStream<CGSize>.makeStream()
        relay.setHandler { [weak root] size in
            root?.hostedContentSizeDidChange(size)
            continuation.yield(size)
        }
        model.height = 900
        for await size in sizes where size.height >= 899 {
            break
        }
        continuation.finish()
        window.layoutIfNeeded()
        root.layoutSubtreeIfNeeded()

        #expect((root.scrollView.documentView?.frame.height ?? 0) >= 899)

        relay.reset()
        root.reset()
        window.contentView = NSView()
    }

    @Test
    @MainActor
    func contentSizeRelayRejectsLateGeometryFromReplacedContent() {
        let relay = NativePlaybackDetailContentSizeRelay()
        var receivedHeights: [CGFloat] = []
        relay.setHandler { receivedHeights.append($0.height) }
        let replacedGeneration = relay.beginContent()
        let currentGeneration = relay.beginContent()

        relay.report(CGSize(width: 800, height: 700), generation: currentGeneration)
        relay.report(CGSize(width: 800, height: 180), generation: replacedGeneration)

        #expect(receivedHeights == [700])
    }

    private func makeScrollWheelEvent(
        deltaX: Int32,
        deltaY: Int32
    ) throws -> NSEvent {
        let event = try #require(
            CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: deltaY,
                wheel2: deltaX,
                wheel3: 0
            )
        )
        return try #require(NSEvent(cgEvent: event))
    }
}

@MainActor
private final class DynamicPlaybackDetailHeightModel: ObservableObject {
    @Published var height: CGFloat

    init(height: CGFloat) {
        self.height = height
    }
}

private struct DynamicPlaybackDetailHeightView: View {
    @ObservedObject var model: DynamicPlaybackDetailHeightModel

    var body: some View {
        Color.clear.frame(height: model.height)
    }
}
