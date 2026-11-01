import AppKit
import BiliVideoCollectionUI

/// 评论图片预览的窗口级 owner：把预览放进铺满父窗口的子窗口面板，换视频、关窗时关闭。
///
/// 父窗口是被点开的格子所在的窗口（详情区只在主窗口里，AVKit detached 全屏时同样挂在主窗口上）。面板有自己的
/// key window：播放器的按键监视只截获播放窗口的事件，Esc、←→ 与 ⌘S 直接交给预览，导航与详情区不必为预览守护，
/// 见 docs/ARCHITECTURE.md「原生 AppKit 集合视图」。
///
/// 拥有当前面板、它的宿主视图与父窗口的通知观察；不拥有图片管线、保存（`NativeCommentImageSaver`，同属窗口级，
/// 关窗时由窗口组装另行取消）与格子本身。同一时间最多一个预览，再次打开先无动画地关掉旧的。MainActor 隔离。
///
/// 关闭顺序（`dismiss`）：先移除通知观察；再结束挂在面板上的 sheet（保存面板按取消结束，`isBusy` 随之复位）；
/// 然后从父窗口摘下面板；用户关闭时把父窗口设为 key 并把焦点交还格子；最后隐藏面板并拆掉宿主视图，SwiftUI 的
/// `.task` 随之取消在途原图加载、释放本次预览持有的原图。先摘子窗口再交还焦点：面板仍是子窗口时父窗口成为 key
/// 会被面板盖住。淡出期间面板已不接收鼠标，也不再是子窗口。
@MainActor
public final class NativeCommentImagePreviewPresenter {
    /// 打开与关闭的淡入淡出时长；「减少动态效果」时不做。
    ///
    /// 只影响观感，不影响关闭顺序：淡出开始前面板已摘下、焦点已交还。
    private static let fadeDuration: TimeInterval = 0.15

    private struct Presentation {
        let request: NativeCommentImagePreviewRequest
        let panel: NativeCommentImagePreviewPanel
        weak var parent: NSWindow?
        var observers: NativeVideoNotificationObservers
    }

    private let imagePipeline: any VideoDetailImageLoading
    private let resolveURL: CommentAssetURLResolver
    private let imageSaver: NativeCommentImageSaver
    private var presentation: Presentation?

    public init(
        imagePipeline: any VideoDetailImageLoading,
        resolveURL: @escaping CommentAssetURLResolver,
        imageSaver: NativeCommentImageSaver
    ) {
        self.imagePipeline = imagePipeline
        self.resolveURL = resolveURL
        self.imageSaver = imageSaver
    }

    /// 打开预览；格子已不在窗口里时不打开。
    ///
    /// 调用方只在 `request.bvid` 是当前播放视频时调用。
    public func present(_ request: NativeCommentImagePreviewRequest) {
        dismiss(restoringFocus: false, animated: false)
        guard let parent = request.sourceWindow() else { return }
        let panel = NativeCommentImagePreviewPanel()
        let anchor = NativeCommentImagePreviewAnchor()
        anchor.window = panel
        panel.onRequestClose = { [weak self, weak panel] in
            guard let self, let panel, self.presentation?.panel === panel else { return }
            self.dismiss(restoringFocus: true, animated: true)
        }
        panel.host(
            NativeCommentImagePreviewView(
                request: request,
                imagePipeline: imagePipeline,
                resolveURL: resolveURL,
                imageSaver: imageSaver,
                anchor: anchor,
                onDismiss: { [weak panel] in panel?.onRequestClose() }
            )
        )
        panel.match(parent)

        var observers = NativeVideoNotificationObservers()
        // 子窗口随父窗口移动，但不随它改变尺寸（含进出原生全屏）。推到下一轮主线程再同步：通知可能在父窗口自己的
        // 布局与约束更新中途发出，此时改另一个窗口的 frame 会把两个窗口的布局搅在一起；面板已摘下（预览关闭或
        // 换成新的）就不再同步。
        observers.observe(NSWindow.didResizeNotification, object: parent) {
            [weak panel, weak parent] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let panel, let parent, panel.parent === parent else { return }
                    panel.match(parent)
                }
            }
        }
        observers.observe(NSWindow.willCloseNotification, object: parent) { [weak self] in
            self?.dismiss(restoringFocus: false, animated: false)
        }
        presentation = Presentation(
            request: request,
            panel: panel,
            parent: parent,
            observers: observers
        )

        let animated = Self.animates
        panel.alphaValue = animated ? 0 : 1
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeDuration
                panel.animator().alphaValue = 1
            }
        }
    }

    /// 播放的视频变化（含退出播放）时由 App 调用：预览属于别的视频就关闭，不交还焦点。
    public func playbackDidChange(to bvid: String?) {
        guard let presentation, presentation.request.bvid != bvid else { return }
        dismiss(restoringFocus: false, animated: false)
    }

    /// 关窗时由窗口组装调用：立即关闭，不交还焦点；须在取消图片保存之前，先让挂在面板上的保存面板按取消结束。
    public func close() {
        dismiss(restoringFocus: false, animated: false)
    }

    private func dismiss(restoringFocus: Bool, animated: Bool) {
        guard var presentation else { return }
        self.presentation = nil
        presentation.observers.removeAll()
        let panel = presentation.panel
        panel.onRequestClose = {}
        if let sheet = panel.attachedSheet {
            panel.endSheet(sheet, returnCode: .cancel)
        }
        panel.ignoresMouseEvents = true
        let parent = presentation.parent
        parent?.removeChildWindow(panel)
        if restoringFocus {
            parent?.makeKey()
            presentation.request.restoreFocus()
        }
        guard animated, Self.animates, panel.isVisible else {
            Self.tearDown(panel)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { Self.tearDown(panel) }
        }
    }

    /// 隐藏面板并拆掉预览内容。
    private static func tearDown(_ panel: NativeCommentImagePreviewPanel) {
        panel.orderOut(nil)
        panel.removeContent()
    }

    private static var animates: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
