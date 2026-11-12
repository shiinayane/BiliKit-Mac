import BiliVideoCollectionUI
import Foundation

/// 窗口网格保活的生命周期 owner：持有 `NativeVideoGridRetainer` 与系统内存压力监听。
///
/// 由 `WindowComposition` 持有，保活容器经它交给 `AppShellView` 构造各来源的网格依赖；账户变化时的丢弃由
/// `AppShellView` 直接调用保活容器。内存压力只释放摘下的网格替卡片留着的图，网格与滚动位置照留：丢掉网格只省下视图本身，
/// 却要在切回时重建、重新取图。监听在主队列投递，处理在 MainActor 上执行。`close()` 在关窗时、关闭图片管线之前调用：
/// 先取消监听，再丢弃全部网格；deinit 时监听自行取消。
@MainActor
final class NativeVideoGridRetainerOwner {
    let retainer = NativeVideoGridRetainer()
    private let memoryPressure: SystemMemoryPressureObserver

    init() {
        memoryPressure = SystemMemoryPressureObserver(queue: .main) { [weak retainer] in
            MainActor.assumeIsolated {
                retainer?.releaseHeldImages()
            }
        }
    }

    func close() {
        memoryPressure.cancel()
        retainer.discardAll()
    }
}
