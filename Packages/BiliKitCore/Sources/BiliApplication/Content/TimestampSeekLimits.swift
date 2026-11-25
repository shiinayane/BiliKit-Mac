import BiliModels

/// 评论与简介里的时间戳能不能跳：各分 P 的可跳转上限（不含），由 `PlayableVideo.timestampSeekLimits` 产生，
/// 播放侧栏据此决定时间戳显示为链接还是普通文字。
///
/// 正在播的分 P 用 `PlayableVideo.seekableDurationSeconds`（充电试看时是试看时长）；其他分 P 还没取播放地址，
/// 用分 P 全长，切过去后的起播位置由 `PlayableVideo.linkStartPosition` 再按真实上限复核。序号不在视频里或
/// 时长未知的分 P 没有上限，时间戳按普通文字显示。侧栏比较这个值决定是否重配时间戳文字，所以正在播的分 P
/// 序号也在值里：换到等长的分 P 时同样要重配。
public struct TimestampSeekLimits: Sendable, Equatable {
    private let selectedPageNumber: Int
    private let limitsByPageNumber: [Int: Int]

    /// `limitsByPageNumber` 以分 P 序号（从 1 开始）为键，只收有上限的分 P。
    public init(selectedPageNumber: Int, limitsByPageNumber: [Int: Int]) {
        self.selectedPageNumber = selectedPageNumber
        self.limitsByPageNumber = limitsByPageNumber
    }

    /// 跳到 `page` 分 P（nil 指正在播的分 P）的 `seconds` 秒是否可行。
    public func accepts(seconds: Int, page: Int?) -> Bool {
        PlayableVideo.accepts(
            seconds: seconds,
            seekableDurationSeconds: limitsByPageNumber[page ?? selectedPageNumber]
        )
    }
}

extension PlayableVideo {
    public var timestampSeekLimits: TimestampSeekLimits {
        var limits: [Int: Int] = [:]
        for page in context.pages where page.durationSeconds > 0 {
            limits[page.index] = limits[page.index] ?? page.durationSeconds
        }
        limits[context.selectedPage.index] = seekableDurationSeconds
        return TimestampSeekLimits(
            selectedPageNumber: context.selectedPage.index,
            limitsByPageNumber: limits
        )
    }
}
