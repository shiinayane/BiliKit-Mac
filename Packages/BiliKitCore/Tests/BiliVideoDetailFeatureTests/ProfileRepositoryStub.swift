import BiliApplication
import BiliModels

@testable import BiliVideoDetailFeature

/// 本 target 唯一的 UploaderProfileRepository 替身：`immediate` 为 nil 时每个请求挂起到测试按序号放行；观看者关注状态取
/// `viewerFollows`。
actor ProfileRepositoryStub: UploaderProfileRepository {
    private let immediate: Result<UploaderProfile, ContentApplicationError>?
    private let viewerFollows: Bool?
    private var held: [CheckedContinuation<UploaderProfile, Never>?] = []
    private var requestWaiters = CountWaiters()
    private(set) var callCount = 0

    init(
        immediate: Result<UploaderProfile, ContentApplicationError>? = nil,
        viewerFollows: Bool? = nil
    ) {
        self.immediate = immediate
        self.viewerFollows = viewerFollows
    }

    func uploaderCard(for ownerID: Int64) async throws -> UploaderCard {
        callCount += 1
        let viewerFollows = viewerFollows
        if let immediate {
            return UploaderCard(profile: try immediate.get(), viewerFollows: viewerFollows)
        }
        let profile = await withCheckedContinuation { continuation in
            held.append(continuation)
            requestWaiters.resume(reaching: held.count)
        }
        return UploaderCard(profile: profile, viewerFollows: viewerFollows)
    }

    func waitForRequestCount(_ count: Int) async {
        await withCheckedContinuation {
            requestWaiters.add($0, until: count, current: held.count)
        }
    }

    func releaseRequest(_ index: Int, profile: UploaderProfile) {
        held[index]?.resume(returning: profile)
        held[index] = nil
    }
}
