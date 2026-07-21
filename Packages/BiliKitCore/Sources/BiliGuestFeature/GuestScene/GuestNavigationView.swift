import BiliApplication
import Foundation
import SwiftUI

public struct GuestNavigationView<PlayerContent: View>: View {
    private let feedModel: GuestFeedViewModel
    private let videoModel: GuestVideoViewModel
    private let playerContent: () -> PlayerContent

    @State private var selectedSection: GuestSection? = .popular
    @State private var selectedBVID: String?
    @State private var searchText = ""
    @State private var submittedQuery: String?
    @State private var searchRevision = 0

    public init(
        feedModel: GuestFeedViewModel,
        videoModel: GuestVideoViewModel,
        @ViewBuilder playerContent: @escaping () -> PlayerContent
    ) {
        self.feedModel = feedModel
        self.videoModel = videoModel
        self.playerContent = playerContent
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                Label("热门", systemImage: "flame")
                    .tag(GuestSection.popular)
                    .accessibilityIdentifier("sidebar.popular")
                Label("搜索", systemImage: "magnifyingglass")
                    .tag(GuestSection.search)
                    .accessibilityIdentifier("sidebar.search")
            }
            .navigationTitle("BiliKit")
            .navigationSplitViewColumnWidth(
                min: 160,
                ideal: 180,
                max: 220
            )
        } content: {
            feedColumn
                .navigationTitle(selectedSection?.title ?? "BiliKit")
                .navigationSplitViewColumnWidth(
                    min: 300,
                    ideal: 360,
                    max: 460
                )
        } detail: {
            detailColumn
        }
        .onChange(of: selectedBVID) { _, bvid in
            guard let bvid else { return }
            videoModel.selectVideo(bvid)
        }
        .task(id: feedTaskID) {
            let intent = feedTaskID
            selectedBVID = nil
            videoModel.reset()
            guard !Task.isCancelled else { return }
            switch intent {
            case .popular:
                feedModel.loadPopular()
                await feedModel.waitForCurrentTask()
            case .search(nil, _), .none:
                feedModel.cancel()
            case let .search(.some(query), _):
                feedModel.search(query)
                await feedModel.waitForCurrentTask()
            }
        }
    }

    @ViewBuilder
    private var feedColumn: some View {
        switch selectedSection {
        case .popular:
            popularColumn
        case .search:
            searchColumn
        case nil:
            ContentUnavailableView(
                "选择一个入口",
                systemImage: "sidebar.left"
            )
        }
    }

    @ViewBuilder
    private var popularColumn: some View {
        switch feedModel.state {
        case .idle, .loading(.popular(_, _)):
            ProgressView("正在加载热门视频…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("feed.loading")
        case let .loaded(.popular(page)) where page.videos.isEmpty:
            ContentUnavailableView(
                "暂无热门视频",
                systemImage: "rectangle.stack",
                description: Text("稍后重试或检查网络连接。")
            )
        case let .loaded(.popular(page)):
            List(page.videos, selection: $selectedBVID) { video in
                GuestVideoRow(video: video)
                    .tag(video.bvid)
            }
            .listStyle(.inset)
            .accessibilityIdentifier("feed.list")
            .refreshable {
                feedModel.loadPopular(
                    page: page.pageNumber,
                    pageSize: page.pageSize
                )
                await feedModel.waitForCurrentTask()
            }
        case let .failed(request: .popular(_, _), error: error):
            GuestFailureView(
                title: error.guestTitle,
                message: error.guestMessage,
                retry: feedModel.retry
            )
            .accessibilityIdentifier("feed.failure")
        default:
            ProgressView("正在切换到热门视频…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var searchColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("搜索 B 站视频", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(performSearch)
                    .accessibilityIdentifier("search.field")

                Button("搜索", action: performSearch)
                    .buttonStyle(.borderedProminent)
                    .disabled(normalizedSearchText.isEmpty)
                    .accessibilityIdentifier("search.submit")
            }
            .padding(12)

            Divider()

            searchResults
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        switch feedModel.state {
        case let .loading(.search(query, _)):
            ProgressView("正在搜索“\(query)”…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("search.loading")
        case let .loaded(.search(query, page)) where page.videos.isEmpty:
            ContentUnavailableView.search(text: query)
                .accessibilityIdentifier("search.empty")
        case let .loaded(.search(query, page)):
            VStack(spacing: 0) {
                HStack {
                    Text("“\(query)”")
                    Spacer()
                    Text("约 \(page.totalResults.formatted()) 条结果")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                List(page.videos, selection: $selectedBVID) { video in
                    GuestVideoRow(video: video)
                        .tag(video.bvid)
                }
                .listStyle(.inset)
                .accessibilityIdentifier("search.results")
                .refreshable {
                    feedModel.search(query, page: page.pageNumber)
                    await feedModel.waitForCurrentTask()
                }
            }
        case let .failed(request: .search(_, _), error: error):
            GuestFailureView(
                title: error.guestTitle,
                message: error.guestMessage,
                retry: feedModel.retry
            )
            .accessibilityIdentifier("search.failure")
        default:
            ContentUnavailableView(
                "搜索视频",
                systemImage: "magnifyingglass",
                description: Text("输入关键词后按下 Return 或点击搜索。")
            )
            .accessibilityIdentifier("search.prompt")
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        switch videoModel.state {
        case .idle:
            ContentUnavailableView(
                "选择一个视频",
                systemImage: "play.rectangle",
                description: Text("从热门或搜索结果中选择视频后，这里会显示详情与播放器。")
            )
            .accessibilityIdentifier("detail.empty")
        case .loading:
            ProgressView("正在加载视频详情…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .preparingPlayback(context):
            GuestVideoDetailView(
                context: context,
                isPreparingPlayback: true,
                playerContent: playerContent
            )
        case let .ready(context):
            GuestVideoDetailView(
                context: context,
                isPreparingPlayback: false,
                playerContent: playerContent
            )
        case let .failed(bvid, failure):
            GuestFailureView(
                title: failure.title,
                message: failure.message,
                retry: { videoModel.selectVideo(bvid) }
            )
        }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var feedTaskID: GuestFeedTaskID {
        switch selectedSection {
        case .popular:
            .popular
        case .search:
            .search(query: submittedQuery, revision: searchRevision)
        case nil:
            .none
        }
    }

    private func performSearch() {
        let query = normalizedSearchText
        guard !query.isEmpty else { return }
        searchText = query
        selectedBVID = nil
        submittedQuery = query
        searchRevision += 1
    }
}

private enum GuestFeedTaskID: Hashable {
    case popular
    case search(query: String?, revision: Int)
    case none
}

private enum GuestSection: String, Hashable {
    case popular
    case search

    var title: String {
        switch self {
        case .popular:
            "热门"
        case .search:
            "搜索"
        }
    }
}

private struct GuestFailureView: View {
    let title: String
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("重试", action: retry)
                .buttonStyle(.borderedProminent)
        }
    }
}

private extension GuestFlowFailure {
    var title: String {
        switch self {
        case let .content(error):
            error.guestTitle
        case .playback:
            "无法准备播放"
        }
    }

    var message: String {
        switch self {
        case let .content(error):
            error.guestMessage
        case .playback:
            "当前媒体轨道或网络响应无法交给系统播放器。"
        }
    }
}

private extension GuestApplicationError {
    var guestTitle: String {
        switch self {
        case .requestRestricted, .serviceRejected:
            "请求受到限制"
        case .unsupportedMedia:
            "没有可播放的游客轨道"
        default:
            "无法加载内容"
        }
    }

    var guestMessage: String {
        switch self {
        case .invalidRequest:
            "请求参数无效，请重新选择内容。"
        case .requestRestricted:
            "服务可能返回了风控页，请降低请求频率后重试。"
        case let .serviceRejected(code):
            "服务暂时无法完成请求（代码 \(code)）。"
        case .transportFailure:
            "请检查网络连接后重试。"
        case .unsupportedMedia:
            "该视频在当前游客画质下没有 AVPlayer 可用的 AVC/AAC 轨道。"
        case .invalidResponse:
            "接口数据与当前客户端预期不一致，请稍后重试。"
        case .unavailable:
            "暂时无法完成请求，请稍后重试。"
        }
    }
}
