import AppKit
import BiliUI
import BiliVideoCollectionUI
import SwiftUI

/// 空间页头部与播放页侧栏「已关注」点开的菜单：加入或移出特别关注、设置分组…、取消关注。
///
/// 实现是 App 窗口的写入协调者与关系存储，由 App 经 SwiftUI 环境 `uploaderFollowingMenu` 注入；菜单项只由 BiliUI 的
/// `UploaderFollowingMenuContent` 定义（与关注页卡片的右键菜单同一份），每次弹出时按此刻的关系重新构造。闭包只转发意图，
/// 门槛与请求由协调者在执行时重新核对。取消关注各处的写入口不同（空间页、播放页各有自己的乐观改动），由调用方在弹出时给出。
/// 整页空间页与播放页在关注状态是已关注时经 `prefetch` 预读关系，菜单弹出时就有状态（侧栏的空间预览不读）。没有注入
/// （预览、测试）时为 nil，「已关注」照旧点一下取消关注。
public struct UploaderFollowingMenu: Sendable {
    /// 这个人此刻是否在特别关注；不知道（还没读到或读取失败）时为 nil，菜单里依赖它的两项不可用。
    public let isSpecial: @MainActor @Sendable (_ mid: Int64) -> Bool?
    public let isWritable: @MainActor @Sendable () -> Bool
    /// 读一次这个人的关系；已知完整分组或在读时不重复读，上次读取失败时再读。
    ///
    /// 调用方只在已登录、已关注时调用。
    public let prefetch: @MainActor @Sendable (_ mid: Int64) -> Void
    public let setSpecial: @MainActor @Sendable (_ isSpecial: Bool, _ mid: Int64) -> Void
    public let chooseGroups: @MainActor @Sendable (_ mid: Int64) -> Void

    public init(
        isSpecial: @escaping @MainActor @Sendable (_ mid: Int64) -> Bool?,
        isWritable: @escaping @MainActor @Sendable () -> Bool,
        prefetch: @escaping @MainActor @Sendable (_ mid: Int64) -> Void,
        setSpecial: @escaping @MainActor @Sendable (_ isSpecial: Bool, _ mid: Int64) -> Void,
        chooseGroups: @escaping @MainActor @Sendable (_ mid: Int64) -> Void
    ) {
        self.isSpecial = isSpecial
        self.isWritable = isWritable
        self.prefetch = prefetch
        self.setSpecial = setSpecial
        self.chooseGroups = chooseGroups
    }

    /// 在 `view` 下方弹出这个人的菜单；`unfollow` 是调用方自己的取消关注入口。
    ///
    /// 弹出前先 `prefetch`：页面出现时的预读失败过、或还没读到时再读一次，这次菜单里依赖它的两项仍不可用，下次弹出就有。
    /// `view` 的坐标可能不是翻转的（SwiftUI 按钮背后的锚点视图），按它是否翻转换算“下方”。
    ///
    /// 菜单按点按此刻的关系构造，推到下一轮 runloop 再弹：菜单的跟踪循环会一直阻塞到菜单关闭，在按钮动作或读屏按下里
    /// 同步弹出会让读屏等到超时（与卡片菜单的 `presentCardMenu` 同一原因）。届时锚点已离开窗口就不弹。
    @MainActor
    func popUp(mid: Int64, below view: NSView, unfollow: @escaping @MainActor () -> Void) {
        prefetch(mid)
        let content = UploaderFollowingMenuContent(
            isSpecial: isSpecial(mid),
            isWritable: isWritable()
        )
        let items = NativeVideoCardMenu.Item.following(content) { action in
            switch action {
            case .setSpecial(let isSpecial): setSpecial(isSpecial, mid)
            case .chooseGroups: chooseGroups(mid)
            case .unfollow: unfollow()
            }
        }
        guard let menu = NativeVideoCardMenu(sections: [items])?.makeMenu() else { return }
        DispatchQueue.main.async { [weak view] in
            guard let view, view.window != nil else { return }
            let below = view.isFlipped ? view.bounds.height + Self.menuOffset : -Self.menuOffset
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: below), in: view)
        }
    }

    /// 菜单顶边与按钮底边之间的间距。
    private static let menuOffset: CGFloat = 4
}

extension EnvironmentValues {
    /// 「已关注」菜单的写入口；App 在窗口外壳上注入一次，见 `UploaderFollowingMenu`。
    @Entry public var uploaderFollowingMenu: UploaderFollowingMenu? = nil
}
