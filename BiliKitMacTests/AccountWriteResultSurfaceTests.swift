import BiliApplication
import Testing

@testable import BiliKit

/// 写入结果同一时刻只在一处显示：AVKit 独立全屏时在播放器上（窗口底部的胶囊看不到），否则在窗口底部；结果在两处之间
/// 换位置时不算新结果，读屏不再报一遍。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AccountWriteResultSurfaceTests {
    @Test
    func aFailureDuringFullScreenIsShownOnThePlayer() async throws {
        let writes = AccountWriteRepositoryStub(outcomes: [.restricted])
        let window = try await signedInWindow(process: makeTestProcess(), writes: writes)
        defer { window.close() }
        await presentEngagement(in: window)
        window.accountWrites.resultSurface = .player

        window.accountWrites.setLiked(true, bvid: "BV17x411w7KC")
        await waitForObservedState { window.accountWrites.report != nil }

        #expect(window.accountWrites.playerReport?.failure == .restricted)
        #expect(window.accountWrites.windowReport == nil)
    }

    @Test
    func leavingFullScreenMovesTheShownResultWithoutANewOne() async throws {
        let writes = AccountWriteRepositoryStub(outcomes: [.restricted])
        let window = try await signedInWindow(process: makeTestProcess(), writes: writes)
        defer { window.close() }
        await presentEngagement(in: window)
        window.accountWrites.resultSurface = .player
        window.accountWrites.setLiked(true, bvid: "BV17x411w7KC")
        await waitForObservedState { window.accountWrites.report != nil }
        let sequence = window.accountWrites.reportSequence

        window.accountWrites.resultSurface = .window

        #expect(window.accountWrites.windowReport?.failure == .restricted)
        #expect(window.accountWrites.playerReport == nil)
        #expect(window.accountWrites.reportSequence == sequence)
    }
}
