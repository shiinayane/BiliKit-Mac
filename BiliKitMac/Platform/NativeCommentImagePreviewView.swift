import AppKit
import BiliModels
import SwiftUI

@MainActor
struct NativeCommentImagePreviewRequest: Identifiable {
    let id = UUID()
    let bvid: String
    let references: [CommentAssetReference]
    let selectedIndex: Int
    let restoreFocus: () -> Void
}

struct NativeCommentImagePreviewView: View {
    let request: NativeCommentImagePreviewRequest
    let imagePipeline: NativeVideoImagePipeline
    let resolveURL: CommentAssetURLResolver
    let onDismiss: () -> Void

    var body: some View {
        NativeCommentImagePreviewHost(
            content: NativeCommentImagePreviewContent(
                request: request,
                loader: NativePlaybackCommentPictureLoader(
                    imagePipeline: imagePipeline,
                    resolveURL: resolveURL,
                    variant: .commentPicturePreview
                ),
                onDismiss: onDismiss
            )
        )
        .id(request.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}

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

/// 预览打开时独占键盘：播放器的按键监视看到第一响应者在它之内，就把方向键与 Esc 留给预览。
@MainActor
final class NativeCommentImagePreviewHostingView<Content: View>: NSHostingView<Content>,
    PlayerKeyboardFocusOwner
{
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
}

private struct NativeCommentImagePreviewHost<Content: View>: NSViewRepresentable {
    let content: Content

    func makeNSView(context: Context) -> NativeCommentImagePreviewHostingView<Content> {
        let view = NativeCommentImagePreviewHostingView(rootView: content)
        view.sizingOptions = []
        return view
    }

    func updateNSView(
        _ view: NativeCommentImagePreviewHostingView<Content>,
        context: Context
    ) {
        view.rootView = content
    }
}

private struct NativeCommentImagePreviewContent: View {
    private enum Focus: Hashable {
        case surface
        case close
    }

    private enum Phase {
        case loading
        case loaded(NSImage)
        case failed
    }

    private struct LoadKey: Equatable {
        let index: Int
        let attempt: Int
    }

    private static let buttonInset: CGFloat = 18
    private static let counterBottomInset: CGFloat = 18

    let request: NativeCommentImagePreviewRequest
    let loader: NativePlaybackCommentPictureLoader
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focus: Focus?
    @State private var selection: NativeCommentImagePreviewSelection
    @State private var phase = Phase.loading
    @State private var loadAttempt = 0

    init(
        request: NativeCommentImagePreviewRequest,
        loader: NativePlaybackCommentPictureLoader,
        onDismiss: @escaping () -> Void
    ) {
        self.request = request
        self.loader = loader
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
                Color.black.opacity(0.82)
                phaseContent
                    .padding(.horizontal, min(96, max(56, geometry.size.width * 0.08)))
                    .padding(.vertical, min(86, max(54, geometry.size.height * 0.08)))
            }
            // 只有背景与图片区域点击关闭；导航按钮不在该手势内，禁用时点击也不会穿透关闭。
            .contentShape(Rectangle())
            .onTapGesture(perform: onDismiss)
            .overlay(alignment: .topTrailing) {
                iconButton(
                    "xmark",
                    label: AppStrings.localized("关闭图片预览"),
                    action: onDismiss
                )
                .focused($focus, equals: .close)
                .padding(Self.buttonInset)
            }
            .overlay { navigation }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .surface)
        .defaultFocus($focus, .close)
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
        .accessibilityLabel(AppStrings.localized("评论图片预览"))
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch phase {
        case .loading:
            ProgressView()
                .accessibilityLabel(AppStrings.localized("评论图片加载中"))
        case .loaded(let image):
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel(imageAccessibilityLabel)
                .transition(.opacity)
        case .failed:
            VStack(spacing: 10) {
                Text(AppStrings.localized("图片加载失败"))
                    .foregroundStyle(.white)
                Button(AppStrings.localized("重试")) { retry() }
                    .accessibilityLabel(AppStrings.localized("重新加载评论图片"))
            }
        }
    }

    @ViewBuilder
    private var navigation: some View {
        if selection.count > 1 {
            HStack {
                iconButton(
                    "chevron.left",
                    label: AppStrings.localized("上一张图片"),
                    action: selectPrevious
                )
                .disabled(!selection.canSelectPrevious)
                Spacer()
                iconButton(
                    "chevron.right",
                    label: AppStrings.localized("下一张图片"),
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
            ? AppStrings.localized("评论图片，第 \(selection.index + 1) 张，共 \(selection.count) 张")
            : AppStrings.localized("评论图片")
    }

    private func iconButton(
        _ systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 24, height: 24)
        }
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .accessibilityLabel(label)
        return Group {
            if #available(macOS 26.0, *) {
                button.buttonStyle(.glass)
            } else {
                button.buttonStyle(.bordered)
            }
        }
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
    private func loadCurrentImage() async {
        guard request.references.indices.contains(selection.index) else {
            phase = .failed
            return
        }
        let reference = request.references[selection.index]
        if let cached = loader.cachedImage(for: reference) {
            phase = .loaded(Self.image(cached))
            return
        }
        phase = .loading
        let result = await loader.image(for: reference)
        guard !Task.isCancelled else { return }
        guard let result else {
            phase = .failed
            return
        }
        let animation: Animation? =
            result.origin.shouldAnimate && !reduceMotion
            ? .easeOut(duration: NativePlaybackCommentImageTransition.duration)
            : nil
        withAnimation(animation) {
            phase = .loaded(Self.image(result.image))
        }
    }

    private static func image(_ image: CGImage) -> NSImage {
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
