import AppKit
import BiliApplication
import BiliModels
import BiliUI
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// 评论分页、上方内容变化与改变宽度时保持阅读位置：高度先估后分批精测，换视频回到顶部，近尾分页不被短内容误判。
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PlaybackSidebarScrollAnchorTests: PlaybackSidebarFixtures {
    @Test
    @MainActor
    func commentPaginationPreservesRowAnchorAtAndAboveTheOldBottom() async throws {
        let sidebar = HostedPlaybackSidebar()
        let controller = sidebar.controller
        defer { sidebar.tearDown() }
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        // 呈现是值，先全部构造：构造要等 ViewModel 加载，中途让出主线程会让侧栏的精测 Task 先跑、改变测量基准。
        let initial = await commentsPresentation(
            subject: subject,
            threads: (1...60).map {
                commentThread(id: Int64($0), message: "第 \($0) 条评论")
            }
        )
        let appended = await commentsPresentation(
            subject: subject,
            threads: (1...70).map {
                commentThread(id: Int64($0), message: "第 \($0) 条评论")
            }
        )
        let loadingAtBottom = await commentsPresentation(
            subject: subject,
            threads: (1...70).map {
                commentThread(id: Int64($0), message: "第 \($0) 条评论")
            },
            isLoadingNextPage: true
        )
        let appendedAtBottom = await commentsPresentation(
            subject: subject,
            threads: (1...80).map {
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
    func continuousResizeRefinesVisibleRowsAtOnceAndOffscreenRowsAfterWidthSettles() async throws {
        let sidebar = HostedPlaybackSidebar()
        let controller = sidebar.controller
        let window = sidebar.window
        defer { sidebar.tearDown() }
        let comments = await commentsPresentation(
            subject: .video(aid: 700_001),
            threads: (1...60).map { commentThread(id: Int64($0), message: "第 \($0) 条评论") }
        )
        controller.update(
            presentation: presentation(bvid: "BVResizeRefinement", comments: comments),
            actions: actions
        )
        let layout = controller.layout
        #expect(
            await waitUntil(timeout: .seconds(5)) {
                layout.collectionViewContentSize.height > 600
                    && layout.pendingRefinementIndexes.isEmpty
            }
        )

        for width in [420.0, 400.0, 380.0] {
            window.setContentSize(NSSize(width: width, height: 600))
            window.contentView?.layoutSubtreeIfNeeded()
            let visibleRect = controller.rootView.scrollView.documentVisibleRect
            // 待精测集合按条目顺序编号，与全部属性的顺序一致。
            let allAttributes = layout.layoutAttributesForElements(
                in: NSRect(x: 0, y: 0, width: 10_000, height: 1_000_000)
            )
            let visiblePending = layout.pendingRefinementIndexes.filter {
                allAttributes[$0].frame.intersects(visibleRect)
            }
            #expect(visiblePending.isEmpty, "width \(width)")
            let pendingCount = layout.pendingRefinementIndexes.count
            #expect(pendingCount > 0, "width \(width)")
            // 宽度还在变：几轮 main actor 之后视野外的行仍未精测，没有每次变化都白测一批。
            for _ in 0..<5 { await Task.yield() }
            #expect(layout.pendingRefinementIndexes.count == pendingCount, "width \(width)")
        }
        #expect(
            await waitUntil(timeout: .seconds(5)) { layout.pendingRefinementIndexes.isEmpty }
        )
    }

    @Test
    @MainActor
    func aboveAnchorMutationAndContinuousResizeKeepTheSameCommentPosition() async throws {
        let sidebar = HostedPlaybackSidebar()
        let controller = sidebar.controller
        let window = sidebar.window
        defer { sidebar.tearDown() }
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let initialThreads = (1...60).map {
            commentThread(id: Int64($0), message: "第 \($0) 条评论")
        }
        var mutatedThreads = initialThreads
        mutatedThreads[0] = commentThread(
            id: 1,
            message: String(repeating: "位于锚点上方的长评论正文", count: 20)
        )
        // 呈现是值，先全部构造：构造要等 ViewModel 加载，中途让出主线程会让侧栏的精测 Task 先跑、改变测量基准。
        let initialComments = await commentsPresentation(subject: subject, threads: initialThreads)
        let mutatedComments = await commentsPresentation(subject: subject, threads: mutatedThreads)
        controller.update(
            presentation: presentation(bvid: "BVResizeAnchor", comments: initialComments),
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

        controller.update(
            presentation: presentation(bvid: "BVResizeAnchor", comments: mutatedComments),
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
                maximumCount: NativePlaybackSidebarLayout.refinementBatchSize,
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
        let controller = makeSidebarController()
        controller.rootView.frame = NSRect(x: 0, y: 0, width: 440, height: 600)
        controller.rootView.layoutSubtreeIfNeeded()
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let loading = await liveCommentsPresentation(subject: subject, rootIsLoading: true)
        let loaded = await commentsPresentation(
            subject: subject,
            threads: (1...40).map {
                commentThread(id: Int64($0), message: "第 \($0) 条评论正文")
            }
        )
        var nextPageRequests = 0
        let testActions = sidebarActions(loadNextComments: { nextPageRequests += 1 })

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
        controller.tearDown()
    }
}
