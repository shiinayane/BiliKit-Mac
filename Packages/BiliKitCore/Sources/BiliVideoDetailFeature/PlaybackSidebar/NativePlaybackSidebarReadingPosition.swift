/// 播放侧栏拆除时留下的阅读位置，同一播放项重新挂上侧栏时恢复（规则见 docs/ARCHITECTURE.md「动线与侧栏上下文层」）。
///
/// 宿主每个窗口持有一份，跨侧栏的拆除与重建存活：播放页被浏览类页面盖住时侧栏换成来源导航，原生侧栏随之拆除，
/// 返回时重建；评论数据还在 ViewModel 里，没有这一份就会回到顶部。只有一格：控制器 `tearDown` 时写入，下一次挂上时
/// 取出并清空，不论是否恢复。所以中间又挂过另一个播放项（盖住它的页面里再打开视频）时，回到更早的那一项不恢复、回到顶部。
/// 不拥有评论数据与滚动视图；位置是语义锚点（条目身份与它到视口顶边的距离），不是偏移，重建后行高先按估算排也能对上。
@MainActor
public final class NativePlaybackSidebarReadingPosition {
    struct Saved {
        /// 宿主给的播放项标识（历史项），区分同一视频的两次打开。
        let placement: AnyHashable
        let bvid: String
        let anchor: NativePlaybackSidebarController.Anchor
    }

    private var saved: Saved?

    public init() {}

    func save(_ saved: Saved?) {
        self.saved = saved
    }

    /// 取出这一播放项留下的位置并清空这一格；标识不同时返回 nil。
    func take(placement: AnyHashable) -> Saved? {
        defer { saved = nil }
        guard let saved, saved.placement == placement else { return nil }
        return saved
    }
}
