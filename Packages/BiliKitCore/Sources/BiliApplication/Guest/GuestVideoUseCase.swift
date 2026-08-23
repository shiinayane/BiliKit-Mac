import BiliModels

/// 播放页一次准备所聚合的详情、分 P、选中分 P 与播放清单。
public struct GuestVideoContext: Sendable, Equatable {
    public let detail: VideoDetail
    public let pages: [VideoPage]
    public let selectedPage: VideoPage
    public let playback: VideoPlayback
    public let resumePositionSeconds: Double?

    public var accessNotice: PlaybackAccessNotice? {
        guard detail.access.isUPowerExclusive == true else { return nil }
        let fullDuration = Int64(selectedPage.durationSeconds)
            .multipliedReportingOverflow(by: 1_000)
        if detail.access.isUPowerPreviewAvailable == true,
            case .progressive(let source) = playback.media,
            source.durationMilliseconds > 0,
            selectedPage.durationSeconds > 0,
            !fullDuration.overflow,
            source.durationMilliseconds < fullDuration.partialValue
        {
            return .upowerPreview(
                previewDurationSeconds: Int(source.durationMilliseconds / 1_000),
                fullDurationSeconds: selectedPage.durationSeconds
            )
        }
        return .upowerExclusive
    }

    public init(
        detail: VideoDetail,
        pages: [VideoPage],
        selectedPage: VideoPage,
        playback: VideoPlayback,
        resumePositionSeconds: Double? = nil
    ) {
        self.detail = detail
        self.pages = pages
        self.selectedPage = selectedPage
        self.playback = playback
        self.resumePositionSeconds = resumePositionSeconds
    }
}

public enum PlaybackAccessNotice: Sendable, Equatable {
    case upowerExclusive
    case upowerPreview(
        previewDurationSeconds: Int,
        fullDurationSeconds: Int
    )
}

/// 优先使用详情响应自带的分 P；旧响应缺失时才回退到独立分 P endpoint。
///
/// 用例不拥有播放器，也不保留可变状态；任何一个阶段取消都会阻止后续播放请求或结果返回。
public struct GuestVideoUseCase: Sendable {
    private let repository: any GuestContentRepository

    public init(repository: any GuestContentRepository) {
        self.repository = repository
    }

    public func prepareVideo(
        bvid: String,
        preferredCID: Int64? = nil
    ) async throws -> GuestVideoContext {
        let resolvedDetail = try await repository.videoDetail(for: bvid)
        try Task.checkCancellation()
        guard resolvedDetail.bvid == bvid else {
            throw GuestApplicationError.invalidResponse
        }

        let resolvedPages =
            resolvedDetail.pages.isEmpty
            ? try await repository.pages(for: bvid)
            : resolvedDetail.pages
        try Task.checkCancellation()
        let sortedPages = resolvedPages.sorted(by: { $0.index < $1.index })
        guard let firstPage = sortedPages.first else {
            throw GuestApplicationError.invalidResponse
        }

        if let preferredCID {
            guard
                let selectedPage = sortedPages.first(where: {
                    $0.cid == preferredCID
                })
            else {
                throw GuestApplicationError.invalidRequest
            }
            let playback = try await playback(
                detail: resolvedDetail,
                bvid: bvid,
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

        let provisionalPlayback = try await playback(
            detail: resolvedDetail,
            bvid: bvid,
            cid: firstPage.cid
        )
        try Task.checkCancellation()

        let selectedPage =
            provisionalPlayback.resumeMetadata.flatMap { metadata in
                sortedPages.first(where: { $0.cid == metadata.lastPlayedCID })
            } ?? firstPage
        let playback: VideoPlayback
        if selectedPage.cid == firstPage.cid {
            playback = provisionalPlayback
        } else {
            playback = try await self.playback(
                detail: resolvedDetail,
                bvid: bvid,
                cid: selectedPage.cid
            )
            try Task.checkCancellation()
        }

        return GuestVideoContext(
            detail: resolvedDetail,
            pages: sortedPages,
            selectedPage: selectedPage,
            playback: playback,
            resumePositionSeconds: Self.resumePosition(
                metadata: provisionalPlayback.resumeMetadata,
                page: selectedPage
            )
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
        let playback = try await playback(
            detail: context.detail,
            bvid: context.detail.bvid,
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

    private func playback(
        detail: VideoDetail,
        bvid: String,
        cid: Int64
    ) async throws -> VideoPlayback {
        do {
            return try await repository.playback(for: bvid, cid: cid)
        } catch GuestApplicationError.serviceRejected(code: _)
            where detail.access.isUPowerExclusive == true
            && detail.access.isUPowerPlayable == false
            && detail.access.isUPowerPreviewAvailable == false
        {
            // 只有详情权益三态和 playurl 业务拒绝同时明确时才收窄为权益语义。
            throw GuestApplicationError.fullViewingEntitlementRequired
        }
    }

    static func resumePosition(
        metadata: PlaybackResumeMetadata?,
        page: VideoPage
    ) -> Double? {
        guard let metadata,
            metadata.lastPlayedCID == page.cid,
            page.durationSeconds > 0
        else { return nil }
        let seconds = Double(metadata.positionMilliseconds) / 1_000
        let latestUsefulPosition =
            Double(page.durationSeconds)
            - PlaybackResumePolicy.completedThresholdSeconds
        guard seconds > 0, seconds < latestUsefulPosition else { return nil }
        return seconds
    }
}
