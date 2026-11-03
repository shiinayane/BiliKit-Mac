import AppKit

/// 尺寸只由集合视图布局决定的集合项基类；本仓库的集合项都继承它（见 ARCHITECTURE「原生 AppKit 集合视图」）。
///
/// `NSCollectionView` 每次排可见项都会问条目 `preferredLayoutAttributesFitting(_:)`，默认实现转给条目视图，为整棵
/// 子视图临时建一个 Auto Layout 引擎做 fitting，算完即弃。我们的布局自己给出尺寸（播放侧栏的测量缓存、网格组合布局的
/// 绝对尺寸、横排与空间列表的固定尺寸），不采纳自报尺寸，所以这里原样返回；否则这笔开销在滚动时每帧都付一次。
@MainActor
open class NativeLayoutSizedCollectionItem: NSCollectionViewItem {
    override open func preferredLayoutAttributesFitting(
        _ layoutAttributes: NSCollectionViewLayoutAttributes
    ) -> NSCollectionViewLayoutAttributes {
        layoutAttributes
    }
}
