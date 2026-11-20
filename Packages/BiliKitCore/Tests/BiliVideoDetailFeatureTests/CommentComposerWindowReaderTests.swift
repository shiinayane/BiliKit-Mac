import AppKit
import SwiftUI
import Testing

@testable import BiliVideoDetailFeature

/// 评论入口叠在 AppKit 评论列表上方：入口用来读窗口的视图覆盖底部整宽一条，但不挡住下面列表的点击与滚轮。
struct CommentComposerWindowReaderTests {
    @Test @MainActor
    func windowReaderLetsClicksReachTheListBelow() throws {
        let list = NSView()
        let readerHeight: CGFloat = 60
        let root = ZStack {
            HitTargetView(view: list)
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: readerHeight)
                .background {
                    CommentComposerWindowReader(reference: CommentComposerWindowReference())
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        let y = hosting.isFlipped ? hosting.bounds.height - readerHeight / 2 : readerHeight / 2
        let superview = try #require(hosting.superview)
        let hit = superview.hitTest(hosting.convert(NSPoint(x: 100, y: y), to: superview))
        #expect(hit === list || hit?.isDescendant(of: list) == true)
    }
}

/// 代表评论列表的 AppKit 视图，只用来接收命中测试。
private struct HitTargetView: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView { view }

    func updateNSView(_ view: NSView, context: Context) {}
}
