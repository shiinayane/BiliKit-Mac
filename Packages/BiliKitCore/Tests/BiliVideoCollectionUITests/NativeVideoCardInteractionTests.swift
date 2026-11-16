import AppKit
import BiliUI
import Testing

@testable import BiliVideoCollectionUI

/// 卡片的悬停描边、读屏值与不可用卡片的拒绝激活契约。
struct NativeVideoCardInteractionTests {
    /// 悬停描边按卡片自己的外观解析，不受当时绘制外观影响；卡片换主题后描边跟着换。
    @Test @MainActor
    func hoverStrokeFollowsTheCardAppearanceAcrossThemeChanges() throws {
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        func stroke(in appearance: NSAppearance) -> CGColor {
            var color = NSColor.secondaryLabelColor.cgColor
            appearance.performAsCurrentDrawingAppearance {
                color = NSColor.secondaryLabelColor.cgColor
            }
            return color
        }
        let card = NativeVideoCardView(frame: NSRect(x: 0, y: 0, width: 240, height: 220))
        card.appearance = dark

        light.performAsCurrentDrawingAppearance {
            card.setHovered(true)
        }
        #expect(card.layer?.borderColor == stroke(in: dark))

        light.performAsCurrentDrawingAppearance {
            card.appearance = light
        }
        #expect(card.layer?.borderColor == stroke(in: light))

        dark.performAsCurrentDrawingAppearance {
            card.appearance = dark
        }
        #expect(card.layer?.borderColor == stroke(in: dark))
    }

    /// 选中卡片的读屏值取自 BiliUI 字符串目录里“已选择”的译文，取消选中后清空。
    @Test @MainActor
    func selectedCardAnnouncesTheBiliUISelectedValue() {
        let card = NativeVideoCardView(frame: NSRect(x: 0, y: 0, width: 240, height: 220))

        card.setSelected(true)
        let value = card.accessibilityValue() as? String
        #expect(value == VideoCardAccessibilityText.selectedValue)
        #expect(["已选择", "已選擇", "選択済み", "Selected"].contains(value ?? ""))

        card.setSelected(false)
        #expect(card.accessibilityValue() == nil)
    }

    /// 不可用卡片读屏按下不激活、呈现为不可用并说明不可播放，悬停不画描边；改配为可用卡片后恢复。
    @Test @MainActor
    func unavailableCardRefusesActivationUntilReconfiguredAsAvailable() {
        let card = NativeVideoCardView(frame: NSRect(x: 0, y: 0, width: 240, height: 220))
        var activations = 0

        card.configure(
            presentation: Self.presentation(
                id: "BV1Gone",
                availability: .unavailable(badge: "已失效")
            ),
            hoverDidChange: { _ in },
            activation: { activations += 1 }
        )
        card.setHovered(true)

        #expect(!card.accessibilityPerformPress())
        #expect(activations == 0)
        #expect(!card.isAccessibilityEnabled())
        #expect(card.accessibilityValue() as? String == VideoCardAccessibilityText.unavailableValue)
        #expect(card.layer?.borderWidth == 0)

        card.configure(
            presentation: Self.presentation(id: "BV1Play", availability: .available),
            hoverDidChange: { _ in },
            activation: { activations += 1 }
        )

        #expect(card.accessibilityPerformPress())
        #expect(activations == 1)
        #expect(card.isAccessibilityEnabled())
        #expect(card.accessibilityValue() == nil)
    }

    /// 网格只把可进入播放的卡片当作可激活、可被鼠标选中；不在内容里的 ID 同样不可激活。
    @Test
    func gridContentsOnlyActivateAvailableCards() {
        let contents = NativeCardContents([
            Self.presentation(id: "BV1Play", availability: .available),
            Self.presentation(id: "BV1Gone", availability: .unavailable(badge: "课程"))
        ])

        #expect(contents.isActivatable("BV1Play"))
        #expect(!contents.isActivatable("BV1Gone"))
        #expect(!contents.isActivatable("BV1Missing"))
        #expect(
            contents.activatableIndexPaths(
                in: [
                    IndexPath(item: 0, section: 0), IndexPath(item: 1, section: 0),
                    IndexPath(item: 5, section: 0)
                ]
            ) == [IndexPath(item: 0, section: 0)]
        )
    }

    private static func presentation(
        id: String,
        availability: NativeVideoCardAvailability
    ) -> NativeVideoCardPresentation {
        NativeVideoCardPresentation(
            id: id,
            title: "手写卡片",
            coverURL: nil,
            avatarURL: nil,
            showsAvatar: false,
            footerLeadingText: "作者",
            accessibilityLabel: "手写卡片",
            availability: availability
        )
    }
}
