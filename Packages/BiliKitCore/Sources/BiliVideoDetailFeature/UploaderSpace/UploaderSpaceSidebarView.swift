import AppKit
import BiliApplication
import BiliModels
import BiliUI
import BiliVideoCollectionUI
import SwiftUI

/// 压在侧栏上的 UP 主空间层。
///
/// 原生列表只画头部与已加载的行；加载中、空、失败与登录提示由本视图按 ViewModel 状态叠在头部下方。
/// 返回按钮悬浮在左上角，不随列表滚走；页码条悬浮在底部，列表为它留出底部空间。
public struct UploaderSpaceSidebarView: View {
    let model: UploaderSpaceViewModel
    let currentBVID: String?
    let imagePipeline: any VideoDetailImageLoading
    let onSelect: (String) -> Void
    let onLogin: () -> Void

    public init(
        model: UploaderSpaceViewModel,
        currentBVID: String?,
        imagePipeline: any VideoDetailImageLoading,
        onSelect: @escaping (String) -> Void,
        onLogin: @escaping () -> Void
    ) {
        self.model = model
        self.currentBVID = currentBVID
        self.imagePipeline = imagePipeline
        self.onSelect = onSelect
        self.onLogin = onLogin
    }

    @Environment(\.locale) private var locale
    @Environment(\.openURL) private var openURL
    @Environment(\.videoCardAccountWriting) private var accountWriting
    /// 关闭前的最后一帧。
    ///
    /// 关闭时 ViewModel 立即清空，而移除动画还要播一段：保留最后一帧，让滑出去的是原来的列表与
    /// 页码条，而不是一层空白。放在引用类型里，记录它不会再触发一次渲染。
    @State private var lastFrame = RetainedFrame()

    private struct Frame: Equatable {
        /// 页码条需要的当前页与总页数。
        struct Pager: Equatable {
            let currentPage: Int
            let pageCount: Int
        }

        let content: UploaderSpaceListContent
        let pager: Pager?
    }

    /// 保存关闭前最后一帧的引用盒子；改它不触发 SwiftUI 重新渲染。
    private final class RetainedFrame {
        var frame: Frame?
    }

    public var body: some View {
        let presentation = UploaderSpaceSidebarPresentation(
            state: model.state,
            pageCount: model.pageCount,
            totalCount: model.totalCount
        )
        let live = liveFrame(presentation)
        let frame = live ?? lastFrame.frame
        if let live { lastFrame.frame = live }

        return ZStack(alignment: .top) {
            if let content = frame?.content {
                UploaderSpaceListRepresentable(
                    content: content,
                    imagePipeline: imagePipeline,
                    actions: UploaderSpaceListActions(
                        selectOrder: model.setOrder,
                        selectVideo: onSelect,
                        cardMenu: { [openURL, accountWriting] row in
                            Self.cardMenu(for: row, openURL: openURL, writing: accountWriting)
                        }
                    )
                )
                .ignoresSafeArea(.container, edges: .top)
            }
            stateOverlay(presentation.overlay)
                .padding(.top, UploaderSpaceGeometry.stateContentTop)
            backButton
        }
        .overlay(alignment: .bottom) {
            if let pager = frame?.pager {
                PageNumberPager(
                    currentPage: pager.currentPage,
                    pageCount: pager.pageCount,
                    onShowPage: model.showPage
                )
            }
        }
    }

    /// 悬浮返回按钮，⌘[ 同样返回；叠在列表与状态覆盖层之上，在顶部时落在头部左侧留出的那一格里。
    private var backButton: some View {
        FloatingIconButton(
            "chevron.left",
            label: VideoDetailFeatureStrings.localized("返回详情"),
            action: model.close
        )
        .keyboardShortcut("[", modifiers: .command)
        // 它叠在最上层，默认会被读屏排到列表之后；视觉上它在头部最左，读屏也先读它。
        .accessibilitySortPriority(1)
        .frame(
            width: UploaderSpaceGeometry.backButtonSlotWidth,
            height: UploaderSpaceGeometry.headerHeight
        )
        .padding(.leading, UploaderSpaceGeometry.backButtonSlotLeading)
        .padding(.top, UploaderSpaceGeometry.listTopInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 投稿行的卡片菜单：与相关推荐卡片相同的「添加到稍后再看」「收藏到…」一组加「拷贝链接」「在浏览器中打开」一组，
    /// 规则在共用的 `NativeVideoCardMenu.video`。
    ///
    /// 投稿都可进入播放；BVID 不合法时没有菜单。`openURL` 是从环境取得的系统 `OpenURLAction`，`writing` 是 App 从环境注入的
    /// 写入口（未登录或复核中时写操作项禁用）。
    static func cardMenu(
        for row: UploaderVideoRowPresentation,
        openURL: OpenURLAction,
        writing: VideoCardAccountWriting?
    ) -> NativeVideoCardMenu? {
        NativeVideoCardMenu.video(
            videoID: row.bvid,
            isActivatable: true,
            webPageURL: BVID.webPageURL(row.bvid),
            openURL: openURL,
            writing: writing,
            watchLater: .add
        )
    }

    /// 空间打开期间按 ViewModel 实时生成；关闭后为 nil。
    ///
    /// 每次刷新只算一次。
    private func liveFrame(_ presentation: UploaderSpaceSidebarPresentation) -> Frame? {
        guard let owner = model.owner else { return nil }
        let rows: [UploaderVideoRowPresentation]
        if case .loaded(let page) = model.state {
            rows = page.videos.map { UploaderVideoRowPresentation(video: $0) }
        } else {
            rows = []
        }
        let content = UploaderSpaceListContent(
            header: UploaderSpaceHeaderContent(
                // 只凭 MID 打开（评论正文里的空间链接）时，名片到达前或失败时名字为空，显示 UID；
                // “UID”是 B 站各语言界面通用的写法，不做本地化。
                name: owner.name.isEmpty ? "UID \(owner.id)" : owner.name,
                avatarURL: owner.avatarURL,
                totalCount: presentation.headerTotalCount,
                order: model.order
            ),
            rows: rows,
            currentBVID: currentBVID,
            pageIdentity: UploaderSpaceListContent.PageIdentity(
                ownerID: owner.id,
                order: model.order,
                page: model.currentPage
            ),
            reservesPagerSpace: presentation.showsPager
        )
        return Frame(
            content: content,
            pager: presentation.showsPager
                ? Frame.Pager(currentPage: model.currentPage, pageCount: model.pageCount)
                : nil
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
        case .signIn:
            message(
                VideoDetailFeatureStrings.localized("登录后可浏览 UP 主投稿"),
                actionTitle: VideoDetailFeatureStrings.localized("登录"),
                action: onLogin
            )
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
