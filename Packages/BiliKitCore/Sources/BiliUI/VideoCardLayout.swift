import SwiftUI

struct VideoCardLayout<
    Cover: View,
    Leading: View,
    Title: View,
    Footer: View
>: View {
    private let showsLeading: Bool
    private let cover: Cover
    private let leading: Leading
    private let title: Title
    private let footer: Footer

    init(
        showsLeading: Bool,
        @ViewBuilder cover: () -> Cover,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder title: () -> Title,
        @ViewBuilder footer: () -> Footer
    ) {
        self.showsLeading = showsLeading
        self.cover = cover()
        self.leading = leading()
        self.title = title()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            cover
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack(alignment: .top, spacing: 10) {
                if showsLeading {
                    leading
                        .frame(width: 34, height: 34)
                        .clipShape(Circle())
                }

                VStack(alignment: .leading, spacing: 6) {
                    title
                        .frame(maxWidth: .infinity, alignment: .leading)
                    footer
                }
            }
        }
    }
}
