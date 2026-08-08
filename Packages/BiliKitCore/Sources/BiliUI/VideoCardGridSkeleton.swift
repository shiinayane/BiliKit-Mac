import SwiftUI

/// 与生产视频卡片网格保持相同列数、间距和内容边距的首载骨架。
package struct VideoCardGridSkeleton: View {
    private let loadingLabel: String

    package init(loadingLabel: String) {
        self.loadingLabel = loadingLabel
    }

    package var body: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVGrid(
                    columns: VideoCardGridLayout.columns(
                        for: geometry.size.width
                    ),
                    alignment: .leading,
                    spacing: VideoCardGridLayout.verticalSpacing
                ) {
                    ForEach(0..<12, id: \.self) { _ in
                        VideoCardSkeleton()
                    }
                }
                .padding(VideoCardGridLayout.contentPadding)
            }
            .scrollDisabled(true)
            .scrollIndicators(.hidden)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loadingLabel)
    }
}

private struct VideoCardSkeleton: View {
    var body: some View {
        VideoCardLayout(showsLeading: true) {
            Rectangle()
                .fill(.quaternary)
        } leading: {
            Circle()
                .fill(.quaternary)
        } title: {
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .frame(height: 18)
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .frame(maxWidth: 180)
                    .frame(height: 18)
            }
        } footer: {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quinary)
                .frame(maxWidth: 130)
                .frame(height: 14)
        }
    }
}
