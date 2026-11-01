import BiliApplication
import BiliModels

/// 空间层的显示规则：头部下方叠什么提示、页码条是否出现、头部是否显示投稿数。
///
/// 纯逻辑，与界面分开测试；登录入口与空状态都是产品契约。
struct UploaderSpaceLayerPresentation: Equatable {
    /// 头部下方叠加的提示；`.none` 时显示列表本身。
    enum Overlay: Equatable {
        case none
        case loading
        case empty
        case signIn
        /// 失败原因决定说明文字与是否给重试（风控、凭据、网络分开说明）。
        case failure(ContentApplicationError)
    }

    let overlay: Overlay
    let showsPager: Bool
    /// 投稿数未知（首页加载中）或为 0 时不显示。
    let headerTotalCount: Int?

    init(state: UploaderSpaceState, pageCount: Int, totalCount: Int) {
        switch state {
        case .closed:
            overlay = .none
        case .loading:
            overlay = .loading
        case .loaded(let page):
            overlay = page.videos.isEmpty ? .empty : .none
        case .failed(_, .authenticationRequired):
            overlay = .signIn
        case .failed(_, let error):
            overlay = .failure(error)
        }
        showsPager = pageCount > 1 && state != .closed
        headerTotalCount = totalCount > 0 ? totalCount : nil
    }
}
