import AppKit

/// 窗口唯一的播放器宿主 `NativePlayerHostView` 的 owner：宿主随窗口存活，播放页卸载时只把它从窗口里摘下。
///
/// 拥有宿主实例；不拥有 player、弹幕 renderer 与 controller，它们由窗口组装持有。播放页的 `AVPlayerContainerView`
/// 挂载时经 `host(making:)` 取同一个宿主放进自己的容器，卸载时只摘下：摘下期间 player、弹幕时钟绑定与 item 观察都保留，
/// 页面被换掉时画面不会随卸载先被清空。逐页的观察与提示由宿主自己在挂上、摘下时开关（见 `NativePlayerHostView`）。
///
/// 拆除只在 `close()`：由 `WindowComposition.close()` 在关闭播放之后调用一次，顺序的理由见那里。之后再有挂载（SwiftUI
/// 在关窗后迟到的更新）只拿到不留住的新宿主，由容器卸载时拆除。
@MainActor
final class PlayerHostOwner {
    private var host: NativePlayerHostView?
    private var isClosed = false

    /// 窗口的宿主；还没有时用 `make` 创建并留住。
    ///
    /// 关窗之后用 `make` 新建一个不留住的宿主。
    func host(making make: () -> NativePlayerHostView) -> NativePlayerHostView {
        if let host { return host }
        let created = make()
        if !isClosed {
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
