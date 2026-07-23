import AppKit
import BiliModels
import CoreText
import Foundation
import QuartzCore

@MainActor
public final class CoreAnimationDanmakuRenderer:
    DanmakuRenderingBackend
{
    private static let maximumTextWidthPixels: CGFloat = 8_192
    private static let maximumTextHeightPixels: CGFloat = 512
    private static let maximumTextUTF16Length = 512

    private struct Entry {
        let layer: CATextLayer
        let objectIdentity: UInt64
        let relay: AnimationCompletionRelay
    }

    public weak var delegate: (any DanmakuRenderingBackendDelegate)?
    public let rootLayer: CALayer

    public private(set) var renderEpoch: UInt64 = 0
    public var activeLayerCount: Int { entries.count }

    private let contentsScale: CGFloat
    private let font = NSFont.systemFont(ofSize: 24, weight: .semibold)
    private let heavyInkShadow: NSShadow = {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black
        shadow.shadowOffset = .zero
        shadow.shadowBlurRadius = 1.5
        return shadow
    }()
    private var entries: [String: Entry] = [:]
    private var nextObjectIdentity: UInt64 = 0
    private var surfaceSize = CGSize.zero

    public init(contentsScale: Double = 2) {
        self.contentsScale = max(CGFloat(contentsScale), 1)
        rootLayer = CALayer()
        rootLayer.anchorPoint = .zero
        rootLayer.isGeometryFlipped = true
        rootLayer.masksToBounds = true
    }

    public func measure(_ event: DanmakuEvent) -> DanmakuTextMetrics {
        guard !event.text.isEmpty,
              event.text.utf16.count <= Self.maximumTextUTF16Length
        else {
            return DanmakuTextMetrics(width: 0, height: 0)
        }
        let attributed = attributedString(for: event)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: attributed.length),
            nil,
            CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            ),
            nil
        )
        let widthPixels = ceil(measured.width * contentsScale) + 8
        let heightPixels = ceil(measured.height * contentsScale) + 8
        guard widthPixels.isFinite,
              heightPixels.isFinite,
              widthPixels > 0,
              heightPixels > 0,
              widthPixels <= Self.maximumTextWidthPixels,
              heightPixels <= Self.maximumTextHeightPixels
        else {
            return DanmakuTextMetrics(width: 0, height: 0)
        }
        return DanmakuTextMetrics(
            width: Double(widthPixels / contentsScale),
            height: Double(heightPixels / contentsScale)
        )
    }

    public func render(_ placement: DanmakuLanePlacement) {
        let event = placement.request.event
        guard entries[event.id] == nil,
              entries.count
                < DanmakuLaneConfiguration.hardMaximumActiveCount,
              surfaceSize.width > 0,
              surfaceSize.height > 0
        else {
            return
        }

        nextObjectIdentity &+= 1
        let objectIdentity = nextObjectIdentity
        let textLayer = makeTextLayer(for: placement)
        let relay = AnimationCompletionRelay(
            renderer: self,
            eventID: event.id,
            objectIdentity: objectIdentity,
            renderEpoch: renderEpoch
        )
        let animation = makeAnimation(
            for: placement,
            layer: textLayer
        )
        animation.delegate = relay
        entries[event.id] = Entry(
            layer: textLayer,
            objectIdentity: objectIdentity,
            relay: relay
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.addSublayer(textLayer)
        if event.mode == .scrolling {
            textLayer.position.x = -textLayer.bounds.width / 2
        }
        textLayer.add(animation, forKey: "danmaku")
        CATransaction.commit()
    }

    public func remove(eventID: String) {
        removeEntry(eventID: eventID)
    }

    public func clearAll() {
        advanceEpoch()
        removeAllEntries()
    }

    public func setPlaybackRate(_ rate: Double) {
        let newRate = rate.isFinite ? max(rate, 0) : 0
        guard Double(rootLayer.speed) != newRate else { return }
        let mediaTime = CACurrentMediaTime()
        let parentTime = rootLayer.superlayer?
            .convertTime(mediaTime, from: nil)
            ?? mediaTime
        let localTime = rootLayer.convertTime(mediaTime, from: nil)
        rootLayer.beginTime = parentTime
        rootLayer.timeOffset = localTime
        rootLayer.speed = Float(newRate)
    }

    public func updateSurfaceSize(width: Double, height: Double) {
        advanceEpoch()
        removeAllEntries()
        surfaceSize = CGSize(
            width: max(width.isFinite ? width : 0, 0),
            height: max(height.isFinite ? height : 0, 0)
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.frame = CGRect(origin: .zero, size: surfaceSize)
        CATransaction.commit()
    }

    public func stop() {
        advanceEpoch()
        removeAllEntries()
        setPlaybackRate(0)
    }

    func textLayer(forEventID eventID: String) -> CATextLayer? {
        entries[eventID]?.layer
    }

    func objectIdentity(forEventID eventID: String) -> UInt64? {
        entries[eventID]?.objectIdentity
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

    private func attributedString(
        for event: DanmakuEvent
    ) -> NSAttributedString {
        NSAttributedString(
            string: event.text,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.white,
                .shadow: heavyInkShadow,
            ]
        )
    }

    private func makeTextLayer(
        for placement: DanmakuLanePlacement
    ) -> CATextLayer {
        let layer = CATextLayer()
        layer.string = attributedString(for: placement.request.event)
        layer.alignmentMode = .left
        layer.isWrapped = false
        layer.contentsScale = contentsScale
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
        layer: CATextLayer
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

    private func advanceEpoch() {
        renderEpoch &+= 1
    }

    private func removeAllEntries() {
        let oldEntries = entries
        entries.removeAll(keepingCapacity: false)
        for entry in oldEntries.values {
            entry.layer.removeAllAnimations()
            entry.layer.removeFromSuperlayer()
        }
    }

    private func removeEntry(eventID: String) {
        guard let entry = entries.removeValue(forKey: eventID) else {
            return
        }
        entry.layer.removeAllAnimations()
        entry.layer.removeFromSuperlayer()
    }
}
