import SwiftUI

/// 播放页点赞、投币、收藏按钮与侧栏关注按钮的写入口：此刻是否满足写入门槛，以及按 BVID 发出写入意图（关注作用于
/// 这个视频的 UP 主，mid 由协调者从互动状态取，不由按钮给出）。
///
/// 实现是 App 窗口的写入协调者（`AccountWriteCoordinator`），由 App 经 SwiftUI 环境 `videoEngagementActions` 注入；按钮
/// 只读取它，不持有 Task、不判断账户。没有注入（预览、测试）时为 nil，按钮禁用。闭包只转发意图：门槛、乐观更新与请求的
/// owner 都在协调者里，并在执行时重新核对。快捷键 Q／W／E 走 App 自己的同一组协调者方法。
public struct VideoEngagementActions: Sendable {
    public let isAvailable: @MainActor @Sendable () -> Bool
    public let setLiked: @MainActor @Sendable (_ isLiked: Bool, _ bvid: String) -> Void
    public let addCoins:
        @MainActor @Sendable (_ count: Int, _ alsoLike: Bool, _ bvid: String) -> Void
    public let chooseFavoriteFolders: @MainActor @Sendable (_ bvid: String) -> Void
    public let setFollowing: @MainActor @Sendable (_ isFollowing: Bool, _ bvid: String) -> Void

    public init(
        isAvailable: @escaping @MainActor @Sendable () -> Bool,
        setLiked: @escaping @MainActor @Sendable (_ isLiked: Bool, _ bvid: String) -> Void,
        addCoins:
            @escaping @MainActor @Sendable (_ count: Int, _ alsoLike: Bool, _ bvid: String) -> Void,
        chooseFavoriteFolders: @escaping @MainActor @Sendable (_ bvid: String) -> Void,
        setFollowing: @escaping @MainActor @Sendable (_ isFollowing: Bool, _ bvid: String) -> Void
    ) {
        self.isAvailable = isAvailable
        self.setLiked = setLiked
        self.addCoins = addCoins
        self.chooseFavoriteFolders = chooseFavoriteFolders
        self.setFollowing = setFollowing
    }
}

extension EnvironmentValues {
    /// 播放页互动按钮的写入口；App 在窗口外壳上注入一次，见 `VideoEngagementActions`。
    @Entry public var videoEngagementActions: VideoEngagementActions? = nil
}
