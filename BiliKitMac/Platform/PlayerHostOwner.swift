import AppKit
import BiliApplication

/// 窗口唯一的播放器宿主 `NativePlayerHostView` 的 owner：宿主随窗口存活，播放页卸载时只把它从窗口里摘下。
///
/// 拥有宿主实例、画中画的交接（`pictureInPicture`）与写入结果交给播放器的一面（`writeResults`），后两者交给留住的宿主；
/// 不拥有 player、弹幕 renderer 与 controller，它们由窗口组装持有。播放页的 `AVPlayerContainerView` 挂载时经 `host(making:)` 取同一个宿主放进自己的容器，卸载时只摘下：摘下期间 player、弹幕时钟绑定与 item 观察都保留，
/// 页面被换掉时画面不会随卸载先被清空。逐页的观察与提示由宿主自己在挂上、摘下时开关（见 `NativePlayerHostView`）。
///
/// 拆除只在 `close()`：由 `WindowComposition.close()` 在关闭播放之后调用一次，顺序的理由见那里。之后再有挂载（SwiftUI
/// 在关窗后迟到的更新）只拿到不留住的新宿主，由容器卸载时拆除。
@MainActor
final class PlayerHostOwner {
    private var host: NativePlayerHostView?
    private var isClosed = false
    /// 窗口的画中画状态与「还原」交接；宿主创建前就在，导航在窗口组装时接上。
    let pictureInPicture = PlayerPictureInPicture()
    /// 窗口的写入结果交给播放器的一面；窗口组装在构造写入协调者后接上，宿主创建时交给它。
    var writeResults: PlayerWriteResults?

    /// 窗口的宿主；还没有时用 `make` 创建并留住。
    ///
    /// 关窗之后用 `make` 新建一个不留住的宿主。
    func host(making make: () -> NativePlayerHostView) -> NativePlayerHostView {
        if let host { return host }
        let created = make()
        if !isClosed {
            created.pictureInPicture = pictureInPicture
            created.writeResults = writeResults
            host = created
        }
        return created
    }

    /// `view` 是否是本 owner 留住的宿主；容器卸载时据此决定只摘下还是整个拆除。
    func retains(_ view: NativePlayerHostView) -> Bool {
        host === view
    }

    /// 关窗时调用一次：拆除宿主并放开它；重复调用不再动作。
    func close() {
        guard !isClosed else { return }
        isClosed = true
        host?.tearDown()
        host?.removeFromSuperview()
        host = nil
    }
}

/// 窗口的写入结果交给播放器的一面：AVKit 独立全屏时结果改在播放器上显示，主窗口底部的胶囊在全屏窗口里看不到。
///
/// 由窗口组装用写入协调者构造，经 `PlayerHostOwner` 交给宿主。读取的几项都在浮层求值或按键时调用，读的是写入协调者的
/// Observable 状态（结果变化会让浮层刷新）：`isOnPlayer` 是结果此刻是否显示在播放器上，`latestSequence` 是最新一条结果的
/// 序号（不论显示在哪），`current` 只在结果显示在播放器上时给出正在显示的那条。`presentOnPlayer` 由宿主在进入、退出全屏、
/// 挂上与摘下播放页、拆除时调用；不在播放页上时必须交回窗口，否则全屏中离开播放页会把之后的结果都留在已不显示的播放器上。
struct PlayerWriteResults {
    let isOnPlayer: @MainActor () -> Bool
    let latestSequence: @MainActor () -> UInt64
    let current: @MainActor () -> AccountWriteReport?
    let presentOnPlayer: @MainActor (Bool) -> Void
}
