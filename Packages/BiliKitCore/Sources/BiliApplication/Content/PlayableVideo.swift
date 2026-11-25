import BiliModels

/// 已取得播放清单、可以交给播放器的一项：播放页的详情与选中分 P（`VideoContext`），加上该分 P 的播放清单与续播位置。
///
/// 充电提示、可跳转时长与链接起播位置都取决于实际下发的媒体，所以只在这里给出；详情先到、播放清单还没到时，
/// 页面只有 `VideoContext`，这些规则都还不成立。
public struct PlayableVideo: Sendable, Equatable {
    public let context: VideoContext
    public let playback: VideoPlayback
    public let resumePositionSeconds: Double?

    public init(
        context: VideoContext,
        playback: VideoPlayback,
        resumePositionSeconds: Double? = nil
    ) {
        self.context = context
        self.playback = playback
        self.resumePositionSeconds = resumePositionSeconds
    }

    public var accessNotice: PlaybackAccessNotice? {
        let detail = context.detail
        let selectedPage = context.selectedPage
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

    /// 当前分 P 里可以跳到的秒数上限（不含）；时长未知时为 nil。
    ///
    /// 充电试看只播放试看片段，上限是试看时长。评论时间戳是否显示为链接、链接起播与原地跳转都按它判断。
    public var seekableDurationSeconds: Int? {
        if case .upowerPreview(let previewDurationSeconds, _) = accessNotice {
            return previewDurationSeconds > 0 ? previewDurationSeconds : nil
        }
        let durationSeconds = context.selectedPage.durationSeconds
        return durationSeconds > 0 ? durationSeconds : nil
    }

    /// 秒数是否在可跳转范围内：不小于 0 且小于上限。
    public static func accepts(seconds: Int, seekableDurationSeconds: Int?) -> Bool {
        guard let seekableDurationSeconds else { return false }
        return seconds >= 0 && seconds < seekableDurationSeconds
    }

    public func acceptsSeek(toSeconds seconds: Int) -> Bool {
        Self.accepts(seconds: seconds, seekableDurationSeconds: seekableDurationSeconds)
    }

    /// 链接给的起播位置：只有能从指定位置起播的媒体（DASH）且在可跳转范围内时采用；progressive
    /// 总是从头播放，返回 nil。
    public func linkStartPosition(seconds: Int?) -> Double? {
        guard let seconds, case .dash = playback.media, acceptsSeek(toSeconds: seconds) else {
            return nil
        }
        return Double(seconds)
    }
}

/// 充电专属稿件的访问提示，由 `PlayableVideo.accessNotice` 从详情权益与播放媒体推出。
///
/// `upowerPreview`：详情声明可试看，且拿到的 progressive 媒体短于分 P 全长，附带试看与完整时长；
/// `upowerExclusive`：充电专属稿件的其余情形（例如已能完整播放）。
public enum PlaybackAccessNotice: Sendable, Equatable {
    case upowerExclusive
    case upowerPreview(
        previewDurationSeconds: Int,
        fullDurationSeconds: Int
    )
}
