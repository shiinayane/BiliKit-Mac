import Foundation

/// 「已关注」菜单的内容：加入或移出特别关注、设置分组…、取消关注三项的标题、图标、可用性与动作种类。
///
/// 「已关注」菜单的项只在这里定义（关注页卡片的右键菜单经 `NativeVideoCardMenu.Item.following` 生成），用到它的各处项、
/// 顺序、标题与可用性因此一致。只用基本类型（BiliUI 不依赖 BiliModels）：调用方把它知道的关系换算成
/// `isSpecial`，动作交回调用方转给 App 的写入协调者。纯值，每次弹出菜单时重新构造。
package struct UploaderFollowingMenuContent: Sendable, Equatable {
    /// 菜单项对应的写入意图。
    package enum Action: Sendable, Equatable {
        /// 加入（true）或移出（false）特别关注。
        case setSpecial(Bool)
        /// 打开「设置分组…」面板。
        case chooseGroups
        case unfollow
    }

    /// 一项：稳定标识（读屏操作按它找回这一项）、标题、SF Symbol 名、是否可用与动作。
    package struct Entry: Sendable, Equatable, Identifiable {
        package let id: String
        package let title: String
        package let systemImage: String
        package let isEnabled: Bool
        package let action: Action
    }

    package let entries: [Entry]

    /// 按这个人此刻是否在特别关注（`isSpecial`，不知道时为 nil）与窗口的写入门槛（`isWritable`）给出三项。
    ///
    /// 前两项要以 `isSpecial` 为底（加入还是移出、面板勾选什么），不知道时不可用；取消关注不需要它。不满足写入门槛时三项都
    /// 不可用。
    package init(isSpecial: Bool?, isWritable: Bool) {
        entries = [
            Entry(
                id: "toggleFollowSpecial",
                title: isSpecial == true
                    ? BiliUIStrings.localized("移出特别关注")
                    : BiliUIStrings.localized("加入特别关注"),
                systemImage: isSpecial == true ? "star.slash" : "star",
                isEnabled: isWritable && isSpecial != nil,
                action: .setSpecial(isSpecial != true)
            ),
            Entry(
                id: "chooseFollowGroups",
                title: BiliUIStrings.localized("设置分组…"),
                systemImage: "tag",
                isEnabled: isWritable && isSpecial != nil,
                action: .chooseGroups
            ),
            Entry(
                id: "unfollow",
                title: BiliUIStrings.localized("取消关注"),
                systemImage: "person.badge.minus",
                isEnabled: isWritable,
                action: .unfollow
            )
        ]
    }
}
