import BiliModels

/// 播放页呈现的视频：详情、按序号排好的分 P 与选中的分 P。
///
/// 只来自详情响应，不含播放清单：详情先到时页面就据此呈现，播放清单相关的规则在 `PlayableVideo`。
public struct VideoContext: Sendable, Equatable {
    public let detail: VideoDetail
    public let pages: [VideoPage]
    public let selectedPage: VideoPage

    public init(
        detail: VideoDetail,
        pages: [VideoPage],
        selectedPage: VideoPage
    ) {
        self.detail = detail
        self.pages = pages
        self.selectedPage = selectedPage
    }
}

/// 打开视频第一步（取详情）的结果：详情、按序号排好的分 P，以及不必等播放清单就已确定的分 P。
///
/// `selectedPage` 在显式 CID、命中的链接分 P 序号或视频只有一个分 P 时给出，此时 `context` 可以立即呈现；多 P 且
/// 没有指定时为 nil，由 `VideoUseCase.preparePlayback(for:)` 按服务器的续播记录选定。
public struct VideoDetailPreparation: Sendable, Equatable {
    public let detail: VideoDetail
    public let pages: [VideoPage]
    public let selectedPage: VideoPage?
    /// 应用内显式选中的分 P（`preferredCID`）从头播放，不取续播位置。
    let isExplicitSelection: Bool

    /// 分 P 已确定时可以立即呈现的页面；未确定时为 nil。
    public var context: VideoContext? {
        selectedPage.map { VideoContext(detail: detail, pages: pages, selectedPage: $0) }
    }

    /// `preparePlayback` 第一个要请求播放清单的 CID：已定的分 P，未定时是第一个分 P（先取它读续播记录）。
    public var firstPlaybackCID: Int64 {
        (selectedPage ?? pages[0]).cid
    }
}

/// 详情到达前按来源列表给的 CID 预取的播放清单请求结果，成功或失败都原样保留。
///
/// 只交给 `VideoUseCase.preparePlayback(for:prefetched:)`：CID 与详情核对一致才采用，失败也在那时才按详情权益解释。
public struct PrefetchedPlayback: Sendable {
    let cid: Int64
    let result: Result<VideoPlayback, any Error>
}

/// 播放页准备视频的用例，分两步：取得详情并尽量选定分 P（`prepareDetail`），再取得选定分 P 的播放清单
/// （`preparePlayback`）。
///
/// 分 P 只来自详情响应；缺失时视为无效响应，不再另行请求分 P。分两步是为了让调用方在详情到达时就呈现页面，
/// 不必再等一次 playurl 往返。
///
/// 用例不拥有播放器，也不保留可变状态；任何一个阶段取消都会阻止后续播放请求或结果返回。
public struct VideoUseCase: Sendable {
    private let repository: any VideoRepository

    public init(repository: any VideoRepository) {
        self.repository = repository
    }

    /// 取得详情、排好序的分 P，并在不需要续播记录时选定分 P。
    ///
    /// `preferredCID` 是用户在应用内显式选中的分 P，不存在时报错；`preferredPageNumber` 来自外部链接
    /// （从 1 开始的分 P 序号），不可信：只在 `preferredCID` 缺省时参考，超出范围时按默认规则选择。
    public func prepareDetail(
        bvid: String,
        preferredCID: Int64? = nil,
        preferredPageNumber: Int? = nil
    ) async throws -> VideoDetailPreparation {
        let resolvedDetail = try await repository.videoDetail(for: bvid)
        try Task.checkCancellation()
        guard resolvedDetail.bvid == bvid else {
            throw ContentApplicationError.invalidResponse
        }

        let sortedPages = resolvedDetail.pages.sorted(by: { $0.index < $1.index })
        guard !sortedPages.isEmpty else {
            throw ContentApplicationError.invalidResponse
        }

        let requestedPage: VideoPage?
        if let preferredCID {
            guard let page = sortedPages.first(where: { $0.cid == preferredCID }) else {
                throw ContentApplicationError.invalidRequest
            }
            requestedPage = page
        } else {
            requestedPage = preferredPageNumber.flatMap { number in
                sortedPages.first(where: { $0.index == number })
            }
        }

        return VideoDetailPreparation(
            detail: resolvedDetail,
            pages: sortedPages,
            // 只有一个分 P 时续播记录也只能指向它，不必等 playurl。
            selectedPage: requestedPage ?? (sortedPages.count == 1 ? sortedPages[0] : nil),
            isExplicitSelection: preferredCID != nil
        )
    }

    /// 取得 `preparation` 选定分 P 的播放清单；分 P 未定时先取第一个分 P 的播放信息，按其中的续播记录选定。
    ///
    /// 应用内显式选中的分 P 从头播放；链接给的分 P 与普通打开一样续播该分 P 的上次位置。`prefetched` 的 CID 等于
    /// 要请求的那个分 P 时直接采用它（含失败），不再请求；不等时忽略。
    public func preparePlayback(
        for preparation: VideoDetailPreparation,
        prefetched: PrefetchedPlayback? = nil
    ) async throws -> PlayableVideo {
        let detail = preparation.detail
        let pages = preparation.pages

        if let selectedPage = preparation.selectedPage {
            let playback = try await playback(
                detail: detail,
                bvid: detail.bvid,
                cid: selectedPage.cid,
                prefetched: prefetched
            )
            try Task.checkCancellation()
            return PlayableVideo(
                context: VideoContext(detail: detail, pages: pages, selectedPage: selectedPage),
                playback: playback,
                resumePositionSeconds: preparation.isExplicitSelection
                    ? nil
                    : Self.resumePosition(metadata: playback.resumeMetadata, page: selectedPage)
            )
        }

        let firstPage = pages[0]
        let provisionalPlayback = try await playback(
            detail: detail,
            bvid: detail.bvid,
            cid: firstPage.cid,
            prefetched: prefetched
        )
        try Task.checkCancellation()

        let selectedPage =
            provisionalPlayback.resumeMetadata.flatMap { metadata in
                pages.first(where: { $0.cid == metadata.lastPlayedCID })
            } ?? firstPage
        let playback: VideoPlayback
        if selectedPage.cid == firstPage.cid {
            playback = provisionalPlayback
        } else {
            playback = try await self.playback(
                detail: detail,
                bvid: detail.bvid,
                cid: selectedPage.cid
            )
            try Task.checkCancellation()
        }

        return PlayableVideo(
            context: VideoContext(detail: detail, pages: pages, selectedPage: selectedPage),
            playback: playback,
            resumePositionSeconds: Self.resumePosition(
                metadata: provisionalPlayback.resumeMetadata,
                page: selectedPage
            )
        )
    }

    /// 取得合集 episode 的分 P；详情必须自带至少一个分 P。
    public func pagesForCollectionEpisode(bvid: String) async throws -> [VideoPage] {
        let detail = try await repository.videoDetail(for: bvid)
        try Task.checkCancellation()
        guard detail.bvid == bvid, !detail.pages.isEmpty else {
            throw ContentApplicationError.invalidResponse
        }
        return detail.pages.sorted(by: { $0.index < $1.index })
    }

    /// 复用同一视频已经取得的详情与分 P，只为指定 CID 重新取得播放清单。
    public func preparePage(
        in context: VideoContext,
        cid: Int64
    ) async throws -> PlayableVideo {
        guard let selectedPage = context.pages.first(where: { $0.cid == cid })
        else {
            throw ContentApplicationError.invalidRequest
        }
        let playback = try await playback(
            detail: context.detail,
            bvid: context.detail.bvid,
            cid: selectedPage.cid
        )
        try Task.checkCancellation()

        return PlayableVideo(
            context: VideoContext(
                detail: context.detail,
                pages: context.pages,
                selectedPage: selectedPage
            ),
            playback: playback
        )
    }

    /// 在详情到达之前请求 `cid` 的播放清单，与详情并行；结果交给 `preparePlayback(for:prefetched:)` 核对后才采用。
    ///
    /// `cid` 来自来源列表，不可信：请求本身只是一次读取，采用前以详情核对。调用方取消时在途请求随之取消；没有 `cid`
    /// 时不请求，返回 nil。
    public func prefetchPlayback(bvid: String, cid: Int64?) async -> PrefetchedPlayback? {
        guard let cid else { return nil }
        do {
            return PrefetchedPlayback(
                cid: cid,
                result: .success(try await repository.playback(for: bvid, cid: cid))
            )
        } catch {
            return PrefetchedPlayback(cid: cid, result: .failure(error))
        }
    }

    private func playback(
        detail: VideoDetail,
        bvid: String,
        cid: Int64,
        prefetched: PrefetchedPlayback? = nil
    ) async throws -> VideoPlayback {
        do {
            if let prefetched, prefetched.cid == cid {
                return try prefetched.result.get()
            }
            return try await repository.playback(for: bvid, cid: cid)
        } catch ContentApplicationError.serviceRejected(code: _)
            where detail.access.isUPowerExclusive == true
            && detail.access.isUPowerPlayable == false
            && detail.access.isUPowerPreviewAvailable == false
        {
            // 只有详情权益三态和 playurl 业务拒绝同时明确时才收窄为权益语义。
            throw ContentApplicationError.fullViewingEntitlementRequired
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
