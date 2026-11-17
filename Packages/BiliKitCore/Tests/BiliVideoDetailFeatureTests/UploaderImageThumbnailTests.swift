import BiliModels
import BiliUI
import BiliVideoCollectionUI
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// 播放侧栏 UP 主名片、整页空间页与空间预览的头部头像，以及空间投稿与相关推荐的封面，请求 B 站图片 CDN 按显示尺寸裁好的
/// 缩略图，与视频卡片同一条规则，不请求原图（原图头像可达 1 MB 以上，空间页与关注页会逐个慢慢出现）；整页空间页头部的
/// 大头像按大尺寸请求并按同一尺寸解码，不在 2x 屏上发软。
struct UploaderImageThumbnailTests {
    private static let avatar = URL(string: "https://i0.hdslb.com/bfs/face/fixture.jpg")!
    private static let cover = URL(string: "https://i0.hdslb.com/bfs/archive/fixture.jpg")!

    @Test
    func uploaderAvatarsAndSpaceAndRelatedCoversRequestThumbnails() {
        let avatar = BiliImageThumbnail.url(Self.avatar, size: .avatar)
        let gridCover = BiliImageThumbnail.url(Self.cover, size: .videoCover)
        let rowCover = BiliImageThumbnail.url(
            Self.cover,
            size: .cover(pointWidth: UploaderSpaceGeometry.coverWidth)
        )
        #expect(avatar != Self.avatar)
        #expect(gridCover != Self.cover)
        #expect(rowCover != Self.cover)

        let owner = VideoOwner(id: 1, name: "UP", avatarURL: Self.avatar)
        // 播放侧栏名片按普通头像请求与解码；整页空间页头部显示得更大，请求与解码都换成大头像，两者成对。
        let sidebar = VideoUploaderHeaderContent(owner: owner)
        #expect(sidebar.avatarURL == avatar)
        #expect(sidebar.avatarPurpose == .avatar)
        let page = VideoUploaderHeaderContent(owner: owner, avatarSize: .large)
        let largeAvatar = BiliImageThumbnail.url(Self.avatar, size: .largeAvatar)
        #expect(largeAvatar != Self.avatar)
        #expect(page.avatarURL == largeAvatar)
        #expect(page.avatarPurpose == .largeAvatar)
        let spaceHeader = UploaderSpaceHeaderContent(
            name: "UP",
            avatarURL: Self.avatar,
            totalCount: nil,
            order: .newest,
            isSearching: false
        )
        #expect(spaceHeader.avatarURL == avatar)

        let video = UploaderVideo(
            bvid: "BV1Fixture",
            title: "标题",
            coverURL: Self.cover,
            durationSeconds: nil,
            viewCount: nil,
            danmakuCount: nil,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            isCollaboration: false
        )
        #expect(UploaderSpacePageCards.presentation(video).coverURL == gridCover)
        #expect(UploaderVideoRowPresentation(video: video).coverURL == rowCover)

        let related = RelatedVideo(
            bvid: "BV1Related",
            title: "标题",
            coverURL: Self.cover,
            ownerName: "UP",
            viewCount: 1,
            danmakuCount: 1,
            durationSeconds: nil
        )
        #expect(RelatedVideoCardPresentation(video: related).coverURL == gridCover)
    }
}
