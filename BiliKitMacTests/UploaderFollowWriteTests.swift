import BiliApplication
import BiliModels
import BiliVideoDetailFeature
import Foundation
import Testing

@testable import BiliKit

/// 播放侧栏的关注按钮与点赞同一条写入链路：先改关注状态、失败放回并在胶囊里说明，写入绑定窗口账户与播放页显示的 UP 主；
/// 关注与点赞、投币、三连不同时在途；关注状态未知、已是目标状态或是自己的视频时不发。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct UploaderFollowWriteTests {
    private static let bvid = "BV17x411w7KC"

    @Test
    func followIsOptimisticAndRollsBackOnFailure() async throws {
        let writes = AccountWriteRepositoryStub(
            outcomes: [.restricted],
            engagement: notFollowing
        )
        let window = try await signedInWindow(process: makeTestProcess(), writes: writes)
        defer { window.close() }
        await presentEngagement(in: window)

        #expect(window.accountWrites.setFollowing(true, bvid: Self.bvid))
        #expect(window.engagementModel.isFollowingUploader == true)
        await waitForObservedState { window.accountWrites.report != nil }

        #expect(window.engagementModel.isFollowingUploader == false)
        let uploader = try #require(UploaderWriteTarget(mid: 1))
        #expect(
            window.accountWrites.report
                == AccountWriteReport(
                    change: .followChanged(uploader, isFollowing: true),
                    failure: .restricted
                )
        )
        #expect(await writes.calls == ["follow 1 7"])
    }

    /// 互动状态的回滚是整份快照：关注在途时点赞不发，点赞在途时关注也不发。
    @Test
    func followAndOtherEngagementWritesAreNeverInFlightTogether() async throws {
        let writes = AccountWriteRepositoryStub(holdsWrites: true, engagement: notFollowing)
        let window = try await signedInWindow(process: makeTestProcess(), writes: writes)
        defer { window.close() }
        await presentEngagement(in: window)

        #expect(window.accountWrites.setFollowing(true, bvid: Self.bvid))
        await writes.waitForCallCount(1)
        #expect(!window.accountWrites.setLiked(true, bvid: Self.bvid))
        #expect(!window.accountWrites.setFollowing(false, bvid: Self.bvid))
        await writes.releaseWrites()
        await waitForObservedState { window.accountWrites.report != nil }
        #expect(window.engagementModel.isFollowingUploader == true)

        let sequence = window.accountWrites.reportSequence
        #expect(window.accountWrites.setLiked(true, bvid: Self.bvid))
        #expect(!window.accountWrites.setFollowing(false, bvid: Self.bvid))
        await waitForObservedState { window.accountWrites.reportSequence != sequence }

        #expect(await writes.calls == ["follow 1 7", "like BV17x411w7KC 7"])
    }

    @Test
    func ownVideoUnknownStateOrAnotherVideoSendsNothing() async throws {
        let unknown = AccountWriteRepositoryStub()
        let window = try await signedInWindow(process: makeTestProcess(), writes: unknown)
        defer { window.close() }
        await presentEngagement(in: window)
        #expect(!window.accountWrites.setFollowing(true, bvid: Self.bvid))

        let writes = AccountWriteRepositoryStub(engagement: notFollowing)
        let own = try await signedInWindow(process: makeTestProcess(), writes: writes)
        defer { own.close() }
        await presentEngagement(in: own, ownerID: 7)
        #expect(!own.engagementModel.showsFollowButton)
        #expect(!own.accountWrites.setFollowing(true, bvid: Self.bvid))

        let other = try await signedInWindow(process: makeTestProcess(), writes: writes)
        defer { other.close() }
        await presentEngagement(in: other)
        #expect(!other.accountWrites.setFollowing(true, bvid: "BV1xx411c7mD"))
        #expect(!other.accountWrites.setFollowing(false, bvid: Self.bvid))

        #expect(await unknown.calls.isEmpty)
        #expect(await writes.calls.isEmpty)
    }

    private var notFollowing: VideoEngagementState {
        VideoEngagementState(
            isLiked: false,
            coinCount: 0,
            isFavorited: false,
            isFollowingUploader: false
        )
    }
}
