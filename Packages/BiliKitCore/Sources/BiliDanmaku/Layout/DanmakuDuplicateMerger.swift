import BiliModels
import Foundation

/// 合并后的一条弹幕：组首，以及并入它的同文弹幕的到达时间。
struct DanmakuDuplicateGroup: Sendable, Equatable {
    /// 组首；组里任何一条是高赞时带高赞标记，其余字段都是组首自己的。
    let event: DanmakuEvent
    /// 组内第 2、3…条的媒体时间，升序；没有同文弹幕时为空。
    let laterArrivalTimes: [Double]
}

/// 重复弹幕合并：同一显示位置、归一化后正文相同、在组首出场后 `windowSeconds` 之内的弹幕并成组首一条。
///
/// 由 `DanmakuLayoutPlanner` 在车道布局前对一个分段调用，输入已过滤、按 (时间, ID) 排好序；纯函数，结果只取决于
/// 输入，所以 seek 与连续播放看到同样的合并。分组不跨分段：分段末尾的组到此为止，下一段的同文弹幕另起一组。
/// 不跨组累计：窗口之后的同文弹幕另起一组。UP 主弹幕不参与合并。条数怎样显示由 `DanmakuCountBadge` 决定，组首的正文不变。
enum DanmakuDuplicateMerger {
    /// 从组首起算的合并时长（媒体秒）。
    ///
    /// 与宽度、窗口都无关，组的成员在排车道前就能确定；取顶部、底部弹幕的显示时长，也接近窄窗口里滚动弹幕的
    /// 可见时长。调长并得更多，但宽窗口里组首还没飞完、同文弹幕被并掉的时间也更长；调短则刷屏时并得少。
    static let windowSeconds = DanmakuMotionPolicy.fixedSeconds
    /// 同一字符连续出现超过这么多次时折叠到这个次数再比较：“哈哈哈哈哈”与“哈哈哈”、“2333333”与“2333”算同一条。
    ///
    /// 调小会把“哈哈”与“哈哈哈”也并到一起，调大则长短不同的刷屏不再合并。
    static let maximumComparedRepetition = 3
    /// 组首本身不是高赞、靠并入的弹幕带上高赞图标时，ID 加这个后缀。
    ///
    /// 纹理与在屏 layer 按 ID 复用，开关合并时同一 ID 若从无图标变成有图标，旧纹理会被拉伸到新宽度；换一个 ID
    /// 就会重新准备纹理。正文不变的合并弹幕沿用组首 ID，开关合并时原位换上新的 placement。
    static let promotedHighLikeIDSuffix = "#highLike"

    /// 合并后的组，顺序仍按组首的 (时间, ID)；没有同文的弹幕自成一组。
    ///
    /// `events` 必须已按 `DanmakuEvent.precedes` 排序。
    static func merged(_ events: [DanmakuEvent]) -> [DanmakuDuplicateGroup] {
        struct GroupKey: Hashable {
            let mode: DanmakuPresentationMode
            let text: String
        }
        struct Group {
            let first: DanmakuEvent
            var laterArrivalTimes: [Double] = []
            var isHighLike: Bool
        }
        var groups: [Group] = []
        var openGroupIndex: [GroupKey: Int] = [:]
        for event in events {
            // UP 主弹幕自成一组，也不吸收别人：并进观众的组会丢掉“UP主”标签，吸收观众的弹幕则把它们画成 UP 主的。
            // 自己刚发的弹幕同样自成一组：并进别人的组就看不出它发出去了。
            guard !event.isUploader, !event.isOwn else {
                groups.append(Group(first: event, isHighLike: event.isHighLike))
                continue
            }
            let key = GroupKey(mode: event.mode, text: comparisonKey(for: event.text))
            if let index = openGroupIndex[key],
                event.timeSeconds - groups[index].first.timeSeconds <= windowSeconds
            {
                groups[index].laterArrivalTimes.append(event.timeSeconds)
                groups[index].isHighLike = groups[index].isHighLike || event.isHighLike
                continue
            }
            openGroupIndex[key] = groups.count
            groups.append(Group(first: event, isHighLike: event.isHighLike))
        }
        return groups.map { group in
            let first = group.first
            guard group.isHighLike != first.isHighLike else {
                return DanmakuDuplicateGroup(
                    event: first,
                    laterArrivalTimes: group.laterArrivalTimes
                )
            }
            return DanmakuDuplicateGroup(
                event: DanmakuEvent(
                    id: first.id + promotedHighLikeIDSuffix,
                    timeSeconds: first.timeSeconds,
                    mode: first.mode,
                    text: first.text,
                    fontSize: first.fontSize,
                    colorRGB: first.colorRGB,
                    colorStyle: first.colorStyle,
                    weight: first.weight,
                    isHighLike: group.isHighLike,
                    isUploader: first.isUploader,
                    isOwn: first.isOwn
                ),
                laterArrivalTimes: group.laterArrivalTimes
            )
        }
    }

    /// 判断两条弹幕是否同文时比较的形式；只用于比较，显示的始终是原文。
    ///
    /// 依次：全角 ASCII 与全角空格转半角（不动片假名等其他全角字符），拉丁字母转小写，去掉空白，去掉句尾标点与
    /// 波浪号，同一字符连续超过 `maximumComparedRepetition` 次时折叠。全是标点的弹幕不去句尾标点，否则“？？？”
    /// 与“！！！”都会变成空串而互相合并。按 `Character` 处理，组合 emoji 不会被拆开。
    static func comparisonKey(for text: String) -> String {
        let folded = String(String.UnicodeScalarView(text.unicodeScalars.map(halfwidthScalar)))
            .lowercased()
            .filter { !$0.isWhitespace }
        var trimmed = Substring(folded)
        while let last = trimmed.last, isTrailingPunctuation(last) {
            trimmed.removeLast()
        }
        let body = trimmed.isEmpty ? Substring(folded) : trimmed
        var result = ""
        var previous: Character?
        var run = 0
        for character in body {
            run = character == previous ? run + 1 : 1
            previous = character
            if run <= maximumComparedRepetition {
                result.append(character)
            }
        }
        return result
    }

    /// 全角 ASCII（U+FF01–U+FF5E）对应到半角，全角空格对应到半角空格；其余原样。
    private static func halfwidthScalar(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        switch scalar.value {
        case 0xFF01...0xFF5E:
            Unicode.Scalar(scalar.value - 0xFEE0) ?? scalar
        case 0x3000:
            " "
        default:
            scalar
        }
    }

    private static func isTrailingPunctuation(_ character: Character) -> Bool {
        character.isPunctuation || character == "~"
    }
}
