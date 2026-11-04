import Testing

@testable import BiliApplication

/// 只有当前 item 的充电试看片段播完时才提示试看结束。
struct PlaybackPreviewEndPolicyTests {
    private let identity = PlaybackItemIdentity(bvid: "BV-preview", cid: 7)

    @Test
    func onlyCurrentPreviewEndedSnapshotPresentsNotice() {
        let access = PlaybackAccessNotice.upowerPreview(
            previewDurationSeconds: 884,
            fullDurationSeconds: 2_255
        )

        #expect(
            PlaybackPreviewEndPolicy.shouldPresentNotice(
                accessNotice: access,
                expectedIdentity: identity,
                timeline: snapshot(identity: identity, state: .ended)
            )
        )
        #expect(
            !PlaybackPreviewEndPolicy.shouldPresentNotice(
                accessNotice: access,
                expectedIdentity: identity,
                timeline: snapshot(identity: identity, state: .playing)
            )
        )
        #expect(
            !PlaybackPreviewEndPolicy.shouldPresentNotice(
                accessNotice: access,
                expectedIdentity: identity,
                timeline: snapshot(
                    identity: PlaybackItemIdentity(bvid: "BV-old", cid: 8),
                    state: .ended
                )
            )
        )
        #expect(
            !PlaybackPreviewEndPolicy.shouldPresentNotice(
                accessNotice: .upowerExclusive,
                expectedIdentity: identity,
                timeline: snapshot(identity: identity, state: .ended)
            )
        )
    }

    /// 只有充电试看需要跟随时间线：其他访问状态（含没有限制）连订阅都不必。
    @Test
    func onlyUpowerPreviewNeedsTheTimeline() {
        #expect(
            PlaybackPreviewEndPolicy.canPresentNotice(
                for: .upowerPreview(previewDurationSeconds: 884, fullDurationSeconds: 2_255)
            )
        )
        #expect(!PlaybackPreviewEndPolicy.canPresentNotice(for: .upowerExclusive))
        #expect(!PlaybackPreviewEndPolicy.canPresentNotice(for: nil))
    }

    private func snapshot(
        identity: PlaybackItemIdentity,
        state: PlaybackTimelineState
    ) -> PlaybackTimelineSnapshot {
        PlaybackTimelineSnapshot(
            identity: identity,
            positionSeconds: state == .ended ? 884 : 100,
            durationSeconds: 884,
            rate: state == .playing ? 1 : 0,
            state: state,
            discontinuityGeneration: state == .ended ? 1 : 2
        )
    }
}
