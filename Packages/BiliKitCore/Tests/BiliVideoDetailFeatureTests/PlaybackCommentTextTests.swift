import AppKit
import BiliApplication
import BiliModels
import BiliUI
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// 评论正文把链接标题、前置图标与表情渲染为固定尺寸的附件和可点目标，时间戳只在可跳转范围内成为链接，
/// 加载失败的表情按渲染作用域有界记录。
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PlaybackCommentTextTests: PlaybackSidebarFixtures {
    /// 接口给了标题的链接：原文网址显示为「图标 + 标题」，图标与标题都带同一个链接；后面的链接位置
    /// 不受前面替换影响，没有标题的链接保持原文。
    @Test
    @MainActor
    func titledLinksShowIconAndTitleInPlaceOfTheAddress() throws {
        let short = "https://b23.tv/Jf3cvv2"
        let message = "看 \(short) 和 BV17x411w7KC"
        let source = message as NSString
        let shortRange = source.range(of: short)
        let bvidRange = source.range(of: "BV17x411w7KC")
        let iconURL = try #require(URL(string: "https://i0.hdslb.com/bfs/icon.png"))
        let content = CommentContent(
            message: message,
            links: [
                CommentLink(
                    range: CommentTextRange(
                        location: shortRange.location,
                        length: shortRange.length
                    ),
                    target: .shortLink(fixtureLinkReference()),
                    title: "韩语版《朋友的酒》",
                    icon: fixtureAssetReference()
                ),
                CommentLink(
                    range: CommentTextRange(location: bvidRange.location, length: bvidRange.length),
                    target: .video(bvid: "BV17x411w7KC", page: nil, startSeconds: nil)
                )
            ]
        )
        let rendered = makeCommentTextRenderer(resolveURL: { _, _ in iconURL }).render(
            content,
            scope: NativePlaybackCommentTextScope(
                subject: .video(aid: 700_001),
                rootID: CommentID(rawValue: 1),
                revision: 1
            )
        )
        let text = rendered.attributedString.string as NSString
        let titleRange = text.range(of: "韩语版《朋友的酒》")
        let iconLocation = titleRange.location - 1
        func link(at location: Int) -> String? {
            rendered.attributedString.attribute(.link, at: location, effectiveRange: nil) as? String
        }

        #expect(!rendered.attributedString.string.contains(short))
        #expect(titleRange.location != NSNotFound)
        #expect(
            rendered.attributedString.attribute(.attachment, at: iconLocation, effectiveRange: nil)
                is NSTextAttachment
        )
        #expect(link(at: iconLocation) == "bilikit-comment-link-0")
        #expect(link(at: titleRange.location) == "bilikit-comment-link-0")
        #expect(link(at: text.range(of: "BV17x411w7KC").location) == "bilikit-comment-link-1")
        #expect(rendered.pendingAssets.map(\.url) == [iconURL])
    }

    /// 图标地址不合规（解析不出）时只显示标题。
    @Test
    @MainActor
    func titledLinksWithoutAUsableIconShowOnlyTheTitle() {
        let content = CommentContent(
            message: "https://b23.tv/Jf3cvv2",
            links: [
                CommentLink(
                    range: CommentTextRange(location: 0, length: 22),
                    target: .shortLink(fixtureLinkReference()),
                    title: "视频标题",
                    icon: fixtureAssetReference()
                )
            ]
        )

        let rendered = makeCommentTextRenderer().render(
            content,
            scope: NativePlaybackCommentTextScope(
                subject: .video(aid: 700_001),
                rootID: CommentID(rawValue: 1),
                revision: 1
            )
        )

        #expect(rendered.attributedString.string == "视频标题")
        #expect(rendered.pendingAssets.isEmpty)
        #expect(rendered.accessibilityText == "视频标题")
    }

    /// 图标在本作用域加载失败后重新渲染：只剩标题，不再登记加载；读屏文本读标题而不是网址。
    @Test
    @MainActor
    func failedLinkIconsFallBackToTheTitle() throws {
        let icon = fixtureAssetReference()
        let iconURL = try #require(URL(string: "https://i0.hdslb.com/bfs/icon.png"))
        let content = CommentContent(
            message: "看 https://b23.tv/Jf3cvv2",
            links: [
                CommentLink(
                    range: CommentTextRange(location: 2, length: 22),
                    target: .shortLink(fixtureLinkReference()),
                    title: "视频标题",
                    icon: icon
                )
            ]
        )
        let scope = NativePlaybackCommentTextScope(
            subject: .video(aid: 700_001),
            rootID: CommentID(rawValue: 1),
            revision: 1
        )
        let renderer = makeCommentTextRenderer(resolveURL: { _, _ in iconURL })
        renderer.retainFailureScopes([scope])
        #expect(renderer.render(content, scope: scope).pendingAssets.count == 1)

        #expect(renderer.markUnavailable(icon, in: scope))
        let rendered = renderer.render(content, scope: scope)

        #expect(rendered.attributedString.string == "看 视频标题")
        #expect(rendered.pendingAssets.isEmpty)
        #expect(rendered.accessibilityText == "看 视频标题")
    }

    /// 表情优先：与表情重叠的链接不替换成图标与标题，表情照常显示；读屏文本保留表情原文。
    @Test
    @MainActor
    func emotesWinOverOverlappingDecoratedLinks() throws {
        let emoteURL = try #require(URL(string: "https://i0.hdslb.com/bfs/emote.png"))
        let content = CommentContent(
            message: "[原神_哈哈]",
            emotes: [
                CommentEmote(
                    text: "[原神_哈哈]",
                    range: CommentTextRange(location: 0, length: 7),
                    asset: fixtureAssetReference(),
                    size: .standard
                )
            ],
            links: [
                CommentLink(
                    range: CommentTextRange(location: 1, length: 2),
                    target: .video(bvid: "BV1xx411c7mD", page: nil, startSeconds: nil),
                    title: "游戏",
                    icon: fixtureAssetReference()
                )
            ]
        )

        let rendered = makeCommentTextRenderer(resolveURL: { _, _ in emoteURL }).render(
            content,
            scope: NativePlaybackCommentTextScope(
                subject: .video(aid: 700_001),
                rootID: CommentID(rawValue: 1),
                revision: 1
            )
        )

        #expect(rendered.attributedString.length == 1)
        #expect(
            rendered.attributedString.attribute(.attachment, at: 0, effectiveRange: nil)
                is NSTextAttachment
        )
        #expect(rendered.accessibilityText == "[原神_哈哈]")
    }

    /// 时间戳只在播放器已装好（有上限）且不超出当前分 P 时长时显示为链接。
    @Test
    @MainActor
    func timestampsLinkOnlyWithinTheCurrentPartDuration() {
        let content = CommentContent(
            message: "1:00 和 5:00",
            links: [
                CommentLink(
                    range: CommentTextRange(location: 0, length: 4),
                    target: .timestamp(seconds: 60)
                ),
                CommentLink(
                    range: CommentTextRange(location: 7, length: 4),
                    target: .timestamp(seconds: 300)
                )
            ]
        )
        let scope = NativePlaybackCommentTextScope(
            subject: .video(aid: 700_001),
            rootID: CommentID(rawValue: 1),
            revision: 1
        )
        let renderer = makeCommentTextRenderer()

        #expect(renderer.render(content, scope: scope).linkTargets.isEmpty)
        renderer.timestampLimitSeconds = 120
        #expect(renderer.render(content, scope: scope).linkTargets == [.timestamp(seconds: 60)])
        renderer.timestampLimitSeconds = 300
        #expect(renderer.render(content, scope: scope).linkTargets == [.timestamp(seconds: 60)])
    }

    /// 悬停提示：站外链接与短链提示真实地址（短链换成标题后仍在），应用内目标不提示；文本视图不弹出
    /// 系统按内部链接值生成的提示。
    @Test
    @MainActor
    func onlyLinksLeavingTheAppShowTheirAddressOnHover() throws {
        let short = "https://b23.tv/Jf3cvv2"
        let external = "https://example.com/shop"
        let message = "\(short) \(external) BV17x411w7KC @回复用户"
        let source = message as NSString
        func range(of text: String) -> CommentTextRange {
            let range = source.range(of: text)
            return CommentTextRange(location: range.location, length: range.length)
        }
        let content = CommentContent(
            message: message,
            links: [
                CommentLink(
                    range: range(of: short),
                    target: .shortLink(
                        CommentExternalLinkReference(remoteURL: try #require(URL(string: short)))
                    ),
                    title: "视频标题"
                ),
                CommentLink(
                    range: range(of: external),
                    target: .external(
                        CommentExternalLinkReference(remoteURL: try #require(URL(string: external)))
                    )
                ),
                CommentLink(
                    range: range(of: "BV17x411w7KC"),
                    target: .video(bvid: "BV17x411w7KC", page: nil, startSeconds: nil)
                ),
                CommentLink(
                    range: range(of: "@回复用户"),
                    target: .member(
                        CommentAuthor(id: CommentAuthorID(rawValue: "301"), name: "回复用户")
                    )
                )
            ]
        )
        let rendered = makeCommentTextRenderer().render(
            content,
            scope: NativePlaybackCommentTextScope(
                subject: .video(aid: 700_001),
                rootID: CommentID(rawValue: 1),
                revision: 1
            )
        )
        let text = rendered.attributedString.string as NSString
        func toolTip(at text: String) -> String? {
            let location = (rendered.attributedString.string as NSString).range(of: text).location
            return rendered.attributedString.attribute(.toolTip, at: location, effectiveRange: nil)
                as? String
        }

        #expect(text.range(of: short).location == NSNotFound)
        #expect(toolTip(at: "视频标题") == short)
        #expect(toolTip(at: external) == external)
        #expect(toolTip(at: "BV17x411w7KC") == nil)
        #expect(toolTip(at: "@回复用户") == nil)

        let textView = NSTextView()
        NativePlaybackTextLinks.configure(textView)
        #expect(!textView.displaysLinkToolTips)
    }

    @Test
    @MainActor
    func commentRendererMapsLinkAttributesToTargetsAndSkipsInvalidRanges() {
        let message = "跳转 BV1FixtureA1 查看视频 @回复用户"
        let videoRange = (message as NSString).range(of: "BV1FixtureA1")
        let memberRange = (message as NSString).range(of: "@回复用户")
        let content = CommentContent(
            message: message,
            links: [
                CommentLink(
                    range: CommentTextRange(
                        location: videoRange.location,
                        length: videoRange.length
                    ),
                    target: .video(bvid: "BV1FixtureA1", page: nil, startSeconds: nil)
                ),
                CommentLink(
                    range: CommentTextRange(location: message.utf16.count, length: 4),
                    target: .video(bvid: "BV1OutOfRange", page: nil, startSeconds: nil)
                ),
                CommentLink(
                    range: CommentTextRange(
                        location: memberRange.location,
                        length: memberRange.length
                    ),
                    target: .member(
                        CommentAuthor(id: CommentAuthorID(rawValue: "301"), name: "回复用户")
                    )
                )
            ]
        )
        let rendered = makeCommentTextRenderer().render(
            content,
            scope: NativePlaybackCommentTextScope(
                subject: .video(aid: 700_001),
                rootID: CommentID(rawValue: 1),
                revision: 1
            )
        )
        func target(at location: Int) -> CommentLinkTarget? {
            guard
                let value = rendered.attributedString.attribute(
                    .link,
                    at: location,
                    effectiveRange: nil
                ) as? String,
                value.hasPrefix("bilikit-comment-link-"),
                let index = Int(value.dropFirst("bilikit-comment-link-".count)),
                rendered.linkTargets.indices.contains(index)
            else { return nil }
            return rendered.linkTargets[index]
        }

        #expect(
            rendered.linkTargets == [
                .video(bvid: "BV1FixtureA1", page: nil, startSeconds: nil),
                .member(CommentAuthor(id: CommentAuthorID(rawValue: "301"), name: "回复用户"))
            ]
        )
        #expect(
            target(at: videoRange.location)
                == .video(bvid: "BV1FixtureA1", page: nil, startSeconds: nil)
        )
        #expect(
            target(at: memberRange.location)
                == .member(CommentAuthor(id: CommentAuthorID(rawValue: "301"), name: "回复用户"))
        )
        #expect(target(at: 0) == nil)
    }

    @Test
    @MainActor
    func commentEmoteRendererUsesFixedTextKitAttachmentsAndLiteralFallback() throws {
        let asset = fixtureAssetReference()
        let url = try #require(
            URL(string: "https://i0.hdslb.com/bfs/emote/doge.png")
        )
        let renderer = makeCommentTextRenderer { reference, _ in
            reference == asset ? url : nil
        }
        let content = CommentContent(
            message: "前[doge]后",
            emotes: [
                CommentEmote(
                    text: "[doge]",
                    range: CommentTextRange(location: 1, length: 6),
                    asset: asset,
                    size: .standard
                )
            ]
        )
        let scope = NativePlaybackCommentTextScope(
            subject: .video(aid: 1),
            rootID: CommentID(rawValue: 10),
            revision: 1
        )

        let rendered = renderer.render(content, scope: scope)
        let attachment = try #require(
            rendered.attributedString.attribute(
                .attachment,
                at: 1,
                effectiveRange: nil
            ) as? NSTextAttachment
        )

        #expect(rendered.attributedString.string == "前\u{fffc}后")
        #expect(attachment.bounds.size == NSSize(width: 18, height: 18))
        #expect(attachment.bounds.origin.y == NSFont.preferredFont(forTextStyle: .body).descender)
        #expect(!attachment.allowsTextAttachmentView)
        #expect(rendered.pendingAssets.map(\.reference) == [asset])

        renderer.retainFailureScopes([scope])
        #expect(renderer.markUnavailable(asset, in: scope))
        #expect(renderer.markUnavailable(asset, in: scope))
        let fallback = renderer.render(content, scope: scope)
        #expect(fallback.attributedString.string == content.message)
        #expect(fallback.pendingAssets.isEmpty)

        let otherScope = NativePlaybackCommentTextScope(
            subject: .video(aid: 2),
            rootID: CommentID(rawValue: 10),
            revision: 1
        )
        #expect(renderer.render(content, scope: otherScope).pendingAssets.count == 1)
        renderer.retainFailureScopes([otherScope])
        #expect(renderer.render(content, scope: scope).pendingAssets.count == 1)
    }

    @Test
    @MainActor
    func commentEmoteFailureCacheIsBoundedByStableRenderScope() throws {
        let asset = fixtureAssetReference()
        let url = try #require(
            URL(string: "https://i0.hdslb.com/bfs/emote/doge.png")
        )
        let renderer = makeCommentTextRenderer { reference, _ in
            reference == asset ? url : nil
        }
        let content = CommentContent(
            message: "[doge]",
            emotes: [
                CommentEmote(
                    text: "[doge]",
                    range: CommentTextRange(location: 0, length: 6),
                    asset: asset,
                    size: .standard
                )
            ]
        )
        let scopes = (0...512).map {
            NativePlaybackCommentTextScope(
                subject: .video(aid: 1),
                rootID: CommentID(rawValue: 10),
                revision: $0
            )
        }

        renderer.retainFailureScopes(Set(scopes))
        for scope in scopes {
            #expect(renderer.markUnavailable(asset, in: scope))
        }

        #expect(renderer.render(content, scope: scopes[0]).pendingAssets.count == 1)
        #expect(renderer.render(content, scope: scopes[512]).pendingAssets.isEmpty)
    }

    @Test
    @MainActor
    func lateCommentEmoteFailureCannotReenterAnInactiveScope() throws {
        let asset = fixtureAssetReference()
        let url = try #require(
            URL(string: "https://i0.hdslb.com/bfs/emote/doge.png")
        )
        let renderer = makeCommentTextRenderer { reference, _ in
            reference == asset ? url : nil
        }
        let content = CommentContent(
            message: "[doge]",
            emotes: [
                CommentEmote(
                    text: "[doge]",
                    range: CommentTextRange(location: 0, length: 6),
                    asset: asset,
                    size: .standard
                )
            ]
        )
        let scopeA = NativePlaybackCommentTextScope(
            subject: .video(aid: 1),
            rootID: CommentID(rawValue: 10),
            revision: 1
        )
        let scopeB = NativePlaybackCommentTextScope(
            subject: .video(aid: 2),
            rootID: CommentID(rawValue: 20),
            revision: 1
        )

        renderer.retainFailureScopes([scopeA])
        renderer.retainFailureScopes([scopeB])
        #expect(!renderer.markUnavailable(asset, in: scopeA))
        renderer.retainFailureScopes([scopeA])

        #expect(renderer.render(content, scope: scopeA).pendingAssets.count == 1)
    }

    @Test
    @MainActor
    func largeAndUnknownCommentEmotesKeepExplicitMeasurementSemantics() throws {
        let largeAsset = fixtureAssetReference()
        let unknownAsset = fixtureAssetReference()
        let url = try #require(
            URL(string: "https://i0.hdslb.com/bfs/emote/large.png")
        )
        let renderer = makeCommentTextRenderer { reference, _ in
            reference == largeAsset ? url : nil
        }
        let content = CommentContent(
            message: "[大][未知]",
            emotes: [
                CommentEmote(
                    text: "[大]",
                    range: CommentTextRange(location: 0, length: 3),
                    asset: largeAsset,
                    size: .large
                ),
                CommentEmote(
                    text: "[未知]",
                    range: CommentTextRange(location: 3, length: 4),
                    asset: unknownAsset,
                    size: .unknown
                )
            ]
        )
        let scope = NativePlaybackCommentTextScope(
            subject: .video(aid: 1),
            rootID: CommentID(rawValue: 11),
            revision: 1
        )

        let rendered = renderer.render(content, scope: scope)
        let attachment = try #require(
            rendered.attributedString.attribute(
                .attachment,
                at: 0,
                effectiveRange: nil
            ) as? NSTextAttachment
        )

        #expect(rendered.attributedString.string == "\u{fffc}[未知]")
        #expect(attachment.bounds.size == NSSize(width: 36, height: 36))
        #expect(attachment.bounds.origin.y == NSFont.preferredFont(forTextStyle: .body).descender)
        #expect(
            renderer.height(content, commentID: CommentID(rawValue: 11), width: 200, scope: scope)
                >= 36
        )
    }

    /// 大表情在本作用域加载失败、改回原文后，同一宽度下的正文高度按原文重新计算，不沿用带表情时的高度。
    @Test
    @MainActor
    func bodyHeightFollowsTheFallbackAfterAnEmoteFails() throws {
        let asset = fixtureAssetReference()
        let url = try #require(URL(string: "https://i0.hdslb.com/bfs/emote/large.png"))
        let renderer = makeCommentTextRenderer { _, _ in url }
        let content = CommentContent(
            message: "[大]",
            emotes: [
                CommentEmote(
                    text: "[大]",
                    range: CommentTextRange(location: 0, length: 3),
                    asset: asset,
                    size: .large
                )
            ]
        )
        let scope = NativePlaybackCommentTextScope(
            subject: .video(aid: 1),
            rootID: CommentID(rawValue: 11),
            revision: 1
        )
        let commentID = CommentID(rawValue: 11)
        renderer.retainFailureScopes([scope])
        let withEmote = renderer.height(content, commentID: commentID, width: 200, scope: scope)

        #expect(renderer.markUnavailable(asset, in: scope))
        let fallback = renderer.height(content, commentID: commentID, width: 200, scope: scope)

        #expect(withEmote >= 36)
        #expect(fallback < withEmote)
    }
}
