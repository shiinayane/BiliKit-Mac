import AppKit
import BiliVideoCollectionUI
import Testing

@testable import BiliVideoDetailFeature

/// UP 主空间投稿行的悬停外观与视频卡片同一份，整行在行内松开才进入播放。
@MainActor
struct VideoRowInteractionTests {
    @Test(arguments: [false, true])
    func hoverDrawsTheSameSurfaceAsVideoCards(isCurrent: Bool) throws {
        let row = VideoRowView(frame: Self.frame)
        row.setCurrent(isCurrent)
        row.setHovered(true)

        let layer = try #require(row.layer)
        let reference = CALayer()
        NativeInteractiveSurface.apply(
            NativeInteractiveSurface.State(
                isHovered: true,
                isPressed: false,
                showsFocusRing: false
            ),
            to: reference,
            appearance: row.effectiveAppearance,
            animated: false
        )
        #expect(layer.borderWidth > 0)
        #expect(layer.borderWidth == reference.borderWidth)
        #expect(layer.borderColor == reference.borderColor)
        #expect(layer.backgroundColor == reference.backgroundColor)

        row.setHovered(false)
        #expect(layer.borderWidth == 0)
    }

    @Test
    func releasingInsideActivatesOnceAndDraggingOutCancels() throws {
        let row = VideoRowView(frame: Self.frame)
        var activations = 0
        row.onActivate = { activations += 1 }
        let inside = NSPoint(x: Self.frame.midX, y: Self.frame.midY)
        let outside = NSPoint(x: Self.frame.maxX + 40, y: Self.frame.midY)

        row.mouseDown(with: try Self.event(.leftMouseDown, at: inside))
        row.mouseUp(with: try Self.event(.leftMouseUp, at: inside))
        #expect(activations == 1)

        row.mouseDown(with: try Self.event(.leftMouseDown, at: inside))
        row.mouseDragged(with: try Self.event(.leftMouseDragged, at: outside))
        row.mouseUp(with: try Self.event(.leftMouseUp, at: outside))
        #expect(activations == 1)
    }

    private static let frame = NSRect(
        x: 0,
        y: 0,
        width: 320,
        height: VideoRowGeometry.rowHeight
    )

    private static func event(_ type: NSEvent.EventType, at location: NSPoint) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
    }
}
