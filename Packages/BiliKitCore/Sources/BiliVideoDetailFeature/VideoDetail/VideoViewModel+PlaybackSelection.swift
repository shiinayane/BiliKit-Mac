/// 播放选择策略：把导航给出的意图落到当前视频上，以及播放失败后的重试。
///
/// 只读写本模型；导航层（App 的 `AppNavigationCoordinator`）负责去重与是否建立播放 surface，在这里之前完成。
extension VideoViewModel {
    /// 开始或替换当前视频，由导航在意图变化时调用。
    ///
    /// 只在已呈现且正在请求的就是这个视频、并且没有整体失败时就地处理。另一个视频加载中残留的旧详情不算；
    /// 整体失败（详情或播放器准备失败）重新加载，重试才不会被同一身份的去重吞掉。
    public func select(_ intent: PlaybackSelectionIntent) {
        var isFailed = false
        if case .failed = state { isFailed = true }
        guard presentedBVID == intent.bvid,
            requestedSelectionBVID == intent.bvid,
            !isFailed
        else {
            loadVideo(
                intent.bvid,
                preferredCID: intent.preferredCID,
                preferredPageNumber: intent.preferredPageNumber,
                startSeconds: intent.preferredStartSeconds,
                firstPageCIDHint: intent.firstPageCIDHint
            )
            return
        }
        // 当前视频的分 P 序号直接换算为 CID，在现有 pages 内切换。没给分 P 或序号超出范围时
        // 已经在看这个视频，保持当前播放。
        let pageCID = intent.preferredPageNumber.flatMap(presentedPageCID(forNumber:))
        guard let preferredCID = intent.preferredCID ?? pageCID else { return }
        // 失败的分 P 收到带新起播秒数的链接时按新秒数重开，否则沿用重试。
        if failedPageCID == preferredCID, intent.preferredStartSeconds == nil {
            retry()
        } else {
            selectPage(cid: preferredCID, startSeconds: intent.preferredStartSeconds)
        }
    }

    /// 链接带 `t=` 且指向正在播放、播放器已装好的分 P（没给分 P 视为当前分 P）、秒数在可跳转范围内时，
    /// 返回要原地跳到的秒数；其余情况为 nil，交给导航打开或切换分 P。
    ///
    /// `currentPlaybackBVID` 是导航当前的播放身份：模型可能还留着已离开的视频的详情。
    public func inPlaceStartSeconds(
        for intent: PlaybackSelectionIntent,
        currentPlaybackBVID: String?
    ) -> Int? {
        guard let startSeconds = intent.preferredStartSeconds,
            intent.preferredCID == nil,
            intent.bvid == currentPlaybackBVID,
            intent.bvid == presentedBVID,
            canSeekPresentedPage(number: intent.preferredPageNumber, toSeconds: startSeconds)
        else { return nil }
        return startSeconds
    }

    /// 播放失败（整体或分 P）时由本模型重试并返回 true；不在失败状态（例如已被重置）时返回 false，由调用方
    /// 重新发出当前导航意图。
    ///
    /// 模型记得链接起播时间是否已经用过，开播后才失败的重试不会跳回链接时间。
    public func retryIfFailed() -> Bool {
        switch state {
        case .failed, .failedPage:
            retry()
            return true
        case .idle, .loading, .loadingPage, .preparingPlayback, .ready:
            return false
        }
    }
}
