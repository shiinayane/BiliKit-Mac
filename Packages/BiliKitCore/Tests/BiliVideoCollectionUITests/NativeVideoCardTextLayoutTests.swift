import AppKit
import QuartzCore
import Testing

@testable import BiliVideoCollectionUI

/// 卡片文字层复用时不残留上一张卡片的文字与样式。
///
/// 标题与页脚以纯字符串绘制，换配置与 `reset` 清掉文字、胶囊样式与尾部图标；尾部图标计入尾部宽度；卡片 `reset` 后
/// 仍是读屏按钮，标签与说明清空。
struct NativeVideoCardTextLayoutTests {
    @Test @MainActor
    func rendererUsesPlainStringsAndClearsReusedContent() throws {
        let renderer = NativeVideoCardTextRenderer()
        let parent = CALayer()
        renderer.install(in: parent)
        renderer.configure(
            title: "旧标题 old 👨‍👩‍👧‍👦",
            footerLeading: "旧作者",
            footerTrailing: "昨天"
        )
        let appearance = try #require(NSAppearance(named: .aqua))
        layout(renderer, scale: 2, appearance: appearance)

        #expect(renderer.titleLayer.string as? String == "旧标题 old 👨‍👩‍👧‍👦")
        #expect(renderer.footerLeadingLayer.string as? String == "旧作者")
        #expect(renderer.footerTrailingLayer.string as? String == "昨天")
        #expect(!(renderer.titleLayer.string is NSAttributedString))
        #expect(renderer.titleLayer.isWrapped)
        #expect(renderer.titleLayer.truncationMode == .end)
        #expect(!renderer.footerLeadingLayer.isWrapped)
        #expect(renderer.footerLeadingLayer.truncationMode == .end)
        #expect(renderer.footerTrailingLayer.alignmentMode == .right)
        #expect(renderer.titleLayer.contentsScale == 2)
        let footerFont = renderer.footerTrailingLayer.font as! CTFont
        #expect(
            renderer.trailingWidth(font: .preferredFont(forTextStyle: .body))
                == NativeVideoCardTextLayout.singleLineWidth("昨天", font: footerFont)
        )
        let cachedTitleFont = renderer.titleLayer.font
        let cachedFooterFont = renderer.footerTrailingLayer.font
        layout(renderer, scale: 2, appearance: appearance)
        #expect(renderer.titleLayer.font === cachedTitleFont)
        #expect(renderer.footerTrailingLayer.font === cachedFooterFont)

        renderer.configure(
            title: "推荐视频",
            footerLeading: "作者",
            footerTrailing: "正在流行",
            footerTrailingStyle: .brandOutlinedCapsule
        )
        layout(renderer, scale: 2, appearance: appearance)
        #expect(renderer.footerTrailingLayer.borderWidth > 0)
        renderer.configure(
            title: "复用视频",
            footerLeading: "新作者",
            footerTrailing: "昨天"
        )
        layout(renderer, scale: 2, appearance: appearance)
        #expect(renderer.footerTrailingLayer.alignmentMode == .right)
        #expect(renderer.footerTrailingLayer.borderColor == nil)
        #expect(renderer.footerTrailingLayer.borderWidth == 0)
        #expect(renderer.footerTrailingLayer.cornerRadius == 0)
        #expect(!renderer.footerTrailingLayer.centersTextVertically)

        renderer.configure(
            title: "新标题",
            footerLeading: "新作者",
            footerTrailing: nil
        )
        layout(renderer, scale: 1, appearance: appearance)
        #expect(renderer.titleLayer.string as? String == "新标题")
        #expect(renderer.footerLeadingLayer.string as? String == "新作者")
        #expect(renderer.footerTrailingLayer.string == nil)
        #expect(renderer.footerTrailingLayer.isHidden)
        #expect(renderer.titleLayer.contentsScale == 1)

        renderer.reset()
        for layer in [
            renderer.titleLayer,
            renderer.footerLeadingLayer,
            renderer.footerTrailingLayer
        ] {
            #expect(layer.string == nil)
            #expect(layer.isHidden)
            #expect(layer.animationKeys()?.isEmpty ?? true)
        }
    }

    /// 尾部图标算进尾部宽度，贴在尾部区域左缘，文字随之右移；胶囊样式与复用后不显示图标。
    @Test @MainActor
    func trailingSymbolSitsBeforeTheTextAndCountsTowardItsWidth() throws {
        let renderer = NativeVideoCardTextRenderer()
        let parent = CALayer()
        renderer.install(in: parent)
        let appearance = try #require(NSAppearance(named: .aqua))
        let font = NSFont.preferredFont(forTextStyle: .body)
        renderer.configure(title: "标题", footerLeading: "作者", footerTrailing: "昨天")
        let plainWidth = renderer.trailingWidth(font: font)

        renderer.configure(
            title: "标题",
            footerLeading: "作者",
            footerTrailing: "昨天",
            footerTrailingSymbolName: "smartphone"
        )
        let symbol = try #require(
            NativeVideoCardTextLayout.footerSymbol(named: "smartphone", pointSize: font.pointSize)
        )
        layout(renderer, scale: 2, appearance: appearance)

        let advance = ceil(symbol.size.width) + NativeVideoCardTextLayout.footerSymbolSpacing
        #expect(renderer.trailingWidth(font: font) == plainWidth + advance)
        #expect(!renderer.footerTrailingIconLayer.isHidden)
        #expect(renderer.footerTrailingIconLayer.frame.minX == 152)
        #expect(renderer.footerTrailingLayer.frame.minX == 152 + advance)
        #expect(renderer.footerTrailingLayer.frame.maxX == 224)

        renderer.configure(
            title: "推荐视频",
            footerLeading: "作者",
            footerTrailing: "正在流行",
            footerTrailingSymbolName: "smartphone",
            footerTrailingStyle: .brandOutlinedCapsule
        )
        layout(renderer, scale: 2, appearance: appearance)
        #expect(renderer.footerTrailingIconLayer.isHidden)

        renderer.reset()
        #expect(renderer.footerTrailingIconLayer.isHidden)
    }

    @Test @MainActor
    func cardRetainsAggregatedButtonAccessibilityAcrossReset() {
        let card = NativeVideoCardView(
            frame: NSRect(x: 0, y: 0, width: 224, height: 210)
        )
        card.configure(
            presentation: NativeVideoCardPresentation(
                id: "BV-text-layer",
                title: "标题",
                coverURL: nil,
                avatarURL: nil,
                showsAvatar: false,
                coverMetrics: [],
                coverTrailingText: nil,
                footerLeadingText: "作者",
                footerTrailingText: nil,
                accessibilityLabel: "标题，作者",
                accessibilityHelp: "播放视频"
            ),
            hoverDidChange: { _ in },
            activation: {}
        )

        #expect(card.accessibilityRole() == .button)
        #expect(card.accessibilityLabel() == "标题，作者")
        #expect(card.accessibilityHelp() == "播放视频")

        card.reset()
        #expect(card.accessibilityRole() == .button)
        #expect(card.accessibilityLabel() == nil)
        #expect(card.accessibilityHelp() == nil)
        #expect(card.accessibilityValue() == nil)
    }

    @MainActor
    private func layout(
        _ renderer: NativeVideoCardTextRenderer,
        scale: CGFloat,
        appearance: NSAppearance
    ) {
        renderer.layout(
            titleFrame: NSRect(x: 44, y: 136, width: 180, height: 47),
            footerLeadingFrame: NSRect(x: 44, y: 189, width: 100, height: 21),
            footerTrailingFrame: NSRect(x: 152, y: 189, width: 72, height: 21),
            titleFont: .systemFont(
                ofSize: NSFont.preferredFont(forTextStyle: .title3).pointSize,
                weight: .medium
            ),
            footerFont: .preferredFont(forTextStyle: .body),
            appearance: appearance,
            contentsScale: scale
        )
    }
}
