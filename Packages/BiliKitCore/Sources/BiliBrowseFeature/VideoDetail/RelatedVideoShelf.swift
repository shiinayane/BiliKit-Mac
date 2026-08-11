import BiliUI
import Foundation
import SwiftUI

struct RelatedVideoShelfItem: Identifiable, Equatable, Sendable {
    let bvid: String
    let title: String
    let coverURL: URL?
    let ownerName: String
    let viewCount: Int64
    let danmakuCount: Int64
    let durationSeconds: Int?

    var id: String { bvid }
}

struct RelatedVideoShelfSelection {
    let onSelect: (String) -> Void

    func select(_ item: RelatedVideoShelfItem) {
        onSelect(item.bvid)
    }
}

enum RelatedVideoShelfState: Equatable, Sendable {
    case loading
    case loaded([RelatedVideoShelfItem])
    case empty
    case failure

    var itemCount: Int {
        if case .loaded(let items) = self {
            return items.count
        }
        return 0
    }
}

/// 播放详情下方的横向相关推荐 shelf。
///
/// 只接收稳定展示状态与 BVID 选择意图；滚动分页、hover 控件和 Reduce Motion
/// 封装在视图内，不拥有推荐请求、导航路径、播放器或认证生命周期。
struct RelatedVideoShelf: View {
    private static let cardWidth: CGFloat = 224
    private static let cardSpacing: CGFloat = 16
    private static let contentPadding: CGFloat = 40

    let state: RelatedVideoShelfState
    let selection: RelatedVideoShelfSelection
    let onRetry: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var shelfHeight: CGFloat = 232
    @State private var isHovered = false
    @State private var viewportWidth: CGFloat = 0
    @State private var visibleItemIDs: [String] = []
    @FocusState private var focusedPageDirection: RecommendationShelfPageDirection?
    @FocusState private var focusedItemID: String?

    init(
        state: RelatedVideoShelfState,
        onSelect: @escaping (String) -> Void,
        onRetry: @escaping () -> Void
    ) {
        self.state = state
        selection = RelatedVideoShelfSelection(onSelect: onSelect)
        self.onRetry = onRetry
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
                .padding(.horizontal, Self.contentPadding)

            ZStack(alignment: .topLeading) {
                content
                    .transition(.opacity)
            }
            .animation(
                LoadingStateTransition.animation(reduceMotion: reduceMotion),
                value: contentVisualPhase
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var contentVisualPhase: LoadingVisualPhase {
        switch state {
        case .loading:
            .loading
        case .loaded(let items) where items.isEmpty:
            .empty
        case .loaded:
            .content
        case .empty:
            .empty
        case .failure:
            .failure
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("相关推荐")
                .font(.title3.weight(.semibold))

            Text("继续观看")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            loadingShelf
        case .loaded(let items) where items.isEmpty:
            unavailableShelf
        case .loaded(let items):
            loadedShelf(items)
        case .empty:
            unavailableShelf
        case .failure:
            failureShelf
        }
    }

    private func loadedShelf(
        _ items: [RelatedVideoShelfItem]
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Self.cardSpacing) {
                    ForEach(items) { item in
                        card(item)
                            .id(item.id)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(
                .horizontal,
                Self.contentPadding,
                for: .scrollContent
            )
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.containerSize.width
            } action: { _, width in
                viewportWidth = width
            }
            .onScrollTargetVisibilityChange(
                idType: String.self,
                threshold: 0.5
            ) { identifiers in
                visibleItemIDs = identifiers
            }
            .overlay {
                pageControls(items, proxy: proxy)
            }
            .onHover { hovered in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                    isHovered = hovered
                }
            }
            .onChange(of: focusedItemID) { _, itemID in
                guard let itemID else { return }
                if reduceMotion {
                    proxy.scrollTo(itemID, anchor: .center)
                } else {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(itemID, anchor: .center)
                    }
                }
            }
            .frame(height: shelfHeight)
            .accessibilityLabel("横向相关推荐")
        }
    }

    private func card(_ item: RelatedVideoShelfItem) -> some View {
        Button {
            selection.select(item)
        } label: {
            RelatedVideoCard(
                item: item,
                isFocused: focusedItemID == item.id
            )
            .frame(width: Self.cardWidth)
        }
        .buttonStyle(VideoCardButtonStyle())
        .focused($focusedItemID, equals: item.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityLabel)
        .accessibilityHint("播放并替换当前视频")
    }

    private var loadingShelf: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Self.cardSpacing) {
                ForEach(0..<4, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 10) {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.quaternary)
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.quaternary)
                            .frame(height: 18)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.quinary)
                            .frame(width: 110, height: 14)
                    }
                    .frame(width: Self.cardWidth)
                }
            }
        }
        .contentMargins(
            .horizontal,
            Self.contentPadding,
            for: .scrollContent
        )
        .scrollDisabled(true)
        .scrollIndicators(.hidden)
        .frame(height: shelfHeight, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在加载相关推荐")
    }

    private var failureShelf: some View {
        VStack(spacing: 10) {
            Label("相关推荐加载失败", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Button("重试", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    private var unavailableShelf: some View {
        ContentUnavailableView(
            "暂无相关推荐",
            systemImage: "rectangle.stack"
        )
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    private func pageControls(
        _ items: [RelatedVideoShelfItem],
        proxy: ScrollViewProxy
    ) -> some View {
        HStack {
            if pageTarget(.backward, in: items) != nil {
                pageButton(.backward, items: items, proxy: proxy)
            }

            Spacer(minLength: 0)

            if pageTarget(.forward, in: items) != nil {
                pageButton(.forward, items: items, proxy: proxy)
            }
        }
        .safeAreaPadding(.horizontal, 12)
        .opacity(showsPageControls ? 1 : 0)
        .allowsHitTesting(showsPageControls)
    }

    private var showsPageControls: Bool {
        isHovered || focusedItemID != nil || focusedPageDirection != nil
    }

    private func pageButton(
        _ direction: RecommendationShelfPageDirection,
        items: [RelatedVideoShelfItem],
        proxy: ScrollViewProxy
    ) -> some View {
        Button {
            guard let target = pageTarget(direction, in: items) else { return }
            if reduceMotion {
                proxy.scrollTo(items[target].id, anchor: .leading)
            } else {
                withAnimation(.easeInOut(duration: 0.32)) {
                    proxy.scrollTo(items[target].id, anchor: .leading)
                }
            }
        } label: {
            Image(systemName: direction.symbol)
                .font(.headline.weight(.semibold))
                .frame(width: 34, height: 44)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(.separator.opacity(0.55), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
        .help(direction.accessibilityLabel)
        .accessibilityLabel(direction.accessibilityLabel)
        .focused($focusedPageDirection, equals: direction)
    }

    private func pageTarget(
        _ direction: RecommendationShelfPageDirection,
        in items: [RelatedVideoShelfItem]
    ) -> Int? {
        let indexByID = Dictionary(
            uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) }
        )
        let visibleIndices = visibleItemIDs.compactMap { indexByID[$0] }
        return RelatedVideoShelfPaging(
            itemCount: items.count,
            cardWidth: Self.cardWidth,
            cardSpacing: Self.cardSpacing,
            contentPadding: Self.contentPadding
        ).targetIndex(
            visibleIndices: visibleIndices,
            containerWidth: viewportWidth,
            direction: direction
        )
    }
}

private struct RelatedVideoCard: View {
    let item: RelatedVideoShelfItem
    let isFocused: Bool

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        VideoCard(
            coverURL: item.coverURL,
            avatarURL: nil,
            showsAvatar: false,
            title: item.title,
            coverMetrics: [
                VideoCardMetric(
                    item.viewCountText,
                    systemImage: "play.fill"
                ),
                VideoCardMetric(
                    item.danmakuCountText,
                    systemImage: "text.bubble.fill"
                ),
            ],
            coverTrailingText: item.durationText,
            footerLeadingText: item.ownerName
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    Color.accentColor,
                    lineWidth: colorSchemeContrast == .increased ? 3 : 2
                )
                .opacity(isFocused ? 1 : 0)
        }
    }
}

extension RelatedVideoShelfItem {
    fileprivate var viewCountText: String {
        VideoMetadataFormatting.compactCount(viewCount)
    }

    fileprivate var danmakuCountText: String {
        VideoMetadataFormatting.compactCount(danmakuCount)
    }

    fileprivate var durationText: String? {
        durationSeconds.map {
            VideoDurationFormatting.string(seconds: $0)
        }
    }

    fileprivate var accessibilityLabel: String {
        var components = [
            title,
            ownerName,
            "\(viewCountText)播放",
            "\(danmakuCountText)弹幕",
        ]
        if let durationText {
            components.append("时长\(durationText)")
        }
        return components.joined(separator: "，")
    }
}

enum RecommendationShelfPageDirection: Hashable {
    case backward
    case forward

    var symbol: String {
        switch self {
        case .backward: "chevron.left"
        case .forward: "chevron.right"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .backward: "上一排相关推荐"
        case .forward: "下一排相关推荐"
        }
    }
}

struct RelatedVideoShelfPaging {
    let itemCount: Int
    let cardWidth: CGFloat
    let cardSpacing: CGFloat
    let contentPadding: CGFloat

    func targetIndex(
        visibleIndices: [Int],
        containerWidth: CGFloat,
        direction: RecommendationShelfPageDirection
    ) -> Int? {
        guard itemCount > 0 else { return nil }

        let visibleIndices = visibleIndices.filter {
            (0..<itemCount).contains($0)
        }
        let firstVisibleIndex = visibleIndices.min() ?? 0
        let lastVisibleIndex = visibleIndices.max() ?? 0
        let availableWidth = max(
            cardWidth,
            containerWidth - contentPadding * 2
        )
        let pageCapacity = max(
            1,
            Int(
                floor(
                    (availableWidth + cardSpacing)
                        / (cardWidth + cardSpacing)
                )
            )
        )

        switch direction {
        case .backward:
            guard firstVisibleIndex > 0 else { return nil }
            return max(0, firstVisibleIndex - pageCapacity)
        case .forward:
            let finalIndex = itemCount - 1
            guard lastVisibleIndex < finalIndex else { return nil }
            return min(finalIndex, firstVisibleIndex + pageCapacity)
        }
    }
}
