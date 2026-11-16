import BiliApplication
import BiliLibraryFeature
import Foundation
import SwiftUI

/// 关注工具栏的排序菜单：只在全部关注、且没有在搜索时出现（分组成员接口与搜索都不接受排序），选中即经 `selectOrder` 生效。
///
/// 菜单形态与搜索、稍后再看、收藏夹共用（`ToolbarSortMenu`）；由关注页面放进自己 `.toolbar` 的 primaryAction 组、排在刷新之前。
struct FollowsToolbarControls: View {
    @Environment(\.locale) private var locale
    let session: FollowListSession

    var body: some View {
        if session.isShowingAllFollowings, session.appliedKeyword.isEmpty {
            ToolbarSortMenu(
                options: FollowListOrder.allCases,
                selection: Binding(get: { session.order }, set: { _ in }),
                title: { $0.localizedTitle(locale: locale) },
                help: AppStrings.localized(
                    "关注排序：\(session.order.localizedTitle(locale: locale))",
                    locale: locale
                ),
                onSelect: session.selectOrder
            )
        }
    }
}

extension FollowListOrder {
    func localizedTitle(locale: Locale = .current) -> String {
        switch self {
        case .recentlyFollowed: AppStrings.localized("最近关注", locale: locale)
        case .mostVisited: AppStrings.localized("最常访问", locale: locale)
        }
    }
}
