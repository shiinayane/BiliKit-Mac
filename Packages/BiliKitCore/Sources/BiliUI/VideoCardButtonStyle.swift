import SwiftUI

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
        VideoCardInteractionAppearance(
            surfaceOpacity: configuration.isPressed ? 0.14 : (isHovered ? 0.08 : 0),
            strokeOpacity: isHovered ? 1 : 0,
            strokeWidth: colorSchemeContrast == .increased ? 2 : 1,
            contentOpacity: configuration.isPressed ? 0.82 : 1,
            scale: configuration.isPressed && !reduceMotion ? 0.985 : 1
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

private struct VideoCardInteractionAppearance: Equatable {
    let surfaceOpacity: Double
    let strokeOpacity: Double
    let strokeWidth: CGFloat
    let contentOpacity: Double
    let scale: CGFloat
}
