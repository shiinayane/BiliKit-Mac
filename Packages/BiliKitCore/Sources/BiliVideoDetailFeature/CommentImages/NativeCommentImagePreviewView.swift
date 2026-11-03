import AppKit
import BiliModels
import BiliUI
import BiliVideoCollectionUI
import SwiftUI

/// App 壳打开一次评论图片预览的请求，交给 `NativeCommentImagePreviewPresenter`：面板挂在被点开的格子所在的
/// 窗口上，播放的视频不再是 `bvid` 时关闭；用户关闭后把焦点交还格子（`restoreFocus`）。
@MainActor
public struct NativeCommentImagePreviewRequest: Identifiable {
    public let id = UUID()
    public let bvid: String
    let references: [CommentAssetReference]
    let selectedIndex: Int
    let sourceWindow: () -> NSWindow?
    let restoreFocus: () -> Void

    /// 侧栏点开的一组评论图片属于 `bvid`；没有图片时为 nil，App 不打开预览。
    public init?(bvid: String, gallery: NativePlaybackCommentPictureGallery) {
        guard !gallery.references.isEmpty else { return nil }
        self.bvid = bvid
        references = gallery.references
        selectedIndex = gallery.selectedIndex
        sourceWindow = gallery.sourceWindow
        restoreFocus = gallery.restoreFocus
    }
}

/// 预览面板的弱引用：保存面板以 sheet 挂在预览自己的面板上，不取当时的 key window。
///
/// 面板由 `NativeCommentImagePreviewPresenter` 创建后写入，内容只读。
@MainActor
final class NativeCommentImagePreviewAnchor {
    weak var window: NSWindow?
}

/// 评论图片预览面板的根视图。
///
/// 原图经 `VideoDetailImageLoading` 加载，列表缩小图作占位；保存交给窗口级的 `NativeCommentImageSaver`，关闭时
/// 调用 `onDismiss`。由 `NativeCommentImagePreviewPresenter` 放进面板，每次打开一个新的宿主，关闭时随宿主一起
/// 释放（取消在途加载、释放原图）。
struct NativeCommentImagePreviewView: View {
    let request: NativeCommentImagePreviewRequest
    let imagePipeline: any VideoDetailImageLoading
    let resolveURL: CommentAssetURLResolver
    /// 窗口级的保存 owner：预览关闭后已确认的保存照常完成。
    let imageSaver: NativeCommentImageSaver
    let anchor: NativeCommentImagePreviewAnchor
    let onDismiss: () -> Void

    var body: some View {
        NativeCommentImagePreviewContent(
            request: request,
            loader: NativePlaybackCommentPictureLoader(
                imagePipeline: imagePipeline,
                resolveURL: resolveURL,
                purpose: .commentPicturePreview
            ),
            placeholderLoader: NativePlaybackCommentPictureLoader(
                imagePipeline: imagePipeline,
                resolveURL: resolveURL,
                purpose: .commentPicture
            ),
            saver: imageSaver,
            anchor: anchor,
            onDismiss: onDismiss
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}

/// 预览当前是第几张：起始位置夹进有效范围，前后翻页到头即停，不循环。
struct NativeCommentImagePreviewSelection: Equatable {
    let count: Int
    private(set) var index: Int

    init(count: Int, requestedIndex: Int) {
        self.count = max(0, count)
        index =
            self.count > 0
            ? min(max(0, requestedIndex), self.count - 1)
            : 0
    }

    var canSelectPrevious: Bool { index > 0 }
    var canSelectNext: Bool { index + 1 < count }

    mutating func selectPrevious() -> Bool {
        guard canSelectPrevious else { return false }
        index -= 1
        return true
    }

    mutating func selectNext() -> Bool {
        guard canSelectNext else { return false }
        index += 1
        return true
    }
}

/// 预览的内容：图片区、关闭与保存按钮、翻页与计数，以及加载阶段。
///
/// 持有选中位置、加载阶段与重试次数（`@State`），以及本次预览会话的原图持有者 `originals`（当前与前后各一张，
/// 随预览关闭释放）。加载由 `.task(id:)` 按“第几张 + 第几次尝试”驱动：切换图片、重试或关闭都会取消上一次加载。
private struct NativeCommentImagePreviewContent: View {
    private enum Focus: Hashable {
        case surface
        case close
    }

    private enum Phase {
        case loading
        /// 原图到达前显示列表里已缓存的缩小图；`originalFailed` 表示原图加载失败，可重试。
        case placeholder(CGImage, originalFailed: Bool)
        /// 原图；动图另带编码数据，由缩放视图播放。缩小图占位不播放。
        case loaded(CGImage, NativeAnimatedImage?)
        case failed

        var image: CGImage? {
            switch self {
            case .placeholder(let image, _), .loaded(let image, _): image
            case .loading, .failed: nil
            }
        }

        var animation: NativeAnimatedImage? {
            guard case .loaded(_, let animation) = self else { return nil }
            return animation
        }

        /// 占位时原图是否失败；不是占位时为 nil。
        var originalFailed: Bool? {
            guard case .placeholder(_, let failed) = self else { return nil }
            return failed
        }
    }

    private struct LoadKey: Equatable {
        let index: Int
        let attempt: Int
    }

    private static let buttonInset: CGFloat = 18
    private static let buttonSpacing: CGFloat = 10
    private static let counterBottomInset: CGFloat = 18
    private static let originalStatusInset: CGFloat = 12

    let request: NativeCommentImagePreviewRequest
    let loader: NativePlaybackCommentPictureLoader
    /// 列表格子用的缩小图；只读缓存，用作原图到达前的占位，不为预览另发请求。
    let placeholderLoader: NativePlaybackCommentPictureLoader
    let saver: NativeCommentImageSaver
    let anchor: NativeCommentImagePreviewAnchor
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focus: Focus?
    @State private var selection: NativeCommentImagePreviewSelection
    @State private var phase = Phase.loading
    @State private var loadAttempt = 0
    /// 本次预览持有的原图；视图随 `request.id` 重建时一起释放。
    @State private var originals = NativeCommentImagePreviewOriginals()

    init(
        request: NativeCommentImagePreviewRequest,
        loader: NativePlaybackCommentPictureLoader,
        placeholderLoader: NativePlaybackCommentPictureLoader,
        saver: NativeCommentImageSaver,
        anchor: NativeCommentImagePreviewAnchor,
        onDismiss: @escaping () -> Void
    ) {
        self.request = request
        self.loader = loader
        self.placeholderLoader = placeholderLoader
        self.saver = saver
        self.anchor = anchor
        self.onDismiss = onDismiss
        _selection = State(
            initialValue: NativeCommentImagePreviewSelection(
                count: request.references.count,
                requestedIndex: request.selectedIndex
            )
        )
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 关闭手势只挂在背景上：图片盖在背景之上，点图片交给缩放视图（单击缩放，图片四周空白
                // 关闭）。挂在外层容器上会让点图片同时缩放和关闭。导航按钮不在该手势内。
                Color.black.opacity(0.82)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)
                phaseContent
                    .padding(.horizontal, min(96, max(56, geometry.size.width * 0.08)))
                    .padding(.vertical, min(86, max(54, geometry.size.height * 0.08)))
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: Self.buttonSpacing) {
                    FloatingIconButton(
                        "square.and.arrow.down",
                        label: VideoDetailFeatureStrings.localized("保存图片"),
                        action: saveCurrentImage
                    )
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(phase.image == nil || saver.isBusy)
                    FloatingIconButton(
                        "xmark",
                        label: VideoDetailFeatureStrings.localized("关闭图片预览"),
                        action: onDismiss
                    )
                    .focused($focus, equals: .close)
                }
                .padding(Self.buttonInset)
            }
            .overlay { navigation }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .surface)
        .defaultFocus($focus, .close)
        .task {
            // 未开启全键盘访问时关闭按钮不可聚焦，默认焦点落空；退到预览表面，保证 ←／→／Esc 可用。
            await Task.yield()
            if focus == nil { focus = .surface }
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            guard press.modifiers.isDisjoint(with: [.command, .control, .option, .shift])
            else { return .ignored }
            if press.key == .leftArrow { selectPrevious() } else { selectNext() }
            return .handled
        }
        .onExitCommand(perform: onDismiss)
        .task(id: LoadKey(index: selection.index, attempt: loadAttempt)) {
            await loadCurrentImage()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(VideoDetailFeatureStrings.localized("评论图片预览"))
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder
    private var phaseContent: some View {
        if let image = phase.image {
            imageView(image, animation: phase.animation, originalFailed: phase.originalFailed)
        } else if case .failed = phase {
            VStack(spacing: 10) {
                Text(VideoDetailFeatureStrings.localized("图片加载失败"))
                    .foregroundStyle(.white)
                Button(VideoDetailFeatureStrings.localized("重试")) { retry() }
                    .accessibilityLabel(VideoDetailFeatureStrings.localized("重新加载评论图片"))
            }
        } else {
            ProgressView()
                .accessibilityLabel(VideoDetailFeatureStrings.localized("评论图片加载中"))
        }
    }

    /// 缩小图与原图共用同一个缩放视图。
    ///
    /// 按序号重建（换图回到适配），同一张换成原图时只替换图片、保留缩放位置；原图状态贴在图片适配区域
    /// 的底边。
    private func imageView(
        _ image: CGImage,
        animation: NativeAnimatedImage?,
        originalFailed: Bool?
    ) -> some View {
        GeometryReader { proxy in
            let fitted = NativeCommentImageZoomGeometry.fittedSize(
                imageSize: CGSize(width: image.width, height: image.height),
                in: proxy.size
            )
            NativeCommentImageZoomView(
                image: image,
                animation: animation,
                accessibilityLabel: imageAccessibilityLabel,
                onDismissArea: onDismiss
            )
            .overlay {
                if let originalFailed {
                    originalStatus(failed: originalFailed)
                        .padding(Self.originalStatusInset)
                        .frame(width: fitted.width, height: fitted.height, alignment: .bottom)
                }
            }
        }
        .id(selection.index)
        .transition(.opacity)
    }

    /// 缩小图占位上的原图状态：加载中显示转圈，失败时提供重试，不让用户误以为原图就是这样。
    ///
    /// 保持自身宽度：窄长图的图片宽度不足时允许超出图片两侧，文字与按钮不被压成省略号。
    @ViewBuilder
    private func originalStatus(failed: Bool) -> some View {
        Group {
            if failed {
                HStack(spacing: 8) {
                    Text(VideoDetailFeatureStrings.localized("原图加载失败"))
                    Button(VideoDetailFeatureStrings.localized("重试")) { retry() }
                        .accessibilityLabel(VideoDetailFeatureStrings.localized("重新加载原图"))
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(VideoDetailFeatureStrings.localized("正在加载原图"))
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }

    @ViewBuilder
    private var navigation: some View {
        if selection.count > 1 {
            HStack {
                FloatingIconButton(
                    "chevron.left",
                    label: VideoDetailFeatureStrings.localized("上一张图片"),
                    action: selectPrevious
                )
                .disabled(!selection.canSelectPrevious)
                Spacer()
                FloatingIconButton(
                    "chevron.right",
                    label: VideoDetailFeatureStrings.localized("下一张图片"),
                    action: selectNext
                )
                .disabled(!selection.canSelectNext)
            }
            .padding(.horizontal, Self.buttonInset)
        }
        if selection.count > 0 {
            Text(verbatim: "\(selection.index + 1) / \(selection.count)")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(.white)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, Self.counterBottomInset)
        }
    }

    private var imageAccessibilityLabel: String {
        selection.count > 0
            ? VideoDetailFeatureStrings.localized(
                "评论图片，第 \(selection.index + 1) 张，共 \(selection.count) 张"
            )
            : VideoDetailFeatureStrings.localized("评论图片")
    }

    /// 保存当前这张的原图，保存面板挂在预览自己的面板上。
    private func saveCurrentImage() {
        guard request.references.indices.contains(selection.index) else { return }
        saver.save(
            request.references[selection.index],
            loader: loader,
            in: anchor.window
        )
    }

    private func selectPrevious() {
        guard selection.selectPrevious() else { return }
        phase = .loading
    }

    private func selectNext() {
        guard selection.selectNext() else { return }
        phase = .loading
    }

    private func retry() {
        phase = .loading
        loadAttempt += 1
    }

    /// 由 `.task(id:)` 驱动：切换图片、重试或关闭都会取消上一次加载。
    ///
    /// 列表里已缓存的缩小图先显示并标出原图加载中，原图到达后原位替换（显示尺寸相同）；原图失败时
    /// 保留缩小图并提供重试，只有连占位都没有时才整页显示失败。共享缓存放不下的大原图由本次预览的
    /// `originals` 持有当前与前后各一张。
    private func loadCurrentImage() async {
        guard request.references.indices.contains(selection.index) else {
            phase = .failed
            return
        }
        let reference = request.references[selection.index]
        if let cached = loader.cachedImage(for: reference) {
            phase = .loaded(cached, loader.cachedAnimation(for: reference))
            return
        }
        let placeholder = placeholderLoader.cachedImage(for: reference)
        phase = placeholder.map { .placeholder($0, originalFailed: false) } ?? .loading
        let result = await originals.image(at: selection.index) { [loader] in
            await loader.image(for: reference)
        }
        guard !Task.isCancelled else { return }
        guard let result else {
            phase = placeholder.map { .placeholder($0, originalFailed: true) } ?? .failed
            return
        }
        // 已有缩小图占位时原位替换，不再淡入。
        let animation = NativeImageFadeTransition.animation(
            fadesIn: placeholder == nil && result.fadesIn,
            reduceMotion: reduceMotion
        )
        withAnimation(animation) {
            phase = .loaded(result.image, result.animation)
        }
    }
}
