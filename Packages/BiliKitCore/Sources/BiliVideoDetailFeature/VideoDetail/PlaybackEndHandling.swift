import BiliModels

/// `VideoViewModel.handlePlaybackEnded` 做了什么，或要调用方接着做什么。
public enum PlaybackEndHandling: Sendable, Equatable {
    /// 不是此刻呈现的那一项、或偏好与访问状态要求停下、或已是列表最后一项。
    case none
    /// 已从头重播（单集循环，或列表循环时列表只有当前一个分 P）。
    case replayed
    /// 要重播但引擎没有回到开头：seek 失败、落点不在开头附近，或期间 item、意图或用户操作变了。
    case replayFailed
    /// 要播下一项；跳转由调用方走与详情区选分 P、选集相同的导航。
    case advance(PlaybackEndAdvance)
    /// 下一集在合集里，但缺少能播放它的身份（没有 BV 号或身份不一致），停下。
    case nextUnavailable
}

/// 自动连播与列表循环要播的下一项。
public enum PlaybackEndAdvance: Sendable, Equatable {
    /// 同一视频的另一个分 P。
    case page(bvid: String, page: VideoPage)
    /// 合集里的另一集；分 P 未知时要先经 `VideoViewModel.selectCollectionEpisode` 解析。
    case episode(VideoCollectionEpisode)

    /// 提示里的名字，与选集菜单同一写法。
    public var title: String {
        switch self {
        case .page(_, let page): page.displayLabel
        case .episode(let episode): episode.displayTitle
        }
    }
}
