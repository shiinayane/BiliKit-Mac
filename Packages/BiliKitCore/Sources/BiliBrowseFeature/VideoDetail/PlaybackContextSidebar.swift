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
    private let onSelectPlayback: (String, Int64?) -> Void
    @State private var isSummaryExpanded = true

    public init(
        model: GuestVideoViewModel,
        onRetry: @escaping () -> Void,
        onSelectPlayback: @escaping (String, Int64?) -> Void
    ) {
        self.model = model
        self.onRetry = onRetry
        self.onSelectPlayback = onSelectPlayback
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

                let projection = selectionProjection(context)
                if !projection.isHidden {
                    playbackSelectionSection(context, projection: projection)
                    Divider()
                }

                commentsUnavailableSection
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
        }
        .font(.headline)
    }

    private func selectionProjection(
        _ context: GuestVideoContext
    ) -> PlaybackSelectionProjection {
        let episodes = context.detail.collection?.sections.flatMap(\.episodes) ?? []
        let pagesByEpisode = Dictionary(
            uniqueKeysWithValues: episodes.compactMap { episode in
                model.collectionEpisodePages(for: episode.id).map {
                    (episode.id, $0)
                }
            }
        )
        return PlaybackSelectionProjection(
            context: context,
            selectedEpisodeID: model.selectedCollectionEpisode,
            requestedBVID: model.requestedSelectionBVID,
            requestedCID: model.requestedPreferredCID,
            presentedIdentity: model.presentedPlaybackIdentity,
            pageStates: model.collectionEpisodePageStates,
            pagesByEpisode: pagesByEpisode
        )
    }

    @ViewBuilder
    private func playbackSelectionSection(
        _ context: GuestVideoContext,
        projection: PlaybackSelectionProjection
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let collectionTitle = projection.collectionTitle {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(collectionTitle)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if let position = projection.episodePositionText {
                        Text(position)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                .font(.headline)
            }

            if projection.showsEpisodePicker {
                episodePicker(context, projection: projection)
            } else if projection.showsStaticEpisodeTitle,
                let episodeTitle = projection.selectedEpisodeTitle
            {
                LabeledContent("选集") {
                    Text(episodeTitle)
                        .multilineTextAlignment(.trailing)
                }
                .font(.callout)
            }

            if let placeholder = projection.episodePlaceholder {
                Text(placeholder)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            selectedEpisodePages(context, projection: projection)
        }
    }

    private func episodePicker(
        _ context: GuestVideoContext,
        projection: PlaybackSelectionProjection
    ) -> some View {
        Picker(
            "选集",
            selection: Binding(
                get: { projection.selectedEpisodeID },
                set: { identity in
                    guard let identity,
                        let episode = context.detail.collection?.sections
                            .flatMap(\.episodes)
                            .first(where: { $0.id == identity })
                    else { return }
                    selectEpisode(episode)
                }
            )
        ) {
            if projection.selectedEpisodeID == nil {
                Text("当前视频不在合集目录中")
                    .tag(Optional<VideoCollectionEpisodeIdentity>.none)
                    .disabled(true)
            }
            ForEach(projection.episodeSections) { section in
                Section(section.title.isEmpty ? "选集" : section.title) {
                    ForEach(section.episodes) { episode in
                        Text(episode.title)
                            .tag(Optional(episode.id))
                            .disabled(!episode.isEnabled)
                    }
                }
            }
        }
        .pickerStyle(.menu)
    }

    @ViewBuilder
    private func selectedEpisodePages(
        _ context: GuestVideoContext,
        projection: PlaybackSelectionProjection
    ) -> some View {
        switch projection.selectedPages {
        case .ready(let pages) where pages.count > 1:
            Picker(
                "分 P",
                selection: Binding(
                    get: { projection.selectedPageCID },
                    set: { cid in
                        guard let cid else { return }
                        onSelectPlayback(context.detail.bvid, cid)
                    }
                )
            ) {
                if projection.selectedPageCID == nil {
                    Text("请选择分 P")
                        .tag(Optional<Int64>.none)
                        .disabled(true)
                }
                ForEach(pages) { page in
                    Text(
                        "P\(page.index) · \(page.title) · "
                            + VideoDurationFormatting.string(
                                seconds: page.durationSeconds
                            )
                    )
                    .tag(Optional(page.cid))
                }
            }
            .pickerStyle(.menu)
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在加载所选视频的分 P")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        case .failed:
            HStack(spacing: 8) {
                Text("无法加载所选视频的分 P")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("重试") {
                    guard let identity = projection.selectedEpisodeID,
                        let episode = context.detail.collection?.sections
                            .flatMap(\.episodes)
                            .first(where: { $0.id == identity })
                    else { return }
                    model.retryCollectionEpisodePages(episode)
                }
            }
            .font(.callout)
        case .ready, .empty:
            EmptyView()
        }
    }

    private func selectEpisode(_ episode: VideoCollectionEpisode) {
        model.selectCollectionEpisode(episode) { bvid, preferredCID in
            onSelectPlayback(bvid, preferredCID)
        }
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
        }
    }

    private func retryAction() {
        if case .failedPage = model.state {
            model.retry()
        } else {
            onRetry()
        }
    }
}
