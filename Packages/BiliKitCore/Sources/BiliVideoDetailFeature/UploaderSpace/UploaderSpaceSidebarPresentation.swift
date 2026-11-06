import BiliApplication
import BiliModels

/// 空间层的显示规则：头部下方叠什么提示、头部是否显示投稿数。
///
/// 纯逻辑，与界面分开测试；空状态与失败说明都是产品契约。未登录也能读取投稿，所以没有登录提示。
struct UploaderSpaceSidebarPresentation: Equatable {
    /// 头部下方叠加的提示；`.none` 时显示列表本身。
    enum Overlay: Equatable {
        case none
        case loading
        case empty
        /// 空间内搜索没有结果。
        case noResults
        /// 失败原因决定说明文字与是否给重试（风控、凭据、网络分开说明）。
        case failure(ContentApplicationError)
    }

    let overlay: Overlay
    /// 投稿数未知（第一批加载中）或为 0 时不显示。
    let headerTotalCount: Int?

    init(state: UploaderSpaceState, totalCount: Int?, isSearching: Bool) {
        switch state {
        case .closed:
            overlay = .none
        case .loading:
            overlay = .loading
        case .loaded(let videos):
            overlay = videos.isEmpty ? (isSearching ? .noResults : .empty) : .none
        case .failed(let error):
            overlay = .failure(error)
        }
        headerTotalCount = totalCount.flatMap { $0 > 0 ? $0 : nil }
    }
}
