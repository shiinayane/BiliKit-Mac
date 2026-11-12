import CoreGraphics
import Foundation
import Synchronization

@testable import BiliVideoCollectionUI

/// 卡片取图 port 的可配置替身（本 target 唯一一份）：按地址给出缓存命中与异步加载结果，配置后不可变；
/// 记下异步加载被请求的次数。
final class StubCardImageLoader: NativeVideoImageLoading {
    private let cached: [URL: CGImage]
    private let loaded: [URL: NativeVideoCardImage]
    private let loadRequests = Mutex(0)

    init(cached: [URL: CGImage] = [:], loaded: [URL: NativeVideoCardImage] = [:]) {
        self.cached = cached
        self.loaded = loaded
    }

    var loadRequestCount: Int { loadRequests.withLock { $0 } }

    func cachedImage(for url: URL, kind: NativeVideoCardImageKind) -> CGImage? {
        cached[url]
    }

    func image(for url: URL, kind: NativeVideoCardImageKind) async -> NativeVideoCardImage? {
        loadRequests.withLock { $0 += 1 }
        return loaded[url]
    }
}
