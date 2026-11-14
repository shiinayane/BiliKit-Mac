import AppKit
import BiliApplication
import BiliUI
import SwiftUI

/// 评论区底部浮动的评论入口：默认收起成右下角一枚玻璃圆钮，点它或评论行的「回复」展开成输入卡片；默认发楼层评论，回复时
/// 卡片顶部显示「回复 @昵称」。
///
/// 收起的圆钮与「返回顶部」同尺寸、同边距；「返回顶部」由侧栏按 `onVisibleHeightChange` 叠在圆钮或卡片上方，并随展开、
/// 收起动画逐帧移动。收起的圆钮在有未发出的草稿时带一个小圆点。
///
/// 变形：圆钮与卡片是同一块玻璃（`surface`），展开时只改它的尺寸与圆角，从 44pt 圆形长成卡片，里面的图标与卡片内容
/// 淡入淡出、按玻璃形状裁剪，以右下角为锚点。不用两个视图加 `glassEffectID`：实测在 macOS 上那样的变形不论隐式动画、
/// `withAnimation` 还是声明 matchedGeometry 过渡都直接跳到终态；同一视图改尺寸与圆角则逐帧变形。
///
/// 收起与焦点：Esc 先取消回复对象，再按一次收起；卡片右上角的按钮也收起；发出成功、草稿已清空时自动收起。收起前先同步
/// 放下焦点再改状态：卡片在收起动画结束前还挂着，焦点若跟着它等到移除才放下，这段时间里播放器快捷键不响应（与弹幕输入
/// 胶囊同一个教训），只放下这个入口所在窗口的焦点。不按失焦收起：点卡片上的按钮也会让输入框失焦。焦点请求只用一次：
/// 入口被重新挂上时不再抢焦点。开着「减少动态效果」时不做变形动画。
///
/// 按键：回车发出，纵向扩展的 `TextField` 在 macOS 上 Option-回车换行。输入框任何时候都不禁用（未登录、复核中、发送中）：禁用会让它交出第一响应者，播放器快捷键随即接管
/// 按键，正在打的 Q 会真的给视频点赞（见 `PlayerKeyboardShortcutController` 的焦点让渡）；能否发出由模型判断。
struct PlaybackCommentComposerView: View {
    @Bindable var model: PlaybackCommentWriteModel
    /// 评论入口此刻看起来的高度（不含外边距），展开与收起动画期间逐帧给出；侧栏据此把「返回顶部」放在它上方。
    ///
    /// 只在渲染时调用，调用方不得在其中改 SwiftUI 状态（会在渲染中触发新的更新），只能直接改 AppKit 视图。
    var onVisibleHeightChange: (CGFloat) -> Void = { _ in }
    /// 评论入口的布局高度（不含外边距）：展开、收起时各给一次终值，侧栏据此在列表末尾留白。
    var onLayoutHeightChange: (CGFloat) -> Void = { _ in }
    /// 展开卡片的布局高度；收起时保留上一次的值，供收起动画插值。
    @State private var cardHeight: CGFloat = 0
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 入口所在的窗口；收起时只放下这个窗口的第一响应者，不碰别的窗口。
    @State private var window = CommentComposerWindowReference()

    var body: some View {
        surface
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                onLayoutHeightChange($0)
            }
            .background {
                CommentComposerHeightReporter(
                    progress: model.isExpanded ? 1 : 0,
                    collapsedHeight: CommentComposerLayout.buttonSize,
                    expandedHeight: cardHeight,
                    report: onVisibleHeightChange
                )
            }
            .frame(maxWidth: .infinity, alignment: .bottomTrailing)
            .padding(CommentComposerLayout.edgeInset)
            .background { CommentComposerWindowReader(reference: window) }
            .animation(
                reduceMotion ? nil : CommentComposerLayout.morphAnimation,
                value: model.isExpanded
            )
            .onExitCommand {
                if model.activeReplyContext != nil {
                    model.cancelReply()
                } else {
                    collapse()
                }
            }
            .onChange(of: model.collapseRequestID) { collapse() }
            // 失败说明在输入框下方，读屏焦点停在输入框里读不到，所以通告一次（与弹幕输入胶囊一致）。
            .accessibilityAnnouncement(failureText, trigger: model.phase)
    }

    /// 圆钮与卡片共用的那一块玻璃。
    ///
    /// 收起时固定 44pt、圆角取一半成圆形；展开时取卡片的自然大小、圆角 16pt。尺寸与圆角随动画插值，内容按当前形状裁剪。
    private var surface: some View {
        let shape = RoundedRectangle(
            cornerRadius: model.isExpanded
                ? CommentComposerLayout.cornerRadius : CommentComposerLayout.buttonSize / 2,
            style: .continuous
        )
        return ZStack(alignment: .bottomTrailing) {
            if model.isExpanded {
                card.transition(.opacity)
            } else {
                collapsedButton.transition(.opacity)
            }
        }
        .frame(
            width: model.isExpanded ? nil : CommentComposerLayout.buttonSize,
            height: model.isExpanded ? nil : CommentComposerLayout.buttonSize,
            alignment: .bottomTrailing
        )
        .clipShape(shape)
        .modifier(CommentComposerGlass(shape: shape, isInteractive: !model.isExpanded))
    }

    private var collapsedButton: some View {
        Button {
            model.expand()
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: CommentComposerLayout.buttonIconSize, weight: .medium))
                .frame(
                    width: CommentComposerLayout.buttonSize,
                    height: CommentComposerLayout.buttonSize
                )
                .overlay(alignment: .topTrailing) {
                    if !model.draft.isEmpty {
                        Circle()
                            .fill(.tint)
                            .frame(
                                width: CommentComposerLayout.draftDotDiameter,
                                height: CommentComposerLayout.draftDotDiameter
                            )
                            .padding(CommentComposerLayout.draftDotInset)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(VideoDetailFeatureStrings.localized("发评论"))
        .accessibilityLabel(VideoDetailFeatureStrings.localized("发评论"))
        .accessibilityValue(
            model.draft.isEmpty ? "" : VideoDetailFeatureStrings.localized("有未发出的草稿")
        )
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: CommentComposerLayout.rowSpacing) {
            HStack(spacing: CommentComposerLayout.headerItemSpacing) {
                if let reply = model.activeReplyContext {
                    Text(VideoDetailFeatureStrings.localized("回复 @\(reply.authorName)"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Button {
                        model.cancelReply()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(VideoDetailFeatureStrings.localized("取消回复"))
                } else {
                    Text(VideoDetailFeatureStrings.localized("发评论"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: CommentComposerLayout.headerItemSpacing)
                Button {
                    collapse()
                } label: {
                    Image(systemName: "chevron.down")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(VideoDetailFeatureStrings.localized("收起"))
                .accessibilityLabel(VideoDetailFeatureStrings.localized("收起"))
            }
            TextField(placeholder, text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(CommentComposerLayout.minimumLines...CommentComposerLayout.maximumLines)
                .focused($isFocused)
                .onSubmit { model.send() }
            HStack(spacing: CommentComposerLayout.rowSpacing) {
                if let failure = failureText {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    Text(verbatim: "\(model.messageLength)/\(CommentPostText.maximumLength)")
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(
                            model.messageLength > CommentPostText.maximumLength ? .red : .secondary
                        )
                }
                Spacer(minLength: CommentComposerLayout.rowSpacing)
                if model.isSending {
                    ProgressView().controlSize(.small)
                }
                Button(VideoDetailFeatureStrings.localized("发布")) {
                    model.send()
                }
                .modifier(CommentComposerPublishButtonStyle())
                .disabled(
                    model.isSending || !model.isWritable
                        || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(CommentComposerLayout.padding)
        .frame(maxWidth: .infinity)
        // 卡片出现（展开）与每次要求聚焦（点「回复」）时把焦点交给输入框。
        .task(id: model.focusRequestID) {
            if model.consumeFocusRequest() { isFocused = true }
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height
        } action: {
            cardHeight = $0
        }
    }

    /// 先同步放下焦点，再收起卡片（理由见类型说明）。
    ///
    /// 只在输入框确实持有焦点时让窗口放下第一响应者，免得抢走侧栏里其他控件的焦点。
    private func collapse() {
        if isFocused {
            window.window?.makeFirstResponder(nil)
            isFocused = false
        }
        model.collapse()
    }

    private var placeholder: String {
        guard model.isWritable else { return VideoDetailFeatureStrings.localized("登录后发表评论") }
        // 接口给了占位文字就用它（UP 主可能设了自己的提示），否则用自己的文案。
        return model.activeReplyContext == nil
            ? model.inputPolicy.rootPlaceholder
                ?? VideoDetailFeatureStrings.localized("发一条友善的评论")
            : model.inputPolicy.replyPlaceholder
                ?? VideoDetailFeatureStrings.localized("写下你的回复")
    }

    private var failureText: String? {
        guard case .failed(let failure) = model.phase else { return nil }
        return switch failure {
        case .signInRequired: VideoDetailFeatureStrings.localized("登录后才能发表评论。")
        case .invalidText:
            VideoDetailFeatureStrings.localized(
                "评论不能为空，最多 \(CommentPostText.maximumLength) 字。"
            )
        case .write(let report): AccountWriteStatusText.message(for: report)
        }
    }
}

/// 记住评论入口所在的窗口（弱引用）；由 `CommentComposerWindowReader` 在挂上窗口时写入。
@MainActor
private final class CommentComposerWindowReference {
    weak var window: NSWindow?
}

/// 读取评论入口所在窗口的零尺寸 AppKit 视图：SwiftUI 没有公开的办法拿到所在窗口，收起时又只能放下这个窗口的焦点。
private struct CommentComposerWindowReader: NSViewRepresentable {
    let reference: CommentComposerWindowReference

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.reference = reference
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.reference = reference
        reference.window = view.window
    }

    final class ReaderView: NSView {
        weak var reference: CommentComposerWindowReference?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reference?.window = window
        }
    }
}

/// 评论入口的尺寸与动画。
private enum CommentComposerLayout {
    /// 输入区至少留出两行、最多长到五行再滚动，与网页评论框的大小相近。
    static let minimumLines = 2
    static let maximumLines = 5
    static let padding: CGFloat = 12
    static let cornerRadius: CGFloat = 16
    /// 卡片里各行之间、底部一行各项之间的间距。
    static let rowSpacing: CGFloat = 8
    /// 回复对象那一行里昵称与 × 之间的间距。
    static let headerItemSpacing: CGFloat = 6
    /// 收起的圆钮与边距取「返回顶部」按钮的同一组值，两枚按钮上下对齐。
    static let buttonSize = NativeScrollToTopScrollView.Geometry.buttonSize
    static let edgeInset = NativeScrollToTopScrollView.Geometry.edgeInset
    /// 圆钮里铅笔图标的字号。
    static let buttonIconSize: CGFloat = 17
    /// 有未发出的草稿时圆钮右上角小圆点的直径，以及它离圆钮边缘的距离。
    static let draftDotDiameter: CGFloat = 8
    static let draftDotInset: CGFloat = 9
    /// 展开与收起的变形动画：带一点回弹，接近 iOS 玻璃按钮展开的手感。
    static let morphAnimation: Animation = .bouncy(duration: 0.35)
}

/// 评论入口那一块玻璃的背景：macOS 26 起是液态玻璃，更早的系统用材质加细描边。
///
/// 收起时是可按的圆钮，用会对按压起反应的 interactive 玻璃；展开后是卡片，点输入区不该让整张卡片跟着起伏，所以不用。
private struct CommentComposerGlass<GlassShape: Shape>: ViewModifier {
    let shape: GlassShape
    let isInteractive: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(isInteractive ? .regular.interactive() : .regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay { shape.stroke(.separator, lineWidth: 0.5) }
        }
    }
}

/// 按展开进度逐帧给出评论入口看起来的高度：圆钮与卡片之间线性插值。
///
/// 玻璃的尺寸由 SwiftUI 在渲染时逐帧插值，布局与 `onGeometryChange` 给出的却在动画一开始就是终值；「返回顶部」是 AppKit
/// 按钮，跟随布局高度会先跳到终点再等卡片长出来，所以改为跟随这里同一条动画曲线的插值。回弹动画的进度会略超出 0–1，按钮随之一起回弹。
private struct CommentComposerHeightReporter: View, Animatable {
    var progress: Double
    let collapsedHeight: CGFloat
    let expandedHeight: CGFloat
    let report: (CGFloat) -> Void

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let height =
            collapsedHeight + (max(expandedHeight, collapsedHeight) - collapsedHeight) * progress
        let _ = report(height)
        Color.clear
    }
}

/// 「发布」按钮：macOS 26 起用强调色的玻璃按钮，更早的系统用强调色实心按钮。
private struct CommentComposerPublishButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}
