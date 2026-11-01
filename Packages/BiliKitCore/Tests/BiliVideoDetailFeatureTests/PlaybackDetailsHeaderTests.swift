import AppKit
import BiliApplication
import BiliModels
import BiliUI
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// UP 主名片与简介的排版：签名单行、简介超过五行才折叠、资料到达不改行高且只有新到的资料淡入，简介链接与时间戳按可跳转范围显示。
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PlaybackDetailsHeaderTests: PlaybackDetailsFixtures {
    @Test
    @MainActor
    func summaryCollapsesOnlyOverflowingBodyToFiveLines() {
        let summary = String(
            repeating: "简介正文需要由 TextKit 精确换行，并在超过五行时才提供展开控制。",
            count: 8
        )
        let collapsed = NativePlaybackSummaryGeometry(summary: summary, width: 240, expanded: false)
        let expanded = NativePlaybackSummaryGeometry(summary: summary, width: 240, expanded: true)
        let short = NativePlaybackSummaryGeometry(
            summary: "不足五行的简介",
            width: 240,
            expanded: false
        )

        #expect(collapsed.overflows)
        #expect(collapsed.maximumLines == NativePlaybackSummaryGeometry.collapsedLineLimit)
        #expect(collapsed.toggleFrame.height > 0)
        #expect(expanded.maximumLines == nil)
        #expect(expanded.height > collapsed.height)
        #expect(!short.overflows)
        #expect(short.maximumLines == nil)
        #expect(short.toggleFrame.height == 0)
    }

    @Test
    @MainActor
    func uploaderSignatureStaysOneLineAtAnyWidth() {
        let long = VideoUploaderHeaderContent(
            owner: VideoOwner(id: 1, name: "UP 主"),
            profileState: .loaded(UploaderProfile(signature: String(repeating: "签名", count: 40)))
        )
        let short = VideoUploaderHeaderContent(
            owner: VideoOwner(id: 1, name: "UP 主"),
            profileState: .loaded(UploaderProfile(signature: "短签名"))
        )
        let wide = NativePlaybackUploaderGeometry(content: long, width: 720)
        let narrow = NativePlaybackUploaderGeometry(content: long, width: 408)
        let shortNarrow = NativePlaybackUploaderGeometry(content: short, width: 408)

        // 长签名省略为一行，完整文字由悬停原地展开显示；高度不随宽度或长度变化。
        #expect(
            narrow.signatureTextFrame.height == NativePlaybackUploaderGeometry.signatureLineHeight
        )
        #expect(narrow.height == wide.height)
        #expect(narrow.height == shortNarrow.height)
        #expect(narrow.signatureTextFrame.maxX <= 408)
    }

    @Test
    @MainActor
    func uploaderNameCentersOnTheAvatarOnlyWithoutSignature() {
        let avatarCenter = NativePlaybackDetailsItemMeasurement.avatarSize / 2
        let withoutSignature = NativePlaybackUploaderGeometry(
            content: VideoUploaderHeaderContent(
                owner: VideoOwner(id: 1, name: "UP 主"),
                profileState: .loaded(UploaderProfile())
            ),
            width: 520
        )
        let withSignature = NativePlaybackUploaderGeometry(
            content: VideoUploaderHeaderContent(
                owner: VideoOwner(id: 1, name: "UP 主"),
                profileState: .loaded(UploaderProfile(signature: "签名"))
            ),
            width: 520
        )

        #expect(withoutSignature.nameFrame.midY == avatarCenter)
        #expect(withSignature.nameFrame.minY == 0)
    }

    /// 名片加载完成前名字保持默认色，不会先粉后灰地闪一下；大会员同时告知 VoiceOver。
    @Test(
        arguments: [
            (VideoUploaderProfileState.loading, false),
            (.loaded(UploaderProfile(isVIP: false)), false),
            (.loaded(UploaderProfile(isVIP: true)), true)
        ]
    )
    @MainActor
    func uploaderNameColorOnlyReflectsLoadedVIPState(
        profileState: VideoUploaderProfileState,
        expectsVIP: Bool
    ) throws {
        let name = "测试 UP"
        let item = NativePlaybackDetailsUploaderItem()
        item.view.frame = NSRect(x: 0, y: 0, width: 408, height: 60)
        item.configure(
            content: VideoUploaderHeaderContent(
                owner: VideoOwner(id: 1, name: name),
                profileState: profileState
            ),
            imagePipeline: StubVideoDetailImageLoader(),
            onOpenSpace: nil
        )

        let nameLabel = try #require(
            descendants(of: item.view).compactMap { $0 as? NSTextField }.first {
                $0.stringValue == name
            }
        )
        #expect(nameLabel.textColor == (expectsVIP ? .systemPink : .labelColor))
        #expect(
            nameLabel.accessibilityLabel()
                == (expectsVIP
                    ? VideoDetailFeatureStrings.localized("UP 主，\(name)，大会员")
                    : VideoDetailFeatureStrings.localized("UP 主，\(name)"))
        )
    }

    /// 只有同一行原地从“名片加载中”变为结果时淡入；首次配置、复用与已加载后的变化照常立即生效。
    @Test
    @MainActor
    func onlyArrivingUploaderProfileFadesIn() {
        func content(_ state: VideoUploaderProfileState) -> VideoUploaderHeaderContent {
            VideoUploaderHeaderContent(
                owner: VideoOwner(id: 1, name: "UP 主"),
                profileState: state
            )
        }
        let loading = content(.loading)
        let loaded = content(.loaded(UploaderProfile(signature: "签名", isVIP: true)))
        let reloaded = content(.loaded(UploaderProfile(signature: "新签名")))

        #expect(NativePlaybackUploaderProfileReveal.fades(from: loading, to: loaded))
        #expect(!NativePlaybackUploaderProfileReveal.fades(from: nil, to: loaded))
        #expect(!NativePlaybackUploaderProfileReveal.fades(from: loaded, to: reloaded))
        #expect(!NativePlaybackUploaderProfileReveal.fades(from: loaded, to: loading))
    }

    /// 过渡只覆盖 UP 主行的前提：名片各状态下行高相同，下方行不会位移。
    @Test(
        arguments: [
            VideoUploaderProfileState.loaded(UploaderProfile()),
            .loaded(UploaderProfile(signature: String(repeating: "签名", count: 40)))
        ]
    )
    @MainActor
    func uploaderRowKeepsItsHeightWhenProfileArrives(loaded: VideoUploaderProfileState) {
        func height(_ state: VideoUploaderProfileState) -> CGFloat {
            NativePlaybackUploaderGeometry(
                content: VideoUploaderHeaderContent(
                    owner: VideoOwner(id: 1, name: "UP 主"),
                    profileState: state
                ),
                width: 408
            ).height
        }

        #expect(height(.loading) == height(loaded))
    }

    /// 简介里有时间戳时，分 P 时长变化只重新配置简介这一项；没有时间戳的简介不受影响。
    @Test
    @MainActor
    func timestampLimitChangeReconfiguresSummaryOnlyWhenItHasTimestamps() throws {
        let base = try #require(presentation(bvid: "BVCurrent").content)
        let timestamp = CommentLink(
            range: CommentTextRange(location: 0, length: 4),
            target: .timestamp(seconds: 60)
        )
        func summary(
            links: [CommentLink],
            limit: Int?
        ) -> NativePlaybackDetailsPresentation {
            NativePlaybackDetailsPresentation(
                content: NativePlaybackDetailsContent(
                    bvid: base.bvid,
                    uploader: base.uploader,
                    summary: "1:00 开始",
                    summaryLinks: links,
                    selection: base.selection,
                    comments: base.comments,
                    timestampLimitSeconds: limit
                ),
                overlay: .none
            )
        }

        #expect(
            summary(links: [timestamp], limit: 600)
                .changedItemIDs(comparedTo: summary(links: [timestamp], limit: 120))
                == [.summary(bvid: "BVCurrent")]
        )
        #expect(
            summary(links: [], limit: 600)
                .changedItemIDs(comparedTo: summary(links: [], limit: 120)).isEmpty
        )
        #expect(
            summary(links: [timestamp], limit: 120)
                .changedItemIDs(comparedTo: summary(links: [], limit: 120))
                == [.summary(bvid: "BVCurrent")]
        )
    }

    /// 简介里的链接与评论正文同一套：点击交出目标；超出可跳转时长的时间戳不是链接。
    @Test
    @MainActor
    func summaryTextOpensLinksAndHidesUnreachableTimestamps() throws {
        let member = CommentAuthor(id: CommentAuthorID(rawValue: "20002"), name: "合作者")
        let text = "@合作者 2:00 9:00"
        let textView = NativePlaybackDetailsReadOnlyTextView(font: .systemFont(ofSize: 13))
        var opened: [CommentLinkTarget] = []
        textView.onOpenLink = { opened.append($0) }

        textView.setText(
            NativePlaybackDetailsLinkedText(
                text: text,
                links: [
                    CommentLink(
                        range: CommentTextRange(location: 0, length: 4),
                        target: .member(member)
                    ),
                    CommentLink(
                        range: CommentTextRange(location: 5, length: 4),
                        target: .timestamp(seconds: 120)
                    ),
                    CommentLink(
                        range: CommentTextRange(location: 10, length: 4),
                        target: .timestamp(seconds: 540)
                    )
                ],
                timestampLimitSeconds: 300
            ),
            font: .systemFont(ofSize: 13),
            color: .labelColor
        )
        let storage = try #require(textView.textStorage)
        for index in [0, 5, 10] {
            if let link = storage.attribute(.link, at: index, effectiveRange: nil) {
                _ = textView.textView(textView, clickedOnLink: link, at: index)
            }
        }

        #expect(storage.string == text)
        #expect(opened == [.member(member), .timestamp(seconds: 120)])
        #expect(storage.attribute(.link, at: 10, effectiveRange: nil) == nil)
    }
}
