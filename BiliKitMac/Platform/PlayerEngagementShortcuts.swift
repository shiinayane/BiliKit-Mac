import BiliApplication
import BiliVideoDetailFeature

/// 播放器快捷键 Q（点赞）、长按 Q（三连）、W（投币）、E（收藏）的意图：执行并返回按键的结局（发出了哪次写入，或做不了的
/// 原因）；发出写入的那几种怎样显示由浮层决定（`PlayerShortcutFeedback.isWriteRequest`）。
///
/// 由 `WindowComposition` 用窗口的写入协调者与播放页互动状态构造（`make`），经播放器内容一路交给
/// `NativePlayerHostView` 的键盘 controller。门槛与写入都在协调者里，这里只决定按键当下给什么提示：没有可写入的
/// 账户时提示登录；保留的旧详情不可操作（换视频正在加载或失败）、或互动状态还没读到时提示暂时不可用，后者顺带重读一次；
/// 全屏（AVKit 独立全屏窗口）下投币与收藏的面板在主窗口里看不到，只提示先退出全屏。协调者没有发出写入（同一视频
/// 已有互动写入在途）时不给提示，免得说出没有发生的事。不持有状态。
struct PlayerEngagementShortcuts {
    let toggleLike: @MainActor () -> PlayerEngagementFeedback?
    let triple: @MainActor () -> PlayerEngagementFeedback?
    let openCoinPanel: @MainActor (_ isFullScreen: Bool) -> PlayerEngagementFeedback?
    let chooseFavoriteFolders: @MainActor (_ isFullScreen: Bool) -> PlayerEngagementFeedback?

    @MainActor
    static func make(
        accountWrites: AccountWriteCoordinator,
        engagementModel: VideoEngagementModel,
        videoModel: VideoViewModel
    ) -> Self {
        /// 门槛满足、页面可操作且读到了正在播放的视频的互动状态时给出 BVID 与状态，否则给出提示。
        func target() -> Target {
            guard accountWrites.isWritable else { return .blocked(.signInRequired) }
            guard let bvid = videoModel.operableBVID, engagementModel.bvid == bvid else {
                return .blocked(.unavailable)
            }
            guard let state = engagementModel.engagement else {
                engagementModel.markNeedsReload(bvid: bvid)
                return .blocked(.unavailable)
            }
            return .ready(bvid: bvid, isLiked: state.isLiked)
        }

        return Self(
            toggleLike: {
                switch target() {
                case .blocked(let feedback):
                    return feedback
                case .ready(let bvid, let isLiked):
                    guard accountWrites.setLiked(!isLiked, bvid: bvid) else { return nil }
                    return isLiked ? .unlikeRequested : .likeRequested
                }
            },
            triple: {
                switch target() {
                case .blocked(let feedback):
                    return feedback
                case .ready(let bvid, _):
                    guard accountWrites.triple(bvid: bvid) else { return nil }
                    return .tripleRequested
                }
            },
            openCoinPanel: { isFullScreen in
                switch target() {
                case .blocked(let feedback):
                    return feedback
                case .ready:
                    guard !isFullScreen else { return .exitFullScreenToCoin }
                    engagementModel.isCoinPanelPresented = true
                    return nil
                }
            },
            chooseFavoriteFolders: { isFullScreen in
                switch target() {
                case .blocked(let feedback):
                    return feedback
                case .ready(let bvid, _):
                    guard !isFullScreen else { return .exitFullScreenToFavorite }
                    accountWrites.chooseFavoriteFolders(bvid: bvid)
                    return nil
                }
            }
        )
    }

    /// 按键当下能否执行：可以时给出视频与是否已赞，不能时给出提示。
    private enum Target {
        case ready(bvid: String, isLiked: Bool)
        case blocked(PlayerEngagementFeedback)
    }
}
