import AppKit
import BiliApplication
import BiliModels
import BiliUI
import BiliVideoCollectionUI
import SwiftUI

/// 压在播放页右栏上的 UP 主空间层。
///
/// 原生列表只画头部与已加载的行；加载中、空、失败与登录提示由本视图按 ViewModel 状态叠在头部下方，
/// 返回按钮始终可点。页码条悬浮在底部，列表为它留出底部空间。
public struct UploaderSpaceLayerView: View {
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

        let content: VideoRowListContent
        let pager: Pager?
    }

    /// 换 UP 主、排序或页码时列表滚回顶部；空间内换视频不改变它。
    private struct PageIdentity: Hashable {
        let ownerID: Int64
        let order: UploaderVideoOrder
        let page: Int
    }

    /// 保存关闭前最后一帧的引用盒子；改它不触发 SwiftUI 重新渲染。
    private final class RetainedFrame {
        var frame: Frame?
    }

    public var body: some View {
        let presentation = UploaderSpaceLayerPresentation(
            state: model.state,
            pageCount: model.pageCount,
            totalCount: model.totalCount
        )
        let live = liveFrame(presentation)
        let frame = live ?? lastFrame.frame
        if let live { lastFrame.frame = live }

        return ZStack(alignment: .top) {
            if let content = frame?.content {
                VideoRowListRepresentable(
                    content: content,
                    imagePipeline: imagePipeline,
                    actions: VideoRowListActions(
                        close: model.close,
                        selectOrder: model.setOrder,
                        selectVideo: onSelect,
                        cardMenu: { [openURL, accountWriting] row in
                            VideoRowCardMenu.menu(
                                for: row,
                                openURL: openURL,
                                writing: accountWriting
                            )
                        }
                    ),
                    accessibilityLabel: VideoDetailFeatureStrings.localized("UP 主投稿"),
                    topButtonLabel: VideoDetailFeatureStrings.localized("返回空间顶部")
                )
                .ignoresSafeArea(.container, edges: .top)
            }
            stateOverlay(presentation.overlay)
                .padding(.top, UploaderSpaceGeometry.stateContentTop)
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

    /// 空间打开期间按 ViewModel 实时生成；关闭后为 nil。
    ///
    /// 每次刷新只算一次。
    private func liveFrame(_ presentation: UploaderSpaceLayerPresentation) -> Frame? {
        guard let owner = model.owner else { return nil }
        let rows: [VideoRowPresentation]
        if case .loaded(let page) = model.state {
            rows = page.videos.map { VideoRowPresentation(video: $0) }
        } else {
            rows = []
        }
        let content = VideoRowListContent(
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
            scrollIdentity: PageIdentity(
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
    private func stateOverlay(_ overlay: UploaderSpaceLayerPresentation.Overlay) -> some View {
        switch overlay {
        case .none:
            EmptyView()
        case .loading:
            // 投稿数因人而异，占位行会误导数量；直接转圈，在头部下方的剩余区域居中。
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(VideoDetailFeatureStrings.localized("正在加载投稿"))
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
