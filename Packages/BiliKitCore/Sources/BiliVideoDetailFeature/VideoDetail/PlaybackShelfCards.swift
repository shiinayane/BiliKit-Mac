import BiliModels
import BiliUI
import BiliVideoCollectionUI
import Foundation

/// 「刚才看过」的卡片：第一张是正在播放的视频，其后最近离开的在前。
///
/// 正在播放的那张画正在播放外观、点了不动作；页脚是 UP 主与离开时的位置。卡片 ID 就是 BVID（列表按 BVID 去重）。
struct RecentlyWatchedShelfCards {
    let entries: [RecentlyWatchedVideo]
    let presentations: [NativeVideoCardPresentation]

    init(entries: [RecentlyWatchedVideo]) {
        self.entries = entries
        let nowPlaying = VideoDetailFeatureStrings.localized("正在播放")
        presentations = entries.enumerated().map { index, entry in
            let isNowPlaying = index == 0
            let positionText =
                entry.isFinished
                ? VideoDetailFeatureStrings.localized("已看完")
                : entry.resumePoint.preferredStartSeconds.map {
                    String(
                        format: VideoDetailFeatureStrings.localized("看到 %@"),
                        VideoDurationFormatting.string(seconds: $0)
                    )
                }
            return NativeVideoCardPresentation(
                id: entry.id,
                title: entry.title,
                coverURL: BiliImageThumbnail.url(entry.coverURL, size: .videoCover),
                avatarURL: nil,
                showsAvatar: false,
                coverTrailingText: VideoDurationFormatting.string(seconds: entry.durationSeconds),
                footerLeadingText: entry.ownerName,
                footerTrailingText: positionText,
                accessibilityLabel: ListFormatter.localizedString(
                    byJoining: [entry.title, entry.ownerName]
                        + (isNowPlaying ? [nowPlaying] : (positionText.map { [$0] } ?? []))
                ),
                accessibilityHelp: isNowPlaying
                    ? nil : VideoDetailFeatureStrings.localized("从离开的位置继续播放"),
                nowPlayingText: isNowPlaying ? nowPlaying : nil
            )
        }
    }

    /// 点了哪张卡片要重建的选择意图；正在播放的那张返回 nil。
    func resumePoint(forCardID cardID: String) -> PlaybackSelectionIntent? {
        entries.dropFirst().first(where: { $0.id == cardID })?.resumePoint
    }
}

/// 合集一个分区的卡片：卡片 ID 用分区内序号（选集身份不是字符串），当前一集是锚点并画正在播放外观。
struct CollectionShelfCards {
    let section: PlaybackEpisodeSectionPresentation
    let presentations: [NativeVideoCardPresentation]
    let anchorID: String?

    init(
        section: PlaybackEpisodeSectionPresentation,
        selectedEpisodeID: VideoCollectionEpisodeIdentity?
    ) {
        self.section = section
        var anchorID: String?
        let nowPlaying = VideoDetailFeatureStrings.localized("正在播放")
        presentations = section.episodes.enumerated().map { index, episode in
            let cardID = Self.cardID(index)
            let isCurrent = episode.id == selectedEpisodeID
            if isCurrent { anchorID = cardID }
            let number = String(
                format: VideoDetailFeatureStrings.localized("第 %lld 集"),
                Int64(index + 1)
            )
            return NativeVideoCardPresentation(
                id: cardID,
                title: episode.title,
                coverURL: BiliImageThumbnail.url(episode.coverURL, size: .videoCover),
                avatarURL: nil,
                showsAvatar: false,
                coverTrailingText: episode.durationSeconds.map {
                    VideoDurationFormatting.string(seconds: $0)
                },
                footerLeadingText: number,
                accessibilityLabel: ListFormatter.localizedString(
                    byJoining: [number, episode.title] + (isCurrent ? [nowPlaying] : [])
                ),
                accessibilityHelp: VideoDetailFeatureStrings.localized("播放这一集"),
                availability: episode.isEnabled
                    ? .available
                    : .unavailable(badge: VideoDetailFeatureStrings.localized("无法播放")),
                nowPlayingText: isCurrent ? nowPlaying : nil
            )
        }
        self.anchorID = anchorID
    }

    /// 换分区或换合集时整体替换横排内容并重新定位；同一分区里换集只移动锚点。
    var contentIdentity: String {
        let id = section.id
        return "collection-\(id.seasonID)-\(id.sectionID)-\(id.occurrenceOrdinal ?? -1)"
    }

    func episodeID(forCardID cardID: String) -> VideoCollectionEpisodeIdentity? {
        guard
            cardID.hasPrefix(Self.cardPrefix),
            let index = Int(cardID.dropFirst(Self.cardPrefix.count)),
            section.episodes.indices.contains(index)
        else { return nil }
        return section.episodes[index].id
    }

    private static let cardPrefix = "episode-"

    private static func cardID(_ index: Int) -> String {
        "\(cardPrefix)\(index)"
    }
}
