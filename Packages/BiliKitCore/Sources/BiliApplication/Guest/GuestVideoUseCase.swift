import BiliModels

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

public struct GuestVideoUseCase: Sendable {
    private let repository: any GuestContentRepository

    public init(repository: any GuestContentRepository) {
        self.repository = repository
    }

    public func prepareVideo(
        bvid: String,
        quality: Int = 32
    ) async throws -> GuestVideoContext {
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
            cid: selectedPage.cid,
            quality: quality
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
