import AppKit
import BiliUI
import Testing

@testable import BiliVideoCollectionUI

/// 卡片的悬停描边（被别的视图盖住的部分不算悬停）、读屏值与不可用卡片的拒绝激活契约。
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

    /// 卡片被盖在别的视图底下的部分（播放页横排伸到侧栏底下）不画悬停：指针从被盖住的部分进入时不画，移到露出的
    /// 部分才画，移回被盖住的部分又撤掉。
    @Test @MainActor
    func coveredPartOfTheCardTakesNoHover() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = root
        defer { window.contentView = NSView() }
        let card = NativeVideoCardView(frame: NSRect(x: 0, y: 0, width: 240, height: 220))
        card.configure(
            presentation: Self.presentation(id: "BV1Play", availability: .available),
            hoverDidChange: { _ in },
            activation: {}
        )
        root.addSubview(card)
        // 后加的兄弟视图排在上面，盖住卡片左半边。
        root.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 300)))
        let covered = NSPoint(x: 60, y: 100)
        let exposed = NSPoint(x: 180, y: 100)

        card.mouseEntered(with: Self.pointerEvent(.mouseEntered, at: covered, in: window))
        #expect(card.layer?.borderWidth == 0)

        card.mouseMoved(with: Self.pointerEvent(.mouseMoved, at: exposed, in: window))
        #expect((card.layer?.borderWidth ?? 0) > 0)

        card.mouseMoved(with: Self.pointerEvent(.mouseMoved, at: covered, in: window))
        #expect(card.layer?.borderWidth == 0)
    }

    @MainActor
    private static func pointerEvent(
        _ type: NSEvent.EventType,
        at location: NSPoint,
        in window: NSWindow
    ) -> NSEvent {
        let event =
            type == .mouseMoved
            ? NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 0,
                pressure: 0
            )
            : NSEvent.enterExitEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                trackingNumber: 0,
                userData: nil
            )
        guard let event else { preconditionFailure("无法构造指针事件") }
        return event
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
