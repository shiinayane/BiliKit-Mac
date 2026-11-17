/// 决定何时提示「进入了第几章」：播放落定在与上次提示不同的一章时提示一次。
///
/// 不论怎么到的那一章（顺着播放跨过边界、点章节卡片或菜单、拖进度条、播完重播），都只经这里判断，提示只有这一个来源。
/// 规则：
/// - 顺着播放前进（同一 `discontinuityGeneration`、位置小步前进）跨进另一章，立刻提示。
/// - 任何跳变（seek、拖动的每一步、从暂停恢复时系统报的原地跳变，或位置倒退、大步前进）之后先不判断，等同一代里
///   连续播放满 `settleSeconds` 再与上次提示的那章比较：拖动途中一路跨过的章节不提示，只提示最后停下的那一章；
///   暂停中 seek 的，恢复播放落定后才提示。
/// - 第一次落定只记下当时所在的章节、不提示：打开视频或从续播位置开播时不弹提示。
///
/// 不用计时器，只按媒体时间判断（见 docs/ARCHITECTURE.md「媒体时间轴」）。跳变与周期快照到达的先后不固定：拖动后
/// 新位置的周期快照可能先于推进代次的跳变通知到达，所以不能只看代次，位置的大步移动同样按跳变处理。
/// 换 item（load intent 变化）或换章节列表时由 owner 换一个新值，不复用旧的状态。
struct VideoChapterAnnouncementGate {
    /// 相邻两个快照之间仍算顺着播放的最大前进量（媒体秒）。
    ///
    /// 播放中每媒体秒约 30 个快照（`PlaybackTimelineSnapshot.periodicSnapshotsPerMediaSecond`），正常一步远小于它；
    /// 留到一秒是给主线程偶尔卡住后的追赶。调小会把卡顿后的追赶当成跳变、晚半秒才提示；调大会把一秒内的小幅 seek
    /// 当成顺着播放、不等落定就提示。
    static let maximumContinuousStepSeconds = 1.0
    /// 跳变之后要连续播放多久（媒体秒）才算落定。
    ///
    /// 拖动进度条时每一步都推进代次，两步之间远不到半秒，拖动途中不会落定。调小可能在拖动停顿时提前提示中途的
    /// 章节；调大会让点章节后的提示来得更晚。
    static let settleSeconds = 0.5

    private var lastPosition: Double?
    private var lastGeneration: UInt64?
    /// 最近一次跳变后的位置；落定后为 nil。
    private var settleOrigin: Double?
    private var hasBaseline = false
    /// 上次提示（或第一次落定时记下）的章节下标；在第一章之前为 nil。
    private var shownIndex: Int?

    /// 消费一个属于本列表所在 item 的快照，返回此刻要提示的章节下标；不提示时为 nil。
    mutating func consume(
        positionSeconds: Double,
        discontinuityGeneration: UInt64,
        isPlaying: Bool,
        chapterIndex: Int?
    ) -> Int? {
        let isContinuous: Bool
        if let lastPosition, lastGeneration == discontinuityGeneration {
            let step = positionSeconds - lastPosition
            isContinuous = step >= 0 && step <= Self.maximumContinuousStepSeconds
        } else {
            isContinuous = false
        }
        lastPosition = positionSeconds
        lastGeneration = discontinuityGeneration
        if !isContinuous {
            settleOrigin = positionSeconds
        }
        guard isPlaying else { return nil }
        if let settleOrigin {
            guard positionSeconds - settleOrigin >= Self.settleSeconds else { return nil }
            self.settleOrigin = nil
        }
        guard hasBaseline else {
            hasBaseline = true
            shownIndex = chapterIndex
            return nil
        }
        guard chapterIndex != shownIndex else { return nil }
        shownIndex = chapterIndex
        return chapterIndex
    }
}
