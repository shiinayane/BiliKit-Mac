import CoreGraphics
import Foundation
import Synchronization

@testable import BiliVideoCollectionUI

/// 卡片取图 port 的可配置替身（本 target 唯一一份）：按地址给出缓存命中与异步加载结果，配置后不可变；
/// 按顺序记下异步加载请求的地址。
final class StubCardImageLoader: NativeVideoImageLoading {
    private let cached: [URL: CGImage]
    private let loaded: [URL: NativeVideoCardImage]
    private let loadRequests = Mutex([URL]())

    init(cached: [URL: CGImage] = [:], loaded: [URL: NativeVideoCardImage] = [:]) {
        self.cached = cached
        self.loaded = loaded
    }

    var loadRequestCount: Int { loadRequests.withLock { $0.count } }

    /// 第 `index` 次起（从 0 数）请求加载的地址。
    func requestedURLs(from index: Int) -> [URL] {
        loadRequests.withLock { Array($0.dropFirst(index)) }
    }

    func cachedImage(for url: URL, kind: NativeVideoCardImageKind) -> CGImage? {
        cached[url]
    }

    func image(for url: URL, kind: NativeVideoCardImageKind) async -> NativeVideoCardImage? {
        loadRequests.withLock { $0.append(url) }
        return loaded[url]
    }
}
