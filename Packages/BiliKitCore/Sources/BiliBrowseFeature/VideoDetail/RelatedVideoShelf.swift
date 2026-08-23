import BiliModels
import BiliUI
import Foundation
import SwiftUI

public struct RelatedVideoCardPresentation: Identifiable, Equatable, Sendable {
    public let bvid: String
    public let title: String
    public let coverURL: URL?
    public let ownerName: String
    public let viewCountText: String
    public let danmakuCountText: String
    public let durationText: String?
    public let accessibilityLabel: String

    public var id: String { bvid }

    public init(
        bvid: String,
        title: String,
        coverURL: URL?,
        ownerName: String,
        viewCountText: String,
        danmakuCountText: String,
        durationText: String?,
        accessibilityLabel: String
    ) {
        self.bvid = bvid
        self.title = title
        self.coverURL = coverURL
        self.ownerName = ownerName
        self.viewCountText = viewCountText
        self.danmakuCountText = danmakuCountText
        self.durationText = durationText
        self.accessibilityLabel = accessibilityLabel
    }

    init(video: RelatedVideo, locale: Locale = .current) {
        bvid = video.bvid
        title = video.title
        coverURL = video.coverURL
        ownerName = video.ownerName
        viewCountText = VideoMetadataFormatting.compactCount(video.viewCount, locale: locale)
        danmakuCountText = VideoMetadataFormatting.compactCount(video.danmakuCount, locale: locale)
        durationText = video.durationSeconds.map {
            VideoDurationFormatting.string(seconds: $0)
        }
        var components = [
            video.title,
            video.ownerName,
            BrowseFeatureStrings.localized("\(viewCountText)播放", locale: locale),
            BrowseFeatureStrings.localized("\(danmakuCountText)弹幕", locale: locale),
        ]
        if let durationText {
            components.append(BrowseFeatureStrings.localized("时长\(durationText)", locale: locale))
        }
        accessibilityLabel = ListFormatter.localizedString(byJoining: components)
    }
}

struct RelatedVideoShelfSelection {
    let onSelect: (String) -> Void

    func select(_ bvid: String) {
        onSelect(bvid)
    }
}

enum RelatedVideoShelfState: Equatable, Sendable {
    case loading
    case loaded([RelatedVideoCardPresentation])
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
struct RelatedVideoShelf<LoadedContent: View>: View {
    private static var cardWidth: CGFloat { 224 }
    private static var cardSpacing: CGFloat { 16 }
    private static var contentPadding: CGFloat { 40 }

    let state: RelatedVideoShelfState
    let selection: RelatedVideoShelfSelection
    let onRetry: () -> Void

    private let shelfHeight: CGFloat = 232
    let contentIdentity: String
    let makeLoadedContent:
        (
            String,
            [RelatedVideoCardPresentation],
            @escaping (String) -> Void
        ) -> LoadedContent

    init(
        state: RelatedVideoShelfState,
        contentIdentity: String,
        onSelect: @escaping (String) -> Void,
        onRetry: @escaping () -> Void,
        @ViewBuilder makeLoadedContent:
            @escaping (
                String,
                [RelatedVideoCardPresentation],
                @escaping (String) -> Void
            ) -> LoadedContent
    ) {
        self.state = state
        self.contentIdentity = contentIdentity
        selection = RelatedVideoShelfSelection(onSelect: onSelect)
        self.onRetry = onRetry
        self.makeLoadedContent = makeLoadedContent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
                .padding(.horizontal, Self.contentPadding)

            ZStack(alignment: .topLeading) {
                content
            }
            .transaction { transaction in
                transaction.disablesAnimations = true
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(BrowseFeatureStrings.localized("相关推荐"))
                .font(.title3.weight(.semibold))

            Text(BrowseFeatureStrings.localized("继续观看"))
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
        _ items: [RelatedVideoCardPresentation]
    ) -> some View {
        makeLoadedContent(contentIdentity, items, selection.select)
            .frame(height: shelfHeight)
    }

    private var loadingShelf: some View {
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
        .padding(.horizontal, Self.contentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .frame(height: shelfHeight, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(BrowseFeatureStrings.localized("正在加载相关推荐"))
    }

    private var failureShelf: some View {
        VStack(spacing: 10) {
            Label(
                BrowseFeatureStrings.localized("相关推荐加载失败"),
                systemImage: "exclamationmark.triangle"
            )
            .font(.headline)
            Button(BrowseFeatureStrings.localized("重试"), action: onRetry)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    private var unavailableShelf: some View {
        ContentUnavailableView(
            BrowseFeatureStrings.localized("暂无相关推荐"),
            systemImage: "rectangle.stack"
        )
        .frame(maxWidth: .infinity, minHeight: 180)
    }
}
