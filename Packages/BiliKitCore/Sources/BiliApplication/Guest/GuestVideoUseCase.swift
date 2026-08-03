import BiliModels

/// 播放页一次准备所聚合的详情、分 P、选中分 P 与播放清单。
public struct GuestVideoContext: Sendable, Equatable {
    public let detail: VideoDetail
    public let pages: [VideoPage]
    public let selectedPage: VideoPage
    public let playback: VideoPlayback

    public init(
        detail: VideoDetail,
        pages: [VideoPage],
        selectedPage: VideoPage,
        playback: VideoPlayback
    ) {
        self.detail = detail
        self.pages = pages
        self.selectedPage = selectedPage
        self.playback = playback
    }
}

/// 并行取得详情与分 P，再为排序后的首分 P 取得播放清单。
///
/// 用例不拥有播放器，也不保留可变状态；任何一个阶段取消都会阻止后续播放请求或结果返回。
public struct GuestVideoUseCase: Sendable {
    private let repository: any GuestContentRepository

    public init(repository: any GuestContentRepository) {
        self.repository = repository
    }

    public func prepareVideo(bvid: String) async throws -> GuestVideoContext {
        async let detail = repository.videoDetail(for: bvid)
        async let pages = repository.pages(for: bvid)
        let (resolvedDetail, resolvedPages) = try await (detail, pages)
        try Task.checkCancellation()

        let sortedPages = resolvedPages.sorted(by: { $0.index < $1.index })
        guard let selectedPage = sortedPages.first else {
            throw GuestApplicationError.invalidResponse
        }
        let playback = try await repository.playback(
            for: bvid,
            cid: selectedPage.cid
        )
        try Task.checkCancellation()

        return GuestVideoContext(
            detail: resolvedDetail,
            pages: sortedPages,
            selectedPage: selectedPage,
            playback: playback
        )
    }
}
