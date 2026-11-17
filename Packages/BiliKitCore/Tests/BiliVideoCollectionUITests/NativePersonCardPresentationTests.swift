import BiliUI
import Foundation
import Testing

@testable import BiliVideoCollectionUI

/// 人物卡片（关注页）的头像请求 B 站图片 CDN 的头像缩略图，与视频卡片头像同一条规则，不请求原图：一页约 50 个头像，
/// 原图合计可达数 MB，卡片会逐个慢慢出现。
struct NativePersonCardPresentationTests {
    @Test
    func avatarRequestsTheCardAvatarThumbnail() throws {
        let original = try #require(URL(string: "https://i0.hdslb.com/bfs/face/fixture.jpg"))
        let thumbnail = BiliImageThumbnail.url(original, size: .avatar)

        let card = NativePersonCardPresentation(
            id: "1",
            name: "UP",
            avatarURL: original,
            isVIP: false,
            subtitle: nil
        )

        #expect(thumbnail != original)
        #expect(card.avatarURL == thumbnail)
    }
}
