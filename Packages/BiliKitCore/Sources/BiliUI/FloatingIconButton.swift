import SwiftUI

/// 浮在内容上的圆形图标按钮：macOS 26 起用玻璃样式，之前退回 bordered，内容从下方滚过时仍看得清。
///
/// 评论图片预览的保存、关闭与翻页按钮，以及 UP 主空间层的返回按钮共用；快捷键、禁用与焦点由调用方在外面加。
package struct FloatingIconButton: View {
    private static let iconSize: CGFloat = 24

    private let systemImage: String
    private let label: String
    private let action: () -> Void

    package init(_ systemImage: String, label: String, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = label
        self.action = action
    }

    package var body: some View {
        let button = Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: Self.iconSize, height: Self.iconSize)
        }
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .accessibilityLabel(label)
        .help(label)
        if #available(macOS 26.0, *) {
            button.buttonStyle(.glass)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}
