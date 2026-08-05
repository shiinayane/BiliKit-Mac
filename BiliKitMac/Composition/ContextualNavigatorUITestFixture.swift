#if DEBUG
    import SwiftUI

    /// 只为显式 UITest 启动路径提供 synthetic sidebar 内容。
    ///
    /// 它不描述生产评论/推荐领域，也不发起网络请求；按钮只把 BVID 意图送回生产
    /// `AppNavigationCoordinator`。
    @MainActor
    enum ContextualNavigatorUITestFixture {
        static let initialBVID = "fixture-video-A"

        static func sidebar(
            bvid: String,
            onSelectRecommendation: @escaping (String) -> Void
        ) -> AnyView {
            AnyView(
                ContextualNavigatorUITestSidebar(
                    bvid: bvid,
                    onSelectRecommendation: onSelectRecommendation
                )
                .id(bvid)
            )
        }
    }

    private struct ContextualNavigatorUITestSidebar: View {
        let bvid: String
        let onSelectRecommendation: (String) -> Void
        @State private var selectedPart = 1

        var body: some View {
            ScrollView {
                LazyVStack(
                    alignment: .leading,
                    spacing: 16,
                    pinnedViews: [.sectionHeaders]
                ) {
                    header
                    Section {
                        comments
                        recommendations
                    } header: {
                        partControls
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.bar)
                    }
                }
                .padding(16)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sidebar.contextual-fixture")
        }

        private var header: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text("Synthetic comments")
                    .font(.headline)
                Text(bvid)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("fixture.playback-identity")
            }
        }

        private var partControls: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("Parts")
                    .font(.subheadline.weight(.semibold))

                HStack {
                    ForEach(1...3, id: \.self) { part in
                        Button("P\(part)") {
                            selectedPart = part
                        }
                        .accessibilityIdentifier("fixture.part.\(part)")
                    }
                }

                Text("Selected P\(selectedPart)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("fixture.selected-part")
            }
        }

        private var comments: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Comments")
                    .font(.subheadline.weight(.semibold))

                ForEach(Self.syntheticComments) { comment in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(comment.author)
                            .font(.caption.weight(.semibold))
                        Text(comment.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(
                        .leading,
                        CGFloat(min(comment.replyDepth, 2)) * 16
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("fixture.comment.\(comment.id)")
                }
            }
        }

        @ViewBuilder
        private var recommendations: some View {
            if let recommendation = Self.recommendations[bvid] {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recommendations")
                        .font(.subheadline.weight(.semibold))

                    Button(recommendation.title) {
                        onSelectRecommendation(recommendation.bvid)
                    }
                    .accessibilityIdentifier(
                        "fixture.recommendation.\(recommendation.bvid)"
                    )
                }
            } else {
                Text("End of synthetic sequence")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("fixture.recommendation.end")
            }
        }

        private static let syntheticComments = [
            SyntheticComment(
                id: "primary",
                author: "Fixture Reader",
                body: "Synthetic content for navigation validation only.",
                replyDepth: 0
            ),
            SyntheticComment(
                id: "reply",
                author: "Fixture Reply",
                body: "这条回复不来自远端，也不代表生产评论能力。",
                replyDepth: 1
            ),
            SyntheticComment(
                id: "mixed",
                author: "Example 読者",
                body: "Mixed Chinese, English and 日本語 verify native wrapping.",
                replyDepth: 0
            ),
            SyntheticComment(
                id: "nested-reply",
                author: "Fixture Nested Reply",
                body: "Second-level hierarchy stays bounded in the sidebar.",
                replyDepth: 2
            ),
            SyntheticComment(
                id: "long",
                author: "长文本夹具",
                body: "这是一段用于形成独立滚动范围的合成长文本。它只验证分栏中的换行、滚动位置和媒体 identity 切换，不代表生产评论内容。",
                replyDepth: 0
            ),
            SyntheticComment(
                id: "last",
                author: "Fixture Last Reader",
                body: "The final synthetic comment makes scroll restoration observable.",
                replyDepth: 0
            ),
        ]

        private static let recommendations = [
            "fixture-video-A": SyntheticRecommendation(
                bvid: "fixture-video-B",
                title: "Continue to synthetic B"
            ),
            "fixture-video-B": SyntheticRecommendation(
                bvid: "fixture-video-C",
                title: "Continue to synthetic C"
            ),
        ]
    }

    private struct SyntheticComment: Identifiable {
        let id: String
        let author: String
        let body: String
        let replyDepth: Int
    }

    private struct SyntheticRecommendation {
        let bvid: String
        let title: String
    }
#endif
