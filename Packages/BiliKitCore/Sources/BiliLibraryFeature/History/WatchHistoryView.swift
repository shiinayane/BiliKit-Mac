import BiliApplication
import BiliModels
import BiliVideoCollectionUI
import SwiftUI

/// 观看历史来源的根视图：给资料库列表的共用根视图（`LibraryVideoListView`）提供历史的文案与卡片映射；登录门槛、
/// 加载、刷新与网格的语义都在共用视图。
public struct WatchHistoryView: View {
    @Environment(\.locale) private var locale
    private let model: WatchHistoryViewModel
    private let accountState: AccountPresentationState
    private let gridHost: NativeVideoGridHostContext
    /// 选中一个视频：BV 号与列表给的第一个分 P 的 CID（没有时为 nil），后者交给播放页提前请求播放清单。
    private let onSelect: (String, Int64?) -> Void
    private let onPresentAuthentication: () -> Void

    public init(
        model: WatchHistoryViewModel,
        accountState: AccountPresentationState,
        gridHost: NativeVideoGridHostContext,
        onSelect: @escaping (String, Int64?) -> Void,
        onPresentAuthentication: @escaping () -> Void
    ) {
        self.model = model
        self.accountState = accountState
        self.gridHost = gridHost
        self.onSelect = onSelect
        self.onPresentAuthentication = onPresentAuthentication
    }

    public var body: some View {
        LibraryVideoListView(
            model: model,
            text: text,
            card: { WatchHistoryCardPresentation(item: $0).nativeCard },
            watchLaterAction: .add,
            accountState: accountState,
            gridHost: gridHost,
            onSelect: { bvid in
                onSelect(
                    bvid,
                    model.state.loadedItems.first(where: { $0.bvid == bvid })?.firstPageCID
                )
            },
            onPresentAuthentication: onPresentAuthentication
        )
    }

    private var text: LibraryVideoListText {
        LibraryVideoListText(
            signInTitle: LibraryFeatureStrings.localized("登录后查看观看历史", locale: locale),
            signInDescription: LibraryFeatureStrings.localized(
                "观看历史只在登录期间加载，不会保存到本机。",
                locale: locale
            ),
            loading: LibraryFeatureStrings.localized("正在加载观看历史", locale: locale),
            emptyTitle: LibraryFeatureStrings.localized("暂无可显示的观看历史", locale: locale),
            emptySymbol: "clock.arrow.circlepath",
            emptyDescription: LibraryFeatureStrings.localized(
                "在哔哩哔哩观看过的普通视频会显示在这里。",
                locale: locale
            ),
            failureTitle: LibraryFeatureStrings.localized("无法加载观看历史", locale: locale),
            refreshing: LibraryFeatureStrings.localized("正在刷新观看历史", locale: locale),
            loadingMore: LibraryFeatureStrings.localized("正在加载更早的记录…", locale: locale),
            gridAccessibilityLabel: LibraryFeatureStrings.localized("观看历史视频", locale: locale),
            manualContinue: LibraryVideoListText.ManualContinue(
                emptyDescription: LibraryFeatureStrings.localized(
                    "当前页没有普通视频记录，可以继续检查更早的历史。",
                    locale: locale
                ),
                actionTitle: LibraryFeatureStrings.localized("加载更早的记录", locale: locale)
            )
        )
    }
}
