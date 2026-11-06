/// 首页推荐、热门、搜索、观看历史、稍后再看与 UP 主空间投稿一次分页会话的上限（`PagedVideoList`）；达到任一项即停止翻页。
package enum VideoListRetention {
    /// 内存中最多保留的条目数。
    ///
    /// 1000 是取舍，没有实测依据：够一次会话连续往下浏览，同时让条目、网格卡片内容和每次并页时按已有条目
    /// 重建的去重集合都有界。调大能翻得更久，内存与每页去重开销随条目数线性增长；调小会更早收起尾标、
    /// 停止翻页。`maximumLoadedPages` 按这个值推算空页余量，改动时一并核对。
    package static let maximumItemCount = 1_000
    /// 显式继续策略（历史）一次分页会话最多加载更多的页数。
    ///
    /// 无进展即停止的来源每页至少并入一条，页数已随条目上限有界，不受此约束；历史没有新条目的页要用户显式
    /// 继续，不受条目上限约束，另以此封顶，已消费游标的线性查找随之有界。按每页 20 条，1000 条约 50 页，
    /// 这里留出同样多的空页或全重复页余量；调小会让历史在空页较多时提前停止。
    package static let maximumLoadedPages = 100
}

extension Array {
    /// 按 BVID 去重：丢弃与 `existing` 或自身前文重复的条目，保持原顺序。
    ///
    /// 列表分页（`PagedVideoList`，首页推荐、热门、搜索、观看历史、稍后再看与 UP 主空间投稿唯一的去重处）、
    /// 收藏夹页（按条目 ID，可播放条目的 ID 就是 BVID）与相关推荐共用。
    package func uniquedByBVID(
        after existing: [Element] = [],
        _ bvid: (Element) -> String
    ) -> [Element] {
        var seen = Set(existing.map(bvid))
        return filter { seen.insert(bvid($0)).inserted }
    }
}
