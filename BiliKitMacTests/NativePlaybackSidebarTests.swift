import AppKit
import BiliApplication
import BiliBrowseFeature
import BiliModels
import Foundation
import Testing

@testable import BiliKit

@Suite(.serialized)
struct NativePlaybackSidebarTests {
    @Test
    @MainActor
    func snapshotKeepsStableSemanticSectionsAndRows() {
        let presentation = presentation(bvid: "BVCurrent")

        #expect(
            presentation.sections.map(\.id)
                == [.uploader, .summary, .selection, .comments]
        )
        #expect(
            presentation.itemIDs
                == [
                    .uploader(bvid: "BVCurrent"),
                    .summary(bvid: "BVCurrent"),
                    .selection(bvid: "BVCurrent"),
                    .commentsHeader(subject: nil),
                    .commentsState(subject: nil, kind: .idle),
                ]
        )
    }

    @Test
    @MainActor
    func rootOwnsExactlyOneVerticalScrollChainWithoutHostingViews() {
        let controller = NativePlaybackSidebarController()
        controller.update(
            presentation: presentation(bvid: "BVCurrent"),
            actions: actions
        )

        let descendants = descendants(of: controller.rootView)
        let verticalScrollViews = descendants.compactMap { $0 as? NSScrollView }
            .filter(\.hasVerticalScroller)
        let hostingViews = descendants.filter {
            String(describing: type(of: $0)).contains("NSHostingView")
        }

        #expect(controller.rootView.scrollView.documentView is NSCollectionView)
        #expect(verticalScrollViews.count == 1)
        #expect(hostingViews.isEmpty)
        #expect(controller.rootView.overlayView.isFlipped)
        #expect(controller.rootView.scrollView.automaticallyAdjustsContentInsets)
        #expect(
            controller.rootView.commentsTopButton.accessibilityLabel()
                == "返回评论区顶部"
        )
        #expect(controller.rootView.commentsTopButton.action != nil)

        controller.tearDown()

        #expect(controller.rootView.scrollView.documentView == nil)
    }

    @Test
    @MainActor
    func summaryUsesSelectableNonScrollingTextKitAtSidebarWidths() throws {
        let text = String(
            repeating: "这是一段需要按字符精确换行的简介，后续链接拦截也由同一个TextKit正文视图承担。",
            count: 3
        )
        let font = NSFont.preferredFont(forTextStyle: .callout)
        let heights = [440.0, 480.0, 520.0].map { sidebarWidth in
            NativePlaybackSidebarTextLayout.height(
                text,
                width: sidebarWidth - NativePlaybackSidebarLayout.contentInset * 2,
                font: font
            )
        }
        let textView = NativePlaybackSidebarReadOnlyTextView(font: font)
        textView.frame = NSRect(x: 0, y: 0, width: 408, height: heights[0])
        textView.setText(text, font: font, color: .secondaryLabelColor)
        textView.layoutSubtreeIfNeeded()
        let container = try #require(textView.textContainer)
        let manager = try #require(textView.layoutManager)
        manager.ensureLayout(for: container)

        #expect(heights[0] >= heights[1])
        #expect(heights[1] >= heights[2])
        #expect(heights[0] > heights[2])
        #expect(textView.isSelectable)
        #expect(!textView.isEditable)
        #expect(textView.enclosingScrollView == nil)
        #expect(textView.textContainer?.lineBreakMode == .byCharWrapping)
        #expect(container.containerSize.height == CGFloat.greatestFiniteMagnitude)
        #expect(manager.usedRect(for: container).height > 0)
    }

    @Test
    @MainActor
    func summaryKeepsItsTitleStaticAndCollapsesOnlyOverflowingBodyToFiveLines() throws {
        let summary = String(
            repeating: "简介正文需要由 TextKit 精确换行，并在超过五行时才提供展开控制。",
            count: 8
        )
        let width: CGFloat = 240
        let collapsedHeight = NativePlaybackSidebarItemMeasurement.summary(
            summary,
            width: width,
            expanded: false
        )
        let expandedHeight = NativePlaybackSidebarItemMeasurement.summary(
            summary,
            width: width,
            expanded: true
        )
        let item = NativePlaybackSidebarSummaryItem()
        item.view.frame = NSRect(
            x: 0,
            y: 0,
            width: width,
            height: collapsedHeight
        )
        var toggled = false
        item.configure(summary: summary, expanded: false) {
            toggled = true
        }
        item.view.layoutSubtreeIfNeeded()

        let views = descendants(of: item.view)
        let body = try #require(views.compactMap { $0 as? NSTextView }.first)
        let expandButton = try #require(
            views.compactMap { $0 as? NSButton }.first { $0.title == "展开" }
        )
        let title = try #require(
            views.compactMap { $0 as? NSTextField }.first { $0.stringValue == "简介" }
        )

        #expect(expandedHeight > collapsedHeight)
        #expect(body.textContainer?.maximumNumberOfLines == 5)
        #expect(body.textContainer?.lineBreakMode == .byTruncatingTail)
        #expect(title.isEnabled)
        #expect(views.compactMap { $0 as? NSButton }.allSatisfy { $0.title != "简介" })
        expandButton.performClick(nil)
        #expect(toggled)

        let shortItem = NativePlaybackSidebarSummaryItem()
        shortItem.view.frame = NSRect(x: 0, y: 0, width: width, height: 80)
        shortItem.configure(summary: "不足五行的简介", expanded: false, onToggle: {})
        shortItem.view.layoutSubtreeIfNeeded()
        #expect(
            descendants(of: shortItem.view).compactMap { $0 as? NSButton }
                .allSatisfy { $0.isHidden }
        )
    }

    @Test
    @MainActor
    func blockingOverlayDoesNotOwnAFullSidebarBackdrop() {
        let overlay = NativePlaybackSidebarOverlayView()
        let views: [NSView] = [overlay] + descendants(of: overlay)

        #expect(!overlay.isOpaque)
        #expect(overlay.layer?.backgroundColor == nil)
        #expect(views.compactMap { $0 as? NSVisualEffectView }.isEmpty)
    }

    @Test
    @MainActor
    func blockingOverlayKeepsTheTransparentScrollSurfaceAndHidesOnlyItsRows() {
        let controller = NativePlaybackSidebarController()
        let loaded = presentation(bvid: "BVCurrent")
        controller.update(presentation: loaded, actions: actions)

        #expect(!controller.rootView.scrollView.isHidden)
        #expect(controller.rootView.scrollView.documentView?.isHidden == false)
        #expect(controller.rootView.overlayView.isHidden)

        controller.update(
            presentation: NativePlaybackSidebarPresentation(
                content: loaded.content,
                overlay: .loading(label: "正在加载视频上下文")
            ),
            actions: actions
        )

        #expect(!controller.rootView.scrollView.isHidden)
        #expect(controller.rootView.scrollView.documentView?.isHidden == true)
        #expect(!controller.rootView.overlayView.isHidden)
        #expect(!controller.rootView.overlayView.isOpaque)

        controller.tearDown()
    }

    @Test
    @MainActor
    func retainedFailedPageKeepsSelectionAvailableAsARecoveryPath() {
        let context = context(bvid: "BVCurrent")
        let failure = GuestVideoFailure.playback

        #expect(
            NativePlaybackSidebarOverlay.resolve(
                state: .failedPage(
                    context: context,
                    targetPage: context.pages[1],
                    failure: failure
                ),
                hasPresentedContent: true
            ) == .none
        )
    }

    @Test
    @MainActor
    func presentationReloadsOnlyTheStableRowWhoseContentChanged() throws {
        let original = presentation(bvid: "BVCurrent")
        let content = try #require(original.content)
        let updatedUploader = NativePlaybackSidebarPresentation(
            content: NativePlaybackSidebarContent(
                bvid: content.bvid,
                uploader: VideoUploaderHeaderContent(
                    owner: VideoOwner(id: 1, name: "UP 主", signature: "新签名")
                ),
                summary: content.summary,
                selection: content.selection,
                comments: content.comments
            ),
            overlay: .none
        )
        let overlayOnly = NativePlaybackSidebarPresentation(
            content: content,
            overlay: .loading(label: "正在加载所选视频上下文")
        )

        #expect(
            updatedUploader.changedItemIDs(comparedTo: original)
                == [.uploader(bvid: content.bvid)]
        )
        #expect(overlayOnly.changedItemIDs(comparedTo: original).isEmpty)
    }

    @Test
    @MainActor
    func collectionUpdatePolicySeparatesStableRowsFromCommentAppend() throws {
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let first = commentThread(id: 1, message: "第一条评论")
        let original = presentation(
            bvid: "BVCurrent",
            comments: commentsPresentation(subject: subject, threads: [first])
        )
        let changed = presentation(
            bvid: "BVCurrent",
            comments: commentsPresentation(
                subject: subject,
                threads: [commentThread(id: 1, message: "修改后的正文")]
            )
        )
        let appended = presentation(
            bvid: "BVCurrent",
            comments: commentsPresentation(
                subject: subject,
                threads: [first, commentThread(id: 2, message: "第二条评论")]
            )
        )

        #expect(
            NativePlaybackSidebarCollectionUpdatePolicy.resolve(
                current: original.snapshotSections,
                next: original.snapshotSections,
                changedItemIDs: [],
                hasSnapshotInFlight: false
            ) == .none
        )
        #expect(
            NativePlaybackSidebarCollectionUpdatePolicy.resolve(
                current: original.snapshotSections,
                next: changed.snapshotSections,
                changedItemIDs: changed.changedItemIDs(comparedTo: original),
                hasSnapshotInFlight: false
            ) == .reloadChangedItems
        )
        #expect(
            NativePlaybackSidebarCollectionUpdatePolicy.resolve(
                current: original.snapshotSections,
                next: appended.snapshotSections,
                changedItemIDs: appended.changedItemIDs(comparedTo: original),
                hasSnapshotInFlight: false
            ) == .appendComments
        )
        #expect(
            NativePlaybackSidebarCollectionUpdatePolicy.resolve(
                current: original.snapshotSections,
                next: appended.snapshotSections,
                changedItemIDs: appended.changedItemIDs(comparedTo: original),
                hasSnapshotInFlight: true
            ) == .replaceSnapshot
        )
    }

    @Test
    @MainActor
    func blockingOverlayReleasesHiddenSidebarFirstResponder() {
        let controller = NativePlaybackSidebarController()
        controller.rootView.frame = NSRect(x: 0, y: 0, width: 440, height: 600)
        let window = NSWindow(
            contentRect: controller.rootView.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.rootView
        controller.update(
            presentation: presentation(bvid: "BVCurrent"),
            actions: actions
        )
        let selectableField = NSTextField(labelWithString: "可选择的标题")
        selectableField.isSelectable = true
        controller.rootView.scrollView.documentView?.addSubview(selectableField)
        let fieldEditor = window.fieldEditor(true, for: selectableField)
        #expect(fieldEditor != nil)
        #expect(window.makeFirstResponder(fieldEditor))

        controller.update(
            presentation: NativePlaybackSidebarPresentation(
                content: presentation(bvid: "BVCurrent").content,
                overlay: .loading(label: "正在加载所选视频上下文")
            ),
            actions: actions
        )

        #expect(window.firstResponder !== fieldEditor)
        controller.tearDown()
        window.contentView = NSView()
    }

    @Test
    @MainActor
    func teardownReleasesDirectSidebarTextViewFirstResponderBeforeDetachingDocument() {
        let controller = NativePlaybackSidebarController()
        controller.rootView.frame = NSRect(x: 0, y: 0, width: 440, height: 600)
        let window = NSWindow(
            contentRect: controller.rootView.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.rootView
        controller.update(
            presentation: presentation(bvid: "BVCurrent"),
            actions: actions
        )
        let textView = NSTextView()
        controller.rootView.scrollView.documentView?.addSubview(textView)
        #expect(window.makeFirstResponder(textView))

        controller.tearDown()

        #expect(window.firstResponder !== textView)
        window.contentView = NSView()
    }

    @Test
    @MainActor
    func teardownReleasesSidebarSharedFieldEditorBeforeDetachingDocument() {
        let controller = NativePlaybackSidebarController()
        controller.rootView.frame = NSRect(x: 0, y: 0, width: 440, height: 600)
        let window = NSWindow(
            contentRect: controller.rootView.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.rootView
        controller.update(
            presentation: presentation(bvid: "BVCurrent"),
            actions: actions
        )
        let selectableField = NSTextField(labelWithString: "可选择的标题")
        selectableField.isSelectable = true
        controller.rootView.scrollView.documentView?.addSubview(selectableField)
        let fieldEditor = window.fieldEditor(true, for: selectableField)
        #expect(fieldEditor != nil)
        #expect(window.makeFirstResponder(fieldEditor))

        controller.tearDown()

        #expect(window.firstResponder !== fieldEditor)
        window.contentView = NSView()
    }

    @Test
    @MainActor
    func summaryAndUploaderRowsContainNativeTextViewsOnly() {
        let summaryItem = NativePlaybackSidebarSummaryItem()
        summaryItem.view.frame = NSRect(x: 0, y: 0, width: 328, height: 180)
        summaryItem.configure(summary: "可选择的简介正文", expanded: true, onToggle: {})

        let imageOwner = NativeVideoImagePipelineOwner()
        let uploaderItem = NativePlaybackSidebarUploaderItem()
        uploaderItem.view.frame = NSRect(x: 0, y: 0, width: 328, height: 64)
        uploaderItem.configure(
            content: VideoUploaderHeaderContent(
                owner: VideoOwner(id: 1, name: "UP 主", signature: "可选择的签名")
            ),
            signatureExpanded: false,
            imagePipeline: imageOwner.pipeline,
            onToggleSignature: {}
        )

        let views = descendants(of: summaryItem.view) + descendants(of: uploaderItem.view)
        let textViews = views.compactMap { $0 as? NSTextView }

        #expect(textViews.count == 2)
        #expect(textViews.allSatisfy { $0.isSelectable && !$0.isEditable })
        #expect(views.compactMap { $0 as? NSScrollView }.isEmpty)
        #expect(
            views.allSatisfy {
                !String(describing: type(of: $0)).contains("NSHostingView")
            }
        )

        uploaderItem.prepareForReuse()
        imageOwner.shutdown()
    }

    @Test
    @MainActor
    func uploaderSignatureRecomputesOverflowWhileSidebarResizes() throws {
        let signature = String(repeating: "签名", count: 16)
        let imageOwner = NativeVideoImagePipelineOwner()
        let item = NativePlaybackSidebarUploaderItem()
        item.view.frame = NSRect(x: 0, y: 0, width: 488, height: 80)
        item.configure(
            content: VideoUploaderHeaderContent(
                owner: VideoOwner(id: 1, name: "UP 主", signature: signature)
            ),
            signatureExpanded: false,
            imagePipeline: imageOwner.pipeline,
            onToggleSignature: {}
        )
        item.view.layoutSubtreeIfNeeded()
        let views = descendants(of: item.view)
        let signatureText = try #require(views.compactMap { $0 as? NSTextView }.first)
        let toggle = try #require(
            views.compactMap { $0 as? NSButton }
                .first { $0.accessibilityLabel() == "UP 主签名" }
        )

        #expect(toggle.isHidden)
        #expect(signatureText.textContainer?.maximumNumberOfLines == 0)
        signatureText.setSelectedRange(NSRange(location: 2, length: 4))

        item.view.frame.size.width = 408
        item.view.layoutSubtreeIfNeeded()

        #expect(!toggle.isHidden)
        #expect(toggle.title == "展开")
        #expect(signatureText.textContainer?.maximumNumberOfLines == 1)
        #expect(signatureText.selectedRange() == NSRange(location: 2, length: 4))

        item.prepareForReuse()
        imageOwner.shutdown()
    }

    @Test
    @MainActor
    func pageMenuKeepsAtomicCIDIntentInNativeMenuItems() {
        let projection = selectionProjection()
        let item = NativePlaybackSidebarSelectionItem()
        item.view.frame = NSRect(x: 0, y: 0, width: 328, height: 80)
        var selectedCID: Int64?
        item.configure(
            projection: projection,
            browsedSectionID: projection.selectedEpisodeSectionID,
            onSelectSection: { _ in },
            onSelectEpisode: { _ in },
            onSelectPage: { selectedCID = $0 },
            onRetryPages: {}
        )
        item.view.layoutSubtreeIfNeeded()

        let pagePopUp = descendants(of: item.view).compactMap { $0 as? NSPopUpButton }
            .first { !$0.isHidden }
        let targetItem = pagePopUp?.menu?.items.last {
            $0.representedObject is NSNumber
        }
        let sent = targetItem.flatMap { item in
            item.action.map {
                NSApplication.shared.sendAction($0, to: item.target, from: item)
            }
        }

        #expect(projection.showsPagePicker)
        #expect(pagePopUp != nil)
        #expect(sent == true)
        #expect(selectedCID == 1_002)
    }

    @Test
    @MainActor
    func sectionPickerLimitsEpisodePickerToTheBrowsedSection() throws {
        let first = collectionEpisode(
            sectionID: 10,
            episodeID: 100,
            bvid: "BVCurrent",
            title: "第一集"
        )
        let second = collectionEpisode(
            sectionID: 11,
            episodeID: 101,
            bvid: "BVOther",
            title: "幕后花絮"
        )
        let collection = VideoCollection(
            id: 1,
            title: "合集",
            reportedEpisodeCount: 2,
            sections: [
                collectionSection(id: 10, title: "正片", episodes: [first]),
                collectionSection(id: 11, title: "花絮", episodes: [second]),
            ]
        )
        let projection = selectionProjection(
            context: context(bvid: "BVCurrent", collection: collection)
        )
        let item = NativePlaybackSidebarSelectionItem()
        item.view.frame = NSRect(x: 0, y: 0, width: 328, height: 130)
        var browsedSectionID: VideoCollectionSectionIdentity?
        var selectedCID: Int64?
        item.configure(
            projection: projection,
            browsedSectionID: projection.selectedEpisodeSectionID,
            onSelectSection: { browsedSectionID = $0 },
            onSelectEpisode: { _ in },
            onSelectPage: { selectedCID = $0 },
            onRetryPages: {}
        )
        item.view.layoutSubtreeIfNeeded()

        let popUps = descendants(of: item.view).compactMap { $0 as? NSPopUpButton }
        let sectionPopUp = try #require(
            popUps.first { $0.accessibilityLabel() == "分区" }
        )
        let episodePopUp = try #require(
            popUps.first { $0.accessibilityLabel() == "选集" }
        )
        let pagePopUp = try #require(
            popUps.first { $0.accessibilityLabel() == "分 P" }
        )
        #expect(sectionPopUp.menu?.items.map(\.title) == ["正片", "花絮"])
        #expect(episodePopUp.menu?.items.map(\.title) == ["第一集"])
        #expect(!pagePopUp.isHidden)

        let targetSection = try #require(
            sectionPopUp.menu?.items.first { $0.title == "花絮" }
        )
        let sent = targetSection.action.map {
            NSApplication.shared.sendAction($0, to: targetSection.target, from: targetSection)
        }

        #expect(sent == true)
        #expect(browsedSectionID == collection.sections[1].id)
        #expect(episodePopUp.menu?.items.map(\.title) == ["请选择选集", "幕后花絮"])
        #expect(pagePopUp.isHidden)
        #expect(pagePopUp.menu == nil)
        #expect(selectedCID == nil)
    }

    @Test
    @MainActor
    func commentsUseStableSubjectAndRootIDsAcrossAppend() {
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let first = commentThread(id: 1, message: "第一条评论")
        let second = commentThread(id: 2, message: "第二条评论")
        let initial = commentsPresentation(subject: subject, threads: [first])
        let appended = commentsPresentation(subject: subject, threads: [first, second])

        #expect(
            commentItemIDs(initial)
                == [
                    .commentsHeader(subject: subject),
                    .commentThread(subject: subject, rootID: first.id),
                    .commentsFooter(subject: subject),
                ]
        )
        #expect(
            Array(commentItemIDs(appended).prefix(2)) == Array(commentItemIDs(initial).prefix(2))
        )
        #expect(
            commentItemIDs(appended)[2]
                == .commentThread(subject: subject, rootID: second.id)
        )
    }

    @Test
    @MainActor
    func commentRevisionTracksRenderedVerificationLinksAndPictures() {
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let message = "查看视频"
        let range = CommentTextRange(location: 0, length: 4)
        let plainAuthor = CommentAuthor(
            id: CommentAuthorID(rawValue: "author"),
            name: "评论者"
        )
        let verifiedAuthor = CommentAuthor(
            id: CommentAuthorID(rawValue: "author"),
            name: "评论者",
            verification: .personal(description: "认证")
        )
        let avatarAuthor = CommentAuthor(
            id: CommentAuthorID(rawValue: "author"),
            name: "评论者",
            avatar: CommentAssetReference()
        )
        let plain = NativePlaybackCommentThreadPresentation(
            subject: subject,
            thread: commentThread(id: 1, message: message, author: plainAuthor),
            replyState: nil
        )
        let verified = NativePlaybackCommentThreadPresentation(
            subject: subject,
            thread: commentThread(id: 1, message: message, author: verifiedAuthor),
            replyState: nil
        )
        let avatar = NativePlaybackCommentThreadPresentation(
            subject: subject,
            thread: commentThread(id: 1, message: message, author: avatarAuthor),
            replyState: nil
        )
        let linked = NativePlaybackCommentThreadPresentation(
            subject: subject,
            thread: commentThread(
                id: 1,
                message: message,
                links: [
                    CommentLink(
                        range: range,
                        target: .video(bvid: "BV1FixtureA1")
                    )
                ],
                author: verifiedAuthor
            ),
            replyState: nil
        )
        let pictured = NativePlaybackCommentThreadPresentation(
            subject: subject,
            thread: commentThread(
                id: 1,
                message: message,
                links: [
                    CommentLink(range: range, target: .video(bvid: "BV1FixtureA1"))
                ],
                pictures: [CommentImage(asset: CommentAssetReference())],
                author: verifiedAuthor
            ),
            replyState: nil
        )

        #expect(plain.revision != avatar.revision)
        #expect(plain.revision != verified.revision)
        #expect(verified.revision != linked.revision)
        #expect(linked.revision != pictured.revision)
    }

    @Test
    @MainActor
    func selectionOnlyUpdateKeepsEveryLoadedCommentInTheLayout() async throws {
        let controller = NativePlaybackSidebarController()
        controller.rootView.frame = NSRect(x: 0, y: 0, width: 440, height: 600)
        controller.rootView.layoutSubtreeIfNeeded()
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let comments = commentsPresentation(
            subject: subject,
            threads: (1...40).map {
                commentThread(id: Int64($0), message: "第 \($0) 条评论正文")
            }
        )
        let original = presentation(bvid: "BVCurrent", comments: comments)
        controller.update(presentation: original, actions: actions)
        for _ in 0..<4 { await Task.yield() }

        let content = try #require(original.content)
        let episode = collectionEpisode(
            sectionID: 10,
            episodeID: 100,
            bvid: content.bvid,
            title: "当前选集"
        )
        let collection = VideoCollection(
            id: 1,
            title: "异步到达的合集",
            reportedEpisodeCount: 1,
            sections: [
                collectionSection(id: 10, title: "正片", episodes: [episode])
            ]
        )
        let updated = NativePlaybackSidebarPresentation(
            content: NativePlaybackSidebarContent(
                bvid: content.bvid,
                uploader: content.uploader,
                summary: content.summary,
                selection: selectionProjection(
                    context: context(bvid: content.bvid, collection: collection)
                ),
                comments: content.comments
            ),
            overlay: .none
        )
        controller.update(presentation: updated, actions: actions)
        for _ in 0..<6 { await Task.yield() }

        let collectionView = try #require(
            controller.rootView.scrollView.documentView as? NSCollectionView
        )
        let collectionLayout = try #require(collectionView.collectionViewLayout)
        let selectionAttributes = try #require(
            collectionLayout.layoutAttributesForItem(
                at: IndexPath(item: 0, section: 2)
            )
        )
        let commentsHeaderAttributes = try #require(
            collectionLayout.layoutAttributesForItem(
                at: IndexPath(item: 0, section: 3)
            )
        )

        #expect(collectionView.numberOfSections == 4)
        #expect(collectionView.numberOfItems(inSection: 3) == 42)
        #expect(collectionLayout.collectionViewContentSize.height > 600)
        #expect(commentsHeaderAttributes.frame.minY > selectionAttributes.frame.maxY)
        #expect(
            collectionLayout.layoutAttributesForItem(
                at: IndexPath(item: 40, section: 3)
            ) != nil
        )
        controller.tearDown()
    }

    @Test
    @MainActor
    func commentPaginationPreservesRowAnchorAtAndAboveTheOldBottom() async throws {
        let controller = NativePlaybackSidebarController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 600),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.rootView
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        defer {
            controller.tearDown()
            window.contentView = nil
        }
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let initial = commentsPresentation(
            subject: subject,
            threads: (1...60).map {
                commentThread(id: Int64($0), message: "第 \($0) 条评论")
            }
        )
        controller.update(
            presentation: presentation(bvid: "BVAnchor", comments: initial),
            actions: actions
        )
        let collectionView = try #require(
            controller.rootView.scrollView.documentView as? NSCollectionView
        )
        let collectionLayout = try #require(collectionView.collectionViewLayout)
        let sidebarLayout = try #require(
            collectionLayout as? NativePlaybackSidebarLayout
        )
        #expect(
            await waitUntil(timeout: .seconds(5)) {
                collectionView.numberOfItems(inSection: 3) == 62
                    && collectionLayout.collectionViewContentSize.height > 600
                    && sidebarLayout.pendingRefinementIndexes.isEmpty
            }
        )
        let anchorPath = IndexPath(item: 31, section: 3)
        let initialAnchor = try #require(
            collectionLayout.layoutAttributesForItem(at: anchorPath)
        )
        controller.scroll(to: initialAnchor.frame.minY - 24)
        let relativeY =
            initialAnchor.frame.minY
            - controller.rootView.scrollView.documentVisibleRect.minY

        let appended = commentsPresentation(
            subject: subject,
            threads: (1...70).map {
                commentThread(id: Int64($0), message: "第 \($0) 条评论")
            }
        )
        controller.update(
            presentation: presentation(bvid: "BVAnchor", comments: appended),
            actions: actions
        )
        #expect(
            await waitUntil(timeout: .seconds(5)) {
                guard
                    collectionView.numberOfItems(inSection: 3) == 72,
                    sidebarLayout.pendingRefinementIndexes.isEmpty,
                    let preservedAnchor = collectionLayout.layoutAttributesForItem(
                        at: anchorPath
                    )
                else { return false }
                return abs(
                    preservedAnchor.frame.minY
                        - controller.rootView.scrollView.documentVisibleRect.minY
                        - relativeY
                ) <= 1
            }
        )

        let previousHeight = collectionLayout.collectionViewContentSize.height
        controller.scroll(to: previousHeight)
        let previousMaximumY = max(
            0,
            previousHeight
                - controller.rootView.scrollView.documentVisibleRect.height
        )
        #expect(
            abs(
                controller.rootView.scrollView.documentVisibleRect.minY
                    - previousMaximumY
            ) <= 2
        )
        collectionView.layoutSubtreeIfNeeded()
        let bottomAnchorPath = try #require(
            collectionView.indexPathsForVisibleItems()
                .filter { $0.section == 3 && (1...70).contains($0.item) }
                .min { lhs, rhs in
                    let lhsY =
                        collectionLayout.layoutAttributesForItem(at: lhs)?
                        .frame.minY ?? .greatestFiniteMagnitude
                    let rhsY =
                        collectionLayout.layoutAttributesForItem(at: rhs)?
                        .frame.minY ?? .greatestFiniteMagnitude
                    return lhsY < rhsY
                }
        )
        let bottomAnchor = try #require(
            collectionLayout.layoutAttributesForItem(at: bottomAnchorPath)
        )
        let bottomRelativeY =
            bottomAnchor.frame.minY
            - controller.rootView.scrollView.documentVisibleRect.minY

        let loadingAtBottom = commentsPresentation(
            subject: subject,
            threads: (1...70).map {
                commentThread(id: Int64($0), message: "第 \($0) 条评论")
            },
            isLoadingNextPage: true
        )
        controller.update(
            presentation: presentation(
                bvid: "BVAnchor",
                comments: loadingAtBottom
            ),
            actions: actions
        )
        #expect(
            await waitUntil(timeout: .seconds(5)) {
                guard
                    collectionView.numberOfItems(inSection: 3) == 72,
                    let preservedAnchor = collectionLayout.layoutAttributesForItem(
                        at: bottomAnchorPath
                    )
                else { return false }
                return abs(
                    preservedAnchor.frame.minY
                        - controller.rootView.scrollView.documentVisibleRect.minY
                        - bottomRelativeY
                ) <= 1
            }
        )

        let appendedAtBottom = commentsPresentation(
            subject: subject,
            threads: (1...80).map {
                commentThread(id: Int64($0), message: "第 \($0) 条评论")
            }
        )
        controller.update(
            presentation: presentation(
                bvid: "BVAnchor",
                comments: appendedAtBottom
            ),
            actions: actions
        )
        #expect(
            await waitUntil(timeout: .seconds(5)) {
                guard
                    collectionView.numberOfItems(inSection: 3) == 82,
                    sidebarLayout.pendingRefinementIndexes.isEmpty,
                    let preservedAnchor = collectionLayout.layoutAttributesForItem(
                        at: bottomAnchorPath
                    )
                else {
                    return false
                }
                let maximumY = max(
                    0,
                    collectionLayout.collectionViewContentSize.height
                        - controller.rootView.scrollView.documentVisibleRect.height
                )
                return abs(
                    preservedAnchor.frame.minY
                        - controller.rootView.scrollView.documentVisibleRect.minY
                        - bottomRelativeY
                ) <= 1
                    && maximumY
                        - controller.rootView.scrollView.documentVisibleRect.minY
                        > 40
            }
        )
        let appendedFooter = try #require(
            collectionLayout.layoutAttributesForItem(
                at: IndexPath(item: 81, section: 3)
            )
        )
        #expect(
            !appendedFooter.frame.intersects(
                controller.rootView.scrollView.documentVisibleRect
            )
        )
    }

    @Test
    @MainActor
    func aboveAnchorMutationAndContinuousResizeKeepTheSameCommentPosition() async throws {
        let controller = NativePlaybackSidebarController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 600),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.rootView
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        defer {
            controller.tearDown()
            window.contentView = nil
        }
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let initialThreads = (1...60).map {
            commentThread(id: Int64($0), message: "第 \($0) 条评论")
        }
        controller.update(
            presentation: presentation(
                bvid: "BVResizeAnchor",
                comments: commentsPresentation(
                    subject: subject,
                    threads: initialThreads
                )
            ),
            actions: actions
        )
        let collectionView = try #require(
            controller.rootView.scrollView.documentView as? NSCollectionView
        )
        let collectionLayout = try #require(collectionView.collectionViewLayout)
        let sidebarLayout = try #require(
            collectionLayout as? NativePlaybackSidebarLayout
        )
        #expect(
            await waitUntil(timeout: .seconds(5)) {
                collectionView.numberOfItems(inSection: 3) == 62
                    && collectionLayout.collectionViewContentSize.height > 600
                    && sidebarLayout.pendingRefinementIndexes.isEmpty
            }
        )
        let anchorPath = IndexPath(item: 31, section: 3)
        let anchor = try #require(
            collectionLayout.layoutAttributesForItem(at: anchorPath)
        )
        controller.scroll(to: anchor.frame.minY)
        let expectedRelativeY =
            anchor.frame.minY
            - controller.rootView.scrollView.documentVisibleRect.minY

        var mutatedThreads = initialThreads
        mutatedThreads[0] = commentThread(
            id: 1,
            message: String(repeating: "位于锚点上方的长评论正文", count: 20)
        )
        controller.update(
            presentation: presentation(
                bvid: "BVResizeAnchor",
                comments: commentsPresentation(
                    subject: subject,
                    threads: mutatedThreads
                )
            ),
            actions: actions
        )

        func anchorRelativeY() throws -> CGFloat {
            let attributes = try #require(
                collectionLayout.layoutAttributesForItem(at: anchorPath)
            )
            return attributes.frame.minY
                - controller.rootView.scrollView.documentVisibleRect.minY
        }
        #expect(
            await waitUntil(timeout: .seconds(5)) {
                sidebarLayout.pendingRefinementIndexes.isEmpty
                    && (try? abs(anchorRelativeY() - expectedRelativeY) <= 1)
                        == true
            }
        )

        for width in [360.0, 520.0, 440.0] {
            window.setContentSize(NSSize(width: width, height: 600))
            window.contentView?.layoutSubtreeIfNeeded()
            let stabilized = await waitUntil(timeout: .seconds(5)) {
                sidebarLayout.pendingRefinementIndexes.isEmpty
                    && (try? abs(anchorRelativeY() - expectedRelativeY) <= 2)
                        == true
            }
            let currentRelativeY = try anchorRelativeY()
            let pendingCount = sidebarLayout.pendingRefinementIndexes.count
            #expect(
                stabilized,
                "width \(width), relativeY \(currentRelativeY), expected \(expectedRelativeY), pending \(pendingCount)"
            )
        }
    }

    @Test
    @MainActor
    func replyLoadingAndFailureHeightsRetainVisiblePreviousPageRows() throws {
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let thread = commentThread(
            id: 1,
            message: "主评论",
            replyCount: 12
        )
        var state = PlaybackCommentReplyState()
        state.isExpanded = true
        state.replies = [
            comment(id: 11, rootID: 1, message: "旧页回复一"),
            comment(id: 12, rootID: 1, message: "旧页回复二"),
        ]
        state.totalCount = 12

        for failure in [false, true] {
            state.isLoading = !failure
            state.error = failure ? .transportFailure : nil
            let row = NativePlaybackCommentThreadPresentation(
                subject: subject,
                thread: thread,
                replyState: state
            )
            let item = NativePlaybackCommentThreadItem()
            item.view.frame = NSRect(
                x: 0,
                y: 0,
                width: 408,
                height: NativePlaybackCommentsItemMeasurement.thread(row, width: 408)
            )
            item.configure(
                presentation: row,
                textRenderer: makeCommentTextRenderer(),
                avatarLoader: makeCommentAvatarLoader(),
                pictureLoader: makeCommentPictureLoader(),
                onTextLayoutChange: {},
                onExpand: {},
                onCollapse: {},
                onPrevious: {},
                onNext: {},
                onRetry: {},
                onOpenLink: { _ in }
            )
            item.view.layoutSubtreeIfNeeded()

            let statusText = failure ? "回复加载失败" : "回复加载中…"
            let status = try #require(
                descendants(of: item.view).compactMap { $0 as? NSTextField }
                    .first { $0.stringValue == statusText }
            )
            let panel = try #require(status.superview)
            let visibleBottom =
                panel.subviews.filter { !$0.isHidden }
                .map(\.frame.maxY).max() ?? 0
            #expect(visibleBottom <= panel.bounds.height + 0.5)
        }
    }

    @Test
    @MainActor
    func commentLoadingAccessibilityDoesNotReuseStaleCountOrFooterState() throws {
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let loaded = commentsPresentation(
            subject: subject,
            threads: [commentThread(id: 1, message: "正文")]
        )
        let loading = NativePlaybackCommentsPresentation(
            subject: subject,
            sort: .latest,
            rootState: .loading,
            totalCount: 0,
            threads: []
        )
        let header = NativePlaybackCommentsHeaderItem()
        header.configure(presentation: loaded, onSelectSort: { _ in })
        let countLabel = try #require(
            descendants(of: header.view).compactMap { $0 as? NSTextField }
                .first { $0.accessibilityLabel()?.hasPrefix("共 ") == true }
        )
        header.configure(presentation: loading, onSelectSort: { _ in })
        #expect(countLabel.stringValue.isEmpty)
        #expect(countLabel.accessibilityLabel() == nil)
        #expect(!countLabel.isAccessibilityElement())

        let footer = NativePlaybackCommentsFooterItem()
        footer.configure(footer: .loading, onRetry: {}, onLoadMore: {})
        #expect(footer.view.isAccessibilityElement())
        #expect(footer.view.accessibilityRole() == .staticText)
        #expect(footer.view.accessibilityLabel() == "后续评论加载中")
        footer.configure(footer: .retry, onRetry: {}, onLoadMore: {})
        #expect(!footer.view.isAccessibilityElement())
        var loadMoreCount = 0
        footer.configure(
            footer: .loadMore,
            onRetry: {},
            onLoadMore: { loadMoreCount += 1 }
        )
        let loadMoreButton = try #require(
            descendants(of: footer.view).compactMap { $0 as? NSButton }
                .first { !$0.isHidden && $0.title == "加载更多" }
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
    func commentsFooterOnlyClaimsAllCommentsForServerEnd() throws {
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let stopped = NativePlaybackCommentsPresentation(
            subject: subject,
            sort: .hot,
            rootState: .loaded,
            totalCount: 2,
            threads: [],
            paginationTermination: .duplicatePage
        )
        let ended = NativePlaybackCommentsPresentation(
            subject: subject,
            sort: .hot,
            rootState: .loaded,
            totalCount: 2,
            threads: [],
            paginationTermination: .serverEnd,
            reachedEnd: true
        )

        #expect(stopped.footer == .stopped)
        #expect(ended.footer == .end(memoryLimited: false))

        let footer = NativePlaybackCommentsFooterItem()
        footer.configure(footer: stopped.footer, onRetry: {}, onLoadMore: {})
        let statusLabels = descendants(of: footer.view).compactMap { $0 as? NSTextField }
        #expect(statusLabels.contains { $0.stringValue == "后续评论暂不可用" })
        #expect(!statusLabels.contains { $0.stringValue == "已显示全部评论" })
    }

    @Test
    @MainActor
    func commentThreadUsesSelectableNonScrollingTextKitAndNativeLinkAttributes() throws {
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let message = "跳转 BV1FixtureA1 查看视频 @回复用户"
        let linkRange = (message as NSString).range(of: "BV1FixtureA1")
        let memberRange = (message as NSString).range(of: "@回复用户")
        let thread = commentThread(
            id: 1,
            message: message,
            links: [
                CommentLink(
                    range: CommentTextRange(
                        location: linkRange.location,
                        length: linkRange.length
                    ),
                    target: .video(bvid: "BV1FixtureA1")
                ),
                CommentLink(
                    range: CommentTextRange(
                        location: memberRange.location,
                        length: memberRange.length
                    ),
                    target: .member(CommentAuthorID(rawValue: "301"))
                ),
            ],
            replyCount: 1,
            preview: [comment(id: 11, rootID: 1, message: "楼中楼正文")]
        )
        let item = NativePlaybackCommentThreadItem()
        var openedTargets: [CommentLinkTarget] = []
        let row = NativePlaybackCommentThreadPresentation(
            subject: subject,
            thread: thread,
            replyState: nil
        )
        item.view.frame = NSRect(
            x: 0,
            y: 0,
            width: 408,
            height: NativePlaybackCommentsItemMeasurement.thread(row, width: 408)
        )
        item.configure(
            presentation: row,
            textRenderer: makeCommentTextRenderer(),
            avatarLoader: makeCommentAvatarLoader(),
            pictureLoader: makeCommentPictureLoader(),
            onTextLayoutChange: {},
            onExpand: {},
            onCollapse: {},
            onPrevious: {},
            onNext: {},
            onRetry: {},
            onOpenLink: { openedTargets.append($0) }
        )
        item.view.layoutSubtreeIfNeeded()

        let views = descendants(of: item.view)
        let textViews = views.compactMap { $0 as? NSTextView }
        let rootBody = try #require(
            textViews.first { $0.string == message }
        )
        let link = try #require(
            rootBody.textStorage?.attribute(
                .link,
                at: linkRange.location,
                effectiveRange: nil
            )
        )
        let handled = rootBody.delegate?.textView?(
            rootBody,
            clickedOnLink: link,
            at: linkRange.location
        )
        let memberLink = try #require(
            rootBody.textStorage?.attribute(
                .link,
                at: memberRange.location,
                effectiveRange: nil
            )
        )
        let handledMember = rootBody.delegate?.textView?(
            rootBody,
            clickedOnLink: memberLink,
            at: memberRange.location
        )

        #expect(textViews.count >= 2)
        #expect(textViews.allSatisfy { $0.isSelectable && !$0.isEditable })
        #expect(textViews.allSatisfy { $0.enclosingScrollView == nil })
        #expect(views.compactMap { $0 as? NSScrollView }.isEmpty)
        #expect(
            views.allSatisfy {
                !String(describing: type(of: $0)).contains("NSHostingView")
            }
        )
        #expect(handled == true)
        #expect(handledMember == true)
        #expect(
            openedTargets == [
                .video(bvid: "BV1FixtureA1"),
                .member(CommentAuthorID(rawValue: "301")),
            ]
        )
        let labels = views.compactMap { $0 as? NSTextField }
        #expect(labels.contains { $0.stringValue.contains("东京") })
        #expect(labels.allSatisfy { !$0.stringValue.contains("IP属地：") })
        let likeLabel = try #require(labels.first { $0.stringValue == "42" })
        #expect(likeLabel.frame.maxX <= item.view.bounds.maxX - 1)
        #expect(likeLabel.frame.width >= ceil(likeLabel.intrinsicContentSize.width) + 2)
        #expect(labels.allSatisfy { !$0.stringValue.contains("👍") })
        let likeImage = views.compactMap { $0 as? NSImageView }.first {
            $0.image?.accessibilityDescription == "点赞"
        }
        #expect(likeImage != nil)
        #expect(
            views.compactMap { $0 as? NSButton }.contains {
                $0.title == "共 1 条回复"
            }
        )
    }

    @Test
    @MainActor
    func commentImageTransitionOnlyAnimatesNetworkResults() {
        #expect(
            !NativePlaybackCommentImageTransition.shouldAnimate(
                loadOrigin: .memoryCache
            )
        )
        #expect(
            NativePlaybackCommentImageTransition.shouldAnimate(
                loadOrigin: .network
            )
        )
        #expect(NativePlaybackCommentImageTransition.duration == 0.15)
    }

    @Test
    @MainActor
    func commentPictureLayoutMatchesTheBoundedOfficialWebFlow() {
        let portrait = CommentImage(
            asset: CommentAssetReference(),
            position: 0,
            pixelWidth: 270,
            pixelHeight: 360
        )
        let landscape = CommentImage(
            asset: CommentAssetReference(),
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
                CGRect(x: 139, y: 0, width: 223, height: 135),
            ]
        )
    }

    @Test
    @MainActor
    func commentPicturesUseMetadataDrivenFlowWithoutNestedScrolling() throws {
        let first = CommentAssetReference()
        let third = CommentAssetReference()
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
            ),
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
        item.view.frame = NSRect(
            x: 0,
            y: 0,
            width: 408,
            height: NativePlaybackCommentsItemMeasurement.thread(row, width: 408)
        )
        item.configure(
            presentation: row,
            textRenderer: makeCommentTextRenderer(),
            avatarLoader: makeCommentAvatarLoader(),
            pictureLoader: makeCommentPictureLoader(),
            onTextLayoutChange: {},
            onExpand: {},
            onCollapse: {},
            onPrevious: {},
            onNext: {},
            onRetry: {},
            onOpenLink: { _ in }
        )
        item.view.layoutSubtreeIfNeeded()

        let views = descendants(of: item.view)
        let pictureGroup = try #require(
            views.first { $0.accessibilityLabel() == "评论图片，共 3 张" }
        )
        let pictureImageViews = descendants(of: pictureGroup).compactMap {
            $0 as? NSImageView
        }
        #expect(pictureGroup.accessibilityRole() == .group)
        #expect(!pictureImageViews.isEmpty)
        #expect(
            pictureImageViews.allSatisfy {
                $0.imageScaling == .scaleProportionallyUpOrDown
            }
        )
        #expect(!views.contains { $0 is NSScrollView })
        #expect(
            !views.contains {
                String(describing: type(of: $0)).contains("NSHostingView")
            }
        )

        item.releaseOffscreenResources()
        item.prepareForReuse()
    }

    @Test
    @MainActor
    func commentEmoteRendererUsesFixedTextKitAttachmentsAndLiteralFallback() throws {
        let asset = CommentAssetReference()
        let url = try #require(
            URL(string: "https://i0.hdslb.com/bfs/emote/doge.png")
        )
        let renderer = makeCommentTextRenderer { reference in
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
        let asset = CommentAssetReference()
        let url = try #require(
            URL(string: "https://i0.hdslb.com/bfs/emote/doge.png")
        )
        let renderer = makeCommentTextRenderer { reference in
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
            renderer.markUnavailable(asset, in: scope)
        }

        #expect(renderer.render(content, scope: scopes[0]).pendingAssets.count == 1)
        #expect(renderer.render(content, scope: scopes[512]).pendingAssets.isEmpty)
    }

    @Test
    @MainActor
    func lateCommentEmoteFailureCannotReenterAnInactiveScope() throws {
        let asset = CommentAssetReference()
        let url = try #require(
            URL(string: "https://i0.hdslb.com/bfs/emote/doge.png")
        )
        let renderer = makeCommentTextRenderer { reference in
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
        let largeAsset = CommentAssetReference()
        let unknownAsset = CommentAssetReference()
        let url = try #require(
            URL(string: "https://i0.hdslb.com/bfs/emote/large.png")
        )
        let renderer = makeCommentTextRenderer { reference in
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
                ),
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
        #expect(renderer.height(content, width: 200, scope: scope) >= 36)
    }

    @Test
    @MainActor
    func commentAuthorNameColorOnlyReflectsVIPState() throws {
        for (id, sex, isVIP, expectedColor) in [
            (21, CommentAuthorSex.male, false, NSColor.labelColor),
            (22, CommentAuthorSex.female, false, NSColor.labelColor),
            (23, CommentAuthorSex.unspecified, true, NSColor.systemPink),
        ] {
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
            item.view.frame = NSRect(
                x: 0,
                y: 0,
                width: 408,
                height: NativePlaybackCommentsItemMeasurement.thread(row, width: 408)
            )
            item.configure(
                presentation: row,
                textRenderer: makeCommentTextRenderer(),
                avatarLoader: makeCommentAvatarLoader(),
                pictureLoader: makeCommentPictureLoader(),
                onTextLayoutChange: {},
                onExpand: {},
                onCollapse: {},
                onPrevious: {},
                onNext: {},
                onRetry: {},
                onOpenLink: { _ in }
            )
            item.view.layoutSubtreeIfNeeded()

            let authorLabel = try #require(
                descendants(of: item.view).compactMap { $0 as? NSTextField }.first {
                    $0.stringValue == author.name
                }
            )
            #expect(authorLabel.textColor == expectedColor)
        }
    }

    @Test
    @MainActor
    func replySummaryRemainsAvailableWhenPreviewAlreadyShowsEveryReply() throws {
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let previews = [
            comment(id: 31, rootID: 3, message: "回复一"),
            comment(id: 32, rootID: 3, message: "回复二"),
        ]

        for replyCount in [2, 3] {
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
            item.view.frame = NSRect(
                x: 0,
                y: 0,
                width: 408,
                height: NativePlaybackCommentsItemMeasurement.thread(row, width: 408)
            )
            item.configure(
                presentation: row,
                textRenderer: makeCommentTextRenderer(),
                avatarLoader: makeCommentAvatarLoader(),
                pictureLoader: makeCommentPictureLoader(),
                onTextLayoutChange: {},
                onExpand: {},
                onCollapse: {},
                onPrevious: {},
                onNext: {},
                onRetry: {},
                onOpenLink: { _ in }
            )
            item.view.layoutSubtreeIfNeeded()

            let summary = descendants(of: item.view).compactMap { $0 as? NSButton }
                .first { $0.title == "共 \(replyCount) 条回复" }
            #expect(summary != nil)
        }
    }

    @Test
    @MainActor
    func crowdedAuthorAndStatusBadgesPreserveNamesAndNativeCapsules() throws {
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let author = CommentAuthor(
            id: CommentAuthorID(rawValue: "crowded-author"),
            name: "昵称应该完整显示",
            sex: .male,
            level: 6,
            isHardcoreMember: true,
            isVIP: true,
            isUploader: true
        )
        let thread = commentThread(
            id: 2,
            message: "正文",
            author: author,
            provenance: [.uploaderPinned, .uploaderLiked]
        )
        let row = NativePlaybackCommentThreadPresentation(
            subject: subject,
            thread: thread,
            replyState: nil
        )
        let item = NativePlaybackCommentThreadItem()
        item.view.frame = NSRect(
            x: 0,
            y: 0,
            width: 220,
            height: NativePlaybackCommentsItemMeasurement.thread(row, width: 220)
        )
        item.configure(
            presentation: row,
            textRenderer: makeCommentTextRenderer(),
            avatarLoader: makeCommentAvatarLoader(),
            pictureLoader: makeCommentPictureLoader(),
            onTextLayoutChange: {},
            onExpand: {},
            onCollapse: {},
            onPrevious: {},
            onNext: {},
            onRetry: {},
            onOpenLink: { _ in }
        )
        item.view.layoutSubtreeIfNeeded()

        let views = descendants(of: item.view)
        let authorLabel = try #require(
            views.compactMap { $0 as? NSTextField }.first {
                $0.stringValue == author.name
            }
        )
        let authorBadges = try #require(
            views.compactMap { $0 as? NativePlaybackCommentAuthorBadgesView }.first
        )
        let statusBadges = try #require(
            views.compactMap { $0 as? NativePlaybackCommentProvenanceBadgesView }.first
        )

        #expect(authorLabel.frame.width >= authorLabel.intrinsicContentSize.width)
        #expect(!authorBadges.isHidden)
        #expect(authorBadges.displayedTexts.contains("LV6⚡︎"))
        #expect(!authorBadges.displayedTexts.contains("硬核"))
        #expect(statusBadges.displayedTexts == ["置顶", "UP 主觉得很赞"])
        #expect(statusBadges.accessibilityLabel() == "置顶，UP 主觉得很赞")
    }

    @Test
    @MainActor
    func inlineAuthorBadgesFollowVisibleNameGlyphsWithoutCellPaddingGap() throws {
        let author = CommentAuthor(
            id: CommentAuthorID(rawValue: "inline-author"),
            name: "短昵称",
            sex: .unspecified,
            level: 6,
            isHardcoreMember: true,
            isVIP: true,
            isUploader: false
        )
        let row = NativePlaybackCommentThreadPresentation(
            subject: .video(aid: 700_001),
            thread: commentThread(id: 3, message: "正文", author: author),
            replyState: nil
        )
        let item = NativePlaybackCommentThreadItem()
        item.view.frame = NSRect(
            x: 0,
            y: 0,
            width: 408,
            height: NativePlaybackCommentsItemMeasurement.thread(row, width: 408)
        )
        item.configure(
            presentation: row,
            textRenderer: makeCommentTextRenderer(),
            avatarLoader: makeCommentAvatarLoader(),
            pictureLoader: makeCommentPictureLoader(),
            onTextLayoutChange: {},
            onExpand: {},
            onCollapse: {},
            onPrevious: {},
            onNext: {},
            onRetry: {},
            onOpenLink: { _ in }
        )
        item.view.layoutSubtreeIfNeeded()

        let views = descendants(of: item.view)
        let authorLabel = try #require(
            views.compactMap { $0 as? NSTextField }.first {
                $0.stringValue == author.name
            }
        )
        let authorBadges = try #require(
            views.compactMap { $0 as? NativePlaybackCommentAuthorBadgesView }.first
        )
        let textWidth = NativePlaybackCommentsItemMeasurement.authorNameTextWidth(
            author,
            maximumWidth: 366
        )

        #expect(authorBadges.frame.minY == authorLabel.frame.minY)
        #expect(
            abs(
                authorBadges.frame.minX - authorLabel.frame.minX - textWidth
                    - NativePlaybackCommentsItemMeasurement.authorBadgeSpacing
            ) <= 0.5
        )
    }

    @Test
    @MainActor
    func commentsHeaderCountReservesTrailingGlyphSpace() throws {
        let header = NativePlaybackCommentsHeaderItem()
        let presentation = NativePlaybackCommentsPresentation(
            subject: .video(aid: 700_001),
            sort: .hot,
            rootState: .loaded,
            totalCount: 12_345,
            threads: []
        )
        header.view.frame = NSRect(x: 0, y: 0, width: 320, height: 42)
        header.configure(presentation: presentation, onSelectSort: { _ in })
        header.view.layoutSubtreeIfNeeded()

        let views = descendants(of: header.view)
        let countLabel = try #require(
            views.compactMap { $0 as? NSTextField }.first {
                $0.accessibilityLabel()?.hasPrefix("共 ") == true
            }
        )
        let sortControl = try #require(
            views.compactMap { $0 as? NSSegmentedControl }.first
        )
        #expect(countLabel.frame.width >= ceil(countLabel.intrinsicContentSize.width) + 3)
        #expect(countLabel.frame.maxX < sortControl.frame.minX)
    }

    @Test
    func commentsPaginationRequiresThresholdExitBeforeLoadingAnotherTail() {
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let first = NativePlaybackCommentsPaginationTailState(
            canLoadMore: true,
            identity: .init(subject: subject, lastRootID: .init(rawValue: 1)),
            isLoading: false
        )
        let loading = NativePlaybackCommentsPaginationTailState(
            canLoadMore: true,
            identity: first.identity,
            isLoading: true
        )
        let second = NativePlaybackCommentsPaginationTailState(
            canLoadMore: true,
            identity: .init(subject: subject, lastRootID: .init(rawValue: 2)),
            isLoading: false
        )
        var gate = NativePlaybackCommentsPaginationGate()

        let outside = gate.update(isInsideThreshold: false, state: first)
        let firstEntry = gate.update(isInsideThreshold: true, state: first)
        let loadingEntry = gate.update(isInsideThreshold: true, state: loading)
        let changedTail = gate.update(isInsideThreshold: true, state: second)
        let repeatedTail = gate.update(isInsideThreshold: true, state: second)
        let leftThreshold = gate.update(isInsideThreshold: false, state: second)
        let reentered = gate.update(isInsideThreshold: true, state: second)
        let ended = gate.update(isInsideThreshold: true, state: .end)

        #expect(!outside)
        #expect(firstEntry)
        #expect(!loadingEntry)
        #expect(!changedTail)
        #expect(!repeatedTail)
        #expect(!leftThreshold)
        #expect(reentered)
        #expect(!ended)
    }

    @Test
    func commentsLiveScrollBackpressureAllowsOnlyOnePagePerGesture() {
        var backpressure = NativePlaybackCommentsLiveScrollBackpressure()

        #expect(backpressure.permitsAutomaticLoad)
        backpressure.recordTrigger(isLiveScrolling: true)
        #expect(!backpressure.permitsAutomaticLoad)
        backpressure.beginLiveScroll()
        #expect(backpressure.permitsAutomaticLoad)
        backpressure.recordTrigger(isLiveScrolling: false)
        #expect(backpressure.permitsAutomaticLoad)
        backpressure.reset()
        #expect(backpressure.permitsAutomaticLoad)
    }

    @Test
    @MainActor
    func commentHeightCacheIsBoundedAndUsesTrueLRURecency() {
        let cache = NativePlaybackSidebarHeightCache(capacity: 2)
        let first = heightKey(rootID: 1)
        let second = heightKey(rootID: 2)
        let third = heightKey(rootID: 3)

        cache.insert(101, for: first)
        cache.insert(102, for: second)
        #expect(cache.value(for: first) == 101)
        cache.insert(103, for: third)

        #expect(cache.count == 2)
        #expect(cache.value(for: first) == 101)
        #expect(cache.value(for: second) == nil)
        #expect(cache.value(for: third) == 103)
    }

    @Test
    @MainActor
    func resizeEstimatesImmediatelyAndRefinesAtMostThirtyTwoRowsPerBatch() {
        let layout = NativePlaybackSidebarLayout()
        let collectionView = NSCollectionView(
            frame: NSRect(x: 0, y: 0, width: 440, height: 600)
        )
        collectionView.collectionViewLayout = layout
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let entries = (0..<80).map { index in
            NativePlaybackSidebarLayout.Entry(
                indexPath: IndexPath(item: index, section: 0),
                itemID: .commentThread(
                    subject: subject,
                    rootID: CommentID(rawValue: Int64(index + 1))
                )
            )
        }
        var measurements = 0
        layout.heightProvider = { _, width in
            measurements += 1
            return 80 + width.truncatingRemainder(dividingBy: 7)
        }
        layout.update(entries: entries)
        layout.prepare()
        #expect(measurements == 80)

        collectionView.frame.size.width = 520
        layout.invalidateLayout()
        layout.prepare()
        #expect(layout.pendingRefinementIndexes.count == 80)
        #expect(measurements == 80)

        #expect(
            layout.refineNextBatch(
                maximumCount: 32,
                prioritizing: entries[40].itemID
            )
        )
        #expect(measurements == 112)
        #expect(layout.pendingRefinementIndexes.count == 48)
    }

    @Test
    @MainActor
    func commentAppendMeasuresOnlyNewRowsAndTheMovedFooter() {
        let layout = NativePlaybackSidebarLayout()
        let collectionView = NSCollectionView(
            frame: NSRect(x: 0, y: 0, width: 440, height: 600)
        )
        collectionView.collectionViewLayout = layout
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let first = NativePlaybackSidebarLayout.Entry(
            indexPath: IndexPath(item: 0, section: 0),
            itemID: .commentThread(subject: subject, rootID: CommentID(rawValue: 1))
        )
        let oldFooter = NativePlaybackSidebarLayout.Entry(
            indexPath: IndexPath(item: 1, section: 0),
            itemID: .commentsFooter(subject: subject)
        )
        let second = NativePlaybackSidebarLayout.Entry(
            indexPath: IndexPath(item: 1, section: 0),
            itemID: .commentThread(subject: subject, rootID: CommentID(rawValue: 2))
        )
        let movedFooter = NativePlaybackSidebarLayout.Entry(
            indexPath: IndexPath(item: 2, section: 0),
            itemID: .commentsFooter(subject: subject)
        )
        var measurements = 0
        layout.heightProvider = { _, _ in
            measurements += 1
            return 80
        }

        layout.update(entries: [first, oldFooter])
        layout.prepare()
        #expect(measurements == 2)
        layout.update(
            entries: [first, second, movedFooter],
            invalidating: [second.itemID, movedFooter.itemID]
        )
        layout.prepare()

        #expect(measurements == 4)
        #expect(
            layout.layoutAttributesForItem(at: movedFooter.indexPath)?.frame.minY
                == 208
        )
    }

    @Test
    @MainActor
    func commentAppendPreservesPendingPrefixRefinementAfterResize() {
        let layout = NativePlaybackSidebarLayout()
        let collectionView = NSCollectionView(
            frame: NSRect(x: 0, y: 0, width: 440, height: 600)
        )
        collectionView.collectionViewLayout = layout
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let first = NativePlaybackSidebarLayout.Entry(
            indexPath: IndexPath(item: 0, section: 0),
            itemID: .commentThread(subject: subject, rootID: CommentID(rawValue: 1))
        )
        let oldFooter = NativePlaybackSidebarLayout.Entry(
            indexPath: IndexPath(item: 1, section: 0),
            itemID: .commentsFooter(subject: subject)
        )
        let second = NativePlaybackSidebarLayout.Entry(
            indexPath: IndexPath(item: 1, section: 0),
            itemID: .commentThread(subject: subject, rootID: CommentID(rawValue: 2))
        )
        let movedFooter = NativePlaybackSidebarLayout.Entry(
            indexPath: IndexPath(item: 2, section: 0),
            itemID: .commentsFooter(subject: subject)
        )
        var measurements = 0
        layout.heightProvider = { _, _ in
            measurements += 1
            return 80
        }
        layout.update(entries: [first, oldFooter])
        layout.prepare()

        collectionView.frame.size.width = 520
        layout.invalidateLayout()
        layout.prepare()
        #expect(layout.pendingRefinementIndexes == IndexSet(integersIn: 0..<2))
        #expect(measurements == 2)

        layout.update(
            entries: [first, second, movedFooter],
            invalidating: [second.itemID, movedFooter.itemID]
        )
        layout.prepare()

        #expect(layout.pendingRefinementIndexes == IndexSet(integer: 0))
        #expect(measurements == 4)
        #expect(layout.layoutAttributesForItem(at: movedFooter.indexPath) != nil)
    }

    @Test
    func shortLoadingContentIsNeverTreatedAsBottomPinned() {
        let viewport = NSRect(x: 0, y: 0, width: 440, height: 600)

        #expect(
            !NativePlaybackSidebarAnchorPolicy.isBottomPinned(
                contentHeight: 420,
                viewport: viewport
            )
        )
        #expect(
            NativePlaybackSidebarAnchorPolicy.isBottomPinned(
                contentHeight: 1_200,
                viewport: NSRect(x: 0, y: 600, width: 440, height: 600)
            )
        )
        #expect(
            !NativePlaybackSidebarAnchorPolicy.isBottomPinned(
                contentHeight: 1_200,
                viewport: viewport
            )
        )
    }

    @Test
    func firstPresentedVideoAndReplacementBothResetToTop() {
        #expect(
            NativePlaybackSidebarIdentityPolicy.resetsToTop(
                previousBVID: nil,
                nextBVID: "BVFirst"
            )
        )
        #expect(
            NativePlaybackSidebarIdentityPolicy.resetsToTop(
                previousBVID: "BVFirst",
                nextBVID: "BVSecond"
            )
        )
        #expect(
            !NativePlaybackSidebarIdentityPolicy.resetsToTop(
                previousBVID: "BVFirst",
                nextBVID: "BVFirst"
            )
        )
        #expect(
            !NativePlaybackSidebarIdentityPolicy.resetsToTop(
                previousBVID: "BVFirst",
                nextBVID: nil
            )
        )
    }

    @Test
    @MainActor
    func initialCommentsSnapshotRestoresTopBeforeConsideringFooterPagination() async throws {
        let controller = NativePlaybackSidebarController()
        controller.rootView.frame = NSRect(x: 0, y: 0, width: 440, height: 600)
        controller.rootView.layoutSubtreeIfNeeded()
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let loading = NativePlaybackCommentsPresentation(
            subject: subject,
            sort: .hot,
            rootState: .loading,
            totalCount: 0,
            threads: []
        )
        let loaded = commentsPresentation(
            subject: subject,
            threads: (1...40).map {
                commentThread(id: Int64($0), message: "第 \($0) 条评论正文")
            }
        )
        var nextPageRequests = 0
        let testActions = NativePlaybackSidebarActions(
            retry: {},
            selectEpisode: { _ in },
            selectPage: { _, _ in },
            retryPages: {},
            selectCommentSort: { _ in },
            retryComments: {},
            loadNextComments: { nextPageRequests += 1 },
            expandReplies: { _ in },
            collapseReplies: { _ in },
            previousReplyPage: { _ in },
            nextReplyPage: { _ in },
            retryReplies: { _ in },
            openCommentLink: { _ in }
        )

        controller.update(
            presentation: presentation(bvid: "BVFirst", comments: loading),
            actions: testActions
        )
        controller.update(
            presentation: presentation(bvid: "BVFirst", comments: loaded),
            actions: testActions
        )
        for _ in 0..<4 { await Task.yield() }

        #expect(controller.rootView.scrollView.documentVisibleRect.minY <= 1)
        #expect(nextPageRequests == 0)
        let collectionView = try #require(
            controller.rootView.scrollView.documentView as? NSCollectionView
        )
        #expect(collectionView.numberOfSections == 4)
        #expect(collectionView.numberOfItems(inSection: 3) == 42)
        #expect(
            collectionView.collectionViewLayout?.collectionViewContentSize.height
                ?? 0 > 600
        )
        controller.tearDown()
    }

    @MainActor
    private var actions: NativePlaybackSidebarActions {
        NativePlaybackSidebarActions(
            retry: {},
            selectEpisode: { _ in },
            selectPage: { _, _ in },
            retryPages: {},
            selectCommentSort: { _ in },
            retryComments: {},
            loadNextComments: {},
            expandReplies: { _ in },
            collapseReplies: { _ in },
            previousReplyPage: { _ in },
            nextReplyPage: { _ in },
            retryReplies: { _ in },
            openCommentLink: { _ in }
        )
    }

    @MainActor
    private func presentation(bvid: String) -> NativePlaybackSidebarPresentation {
        presentation(
            bvid: bvid,
            comments: NativePlaybackCommentsPresentation(model: nil)
        )
    }

    @MainActor
    private func presentation(
        bvid: String,
        comments: NativePlaybackCommentsPresentation
    ) -> NativePlaybackSidebarPresentation {
        let context = context(bvid: bvid)
        return NativePlaybackSidebarPresentation(
            content: NativePlaybackSidebarContent(
                bvid: bvid,
                uploader: VideoUploaderHeaderContent(
                    owner: context.detail.owner,
                    signatureState: .loaded(context.detail.owner.signature)
                ),
                summary: context.detail.summary,
                selection: selectionProjection(context: context),
                comments: comments
            ),
            overlay: .none
        )
    }

    @MainActor
    private func commentsPresentation(
        subject: CommentSubjectIdentity,
        threads: [CommentThread],
        isLoadingNextPage: Bool = false
    ) -> NativePlaybackCommentsPresentation {
        NativePlaybackCommentsPresentation(
            subject: subject,
            sort: .hot,
            rootState: .loaded,
            totalCount: threads.count,
            threads: threads.map {
                NativePlaybackCommentThreadPresentation(
                    subject: subject,
                    thread: $0,
                    replyState: nil
                )
            },
            isLoadingNextPage: isLoadingNextPage
        )
    }

    @MainActor
    private func commentItemIDs(
        _ comments: NativePlaybackCommentsPresentation
    ) -> [NativePlaybackSidebarItemID] {
        let base = presentation(bvid: "BVCurrent")
        guard let content = base.content else { return [] }
        return NativePlaybackSidebarPresentation(
            content: NativePlaybackSidebarContent(
                bvid: content.bvid,
                uploader: content.uploader,
                summary: content.summary,
                selection: content.selection,
                comments: comments
            ),
            overlay: .none
        ).sections.first { $0.id == .comments }?.items ?? []
    }

    private func heightKey(rootID: Int64) -> NativePlaybackSidebarHeightCacheKey {
        NativePlaybackSidebarHeightCacheKey(
            itemID: .commentThread(
                subject: .video(aid: 700_001),
                rootID: CommentID(rawValue: rootID)
            ),
            widthBucket: 816,
            revision: Int(rootID)
        )
    }

    private func commentThread(
        id: Int64,
        message: String,
        links: [CommentLink] = [],
        pictures: [CommentImage] = [],
        pictureCount: Int? = nil,
        replyCount: Int = 0,
        preview: [BiliModels.Comment] = [],
        author: CommentAuthor? = nil,
        provenance: [CommentProvenance] = []
    ) -> CommentThread {
        CommentThread(
            root: comment(
                id: id,
                message: message,
                links: links,
                pictures: pictures,
                pictureCount: pictureCount,
                replyCount: replyCount,
                author: author,
                provenance: provenance
            ),
            replyPreview: preview
        )
    }

    private func comment(
        id: Int64,
        rootID: Int64? = nil,
        message: String,
        links: [CommentLink] = [],
        pictures: [CommentImage] = [],
        pictureCount: Int? = nil,
        replyCount: Int = 0,
        author: CommentAuthor? = nil,
        provenance: [CommentProvenance] = []
    ) -> BiliModels.Comment {
        BiliModels.Comment(
            id: CommentID(rawValue: id),
            rootID: rootID.map { CommentID(rawValue: $0) },
            payload: .available(
                CommentDetails(
                    author: author
                        ?? CommentAuthor(
                            id: CommentAuthorID(rawValue: "author-\(id)"),
                            name: "评论者\(id)",
                            level: 6,
                            isVIP: true
                        ),
                    content: CommentContent(
                        message: message,
                        links: links,
                        pictures: pictures,
                        pictureCount: pictureCount
                    ),
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    location: "东京",
                    likeCount: 42,
                    replyCount: replyCount,
                    provenance: provenance
                )
            )
        )
    }

    @MainActor
    private func selectionProjection(
        context: GuestVideoContext? = nil
    ) -> PlaybackSelectionProjection {
        let context = context ?? self.context(bvid: "BVCurrent")
        return PlaybackSelectionProjection(
            context: context,
            selectedEpisodeID: nil,
            requestedBVID: context.detail.bvid,
            requestedCID: context.pages.first?.cid,
            presentedIdentity: nil,
            pageStates: [:],
            pagesByEpisode: [:]
        )
    }

    private func context(
        bvid: String,
        collection: VideoCollection? = nil
    ) -> GuestVideoContext {
        let pages = [
            VideoPage(cid: 1_001, index: 1, title: "第一部分", durationSeconds: 61),
            VideoPage(cid: 1_002, index: 2, title: "第二部分", durationSeconds: 122),
        ]
        return GuestVideoContext(
            detail: VideoDetail(
                bvid: bvid,
                title: "当前视频",
                summary: "一段可选择、可精确换行的简介正文。",
                coverURL: nil,
                owner: VideoOwner(id: 1, name: "UP 主", signature: "签名"),
                statistics: VideoStatistics(
                    viewCount: 1,
                    danmakuCount: 1,
                    likeCount: 1
                ),
                durationSeconds: 122,
                publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
                pages: pages,
                collection: collection
            ),
            pages: pages,
            selectedPage: pages[0],
            playback: VideoPlayback(
                manifest: PlaybackManifest(
                    videoRepresentations: [],
                    originalAudioRepresentations: []
                ),
                mediaHeaders: [:]
            )
        )
    }

    private func collectionSection(
        id: Int64,
        title: String,
        episodes: [VideoCollectionEpisode]
    ) -> VideoCollectionSection {
        VideoCollectionSection(
            id: VideoCollectionSectionIdentity(seasonID: 1, sectionID: id),
            ordinal: Int(id - 10),
            title: title,
            episodes: episodes
        )
    }

    private func collectionEpisode(
        sectionID: Int64,
        episodeID: Int64,
        bvid: String,
        title: String
    ) -> VideoCollectionEpisode {
        VideoCollectionEpisode(
            id: VideoCollectionEpisodeIdentity(
                seasonID: 1,
                sectionID: sectionID,
                episodeID: episodeID
            ),
            ordinal: Int(episodeID - 100),
            aid: nil,
            bvid: bvid,
            title: title,
            coverURL: nil,
            durationSeconds: 122,
            defaultCID: 1_001,
            knownPages: [
                VideoPage(
                    cid: 1_001,
                    index: 1,
                    title: "第一部分",
                    durationSeconds: 61
                )
            ]
        )
    }

    @MainActor
    private func makeCommentTextRenderer(
        resolveURL: @escaping CommentAssetURLResolver = { _ in nil }
    ) -> NativePlaybackCommentTextRenderer {
        NativePlaybackCommentTextRenderer(
            imagePipeline: NativeVideoImagePipeline(),
            resolveURL: resolveURL
        )
    }

    @MainActor
    private func makeCommentAvatarLoader(
        resolveURL: @escaping CommentAssetURLResolver = { _ in nil }
    ) -> NativePlaybackCommentAvatarLoader {
        NativePlaybackCommentAvatarLoader(
            imagePipeline: NativeVideoImagePipeline(),
            resolveURL: resolveURL
        )
    }

    @MainActor
    private func makeCommentPictureLoader(
        resolveURL: @escaping CommentAssetURLResolver = { _ in nil }
    ) -> NativePlaybackCommentPictureLoader {
        NativePlaybackCommentPictureLoader(
            imagePipeline: NativeVideoImagePipeline(),
            resolveURL: resolveURL
        )
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(1),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { return false }
            await Task.yield()
        }
        return true
    }
}
