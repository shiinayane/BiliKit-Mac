import BiliApplication
import BiliModels
import Testing

@testable import BiliDanmaku

/// 重复弹幕合并的契约：同一位置、归一化后同文、组首后 4 秒内的弹幕并成组首一条，记下后续到达时间，组首的正文、
/// 时间与样式不变；不跨分段、不跨组累计；UP 主弹幕不参与合并；只靠并入才带上高赞时换用自己的 ID；开关关闭时布局
/// 不变。
@Suite
struct DanmakuDuplicateMergerTests {
    @Test(
        arguments: [
            ("哈哈哈哈哈", "哈哈哈"),
            ("2333333", "2333"),
            ("６６６！！！", "666"),
            ("Ｌｉｋｅ  THIS～", "likethis"),
            ("好耶。", "好耶"),
            ("？？？？", "???"),
            ("👨‍👩‍👧👨‍👩‍👧👨‍👩‍👧👨‍👩‍👧", "👨‍👩‍👧👨‍👩‍👧👨‍👩‍👧"),
            ("ｶﾀｶﾅ", "ｶﾀｶﾅ")
        ]
    )
    func comparisonKeyFoldsOnlyCosmeticDifferences(text: String, expected: String) {
        #expect(DanmakuDuplicateMerger.comparisonKey(for: text) == expected)
    }

    /// 全是标点的弹幕按标点本身比较，不会因去掉句尾标点变成空串而与别的标点弹幕合并。
    @Test
    func punctuationOnlyTextsStayDistinct() {
        let question = DanmakuDuplicateMerger.comparisonKey(for: "？？？")
        let exclamation = DanmakuDuplicateMerger.comparisonKey(for: "！！！")
        #expect(!question.isEmpty)
        #expect(question != exclamation)
    }

    @Test
    func duplicatesWithinTheWindowBecomeOneCountedEvent() {
        let window = DanmakuDuplicateMerger.windowSeconds
        let events = [
            event("a", time: 10, text: "好耶"),
            event("b", time: 11, text: "别的"),
            event("c", time: 12, text: "好耶！", isHighLike: true),
            event("d", time: 10 + window, text: "好耶～"),
            event("e", time: 10 + window + 0.01, text: "好耶")
        ]

        let merged = DanmakuDuplicateMerger.merged(events)

        #expect(merged.map(\.event.text) == ["好耶", "别的", "好耶"])
        #expect(merged.map(\.event.timeSeconds) == [10, 11, 10 + window + 0.01])
        #expect(merged.map(\.laterArrivalTimes) == [[12, 10 + window], [], []])
        #expect(merged[0].event.id == "a" + DanmakuDuplicateMerger.promotedHighLikeIDSuffix)
        #expect(merged[0].event.isHighLike)
        #expect(merged[1].event == events[1])
        #expect(merged[2].event == events[4])
    }

    @Test
    func differentPositionsAreNotMerged() {
        let events = [
            event("a", time: 1, text: "好耶", mode: .scrolling),
            event("b", time: 1.5, text: "好耶", mode: .top),
            event("c", time: 2, text: "好耶", mode: .bottom)
        ]

        #expect(
            DanmakuDuplicateMerger.merged(events)
                == events.map { DanmakuDuplicateGroup(event: $0, laterArrivalTimes: []) }
        )
    }

    /// UP 主弹幕既不并入别人的组，也不吸收后来的同文弹幕。
    @Test
    func uploaderDanmakuIsNeverMerged() {
        let events = [
            event("fan", time: 1, text: "好耶"),
            event("up", time: 1.5, text: "好耶", isUploader: true),
            event("fan-2", time: 2, text: "好耶")
        ]

        let groups = DanmakuDuplicateMerger.merged(events)

        #expect(groups.map(\.event.id) == ["fan", "up"])
        #expect(groups.map(\.laterArrivalTimes) == [[2], []])
    }

    /// 组首后同一组只吸收窗口内的弹幕；窗口外的同文另起一组，从 1 开始计，不接着上一组累计。
    @Test
    func laterGroupsStartCountingAgain() {
        let window = DanmakuDuplicateMerger.windowSeconds
        let events = (0..<6).map { offset in
            event("e\(offset)", time: Double(offset) * window * 0.6, text: "草")
        }

        #expect(DanmakuDuplicateMerger.merged(events).map(\.laterArrivalTimes.count) == [1, 1, 1])
    }

    /// 开关打开时同一段内合并、不跨分段，整条宽度按最终条数预留胶囊；关闭时与原来的布局一致。
    @Test
    func plannerMergesWithinASegmentOnlyWhenEnabled() throws {
        let boundary = DanmakuSegmentCache.segmentDurationSeconds
        let segments: [Int: [DanmakuEvent]] = [
            1: [
                event("a", time: boundary - 2, text: "好耶"),
                event("b", time: boundary - 1, text: "好耶")
            ],
            2: [event("c", time: boundary + 0.5, text: "好耶")]
        ]

        let merged = try #require(layouts(segments, mergesDuplicates: true))
        let plain = try #require(layouts(segments, mergesDuplicates: false))

        let request = try #require(merged[1]?.placements.first?.request)
        let badge = try #require(request.countBadge)
        #expect(merged[1]?.placements.count == 1)
        #expect(request.event.text == "好耶")
        #expect(badge.laterArrivalTimes == [boundary - 1])
        let textWidth = try #require(fixtureMetrics(request.event)?.width)
        #expect(request.width == textWidth + badge.reservedWidth)
        #expect(abs(request.textWidth - textWidth) < 1e-9)
        #expect(merged[2]?.placements.map(\.request.countBadge) == [nil])
        #expect(plain[1]?.placements.map(\.request.event.id) == ["a", "b"])
        #expect(plain[2]?.placements.map(\.request.event.id) == ["c"])
    }

    private func layouts(
        _ segments: [Int: [DanmakuEvent]],
        mergesDuplicates: Bool
    ) -> [Int: DanmakuSegmentLayout]? {
        DanmakuLayoutPlanner.layouts(
            for: segments,
            reusing: [:],
            parameters: DanmakuLayoutParameters(
                configuration: BiliDanmakuTests.configuration(),
                speedLevel: .default,
                backingScale: 2,
                filter: DanmakuFilter(mergesDuplicates: mergesDuplicates)
            ),
            measure: fixtureMetrics
        )
    }

    private func event(
        _ id: String,
        time: Double,
        text: String,
        mode: DanmakuPresentationMode = .scrolling,
        isHighLike: Bool = false,
        isUploader: Bool = false
    ) -> DanmakuEvent {
        DanmakuEvent(
            id: id,
            timeSeconds: time,
            mode: mode,
            text: text,
            fontSize: 25,
            colorRGB: 0xFFFFFF,
            colorStyle: .solid,
            weight: 1,
            isHighLike: isHighLike,
            isUploader: isUploader
        )
    }
}
