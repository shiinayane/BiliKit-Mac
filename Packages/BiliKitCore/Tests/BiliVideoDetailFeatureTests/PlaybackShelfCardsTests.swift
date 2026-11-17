import BiliModels
import BiliUI
import BiliVideoCollectionUI
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// 播放页横排的卡片：合集里当前一集是停靠锚点并画正在播放外观、不可播放的集不能点、封面请求缩略图、卡片能对回选集；
/// 「刚才看过」第一张是正在播放的视频（点了不动作），其余按离开的位置续播，封面同样请求缩略图。
struct PlaybackShelfCardsTests {
    @Test
    func collectionCardsMarkAndAnchorTheCurrentEpisodeAndMapBackToEpisodes() {
        let sectionID = VideoCollectionSectionIdentity(seasonID: 1, sectionID: 2)
        let episodes = (0..<3).map { index in
            PlaybackEpisodeOption(
                id: VideoCollectionEpisodeIdentity(
                    seasonID: 1,
                    sectionID: 2,
                    episodeID: Int64(index)
                ),
                sectionID: sectionID,
                title: "第 \(index + 1) 集",
                bvid: "BV\(index)",
                preferredCID: nil,
                coverURL: URL(string: "https://i0.hdslb.com/bfs/archive/\(index).jpg"),
                durationSeconds: 60,
                isEnabled: index != 2
            )
        }
        let cards = CollectionShelfCards(
            section: PlaybackEpisodeSectionPresentation(
                id: sectionID,
                title: "正片",
                episodes: episodes
            ),
            selectedEpisodeID: episodes[1].id
        )

        #expect(cards.presentations.map { $0.nowPlayingText != nil } == [false, true, false])
        #expect(cards.anchorID == cards.presentations[1].id)
        #expect(cards.presentations.map(\.isActivatable) == [true, true, false])
        // 封面与其他视频卡片同一条规则：请求 CDN 按卡片尺寸裁好的缩略图，不请求原图。
        #expect(
            cards.presentations.map(\.coverURL)
                == episodes.map { BiliImageThumbnail.url($0.coverURL, size: .videoCover) }
        )
        #expect(cards.presentations.map(\.coverURL) != episodes.map(\.coverURL))
        #expect(
            cards.presentations.map { cards.episodeID(forCardID: $0.id) } == episodes.map(\.id)
        )
    }

    @Test
    func recentCardsPutTheVideoNowPlayingFirstAndResumeTheOthers() throws {
        let cover = URL(string: "https://i0.hdslb.com/bfs/archive/now.jpg")
        let nowPlaying = RecentlyWatchedVideo(
            nowPlaying: makeVideoDetail(bvid: "BVNow", coverURL: cover, pages: [makeTestPage(1)])
        )
        let page = VideoPage(cid: 1_001, index: 1, title: "P1", durationSeconds: 600)
        let leftPoint = PlaybackSelectionIntent(
            bvid: "BVLeft",
            preferredCID: page.cid,
            preferredStartSeconds: 42
        )
        let left = try #require(
            RecentlyWatchedVideo(
                detail: makeVideoDetail(bvid: "BVLeft", pages: [page]),
                resumePoint: leftPoint
            )
        )
        let cards = RecentlyWatchedShelfCards(entries: [nowPlaying, left])

        #expect(cards.presentations.map { $0.nowPlayingText != nil } == [true, false])
        #expect(cards.resumePoint(forCardID: "BVNow") == nil)
        #expect(cards.resumePoint(forCardID: "BVLeft") == leftPoint)
        // 与其他视频卡片同一条规则：封面请求 CDN 缩略图，不请求原图。
        #expect(cards.presentations[0].coverURL == BiliImageThumbnail.url(cover, size: .videoCover))
        #expect(cards.presentations[0].coverURL != cover)
    }
}
