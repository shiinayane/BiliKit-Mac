import AppKit
import BiliApplication
import BiliModels
import BiliUI
import BiliVideoCollectionUI
import SwiftUI

/// 右侧整页的 UP 主空间页：头部随投稿网格滚动，排序与空间内搜索在工具栏，右下角「返回顶部」。
///
/// 内容、排序、搜索与翻页归 `UploaderSpaceViewModel`（整页那一份，由 App 的导航打开）；滚动位置、回顶请求与取图 port
/// 来自 App 的 `NativeVideoGridHostContext`。网格在各状态下都在（加载中、空与失败时没有卡片），头部是它的顶部附加
/// 视图，始终是同一个宿主：换排序、搜索或首次加载完成都不拆网格、不丢头部里的焦点；加载中、空与失败的内容画在头部
/// 下方。选中投稿交给 `onSelect`。
public struct UploaderSpacePageView: View {
    @Environment(\.uploaderFollowingMenu) private var followingMenu
    let model: UploaderSpaceViewModel
    let imagePipeline: any VideoDetailImageLoading
    let gridHost: NativeVideoGridHostContext
    /// 关注按钮的状态；看自己的空间时为 nil，不显示按钮。
    let follow: VideoUploaderFollowContent?
    let onToggleFollow: @MainActor () -> Void
    /// 「已关注」菜单里的取消关注：显式取消，不经切换（菜单弹出后关注状态可能已经变了）。
    let onUnfollow: @MainActor () -> Void
    let onSelect: (String) -> Void
    @Environment(\.openURL) private var openURL
    @Environment(\.videoCardAccountWriting) private var accountWriting
    /// 卡片展示数据按位置缓存，加载更多时只格式化新追加的投稿，见 `NativeVideoCardCache`。
    @State private var cards = NativeVideoCardCache<UploaderVideo>()

    public init(
        model: UploaderSpaceViewModel,
        imagePipeline: any VideoDetailImageLoading,
        gridHost: NativeVideoGridHostContext,
        follow: VideoUploaderFollowContent?,
        onToggleFollow: @escaping @MainActor () -> Void,
        onUnfollow: @escaping @MainActor () -> Void,
        onSelect: @escaping (String) -> Void
    ) {
        self.model = model
        self.imagePipeline = imagePipeline
        self.gridHost = gridHost
        self.follow = follow
        self.onToggleFollow = onToggleFollow
        self.onUnfollow = onUnfollow
        self.onSelect = onSelect
    }

    public var body: some View {
        ZStack(alignment: .top) {
            grid
                .ignoresSafeArea(.container, edges: .top)
            stateContent
                .padding(.top, UploaderSpacePageGeometry.headerHeight)
        }
        .overlay(alignment: .bottom) {
            PaginationStatusOverlay(paginationStatus)
        }
        .navigationTitle(displayOwner.name)
        .toolbar {
            if model.searchKeyword == nil {
                ToolbarItem(placement: .primaryAction) {
                    orderPicker
                }
            }
        }
        .modifier(UploaderSpacePageSearch(model: model))
        // 已关注时预读关系，「已关注」菜单弹出时就有状态。
        .task(id: follow?.isFollowing == true ? displayOwner.id : nil) {
            guard follow?.isFollowing == true else { return }
            followingMenu?.prefetch(displayOwner.id)
        }
    }

    /// 已关注时点按钮弹出的「已关注」菜单；菜单里的取消关注经本页的 `onUnfollow`。
    private var showFollowingMenu: ((NSView) -> Void)? {
        guard let followingMenu else { return nil }
        let ownerID = displayOwner.id
        let onUnfollow = onUnfollow
        return { button in
            followingMenu.popUp(mid: ownerID, below: button, unfollow: onUnfollow)
        }
    }

    /// 只凭 MID 打开、名片还没到或失败时名字为空，显示 UID（与预览一致，“UID”不做本地化）。
    private var displayOwner: VideoOwner {
        guard let owner = model.owner else { return VideoOwner(id: 0, name: "") }
        guard owner.name.isEmpty else { return owner }
        return VideoOwner(id: owner.id, name: "UID \(owner.id)", avatarURL: owner.avatarURL)
    }

    private var videos: [UploaderVideo] {
        if case .loaded(let videos) = model.state { return videos }
        return []
    }

    private var grid: some View {
        NativeVideoGridView(
            items: cards.cards(for: videos, make: UploaderSpacePageCards.presentation),
            accessibilityLabel: VideoDetailFeatureStrings.localized("UP 主投稿"),
            tailState: NativeVideoGridTailState(
                canLoadMore: model.loadMoreTailIdentity != nil,
                tailIdentity: model.loadMoreTailIdentity,
                isLoading: model.footer == .loading
            ),
            decorations: NativeVideoGridDecorations(
                topAccessory: NativeVideoGridTopAccessory(
                    height: UploaderSpacePageGeometry.headerHeight,
                    content: AnyView(
                        UploaderSpacePageHeader(
                            content: VideoUploaderHeaderContent(
                                owner: displayOwner,
                                profileState: model.profile.map { .loaded($0) } ?? .loading,
                                follow: follow,
                                avatarSize: .large
                            ),
                            imagePipeline: imagePipeline,
                            onToggleFollow: onToggleFollow,
                            showFollowingMenu: showFollowingMenu
                        )
                    )
                ),
                scrollToTopLabel: VideoDetailFeatureStrings.localized("返回顶部")
            ),
            host: gridHost,
            onNearEnd: model.loadMore,
            onSelect: onSelect,
            cardMenu: { [openURL, accountWriting] card in
                UploaderSpaceCardMenu.menu(
                    videoID: card.id,
                    openURL: openURL,
                    writing: accountWriting
                )
            }
        )
    }

    @ViewBuilder
    private var stateContent: some View {
        switch model.state {
        case .closed, .loading:
            VideoCardGridSkeleton(
                loadingLabel: VideoDetailFeatureStrings.localized("正在加载投稿")
            )
        case .failed(let error):
            ContentUnavailableView {
                Label(
                    VideoDetailFeatureStrings.localized("无法加载内容"),
                    systemImage: "exclamationmark.triangle"
                )
            } description: {
                Text(ContentFailureText.message(for: error))
            } actions: {
                if error.isRetryable {
                    Button(VideoDetailFeatureStrings.localized("重试"), action: model.reload)
                }
            }
        case .loaded(let videos) where videos.isEmpty:
            ContentUnavailableView(
                model.searchKeyword == nil
                    ? VideoDetailFeatureStrings.localized("还没有投稿")
                    : VideoDetailFeatureStrings.localized("没有找到相关投稿"),
                systemImage: "play.rectangle"
            )
        case .loaded:
            EmptyView()
        }
    }

    private var paginationStatus: PaginationStatusOverlay.Status {
        switch model.footer {
        case .loading:
            return .loadingMore(label: VideoDetailFeatureStrings.localized("正在加载更多投稿"))
        case .failed(let error):
            let model = model
            let retry: (() -> Void)? = error.isRetryable ? { model.loadMore() } : nil
            return .failed(message: ContentFailureText.message(for: error), retry: retry)
        case .none, .loadMore:
            return .idle
        }
    }

    private var orderPicker: some View {
        Picker(
            selection: Binding(get: { model.order }, set: { model.setOrder($0) })
        ) {
            Text(VideoDetailFeatureStrings.localized("最新发布")).tag(UploaderVideoOrder.newest)
            Text(VideoDetailFeatureStrings.localized("最多播放")).tag(UploaderVideoOrder.mostPlayed)
        } label: {
            Label(VideoDetailFeatureStrings.localized("排序"), systemImage: "arrow.up.arrow.down")
        }
        .pickerStyle(.menu)
    }
}

/// 工具栏里的空间内搜索框：回车搜索，清空回到投稿列表。
///
/// 单独成一个修饰符，只有它读取搜索框草稿：每敲一个字只让它重新求值，不让整页（网格与头部）跟着重算。
private struct UploaderSpacePageSearch: ViewModifier {
    let model: UploaderSpaceViewModel

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .searchable(
                text: $model.searchDraft,
                placement: .toolbar,
                prompt: Text(VideoDetailFeatureStrings.localized("搜索 UP 主的投稿"))
            )
            .onSubmit(of: .search) {
                model.submitSearch(model.searchDraft)
            }
            .onChange(of: model.searchDraft) { _, draft in
                if draft.isEmpty { model.clearSearch() }
            }
    }
}
