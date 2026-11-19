import BiliModels

/// 读取某个分 P 此刻的「正在看」人数文本。
///
/// 由播放页的 `VideoOnlineViewerModel` 按播放周期调用，Task 与取消归它；空 BV 或无效 CID 按无效请求拒绝，不发请求。
public struct VideoOnlineViewerUseCase: Sendable {
    private let repository: any VideoOnlineViewerRepository

    public init(repository: any VideoOnlineViewerRepository) {
        self.repository = repository
    }

    public func onlineViewerText(for identity: PlaybackItemIdentity) async throws -> String? {
        guard !identity.bvid.isEmpty, identity.cid > 0 else {
            throw ContentApplicationError.invalidRequest
        }
        let text = try await repository.onlineViewerText(for: identity)
        try Task.checkCancellation()
        return text
    }
}
