import AppKit
import BiliApplication
import BiliModels
import BiliUI
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// 侧栏被遮挡、打开空间层或拆除时，先把第一响应者从侧栏文档交还给窗口，隐藏的视图不持有焦点。
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PlaybackSidebarFocusTests: PlaybackSidebarFixtures {
    /// 只隐藏焦点视图时 AppKit 会把焦点交给下一个 key view，也就是侧栏外的控件；
    /// 侧栏必须在隐藏前把焦点还给窗口。
    @Test(arguments: SidebarFocus.allCases)
    @MainActor
    func blockingOverlayReturnsHiddenSidebarFirstResponderToWindow(focus: SidebarFocus) {
        let (controller, window, outsideKeyView) = hostedSidebar()
        let focused = focusInsideSidebar(
            focus,
            of: controller,
            in: window,
            nextKeyView: outsideKeyView
        )
        #expect(focused != nil)
        #expect(window.firstResponder === focused)

        controller.update(
            presentation: NativePlaybackSidebarPresentation(
                content: presentation(bvid: "BVCurrent").content,
                overlay: .loading(label: "正在加载所选视频上下文")
            ),
            actions: actions
        )

        #expect(window.firstResponder === window)
        controller.tearDown()
        window.contentView = NSView()
    }

    /// 打开空间前侧栏先把焦点还给窗口：侧栏随后会被空间层盖住并隐藏，焦点留在其中会让系统在
    /// 空间层进场动画中途改派焦点，进场变成从中间宽度伸展。
    @Test(arguments: SidebarFocus.allCases)
    @MainActor
    func openingTheSpaceReturnsSidebarFirstResponderToWindowFirst(
        focus: SidebarFocus
    ) throws {
        let (controller, window, outsideKeyView) = hostedSidebar()
        var focusWhenOpening: [NSResponder?] = []
        var spaceActions = actions
        spaceActions.openUploaderSpace = { focusWhenOpening.append(window.firstResponder) }
        controller.update(presentation: presentation(bvid: "BVCurrent"), actions: spaceActions)
        controller.rootView.layoutSubtreeIfNeeded()
        let focused = focusInsideSidebar(
            focus,
            of: controller,
            in: window,
            nextKeyView: outsideKeyView
        )
        #expect(focused != nil)
        #expect(window.firstResponder === focused)
        let collectionView = try #require(
            controller.rootView.scrollView.documentView as? NSCollectionView
        )
        let uploaderItem = try #require(
            collectionView.visibleItems().lazy
                .compactMap { $0 as? NativePlaybackSidebarUploaderItem }.first
        )
        // 定位前提：UP 主行里进入空间的只有名字右侧的箭头（另一个按钮是关注）。
        let spaceButtons = descendants(of: uploaderItem.view).compactMap { $0 as? NSButton }
            .filter { $0.accessibilityLabel() == VideoDetailFeatureStrings.localized("查看空间") }
        try #require(spaceButtons.count == 1)
        let spaceButton = spaceButtons[0]
        #expect(!spaceButton.isHidden)

        spaceButton.performClick(nil)

        #expect(focusWhenOpening.count == 1)
        #expect(focusWhenOpening.first.flatMap { $0 } === window)
        controller.tearDown()
        window.contentView = NSView()
    }

    /// 拆掉文档时 AppKit 会把窗口设回 first responder，但直接持有焦点的文本视图收不到
    /// resign（field editor 会随文本框结束编辑而 resign）；侧栏必须在拆文档前正常结束焦点。
    @Test(arguments: SidebarFocus.allCases)
    @MainActor
    func teardownResignsSidebarFirstResponderBeforeDetachingDocument(focus: SidebarFocus) {
        let (controller, window, outsideKeyView) = hostedSidebar()
        let focused = focusInsideSidebar(
            focus,
            of: controller,
            in: window,
            nextKeyView: outsideKeyView
        )
        #expect(focused != nil)
        #expect(window.firstResponder === focused)

        controller.tearDown()

        #expect(focused?.didResign == true)
        #expect(window.firstResponder === window)
        window.contentView = NSView()
    }

    /// 侧栏文档里真正能拿到焦点的两类 responder：可选择的文本视图本身，以及可选择文本框
    /// 编辑会话里由窗口共享的 field editor。
    enum SidebarFocus: CaseIterable {
        case selectableTextView
        case textFieldEditor
    }

    final class ResignRecordingTextView: NSTextView {
        private(set) var didResign = false

        override func resignFirstResponder() -> Bool {
            didResign = true
            return super.resignFirstResponder()
        }
    }

    /// 用可记录 resign 的 field editor 代替窗口共享的 field editor。
    final class RecordingFieldEditorWindow: NSWindow {
        private lazy var recordingFieldEditor: ResignRecordingTextView = {
            let fieldEditor = ResignRecordingTextView()
            fieldEditor.isFieldEditor = true
            return fieldEditor
        }()

        override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
            recordingFieldEditor
        }
    }

    /// 把侧栏装进窗口，并在侧栏外放一个可接焦点的视图，代表窗口里的其他控件。
    @MainActor
    private func hostedSidebar() -> (
        controller: NativePlaybackSidebarController,
        window: NSWindow,
        outsideKeyView: NSView
    ) {
        let controller = makeSidebarController()
        controller.rootView.frame = NSRect(x: 0, y: 0, width: 440, height: 600)
        let window = RecordingFieldEditorWindow(
            contentRect: controller.rootView.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.rootView
        controller.update(
            presentation: presentation(bvid: "BVCurrent"),
            actions: actions
        )
        let outsideKeyView = selectableTextView()
        controller.rootView.addSubview(outsideKeyView)
        return (controller, window, outsideKeyView)
    }

    /// 让焦点真正落进侧栏文档并返回持有焦点的 responder。
    ///
    /// 直接把裸 field editor 设为 first responder 不会生效（窗口自己会接回焦点），所以
    /// field editor 必须来自文本框真正开始的编辑会话。AppKit 隐藏焦点视图时沿持有焦点的
    /// responder 找下一个 key view，因此把它（而不是文本框）的下一个 key view 指向侧栏外。
    @MainActor
    private func focusInsideSidebar(
        _ focus: SidebarFocus,
        of controller: NativePlaybackSidebarController,
        in window: NSWindow,
        nextKeyView outsideKeyView: NSView
    ) -> ResignRecordingTextView? {
        let documentView = controller.rootView.scrollView.documentView
        let focused: ResignRecordingTextView?
        switch focus {
        case .selectableTextView:
            let textView = selectableTextView()
            documentView?.addSubview(textView)
            window.makeFirstResponder(textView)
            focused = textView
        case .textFieldEditor:
            let selectableField = NSTextField(labelWithString: "可选择的标题")
            selectableField.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
            selectableField.isSelectable = true
            documentView?.addSubview(selectableField)
            selectableField.selectText(nil)
            focused = selectableField.currentEditor() as? ResignRecordingTextView
        }
        focused?.nextKeyView = outsideKeyView
        return focused
    }

    @MainActor
    private func selectableTextView() -> ResignRecordingTextView {
        let textView = ResignRecordingTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        textView.isEditable = false
        textView.isSelectable = true
        return textView
    }
}
