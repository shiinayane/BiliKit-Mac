import BiliBrowseFeature

/// 压栈搜索页的内容：一份搜索会话与它专用的 Browse 模型，与侧栏「搜索」的那一份分开，两边的结果互不覆盖。
///
/// 由 `WindowComposition` 构造，经 `HistoryPageSlot` 归 `AppNavigationCoordinator`：每个窗口只有这一份，属于此刻
/// 占用它的搜索项。拥有“是否已关闭”；请求、分页与 generation 归 `browseModel`，草稿与筛选归 `session`。Browse 模型
/// 只激活搜索工作集，由页面视图按 `session.browseActivation` 激活。账户变化总会清空历史（`closePlaybackForAuthenticationChange`），
/// 这份模型随之关闭、丢弃工作集，所以不接账户会话同步；凭据失败的复核仍按窗口级参与者登记。
@MainActor
final class SearchPageModel: HistoryPageModel {
    let session: VideoSearchSession
    let browseModel: BrowseViewModel
    private(set) var isPageClosed = true

    init(session: VideoSearchSession, browseModel: BrowseViewModel) {
        self.session = session
        self.browseModel = browseModel
    }

    func openPage(_ destination: VideoSearchSession.Snapshot) {
        session.restore(destination)
        isPageClosed = false
    }

    func capturePage(into destination: inout VideoSearchSession.Snapshot) {
        destination = session.snapshot
    }

    /// 撤回草稿与条件，并取消请求、丢弃工作集，下次打开时不沿用上一项的结果。
    func closePage() {
        session.reset()
        browseModel.reset()
        isPageClosed = true
    }
}
