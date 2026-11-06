import AppKit
import BiliModels
import BiliVideoCollectionUI

/// 空间层头部的展示值。
struct UploaderSpaceHeaderContent: Equatable {
    let name: String
    let avatarURL: URL?
    /// 投稿总数（搜索时是结果数）未知时为 nil，不显示。
    let totalCount: Int?
    let order: UploaderVideoOrder
    /// 在空间内搜索：排序对搜索结果不生效，不显示排序；数目写作结果数。
    let isSearching: Bool
}

/// 空间层头部：头像、名字与投稿数，右侧排序（搜索时不显示）。
///
/// 是列表的第一行，随列表一起滚动，滚到工具栏下由系统做边缘模糊；返回按钮与搜索框在 `UploaderSpaceSidebarView` 顶部
/// 浮动的一行里，不随列表滚走。
@MainActor
final class UploaderSpaceHeaderItem: NativeLayoutSizedCollectionItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("UploaderSpaceHeaderItem")
    static let orders: [UploaderVideoOrder] = [.newest, .mostPlayed]

    private let headerView = UploaderSpaceHeaderView()

    override func loadView() {
        view = headerView
    }

    func configure(
        content: UploaderSpaceHeaderContent,
        imagePipeline: any VideoDetailImageLoading,
        onSelectOrder: @escaping (UploaderVideoOrder) -> Void
    ) {
        headerView.configure(content: content, imagePipeline: imagePipeline)
        headerView.onSelectOrder = onSelectOrder
    }

    func invalidateImageRequests() {
        headerView.cancelAvatarRequest()
    }
}

/// 空间头部的内容视图：头像、名字、投稿数与排序（搜索时不显示排序）。
///
/// 拥有头像加载 Task：换头像地址时取消上一次，到达的头像只在地址仍相同时显示；`cancelAvatarRequest` 经条目的
/// `invalidateImageRequests` 在头部离屏（`didEndDisplaying`）与列表拆除时调用。
@MainActor
private final class UploaderSpaceHeaderView: NSView {
    override var isFlipped: Bool { true }

    var onSelectOrder: ((UploaderVideoOrder) -> Void)?

    private let avatar = NativeVideoLayerImageView(
        placeholderSystemSymbolName: NativeAvatarPlaceholder.systemSymbolName,
        placeholderTintColor: NativeAvatarPlaceholder.tintColor
    )
    private let nameLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let orderControl = NSSegmentedControl(
        labels: [
            VideoDetailFeatureStrings.localized("最新发布"),
            VideoDetailFeatureStrings.localized("最多播放")
        ],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private var avatarURL: URL?
    private var avatarTask: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        avatar.layer?.cornerRadius = UploaderSpaceGeometry.avatarSize / 2
        avatar.setAccessibilityElement(false)

        nameLabel.font = .preferredFont(forTextStyle: .headline)
        nameLabel.lineBreakMode = .byTruncatingTail
        countLabel.font = .preferredFont(forTextStyle: .caption1)
        countLabel.textColor = .secondaryLabelColor
        countLabel.lineBreakMode = .byTruncatingTail

        orderControl.target = self
        orderControl.action = #selector(selectOrder)
        orderControl.setAccessibilityLabel(VideoDetailFeatureStrings.localized("排序"))

        for subview in [avatar, nameLabel, countLabel, orderControl] {
            addSubview(subview)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(content: UploaderSpaceHeaderContent, imagePipeline: any VideoDetailImageLoading)
    {
        nameLabel.stringValue = content.name
        nameLabel.setAccessibilityLabel(VideoDetailFeatureStrings.localized("UP 主，\(content.name)"))
        if let totalCount = content.totalCount {
            countLabel.stringValue =
                content.isSearching
                ? VideoDetailFeatureStrings.localized("\(totalCount) 条结果")
                : VideoDetailFeatureStrings.localized("\(totalCount) 个投稿")
            countLabel.isHidden = false
        } else {
            countLabel.isHidden = true
        }
        orderControl.isHidden = content.isSearching
        orderControl.selectedSegment =
            UploaderSpaceHeaderItem.orders.firstIndex(of: content.order) ?? 0
        if avatarURL != content.avatarURL {
            loadAvatar(content.avatarURL, imagePipeline: imagePipeline)
        }
        needsLayout = true
    }

    func cancelAvatarRequest() {
        avatarTask?.cancel()
        avatarTask = nil
        // 下次配置时重新加载。
        avatarURL = nil
    }

    override func layout() {
        super.layout()
        let padding = UploaderSpaceGeometry.headerHorizontalPadding
        let spacing = UploaderSpaceGeometry.headerSpacing
        let midY = bounds.midY
        let avatarSize = UploaderSpaceGeometry.avatarSize
        avatar.frame = NSRect(
            x: padding,
            y: midY - avatarSize / 2,
            width: avatarSize,
            height: avatarSize
        )

        let controlSize = orderControl.isHidden ? .zero : orderControl.fittingSize
        orderControl.frame = NSRect(
            x: bounds.width - padding - controlSize.width,
            y: midY - controlSize.height / 2,
            width: controlSize.width,
            height: controlSize.height
        )

        let textX = avatar.frame.maxX + spacing
        let textTrailing =
            orderControl.isHidden ? bounds.width - padding : orderControl.frame.minX - spacing
        let textWidth = max(0, textTrailing - textX)
        let nameHeight = nameLabel.fittingSize.height
        let countHeight = countLabel.isHidden ? 0 : countLabel.fittingSize.height
        let textTop = midY - (nameHeight + countHeight) / 2
        nameLabel.frame = NSRect(x: textX, y: textTop, width: textWidth, height: nameHeight)
        countLabel.frame = NSRect(
            x: textX,
            y: nameLabel.frame.maxY,
            width: textWidth,
            height: countHeight
        )
    }

    @objc private func selectOrder() {
        let index = orderControl.selectedSegment
        guard UploaderSpaceHeaderItem.orders.indices.contains(index) else { return }
        onSelectOrder?(UploaderSpaceHeaderItem.orders[index])
    }

    private func loadAvatar(_ url: URL?, imagePipeline: any VideoDetailImageLoading) {
        avatarTask?.cancel()
        avatarURL = url
        avatar.setImage(nil, animated: false)
        guard let url else { return }
        if let cached = imagePipeline.cachedImage(for: url, purpose: .avatar) {
            avatar.setImage(cached, animated: false)
            return
        }
        avatarTask = Task { [weak self] in
            let result = await imagePipeline.image(for: url, purpose: .avatar)
            guard let self, !Task.isCancelled, avatarURL == url, let result else { return }
            avatar.setImage(result.image, animated: result.fadesIn)
        }
    }
}
