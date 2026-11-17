import BiliModels
import Foundation

/// 「刚才看过」里的一项：离开时的分 P 与秒数（可直接重建的选择意图），加上画卡片要的标题、封面、UP 主与时长。
///
/// 只在窗口内存里，由 App 层的导航协调器持有列表；本类型不拥有任何生命周期。
public struct RecentlyWatchedVideo: Identifiable, Equatable, Sendable {
    public let resumePoint: PlaybackSelectionIntent
    public let title: String
    public let coverURL: URL?
    public let ownerName: String
    public let durationSeconds: Int
    /// 离开时已到分 P 结尾（多半是播完自动连播走的）；`resumePoint` 此时不带秒数，点开从头播。
    public let isFinished: Bool

    public var id: String { resumePoint.bvid }

    /// 把离开的视频写成一项；`resumePoint` 与详情不是同一个 BVID 时（呈现的已不是它）为 nil。
    ///
    /// 离分 P 结尾不到 `finishedTailSeconds` 的按看完处理：从那里续播只会马上结束。
    public init?(detail: VideoDetail, resumePoint: PlaybackSelectionIntent) {
        guard detail.bvid == resumePoint.bvid else { return nil }
        let pageDuration =
            detail.pages.first(where: { $0.cid == resumePoint.preferredCID })?.durationSeconds
            ?? detail.durationSeconds
        let isFinished =
            resumePoint.preferredStartSeconds.map {
                $0 >= pageDuration - Self.finishedTailSeconds
            } ?? false
        self.init(
            detail: detail,
            resumePoint: isFinished
                ? PlaybackSelectionIntent(
                    bvid: resumePoint.bvid,
                    preferredCID: resumePoint.preferredCID
                )
                : resumePoint,
            isFinished: isFinished
        )
    }

    /// 正在播放的视频排在「刚才看过」最前的那一项；不带位置，卡片画正在播放外观。
    init(nowPlaying detail: VideoDetail) {
        self.init(
            detail: detail,
            resumePoint: PlaybackSelectionIntent(bvid: detail.bvid),
            isFinished: false
        )
    }

    private init(detail: VideoDetail, resumePoint: PlaybackSelectionIntent, isFinished: Bool) {
        self.resumePoint = resumePoint
        title = detail.title
        coverURL = detail.coverURL
        ownerName = detail.owner.name
        durationSeconds = detail.durationSeconds
        self.isFinished = isFinished
    }

    /// 离分 P 结尾不到这么多秒就算看完。
    ///
    /// 片尾字幕、播完停在最后一帧都落在结尾这几秒里；调大会把没看完的也当成看完、从头播。
    static let finishedTailSeconds = 10
}
