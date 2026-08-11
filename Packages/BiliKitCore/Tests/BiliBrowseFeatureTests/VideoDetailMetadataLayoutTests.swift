import Testing

@testable import BiliBrowseFeature

struct VideoDetailMetadataLayoutTests {
    @Test
    func loadedAndPlaceholderContentShareThreeMetadataSlots() {
        let loaded = VideoDetailMetadataContent(
            viewCount: "播放数",
            danmakuCount: "弹幕数",
            publishedAt: "发布日期"
        )
        let expectedSlots: [VideoDetailMetadataSlot] = [
            .viewCount,
            .danmakuCount,
            .publishedAt,
        ]

        #expect(loaded.items.map(\.slot) == expectedSlots)
        #expect(
            loaded.items.map(\.text)
                == ["播放数", "弹幕数", "发布日期"]
        )
        #expect(
            VideoDetailMetadataContent.placeholder.items.map(\.slot)
                == expectedSlots
        )
        #expect(
            loaded.items.map { $0.slot.systemImage }
                == ["play", "text.bubble", "calendar"]
        )
        #expect(
            VideoDetailMetadataContent.placeholder.items.map {
                $0.slot.systemImage
            } == ["play", "text.bubble", "calendar"]
        )
    }
}
