import AppKit
import Foundation
import Network

/// 一个窗口加载播放时判断“这次能否加入 HDR 档”的环境条件：播放器所在屏幕、低电量模式与网络。
///
/// 只回答 App 层能看到的条件；“HDR 视频”开关在 `AppSettingsModel`，系统的 HDR 播放资格
/// （`AVPlayer.eligibleForHDRPlayback`）由引擎自己再查。B 站 HDR 只有一档，AVPlayer 选中后不会降到
/// SDR（见 ARCHITECTURE），所以在加载时就排除撑不住的情形：屏幕显示不了 HDR、低电量、昂贵或受限网络。
///
/// 每个窗口一份，由 `WindowAdapters.live` 创建。持有一个在主队列回调的 `NWPathMonitor`，`deinit` 时取消；
/// 不持有播放器视图，只弱引用宿主视图来取它当前所在的屏幕（视图由 `PlayerHostView` 登记）。
@MainActor
final class PlaybackHDREnvironment {
    /// 播放器宿主视图；还没有视图（播放页尚未出现）时按主屏判断。
    weak var playerView: NSView?
    private let pathMonitor = NWPathMonitor()
    private var isNetworkLimited = false

    init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated {
                self?.isNetworkLimited = path.isExpensive || path.isConstrained
            }
        }
        pathMonitor.start(queue: .main)
    }

    deinit {
        pathMonitor.cancel()
    }

    /// 屏幕的 EDR 能力大于 1（能显示超过 SDR 白点的亮度）、不在低电量模式、网络不昂贵也不受限时为 true。
    var allowsHDR: Bool {
        guard
            let screen = playerView?.window?.screen ?? NSScreen.main,
            screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1
        else { return false }
        return !ProcessInfo.processInfo.isLowPowerModeEnabled && !isNetworkLimited
    }
}
