import AppKit
import BiliModels

struct NativePlaybackCommentTextScope: Hashable {
    let subject: CommentSubjectIdentity
    let rootID: CommentID
    let revision: Int
}

@MainActor
final class NativePlaybackCommentTextRenderer {
    struct PendingAsset: Hashable {
        let reference: CommentAssetReference
        let url: URL
    }

    struct RenderedText {
        let attributedString: NSAttributedString
        let attachments: [CommentAssetReference: [NSTextAttachment]]
        let pendingAssets: [PendingAsset]
        let linkTargets: [CommentLinkTarget]
    }

    private let imagePipeline: NativeVideoImagePipeline
    private let resolveURL: CommentAssetURLResolver
    private struct UnavailableAssetKey: Hashable {
        let scope: NativePlaybackCommentTextScope
        let reference: CommentAssetReference
    }

    private static let maximumUnavailableAssetCount = 512
    private var activeScopes: Set<NativePlaybackCommentTextScope> = []
    private var unavailableAssets: Set<UnavailableAssetKey> = []
    private var unavailableAssetOrder: [UnavailableAssetKey] = []
    private var unavailableAssetOrderHead = 0
    private static let standardPlaceholder = placeholderImage(side: 18)
    private static let largePlaceholder = placeholderImage(side: 36)

    init(
        imagePipeline: NativeVideoImagePipeline,
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
                .paragraphStyle: NativePlaybackSidebarTextLayout.paragraphStyle,
            ]
        )
        let linkTargets = applyLinks(content.links, to: attributed)

        var attachments: [CommentAssetReference: [NSTextAttachment]] = [:]
        var pendingByReference: [CommentAssetReference: PendingAsset] = [:]
        for emote in content.emotes.sorted(by: Self.reverseRangeOrder) {
            guard
                !unavailableAssets.contains(
                    UnavailableAssetKey(scope: scope, reference: emote.asset)
                ),
                emote.size != .unknown,
                let url = resolveURL(emote.asset)
            else { continue }
            let range = NSRange(
                location: emote.range.location,
                length: emote.range.length
            )
            guard range.location >= 0, range.length > 0,
                NSMaxRange(range) <= attributed.length
            else { continue }

            let image = imagePipeline.cachedImage(for: url, variant: .commentEmote)
            let attachment = makeAttachment(
                image: image,
                size: emote.size,
                font: font
            )
            attributed.replaceCharacters(
                in: range,
                with: NSAttributedString(attachment: attachment)
            )
            attachments[emote.asset, default: []].append(attachment)
            if image == nil {
                pendingByReference[emote.asset] = PendingAsset(
                    reference: emote.asset,
                    url: url
                )
            }
        }

        return RenderedText(
            attributedString: attributed,
            attachments: attachments,
            pendingAssets: pendingByReference.values.sorted {
                $0.url.absoluteString < $1.url.absoluteString
            },
            linkTargets: linkTargets
        )
    }

    func load(_ pending: PendingAsset) async -> NativeVideoImageLoadResult? {
        await imagePipeline.image(for: pending.url, variant: .commentEmote)
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
        }
        return true
    }

    func retainFailureScopes(_ scopes: Set<NativePlaybackCommentTextScope>) {
        activeScopes = scopes
        unavailableAssets = unavailableAssets.filter { scopes.contains($0.scope) }
        unavailableAssetOrder = unavailableAssetOrder[
            unavailableAssetOrderHead...
        ].filter { unavailableAssets.contains($0) }
        unavailableAssetOrderHead = 0
    }

    func removeAllFailures() {
        activeScopes.removeAll(keepingCapacity: false)
        unavailableAssets.removeAll(keepingCapacity: false)
        unavailableAssetOrder.removeAll(keepingCapacity: false)
        unavailableAssetOrderHead = 0
    }

    func apply(
        _ result: NativeVideoImageLoadResult,
        to attachments: [NSTextAttachment]
    ) {
        for attachment in attachments {
            attachment.image = NSImage(
                cgImage: result.image,
                size: attachment.bounds.size
            )
        }
    }

    func height(
        _ content: CommentContent,
        width: CGFloat,
        scope: NativePlaybackCommentTextScope
    ) -> CGFloat {
        NativePlaybackSidebarTextLayout.height(
            render(content, scope: scope).attributedString,
            width: width
        )
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

    private func makeAttachment(
        image: CGImage?,
        size: CommentEmoteSize,
        font: NSFont
    ) -> NSTextAttachment {
        let side = Self.sideLength(for: size)
        let attachment = NSTextAttachment()
        attachment.allowsTextAttachmentView = false
        attachment.bounds = NSRect(
            x: 0,
            y: font.descender,
            width: side,
            height: side
        )
        attachment.image =
            image.map {
                NSImage(cgImage: $0, size: NSSize(width: side, height: side))
            } ?? Self.placeholder(for: size)
        return attachment
    }

    private func applyLinks(
        _ links: [CommentLink],
        to attributed: NSMutableAttributedString
    ) -> [CommentLinkTarget] {
        var targets: [CommentLinkTarget] = []
        for link in links {
            let range = NSRange(
                location: link.range.location,
                length: link.range.length
            )
            guard range.location >= 0, range.length > 0,
                NSMaxRange(range) <= attributed.length
            else { continue }
            let value = "bilikit-comment-link-\(targets.count)"
            targets.append(link.target)
            attributed.addAttribute(.link, value: value, range: range)
        }
        return targets
    }

    private static func reverseRangeOrder(_ lhs: CommentEmote, _ rhs: CommentEmote) -> Bool {
        if lhs.range.location != rhs.range.location {
            return lhs.range.location > rhs.range.location
        }
        return lhs.range.length < rhs.range.length
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
