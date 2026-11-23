import BiliApplication
import Foundation
import Observation

/// 搜索来源的会话：工具栏草稿、排序与筛选、已提交的搜索条件，以及它们到 Browse 搜索工作集的映射。
///
/// 由 App 的窗口组装（`WindowComposition`）构造，每个窗口两份：侧栏「搜索」一份，压栈的搜索页一份（各配一个
/// `BrowseViewModel`，互不覆盖）。拥有草稿、筛选选择、已应用的筛选与已提交的条件；不拥有请求、分页与
/// generation（`BrowseViewModel`），也不拥有搜索历史的存储：提交时经 App 注入的 `recordHistory` 写入（历史的
/// 读取、删除与清除经 `SearchStartPageContext`）。工具栏控件的 AppKit/SwiftUI 宿主在 App，只绑定这里的状态。
@MainActor
@Observable
public final class VideoSearchSession {
    /// 工具栏搜索框的文字；编辑中的草稿只经搜索框联想匿名请求联想词，不触发搜索。
    ///
    /// 清空（只剩空白）时撤回已提交的搜索，搜索页回到起始页。
    public var draft = "" {
        didSet {
            guard draft != oldValue, Self.normalized(draft).isEmpty else { return }
            submittedCriteria = nil
        }
    }
    /// 排序菜单与筛选弹窗编辑的选择；排序立即生效，筛选在弹窗“应用”后经 `applyFilters` 生效。
    public var filterSelection = SearchFilterSelection()
    /// 最近一次提交的完整条件；为 nil 时搜索页显示起始页。
    ///
    /// 筛选或排序变化会以同一查询词替换它。
    public private(set) var submittedCriteria: VideoSearchCriteria?

    private var appliedFilters = AppliedVideoSearchFilters()
    @ObservationIgnored private let browseModel: BrowseViewModel
    @ObservationIgnored private let recordHistory: @MainActor (String) -> Void

    /// 搜索会话依赖窗口的 Browse 模型与搜索历史的写入。
    ///
    /// - Parameters:
    ///   - browseModel: 承担搜索请求与分页的窗口 Browse 模型。
    ///   - recordHistory: 每次提交时以规范化后的查询词调用一次（含重复提交）。
    public init(
        browseModel: BrowseViewModel,
        recordHistory: @escaping @MainActor (String) -> Void
    ) {
        self.browseModel = browseModel
        self.recordHistory = recordHistory
    }

    /// 搜索页要求 Browse 激活的工作集。
    public var browseActivation: BrowseActivation {
        .search(criteria: submittedCriteria)
    }

    /// 提交规范化后的草稿并写入搜索历史。
    ///
    /// 与上次提交的条件相同时原地刷新同一工作集（`.task(id:)` 的 identity 不变，不会重新激活），否则替换提交的
    /// 条件，由 App 的 Browse 激活接手。
    public func submit() {
        let query = Self.normalized(draft)
        guard !query.isEmpty else { return }
        draft = query
        let criteria = appliedFilters.criteria(query: query)
        recordHistory(criteria.query)
        if submittedCriteria == criteria {
            browseModel.search(criteria)
        } else {
            submittedCriteria = criteria
        }
    }

    /// 点选历史、热搜或联想词：与在搜索框输入后提交走同一条路径。
    public func search(keyword: String) {
        draft = keyword
        submit()
    }

    /// 排序菜单已把 `filterSelection.order` 设为 `order`。
    public func selectOrder(_ order: VideoSearchOrder) {
        appliedFilters.order = order
        updateSubmittedCriteria()
    }

    /// 筛选弹窗“应用”；自定义日期不合法时不生效（弹窗已禁用应用按钮）。
    public func applyFilters(_ selection: SearchFilterSelection) {
        guard let filters = try? selection.resolvedFilters() else { return }
        appliedFilters = filters
        updateSubmittedCriteria()
    }

    /// 清除时长与发布日期筛选，保留排序。
    public func clearFilters() {
        filterSelection.resetFilters()
        appliedFilters.duration = .all
        appliedFilters.publicationRange = nil
        updateSubmittedCriteria()
    }

    /// 关窗时清空草稿（随之撤回已提交的搜索），与新窗口一致。
    public func reset() {
        draft = ""
    }

    /// 此刻的全部会话状态；压栈搜索页被另一项占用前由 App 记进历史项。
    public var snapshot: Snapshot {
        Snapshot(
            draft: draft,
            filterSelection: filterSelection,
            appliedFilters: appliedFilters,
            submittedCriteria: submittedCriteria
        )
    }

    /// 回到历史里的搜索页时按记下的状态重建；不写搜索历史，那次提交当时已经写过（或按入口约定不写）。
    ///
    /// 先设草稿：草稿为空时 `didSet` 会撤回已提交的条件，之后再写回快照里的条件。
    public func restore(_ snapshot: Snapshot) {
        draft = snapshot.draft
        filterSelection = snapshot.filterSelection
        appliedFilters = snapshot.appliedFilters
        submittedCriteria = snapshot.submittedCriteria
    }

    private func updateSubmittedCriteria() {
        guard let submittedCriteria else { return }
        self.submittedCriteria = appliedFilters.criteria(query: submittedCriteria.query)
    }

    private static func normalized(_ draft: String) -> String {
        SearchText.normalized(draft)
    }
}

extension VideoSearchSession {
    /// 一份会话的全部状态，作为压栈搜索页历史项的内容。
    ///
    /// 不能只记已提交的条件：自定义日期的筛选选择无法从解析后的时间范围反推，草稿也可能改过还没提交。
    public struct Snapshot: Hashable, Sendable {
        let draft: String
        let filterSelection: SearchFilterSelection
        let appliedFilters: AppliedVideoSearchFilters
        let submittedCriteria: VideoSearchCriteria?

        /// 以默认排序与筛选提交 `keyword` 的新会话；规范化后为空时停在起始页。
        public static func submitted(_ keyword: String) -> Snapshot {
            let query = SearchText.normalized(keyword)
            let filters = AppliedVideoSearchFilters()
            return Snapshot(
                draft: query,
                filterSelection: SearchFilterSelection(),
                appliedFilters: filters,
                submittedCriteria: query.isEmpty ? nil : filters.criteria(query: query)
            )
        }
    }
}
