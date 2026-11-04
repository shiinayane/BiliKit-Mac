/// 把已验证的唯一播放时间线投影为试看片尾状态。
///
/// 不保存自己的 ended owner；旧 item、seek、replay、replace 或 stop 产生的
/// 任何非当前 ended 快照都会自然清除提示。
public enum PlaybackPreviewEndPolicy {
    /// 这种访问状态下才可能出现试看结束提示（充电试看）；其他视频不必跟随时间线判断。
    public static func canPresentNotice(for accessNotice: PlaybackAccessNotice?) -> Bool {
        guard case .upowerPreview = accessNotice else { return false }
        return true
    }

    public static func shouldPresentNotice(
        accessNotice: PlaybackAccessNotice?,
        expectedIdentity: PlaybackItemIdentity,
        timeline: PlaybackTimelineSnapshot
    ) -> Bool {
        guard canPresentNotice(for: accessNotice) else { return false }
        guard timeline.identity == expectedIdentity else { return false }
        return timeline.state == .ended
    }
}
