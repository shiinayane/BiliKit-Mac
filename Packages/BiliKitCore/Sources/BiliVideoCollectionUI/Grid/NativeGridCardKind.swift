import AppKit
import BiliUI

/// 网格与横排能渲染的卡片展示值：按 `id` 去重与激活，按值比对决定是否重配可见卡片。
///
/// 只携带渲染要的、已格式化的数据（视频卡片 `NativeVideoCardPresentation`、人物卡片 `NativePersonCardPresentation`）；
/// 业务判断与文案由 Feature 给出。
package protocol NativeGridCardPresentation: Identifiable, Equatable, Sendable where ID == String {
    /// 能否激活；网格与横排的激活入口、鼠标选中与按下高亮都只看它。
    var isActivatable: Bool { get }
}

/// 网格与横排卡片集合项的共同一面：键盘选择框、外观刷新、拆除与正显示的图。
///
/// 网格与横排按它遍历已实例化的卡片（`NSCollectionView.visibleCardItems`），不关心卡片种类；UP 主空间的投稿行不实现它。
@MainActor
package protocol NativeCardCollectionItem: NativeHoverableCollectionItem,
    NativeVideoMenuTargetItem
{
    /// 卡片此刻显示着的图，按图片地址；保活的网格摘下前经它取走（`NativeVideoGridHeldImages`）。
    var displayedImages: [URL: CGImage] { get }
    func setKeyboardFocusVisible(_ isVisible: Bool)
    /// 系统辅助功能显示选项（提高对比度、降低透明度）或外观变化后重画。
    func refreshEnvironmentAppearance()
    /// 复用前与拆除时调用：取消取图、递增配置代次、清空内容与回调。
    func invalidate()
}

/// 一种卡片的集合项：按展示值配置自己的外观、读屏描述与取图。
///
/// 网格与横排先按 `reuseIdentifier` 注册它，数据源每次取出或内容变化时调 `configure`；`hoverChanged` 报告卡片自己的
/// tracking area 看到的悬停变化，`activation` 是读屏按下的激活（参数是卡片 ID），点击与回车由集合视图处理。
@MainActor
package protocol NativeGridCardItem: NativeCardCollectionItem {
    associatedtype Presentation: NativeGridCardPresentation

    static var reuseIdentifier: NSUserInterfaceItemIdentifier { get }

    func configure(
        presentation: Presentation,
        imagePipeline: any NativeVideoImageLoading,
        hoverChanged: @escaping (Self, Bool) -> Void,
        activation: @escaping (String) -> Void
    )
}

/// `NativeGridView` 的一种卡片：集合项（连同它的展示值）与网格几何。
///
/// 网格自己拥有保活、滚动位置恢复、近尾翻页、尾部状态、顶部附加视图、回顶与键盘选择；卡片种类只给出这两样，
/// 读屏描述、取图与外观都在集合项里，菜单由调用方按展示值经 `cardMenu` 给出。
package protocol NativeGridCardKind {
    associatedtype Item: NativeGridCardItem

    static var geometry: CardGridGeometry { get }
}

/// 视频卡片：BiliUI 的 `CardGridGeometry.video` 与加载骨架共用。
package enum NativeVideoCardKind: NativeGridCardKind {
    package typealias Item = NativeVideoCollectionItem

    package static var geometry: CardGridGeometry { .video }
}
