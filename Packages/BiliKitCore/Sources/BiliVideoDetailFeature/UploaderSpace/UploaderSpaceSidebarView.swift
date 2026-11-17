import AppKit
import BiliApplication
import BiliModels
import BiliUI
import BiliVideoCollectionUI
import SwiftUI

/// 压在侧栏上的 UP 主空间层。
///
/// 原生列表画头部、已加载的行与底部加载行；第一批的加载中、空与失败由本视图按 ViewModel 状态叠在头部下方。
/// 返回按钮、空间内搜索框与打开整页空间页的按钮在顶部浮动的一行里，不随列表滚走，列表从它下方开始。
public struct UploaderSpaceSidebarView: View {
    let model: UploaderSpaceViewModel
    let currentBVID: String?
    let imagePipeline: any VideoDetailImageLoading
    let onSelect: (String) -> Void
    /// 在右侧打开这位 UP 主的整页空间页（App 的导航）。
    let onOpenFullSpace: () -> Void
    /// 关掉预览回到详情（App 的导航，带侧栏转场）。
    let onClose: () -> Void

    public init(
        model: UploaderSpaceViewModel,
        currentBVID: String?,
        imagePipeline: any VideoDetailImageLoading,
        onSelect: @escaping (String) -> Void,
        onOpenFullSpace: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.model = model
        self.currentBVID = currentBVID
        self.imagePipeline = imagePipeline
        self.onSelect = onSelect
        self.onOpenFullSpace = onOpenFullSpace
        self.onClose = onClose
    }

    @Environment(\.locale) private var locale
    @Environment(\.openURL) private var openURL
    @Environment(\.videoCardAccountWriting) private var accountWriting
    public var body: some View {
        let presentation = UploaderSpaceSidebarPresentation(
            state: model.state,
            totalCount: model.totalCount,
            isSearching: model.searchKeyword != nil
        )
        let content = liveContent(presentation)

        return ZStack(alignment: .top) {
            if let content {
                UploaderSpaceListRepresentable(
                    content: content,
                    imagePipeline: imagePipeline,
                    actions: UploaderSpaceListActions(
                        selectOrder: model.setOrder,
                        selectVideo: onSelect,
                        loadMore: model.loadMore,
                        cardMenu: { [openURL, accountWriting] row in
                            UploaderSpaceCardMenu.menu(
                                videoID: row.bvid,
                                openURL: openURL,
                                writing: accountWriting
                            )
                        }
                    )
                )
                .ignoresSafeArea(.container, edges: .top)
            }
            stateOverlay(presentation.overlay)
                .padding(.top, UploaderSpaceGeometry.stateContentTop)
            topBar
        }
    }

    /// 顶部浮动的一行：返回按钮（菜单「前往 › 返回」的 ⌘[ 同样关闭预览）、空间内搜索框与打开整页空间页的按钮；叠在列表与
    /// 状态覆盖层之上。
    ///
    /// 搜索框以 UP 主为身份重建：换 UP 主时草稿清空，与 ViewModel 清掉的搜索词一致。
    private var topBar: some View {
        HStack(spacing: UploaderSpaceGeometry.topBarSpacing) {
            FloatingIconButton(
                "chevron.left",
                label: VideoDetailFeatureStrings.localized("返回详情"),
                action: onClose
            )
            UploaderSpaceSearchField(onSubmit: model.submitSearch)
                .id(model.owner?.id)
                // 超大档的搜索框固有高度 36pt，与左侧返回按钮（large 档、24pt 图标的圆形按钮）等高。
                .controlSize(.extraLarge)
            FloatingIconButton(
                "rectangle.portrait.and.arrow.forward",
                label: VideoDetailFeatureStrings.localized("打开完整空间"),
                action: onOpenFullSpace
            )
        }
        // 它叠在最上层，默认会被读屏排到列表之后；视觉上它在最上面，读屏也先读它。
        .accessibilitySortPriority(1)
        .frame(height: UploaderSpaceGeometry.topBarHeight)
        .padding(.horizontal, UploaderSpaceGeometry.topBarHorizontalPadding)
        .padding(.top, UploaderSpaceGeometry.listTopInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 空间打开期间按 ViewModel 实时生成；关闭后为 nil。
    ///
    /// 每次刷新只算一次。
    private func liveContent(
        _ presentation: UploaderSpaceSidebarPresentation
    ) -> UploaderSpaceListContent? {
        guard let owner = model.owner else { return nil }
        let rows: [UploaderVideoRowPresentation]
        if case .loaded(let videos) = model.state {
            rows = videos.map { UploaderVideoRowPresentation(video: $0) }
        } else {
            rows = []
        }
        return UploaderSpaceListContent(
            header: UploaderSpaceHeaderContent(
                // 只凭 MID 打开（评论正文里的空间链接）时，名片到达前或失败时名字为空，显示 UID；
                // “UID”是 B 站各语言界面通用的写法，不做本地化。
                name: owner.name.isEmpty ? "UID \(owner.id)" : owner.name,
                avatarURL: owner.avatarURL,
                totalCount: presentation.headerTotalCount,
                order: model.order,
                isSearching: model.searchKeyword != nil
            ),
            rows: rows,
            currentBVID: currentBVID,
            listIdentity: UploaderSpaceListContent.ListIdentity(
                ownerID: owner.id,
                order: model.order,
                searchKeyword: model.searchKeyword
            ),
            footer: model.footer,
            tailIdentity: model.loadMoreTailIdentity
        )
    }

    @ViewBuilder
    private func stateOverlay(_ overlay: UploaderSpaceSidebarPresentation.Overlay) -> some View {
        switch overlay {
        case .none:
            EmptyView()
        case .loading:
            // 投稿数因人而异，占位行会误导数量；直接转圈，在头部下方的剩余区域居中。
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(VideoDetailFeatureStrings.localized("正在加载投稿"))
                .revealsAfterLoadingDelay()
        case .empty:
            message(VideoDetailFeatureStrings.localized("还没有投稿"))
        case .noResults:
            message(VideoDetailFeatureStrings.localized("没有找到相关投稿"))
        case .failure(let error):
            // 紧凑布局只放一行说明：共享说明已分开风控、凭据失效、凭据读不到与网络，标题只会重复它。
            message(
                ContentFailureText.message(for: error, locale: locale),
                actionTitle: error.isRetryable ? VideoDetailFeatureStrings.localized("重试") : nil,
                action: model.reload
            )
        }
    }

    private func message(
        _ text: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: UploaderSpaceGeometry.messageSpacing) {
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
            }
        }
        .padding(.horizontal, UploaderSpaceGeometry.messageHorizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct UploaderSpaceListRepresentable: NSViewRepresentable {
    let content: UploaderSpaceListContent
    let imagePipeline: any VideoDetailImageLoading
    let actions: UploaderSpaceListActions

    func makeCoordinator() -> UploaderSpaceListController {
        UploaderSpaceListController(imagePipeline: imagePipeline)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.update(content: content, actions: actions)
        return context.coordinator.scrollView
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.update(content: content, actions: actions)
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: UploaderSpaceListController) {
        coordinator.tearDown()
    }
}
