import AppKit
import BiliApplication
import BiliModels
import Foundation
import QuartzCore

@MainActor
/// 有硬上限的 Core Animation 弹幕 backend，负责纹理准备、layer identity、动画时钟与回收。
///
/// Core Text shaping、整行 union mask、vImage 阴影与 RGBA 合成都由有界 preparation owner
/// 在后台完成。MainActor 只消费不可变像素并安装一个普通 `CALayer`；用户透明度统一落在
/// `rootLayer.opacity`，活动 layer 不启用实时 shadow。
public final class CoreAnimationDanmakuRenderer:
    DanmakuRenderingBackend
{
    private struct Entry {
        let layer: CALayer
        let placement: DanmakuLanePlacement
        let textureByteCost: Int
        let objectIdentity: UInt64
        let relay: AnimationCompletionRelay
    }

    static let maximumActiveTextureByteCost = 64 * 1_024 * 1_024

    public weak var delegate: (any DanmakuRenderingBackendDelegate)?
    public let rootLayer: CALayer
    public let style: CoreAnimationDanmakuStyle

    public private(set) var renderEpoch: UInt64 = 0
    public var activeLayerCount: Int { entries.count }

    private var backingScale: Double
    private var entries: [String: Entry] = [:]
    private var nextObjectIdentity: UInt64 = 0
    private var surfaceSize = CGSize.zero
    private let preparationOwner: DanmakuTexturePreparationOwner
    private let activeTextureByteLimit: Int
    private(set) var activeTextureByteCost = 0

    public convenience init(
        style: CoreAnimationDanmakuStyle = .production,
        contentsScale: Double = 2
    ) {
        self.init(
            style: style,
            contentsScale: contentsScale,
            preparationConfiguration: .production,
            activeTextureByteLimit: Self.maximumActiveTextureByteCost
        )
    }

    init(
        style: CoreAnimationDanmakuStyle,
        contentsScale: Double,
        preparationConfiguration: DanmakuTexturePreparationOwner.Configuration,
        activeTextureByteLimit: Int = CoreAnimationDanmakuRenderer
            .maximumActiveTextureByteCost
    ) {
        precondition(activeTextureByteLimit > 0)
        self.style = style
        self.activeTextureByteLimit = activeTextureByteLimit
        backingScale = Self.normalizedBackingScale(contentsScale)
        preparationOwner = DanmakuTexturePreparationOwner(
            configuration: preparationConfiguration
        )
        rootLayer = CALayer()
        rootLayer.anchorPoint = .zero
        rootLayer.isGeometryFlipped = true
        rootLayer.masksToBounds = true
    }

    /// 同步接口只为旧 Lab backend 的协议兼容保留；生产 renderer 必须走 `prepare`。
    public func measure(_ event: DanmakuEvent) -> DanmakuTextMetrics {
        DanmakuTextMetrics(width: 0, height: 0)
    }

    /// 同步接口在生产 renderer 中 fail closed，防止恢复 MainActor 栅格化路径。
    public func render(_ placement: DanmakuLanePlacement) {}

    public func prepare(
        _ event: DanmakuEvent,
        preparationID: UInt64,
        generation: UInt64,
        backingScale: Double,
        completion:
            @escaping @MainActor @Sendable (
                DanmakuPreparationResult
            ) -> Void
    ) {
        let normalizedScale = Self.normalizedBackingScale(backingScale)
        guard normalizedScale == self.backingScale else {
            completion(.rejected(.cancelled))
            return
        }
        preparationOwner.prepare(
            event: event,
            style: style,
            backingScale: normalizedScale,
            preparationID: preparationID,
            generation: generation,
            completion: completion
        )
    }

    @discardableResult
    public func renderPrepared(
        _ placement: DanmakuLanePlacement,
        preparationID: UInt64,
        generation: UInt64
    ) -> Bool {
        let event = placement.request.event
        guard entries[event.id] == nil,
            entries.count
                < DanmakuLaneConfiguration.hardMaximumActiveCount,
            surfaceSize.width > 0,
            surfaceSize.height > 0,
            let key = DanmakuTextureRasterizer.key(
                event: event,
                style: style,
                backingScale: backingScale
            ),
            let payload = preparationOwner.consume(
                preparationID: preparationID,
                generation: generation,
                expectedKey: key
            )
        else {
            preparationOwner.discard(preparationID: preparationID)
            return false
        }
        let remainingTextureBytes = max(
            activeTextureByteLimit - activeTextureByteCost,
            0
        )
        guard payload.byteCost <= remainingTextureBytes,
            let image = Self.makeImage(payload)
        else {
            return false
        }

        nextObjectIdentity &+= 1
        let objectIdentity = nextObjectIdentity
        let layer = makeLayer(for: placement, image: image, scale: backingScale)
        let relay = AnimationCompletionRelay(
            renderer: self,
            eventID: event.id,
            objectIdentity: objectIdentity,
            renderEpoch: renderEpoch
        )
        let animation = makeAnimation(for: placement, layer: layer)
        animation.delegate = relay
        entries[event.id] = Entry(
            layer: layer,
            placement: placement,
            textureByteCost: payload.byteCost,
            objectIdentity: objectIdentity,
            relay: relay
        )
        activeTextureByteCost += payload.byteCost

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.addSublayer(layer)
        if event.mode == .scrolling {
            layer.position.x = -layer.bounds.width / 2
        }
        layer.add(animation, forKey: "danmaku")
        CATransaction.commit()
        return true
    }

    public func discardPreparation(preparationID: UInt64) {
        preparationOwner.discard(preparationID: preparationID)
    }

    public func cancelPendingPreparations() {
        preparationOwner.cancelAllPreparations()
    }

    public func remove(eventID: String) {
        removeEntry(eventID: eventID)
    }

    public func clearAll() {
        advanceEpoch()
        preparationOwner.cancelAllPreparations()
        removeAllEntries()
    }

    /// 在保持当前 layer 局部时间连续的前提下暂停或调整动画速率。
    public func setPlaybackRate(_ rate: Double) {
        let newRate = rate.isFinite ? max(rate, 0) : 0
        guard Double(rootLayer.speed) != newRate else { return }
        let mediaTime = CACurrentMediaTime()
        let parentTime =
            rootLayer.superlayer?
            .convertTime(mediaTime, from: nil)
            ?? mediaTime
        let localTime = rootLayer.convertTime(mediaTime, from: nil)
        rootLayer.beginTime = parentTime
        rootLayer.timeOffset = localTime
        rootLayer.speed = Float(newRate)
    }

    public func setOpacity(_ opacity: DanmakuOpacity) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.opacity = Float(opacity.value)
        CATransaction.commit()
    }

    public func updateSurfaceSize(width: Double, height: Double) {
        updateSurfaceSize(
            width: width,
            height: height,
            backingScale: backingScale
        )
    }

    public func updateSurfaceSize(
        width: Double,
        height: Double,
        backingScale: Double
    ) {
        let normalizedScale = Self.normalizedBackingScale(backingScale)
        if normalizedScale != self.backingScale {
            self.backingScale = normalizedScale
            preparationOwner.cancelAllPreparations()
        }
        let oldSurfaceSize = surfaceSize
        surfaceSize = CGSize(
            width: max(width.isFinite ? width : 0, 0),
            height: max(height.isFinite ? height : 0, 0)
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.frame = CGRect(origin: .zero, size: surfaceSize)
        for entry in entries.values {
            updateFixedGeometry(
                for: entry,
                heightDelta: surfaceSize.height - oldSurfaceSize.height
            )
        }
        CATransaction.commit()
    }

    public func stop() {
        advanceEpoch()
        preparationOwner.cancelAllPreparations()
        removeAllEntries()
        setPlaybackRate(0)
    }

    func textLayer(forEventID eventID: String) -> CALayer? {
        entries[eventID]?.layer
    }

    func objectIdentity(forEventID eventID: String) -> UInt64? {
        entries[eventID]?.objectIdentity
    }

    var outstandingPreparationCount: Int {
        preparationOwner.outstandingRequestCount
    }

    var cachedTextureCount: Int { preparationOwner.cachedTextureCount }
    var cachedTextureByteCost: Int { preparationOwner.cachedByteCost }
    var cacheHitCount: Int { preparationOwner.cacheHitCount }
    var cacheMissCount: Int { preparationOwner.cacheMissCount }
    var cacheEvictionCount: Int { preparationOwner.cacheEvictionCount }
    var rasterizationCount: Int { preparationOwner.rasterizationCount }
    var maximumConcurrentPreparationCount: Int {
        preparationOwner.maximumConcurrentOperationCount
    }

    func handleMemoryPressureForTesting() {
        preparationOwner.handleMemoryPressureForTesting()
    }

    func completeAnimation(
        eventID: String,
        objectIdentity: UInt64,
        renderEpoch completionEpoch: UInt64
    ) {
        guard completionEpoch == renderEpoch,
            let entry = entries[eventID],
            entry.objectIdentity == objectIdentity
        else {
            return
        }
        removeEntry(eventID: eventID)
        delegate?.rendererDidFinish(eventID: eventID)
    }

    private func makeLayer(
        for placement: DanmakuLanePlacement,
        image: CGImage,
        scale: Double
    ) -> CALayer {
        let layer = CALayer()
        layer.contents = image
        layer.contentsScale = CGFloat(scale)
        layer.contentsGravity = .resize
        layer.magnificationFilter = .linear
        layer.minificationFilter = .linear
        layer.bounds = CGRect(
            x: 0,
            y: 0,
            width: placement.request.width,
            height: placement.request.height
        )
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(
            x: placement.request.event.mode == .scrolling
                ? surfaceSize.width + layer.bounds.width / 2
                : surfaceSize.width / 2,
            y: placement.originY + layer.bounds.height / 2
        )
        layer.shadowOpacity = 0
        return layer
    }

    private func makeAnimation(
        for placement: DanmakuLanePlacement,
        layer: CALayer
    ) -> CABasicAnimation {
        let animation: CABasicAnimation
        switch placement.request.event.mode {
        case .scrolling:
            animation = CABasicAnimation(keyPath: "position.x")
            animation.fromValue = layer.position.x
            animation.toValue = -layer.bounds.width / 2
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
        case .top, .bottom:
            animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 1
            animation.toValue = 1
        }
        animation.duration = placement.request.durationSeconds
        return animation
    }

    private func updateFixedGeometry(
        for entry: Entry,
        heightDelta: CGFloat
    ) {
        switch entry.placement.request.event.mode {
        case .scrolling:
            return
        case .top:
            entry.layer.position.x = surfaceSize.width / 2
        case .bottom:
            entry.layer.position.x = surfaceSize.width / 2
            entry.layer.position.y += heightDelta
        }
    }

    private func advanceEpoch() {
        renderEpoch &+= 1
    }

    private func removeAllEntries() {
        let oldEntries = entries
        entries.removeAll(keepingCapacity: false)
        activeTextureByteCost = 0
        for entry in oldEntries.values {
            entry.layer.removeAllAnimations()
            entry.layer.removeFromSuperlayer()
        }
    }

    private func removeEntry(eventID: String) {
        guard let entry = entries.removeValue(forKey: eventID) else {
            return
        }
        activeTextureByteCost -= entry.textureByteCost
        entry.layer.removeAllAnimations()
        entry.layer.removeFromSuperlayer()
    }

    private static func normalizedBackingScale(_ scale: Double) -> Double {
        scale.isFinite
            ? min(max(scale, 1), DanmakuTextureRasterizer.maximumBackingScale)
            : 2
    }

    private static func makeImage(
        _ payload: DanmakuTexturePayload
    ) -> CGImage? {
        guard let provider = CGDataProvider(data: payload.pixels as CFData)
        else {
            return nil
        }
        let colorSpace =
            CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
        ).union(.byteOrder32Big)
        return CGImage(
            width: payload.widthPixels,
            height: payload.heightPixels,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: payload.bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
