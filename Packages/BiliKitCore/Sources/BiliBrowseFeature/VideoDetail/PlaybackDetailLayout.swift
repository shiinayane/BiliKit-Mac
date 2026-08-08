import SwiftUI

struct PlaybackDetailLayout<
    Metadata: View,
    Player: View,
    Controls: View,
    Related: View
>: View {
    private let metadata: Metadata
    private let player: Player
    private let controls: Controls
    private let related: Related

    init(
        @ViewBuilder metadata: () -> Metadata,
        @ViewBuilder player: () -> Player,
        @ViewBuilder controls: () -> Controls,
        @ViewBuilder related: () -> Related
    ) {
        self.metadata = metadata()
        self.player = player()
        self.controls = controls()
        self.related = related()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PlaybackPageLayout.sectionSpacing) {
            metadata
            player

            Divider()
            controls

            related
                .padding(
                    .horizontal,
                    -PlaybackPageLayout.horizontalContentPadding
                )
        }
        .padding(
            .horizontal,
            PlaybackPageLayout.horizontalContentPadding
        )
        .padding(
            .vertical,
            PlaybackPageLayout.verticalContentPadding
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
