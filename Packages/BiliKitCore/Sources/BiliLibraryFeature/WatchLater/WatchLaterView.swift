import BiliApplication
import BiliModels
import BiliVideoCollectionUI
import SwiftUI

/// 稍后再看来源的根视图：给资料库列表的共用根视图（`LibraryVideoListView`）提供稍后再看的文案与卡片映射；登录
/// 门槛、加载、刷新、近尾自动加载与网格的语义都在共用视图。
///
/// 不可用条目由卡片映射标出，网格拒绝激活。有筛选或关键词
/// 而结果为空时，空态改为“没有符合条件的视频”并经会话清除条件；排序、筛选与搜索框的宿主在 App。
public struct WatchLaterView: View {
    @Environment(\.locale) private var locale
    private let model: WatchLaterViewModel
    private let session: WatchLaterSession
    private let accountState: AccountPresentationState
    private let gridHost: NativeVideoGridHostContext
    /// 选中一个视频：BV 号与列表给的第一个分 P 的 CID（没有时为 nil），后者交给播放页提前请求播放清单。
    private let onSelect: (String, Int64?) -> Void
    private let onPresentAuthentication: () -> Void
    private let toolbarControls: AnyView

    public init(
        model: WatchLaterViewModel,
        session: WatchLaterSession,
        accountState: AccountPresentationState,
        gridHost: NativeVideoGridHostContext,
        onSelect: @escaping (String, Int64?) -> Void,
        onPresentAuthentication: @escaping () -> Void,
        toolbarControls: AnyView
    ) {
        self.model = model
        self.session = session
        self.accountState = accountState
        self.gridHost = gridHost
        self.onSelect = onSelect
        self.onPresentAuthentication = onPresentAuthentication
        self.toolbarControls = toolbarControls
    }

    public var body: some View {
        LibraryVideoListView(
            model: model,
            text: text,
            card: { WatchLaterCardPresentation(item: $0).nativeCard },
            watchLaterAction: .remove,
            accountState: accountState,
            gridHost: gridHost,
            onSelect: { bvid in
                onSelect(
                    bvid,
                    model.state.loadedItems.first(where: { $0.bvid == bvid })?.firstPageCID
                )
            },
            onPresentAuthentication: onPresentAuthentication,
            toolbarControls: toolbarControls,
            refresh: session.refresh
        )
    }

    private var text: LibraryVideoListText {
        LibraryVideoListText(
            signInTitle: LibraryFeatureStrings.localized("登录后查看稍后再看", locale: locale),
            signInDescription: LibraryFeatureStrings.localized(
                "稍后再看只在登录期间加载，不会保存到本机。",
                locale: locale
            ),
            loading: LibraryFeatureStrings.localized("正在加载稍后再看", locale: locale),
            emptyTitle: LibraryFeatureStrings.localized("稍后再看里还没有视频", locale: locale),
            emptySymbol: "play.square.stack",
            emptyDescription: LibraryFeatureStrings.localized(
                "在哔哩哔哩加入稍后再看的视频会显示在这里。",
                locale: locale
            ),
            failureTitle: LibraryFeatureStrings.localized("无法加载稍后再看", locale: locale),
            refreshing: LibraryFeatureStrings.localized("正在刷新稍后再看", locale: locale),
            loadingMore: LibraryFeatureStrings.localized("正在加载更多…", locale: locale),
            gridAccessibilityLabel: LibraryFeatureStrings.localized("稍后再看视频", locale: locale),
            manualContinue: nil,
            filteredEmpty: session.narrowsResults
                ? LibraryVideoListText.FilteredEmpty(
                    title: LibraryFeatureStrings.localized("没有符合条件的视频", locale: locale),
                    description: LibraryFeatureStrings.localized(
                        "试试调整筛选或搜索词。",
                        locale: locale
                    ),
                    clearTitle: LibraryFeatureStrings.localized("清除筛选", locale: locale),
                    clear: session.clearFilters
                )
                : nil
        )
    }
}
