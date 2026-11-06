import AppKit
import BiliApplication
import BiliUI
import BiliVideoCollectionUI

/// 空间列表底部那一行：还有下一批或正在加载时转圈，加载下一批失败时给一行说明与「重试」。
///
/// 是否加载、何时加载由 `UploaderSpaceListController` 按这一行是否进入视野决定，这里只画状态。用 AppKit 的理由同列表
/// 本身，见 ARCHITECTURE「原生 AppKit 集合视图」。
@MainActor
final class UploaderSpaceFooterItem: NativeLayoutSizedCollectionItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("UploaderSpaceFooterItem")

    private let spinner = NSProgressIndicator()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let retryButton = NSButton(
        title: VideoDetailFeatureStrings.localized("重试"),
        target: nil,
        action: nil
    )
    private let stack = NSStackView()
    private var onRetry: (() -> Void)?

    override func loadView() {
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.setAccessibilityLabel(VideoDetailFeatureStrings.localized("正在加载更多投稿"))
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.font = .preferredFont(forTextStyle: .callout)
        retryButton.bezelStyle = .rounded
        retryButton.controlSize = .small
        retryButton.target = self
        retryButton.action = #selector(retry)

        stack.orientation = .horizontal
        stack.spacing = UploaderSpaceGeometry.footerSpacing
        stack.alignment = .centerY
        for view in [spinner, messageLabel, retryButton] {
            stack.addArrangedSubview(view)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor)
        ])
        view = container
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        spinner.stopAnimation(nil)
        onRetry = nil
    }

    /// `footer` 为 `.none` 时列表不放这一行，不会调用到这里。
    func configure(footer: UploaderSpaceFooter, onRetry: @escaping () -> Void) {
        self.onRetry = onRetry
        switch footer {
        case .loadMore, .loading, .none:
            spinner.isHidden = false
            spinner.startAnimation(nil)
            messageLabel.isHidden = true
            retryButton.isHidden = true
        case .failed(let error):
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            messageLabel.stringValue = ContentFailureText.message(for: error)
            messageLabel.isHidden = false
            retryButton.isHidden = !error.isRetryable
        }
    }

    @objc private func retry() {
        onRetry?()
    }
}
