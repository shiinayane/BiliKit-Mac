import Testing

@testable import BiliVideoDetailFeature

/// 侧栏加载提示的延迟露出：加载开始时先隐藏，延迟后仍在加载才露出；露出前结束则始终不露出，结束时立即隐藏。
@Suite(.serialized, .timeLimit(.minutes(1)))
struct NativeLoadingRevealTests {
    @Test
    @MainActor
    func revealsOnlyAfterTheDelayAndHidesWhenLoadingEnds() async {
        let recorder = RevealRecorder()
        let reveal = NativeLoadingReveal { recorder.record($0) }
        await withCheckedContinuation { revealed in
            recorder.onReveal = { revealed.resume() }
            reveal.setLoading(true)
            #expect(recorder.applied == [false])
        }
        #expect(recorder.applied == [false, true])

        reveal.setLoading(false)
        #expect(recorder.applied == [false, true, false])
    }

    @Test
    @MainActor
    func loadingThatEndsBeforeTheDelayIsNeverShown() async {
        let cancelledRecorder = RevealRecorder()
        let cancelled = NativeLoadingReveal { cancelledRecorder.record($0) }
        cancelled.setLoading(true)
        cancelled.setLoading(false)

        // 晚开始的同一延迟露出时，先开始的那次早已到期；它此时仍未露出，就说明取消生效。
        let laterRecorder = RevealRecorder()
        let later = NativeLoadingReveal { laterRecorder.record($0) }
        await withCheckedContinuation { revealed in
            laterRecorder.onReveal = { revealed.resume() }
            later.setLoading(true)
        }
        #expect(cancelledRecorder.applied == [false, false])
    }
}

/// 记下每次应用的显隐，露出时通知等待方。
@MainActor
private final class RevealRecorder {
    var applied: [Bool] = []
    var onReveal: (() -> Void)?

    func record(_ isRevealed: Bool) {
        applied.append(isRevealed)
        if isRevealed { onReveal?() }
    }
}
