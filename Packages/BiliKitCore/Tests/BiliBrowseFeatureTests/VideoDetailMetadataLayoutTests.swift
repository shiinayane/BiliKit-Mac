import Testing

@testable import BiliBrowseFeature

struct VideoDetailMetadataLayoutTests {
    @Test
    func loadedAndPlaceholderContentKeepAccessAfterPublishedDate() {
        let loaded = VideoDetailMetadataContent(
            viewCount: "播放数",
            danmakuCount: "弹幕数",
            publishedAt: "发布日期",
            accessNotice: "充电专属"
        )
        let expectedSlots: [VideoDetailMetadataSlot] = [
            .viewCount,
            .danmakuCount,
            .publishedAt,
            .accessNotice,
        ]

        #expect(loaded.items.map(\.slot) == expectedSlots)
        #expect(
            loaded.items.map(\.text)
                == ["播放数", "弹幕数", "发布日期", "充电专属"]
        )
        #expect(
            VideoDetailMetadataContent.placeholder.items.map(\.slot)
                == expectedSlots
        )
        #expect(
            loaded.items.map { $0.slot.systemImage }
                == ["play", "text.bubble", "calendar", "bolt.heart"]
        )
        #expect(
            VideoDetailMetadataContent.placeholder.items.map {
                $0.slot.systemImage
            } == ["play", "text.bubble", "calendar", "bolt.heart"]
        )
    }

    @Test
    func ordinaryVideoKeepsTheAccessSlotButDoesNotRenderText() {
        let content = VideoDetailMetadataContent(
            viewCount: "1",
            danmakuCount: "2",
            publishedAt: "3",
            accessNotice: nil
        )

        #expect(content.items.map(\.slot) == VideoDetailMetadataSlot.allCases)
        #expect(content.items.last?.text == nil)
    }
}
