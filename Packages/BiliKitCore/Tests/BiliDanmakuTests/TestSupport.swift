import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 本 target 唯一的 `DanmakuEvent` 构造：未给出的字段取普通白色滚动弹幕（1 秒、25 号字、文字 `fixture`）。
func danmakuEvent(
    id: String,
    time: Double = 1,
    mode: DanmakuPresentationMode = .scrolling,
    text: String = "fixture",
    fontSize: Double = 25,
    colorRGB: UInt32 = 0xFFFFFF,
    colorStyle: DanmakuColorStyle = .solid,
    weight: Int = 1,
    isHighLike: Bool = false,
    isUploader: Bool = false
) -> DanmakuEvent {
    DanmakuEvent(
        id: id,
        timeSeconds: time,
        mode: mode,
        text: text,
        fontSize: fontSize,
        colorRGB: colorRGB,
        colorStyle: colorStyle,
        weight: weight,
        isHighLike: isHighLike,
        isUploader: isUploader
    )
}

/// 纹理测试共用的弹幕：时间点固定为 1 秒，文字覆盖多种文字系统与 emoji。
func fixtureEvent(
    id: String,
    mode: DanmakuPresentationMode,
    colorRGB: UInt32 = 0xFFFFFF,
    fontSize: Double = 24,
    isHighLike: Bool = false,
    isUploader: Bool = false
) -> DanmakuEvent {
    danmakuEvent(
        id: id,
        mode: mode,
        text: "中文 日本語 한국어 Latin 😀 #",
        fontSize: fontSize,
        colorRGB: colorRGB,
        isHighLike: isHighLike,
        isUploader: isUploader
    )
}

/// 测试用的测量：宽度取文字里的数字（没有时按字数 × 20），高度固定 24，不经 Core Text。
func fixtureMetrics(_ event: DanmakuEvent) -> DanmakuTextMetrics? {
    let width = Double(event.text) ?? Double(event.text.count * 20)
    return DanmakuTextMetrics(width: width, height: 24)
}

/// 测量宽度为 `width` 的滚动弹幕：`fixtureMetrics` 把数字文字读成宽度。
func scrollingEvent(id: String, time: Double, width: Int) -> DanmakuEvent {
    danmakuEvent(id: id, time: time, text: String(width))
}

/// 测试用的确定性随机序列：同一种子总得到同一串 31 位整数（线性同余，取高位）。
///
/// 不遵循 `RandomNumberGenerator`：标准库的 `random(in:using:)` 要求均匀的 64 位输出。
struct SeededSequence {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 33
    }

    /// [0, 1) 里的一个数。
    mutating func unit() -> Double {
        Double(next()) / Double(1 << 31)
    }
}

/// 落在第 `segment` 段内、三种模式混合的高密度弹幕；同一 `seed` 总得到同一组。
func denseEvents(segment: Int, count: Int, seed: UInt64) -> [DanmakuEvent] {
    var sequence = SeededSequence(seed: seed)
    func next() -> UInt64 {
        sequence.next()
    }
    let start = Double(segment - 1) * DanmakuSegmentCache.segmentDurationSeconds
    return (0..<count).map { offset in
        let time = start + Double(next() % 3_600) / 10
        let mode: DanmakuPresentationMode =
            switch next() % 5 {
            case 0: .top
            case 1: .bottom
            default: .scrolling
            }
        return danmakuEvent(
            id: "s\(segment)-\(offset)",
            time: time,
            mode: mode,
            text: String(60 + Int(next() % 400))
        )
    }
}

/// 同一槽位上没有两条弹幕在同一时刻重叠：滚动弹幕前后保持最小间距直到前一条走完，顶部底部不同时占用。
func expectNoOverlap(
    _ placements: [DanmakuLanePlacement],
    configuration: DanmakuLaneConfiguration,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    func rightEdge(_ placement: DanmakuLanePlacement, at time: Double) -> Double {
        let request = placement.request
        let speed = (placement.planningWidth + request.width) / request.durationSeconds
        return placement.planningWidth + request.width
            - speed * (time - placement.admittedAtSeconds)
    }
    func leftEdge(_ placement: DanmakuLanePlacement, at time: Double) -> Double {
        rightEdge(placement, at: time) - placement.request.width
    }
    func lanes(_ placement: DanmakuLanePlacement) -> Range<Int> {
        let span = Int(
            (placement.request.height / DanmakuLaneConfiguration.laneHeight).rounded(.up)
        )
        return placement.laneIndex..<(placement.laneIndex + span)
    }
    let ordered = placements.sorted { $0.admittedAtSeconds < $1.admittedAtSeconds }
    for (offset, later) in ordered.enumerated() {
        for earlier in ordered[..<offset]
        where earlier.request.event.mode == later.request.event.mode
            && earlier.overlapDepth == later.overlapDepth
            && lanes(earlier).overlaps(lanes(later))
            && earlier.expiresAtSeconds > later.admittedAtSeconds
        {
            switch later.request.event.mode {
            case .top, .bottom:
                Issue.record(
                    "\(earlier.request.event.id) 与 \(later.request.event.id) 同时占用同一槽位",
                    sourceLocation: sourceLocation
                )
            case .scrolling:
                // 前一条走完之前，两条的间距始终不小于最小间距；匀速运动只需比较两个端点。
                let end = earlier.expiresAtSeconds
                let start = later.admittedAtSeconds
                let gapAtStart = leftEdge(later, at: start) - rightEdge(earlier, at: start)
                let gapAtEnd = leftEdge(later, at: end) - rightEdge(earlier, at: end)
                if min(gapAtStart, gapAtEnd) < configuration.minimumHorizontalGap - 1e-6 {
                    Issue.record(
                        "\(later.request.event.id) 追上了 \(earlier.request.event.id)",
                        sourceLocation: sourceLocation
                    )
                }
            }
        }
    }
}
