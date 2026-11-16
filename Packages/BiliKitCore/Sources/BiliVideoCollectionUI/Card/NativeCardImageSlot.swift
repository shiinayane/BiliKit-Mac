import CoreGraphics
import Foundation

/// 卡片上一个图片位（视频卡片的封面与头像、人物卡片的头像）的取图状态与在途 Task。
///
/// 由集合项持有，每个图片位一份；不拥有图片管线，也不拥有复用身份与配置代次（归集合项，换内容时由它递增）。只在空闲时
/// 发起：缓存命中当帧上图且不淡入，否则异步加载，结果经 `NativeVideoImageApplicationGate` 按发起时的复用身份核对后
/// 写回，身份已变或已取消时丢弃。`cancel()` 取消在途 Task，把加载中与失败退回空闲，卡片再次显示时重试，已显示的图
/// 留着；`clear()` 连同已显示的图一起忘掉。集合项释放时随之释放，`deinit` 兜底取消 Task。
@MainActor
final class NativeCardImageSlot {
    private enum Phase {
        case idle
        case loading
        /// 带着正显示的图：保活的网格摘下前经 `displayedImage` 取走（`NativeVideoGridHeldImages`）。
        case loaded(URL, CGImage)
        case failed
    }

    private let kind: NativeVideoCardImageKind
    private var phase = Phase.idle
    private var task: Task<Void, Never>?

    init(kind: NativeVideoCardImageKind) {
        self.kind = kind
    }

    deinit {
        task?.cancel()
    }

    /// 此刻显示着的图及其地址。
    var displayedImage: (url: URL, image: CGImage)? {
        guard case .loaded(let url, let image) = phase else { return nil }
        return (url, image)
    }

    /// `url` 非 nil 且空闲时取图，图经 `show` 交给卡片（第二个参数是否淡入）；`currentIdentity` 读集合项此刻的复用身份。
    func requestIfIdle(
        _ url: URL?,
        identity: NativeVideoReuseIdentity,
        currentIdentity: @escaping @MainActor () -> NativeVideoReuseIdentity?,
        pipeline: any NativeVideoImageLoading,
        show: @escaping @MainActor (CGImage, Bool) -> Void
    ) {
        guard let url, case .idle = phase else { return }
        if let cached = pipeline.cachedImage(for: url, kind: kind) {
            phase = .loaded(url, cached)
            show(cached, false)
            return
        }
        phase = .loading
        let kind = kind
        task = Task { [weak self] in
            let result = await pipeline.image(for: url, kind: kind)
            guard
                NativeVideoImageApplicationGate.accepts(
                    currentIdentity: currentIdentity(),
                    resultIdentity: identity,
                    isCancelled: Task.isCancelled
                ),
                let self
            else { return }
            task = nil
            if let result {
                phase = .loaded(url, result.image)
                show(result.image, result.fadesIn)
            } else {
                phase = .failed
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        switch phase {
        case .loading, .failed: phase = .idle
        case .idle, .loaded: break
        }
    }

    /// 只在 `cancel()` 之后调用：忘掉已显示的图，下次 `requestIfIdle` 重新取。
    func clear() {
        phase = .idle
    }
}
