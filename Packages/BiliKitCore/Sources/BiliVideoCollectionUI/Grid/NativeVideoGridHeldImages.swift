import CoreGraphics
import Foundation

/// 网格交给卡片的取图入口：保活的网格离开窗口时替卡片留住它们正显示的封面与头像，挂回后重新配置的卡片先从这里同步取，
/// 其余照常交给管线；为什么需要见 ARCHITECTURE「原生 AppKit 集合视图」。
///
/// 由 `NativeVideoGridView.Coordinator` 持有：保活的网格每次离开窗口之前 `hold(_:)` 换成此刻实例化的卡片正显示的图，
/// `reset()`、被保活容器丢弃与系统内存压力（`NativeVideoGridRetainer.releaseHeldImages()`）时 `release()`。不在挂回后
/// 某次排版时清空：挂回的第一遍排版可能还在恢复滚动位置之前，之后才配置的卡片会取不到。卡片仍显示着的图与这里共用
/// 同一份；多出来的只是挂回后被滚出视野的那些，以一个网格实例化的卡片数为界，不计入管线的缓存上限。
struct NativeVideoGridHeldImages: NativeVideoImageLoading {
    let pipeline: any NativeVideoImageLoading
    private var images: [URL: CGImage] = [:]

    init(pipeline: any NativeVideoImageLoading) {
        self.pipeline = pipeline
    }

    @MainActor
    mutating func hold(_ items: [NativeVideoCollectionItem]) {
        images = [:]
        for item in items {
            images.merge(item.displayedImages) { held, _ in held }
        }
    }

    mutating func release() {
        images = [:]
    }

    func cachedImage(for url: URL, kind: NativeVideoCardImageKind) -> CGImage? {
        images[url] ?? pipeline.cachedImage(for: url, kind: kind)
    }

    func image(for url: URL, kind: NativeVideoCardImageKind) async -> NativeVideoCardImage? {
        await pipeline.image(for: url, kind: kind)
    }
}
