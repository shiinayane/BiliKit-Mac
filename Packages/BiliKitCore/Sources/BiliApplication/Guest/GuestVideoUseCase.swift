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

/// 优先使用详情响应自带的分 P；旧响应缺失时才回退到独立分 P endpoint。
///
/// 用例不拥有播放器，也不保留可变状态；任何一个阶段取消都会阻止后续播放请求或结果返回。
public struct GuestVideoUseCase: Sendable {
    private let repository: any GuestContentRepository

    public init(repository: any GuestContentRepository) {
        self.repository = repository
    }

    public func prepareVideo(bvid: String) async throws -> GuestVideoContext {
        let resolvedDetail = try await repository.videoDetail(for: bvid)
        try Task.checkCancellation()

        let resolvedPages =
            resolvedDetail.pages.isEmpty
            ? try await repository.pages(for: bvid)
            : resolvedDetail.pages
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

    /// 取得合集 episode 的分 P；详情已含 pages 时不重复请求独立 pagelist。
    public func pagesForCollectionEpisode(bvid: String) async throws -> [VideoPage] {
        let detail = try await repository.videoDetail(for: bvid)
        try Task.checkCancellation()
        guard detail.bvid == bvid else {
            throw GuestApplicationError.invalidResponse
        }
        let resolvedPages =
            detail.pages.isEmpty
            ? try await repository.pages(for: bvid)
            : detail.pages
        try Task.checkCancellation()
        return resolvedPages.sorted(by: { $0.index < $1.index })
    }

    /// 复用同一视频已经取得的详情与分 P，只为指定 CID 重新取得播放清单。
    public func preparePage(
        in context: GuestVideoContext,
        cid: Int64
    ) async throws -> GuestVideoContext {
        guard let selectedPage = context.pages.first(where: { $0.cid == cid })
        else {
            throw GuestApplicationError.invalidRequest
        }
        let playback = try await repository.playback(
            for: context.detail.bvid,
            cid: selectedPage.cid
        )
        try Task.checkCancellation()

        return GuestVideoContext(
            detail: context.detail,
            pages: context.pages,
            selectedPage: selectedPage,
            playback: playback
        )
    }
}
