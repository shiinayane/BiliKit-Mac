import BiliApplication

/// 资料库来源工具栏搜索框的关键词规则（稍后再看、收藏夹、关注共用）：草稿与已应用的关键词。
///
/// 值类型，由来源的会话或 ViewModel 持有（`WatchLaterSession`、`FavoriteFolderViewModel`、`FollowListSession`），它们在
/// 方法返回 true 时重新加载。规则只在这里：提交时按 `SearchText` 规范化，与已应用的关键词相同不重新加载，超长时忽略这次
/// 提交（与空间内搜索一致：不发请求、不进失败页，草稿留着可以改短）；草稿清空（只剩空白）且已按关键词过滤时立即恢复全部；
/// “清除搜索”先清已应用的关键词再清草稿，不会因清草稿再触发一次加载。
struct LibrarySearchKeyword: Equatable {
    /// 搜索框的文字；提交前不影响内容。
    private(set) var draft = ""
    /// 当前内容使用的关键词；空串表示不按关键词过滤。
    private(set) var applied = ""

    /// 搜索框改写草稿；返回 true 表示草稿被清空而撤销了已应用的关键词，调用方需要重新加载。
    mutating func updateDraft(_ newDraft: String) -> Bool {
        let oldDraft = draft
        draft = newDraft
        guard newDraft != oldDraft,
            SearchText.normalized(newDraft).isEmpty,
            !applied.isEmpty
        else { return false }
        applied = ""
        return true
    }

    /// 提交规范化后的草稿；与已应用的关键词相同或超长时返回 false，不重新加载。
    mutating func submit() -> Bool {
        let keyword = SearchText.normalized(draft)
        guard keyword != applied, SearchText.isWithinLimit(keyword) else { return false }
        applied = keyword
        return true
    }

    /// 清空关键词与草稿；返回清除前是否有关键词在起作用。
    mutating func clear() -> Bool {
        let wasApplied = !applied.isEmpty
        applied = ""
        draft = ""
        return wasApplied
    }
}
