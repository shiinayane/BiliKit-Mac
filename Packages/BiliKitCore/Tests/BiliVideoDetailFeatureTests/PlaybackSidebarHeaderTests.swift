import AppKit
import BiliApplication
import BiliModels
import BiliUI
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// UP 主名片与简介的排版：签名单行、简介超过五行才折叠、资料到达不改行高且只有新到的资料淡入，文字与头像一起上下居中，
/// 关注按钮紧跟名字、“查看空间”箭头在行尾、文字止于箭头左侧，点按关注按钮交出相反的目标状态；简介链接与时间戳按可跳转范围显示。
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

    /// 关注按钮紧跟名字，名字太长时先截断、按钮仍完整，按钮不越出这一行；箭头在行尾、与头像一起上下居中，文字各行止于它
    /// 左侧；有没有关注按钮不改行高；没有空间入口时文字可以到行尾。
    @Test
    @MainActor
    func followButtonFollowsTheNameAndTheSpaceArrowEndsTheRow() {
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
        let withoutSpace = NativePlaybackUploaderGeometry(
            content: content,
            width: 408,
            showsSpaceButton: false
        )

        let short = geometry.nameRow(nameWidth: 60)
        #expect(short.name.width == 60)
        #expect(
            short.followButton.minX == short.name.maxX
                + NativePlaybackUploaderGeometry.followButtonSpacing
        )
        #expect(abs(short.followButton.midY - geometry.nameFrame.midY) <= 1)
        #expect(short.followButton.minY >= 0)
        #expect(short.followButton.maxY <= geometry.height)
        #expect(short.spaceButton.maxX == 408)
        #expect(abs(short.spaceButton.midY - geometry.avatarFrame.midY) <= 1)

        let long = geometry.nameRow(nameWidth: 2_000)
        #expect(long.name.width < geometry.nameFrame.width)
        #expect(long.followButton.width == short.followButton.width)
        #expect(long.followButton.maxX <= geometry.nameFrame.maxX)
        for line in [geometry.nameFrame, geometry.statsFrame, geometry.signatureTextFrame] {
            #expect(line.maxX < long.spaceButton.minX)
        }

        #expect(geometry.height == withoutFollow.height)
        #expect(withoutFollow.nameRow(nameWidth: 60).followButton == .zero)
        #expect(withoutSpace.nameFrame.maxX == 408)
        #expect(withoutSpace.nameRow(nameWidth: 60).spaceButton == .zero)
    }

    /// 标题说明现状，读屏的值说明是否已关注，提示说明点按的结果；未关注时点按交出关注，已关注时点按交出按钮去弹「已关注」
    /// 菜单、不直接取消；没有菜单时已关注的点按照旧交出取消关注；禁用或没有关注内容时点按什么也不交出。
    @Test(arguments: [(false, true), (true, true), (true, false)])
    @MainActor
    func followButtonReportsStateAndSendsTheOppositeTarget(isFollowing: Bool, hasMenu: Bool) throws
    {
        let item = NativePlaybackSidebarUploaderItem()
        item.view.frame = NSRect(x: 0, y: 0, width: 408, height: 60)
        var requested: [Bool] = []
        var menuAnchors: [NSView] = []
        item.configure(
            content: VideoUploaderHeaderContent(
                owner: VideoOwner(id: 1, name: "UP 主"),
                profileState: .loaded(UploaderProfile()),
                follow: VideoUploaderFollowContent(isFollowing: isFollowing, isEnabled: true)
            ),
            imagePipeline: StubVideoDetailImageLoader(),
            onOpenSpace: nil,
            onSetFollowing: { requested.append($0) },
            onShowFollowingMenu: hasMenu ? { menuAnchors.append($0) } : nil
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
        let help =
            if !isFollowing {
                VideoDetailFeatureStrings.localized("关注")
            } else if hasMenu {
                VideoDetailFeatureStrings.localized("显示关注选项")
            } else {
                VideoDetailFeatureStrings.localized("取消关注")
            }
        #expect(button.toolTip == help)
        #expect(button.isEnabled)
        button.performClick(nil)
        if isFollowing, hasMenu {
            #expect(requested.isEmpty)
            #expect(menuAnchors.map(ObjectIdentifier.init) == [ObjectIdentifier(button)])
        } else {
            #expect(requested == [!isFollowing])
        }
        requested = []
        menuAnchors = []

        item.configure(
            content: VideoUploaderHeaderContent(
                owner: VideoOwner(id: 1, name: "UP 主"),
                profileState: .loaded(UploaderProfile()),
                follow: VideoUploaderFollowContent(isFollowing: isFollowing, isEnabled: false)
            ),
            imagePipeline: StubVideoDetailImageLoader(),
            onOpenSpace: nil,
            onSetFollowing: { requested.append($0) },
            onShowFollowingMenu: hasMenu ? { menuAnchors.append($0) } : nil
        )
        #expect(!button.isEnabled)
        button.performClick(nil)
        // 动作不经按钮本身送达（键盘、读屏或别的入口）时，按钮的处理同样按内容里的禁用拒绝。
        let action = try #require(button.action)
        NSApplication.shared.sendAction(action, to: button.target, from: button)
        #expect(requested.isEmpty)
        #expect(menuAnchors.isEmpty)
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
        #expect(requested.isEmpty)
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
                timestampLimits: TimestampSeekLimits(
                    selectedPageNumber: 1,
                    limitsByPageNumber: [1: 300]
                )
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
