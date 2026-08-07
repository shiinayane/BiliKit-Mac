import BiliApplication
import BiliModels
import BiliUI
import SwiftUI

/// 在播放状态下用真实详情组织同一系统 Sidebar，不拥有网络或播放生命周期。
///
/// `presentedContext` 让 Sidebar 与主区共享最近有效内容；替换视频的 loading／failed
/// 状态会遮挡旧内容并从辅助树隐藏，避免把上一视频误读成当前上下文。
public struct PlaybackContextSidebar: View {
    private let model: GuestVideoViewModel
    private let onRetry: () -> Void
    @State private var isSummaryExpanded = true
    @State private var arePartsExpanded = true

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
                }
            } else {
                emptyState
            }
        }
        .navigationTitle("观看辅助")
        .accessibilityIdentifier("sidebar.playback-context")
    }

    private func sidebarContent(_ context: GuestVideoContext) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
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
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .accessibilityIdentifier("sidebar.playback-summary.text")
        }
        .font(.headline)
        .accessibilityIdentifier("sidebar.playback-summary")
    }

    private func partsSection(_ context: GuestVideoContext) -> some View {
        DisclosureGroup("分 P", isExpanded: $arePartsExpanded) {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(context.pages) { page in
                    partRow(
                        page,
                        isSelected: page.id == context.selectedPage.id
                    )
                }
            }
            .padding(.top, 8)
        }
        .font(.headline)
        .accessibilityIdentifier("sidebar.playback-parts")
    }

    private func partRow(
        _ page: VideoPage,
        isSelected: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isSelected ? "play.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)

            Text("P\(page.index)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 30, alignment: .leading)

            Text(page.title)
                .font(.callout)
                .lineLimit(2)

            Spacer(minLength: 8)

            Text(
                VideoDurationFormatting.string(
                    seconds: page.durationSeconds
                )
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "第 \(page.index) 分 P，\(page.title)，"
                + VideoDurationFormatting.string(
                    seconds: page.durationSeconds
                )
        )
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("sidebar.playback-part.\(page.index)")
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
        case .idle, .preparingPlayback, .ready:
            false
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch model.state {
        case .loading, .preparingPlayback:
            ProgressView("正在加载视频上下文…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("sidebar.playback-loading")
        case .failed(_, let failure):
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
            ZStack {
                Rectangle().fill(.background)
                ProgressView("正在加载所选视频…")
                    .controlSize(.large)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("sidebar.playback-replacement-loading")
        case .failed(_, let failure):
            failureView(failure)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
        case .idle, .preparingPlayback, .ready:
            EmptyView()
        }
    }

    private func failureView(_ failure: GuestVideoFailure) -> some View {
        ContentUnavailableView {
            Label(failure.title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(failure.message)
        } actions: {
            Button("重试", action: onRetry)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("sidebar.playback-failure-retry")
        }
        .accessibilityIdentifier("sidebar.playback-failure")
    }
}
