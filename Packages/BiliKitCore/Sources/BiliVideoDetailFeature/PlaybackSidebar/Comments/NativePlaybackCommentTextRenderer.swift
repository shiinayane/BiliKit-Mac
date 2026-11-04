import AppKit
import BiliApplication
import BiliModels

/// 一次正文渲染的作用域：评论对象、根评论与这条评论呈现的 revision。
///
/// 附件加载失败按作用域记录，内容一变即是新作用域。
struct NativePlaybackCommentTextScope: Hashable {
    let subject: CommentSubjectIdentity
    let rootID: CommentID
    let revision: Int
}

/// 评论正文的渲染器：把文字、接口链接、识别出的链接、时间戳与表情排成富文本，测量与显示共用同一结果。
///
/// 侧栏控制器持有一个，所有评论行共用；拥有“哪些表情或图标在哪个作用域里加载失败”的有界记录（最多 512 条，
/// 按先进先出淘汰；控制器每次更新只保留仍在呈现列表里的作用域，拆除时清空）。失败的附件在该作用域内改回原文，
/// 不再请求。图片加载经取图 port，不缓存图片。
///
/// 还拥有正文高度的有界缓存：行高测量与评论行的 `layout()` 都经 `height(_:commentID:width:scope:)` 取正文高度，
/// 同一宽度下只渲染、排版一次。失败记录一变（记下新的失败、丢掉不再呈现的作用域的记录、清空）缓存键里的
/// `failureRevision` 就递增，改回原文或重新加载后的高度不会沿用旧值。
@MainActor
final class NativePlaybackCommentTextRenderer {
    /// 一个需要加载的附件：资源引用与解析出的地址；同一引用在一次渲染里只加载一次。
    struct PendingAsset: Hashable {
        let reference: CommentAssetReference
        let url: URL
    }

    /// 一次渲染的结果：富文本、按引用分组的附件（加载后统一换图）、待加载的附件、链接目标与读屏文本。
    struct RenderedText {
        let attributedString: NSAttributedString
        let attachments: [CommentAssetReference: [NSTextAttachment]]
        let pendingAssets: [PendingAsset]
        let linkTargets: [CommentLinkTarget]
        /// 读屏文本：带标题的链接读标题，表情保留原文写法，图标不读。
        let accessibilityText: String
    }

    private let imagePipeline: any VideoDetailImageLoading
    private let resolveURL: CommentAssetURLResolver
    /// 正文时间戳可跳转的上限（不含），超出或为 nil 时时间戳按普通文字显示。
    ///
    /// 链接只改颜色、不改行高，所以测量不依赖它。
    var timestampLimitSeconds: Int?
    private struct UnavailableAssetKey: Hashable {
        let scope: NativePlaybackCommentTextScope
        let reference: CommentAssetReference
    }

    /// 失败记录的上限：足够覆盖一屏评论里的表情与图标，又不让长时间浏览后的记录无界增长。
    private static let maximumUnavailableAssetCount = 512
    private var activeScopes: Set<NativePlaybackCommentTextScope> = []
    private var unavailableAssets: Set<UnavailableAssetKey> = []
    private var unavailableAssetOrder: [UnavailableAssetKey] = []
    private var unavailableAssetOrderHead = 0
    private static let standardPlaceholder = placeholderImage(side: 18)
    /// 链接前置小图标的边长，与正文字号相近。
    private static let linkIconSide: CGFloat = 16
    private static let largePlaceholder = placeholderImage(side: 36)

    /// 正文高度缓存的键。
    ///
    /// 宽度按原值比较：测量与布局给同一条评论的宽度来自同一套几何计算，相等即可命中；
    /// 不按宽度桶取整，避免把相差不到半点、换行却不同的宽度当成一样。
    private struct BodyHeightKey: Hashable {
        let scope: NativePlaybackCommentTextScope
        let commentID: CommentID
        let width: CGFloat
        let failureRevision: Int
    }

    private let bodyHeights = CostBoundedLRUCache<BodyHeightKey, CGFloat>(
        limits: .commentBodyHeights
    )
    /// 失败记录的版本：`markUnavailable` 记下新失败、`retainFailureScopes` 丢掉失败记录与 `removeAllFailures`
    /// 时递增；正文高度缓存只认当前版本的条目。
    private var failureRevision = 0

    init(
        imagePipeline: any VideoDetailImageLoading,
        resolveURL: @escaping CommentAssetURLResolver
    ) {
        self.imagePipeline = imagePipeline
        self.resolveURL = resolveURL
    }

    func render(
        _ content: CommentContent,
        scope: NativePlaybackCommentTextScope
    ) -> RenderedText {
        let font = NSFont.preferredFont(forTextStyle: .body)
        let attributed = NSMutableAttributedString(
            string: content.message,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: NativePlaybackSidebarTextLayout.paragraphStyle
            ]
        )
        let (linkTargets, appliedLinks) = NativePlaybackTextLinks.apply(
            content.links,
            to: attributed,
            timestampLimitSeconds: timestampLimitSeconds
        )

        // 表情与带标题或图标的链接都要替换原文；从后往前替换，前面的位置不受影响，重叠的跳过。
        // 表情优先：与表情重叠的链接不替换，避免表情被拆开。
        var attachments: [CommentAssetReference: [NSTextAttachment]] = [:]
        var pendingByReference: [CommentAssetReference: PendingAsset] = [:]
        let spoken = NSMutableString(string: content.message)
        let decoratedLinks = appliedLinks.filter { link in
            (link.title != nil || link.icon != nil)
                && !content.emotes.contains { Self.overlaps($0.range, link.range) }
        }
        let replacements =
            content.emotes.map(Replacement.emote) + decoratedLinks.map(Replacement.link)
        var replacedFrom = attributed.length
        for replacement in replacements.sorted(by: Replacement.reverseRangeOrder) {
            let range = NSRange(
                location: replacement.range.location,
                length: replacement.range.length
            )
            guard range.location >= 0, range.length > 0,
                NSMaxRange(range) <= replacedFrom
            else { continue }
            let replaced: NSAttributedString?
            switch replacement {
            case .emote(let emote):
                replaced = emoteText(
                    emote,
                    scope: scope,
                    font: font,
                    attachments: &attachments,
                    pending: &pendingByReference
                )
            case .link(let link):
                if let title = link.title {
                    spoken.replaceCharacters(in: range, with: title)
                }
                replaced = linkText(
                    link,
                    original: attributed.attributedSubstring(from: range),
                    scope: scope,
                    font: font,
                    attachments: &attachments,
                    pending: &pendingByReference
                )
            }
            guard let replaced else { continue }
            attributed.replaceCharacters(in: range, with: replaced)
            replacedFrom = range.location
        }

        return RenderedText(
            attributedString: attributed,
            attachments: attachments,
            pendingAssets: pendingByReference.values.sorted {
                $0.url.absoluteString < $1.url.absoluteString
            },
            linkTargets: linkTargets,
            accessibilityText: spoken as String
        )
    }

    func load(_ pending: PendingAsset) async -> VideoDetailImage? {
        await imagePipeline.image(for: pending.url, purpose: .commentEmote)
    }

    func markUnavailable(
        _ reference: CommentAssetReference,
        in scope: NativePlaybackCommentTextScope
    ) -> Bool {
        guard activeScopes.contains(scope) else { return false }
        let key = UnavailableAssetKey(scope: scope, reference: reference)
        if unavailableAssets.insert(key).inserted {
            unavailableAssetOrder.append(key)
            trimUnavailableAssetsIfNeeded()
            failureRevision &+= 1
        }
        return true
    }

    func retainFailureScopes(_ scopes: Set<NativePlaybackCommentTextScope>) {
        activeScopes = scopes
        let retained = unavailableAssets.filter { scopes.contains($0.scope) }
        // 每次侧栏更新都会调到这里；只有真的丢掉了失败记录才作废正文高度，否则同一宽度下的缓存照常命中。
        if retained.count != unavailableAssets.count { failureRevision &+= 1 }
        unavailableAssets = retained
        unavailableAssetOrder = unavailableAssetOrder[
            unavailableAssetOrderHead...
        ].filter { unavailableAssets.contains($0) }
        unavailableAssetOrderHead = 0
    }

    /// 拆除时清空失败记录与正文高度缓存。
    func removeAllFailures() {
        activeScopes.removeAll(keepingCapacity: false)
        unavailableAssets.removeAll(keepingCapacity: false)
        unavailableAssetOrder.removeAll(keepingCapacity: false)
        unavailableAssetOrderHead = 0
        failureRevision &+= 1
        bodyHeights.removeAll()
    }

    func apply(
        _ result: VideoDetailImage,
        to attachments: [NSTextAttachment]
    ) {
        for attachment in attachments {
            attachment.image = Self.fittedImage(result.image, side: attachment.bounds.width)
        }
    }

    /// 正文在 `width` 下的高度；同一作用域、同一条评论、同一宽度且失败记录未变时取缓存，否则渲染并排版一次。
    func height(
        _ content: CommentContent,
        commentID: CommentID,
        width: CGFloat,
        scope: NativePlaybackCommentTextScope
    ) -> CGFloat {
        let key = BodyHeightKey(
            scope: scope,
            commentID: commentID,
            width: width,
            failureRevision: failureRevision
        )
        if let height = bodyHeights.value(for: key) { return height }
        let height = NativePlaybackSidebarTextLayout.height(
            render(content, scope: scope).attributedString,
            width: width
        )
        bodyHeights.insert(height, for: key)
        return height
    }

    private func trimUnavailableAssetsIfNeeded() {
        while unavailableAssets.count > Self.maximumUnavailableAssetCount,
            unavailableAssetOrderHead < unavailableAssetOrder.count
        {
            unavailableAssets.remove(unavailableAssetOrder[unavailableAssetOrderHead])
            unavailableAssetOrderHead += 1
        }
        if unavailableAssetOrderHead >= Self.maximumUnavailableAssetCount,
            unavailableAssetOrderHead * 2 >= unavailableAssetOrder.count
        {
            unavailableAssetOrder.removeFirst(unavailableAssetOrderHead)
            unavailableAssetOrderHead = 0
        }
    }

    private enum Replacement {
        case emote(CommentEmote)
        case link(CommentLink)

        var range: CommentTextRange {
            switch self {
            case .emote(let emote): emote.range
            case .link(let link): link.range
            }
        }

        static func reverseRangeOrder(_ lhs: Self, _ rhs: Self) -> Bool {
            if lhs.range.location != rhs.range.location {
                return lhs.range.location > rhs.range.location
            }
            return lhs.range.length < rhs.range.length
        }
    }

    /// 表情原文换成图片附件；资源不可用、尺寸未知或地址不合规时保留原文。
    private func emoteText(
        _ emote: CommentEmote,
        scope: NativePlaybackCommentTextScope,
        font: NSFont,
        attachments: inout [CommentAssetReference: [NSTextAttachment]],
        pending: inout [CommentAssetReference: PendingAsset]
    ) -> NSAttributedString? {
        guard emote.size != .unknown,
            let attachment = assetAttachment(
                emote.asset,
                side: Self.sideLength(for: emote.size),
                placeholder: Self.placeholder(for: emote.size),
                scope: scope,
                font: font,
                attachments: &attachments,
                pending: &pending
            )
        else { return nil }
        return NSAttributedString(attachment: attachment)
    }

    /// 接口给了标题或图标的链接：原文（多为网址）换成「图标 + 标题」。
    ///
    /// 沿用原文的链接与字体属性，点图标也能打开链接；图标不可用时只显示标题。
    private func linkText(
        _ link: CommentLink,
        original: NSAttributedString,
        scope: NativePlaybackCommentTextScope,
        font: NSFont,
        attachments: inout [CommentAssetReference: [NSTextAttachment]],
        pending: inout [CommentAssetReference: PendingAsset]
    ) -> NSAttributedString {
        let attributes = original.attributes(at: 0, effectiveRange: nil)
        let text = NSMutableAttributedString()
        if let icon = link.icon,
            let attachment = assetAttachment(
                icon,
                side: Self.linkIconSide,
                placeholder: Self.standardPlaceholder,
                scope: scope,
                font: font,
                attachments: &attachments,
                pending: &pending
            )
        {
            text.append(NSAttributedString(attachment: attachment))
        }
        text.append(NSAttributedString(string: link.title ?? original.string))
        text.addAttributes(attributes, range: NSRange(location: 0, length: text.length))
        return text
    }

    /// 小图片附件：已缓存时直接显示，否则先放占位并登记待加载；本作用域内已标记不可用时为 nil。
    private func assetAttachment(
        _ reference: CommentAssetReference,
        side: CGFloat,
        placeholder: NSImage,
        scope: NativePlaybackCommentTextScope,
        font: NSFont,
        attachments: inout [CommentAssetReference: [NSTextAttachment]],
        pending: inout [CommentAssetReference: PendingAsset]
    ) -> NSTextAttachment? {
        guard
            !unavailableAssets.contains(UnavailableAssetKey(scope: scope, reference: reference)),
            let url = resolveURL(reference, nil)
        else { return nil }
        let image = imagePipeline.cachedImage(for: url, purpose: .commentEmote)
        let attachment = makeAttachment(
            image: image,
            side: side,
            placeholder: placeholder,
            font: font
        )
        attachments[reference, default: []].append(attachment)
        if image == nil {
            pending[reference] = PendingAsset(reference: reference, url: url)
        }
        return attachment
    }

    private func makeAttachment(
        image: CGImage?,
        side: CGFloat,
        placeholder: NSImage,
        font: NSFont
    ) -> NSTextAttachment {
        let attachment = NSTextAttachment()
        attachment.allowsTextAttachmentView = false
        attachment.bounds = NSRect(
            x: 0,
            y: font.descender,
            width: side,
            height: side
        )
        attachment.image = image.map { Self.fittedImage($0, side: side) } ?? placeholder
        return attachment
    }

    /// 在边长为 `side` 的正方形里按原比例居中绘制：附件占位尺寸固定（测量不依赖图片），非方图不变形。
    private static func fittedImage(_ image: CGImage, side: CGFloat) -> NSImage {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0, width != height else {
            return NSImage(cgImage: image, size: NSSize(width: side, height: side))
        }
        let scale = side / max(width, height)
        let drawn = NSRect(
            x: (side - width * scale) / 2,
            y: (side - height * scale) / 2,
            width: width * scale,
            height: height * scale
        )
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.draw(image, in: drawn)
            return true
        }
    }

    private static func overlaps(_ lhs: CommentTextRange, _ rhs: CommentTextRange) -> Bool {
        lhs.location < rhs.location + rhs.length && rhs.location < lhs.location + lhs.length
    }

    private static func sideLength(for size: CommentEmoteSize) -> CGFloat {
        switch size {
        case .standard: 18
        case .large: 36
        case .unknown: 18
        }
    }

    private static func placeholder(for size: CommentEmoteSize) -> NSImage {
        size == .large ? largePlaceholder : standardPlaceholder
    }

    private static func placeholderImage(side: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.quaternaryLabelColor.withAlphaComponent(0.18).setFill()
            NSBezierPath(
                roundedRect: rect.insetBy(dx: 1, dy: 1),
                xRadius: side / 4,
                yRadius: side / 4
            ).fill()
            return true
        }
    }
}

extension CostBoundedLRUCacheLimits {
    /// 评论正文高度缓存：每项成本记 1，总上限即条目上限 4096（作用域 × 评论 × 宽度）。
    ///
    /// 拖动改宽度时每个宽度、每条可见评论（含楼中楼回复）各占一项，最久未用的先淘汰；调小则同一宽度下的几轮布局
    /// 更可能重新排版，调大只多占少量内存（每项一个 key 与一个 CGFloat）。
    static let commentBodyHeights = CostBoundedLRUCacheLimits(
        maximumItemCost: 1,
        maximumTotalCost: 4_096
    )
}
