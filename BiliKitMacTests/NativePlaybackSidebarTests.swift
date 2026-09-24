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
                    .commentsState(subject: nil, kind: .idle)
                ]
        )
    }

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
    func uploaderSignatureOverflowFollowsTheAvailableWidth() {
        let content = VideoUploaderHeaderContent(
            owner: VideoOwner(
                id: 1,
                name: "UP 主",
                signature: String(repeating: "签名", count: 16)
            )
        )
        let wide = NativePlaybackUploaderGeometry(
            content: content,
            width: 488,
            signatureExpanded: false
        )
        let narrow = NativePlaybackUploaderGeometry(
            content: content,
            width: 408,
            signatureExpanded: false
        )
        let expanded = NativePlaybackUploaderGeometry(
            content: content,
            width: 408,
            signatureExpanded: true
        )

        #expect(!wide.signatureOverflows)
        #expect(wide.signatureMaximumLines == nil)
        #expect(wide.signatureToggleFrame.width == 0)
        #expect(narrow.signatureOverflows)
        #expect(narrow.signatureMaximumLines == 1)
        #expect(narrow.signatureTextFrame.maxX <= narrow.signatureToggleFrame.minX)
        #expect(expanded.signatureOverflows)
        #expect(expanded.signatureMaximumLines == nil)
        #expect(expanded.height > narrow.height)
    }

    @Test
    @MainActor
    func browsingAnotherSectionKeepsPagesOnlyForTheSelectedEpisodeSection() {
        let collection = VideoCollection(
            id: 1,
            title: "合集",
            reportedEpisodeCount: 2,
            sections: [
                collectionSection(
                    id: 10,
                    title: "正片",
                    episodes: [
                        collectionEpisode(
                            sectionID: 10,
                            episodeID: 100,
                            bvid: "BVCurrent",
                            title: "第一集"
                        )
                    ]
                ),
                collectionSection(
                    id: 11,
                    title: "花絮",
                    episodes: [
                        collectionEpisode(
                            sectionID: 11,
                            episodeID: 101,
                            bvid: "BVOther",
                            title: "幕后花絮"
                        )
                    ]
                )
            ]
        )
        let projection = selectionProjection(
            context: context(bvid: "BVCurrent", collection: collection)
        )
        let selectedSectionHeight = NativePlaybackSidebarItemMeasurement.selection(
            projection,
            width: 328,
            browsedSectionID: projection.selectedEpisodeSectionID
        )
        let otherSectionHeight = NativePlaybackSidebarItemMeasurement.selection(
            projection,
            width: 328,
            browsedSectionID: collection.sections[1].id
        )

        #expect(projection.showsSectionPicker)
        #expect(
            projection.episodeSections.map { $0.episodes.map(\.title) }
                == [["第一集"], ["幕后花絮"]]
        )
        #expect(projection.selectedEpisodeSectionID == collection.sections[0].id)
        #expect(projection.showsPagePicker)
        #expect(otherSectionHeight < selectedSectionHeight)
    }

    @Test
    @MainActor
    func retainedFailedPageKeepsSelectionAvailableAsARecoveryPath() {
        let context = context(bvid: "BVCurrent")
        let failure = VideoLoadFailure.playback

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
                    .commentsFooter(subject: subject)
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
        let loadedCount = CommentPresentationFormatting.compactCount(
            loaded.totalCount
        )
        let countLabel = try #require(
            descendants(of: header.view).compactMap { $0 as? NSTextField }
                .first {
                    $0.accessibilityLabel()
                        == AppStrings.localized("共 \(loadedCount) 条评论")
                }
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
                == AppStrings.localized("后续评论加载中")
        )
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
                .first {
                    !$0.isHidden && $0.title == AppStrings.localized("加载更多")
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
                    target: .video(bvid: "BV1FixtureA1")
                ),
                CommentLink(
                    range: CommentTextRange(location: message.utf16.count, length: 4),
                    target: .video(bvid: "BV1OutOfRange")
                ),
                CommentLink(
                    range: CommentTextRange(
                        location: memberRange.location,
                        length: memberRange.length
                    ),
                    target: .member(CommentAuthorID(rawValue: "301"))
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
                .video(bvid: "BV1FixtureA1"),
                .member(CommentAuthorID(rawValue: "301"))
            ]
        )
        #expect(target(at: videoRange.location) == .video(bvid: "BV1FixtureA1"))
        #expect(target(at: memberRange.location) == .member(CommentAuthorID(rawValue: "301")))
        #expect(target(at: 0) == nil)
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
                CGRect(x: 139, y: 0, width: 223, height: 135)
            ]
        )
    }

    @Test
    @MainActor
    func commentPicturesOpenAMetadataDrivenGalleryAndSkipStaleFocusRestore() throws {
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
            onOpenLink: { _ in },
            onOpenPictures: { openedGallery = $0 }
        )
        item.view.layoutSubtreeIfNeeded()

        let thirdPictureButton = try #require(
            descendants(of: item.view).compactMap { $0 as? NSButton }.first {
                $0.accessibilityLabel()
                    == AppStrings.localized("查看第 \(3) 张评论图片")
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
        let replacement = CommentAssetReference()
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
        item.configure(
            presentation: replacementRow,
            textRenderer: makeCommentTextRenderer(),
            avatarLoader: makeCommentAvatarLoader(),
            pictureLoader: makeCommentPictureLoader(),
            onTextLayoutChange: {},
            onExpand: {},
            onCollapse: {},
            onPrevious: {},
            onNext: {},
            onRetry: {},
            onOpenLink: { _ in },
            onOpenPictures: { _ in }
        )
        item.view.layoutSubtreeIfNeeded()
        focusWindow.makeFirstResponder(fallbackResponder)

        openedGallery?.restoreFocus()

        #expect(focusWindow.firstResponder === fallbackResponder)

        item.releaseOffscreenResources()
        item.prepareForReuse()
        focusWindow.contentView = NSView()
    }

    @Test
    @MainActor
    func commentImagePreviewClampsSelectionAndNavigatesWithoutWrapping() {
        var selection = NativeCommentImagePreviewSelection(
            count: 3,
            requestedIndex: 9
        )
        #expect(selection.index == 2)
        #expect(selection.canSelectPrevious)
        #expect(!selection.canSelectNext)
        let didSelectPastEnd = selection.selectNext()
        let didSelectPrevious = selection.selectPrevious()
        #expect(!didSelectPastEnd)
        #expect(didSelectPrevious)
        #expect(selection.index == 1)

        selection = NativeCommentImagePreviewSelection(
            count: 3,
            requestedIndex: -4
        )
        #expect(selection.index == 0)
        #expect(!selection.canSelectPrevious)
        #expect(selection.canSelectNext)
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
        #expect(renderer.height(content, width: 200, scope: scope) >= 36)
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
        #expect(
            statusBadges.displayedTexts
                == [AppStrings.localized("置顶"), AppStrings.localized("UP 主觉得很赞")]
        )
        #expect(
            statusBadges.accessibilityLabel()
                == ListFormatter.localizedString(byJoining: statusBadges.displayedTexts)
        )
    }

    @Test
    @MainActor
    func commentAuthorNameColorOnlyReflectsVIPState() throws {
        for (id, sex, isVIP, expectedColor) in [
            (21, CommentAuthorSex.male, false, NSColor.labelColor),
            (22, CommentAuthorSex.female, false, NSColor.labelColor),
            (23, CommentAuthorSex.unspecified, true, NSColor.systemPink)
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
                onOpenLink: { _ in },
                onOpenPictures: { _ in }
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
            comment(id: 32, rootID: 3, message: "回复二")
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
                onOpenLink: { _ in },
                onOpenPictures: { _ in }
            )
            item.view.layoutSubtreeIfNeeded()

            let summary = descendants(of: item.view).compactMap { $0 as? NSButton }
                .first {
                    $0.title
                        == AppStrings.localized(
                            "共 \(CommentPresentationFormatting.compactCount(replyCount)) 条回复"
                        )
                }
            #expect(summary != nil)
        }
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
            openCommentLink: { _ in },
            openCommentPictures: { _ in }
        )

        controller.update(
            presentation: presentation(bvid: "BVFirst", comments: loading),
            actions: testActions
        )
        controller.update(
            presentation: presentation(bvid: "BVFirst", comments: loaded),
            actions: testActions
        )
        #expect(
            await waitUntil(timeout: .seconds(5)) {
                guard
                    let collectionView = controller.rootView.scrollView.documentView
                        as? NSCollectionView
                else { return false }
                controller.rootView.layoutSubtreeIfNeeded()
                return collectionView.numberOfSections == 4
                    && collectionView.numberOfItems(inSection: 3) == 42
                    && (collectionView.collectionViewLayout?.collectionViewContentSize.height
                        ?? 0) > 600
            }
        )

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
            openCommentLink: { _ in },
            openCommentPictures: { _ in }
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
        context: VideoContext? = nil
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
    ) -> VideoContext {
        let pages = [
            VideoPage(cid: 1_001, index: 1, title: "第一部分", durationSeconds: 61),
            VideoPage(cid: 1_002, index: 2, title: "第二部分", durationSeconds: 122)
        ]
        return VideoContext(
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
}
