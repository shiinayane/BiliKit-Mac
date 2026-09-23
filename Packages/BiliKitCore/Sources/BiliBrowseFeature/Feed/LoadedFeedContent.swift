/// Feature 交给 App 列表渲染器的已加载条目与分页／选择意图。
///
/// 分页状态与请求仍由 `GuestBrowseViewModel` 拥有；渲染器只显示条目并回送意图。
public struct LoadedFeedContent<Item> {
    public let items: [Item]
    /// 仍有下一页，渲染器接近末尾时应调用 `loadMore`。
    public let canLoadMore: Bool
    /// 渲染器对 near-end 事件去重的不透明标识；不编码远端 continuation。
    public let tailIdentity: String?
    public let isLoadingMore: Bool
    public let loadMore: () -> Void
    public let select: (String) -> Void
}
