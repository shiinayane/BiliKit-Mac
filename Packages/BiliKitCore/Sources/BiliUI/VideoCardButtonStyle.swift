import SwiftUI

package struct VideoCardInteractionState: Sendable, Equatable {
    package let isHovered: Bool
    package let isPressed: Bool
    package let isSelected: Bool
    package let isFocused: Bool
    package let increasedContrast: Bool
    package let reduceMotion: Bool

    package init(
        isHovered: Bool,
        isPressed: Bool,
        isSelected: Bool,
        isFocused: Bool,
        increasedContrast: Bool,
        reduceMotion: Bool
    ) {
        self.isHovered = isHovered
        self.isPressed = isPressed
        self.isSelected = isSelected
        self.isFocused = isFocused
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
        let isEmphasized =
            state.isSelected || state.isFocused || state.isHovered
        return VideoCardInteractionAppearance(
            surfaceOpacity: state.isPressed ? 0.14 : (isEmphasized ? 0.08 : 0),
            strokeOpacity: isEmphasized ? 1 : 0,
            strokeWidth: state.increasedContrast ? 2 : 1,
            contentOpacity: state.isPressed ? 0.82 : 1,
            scale: state.isPressed && !state.reduceMotion ? 0.985 : 1
        )
    }
}

package struct VideoCardButtonStyle: ButtonStyle {
    private let isSelected: Bool

    package init(isSelected: Bool) {
        self.isSelected = isSelected
    }

    package func makeBody(configuration: Configuration) -> some View {
        VideoCardInteractionBody(
            configuration: configuration,
            isSelected: isSelected
        )
    }
}

private struct VideoCardInteractionBody: View {
    let configuration: ButtonStyle.Configuration
    let isSelected: Bool

    @Environment(\.accessibilityDifferentiateWithoutColor)
    private var differentiateWithoutColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.isFocused) private var isFocused
    @State private var isHovered = false

    private var appearance: VideoCardInteractionAppearance {
        VideoCardInteractionPolicy.appearance(
            for: VideoCardInteractionState(
                isHovered: isHovered,
                isPressed: configuration.isPressed,
                isSelected: isSelected,
                isFocused: isFocused,
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
                        isSelected || isFocused
                            ? Color.accentColor
                            : Color.secondary,
                        lineWidth: appearance.strokeWidth
                    )
                    .opacity(appearance.strokeOpacity)
            }
            .overlay(alignment: .topTrailing) {
                if isSelected && differentiateWithoutColor {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .font(.title3)
                        .padding(8)
                        .accessibilityHidden(true)
                }
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
