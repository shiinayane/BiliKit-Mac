import AppKit
import BiliApplication
import BiliModels
import BiliUI
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// UP 主名片与简介的排版：签名单行、简介超过五行才折叠、资料到达不改行高且只有新到的资料淡入，文字与头像一起上下居中，
/// 关注按钮在行尾、文字止于它左侧、点按交出相反的目标状态；简介链接与时间戳按可跳转范围显示。
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PlaybackSidebarHeaderTests: PlaybackSidebarFixtures {
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
    func uploaderTextCentersWithTheAvatar() {
        func geometry(_ profile: UploaderProfile) -> NativePlaybackUploaderGeometry {
            NativePlaybackUploaderGeometry(
                content: VideoUploaderHeaderContent(
                    owner: VideoOwner(id: 1, name: "UP 主"),
                    profileState: .loaded(profile)
                ),
                width: 520
            )
        }
        let nameOnly = geometry(UploaderProfile())
        let full = geometry(
            UploaderProfile(signature: "签名", followerCount: 12_345, videoCount: 6)
        )

        #expect(abs(nameOnly.nameFrame.midY - nameOnly.avatarFrame.midY) <= 1)
        #expect(full.nameFrame.minY == 0)
        #expect(full.statsFrame.minY > full.nameFrame.maxY)
        #expect(full.signatureTextFrame.minY > full.statsFrame.maxY)
        #expect(full.signatureTextFrame.maxY <= full.height)
    }

    @Test
    @MainActor
    func followButtonSitsAtTheTrailingEdgeAndTextStopsBeforeIt() {
        let content = VideoUploaderHeaderContent(
            owner: VideoOwner(id: 1, name: "UP 主"),
            profileState: .loaded(
                UploaderProfile(
                    signature: String(repeating: "签名", count: 40),
                    followerCount: 12_345,
                    videoCount: 6
                )
            ),
            follow: VideoUploaderFollowContent(isFollowing: false, isEnabled: true)
        )
        let geometry = NativePlaybackUploaderGeometry(content: content, width: 408)
        let withoutFollow = NativePlaybackUploaderGeometry(
            content: VideoUploaderHeaderContent(
                owner: VideoOwner(id: 1, name: "UP 主"),
                profileState: .loaded(UploaderProfile(signature: "签名"))
            ),
            width: 408
        )

        #expect(geometry.followButtonFrame.maxX == 408)
        #expect(geometry.followButtonFrame.width > 0)
        for line in [geometry.nameFrame, geometry.statsFrame, geometry.signatureTextFrame] {
            #expect(line.maxX < geometry.followButtonFrame.minX)
        }
        #expect(geometry.height == withoutFollow.height)
        #expect(withoutFollow.followButtonFrame == .zero)
    }

    /// 箭头紧跟名字末尾；名字放不下时截断，箭头仍在关注按钮左侧；没有空间入口时名字可占满整段。
    @Test
    @MainActor
    func spaceArrowFollowsTheNameAndStaysBeforeTheFollowButton() {
        let geometry = NativePlaybackUploaderGeometry(
            content: VideoUploaderHeaderContent(
                owner: VideoOwner(id: 1, name: "UP 主"),
                profileState: .loaded(UploaderProfile(signature: "签名")),
                follow: VideoUploaderFollowContent(isFollowing: false, isEnabled: true)
            ),
            width: 408
        )
        let spacing = NativePlaybackUploaderGeometry.spaceButtonSpacing

        let short = geometry.nameRow(nameWidth: 60, showsSpaceButton: true)
        #expect(short.name.width == 60)
        #expect(short.spaceButton.minX == short.name.maxX + spacing)
        #expect(abs(short.spaceButton.midY - geometry.nameFrame.midY) <= 1)

        let long = geometry.nameRow(nameWidth: 2_000, showsSpaceButton: true)
        #expect(long.name.width < geometry.nameFrame.width)
        #expect(long.spaceButton.maxX <= geometry.nameFrame.maxX)
        #expect(long.spaceButton.maxX < geometry.followButtonFrame.minX)

        let withoutSpace = geometry.nameRow(nameWidth: 2_000, showsSpaceButton: false)
        #expect(withoutSpace.name.width == geometry.nameFrame.width)
        #expect(withoutSpace.spaceButton == .zero)
    }

    /// 标题说明现状，读屏的值说明是否已关注；点按交出相反的目标状态，禁用或没有关注内容时不交出。
    @Test(arguments: [false, true])
    @MainActor
    func followButtonReportsStateAndSendsTheOppositeTarget(isFollowing: Bool) throws {
        let item = NativePlaybackSidebarUploaderItem()
        item.view.frame = NSRect(x: 0, y: 0, width: 408, height: 60)
        var requested: [Bool] = []
        item.configure(
            content: VideoUploaderHeaderContent(
                owner: VideoOwner(id: 1, name: "UP 主"),
                profileState: .loaded(UploaderProfile()),
                follow: VideoUploaderFollowContent(isFollowing: isFollowing, isEnabled: true)
            ),
            imagePipeline: StubVideoDetailImageLoader(),
            onOpenSpace: nil,
            onSetFollowing: { requested.append($0) }
        )
        let button = try #require(
            descendants(of: item.view).compactMap { $0 as? NSButton }.first {
                $0.accessibilityLabel() == VideoDetailFeatureStrings.localized("关注")
            }
        )

        #expect(
            button.title
                == (isFollowing
                    ? VideoDetailFeatureStrings.localized("已关注")
                    : VideoDetailFeatureStrings.localized("关注"))
        )
        #expect(
            button.accessibilityValue() as? String
                == (isFollowing
                    ? VideoDetailFeatureStrings.localized("已关注")
                    : VideoDetailFeatureStrings.localized("未关注"))
        )
        #expect(button.isEnabled)
        button.performClick(nil)
        #expect(requested == [!isFollowing])

        item.configure(
            content: VideoUploaderHeaderContent(
                owner: VideoOwner(id: 1, name: "UP 主"),
                profileState: .loaded(UploaderProfile()),
                follow: VideoUploaderFollowContent(isFollowing: isFollowing, isEnabled: false)
            ),
            imagePipeline: StubVideoDetailImageLoader(),
            onOpenSpace: nil,
            onSetFollowing: { requested.append($0) }
        )
        #expect(!button.isEnabled)
        item.configure(
            content: VideoUploaderHeaderContent(
                owner: VideoOwner(id: 1, name: "UP 主"),
                profileState: .loaded(UploaderProfile())
            ),
            imagePipeline: StubVideoDetailImageLoader(),
            onOpenSpace: nil,
            onSetFollowing: { requested.append($0) }
        )
        #expect(button.isHidden)
        #expect(requested == [!isFollowing])
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
        let item = NativePlaybackSidebarUploaderItem()
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
            .loaded(UploaderProfile(signature: String(repeating: "签名", count: 40))),
            .loaded(UploaderProfile(followerCount: 12_345, videoCount: 6)),
            .loaded(UploaderProfile(signature: "签名", followerCount: 12_345, videoCount: 6))
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
        ) -> NativePlaybackSidebarPresentation {
            NativePlaybackSidebarPresentation(
                content: NativePlaybackSidebarContent(
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
        let textView = NativePlaybackSidebarReadOnlyTextView(font: .systemFont(ofSize: 13))
        var opened: [CommentLinkTarget] = []
        textView.onOpenLink = { opened.append($0) }

        textView.setText(
            NativePlaybackSidebarLinkedText(
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
