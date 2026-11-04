import AppKit
import BiliApplication
import BiliModels
import BiliUI
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// 评论行的作者、徽章、图片、楼中楼与状态行按评论内容呈现：空间与图片预览入口只在数据合法时提供，读屏文字不复用过期状态。
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PlaybackSidebarCommentRowTests: PlaybackSidebarFixtures {
    /// 认证优先于大会员，个人与机构认证分开，普通用户没有角标。
    @Test(
        arguments: [
            (.personal(description: nil), false, .personalVerification),
            (.personal(description: nil), true, .personalVerification),
            (.organization(description: nil), true, .organizationVerification),
            (nil, true, .vip),
            (nil, false, nil)
        ] as [(CommentVerification?, Bool, NativeCommentAvatarMark?)]
    )
    func commentAvatarMarkPrefersVerificationOverVIP(
        verification: CommentVerification?,
        isVIP: Bool,
        expected: NativeCommentAvatarMark?
    ) {
        let author = CommentAuthor(
            id: CommentAuthorID(rawValue: "author"),
            name: "昵称",
            isVIP: isVIP,
            verification: verification
        )

        #expect(NativeCommentAvatarMark(author: author) == expected)
    }

    /// 评论区已关闭成为终态说明行，其余失败仍是失败状态行。
    @Test
    @MainActor
    func closedCommentSectionBecomesATerminalStateRow() async {
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        for (error, kind) in [
            (CommentReadError.closed, NativePlaybackCommentsStateKind.closed),
            (.transportFailure, .failed(.transportFailure))
        ] {
            let comments = await liveCommentsPresentation(subject: subject, rootFailure: error)
            #expect(
                presentation(bvid: "BVCurrent", comments: comments).itemIDs.last
                    == .commentsState(subject: subject, kind: kind)
            )
        }
    }

    @Test
    @MainActor
    func commentLoadingAccessibilityDoesNotReuseStaleCountOrFooterState() async throws {
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        // 总数取不易与界面其他数字相撞的值，按可见计数文字定位时不会找错控件。
        let loaded = await liveCommentsPresentation(
            subject: subject,
            threads: [commentThread(id: 1, message: "正文")],
            totalCount: 12_345
        )
        let loading = await liveCommentsPresentation(
            subject: subject,
            sort: .latest,
            rootIsLoading: true
        )
        let header = NativePlaybackCommentsHeaderItem()
        header.configure(presentation: loaded, onSelectSort: { _ in })
        let loadedCount = CommentPresentationFormatting.compactCount(
            loaded.totalCount
        )
        let countLabels = descendants(of: header.view).compactMap { $0 as? NSTextField }
            .filter { $0.stringValue == loadedCount }
        try #require(countLabels.count == 1)
        let countLabel = countLabels[0]
        #expect(countLabel.isAccessibilityElement())
        #expect(
            countLabel.accessibilityLabel()
                == VideoDetailFeatureStrings.localized("共 \(loadedCount) 条评论")
        )
        header.configure(presentation: loading, onSelectSort: { _ in })
        #expect(countLabel.stringValue.isEmpty)
        #expect(countLabel.accessibilityLabel() == nil)
        #expect(!countLabel.isAccessibilityElement())

        let footer = NativePlaybackCommentsFooterItem()
        footer.configure(footer: .loading, onRetry: {}, onLoadMore: {})
        #expect(footer.view.isAccessibilityElement())
        #expect(footer.view.accessibilityRole() == .staticText)
        #expect(
            footer.view.accessibilityLabel()
                == VideoDetailFeatureStrings.localized("后续评论加载中")
        )
        footer.configure(footer: .failed(.transportFailure), onRetry: {}, onLoadMore: {})
        #expect(!footer.view.isAccessibilityElement())
        var loadMoreCount = 0
        footer.configure(
            footer: .loadMore,
            onRetry: {},
            onLoadMore: { loadMoreCount += 1 }
        )
        let loadMoreButton = try #require(
            descendants(of: footer.view).compactMap { $0 as? NSButton }
                .first {
                    !$0.isHidden && $0.title == VideoDetailFeatureStrings.localized("加载更多")
                }
        )
        loadMoreButton.performClick(nil)
        #expect(loadMoreCount == 1)
        footer.configure(
            footer: .end(memoryLimited: false),
            onRetry: {},
            onLoadMore: {}
        )
        #expect(!footer.view.isAccessibilityElement())
    }

    @Test
    @MainActor
    func commentsFooterOnlyClaimsAllCommentsForServerEnd() async throws {
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let threads = [commentThread(id: 1, message: "正文")]
        let stopped = await liveCommentsPresentation(
            subject: subject,
            threads: threads,
            totalCount: 2,
            next: .duplicate
        )
        let ended = await liveCommentsPresentation(
            subject: subject,
            threads: threads,
            totalCount: 2,
            next: .serverEnd
        )

        #expect(stopped.footer == .stopped)
        #expect(ended.footer == .end(memoryLimited: false))
    }

    @Test
    @MainActor
    func commentPictureLayoutMatchesTheBoundedOfficialWebFlow() {
        let portrait = CommentImage(
            asset: fixtureAssetReference(),
            position: 0,
            pixelWidth: 270,
            pixelHeight: 360
        )
        let landscape = CommentImage(
            asset: fixtureAssetReference(),
            position: 1,
            pixelWidth: 446,
            pixelHeight: 270
        )

        let layout = NativePlaybackCommentPictureLayout.make(
            images: [portrait, landscape],
            count: 2,
            availableWidth: 408
        )

        #expect(layout.size == CGSize(width: 364, height: 180))
        #expect(
            layout.frames == [
                CGRect(x: 0, y: 0, width: 135, height: 180),
                CGRect(x: 139, y: 0, width: 223, height: 135)
            ]
        )
    }

    @Test
    @MainActor
    func commentPicturesOpenAMetadataDrivenGalleryAndSkipStaleFocusRestore() throws {
        let first = fixtureAssetReference()
        let third = fixtureAssetReference()
        let pictures = [
            CommentImage(
                asset: first,
                position: 0,
                pixelWidth: 270,
                pixelHeight: 360
            ),
            CommentImage(
                asset: third,
                position: 2,
                pixelWidth: 446,
                pixelHeight: 270
            )
        ]
        let slots = NativePlaybackCommentPictureSlots.slots(
            images: pictures,
            count: 3
        )
        #expect(slots.map(\.reference) == [first, nil, third])
        #expect(slots.map(\.pixelWidth) == [270, nil, 446])
        #expect(slots.map(\.pixelHeight) == [360, nil, 270])

        let layout = NativePlaybackCommentPictureLayout.make(
            slots: slots,
            availableWidth: 408
        )
        #expect(layout.size == CGSize(width: 364, height: 319))
        #expect(layout.frames[0].size == CGSize(width: 135, height: 180))
        #expect(layout.frames[1].size == CGSize(width: 120, height: 120))
        #expect(layout.frames[2].origin == CGPoint(x: 0, y: 184))
        #expect(layout.frames[2].size == CGSize(width: 223, height: 135))

        let row = NativePlaybackCommentThreadPresentation(
            subject: .video(aid: 700_001),
            thread: commentThread(
                id: 7,
                message: "带图评论",
                pictures: pictures,
                pictureCount: 3
            ),
            replyState: nil
        )
        let item = NativePlaybackCommentThreadItem()
        var openedGallery: NativePlaybackCommentPictureGallery?
        configureThreadItem(
            item,
            with: row,
            onOpenPictures: { openedGallery = $0 }
        )

        let thirdPictureButton = try #require(
            descendants(of: item.view).compactMap { $0 as? NSButton }.first {
                $0.accessibilityLabel()
                    == VideoDetailFeatureStrings.localized("查看第 \(3) 张评论图片")
            }
        )
        thirdPictureButton.performClick(nil)
        #expect(openedGallery?.references == [first, third])
        #expect(openedGallery?.selectedIndex == 1)

        let focusWindow = NSWindow(
            contentRect: item.view.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let fallbackResponder = NSButton()
        item.view.addSubview(fallbackResponder)
        focusWindow.contentView = item.view
        let replacement = fixtureAssetReference()
        let replacementRow = NativePlaybackCommentThreadPresentation(
            subject: .video(aid: 700_001),
            thread: commentThread(
                id: 7,
                message: "已复用评论",
                pictures: [
                    CommentImage(
                        asset: replacement,
                        position: 2,
                        pixelWidth: 446,
                        pixelHeight: 270
                    )
                ],
                pictureCount: 3
            ),
            replyState: nil
        )
        configureThreadItem(item, with: replacementRow)
        focusWindow.makeFirstResponder(fallbackResponder)

        openedGallery?.restoreFocus()

        #expect(focusWindow.firstResponder === fallbackResponder)

        item.releaseOffscreenResources()
        item.prepareForReuse()
        focusWindow.contentView = NSView()
    }

    @Test
    @MainActor
    func crowdedAuthorBadgesMergeHardcoreIntoLevelAndStatusBadgesStayOrdered() {
        let author = CommentAuthor(
            id: CommentAuthorID(rawValue: "crowded-author"),
            name: "昵称应该完整显示",
            sex: .male,
            level: 6,
            isHardcoreMember: true,
            isVIP: true,
            isUploader: true
        )
        let statusBadges = NativePlaybackCommentProvenanceBadgesView()
        statusBadges.configure([.uploaderLiked, .uploaderPinned])

        #expect(
            NativePlaybackCommentAuthorBadgesView.segments(for: author).map(\.text)
                == ["♂", "LV6⚡︎", "UP"]
        )
        let pinned = VideoDetailFeatureStrings.localized("置顶")
        let uploaderLiked = VideoDetailFeatureStrings.localized("UP 主觉得很赞")
        #expect(statusBadges.displayedTexts == [pinned, uploaderLiked])
        #expect(
            statusBadges.accessibilityLabel()
                == ListFormatter.localizedString(byJoining: statusBadges.displayedTexts)
        )
    }

    @Test(
        arguments: [
            (21, CommentAuthorSex.male, false),
            (22, CommentAuthorSex.female, false),
            (23, CommentAuthorSex.unspecified, true)
        ]
    )
    @MainActor
    func commentAuthorNameColorOnlyReflectsVIPState(
        id: Int,
        sex: CommentAuthorSex,
        isVIP: Bool
    ) throws {
        let expectedColor = isVIP ? NSColor.systemPink : NSColor.labelColor
        let author = CommentAuthor(
            id: CommentAuthorID(rawValue: "author-\(id)"),
            name: "昵称\(id)",
            sex: sex,
            isVIP: isVIP
        )
        let row = NativePlaybackCommentThreadPresentation(
            subject: .video(aid: 700_001),
            thread: commentThread(id: Int64(id), message: "正文", author: author),
            replyState: nil
        )
        let item = NativePlaybackCommentThreadItem()
        configureThreadItem(item, with: row)

        let authorLabel = try #require(
            descendants(of: item.view).compactMap { $0 as? NSTextField }.first {
                $0.stringValue == author.name
            }
        )
        #expect(authorLabel.textColor == expectedColor)
    }

    /// 根评论与楼中楼回复的作者都提供“查看空间”，打开对应作者；MID 不合法的作者没有入口。
    @Test
    @MainActor
    func commentAuthorsOfferSpaceEntryOnlyForValidMemberIDs() throws {
        let rootAuthor = CommentAuthor(id: CommentAuthorID(rawValue: "1001"), name: "根评论作者")
        let replyAuthor = CommentAuthor(id: CommentAuthorID(rawValue: "1002"), name: "回复作者")
        let invalidAuthor = CommentAuthor(
            id: CommentAuthorID(rawValue: "author-x"),
            name: "无效作者"
        )
        let presentation = NativePlaybackCommentThreadPresentation(
            subject: .video(aid: 700_001),
            thread: commentThread(
                id: 31,
                message: "正文",
                replyCount: 2,
                preview: [
                    comment(id: 32, rootID: 31, message: "回复", author: replyAuthor),
                    comment(id: 33, rootID: 31, message: "回复", author: invalidAuthor)
                ],
                author: rootAuthor
            ),
            replyState: nil
        )
        var opened: [CommentAuthorID] = []
        let item = NativePlaybackCommentThreadItem()
        configureThreadItem(
            item,
            with: presentation,
            onOpenAuthorSpace: { opened.append($0.id) }
        )
        func spaceAction(for name: String) throws -> NSAccessibilityCustomAction? {
            let label = try #require(
                descendants(of: item.view).compactMap { $0 as? NSTextField }.first {
                    $0.stringValue == name
                }
            )
            return label.accessibilityCustomActions()?.first
        }

        let rootAction = try #require(try spaceAction(for: rootAuthor.name))
        #expect(rootAction.name == VideoDetailFeatureStrings.localized("查看空间"))
        #expect(rootAction.handler?() == true)
        #expect(try spaceAction(for: replyAuthor.name)?.handler?() == true)
        #expect(try spaceAction(for: invalidAuthor.name) == nil)
        #expect(opened == [rootAuthor.id, replyAuthor.id])
    }

    /// 进入空间的身份：正整数 MID、评论昵称，头像经评论资源解析器取得。
    @Test
    func commentAuthorSpaceOwnerUsesMemberIDAndResolvedAvatar() throws {
        let avatar = fixtureAssetReference()
        let avatarURL = try #require(URL(string: "https://i0.hdslb.com/bfs/face/a.jpg"))
        let resolver: CommentAssetURLResolver = { reference, _ in
            reference == avatar ? avatarURL : nil
        }
        let author = CommentAuthor(
            id: CommentAuthorID(rawValue: "1001"),
            name: "评论作者",
            avatar: avatar
        )

        #expect(
            NativePlaybackCommentAuthorSpace.owner(for: author, resolveAvatar: resolver)
                == VideoOwner(id: 1001, name: "评论作者", avatarURL: avatarURL)
        )
        for rawValue in ["", "0", "-1", "author-x"] {
            let invalid = CommentAuthor(id: CommentAuthorID(rawValue: rawValue), name: "无效")
            #expect(!NativePlaybackCommentAuthorSpace.isOpenable(invalid))
            #expect(
                NativePlaybackCommentAuthorSpace.owner(for: invalid, resolveAvatar: resolver)
                    == nil
            )
        }
    }

    /// 正文 @ 提及在应用内打开空间；其他链接交给原有处理。
    @Test
    func commentMentionLinksOpenTheSpaceInsideTheApp() {
        let mentioned = CommentAuthor(id: CommentAuthorID(rawValue: "301"), name: "回复用户")
        var openedSpaces: [CommentAuthor] = []
        var otherLinks: [CommentLinkTarget] = []
        func open(_ target: CommentLinkTarget) {
            NativePlaybackCommentAuthorSpace.openLink(
                target,
                openSpace: { openedSpaces.append($0) },
                otherwise: { otherLinks.append($0) }
            )
        }

        open(.member(mentioned))
        open(.video(bvid: "BV1FixtureA1", page: nil, startSeconds: nil))

        #expect(openedSpaces == [mentioned])
        #expect(otherLinks == [.video(bvid: "BV1FixtureA1", page: nil, startSeconds: nil)])
    }

    @Test(arguments: [2, 3])
    @MainActor
    func replySummaryRemainsAvailableWhenPreviewAlreadyShowsEveryReply(
        replyCount: Int
    ) throws {
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let previews = [
            comment(id: 31, rootID: 3, message: "回复一"),
            comment(id: 32, rootID: 3, message: "回复二")
        ]

        let row = NativePlaybackCommentThreadPresentation(
            subject: subject,
            thread: commentThread(
                id: 3,
                message: "正文",
                replyCount: replyCount,
                preview: previews
            ),
            replyState: nil
        )
        let item = NativePlaybackCommentThreadItem()
        configureThreadItem(item, with: row)

        let summary = descendants(of: item.view).compactMap { $0 as? NSButton }
            .first {
                $0.title
                    == VideoDetailFeatureStrings.localized(
                        "共 \(CommentPresentationFormatting.compactCount(replyCount)) 条回复"
                    )
            }
        #expect(summary != nil)
    }

    /// 头像角标按种类、根评论或回复、屏幕倍数与外观渲染一次，之后共用同一张图；深浅色各有一张。
    @Test
    @MainActor
    func avatarMarkImagesAreRenderedOncePerKindScaleAndAppearance() throws {
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        let first = try #require(
            NativeCommentAvatarMark.vip.image(isReply: false, scale: 2, appearance: light)
        )
        let again = try #require(
            NativeCommentAvatarMark.vip.image(isReply: false, scale: 2, appearance: light)
        )
        let darkImage = try #require(
            NativeCommentAvatarMark.vip.image(isReply: false, scale: 2, appearance: dark)
        )
        let reply = try #require(
            NativeCommentAvatarMark.vip.image(isReply: true, scale: 2, appearance: light)
        )

        #expect(first === again)
        #expect(first !== darkImage)
        #expect(first.width == Int((NativeCommentAvatarMark.size(isReply: false) * 2).rounded(.up)))
        #expect(reply.width == Int((NativeCommentAvatarMark.size(isReply: true) * 2).rounded(.up)))
    }
}
