import BiliAPI
import BiliPlayback
import SwiftUI

struct GuestNavigationView: View {
    let model: GuestAppModel
    let playerEngine: AVPlayerEngine

    @State private var selectedSection: GuestSection? = .popular
    @State private var selectedBVID: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                Label("热门", systemImage: "flame")
                    .tag(GuestSection.popular)
                    .accessibilityIdentifier("sidebar.popular")
            }
            .navigationTitle("BiliKit")
            .navigationSplitViewColumnWidth(
                min: 160,
                ideal: 180,
                max: 220
            )
        } content: {
            feedColumn
                .navigationTitle("热门")
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
            model.selectVideo(bvid)
        }
    }

    @ViewBuilder
    private var feedColumn: some View {
        switch model.feedState {
        case .idle, .loading:
            ProgressView("正在加载热门视频…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("feed.loading")
        case let .loaded(page) where page.videos.isEmpty:
            ContentUnavailableView(
                "暂无热门视频",
                systemImage: "rectangle.stack",
                description: Text("稍后重试或检查网络连接。")
            )
        case let .loaded(page):
            List(page.videos, selection: $selectedBVID) { video in
                PopularVideoRow(video: video)
                    .tag(video.bvid)
            }
            .listStyle(.inset)
            .accessibilityIdentifier("feed.list")
            .refreshable {
                model.loadPopular(
                    page: page.pageNumber,
                    pageSize: page.pageSize
                )
                await model.waitForFeed()
            }
        case let .failed(error):
            GuestFailureView(
                title: error.guestTitle,
                message: error.guestMessage,
                retry: { model.loadPopular() }
            )
            .accessibilityIdentifier("feed.failure")
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        switch model.selectionState {
        case .idle:
            ContentUnavailableView(
                "选择一个视频",
                systemImage: "play.rectangle",
                description: Text("从热门列表中选择视频后，这里会显示详情与播放器。")
            )
            .accessibilityIdentifier("detail.empty")
        case .loading:
            ProgressView("正在加载视频详情…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .preparingPlayback(context):
            GuestVideoDetailView(
                context: context,
                playerEngine: playerEngine,
                isPreparingPlayback: true
            )
        case let .ready(context):
            GuestVideoDetailView(
                context: context,
                playerEngine: playerEngine,
                isPreparingPlayback: false
            )
        case let .failed(bvid, failure):
            GuestFailureView(
                title: failure.title,
                message: failure.message,
                retry: { model.selectVideo(bvid) }
            )
        }
    }
}

private enum GuestSection: String, Hashable {
    case popular
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
        case let .api(error):
            error.guestTitle
        case .playback:
            "无法准备播放"
        }
    }

    var message: String {
        switch self {
        case let .api(error):
            error.guestMessage
        case .playback:
            "当前媒体轨道或网络响应无法交给系统播放器。"
        }
    }
}

private extension BiliAPIError {
    var guestTitle: String {
        switch self {
        case .nonJSONResponse, .apiRejected:
            "请求受到限制"
        case .noAVCVideo, .noAACAudio:
            "没有可播放的游客轨道"
        default:
            "无法加载内容"
        }
    }

    var guestMessage: String {
        switch self {
        case .invalidRequest:
            "请求参数无效，请重新选择内容。"
        case .httpStatus(403), .apiRejected(code: -403, _):
            "匿名请求被服务拒绝，请稍后重试。"
        case .apiRejected(code: -412, _), .nonJSONResponse:
            "服务可能返回了风控页，请降低请求频率后重试。"
        case let .apiRejected(code, _):
            "服务暂时无法完成请求（代码 \(code)）。"
        case .transportFailure:
            "请检查网络连接后重试。"
        case .noAVCVideo, .noAACAudio:
            "该视频在当前游客画质下没有 AVPlayer 可用的 AVC/AAC 轨道。"
        case .responseTooLarge:
            "服务响应超过安全上限。"
        case .decodingFailed, .missingData, .invalidMediaData,
             .invalidWBIKey, .signingFailed:
            "接口数据与当前客户端预期不一致，请稍后重试。"
        default:
            "暂时无法完成请求，请稍后重试。"
        }
    }
}
