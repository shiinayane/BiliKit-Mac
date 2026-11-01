import AppKit
import BiliApplication
import BiliModels
import BiliVideoCollectionUI

/// 遮挡与焦点：被覆盖层挡住或打开空间、跟随链接前，先把详情区文档里的第一响应者交还给窗口。
extension NativePlaybackDetailsController {
    func updateOverlay() {
        let blocked = presentation.overlay.blocksContent
        if blocked, !collectionView.isHidden {
            releaseCollectionFirstResponder()
        }
        rootView.scrollView.setAccessibilityHidden(blocked)
        rootView.scrollView.isHidden = false
        collectionView.isHidden = blocked
        updateTopButton()
    }

    /// 打开空间或跟随链接前先交出详情区里的焦点，再执行动作。
    ///
    /// 单栏时打开空间会切到右栏分页，详情区被真正隐藏；焦点若还留在其中（例如刚点过的评论正文、选中过的简介），
    /// 系统会在空间层进场动画中途改派焦点，引发额外布局，进场变成从中间宽度伸展开。双栏时详情区仍可见，先交出焦点
    /// 也无害。
    func releasingFocus(_ action: (NativePlaybackDetailsController) -> Void) {
        releaseCollectionFirstResponder()
        action(self)
    }

    func releaseCollectionFirstResponder() {
        guard let window = rootView.window,
            let responder = window.firstResponder,
            collectionOwnsFirstResponder(responder)
        else { return }
        window.makeFirstResponder(nil)
    }

    private func collectionOwnsFirstResponder(_ responder: NSResponder) -> Bool {
        if let responderView = responder as? NSView,
            responderView === collectionView
                || responderView.isDescendant(of: collectionView)
        {
            return true
        }
        return containsFieldEditor(responder, in: collectionView)
    }

    private func containsFieldEditor(
        _ responder: NSResponder,
        in view: NSView
    ) -> Bool {
        if let textField = view as? NSTextField,
            textField.currentEditor() === responder
        {
            return true
        }
        return view.subviews.contains {
            containsFieldEditor(responder, in: $0)
        }
    }
}
