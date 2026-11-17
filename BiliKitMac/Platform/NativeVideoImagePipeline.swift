import AppKit
import BiliNetworking
import BiliUI
import BiliVideoDetailFeature
import CoreGraphics
import Foundation
import ImageIO
import Synchronization

/// 图片结果的来源：内存缓存或网络，决定是否淡入。
enum NativeVideoImageLoadOrigin: Equatable {
    case memoryCache
    case network

    /// 刚从网络到达的图片淡入；内存缓存命中直接显示。
    var shouldFadeIn: Bool { self == .network }
}

/// 管线交给各取图 port 的统一结果：第一帧、来源与可选的动图数据。
struct NativeVideoImageLoadResult: Sendable {
    /// 第一帧（静态图就是整张图），按用途限制解码尺寸。
    let image: CGImage
    let origin: NativeVideoImageLoadOrigin
    /// 只有保留动图的用途、且源图是可播放的多帧图时才有。
    let animation: NativeAnimatedImage?
}

/// 评论动图的播放门槛：超过任一上限只显示第一帧，避免逐帧解码持续占用 CPU 与内存。
///
/// 是否动图按解码出的帧数判断：接口没有可靠的动图标记。
enum NativeAnimatedImagePolicy {
    /// 帧数上限，超过时只显示第一帧。
    ///
    /// 1000 是取舍，没有实测依据，意在只拦下帧数极多的长动画。播放边解码边显示、不预先解出所有帧，
    /// 解码后的帧不随帧数累积，所以它约束的是放行哪类源：帧数越多，留在 cache 里的编码数据通常越大。
    /// 调大会放行更长的动图，可见期间持续逐帧解码；调小会让更多动图只显示第一帧。
    /// SECURITY-MODEL 的图片管线一节写明了这个值，改动时同步。
    static let maximumFrameCount = 1_000
    /// 每帧像素数上限：动图按原尺寸逐帧解码，过大的原图只显示第一帧，避免持续占用 CPU。
    static let maximumPixelCount = 2_048 * 2_048

    static func animation(from data: Data, source: CGImageSource) -> NativeAnimatedImage? {
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 1, frameCount <= maximumFrameCount,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0
        else { return nil }
        let pixels = width.multipliedReportingOverflow(by: height)
        guard !pixels.overflow, pixels.partialValue <= maximumPixelCount else { return nil }
        return NativeAnimatedImage(data: data)
    }
}

/// 管线的图片用途：决定解码尺寸上限、响应大小上限与是否保留动图；各 Feature 的取图用途都映射到这里。
enum NativeVideoImageVariant: Hashable, Sendable {
    case cover
    case avatar
    case largeAvatar
    case commentEmote
    case commentPicture
    case commentPicturePreview
    case trendingSearchIcon

    /// 是否保留动图数据：评论图片的列表格子与预览会播放动图，其余用途只用第一帧。
    var retainsAnimation: Bool {
        switch self {
        case .commentPicture, .commentPicturePreview:
            true
        case .cover, .avatar, .largeAvatar, .commentEmote, .trendingSearchIcon:
            false
        }
    }

    /// 解码后最长边的像素上限（`kCGImageSourceThumbnailMaxPixelSize`），头像与 BiliUI
    /// `BiliAvatarImageSize` 同源。
    ///
    /// 调大增加解码内存与缓存成本，调小会在较大的显示尺寸或高分屏上发虚。
    var maximumDecodedPixelSize: Int {
        switch self {
        case .cover:
            640
        case .avatar:
            BiliAvatarImageSize.pixelSide
        case .largeAvatar:
            BiliAvatarImageSize.largePixelSide
        case .commentEmote:
            128
        case .commentPicture:
            1_024
        case .commentPicturePreview:
            3_840
        case .trendingSearchIcon:
            96
        }
    }

    /// 单次响应允许的最大字节数。
    ///
    /// 只有评论图片预览请求原图，按 B 站评论图片 20 MB 的上传上限放宽；
    /// 其余用途请求的是缩小图或小图，保持较低上限。调大放宽单次下载的内存与流量上限，
    /// 调小会让较大的图片加载失败；见 SECURITY-MODEL §4。
    var maximumResponseBytes: Int {
        switch self {
        case .commentPicturePreview:
            20 * 1_024 * 1_024
        case .cover, .avatar, .largeAvatar, .commentEmote, .commentPicture, .trendingSearchIcon:
            8 * 1_024 * 1_024
        }
    }
}

/// 缓存与在途请求合并的键：同一 URL 在不同用途下分别解码与缓存。
struct NativeVideoImageKey: Hashable, Sendable {
    let url: URL
    let variant: NativeVideoImageVariant
}

/// 原生界面远端图片的加载与解码缓存：同一 URL 与 variant 的并发请求合并为一次下载。
///
/// 拥有无 Cookie 的 ephemeral session、做响应校验与大小上限的 session delegate、内存缓存与在途下载
/// Task；不拥有显示与动图播放（交给视图层）。`shutdown()` 先取消在途 Task 并唤醒等待者，再经
/// `sessionGate` 失效 session；deinit 兜底失效。可变状态由 `Mutex` 隔离。
///
/// 由 `NativeVideoImagePipelineOwner` 持有：每个窗口一个，Now Playing 封面一个。请求来源、
/// 响应校验与缓存规则见 SECURITY-MODEL §4。
final class NativeVideoImagePipeline: Sendable {
    /// 同一个键的一次在途下载：请求序号 `id`、网络 Task 与等待者表。
    ///
    /// Task 在锁外创建后才挂上，因此可能暂时为 nil；最后一个等待者取消时移除本项并取消 Task。
    /// 每个等待者各持一个 `OneShotResult`（它只允许一个等待方），完成、取消或关闭时逐个交付。
    private struct InFlight {
        let id: UInt64
        var task: Task<Void, Never>?
        var waiters: [UInt64: Waiter]
    }

    private typealias Waiter = OneShotResult<NativeVideoImageLoadResult?>

    /// 管线在 `Mutex` 内的全部可变状态：缓存、在途请求、请求与等待者序号、是否已关闭。
    ///
    /// `nextRequestID` 在为某个键新建在途请求时递增，挂接 Task、取消等待者与完成请求都比对这个 id；
    /// 不符说明该键的请求已结束或已被新请求取代，此时挂接方立即取消刚创建的 Task，
    /// 完成方不再唤醒任何等待者，取消方什么也不做。`isShutdown` 置位后不再查缓存、不再新建请求，
    /// 迟到的结果也不写回缓存。
    private struct State {
        var cache: NativeVideoImageCache
        var inFlight: [NativeVideoImageKey: InFlight] = [:]
        var nextRequestID: UInt64 = 0
        var nextWaiterID: UInt64 = 0
        var isShutdown = false
    }

    private enum Lookup {
        case unavailable
        case cached(CGImage, NativeAnimatedImage?)
        case request(
            requestID: UInt64,
            waiterID: UInt64,
            Waiter,
            startsNetwork: Bool
        )
    }

    private let state: Mutex<State>
    private let sessionGate = NativeVideoImageSessionGate()
    private let sessionDelegate = NativeVideoImageSessionDelegate()
    private let session: URLSession

    init(cacheLimits: NativeVideoImageCacheLimits) {
        state = Mutex(State(cache: NativeVideoImageCache(limits: cacheLimits)))
        session = URLSession(
            configuration: .credentialFreeEphemeral(),
            delegate: sessionDelegate,
            delegateQueue: nil
        )
    }

    deinit {
        sessionGate.invalidate(session)
    }

    func cachedImage(
        for url: URL,
        variant: NativeVideoImageVariant
    ) -> CGImage? {
        state.withLock { state in
            guard !state.isShutdown else { return nil }
            return state.cache.image(for: NativeVideoImageKey(url: url, variant: variant))
        }
    }

    /// 已缓存图片的动图数据；静态图或没有缓存时为 nil。
    func cachedAnimation(
        for url: URL,
        variant: NativeVideoImageVariant
    ) -> NativeAnimatedImage? {
        state.withLock { state in
            guard !state.isShutdown else { return nil }
            return state.cache.animation(for: NativeVideoImageKey(url: url, variant: variant))
        }
    }

    func image(
        for url: URL,
        variant: NativeVideoImageVariant
    ) async -> NativeVideoImageLoadResult? {
        guard !Task.isCancelled, Self.acceptsRequestURL(url) else { return nil }

        let key = NativeVideoImageKey(url: url, variant: variant)

        switch lookup(for: key) {
        case .unavailable:
            return nil
        case .cached(let image, let animation):
            return NativeVideoImageLoadResult(
                image: image,
                origin: .memoryCache,
                animation: animation
            )
        case .request(let requestID, let waiterID, let waiter, let startsNetwork):
            if startsNetwork {
                startRequest(key: key, requestID: requestID)
            }
            // 等待者只以 `.success` 交付（取消与关闭交付 nil），`try?` 不会吞掉真实错误。
            let result = await withTaskCancellationHandler {
                try? await waiter.value()
            } onCancel: {
                self.cancelWaiter(key: key, requestID: requestID, waiterID: waiterID)
            }
            guard isActive, !Task.isCancelled else {
                return nil
            }
            return result
        }
    }

    /// 用户保存原图时取原始响应数据：不解码、不缓存，响应校验与大小上限与图片请求相同；失败、取消
    /// 或已关闭时为 nil。
    func originalData(
        for url: URL,
        variant: NativeVideoImageVariant
    ) async -> Data? {
        guard isActive, !Task.isCancelled, Self.acceptsRequestURL(url) else { return nil }
        let data = try? await fetchData(for: url, maximumBytes: variant.maximumResponseBytes)
        guard isActive, !Task.isCancelled, let data, Self.isBitmapImage(data) else { return nil }
        return data
    }

    /// 只请求过公开 HTTPS 基线的地址（拒绝 IP、本机与内网域名、非 443 端口）；
    /// 图片加载与保存原图共用，见 SECURITY-MODEL §4。
    nonisolated static func acceptsRequestURL(_ url: URL) -> Bool {
        PublicHTTPSURLPolicy().allows(url)
    }

    /// 数据能被 ImageIO 识别为位图（JPEG、PNG、GIF、WebP 等）；SVG、HTML 等不算，保存时拒绝，见
    /// SECURITY-MODEL §4。
    nonisolated static func isBitmapImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetType(source) != nil
        else { return false }
        return CGImageSourceGetCount(source) > 0
    }

    /// 无 Cookie 的请求经同一个 session delegate 做响应校验与大小上限；图片加载与保存原图共用。
    private func fetchData(for url: URL, maximumBytes: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        return try await sessionDelegate.response(
            for: request,
            maximumBytes: maximumBytes,
            using: session,
            gate: sessionGate
        ).data
    }

    /// 系统内存压力时清空已解码的缓存；在途请求照常完成并写回，之后的请求照常进行。
    func discardCachedImages() {
        state.withLock { state in
            guard !state.isShutdown else { return }
            state.cache.removeAll()
        }
    }

    func shutdown() {
        let inFlight: [InFlight]? = state.withLock { state in
            guard !state.isShutdown else { return nil }
            state.isShutdown = true
            state.cache.removeAll()
            let requests = Array(state.inFlight.values)
            state.inFlight.removeAll()
            return requests
        }
        guard let inFlight else { return }
        for request in inFlight { request.task?.cancel() }
        for waiter in inFlight.flatMap({ $0.waiters.values }) { waiter.resolve(.success(nil)) }
        sessionGate.invalidate(session)
    }

    /// 响应头声明的长度是否可接受：未声明（-1）时放行，由正文累积上限兜底；
    /// 已声明超过上限时直接拒绝。
    nonisolated static func acceptsExpectedLength(_ length: Int64, maximumBytes: Int) -> Bool {
        length < 0 || length <= maximumBytes
    }

    /// 按用途的最长边上限缩略第一帧，并按 EXIF 方向转正；ImageIO 识别不了或文件头不完整时为 nil，
    /// 调用方此时不写缓存。
    ///
    /// 服务端正常结束响应但内容被截断的 JPEG／PNG（无论是否声明长度）会被 ImageIO 容错解码（缺失部分留空）
    /// 并照常显示、缓存；连接中断由 URLSession 报错，在 session delegate 里就失败，不会走到这里。见
    /// SECURITY-MODEL §9。
    nonisolated static func decodeImage(
        _ data: Data,
        variant: NativeVideoImageVariant
    ) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: variant.maximumDecodedPixelSize,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary
        )
    }

    /// 保留动图的用途里，多帧且在播放门槛内的源图返回动图数据。
    nonisolated static func decodeAnimation(
        _ data: Data,
        variant: NativeVideoImageVariant
    ) -> NativeAnimatedImage? {
        guard variant.retainsAnimation,
            let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        return NativeAnimatedImagePolicy.animation(from: data, source: source)
    }

    private func loadNetworkImage(
        for key: NativeVideoImageKey
    ) async -> NativeVideoImageLoadResult? {
        do {
            let data = try await fetchData(
                for: key.url,
                maximumBytes: key.variant.maximumResponseBytes
            )
            guard
                !Task.isCancelled,
                let image = Self.decodeImage(data, variant: key.variant)
            else { return nil }
            let animation = Self.decodeAnimation(data, variant: key.variant)
            guard store(image, animation: animation, for: key) else { return nil }
            return NativeVideoImageLoadResult(image: image, origin: .network, animation: animation)
        } catch {
            return nil
        }
    }

    private func lookup(for key: NativeVideoImageKey) -> Lookup {
        state.withLock { state in
            guard !state.isShutdown else { return .unavailable }
            if let image = state.cache.image(for: key) {
                return .cached(image, state.cache.animation(for: key))
            }
            state.nextWaiterID &+= 1
            let waiterID = state.nextWaiterID
            let waiter = Waiter()
            if var existing = state.inFlight[key] {
                existing.waiters[waiterID] = waiter
                state.inFlight[key] = existing
                return .request(
                    requestID: existing.id,
                    waiterID: waiterID,
                    waiter,
                    startsNetwork: false
                )
            }
            state.nextRequestID &+= 1
            let requestID = state.nextRequestID
            state.inFlight[key] = InFlight(
                id: requestID,
                task: nil,
                waiters: [waiterID: waiter]
            )
            return .request(
                requestID: requestID,
                waiterID: waiterID,
                waiter,
                startsNetwork: true
            )
        }
    }

    /// 在锁外创建网络 Task；请求已被取消或关闭时立即取消刚创建的 Task。
    private func startRequest(key: NativeVideoImageKey, requestID: UInt64) {
        let task = Task { [weak self] in
            guard let self else { return }
            let result = await loadNetworkImage(for: key)
            finishRequest(key: key, requestID: requestID, result: result)
        }
        let isAttached = state.withLock { state in
            guard var active = state.inFlight[key], active.id == requestID else {
                return false
            }
            active.task = task
            state.inFlight[key] = active
            return true
        }
        if !isAttached { task.cancel() }
    }

    private var isActive: Bool {
        state.withLock { !$0.isShutdown }
    }

    private func cancelWaiter(
        key: NativeVideoImageKey,
        requestID: UInt64,
        waiterID: UInt64
    ) {
        let removed: (Waiter, Task<Void, Never>?)? = state.withLock { state in
            guard var request = state.inFlight[key], request.id == requestID,
                let waiter = request.waiters.removeValue(forKey: waiterID)
            else { return nil }
            guard request.waiters.isEmpty else {
                state.inFlight[key] = request
                return (waiter, nil)
            }
            state.inFlight[key] = nil
            return (waiter, request.task)
        }
        guard let (waiter, task) = removed else { return }
        waiter.resolve(.success(nil))
        task?.cancel()
    }

    private func finishRequest(
        key: NativeVideoImageKey,
        requestID: UInt64,
        result: NativeVideoImageLoadResult?
    ) {
        let waiters: [Waiter] = state.withLock { state in
            guard let request = state.inFlight[key], request.id == requestID else {
                return []
            }
            state.inFlight[key] = nil
            return Array(request.waiters.values)
        }
        for waiter in waiters { waiter.resolve(.success(result)) }
    }

    private func store(
        _ image: CGImage,
        animation: NativeAnimatedImage?,
        for key: NativeVideoImageKey
    ) -> Bool {
        state.withLock { state in
            guard !state.isShutdown else { return false }
            state.cache.insert(image, animation: animation, for: key)
            return true
        }
    }
}
