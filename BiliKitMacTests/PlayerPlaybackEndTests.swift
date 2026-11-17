import BiliApplication
import Foundation
import Testing

@testable import BiliKit

/// 「播放结束后」：偏好只认已知值、缺失或损坏时回退不循环；播完的处理只在同一 item 刚进入结束时触发一次，
/// 订阅当下已经结束、重复发布结束都不触发，换了 item 的结束照常触发；停止观察后不再处理。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct PlayerPlaybackEndTests {
    @Test
    func behaviorPreferenceFallsBackToStop() {
        withIsolatedDefaults { defaults in
            let store = PlaybackEndBehaviorStore(defaults: defaults)
            #expect(store.behavior == .stop)
            store.behavior = .repeatOne
            #expect(PlaybackEndBehaviorStore(defaults: defaults).behavior == .repeatOne)
            defaults.set("loop-forever", forKey: "player.endBehavior")
            #expect(store.behavior == .stop)
            defaults.set(1, forKey: "player.endBehavior")
            #expect(store.behavior == .stop)
        }
    }

    @Test
    func handlingFiresOnceWhenTheItemEntersTheEnd() async {
        let timeline = ManualTimeline()
        let handled = HandledEnds()
        let observer = PlayerPlaybackEndObserver()
        let first = PlaybackLoadIntent()
        timeline.current = snapshot(first, .ended)
        observer.start(
            PlayerPlaybackEndActions(
                observeTimeline: timeline.observeTimeline,
                handleEnded: { snapshot, _ in
                    handled.snapshots.append(snapshot)
                    return .endBehavior(.repeatOne)
                }
            ),
            present: { handled.feedback.append($0) }
        )

        timeline.send(snapshot(first, .ended))
        timeline.send(snapshot(first, .playing))
        timeline.send(snapshot(first, .ended))
        await waitForObservedState { handled.feedback.count == 1 }
        timeline.send(snapshot(first, .ended))
        let second = PlaybackLoadIntent()
        timeline.send(snapshot(second, .ended))
        await waitForObservedState { handled.feedback.count == 2 }
        #expect(handled.snapshots.map(\.loadIntent) == [first, second])

        observer.stop()
        #expect(timeline.observers.isEmpty)
    }

    private func snapshot(
        _ intent: PlaybackLoadIntent,
        _ state: PlaybackTimelineState
    ) -> PlaybackTimelineSnapshot {
        PlaybackTimelineSnapshot(
            identity: PlaybackItemIdentity(bvid: "BV1EndFixture", cid: 1),
            positionSeconds: 0,
            durationSeconds: 60,
            rate: 0,
            state: state,
            discontinuityGeneration: 0,
            loadIntent: intent
        )
    }
}

@MainActor
@Observable
private final class HandledEnds {
    var snapshots: [PlaybackTimelineSnapshot] = []
    var feedback: [PlayerActionFeedback] = []
}
