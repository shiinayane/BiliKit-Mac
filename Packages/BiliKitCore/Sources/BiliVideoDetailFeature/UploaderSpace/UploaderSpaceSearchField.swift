import AppKit
import SwiftUI

/// 空间顶部那一行里的搜索框：回车提交，清除按钮或 Esc 清空后提交空串即退出搜索（空串的含义由
/// `UploaderSpaceViewModel.submitSearch` 决定）。
///
/// 用 AppKit `NSSearchField`：SwiftUI 的系统搜索框（`.searchable`）只能放进窗口工具栏，放不进侧栏的上下文层；原生搜索框
/// 自带清除按钮、Esc 清空与读屏的搜索语义。尺寸档由调用方经 SwiftUI 环境 `.controlSize` 给出：SwiftUI 宿主会用环境
/// 的尺寸档覆盖这里直接设的 `controlSize`。只在回车或清空时发出（`sendsWholeSearchString`），不随输入发请求。提交或清空
/// 之后放下键盘焦点，空格、方向键回到播放器快捷键。草稿文字只在控件里；换 UP 主时由调用方以 `.id` 重建控件清掉草稿。
struct UploaderSpaceSearchField: NSViewRepresentable {
    let onSubmit: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = VideoDetailFeatureStrings.localized("搜索 TA 的投稿")
        field.setAccessibilityLabel(VideoDetailFeatureStrings.localized("搜索 UP 主的投稿"))
        field.sendsWholeSearchString = true
        field.sendsSearchStringImmediately = false
        field.target = context.coordinator
        field.action = #selector(Coordinator.search(_:))
        context.coordinator.onSubmit = onSubmit
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.onSubmit = onSubmit
    }

    /// 搜索框的 target：转交最新的回调，并在提交或清空后放下焦点。
    @MainActor
    final class Coordinator: NSObject {
        var onSubmit: ((String) -> Void)?

        @objc func search(_ sender: NSSearchField) {
            onSubmit?(sender.stringValue)
            sender.window?.makeFirstResponder(nil)
        }
    }
}
