import BiliApplication
import BiliModels
import BiliUI
import SwiftUI

/// 在播放状态下用真实详情组织同一系统 Sidebar，不拥有网络或播放生命周期。
///
/// `presentedContext` 让 Sidebar 与主区共享最近有效内容；替换视频的 loading／failed
/// 状态会遮挡旧内容并从辅助树隐藏，避免把上一视频误读成当前上下文。
public struct PlaybackContextSidebar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let model: GuestVideoViewModel
    private let onRetry: () -> Void
    @State private var isSummaryExpanded = true
    @State private var arePartsExpanded = true
    @ScaledMetric(relativeTo: .callout) private var partRowHeight: CGFloat = 40

    public init(
        model: GuestVideoViewModel,
        onRetry: @escaping () -> Void
    ) {
        self.model = model
        self.onRetry = onRetry
    }

    public var body: some View {
        Group {
            if let context = model.presentedContext {
                ZStack {
                    sidebarContent(context)
                        .disabled(blocksPresentedContext)
                        .allowsHitTesting(!blocksPresentedContext)
                        .accessibilityHidden(blocksPresentedContext)

                    presentedContextOverlay
                        .transition(.opacity)
                }
            } else {
                emptyState
                    .transition(.opacity)
            }
        }
        .animation(
            LoadingStateTransition.animation(reduceMotion: reduceMotion),
            value: visualPhase
        )
        .navigationTitle("观看辅助")
        .accessibilityIdentifier("sidebar.playback-context")
    }

    private func sidebarContent(_ context: GuestVideoContext) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                VideoUploaderHeader(
                    owner: context.detail.owner,
                    signatureState: model.uploaderSignatureState
                )
                .id(context.detail.bvid)

                Divider()

                if !context.detail.summary.isEmpty {
                    summarySection(context.detail.summary)
                    Divider()
                }

                if context.pages.count > 1 {
                    partsSection(context)
                    Divider()
                }

                commentsUnavailableSection
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar.playback-content")
    }

    private func summarySection(_ summary: String) -> some View {
        DisclosureGroup("简介", isExpanded: $isSummaryExpanded) {
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
                .accessibilityIdentifier("sidebar.playback-summary.text")
        }
        .font(.headline)
        .accessibilityIdentifier("sidebar.playback-summary")
    }

    private func partsSection(_ context: GuestVideoContext) -> some View {
        ScrollViewReader { proxy in
            DisclosureGroup(isExpanded: $arePartsExpanded) {
                List {
                    ForEach(context.pages) { page in
                        partRow(
                            page,
                            identity: PlaybackItemIdentity(
                                bvid: context.detail.bvid,
                                cid: page.cid
                            )
                        )
                        .id(page.cid)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(height: partsListHeight(pageCount: context.pages.count))
                .padding(.top, 8)
                .accessibilityIdentifier("sidebar.playback-parts.list")
            } label: {
                Text("分 P（\(context.pages.count)）")
                    .accessibilityIdentifier("sidebar.playback-parts")
            }
            .font(.headline)
            .onChange(of: arePartsExpanded) { _, isExpanded in
                guard isExpanded,
                    let selectedCID = model.presentedPlaybackIdentity?.cid,
                    context.pages.contains(where: { $0.cid == selectedCID })
                else { return }
                Task { @MainActor in
                    await Task.yield()
                    proxy.scrollTo(selectedCID, anchor: .center)
                }
            }
        }
    }

    private func partRow(
        _ page: VideoPage,
        identity: PlaybackItemIdentity
    ) -> some View {
        let isSelected = model.presentedPlaybackIdentity == identity
        let isRequested = model.requestedPlaybackIdentity == identity
        let isFailed = isRequested && isPageFailure
        let isLoading = isRequested && !isSelected && !isFailed
        let accessibilityStatus = accessibilityStatus(
            isLoading: isLoading,
            isFailed: isFailed
        )
        return Button {
            if isFailed {
                model.retry()
            } else {
                model.selectPage(cid: page.cid)
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Group {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(
                            systemName: isFailed
                                ? "exclamationmark.circle"
                                : (isSelected ? "play.circle.fill" : "circle")
                        )
                        .foregroundStyle(
                            isFailed
                                ? Color.red
                                : (isSelected ? Color.accentColor : .secondary)
                        )
                    }
                }
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)

                Text("P\(page.index)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 30, alignment: .leading)

                Text(page.title)
                    .font(.callout)
                    .lineLimit(2)
                    .layoutPriority(1)

                Spacer(minLength: 8)

                Text(
                    VideoDurationFormatting.string(
                        seconds: page.durationSeconds
                    )
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isSelected || isLoading)
        .frame(minHeight: partRowHeight)
        .listRowInsets(
            EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "第 \(page.index) 分 P，\(page.title)，"
                + VideoDurationFormatting.string(
                    seconds: page.durationSeconds
                )
                + (accessibilityStatus.map { "，\($0)" } ?? "")
        )
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityHint(
            isFailed
                ? "点按重试"
                : (isSelected
                    ? ""
                    : (isLoading ? "" : "切换到此分 P"))
        )
        .help(isFailed ? "加载失败，点按重试" : "")
        .accessibilityIdentifier("sidebar.playback-part.\(page.index)")
    }

    private func partsListHeight(pageCount: Int) -> CGFloat {
        CGFloat(min(pageCount, 5)) * partRowHeight + 4
    }

    private func accessibilityStatus(
        isLoading: Bool,
        isFailed: Bool
    ) -> String? {
        if isFailed { return "加载失败，可重试" }
        if isLoading { return "正在载入" }
        return nil
    }

    private var isPageFailure: Bool {
        if case .failedPage = model.state {
            return true
        }
        return false
    }

    private var commentsUnavailableSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("评论尚未接入", systemImage: "text.bubble")
                .font(.headline)
            Text("当前版本不会伪造评论内容。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sidebar.playback-comments-unavailable")
    }

    private var blocksPresentedContext: Bool {
        switch model.state {
        case .loading, .failed:
            true
        case .idle, .loadingPage, .preparingPlayback, .ready, .failedPage:
            false
        }
    }

    private var visualPhase: LoadingVisualPhase {
        if model.presentedContext != nil {
            switch model.state {
            case .loading:
                return .replacementLoading
            case .failed:
                return .failure
            case .idle, .loadingPage, .preparingPlayback, .ready, .failedPage:
                return .content
            }
        }

        switch model.state {
        case .idle:
            return .idle
        case .loading, .loadingPage, .preparingPlayback:
            return .loading
        case .failed, .failedPage:
            return .failure
        case .ready:
            return .content
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch model.state {
        case .loading, .loadingPage, .preparingPlayback:
            PlaybackContextSidebarSkeleton(
                loadingLabel: "正在加载视频上下文"
            )
            .accessibilityIdentifier("sidebar.playback-loading")
        case .failed(_, let failure), .failedPage(_, _, let failure):
            failureView(failure)
        case .idle:
            ContentUnavailableView(
                "没有播放上下文",
                systemImage: "play.rectangle",
                description: Text("返回来源页并重新选择视频。")
            )
        case .ready:
            EmptyView()
        }
    }

    @ViewBuilder
    private var presentedContextOverlay: some View {
        switch model.state {
        case .loading:
            PlaybackContextSidebarSkeleton(
                loadingLabel: "正在加载所选视频上下文"
            )
            .accessibilityIdentifier("sidebar.playback-replacement-loading")
        case .failed(_, let failure):
            failureView(failure)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
        case .idle, .loadingPage, .preparingPlayback, .ready, .failedPage:
            EmptyView()
        }
    }

    private func failureView(_ failure: GuestVideoFailure) -> some View {
        ContentUnavailableView {
            Label(failure.title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(failure.message)
        } actions: {
            Button("重试", action: retryAction)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("sidebar.playback-failure-retry")
        }
        .accessibilityIdentifier("sidebar.playback-failure")
    }

    private func retryAction() {
        if case .failedPage = model.state {
            model.retry()
        } else {
            onRetry()
        }
    }
}
