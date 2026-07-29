import SwiftUI

package struct VideoCardInteractionState: Sendable, Equatable {
    package let isHovered: Bool
    package let isPressed: Bool
    package let increasedContrast: Bool
    package let reduceMotion: Bool

    package init(
        isHovered: Bool,
        isPressed: Bool,
        increasedContrast: Bool,
        reduceMotion: Bool
    ) {
        self.isHovered = isHovered
        self.isPressed = isPressed
        self.increasedContrast = increasedContrast
        self.reduceMotion = reduceMotion
    }
}

package struct VideoCardInteractionAppearance: Sendable, Equatable {
    package let surfaceOpacity: Double
    package let strokeOpacity: Double
    package let strokeWidth: CGFloat
    package let contentOpacity: Double
    package let scale: CGFloat
}

package enum VideoCardInteractionPolicy {
    package static func appearance(
        for state: VideoCardInteractionState
    ) -> VideoCardInteractionAppearance {
        VideoCardInteractionAppearance(
            surfaceOpacity: state.isPressed ? 0.14 : (state.isHovered ? 0.08 : 0),
            strokeOpacity: state.isHovered ? 1 : 0,
            strokeWidth: state.increasedContrast ? 2 : 1,
            contentOpacity: state.isPressed ? 0.82 : 1,
            scale: state.isPressed && !state.reduceMotion ? 0.985 : 1
        )
    }
}

package struct VideoCardButtonStyle: ButtonStyle {
    package init() {}

    package func makeBody(configuration: Configuration) -> some View {
        VideoCardInteractionBody(
            configuration: configuration
        )
    }
}

private struct VideoCardInteractionBody: View {
    let configuration: ButtonStyle.Configuration

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var isHovered = false

    private var appearance: VideoCardInteractionAppearance {
        VideoCardInteractionPolicy.appearance(
            for: VideoCardInteractionState(
                isHovered: isHovered,
                isPressed: configuration.isPressed,
                increasedContrast: colorSchemeContrast == .increased,
                reduceMotion: reduceMotion
            )
        )
    }

    var body: some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.primary.opacity(appearance.surfaceOpacity))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        Color.secondary,
                        lineWidth: appearance.strokeWidth
                    )
                    .opacity(appearance.strokeOpacity)
            }
            .opacity(appearance.contentOpacity)
            .scaleEffect(appearance.scale)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: appearance
            )
            .onHover { isHovered = $0 }
    }
}
