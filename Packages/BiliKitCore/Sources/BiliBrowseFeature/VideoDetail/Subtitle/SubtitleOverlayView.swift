import SwiftUI

public struct SubtitleOverlayView: View {
    private let model: SubtitleViewModel

    public init(model: SubtitleViewModel) {
        self.model = model
    }

    public var body: some View {
        VStack {
            Spacer()
            if let text = model.currentCueText {
                Text(text)
                    .font(.title3.weight(.medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .accessibilityIdentifier("subtitle.overlay")
            }
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 54)
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
    }
}
