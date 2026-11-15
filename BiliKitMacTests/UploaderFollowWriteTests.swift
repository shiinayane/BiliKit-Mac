import BiliApplication
import BiliModels
import BiliVideoDetailFeature
import Foundation
import Testing

@testable import BiliKit

/// 播放侧栏的关注按钮与点赞同一条写入链路：先改关注状态、失败放回并在胶囊里说明，写入绑定窗口账户与播放页显示的 UP 主；
/// 关注与点赞、投币、三连不同时在途；关注状态未知、已是目标状态或是自己的视频时不发。
///
/// 整页空间页的关注按钮同一条写入链路：乐观改动只在空间页模型里，失败放回；同一 UP 主同时只有一次关注在途，不分方向；
/// 成功后其他窗口里显示这位 UP 主的空间页随之更新。
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

    @Test
    func spacePageFollowIsOptimisticAndRollsBackOnFailure() async throws {
        let writes = AccountWriteRepositoryStub(outcomes: [.restricted])
        let window = try await signedInWindow(
            process: makeTestProcess(),
            writes: writes,
            uploaderProfile: UploaderProfileRepositoryStub(
                holdsRequests: false,
                viewerFollows: false
            )
        )
        defer { window.close() }
        let page = try await openSpacePage(in: window)

        #expect(window.accountWrites.setFollowing(true, onSpacePage: page))
        #expect(page.viewerFollows == true)
        await waitForObservedState { window.accountWrites.report != nil }

        #expect(page.viewerFollows == false)
        #expect(await writes.calls == ["follow 1 7"])
    }

    /// 同一 UP 主的关注与取消关注不同时在途：两个请求到达服务端的先后不可知，最终状态可能与按钮相反。
    @Test
    func spacePageFollowIsSerializedPerUploader() async throws {
        let writes = AccountWriteRepositoryStub(holdsWrites: true)
        let window = try await signedInWindow(
            process: makeTestProcess(),
            writes: writes,
            uploaderProfile: UploaderProfileRepositoryStub(
                holdsRequests: false,
                viewerFollows: false
            )
        )
        defer { window.close() }
        let page = try await openSpacePage(in: window)

        #expect(window.accountWrites.setFollowing(true, onSpacePage: page))
        await writes.waitForCallCount(1)
        #expect(!window.accountWrites.setFollowing(false, onSpacePage: page))
        await writes.releaseWrites()
        await waitForObservedState { window.accountWrites.report != nil }

        #expect(page.viewerFollows == true)
        #expect(await writes.calls == ["follow 1 7"])
    }

    /// 关注成功后，其他窗口里正在显示这位 UP 主的整页空间页取服务端确认的状态。
    @Test
    func spacePageFollowReachesOtherWindowsShowingTheUploader() async throws {
        let process = makeTestProcess()
        let profile = UploaderProfileRepositoryStub(holdsRequests: false, viewerFollows: false)
        let origin = try await signedInWindow(process: process, uploaderProfile: profile)
        let other = try await signedInWindow(process: process, uploaderProfile: profile)
        defer {
            origin.close()
            other.close()
        }
        let page = try await openSpacePage(in: origin)
        let otherPage = try await openSpacePage(in: other)

        #expect(origin.accountWrites.setFollowing(true, onSpacePage: page))
        await waitForObservedState { otherPage.viewerFollows == true }
    }

    /// 从根页压一层 UP 主 1 的整页空间页，等它读到关注状态。
    private func openSpacePage(in window: WindowComposition) async throws -> UploaderSpaceViewModel
    {
        window.navigationCoordinator.openUploaderSpacePage(owner: VideoOwner(id: 1, name: "UP 主"))
        let page = window.navigationCoordinator.uploaderSpacePage
        await waitForObservedState { page.viewerFollows != nil }
        return page
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
