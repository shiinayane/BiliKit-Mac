import AppKit
import CoreText
import QuartzCore

/// 卡片文字层的几何常量与单行测量；尾部宽度的测量与排版都经 `singleLineWidth`。
enum NativeVideoCardTextLayout {
    static let recommendationCapsuleHeight: CGFloat = 16
    static let recommendationCapsuleHorizontalPadding: CGFloat = 10
    static let recommendationCapsuleSpacing: CGFloat = 5
    static let recommendationCapsuleVerticalAdjustment: CGFloat = -1
    static let recommendationCapsuleTextVerticalAdjustment: CGFloat = -1
    /// 尾部图标与文字之间的间距。
    static let footerSymbolSpacing: CGFloat = 4

    /// 按“名字|字号”缓存的尾部图标；名字只来自观看历史的四种设备图标，字号随页脚字体，组合有限，
    /// 不设上限。
    @MainActor private static var footerSymbolCache: [String: NSImage] = [:]

    /// 尾部图标：按页脚字号取小号 SF Symbol，作为遮罩着色；同名同字号复用。
    @MainActor
    static func footerSymbol(named name: String, pointSize: CGFloat) -> NSImage? {
        let key = "\(name)|\(pointSize)"
        if let cached = footerSymbolCache[key] { return cached }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular, scale: .small)
            )
        footerSymbolCache[key] = image
        return image
    }
    static func singleLineWidth(
        _ text: String,
        font: NSFont
    ) -> CGFloat {
        singleLineWidth(text, font: ctFont(font))
    }

    static func singleLineWidth(
        _ text: String,
        font: CTFont
    ) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: text,
                attributes: [
                    kCTFontAttributeName as NSAttributedString.Key: font
                ]
            )
        )
        return ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }

    /// NSFont 与 CTFont toll-free bridged，直接转换即可，不需要缓存。
    static func ctFont(_ font: NSFont) -> CTFont {
        font as CTFont
    }

    static func recommendationCapsuleTextOffset(
        height: CGFloat,
        fontSize: CGFloat
    ) -> CGFloat {
        max(
            0,
            (height - fontSize) / 2
                - fontSize * 0.08
                + recommendationCapsuleTextVerticalAdjustment
        )
    }

    /// 关掉这些属性的隐式动画，卡片复用时文字、颜色与位置立即替换；字典值不是 Sendable，只读，故用
    /// `nonisolated(unsafe)`。
    nonisolated(unsafe) static let disabledLayerActions: [String: CAAction] = [
        "bounds": NSNull(),
        "backgroundColor": NSNull(),
        "borderColor": NSNull(),
        "borderWidth": NSNull(),
        "contents": NSNull(),
        "cornerRadius": NSNull(),
        "font": NSNull(),
        "fontSize": NSNull(),
        "foregroundColor": NSNull(),
        "hidden": NSNull(),
        "position": NSNull(),
        "string": NSNull()
    ]
}

/// 页脚尾部的文字层，普通样式也用它；只有推荐理由胶囊样式打开竖直居中：`CATextLayer` 只按顶边排字，
/// 居中时在绘制前整体下移。
@MainActor
final class NativeVideoVerticallyCenteredTextLayer: CATextLayer {
    /// 由渲染器在主线程写入；非隔离的 `draw(in:)` 要读它，故用 `nonisolated(unsafe)`。
    nonisolated(unsafe) var centersTextVertically = false

    override func draw(in context: CGContext) {
        guard centersTextVertically else {
            super.draw(in: context)
            return
        }
        let offset = NativeVideoCardTextLayout.recommendationCapsuleTextOffset(
            height: bounds.height,
            fontSize: fontSize
        )
        context.saveGState()
        context.translateBy(x: 0, y: offset)
        super.draw(in: context)
        context.restoreGState()
    }
}

/// 卡片标题与页脚的文字层组：持有 `CATextLayer` 与尾部图标层，按外观解析颜色并排版。
///
/// 文字一律是纯字符串，不用 `NSAttributedString`；父 layer 归卡片，`install` 时挂上，`reset` 清空复用前的内容。
@MainActor
final class NativeVideoCardTextRenderer {
    let titleLayer = NativeVideoCardTextRenderer.makeTextLayer(isWrapped: true)
    let footerLeadingLayer = NativeVideoCardTextRenderer.makeTextLayer(isWrapped: false)
    let footerTrailingLayer =
        NativeVideoCardTextRenderer.makeVerticallyCenteredTextLayer(
            alignmentMode: .right
        )
    /// 尾部文字前的图标：底色取页脚颜色，SF Symbol 作遮罩，随外观与文字同色。
    let footerTrailingIconLayer = CALayer()
    private let footerTrailingIconMask = CALayer()

    private var title = ""
    private var footerLeading = ""
    private var footerTrailing: String?
    private var footerTrailingSymbolName: String?
    private var footerTrailingStyle: NativeVideoCardFooterTrailingStyle = .plain
    private var footerTrailingWidthCache = NativeVideoSingleLineWidthCache()

    var showsFooterTrailing: Bool { footerTrailing != nil }
    var usesLeadingCapsule: Bool {
        showsFooterTrailing && footerTrailingStyle == .brandOutlinedCapsule
    }

    func install(in parentLayer: CALayer) {
        parentLayer.addSublayer(titleLayer)
        parentLayer.addSublayer(footerLeadingLayer)
        parentLayer.addSublayer(footerTrailingLayer)
        footerTrailingIconLayer.actions = NativeVideoCardTextLayout.disabledLayerActions
        footerTrailingIconMask.actions = NativeVideoCardTextLayout.disabledLayerActions
        footerTrailingIconMask.contentsGravity = .resizeAspect
        footerTrailingIconLayer.mask = footerTrailingIconMask
        parentLayer.addSublayer(footerTrailingIconLayer)
        reset()
    }

    func configure(
        title: String,
        footerLeading: String,
        footerTrailing: String?,
        footerTrailingSymbolName: String? = nil,
        footerTrailingStyle: NativeVideoCardFooterTrailingStyle = .plain
    ) {
        self.title = title
        self.footerLeading = footerLeading
        self.footerTrailing = footerTrailing
        self.footerTrailingSymbolName = footerTrailingSymbolName
        self.footerTrailingStyle = footerTrailingStyle
    }

    /// 全部文字层（含尾部图标）的不透明度；不可用卡片变暗时由卡片设置，`reset` 恢复为 1。
    func setContentOpacity(_ opacity: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [titleLayer, footerLeadingLayer, footerTrailingLayer, footerTrailingIconLayer]
        {
            layer.opacity = opacity
        }
        CATransaction.commit()
    }

    func reset() {
        setContentOpacity(1)
        title = ""
        footerLeading = ""
        footerTrailing = nil
        footerTrailingSymbolName = nil
        footerTrailingStyle = .plain
        footerTrailingWidthCache.reset()
        footerTrailingIconLayer.isHidden = true
        footerTrailingIconMask.contents = nil
        for textLayer in [titleLayer, footerLeadingLayer, footerTrailingLayer] {
            textLayer.removeAllAnimations()
            textLayer.string = nil
            textLayer.isHidden = true
        }
        footerTrailingLayer.backgroundColor = nil
        footerTrailingLayer.borderColor = nil
        footerTrailingLayer.borderWidth = 0
        footerTrailingLayer.cornerRadius = 0
        footerTrailingLayer.alignmentMode = .right
        footerTrailingLayer.centersTextVertically = false
    }

    func trailingWidth(font: NSFont) -> CGFloat {
        guard let footerTrailing else { return 0 }
        let font: CTFont =
            switch footerTrailingStyle {
            case .plain: resolvedFooterFont(for: font)
            case .brandOutlinedCapsule: resolvedCapsuleFont(for: font)
            case .nowPlaying: NativeNowPlayingAppearance.markerFont(for: font) as CTFont
            }
        let measurementVariant =
            "\(footerTrailingStyle)|\(CTFontCopyPostScriptName(font))|\(CTFontGetSize(font))"
        let textWidth = footerTrailingWidthCache.width(
            for: footerTrailing,
            variant: measurementVariant
        ) {
            NativeVideoCardTextLayout.singleLineWidth(footerTrailing, font: font)
        }
        switch footerTrailingStyle {
        case .plain, .nowPlaying:
            guard let symbol = trailingSymbol(font: font) else { return textWidth }
            return textWidth + ceil(symbol.size.width)
                + NativeVideoCardTextLayout.footerSymbolSpacing
        case .brandOutlinedCapsule:
            return textWidth
                + NativeVideoCardTextLayout.recommendationCapsuleHorizontalPadding
        }
    }

    func layout(
        titleFrame: NSRect,
        footerLeadingFrame: NSRect,
        footerTrailingFrame: NSRect,
        titleFont: NSFont,
        footerFont: NSFont,
        appearance: NSAppearance,
        contentsScale: CGFloat
    ) {
        let colors = Self.resolvedColors(appearance: appearance)
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        titleLayer.frame = titleFrame
        titleLayer.contentsScale = contentsScale
        titleLayer.font = resolvedTitleFont(for: titleFont)
        titleLayer.fontSize = titleFont.pointSize
        titleLayer.foregroundColor = colors.title.cgColor
        titleLayer.string = title.isEmpty ? nil : title
        titleLayer.isHidden = title.isEmpty

        let footerCTFont = resolvedFooterFont(for: footerFont)
        for footerLayer in [footerLeadingLayer, footerTrailingLayer] {
            footerLayer.contentsScale = contentsScale
            footerLayer.font = footerCTFont
            footerLayer.fontSize = footerFont.pointSize
            footerLayer.foregroundColor = colors.footer.cgColor
        }
        footerLeadingLayer.frame = footerLeadingFrame
        footerLeadingLayer.string = footerLeading.isEmpty ? nil : footerLeading
        footerLeadingLayer.isHidden = footerLeading.isEmpty
        footerTrailingLayer.frame = footerTrailingFrame
        footerTrailingLayer.string = footerTrailing
        footerTrailingLayer.isHidden = footerTrailing == nil
        let markerCTFont = NativeNowPlayingAppearance.markerFont(for: footerFont) as CTFont
        layoutTrailingIcon(
            in: footerTrailingFrame,
            font: footerTrailingStyle == .nowPlaying ? markerCTFont : footerCTFont,
            color: footerTrailingStyle == .nowPlaying ? colors.accent : colors.footer,
            contentsScale: contentsScale
        )
        switch footerTrailingStyle {
        case .plain:
            footerTrailingLayer.font = footerCTFont
            footerTrailingLayer.fontSize = footerFont.pointSize
            footerTrailingLayer.alignmentMode = .right
            footerTrailingLayer.centersTextVertically = false
            footerTrailingLayer.setNeedsDisplay()
            footerTrailingLayer.foregroundColor = colors.footer.cgColor
            footerTrailingLayer.backgroundColor = nil
            footerTrailingLayer.borderColor = nil
            footerTrailingLayer.borderWidth = 0
            footerTrailingLayer.cornerRadius = 0
        case .brandOutlinedCapsule:
            let capsuleFont = resolvedCapsuleFont(for: footerFont)
            footerTrailingLayer.font = capsuleFont
            footerTrailingLayer.fontSize = CTFontGetSize(capsuleFont)
            footerTrailingLayer.alignmentMode = .center
            footerTrailingLayer.centersTextVertically = true
            footerTrailingLayer.setNeedsDisplay()
            footerTrailingLayer.foregroundColor = colors.brand.cgColor
            footerTrailingLayer.backgroundColor = NSColor.clear.cgColor
            footerTrailingLayer.borderColor = colors.brand.cgColor
            footerTrailingLayer.borderWidth = 1 / max(1, contentsScale)
            footerTrailingLayer.cornerRadius = footerTrailingFrame.height / 2
        case .nowPlaying:
            footerTrailingLayer.font = markerCTFont
            footerTrailingLayer.fontSize = CTFontGetSize(markerCTFont)
            footerTrailingLayer.alignmentMode = .right
            footerTrailingLayer.centersTextVertically = false
            footerTrailingLayer.setNeedsDisplay()
            footerTrailingLayer.foregroundColor = colors.accent.cgColor
            footerTrailingLayer.backgroundColor = nil
            footerTrailingLayer.borderColor = nil
            footerTrailingLayer.borderWidth = 0
            footerTrailingLayer.cornerRadius = 0
        }

        CATransaction.commit()
    }

    private func trailingSymbol(font: CTFont) -> NSImage? {
        guard footerTrailingStyle != .brandOutlinedCapsule, footerTrailing != nil,
            let footerTrailingSymbolName
        else { return nil }
        return NativeVideoCardTextLayout.footerSymbol(
            named: footerTrailingSymbolName,
            pointSize: CTFontGetSize(font)
        )
    }

    /// 图标贴在尾部区域左缘，竖直方向对齐文字的大写字母中线；文字区域相应右移，宽度不足时只截断文字。
    private func layoutTrailingIcon(
        in trailingFrame: NSRect,
        font: CTFont,
        color: NSColor,
        contentsScale: CGFloat
    ) {
        guard let symbol = trailingSymbol(font: font) else {
            footerTrailingIconLayer.isHidden = true
            footerTrailingIconMask.contents = nil
            return
        }
        let size = NSSize(width: ceil(symbol.size.width), height: ceil(symbol.size.height))
        let textCenterY =
            trailingFrame.minY + CTFontGetAscent(font) - CTFontGetCapHeight(font) / 2
        let scale = max(1, contentsScale)
        footerTrailingIconLayer.frame = NSRect(
            x: round(trailingFrame.minX * scale) / scale,
            y: round((textCenterY - size.height / 2) * scale) / scale,
            width: size.width,
            height: size.height
        )
        footerTrailingIconLayer.backgroundColor = color.cgColor
        footerTrailingIconMask.frame = footerTrailingIconLayer.bounds
        footerTrailingIconMask.contentsScale = scale
        footerTrailingIconMask.contents = symbol.layerContents(forContentsScale: scale)
        footerTrailingIconLayer.isHidden = false
        let iconAdvance = size.width + NativeVideoCardTextLayout.footerSymbolSpacing
        var textFrame = trailingFrame
        textFrame.origin.x += iconAdvance
        textFrame.size.width = max(0, textFrame.width - iconAdvance)
        footerTrailingLayer.frame = textFrame
    }

    private func resolvedTitleFont(for font: NSFont) -> CTFont {
        font as CTFont
    }

    private func resolvedFooterFont(for font: NSFont) -> CTFont {
        font as CTFont
    }

    private func resolvedCapsuleFont(for footerFont: NSFont) -> CTFont {
        NSFont.systemFont(
            ofSize: min(11, max(9, footerFont.pointSize - 2)),
            weight: .medium
        ) as CTFont
    }

    private static func makeTextLayer(
        isWrapped: Bool,
        alignmentMode: CATextLayerAlignmentMode = .left
    ) -> CATextLayer {
        let layer = CATextLayer()
        configureTextLayer(
            layer,
            isWrapped: isWrapped,
            alignmentMode: alignmentMode
        )
        return layer
    }

    private static func makeVerticallyCenteredTextLayer(
        alignmentMode: CATextLayerAlignmentMode
    ) -> NativeVideoVerticallyCenteredTextLayer {
        let layer = NativeVideoVerticallyCenteredTextLayer()
        configureTextLayer(
            layer,
            isWrapped: false,
            alignmentMode: alignmentMode
        )
        return layer
    }

    private static func configureTextLayer(
        _ layer: CATextLayer,
        isWrapped: Bool,
        alignmentMode: CATextLayerAlignmentMode
    ) {
        layer.isWrapped = isWrapped
        layer.truncationMode = .end
        layer.alignmentMode = alignmentMode
        layer.actions = NativeVideoCardTextLayout.disabledLayerActions
    }

    /// 解析到 `appearance` 下的文字颜色：标题、页脚按外观名缓存，品牌色只换算一次，强调色每次现取。
    ///
    /// 每张卡片每次 `layout()` 都要取，改宽度时每帧都排；每次在外观里逐个换算颜色空间是可观的开销。标题与页脚色只随外观
    /// （深浅色、高对比度，名字各不相同）变化；强调色跟系统设置走，运行中可以改而外观名不变，所以不缓存。
    private static func resolvedColors(
        appearance: NSAppearance
    ) -> (title: NSColor, footer: NSColor, brand: NSColor, accent: NSColor) {
        let labels: (title: NSColor, footer: NSColor)
        if let cached = labelColors[appearance.name] {
            labels = cached
        } else {
            var title = NSColor.labelColor
            var footer = NSColor.secondaryLabelColor
            appearance.performAsCurrentDrawingAppearance {
                title = NSColor.labelColor.usingColorSpace(.deviceRGB) ?? .labelColor
                footer =
                    NSColor.secondaryLabelColor.usingColorSpace(.deviceRGB) ?? .secondaryLabelColor
            }
            labels = (title, footer)
            labelColors[appearance.name] = labels
        }
        var accent = NativeNowPlayingAppearance.markerColor
        appearance.performAsCurrentDrawingAppearance {
            accent = accent.usingColorSpace(.deviceRGB) ?? accent
        }
        return (labels.title, labels.footer, brandColor, accent)
    }

    /// 按外观名缓存的标题与页脚色；外观名只有深浅色与高对比度几种，条目数有界。
    private static var labelColors: [NSAppearance.Name: (title: NSColor, footer: NSColor)] = [:]

    /// 品牌色：固定的 sRGB 值，与外观无关。
    private static let brandColor: NSColor = {
        let color = NSColor(srgbRed: 0, green: 174.0 / 255.0, blue: 236.0 / 255.0, alpha: 1)
        return color.usingColorSpace(.deviceRGB) ?? color
    }()
}
