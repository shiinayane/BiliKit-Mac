#if DEBUG
import AppKit
import BiliApplication
import BiliAuthFeature
import BiliBrowseFeature
import BiliLibraryFeature
import BiliModels
import CoreGraphics
import Foundation
import SwiftUI

struct UITestConfiguration {
    let isEnabled: Bool
    let usesCompactWindow: Bool
    let usesDarkAppearance: Bool
    let usesLargeText: Bool

    static var current: UITestConfiguration {
        parse(arguments: ProcessInfo.processInfo.arguments)
    }

    static func parse(arguments: [String]) -> UITestConfiguration {
        let isEnabled = arguments.contains("-ui-testing")
        return UITestConfiguration(
            isEnabled: isEnabled,
            usesCompactWindow:
                isEnabled && arguments.contains("-ui-testing-compact"),
            usesDarkAppearance:
                isEnabled && arguments.contains("-ui-testing-dark"),
            usesLargeText:
                isEnabled && arguments.contains("-ui-testing-large-text")
        )
    }
}

struct UITestConfiguredRoot: View {
    let configuration: UITestConfiguration

    var body: some View {
        UITestContentView()
            .background(
                UITestWindowConfigurator(
                    contentSize: configuration.usesCompactWindow
                        ? CGSize(width: 1_080, height: 680)
                        : CGSize(width: 1_320, height: 820)
                )
            )
            .preferredColorScheme(
                configuration.usesDarkAppearance ? .dark : .light
            )
            .environment(
                \.dynamicTypeSize,
                configuration.usesLargeText
                    ? .accessibility1
                    : .large
            )
    }
}

private struct UITestWindowConfigurator: NSViewRepresentable {
    let contentSize: CGSize

    func makeNSView(context: Context) -> WindowConfiguringView {
        WindowConfiguringView(contentSize: contentSize)
    }

    func updateNSView(
        _ view: WindowConfiguringView,
        context: Context
    ) {
        view.contentSize = contentSize
        view.applyIfPossible()
    }
}

private final class WindowConfiguringView: NSView {
    var contentSize: CGSize

    init(contentSize: CGSize) {
        self.contentSize = contentSize
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyIfPossible()
        DispatchQueue.main.async { [weak self] in
            self?.applyIfPossible()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.applyIfPossible()
        }
    }

    func applyIfPossible() {
        guard let window else { return }
        window.isRestorable = false
        guard abs(window.contentLayoutRect.width - contentSize.width) > 1
                || abs(window.contentLayoutRect.height - contentSize.height) > 1
        else {
            return
        }
        window.setContentSize(contentSize)
    }
}

private struct UITestContentView: View {
    private let content: ContentView

    init() {
        let repository = UITestGuestRepository()
        let playback = UITestPlayback()
        let feedModel = GuestFeedViewModel(
            useCase: GuestFeedUseCase(repository: repository)
        )
        let videoModel = GuestVideoViewModel(
            useCase: GuestVideoUseCase(repository: repository),
            playback: playback
        )
        let timeline = UITestTimeline()
        let subtitleModel = SubtitleViewModel(
            useCase: SubtitleUseCase(
                repository: UITestSubtitleRepository()
            ),
            timeline: timeline
        )
        let danmakuModel = DanmakuControlsViewModel(
            presentation: UITestDanmakuPresentation()
        )
        let authenticationModel = AuthenticationViewModel(
            service: UITestAuthenticationService(),
            qrCodeProvider: UITestQRCodeProvider()
        )
        let historyModel = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(
                repository: UITestHistoryRepository()
            )
        )
        let navigationModel = AppNavigationModel(
            startPlayback: { bvid in
                videoModel.selectVideo(bvid)
            },
            stopPlayback: {
                videoModel.reset()
                subtitleModel.reset()
                danmakuModel.reset()
            }
        )

        content = ContentView(
            navigationModel: navigationModel,
            feedModel: feedModel,
            videoModel: videoModel,
            subtitleModel: subtitleModel,
            danmakuModel: danmakuModel,
            authenticationModel: authenticationModel,
            historyModel: historyModel,
            playerContent: AnyView(
                ZStack {
                    Color.black
                    Image(systemName: "play.rectangle")
                        .font(.largeTitle)
                        .foregroundStyle(.white.opacity(0.75))
                        .accessibilityHidden(true)
                }
            )
        )
    }

    var body: some View {
        content
    }
}

private struct UITestGuestRepository: GuestContentRepository {
    func popular(page: Int, pageSize: Int) async throws -> PopularPage {
        PopularPage(
            videos: Self.popularVideos,
            pageNumber: page,
            pageSize: pageSize
        )
    }

    func searchVideos(keyword: String, page: Int) async throws -> SearchPage {
        SearchPage(
            videos: Self.searchVideos,
            pageNumber: page,
            pageSize: Self.searchVideos.count,
            totalResults: Self.searchVideos.count,
            totalPages: 1
        )
    }

    func videoDetail(for bvid: String) async throws -> VideoDetail {
        VideoDetail(
            bvid: bvid,
            title: "自制播放页示例",
            summary: "用于验证布局、键盘和辅助显示的本机假值。",
            coverURL: nil,
            owner: Self.owner,
            statistics: Self.statistics,
            durationSeconds: 4_205,
            publishedAt: Self.publishedAt,
            dimension: VideoDimension(width: 1_920, height: 1_080, rotation: 0)
        )
    }

    func pages(for bvid: String) async throws -> [VideoPage] {
        [
            VideoPage(
                cid: 101,
                index: 1,
                title: "示例章节一",
                durationSeconds: 1_205
            ),
            VideoPage(
                cid: 102,
                index: 2,
                title: "示例章节二",
                durationSeconds: 1_400
            ),
            VideoPage(
                cid: 103,
                index: 3,
                title: "示例章节三",
                durationSeconds: 1_600
            ),
        ]
    }

    func playback(
        for bvid: String,
        cid: Int64,
        quality: Int
    ) async throws -> VideoPlayback {
        VideoPlayback(
            manifest: PlaybackManifest(
                videoRepresentations: [],
                audioRepresentations: []
            ),
            mediaHeaders: [:]
        )
    }

    private static let owner = VideoOwner(
        id: 1,
        name: "示例创作者"
    )
    private static let statistics = VideoStatistics(
        viewCount: 123_456,
        danmakuCount: 7_890,
        likeCount: 4_321
    )
    private static let publishedAt = Date(timeIntervalSince1970: 1_785_000_000)

    private static let popularVideos = (1...8).map { index in
        PopularVideo(
            bvid: "fixture-video-\(index)",
            title: "自制热门示例 \(index)：用于检查两行标题与文字放大",
            coverURL: nil,
            owner: owner,
            statistics: statistics,
            durationSeconds: 600 + index * 37,
            publishedAt: publishedAt
        )
    }

    private static let searchVideos = (1...4).map { index in
        SearchVideo(
            bvid: "fixture-search-\(index)",
            title: "自制搜索结果 \(index)",
            coverURL: nil,
            owner: owner,
            statistics: statistics,
            durationSeconds: 900 + index * 15,
            publishedAt: publishedAt
        )
    }
}

@MainActor
private final class UITestPlayback: PlaybackControlling {
    func load(
        _ playback: VideoPlayback,
        identity: PlaybackItemIdentity
    ) async throws {}

    func pause() {}

    func stop() {}
}

@MainActor
private final class UITestTimeline: PlaybackTimelineProviding {
    let currentTimelineSnapshot = PlaybackTimelineSnapshot.idle

    func timelineUpdates() -> AsyncStream<PlaybackTimelineSnapshot> {
        AsyncStream { continuation in
            continuation.yield(.idle)
            continuation.finish()
        }
    }
}

private struct UITestSubtitleRepository: SubtitleRepository {
    func tracks(
        for identity: PlaybackItemIdentity
    ) async throws -> [SubtitleTrack] {
        []
    }

    func cues(
        for trackID: String,
        identity: PlaybackItemIdentity
    ) async throws -> [SubtitleCue] {
        []
    }

    func reset(for identity: PlaybackItemIdentity) async {}
}

@MainActor
private final class UITestDanmakuPresentation:
    DanmakuPresentationControlling
{
    func start(for identity: PlaybackItemIdentity) {}

    func setEnabled(_ enabled: Bool) {}

    func setModeVisibility(
        scrolling: Bool,
        top: Bool,
        bottom: Bool
    ) {}

    func stop() {}
}

private struct UITestAuthenticationService: AuthenticationServicing {
    func restore() async -> AuthenticationState { .signedOut }
    func requestQRCode() async -> AuthenticationState { .signedOut }
    func pollOnce() async -> AuthenticationState { .signedOut }
    func finalizeLogin() async -> AuthenticationState { .signedOut }
    func cancelLogin() async -> AuthenticationState { .signedOut }
    func logout() async -> AuthenticationState { .signedOut }
}

private struct UITestQRCodeProvider: AuthenticationQRCodeProviding {
    func makeQRCodeImage(scale: Int) async throws -> CGImage? { nil }
}

private struct UITestHistoryRepository: WatchHistoryRepository {
    func watchHistory(
        after continuation: WatchHistoryContinuation?,
        pageSize: Int
    ) async throws -> WatchHistoryPage {
        WatchHistoryPage(items: [], continuation: nil)
    }
}
#endif
