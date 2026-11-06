import AppKit
import BiliModels
import Foundation

@testable import BiliVideoDetailFeature

extension UploaderVideo {
    /// 合成的 UP 主投稿；各测试只传自己关心的字段。
    static func testFixture(
        bvid: String = "BV1FixtureA1",
        title: String = "投稿",
        durationSeconds: Int? = 60,
        viewCount: Int64? = 1,
        danmakuCount: Int64? = 0,
        isCollaboration: Bool = false
    ) -> UploaderVideo {
        UploaderVideo(
            bvid: bvid,
            title: title,
            coverURL: nil,
            durationSeconds: durationSeconds,
            viewCount: viewCount,
            danmakuCount: danmakuCount,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            isCollaboration: isCollaboration
        )
    }
}

/// 空间列表控制器的测试组装：放进无边框窗口的容器视图，按一位 UP 主与给定投稿行（已到底、没有加载行）更新一次并完成布局。
///
/// 测试结束时调用 `controller.tearDown()`。`listWidth` 是列表的初始宽度，容器始终 420×600。
@MainActor
struct UploaderSpaceListFixture {
    let controller: UploaderSpaceListController
    let window: NSWindow
    let container: NSView

    init(
        rows: [UploaderVideoRowPresentation],
        listWidth: CGFloat = 420,
        actions: UploaderSpaceListActions = .none
    ) {
        controller = UploaderSpaceListController(imagePipeline: StubVideoDetailImageLoader())
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 600))
        window.contentView = container
        controller.scrollView.frame = NSRect(x: 0, y: 0, width: listWidth, height: 600)
        container.addSubview(controller.scrollView)
        controller.update(
            content: UploaderSpaceListContent(
                header: UploaderSpaceHeaderContent(
                    name: "UP 主",
                    avatarURL: nil,
                    totalCount: nil,
                    order: .newest,
                    isSearching: false
                ),
                rows: rows,
                currentBVID: nil,
                listIdentity: .init(ownerID: 1, order: .newest, searchKeyword: nil),
                footer: .none,
                tailIdentity: nil
            ),
            actions: actions
        )
        container.layoutSubtreeIfNeeded()
    }
}
