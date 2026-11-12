import SwiftUI

/// 窗口级的网格保活：每个来源留住一个从 SwiftUI 层级里摘下的网格（`NativeVideoGridView.Coordinator` 连同它的滚动视图、
/// 集合视图、滚动位置与锚点），同一来源、同一内容身份再次出现时原样挂回，不重建。
///
/// 规则与取舍见 ARCHITECTURE「原生 AppKit 集合视图」。每个窗口一份，由 App 的窗口组装持有，生命周期由它的
/// owner 管理。拥有留住的 Coordinator；不拥有图片管线与内容。丢弃一个 Coordinator 时，已摘下的立即 `reset()`；
/// 仍挂在层级里的改为不保活并释放留住的图，等它被拆除时照常 `reset()`。
@MainActor
public final class NativeVideoGridRetainer {
    private struct Entry {
        let contentIdentity: AnyHashable?
        let coordinator: NativeVideoGridView.Coordinator
    }

    private var entries: [AnyHashable: Entry] = [:]

    public init() {}

    /// 网格的 Coordinator：本来源留住的那个已摘下、内容身份相同时复用它，否则另建一个并留住它、丢弃旧的。
    ///
    /// 同一来源的网格仍挂着时又要一个（过渡中新旧两个实例同时存在），留下新的：旧的随后被拆除，留下的是还在显示的那个。
    /// 内容身份不同（例如换了收藏夹，Feature 按夹重建视图）时不把旧内容的位置、锚点与图带给新内容。
    func coordinator(
        for retention: NativeVideoGridRetention,
        make: () -> NativeVideoGridView.Coordinator
    ) -> NativeVideoGridView.Coordinator {
        if let entry = entries[retention.key] {
            if entry.contentIdentity == retention.contentIdentity, entry.coordinator.isDetached {
                return entry.coordinator
            }
            Self.discard(entry.coordinator)
        }
        let created = make()
        created.isRetained = true
        entries[retention.key] = Entry(
            contentIdentity: retention.contentIdentity,
            coordinator: created
        )
        return created
    }

    /// 释放留住的网格替卡片留着的图（系统内存压力）；网格、滚动位置与锚点照留，挂回后缺图的卡片重新取。
    public func releaseHeldImages() {
        for entry in entries.values {
            entry.coordinator.releaseHeldImages()
        }
    }

    /// 丢弃全部留住的网格（关窗、账户变化：仍挂着的网格留住的图属于旧账户，也立即释放）。
    public func discardAll() {
        let all = entries.values
        entries = [:]
        for entry in all {
            Self.discard(entry.coordinator)
        }
    }

    private static func discard(_ coordinator: NativeVideoGridView.Coordinator) {
        coordinator.isRetained = false
        coordinator.releaseHeldImages()
        if coordinator.isDetached { coordinator.reset() }
    }
}

/// 一个网格在窗口保活里的位置：窗口的保活容器、来源 key，以及来源内的内容身份。
///
/// `contentIdentity` 给 Feature 按内容重建视图的来源用（收藏夹按夹）；身份变了就不复用旧网格。
public struct NativeVideoGridRetention {
    let retainer: NativeVideoGridRetainer
    let key: AnyHashable
    let contentIdentity: AnyHashable?

    public init(
        retainer: NativeVideoGridRetainer,
        key: AnyHashable,
        contentIdentity: AnyHashable?
    ) {
        self.retainer = retainer
        self.key = key
        self.contentIdentity = contentIdentity
    }
}
