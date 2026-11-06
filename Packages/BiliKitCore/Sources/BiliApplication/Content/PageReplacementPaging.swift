import BiliModels

/// 按页码整体替换的列表（收藏夹内容）的翻页状态：当前请求或显示的页、最近一次给出总数的
/// 成功页的总条数与总页数，以及哪些页值得请求。
///
/// 值类型，由拥有请求 Task 的 ViewModel 持有，在请求开始与结束时推进；不拥有请求、取消与旧结果的隔离（ViewModel 的
/// `LatestTask`）。总数与总页数在翻页加载与失败期间保留，页码条不会消失；换来源（换夹、换排序或关键词）时由
/// ViewModel `reset`。成功页落在新总页数之外（总数在翻页期间变少）时不显示它，而是让 ViewModel 改请求最后一页。
package struct PageReplacementPaging<Content: Sendable & Equatable>: Sendable, Equatable {
    /// 当前请求或显示的页；`content` 是来源给出的整页内容。
    package enum Phase: Sendable, Equatable {
        case idle
        case loading(page: Int)
        case loaded(page: Int, content: Content)
        case failed(page: Int, error: ContentApplicationError)
    }

    /// 一页成功返回后 ViewModel 该做的事。
    package enum Outcome: Sendable, Equatable {
        /// 已显示这一页。
        case show
        /// 这一页落在范围之外，状态已转为加载 `page`，由 ViewModel 发出这一页的请求（不再调用 `beginLoading`）。
        case request(page: Int)
    }

    /// 一次用户意图（翻页、刷新、换条件）里最多改请求几次：越界页没有总数时先回第 1 页、再转到最后一页，共两次。
    ///
    /// 来源的总数前后矛盾时不会因此来回请求；用完后照常显示拿到的页。
    private static var redirectLimit: Int { 2 }

    package private(set) var phase: Phase = .idle
    /// 最近一次给出总数的成功页的总条数；还没有时为 nil。
    package private(set) var totalCount: Int?
    /// 至少为 1；还没有成功页时为 1。
    package private(set) var pageCount = 1
    /// 越界页没有给出总数，已改请求第 1 页：第 1 页带回新总数后再转到最后一页。
    private var returnsToLastPage = false
    private var remainingRedirects = Self.redirectLimit

    package init() {}

    /// 正在请求、显示或失败的页；还没有请求时为 1。
    package var currentPage: Int {
        switch phase {
        case .idle:
            1
        case .loading(let page), .loaded(let page, _), .failed(let page, _):
            page
        }
    }

    /// 页码在已知范围内，且不是正在显示或正在加载的页；失败的页可以再次请求。
    package func accepts(_ page: Int) -> Bool {
        guard (1...pageCount).contains(page) else { return false }
        switch phase {
        case .loading(let current), .loaded(let current, _):
            return current != page
        case .idle, .failed:
            return true
        }
    }

    /// 用户意图（翻页、换条件、失败重试）开始请求 `page`：转为加载中，总数保留。
    package mutating func beginLoading(page: Int) {
        phase = .loading(page: page)
        startIntent()
    }

    /// 原地刷新当前已显示的页：内容继续显示到结果返回。
    package mutating func beginRefresh() {
        startIntent()
    }

    /// 记录一页成功的结果，返回显示它还是改请求另一页。
    ///
    /// `totalCount` 是当前条件下的总条数；nil 表示这一页落在末尾之后、来源没有给出可信的总数（收藏夹越界页给 0），
    /// 此时保留上一次的总数并经第 1 页转到最后一页。`hasMore` 为真（来源明确说还有下一页）时总页数至少到下一页：
    /// 收藏夹以 `has_more` 为准，页内条数不足不代表结束。
    package mutating func succeed(
        page: Int,
        content: Content,
        totalCount: Int?,
        pageSize: Int,
        hasMore: Bool = false
    ) -> Outcome {
        guard let totalCount else {
            if page > 1, let redirect = redirect(to: 1) {
                returnsToLastPage = true
                return redirect
            }
            phase = .loaded(page: page, content: content)
            return .show
        }
        self.totalCount = max(0, totalCount)
        pageCount = max(
            PageNumbering.pageCount(totalCount: totalCount, pageSize: pageSize),
            hasMore ? page + 1 : 1
        )
        let target =
            if page > pageCount {
                pageCount
            } else if returnsToLastPage, page < pageCount {
                pageCount
            } else {
                page
            }
        returnsToLastPage = false
        if target != page, let redirect = redirect(to: target) {
            return redirect
        }
        phase = .loaded(page: page, content: content)
        return .show
    }

    /// 已显示的页被本地改动（乐观移除一条或回滚）：换上新内容与总数，页码与总页数不变（下一次读取再校正）。
    ///
    /// 不在显示状态时不替换、返回 false：此时没有可改的内容，旧改动也不该落到别的页或别的请求上。
    package mutating func replaceLoadedContent(_ content: Content, totalCount: Int?) -> Bool {
        guard case .loaded(let page, _) = phase else { return false }
        phase = .loaded(page: page, content: content)
        self.totalCount = totalCount
        return true
    }

    /// 记录一页失败；总数保留，`currentPage` 仍是失败的页，重试请求同一页。
    package mutating func fail(page: Int, error: ContentApplicationError) {
        returnsToLastPage = false
        phase = .failed(page: page, error: error)
    }

    /// 换来源或丢弃内容：回到还没有请求的状态，总数与总页数一并清空。
    package mutating func reset() {
        self = Self()
    }

    private mutating func startIntent() {
        returnsToLastPage = false
        remainingRedirects = Self.redirectLimit
    }

    private mutating func redirect(to page: Int) -> Outcome? {
        guard remainingRedirects > 0 else { return nil }
        remainingRedirects -= 1
        phase = .loading(page: page)
        return .request(page: page)
    }
}
