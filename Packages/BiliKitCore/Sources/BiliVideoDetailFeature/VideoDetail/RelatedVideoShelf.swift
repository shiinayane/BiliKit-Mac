import BiliModels
import BiliUI
import BiliVideoCollectionUI
import Foundation
import SwiftUI

/// 相关推荐卡片的展示值（含读屏文案），横排 renderer 直接消费。
public struct RelatedVideoCardPresentation: Identifiable, Equatable, Sendable {
    public let bvid: String
    public let title: String
    /// 封面的请求地址：与视频卡片同一尺寸的 B 站图片 CDN 缩略图。
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

    init(video: RelatedVideo, locale: Locale = InterfaceLocale.current) {
        bvid = video.bvid
        title = video.title
        coverURL = BiliImageThumbnail.url(video.coverURL, size: .videoCover)
        ownerName = video.ownerName
        viewCountText = VideoMetadataFormatting.compactCount(video.viewCount, locale: locale)
        danmakuCountText = VideoMetadataFormatting.compactCount(video.danmakuCount, locale: locale)
        durationText = video.durationSeconds.map {
            VideoDurationFormatting.string(seconds: $0)
        }
        var components = [
            video.title,
            video.ownerName,
            VideoMetadataFormatting.viewCountText(compactText: viewCountText, locale: locale),
            VideoMetadataFormatting.danmakuCountText(compactText: danmakuCountText, locale: locale)
        ]
        if let durationSeconds = video.durationSeconds {
            components.append(
                VideoCardAccessibilityText.duration(seconds: durationSeconds, locale: locale)
            )
        }
        accessibilityLabel = ListFormatter.localizedString(byJoining: components)
    }
}

/// 横排只关心的四种形态；由 `VideoDetailView` 按当前 BVID 从 `RelatedVideoState` 投影。
enum RelatedVideoShelfState: Equatable, Sendable {
    case loading
    case loaded([RelatedVideoCardPresentation])
    case empty
    case failure
}

/// 播放详情下方的横向相关推荐 shelf。
///
/// 只接收稳定展示状态、卡片取图 port 与 BVID 选择意图；滚动分页、hover 控件和 Reduce Motion
/// 封装在视图内，不拥有推荐请求、导航路径、播放器或认证生命周期。
/// 加载、失败、空与已加载状态同高，播放页主区不随推荐状态改变视频尺寸。
struct RelatedVideoShelf: View {
    private typealias Shelf = VideoCardShelfGeometry

    let state: RelatedVideoShelfState
    let onSelect: (String) -> Void
    let onRetry: () -> Void
    let contentIdentity: String
    let imageLoader: any NativeVideoImageLoading
    var scrollCommand: NativeVideoShelfScrollCommand? = nil
    var fadesInOnCreation = false

    /// 只有内容区；标题行由外层 `PlaybackShelf` 按分页给出。
    @ViewBuilder
    var body: some View {
        switch state {
        case .loading:
            RelatedVideoShelfLoadingRow()
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
        RelatedNativeShelfView(
            contentIdentity: contentIdentity,
            presentations: items,
            imagePipeline: imageLoader,
            onSelect: onSelect,
            scrollCommand: scrollCommand,
            fadesInOnCreation: fadesInOnCreation
        )
        .frame(height: Shelf.viewportHeight)
    }

    private var failureShelf: some View {
        VStack(spacing: 10) {
            Label(
                VideoDetailFeatureStrings.localized("相关视频加载失败"),
                systemImage: "exclamationmark.triangle"
            )
            .font(.headline)
            Button(VideoDetailFeatureStrings.localized("重试"), action: onRetry)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Shelf.viewportHeight)
    }

    private var unavailableShelf: some View {
        ContentUnavailableView(
            VideoDetailFeatureStrings.localized("暂无相关视频"),
            systemImage: "rectangle.stack"
        )
        .frame(maxWidth: .infinity)
        .frame(height: Shelf.viewportHeight)
    }
}

/// 横排的外框：标题行与下方内容区；真实横排与播放页加载骨架共用，两者的布局一致。
struct RelatedVideoShelfFrame<Header: View, Content: View>: View {
    private typealias Shelf = VideoCardShelfGeometry

    private let customHeader: Header
    private let content: Content

    init(
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) {
        customHeader = header()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            customHeader
                .frame(height: Shelf.headerHeight, alignment: .leading)
                .padding(.horizontal, Shelf.contentInset)

            ZStack(alignment: .topLeading) {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 横排加载中的占位行：与真实横排同一几何的卡片骨架（无头像，与横排卡片一致），张数按可见宽度铺满
/// （`NativeVideoShelfGeometry.placeholderCount`），与已加载的横排同高；不需要取图。
///
/// 首卡起点是安全区前缘加内容边距，与真实横排一致；骨架只在安全区内铺开并裁掉超出部分。
struct RelatedVideoShelfLoadingRow: View {
    private typealias Shelf = VideoCardShelfGeometry

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: Shelf.spacing) {
                ForEach(
                    0..<NativeVideoShelfGeometry.placeholderCount(
                        viewportWidth: geometry.size.width
                    ),
                    id: \.self
                ) { _ in
                    VideoCardSkeleton(
                        size: CGSize(width: Shelf.cardWidth, height: Shelf.cardHeight),
                        showsAvatar: false
                    )
                }
            }
            .padding(.horizontal, Shelf.contentInset)
            .frame(width: geometry.size.width, alignment: .leading)
            .clipped()
        }
        .frame(height: Shelf.viewportHeight, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(VideoDetailFeatureStrings.localized("正在加载相关视频"))
    }
}
