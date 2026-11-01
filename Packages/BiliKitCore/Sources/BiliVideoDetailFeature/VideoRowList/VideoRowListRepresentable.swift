import AppKit
import SwiftUI

/// 竖向视频行列表的 SwiftUI 宿主：创建并持有 `VideoRowListController`，拆除时调用它的 `tearDown`。
///
/// 读屏名称只在创建时生效；同一个宿主不会在空间与相关推荐之间切换用途。`isObscured` 为 true 时（被空间层盖住、
/// 单栏时在另一个分页）设 `isHidden`：只设 SwiftUI 透明度与 hit testing 管不到行的 tracking area 与悬停。
struct VideoRowListRepresentable: NSViewRepresentable {
    let content: VideoRowListContent
    let imagePipeline: any VideoDetailImageLoading
    let actions: VideoRowListActions
    let accessibilityLabel: String
    let topButtonLabel: String
    var isObscured = false

    func makeCoordinator() -> VideoRowListController {
        VideoRowListController(
            imagePipeline: imagePipeline,
            accessibilityLabel: accessibilityLabel,
            topButtonLabel: topButtonLabel
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.update(content: content, actions: actions)
        context.coordinator.scrollView.isHidden = isObscured
        return context.coordinator.scrollView
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.update(content: content, actions: actions)
        view.isHidden = isObscured
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: VideoRowListController) {
        coordinator.tearDown()
    }
}
