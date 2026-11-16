import AppKit
import BiliUI
import Testing

@testable import BiliVideoCollectionUI

/// 人物卡片网格按自己的几何移动键盘选择与判断近尾翻页，不沿用视频网格的列数与内容高度；卡片高度固定，名字与副标题
/// 各只占一行，副标题带换行也不撑高、不把名字顶出卡片。
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct NativePersonGridTests {
    /// 两种卡片在这个宽度下列数不同，用例才分得出网格用的是哪一份几何。
    private static let width: CGFloat = 1_120

    /// 放得下的名字与角标完整显示、不出省略号：标签的框不比系统画出全文需要的宽度窄（展开框为零说明不需要展开）。
    @Test(arguments: [("你好", nil as String?), ("极客湾Geekerwan", "互相关注")])
    func aNameThatFitsIsNotTruncated(name: String, badge: String?) {
        let card = NativePersonCardView(frame: NSRect(x: 0, y: 0, width: 260, height: 64))
        card.configure(
            presentation: NativePersonCardPresentation(
                id: "1",
                name: name,
                avatarURL: nil,
                isVIP: false,
                subtitle: "签名",
                mutualBadge: badge
            ),
            hoverDidChange: { _ in },
            activation: {}
        )
        card.layoutSubtreeIfNeeded()
        let labels = Self.textFields(in: card).filter {
            $0.stringValue == name || $0.stringValue == badge
        }

        #expect(labels.count == (badge == nil ? 1 : 2))
        for label in labels {
            let expansion = label.cell?.expansionFrame(withFrame: label.bounds, in: label) ?? .zero
            #expect(expansion == .zero, "\(label.stringValue) \(label.frame) \(expansion)")
        }
    }

    private static func textFields(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { subview in
            (subview as? NSTextField).map { [$0] } ?? textFields(in: subview)
        }
    }

    /// 签名常带换行：文字仍排在卡片之内，名字与副标题各一行高，名字不被顶到上沿。
    @Test
    func aMultilineSubtitleStaysOneLineInsideTheCard() {
        let card = NativePersonCardView(frame: NSRect(x: 0, y: 0, width: 300, height: 64))
        card.configure(
            presentation: NativePersonCardPresentation(
                id: "1",
                name: "UP 主",
                avatarURL: nil,
                isVIP: false,
                subtitle: "第一行\n第二行\n第三行"
            ),
            hoverDidChange: { _ in },
            activation: {}
        )
        card.layoutSubtreeIfNeeded()
        let labels = card.subviews.compactMap { $0 as? NSTextField }
        let name = labels.first { $0.stringValue == "UP 主" }
        let subtitle = labels.first { $0 !== name }

        #expect(name.map { $0.frame.minY > 0 && $0.frame.height < 24 } == true)
        #expect(subtitle.map { $0.frame.height < 24 } == true)
        for label in labels {
            #expect(card.bounds.contains(label.frame), "\(label.stringValue) \(label.frame)")
        }
    }

    @Test
    func downArrowMovesSelectionByThePersonGridRowLength() async throws {
        let grid = try await Self.makeGrid()
        let rowLength = grid.firstRowCardCount()
        try #require(
            rowLength != CardGridGeometry.video.columnCount(for: grid.viewportWidth),
            "\(grid.diagnostics)"
        )

        grid.collectionView.keyDown(with: try Self.downArrow(in: grid.window))

        #expect(
            grid.collectionView.selectionIndexPaths == [IndexPath(item: rowLength, section: 0)],
            "\(grid.diagnostics)"
        )
    }

    @Test
    func scrollingToTheEndOfThePersonGridLoadsTheNextPage() async throws {
        let grid = try await Self.makeGrid()
        let viewportHeight = grid.collectionView.visibleRect.height
        // 按视频网格的内容高度算，这里离底部还远：请求只能来自人物网格自己的内容高度。
        try #require(
            CardGridGeometry.video.contentHeight(for: grid.viewportWidth, itemCount: grid.ids.count)
                - grid.collectionView.frame.height
                > viewportHeight * CardGridGeometry.nearEndViewportMultiple,
            "\(grid.diagnostics)"
        )
        let requestsBeforeScrolling = grid.nearEndRequests

        grid.scroll(toLogicalOffset: grid.maximumLogicalOffset)

        #expect(grid.nearEndRequests == requestsBeforeScrolling + 1, "\(grid.diagnostics)")
    }

    private static func makeGrid() async throws -> CardGridHarness<NativePersonCardKind> {
        try await CardGridHarness<NativePersonCardKind>(
            makeCard: { id in
                NativePersonCardPresentation(
                    id: id,
                    name: "用户 \(id)",
                    avatarURL: nil,
                    isVIP: false,
                    subtitle: "签名"
                )
            },
            width: width,
            scrollerStyle: .overlay
        )
    }

    private static func downArrow(in window: NSWindow) throws -> NSEvent {
        // 窗口属性只能在主线程读；`#require` 的展开不继承主线程隔离，先取出再交给它。
        let windowNumber = window.windowNumber
        return try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: windowNumber,
                context: nil,
                characters: "\u{F701}",
                charactersIgnoringModifiers: "\u{F701}",
                isARepeat: false,
                keyCode: 125
            )
        )
    }
}
