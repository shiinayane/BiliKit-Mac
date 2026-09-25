import AppKit
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
}
