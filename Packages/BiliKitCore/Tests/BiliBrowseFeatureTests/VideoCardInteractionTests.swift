import Testing
@testable import BiliUI

struct VideoCardInteractionTests {
    @Test
    func idleCardHasNoSyntheticSurfaceOrTransform() {
        let appearance = VideoCardInteractionPolicy.appearance(for: state())

        #expect(appearance.surfaceOpacity == 0)
        #expect(appearance.strokeOpacity == 0)
        #expect(appearance.contentOpacity == 1)
        #expect(appearance.scale == 1)
    }

    @Test
    func hoverSelectionAndFocusExposeStableEmphasis() {
        for state in [
            state(isHovered: true),
            state(isSelected: true),
            state(isFocused: true),
        ] {
            let appearance = VideoCardInteractionPolicy.appearance(for: state)
            #expect(appearance.surfaceOpacity > 0)
            #expect(appearance.strokeOpacity == 1)
            #expect(appearance.scale == 1)
        }
    }

    @Test
    func reduceMotionRemovesPressedScaleButKeepsPressedFeedback() {
        let animated = VideoCardInteractionPolicy.appearance(
            for: state(isPressed: true)
        )
        let reduced = VideoCardInteractionPolicy.appearance(
            for: state(isPressed: true, reduceMotion: true)
        )

        #expect(animated.scale < 1)
        #expect(reduced.scale == 1)
        #expect(reduced.surfaceOpacity == animated.surfaceOpacity)
        #expect(reduced.contentOpacity == animated.contentOpacity)
    }

    @Test
    func increasedContrastStrengthensTheSameOutline() {
        let standard = VideoCardInteractionPolicy.appearance(
            for: state(isSelected: true)
        )
        let increased = VideoCardInteractionPolicy.appearance(
            for: state(isSelected: true, increasedContrast: true)
        )

        #expect(increased.strokeWidth > standard.strokeWidth)
        #expect(increased.strokeOpacity == standard.strokeOpacity)
    }

    private func state(
        isHovered: Bool = false,
        isPressed: Bool = false,
        isSelected: Bool = false,
        isFocused: Bool = false,
        increasedContrast: Bool = false,
        reduceMotion: Bool = false
    ) -> VideoCardInteractionState {
        VideoCardInteractionState(
            isHovered: isHovered,
            isPressed: isPressed,
            isSelected: isSelected,
            isFocused: isFocused,
            increasedContrast: increasedContrast,
            reduceMotion: reduceMotion
        )
    }
}
