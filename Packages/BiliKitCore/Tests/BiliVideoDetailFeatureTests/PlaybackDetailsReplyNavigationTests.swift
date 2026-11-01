import AppKit
import BiliApplication
import BiliModels
import Testing

@testable import BiliVideoDetailFeature

/// 楼中楼翻页与进出对话时，回复面板顶边已在可见区上方就把它顶到顶部；收起时根评论顶边同理；对齐边仍可见时这一楼
/// 停在原处。
///
/// 定位意图保留到这一楼加载完成，加载态与回复到达都按它定位。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct PlaybackDetailsReplyNavigationTests: PlaybackDetailsFixtures {
    private static let subject = CommentSubjectIdentity.video(aid: 700_001)
    private static let rootID = CommentID(rawValue: 5)
    private static let itemID = NativePlaybackDetailsItemID.commentThread(
        subject: subject,
        rootID: rootID
    )

    @Test
    func pageChangeBringsTheRepliesPanelUpOnlyWhenItsTopWasAbove() async throws {
        let states = await replyStates(next: .page)
        let sidebar = try await SidebarHarness(fixtures: self, comments: states.expanded)
        defer { sidebar.tearDown() }

        let panelTop = try sidebar.alignmentY(.repliesPanel)
        sidebar.controller.scroll(to: panelTop - 40)
        sidebar.controller.prepareThreadAlignment(Self.itemID, edge: .repliesPanel)
        let rootTop = try sidebar.alignmentY(.root)
        #expect(
            sidebar.controller.pendingThreadAlignment?.target
                == .keepItemTop(offsetFromVisibleTop: rootTop - sidebar.visibleTop)
        )

        sidebar.controller.scroll(to: panelTop + 20)
        sidebar.controller.prepareThreadAlignment(Self.itemID, edge: .repliesPanel)
        sidebar.update(states.changed)
        func panelIsAtTop() -> Bool {
            (try? abs(sidebar.alignmentY(.repliesPanel) - sidebar.visibleTop)) ?? .infinity <= 1
        }
        #expect(await waitUntil(timeout: .seconds(5)) { panelIsAtTop() })
        #expect(sidebar.controller.pendingThreadAlignment != nil)

        sidebar.update(await states.arrive())
        #expect(
            await waitUntil(timeout: .seconds(5)) {
                panelIsAtTop() && sidebar.controller.pendingThreadAlignment == nil
            }
        )
    }

    @Test
    func enteringADialogKeepsTheRepliesPanelAtTheTopThroughArrival() async throws {
        let states = await replyStates(next: .dialog)
        let sidebar = try await SidebarHarness(fixtures: self, comments: states.expanded)
        defer { sidebar.tearDown() }

        let panelTop = try sidebar.alignmentY(.repliesPanel)
        sidebar.controller.scroll(to: panelTop + 20)
        sidebar.controller.prepareThreadAlignment(Self.itemID, edge: .repliesPanel)
        sidebar.update(states.changed)
        func panelIsAtTop() -> Bool {
            (try? abs(sidebar.alignmentY(.repliesPanel) - sidebar.visibleTop)) ?? .infinity <= 1
        }
        #expect(await waitUntil(timeout: .seconds(5)) { panelIsAtTop() })
        #expect(sidebar.controller.pendingThreadAlignment != nil)

        sidebar.update(await states.arrive())
        #expect(
            await waitUntil(timeout: .seconds(5)) {
                panelIsAtTop() && sidebar.controller.pendingThreadAlignment == nil
            }
        )
    }

    @Test
    func collapseBringsTheRootCommentUpWhenItsTopWasAbove() async throws {
        let states = await replyStates(next: .collapse)
        let sidebar = try await SidebarHarness(fixtures: self, comments: states.expanded)
        defer { sidebar.tearDown() }

        let rootTop = try sidebar.alignmentY(.root)
        sidebar.controller.scroll(to: rootTop + 30)
        sidebar.controller.prepareThreadAlignment(Self.itemID, edge: .root)
        sidebar.update(states.changed)
        #expect(
            await waitUntil(timeout: .seconds(5)) {
                (try? abs(sidebar.alignmentY(.root) - sidebar.visibleTop)) ?? .infinity <= 1
            }
        )
        #expect(sidebar.controller.pendingThreadAlignment == nil)
        _ = await states.arrive()
    }

    private enum NextStep {
        case page
        case dialog
        case collapse
    }

    /// 第 5 楼展开第一页的呈现，翻到第 2 页（请求挂起、面板显示加载中）或收起之后的呈现，以及放行挂起的请求、
    /// 等第 2 页到达后的呈现。
    ///
    /// 前两个呈现先构造：构造要等 ViewModel 加载，中途让出主线程会让侧栏的精测 Task 先跑、改变测量基准。
    private func replyStates(
        next: NextStep
    ) async -> (
        expanded: NativePlaybackCommentsPresentation,
        changed: NativePlaybackCommentsPresentation,
        arrive: () async -> NativePlaybackCommentsPresentation
    ) {
        let threads = (1...40).map { id in
            commentThread(
                id: Int64(id),
                message: "第 \(id) 条评论",
                replyCount: id == Int(Self.rootID.rawValue) ? 25 : 0
            )
        }
        let repository = CommentRepositoryStub(
            rootPages: [
                CommentRootPage(
                    threads: threads,
                    totalCount: threads.count,
                    continuation: nil,
                    isEnd: true
                )
            ],
            replyTotalCount: 25,
            heldReplyPages: [2],
            holdsDialogs: true
        )
        let model = PlaybackCommentsViewModel(useCase: CommentUseCase(repository: repository))
        model.activate(subject: Self.subject)
        await model.waitForCurrentRootTask()
        model.expandReplies(for: Self.rootID)
        await waitForObservedState { model.replyStates[Self.rootID]?.isLoading == false }
        let expanded = NativePlaybackCommentsPresentation(model: model)
        switch next {
        case .page: model.showReplyPage(2, for: Self.rootID)
        case .dialog:
            model.showDialog(
                of: BiliModels.Comment(
                    id: CommentID(rawValue: 53),
                    rootID: Self.rootID,
                    parentID: CommentID(rawValue: 52),
                    dialogID: CommentID(rawValue: 51),
                    payload: .unavailable(.unavailable)
                ),
                for: Self.rootID
            )
        case .collapse: model.collapseReplies(for: Self.rootID)
        }
        let changed = NativePlaybackCommentsPresentation(model: model)
        return (
            expanded,
            changed,
            {
                // 先等请求真正到达替身再放行，否则放行早于挂起，请求会一直挂着。
                switch next {
                case .page:
                    await repository.waitForReplyRequestCount(2)
                    await repository.releaseAllHeldReplies()
                case .dialog:
                    await repository.waitForDialogRequestCount(1)
                    await repository.releaseDialogs()
                case .collapse:
                    break
                }
                await waitForObservedState {
                    let state = model.replyStates[Self.rootID]
                    return state?.isLoading != true && state?.dialog?.isLoading != true
                }
                return NativePlaybackCommentsPresentation(model: model)
            }
        )
    }
}

/// 挂在真实窗口里的侧栏控制器，加上读取第 5 楼对齐边与可见区顶边的帮手。
@MainActor
private struct SidebarHarness {
    let controller = makeSidebarController()
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 440, height: 600),
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    let fixtures: PlaybackDetailsReplyNavigationTests

    init(
        fixtures: PlaybackDetailsReplyNavigationTests,
        comments: NativePlaybackCommentsPresentation
    ) async throws {
        self.fixtures = fixtures
        window.contentView = controller.rootView
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        update(comments)
        let layout = controller.layout
        let settled = await waitUntil(timeout: .seconds(5)) { [controller] in
            controller.layout.collectionViewContentSize.height > 600
                && layout.pendingRefinementIndexes.isEmpty
        }
        try #require(settled)
    }

    var visibleTop: CGFloat {
        controller.rootView.scrollView.documentVisibleRect.minY
            + max(0, controller.rootView.scrollView.contentInsets.top)
    }

    func update(_ comments: NativePlaybackCommentsPresentation) {
        controller.update(
            presentation: fixtures.presentation(bvid: "BVReplyNavigation", comments: comments),
            actions: fixtures.actions
        )
    }

    func alignmentY(_ edge: NativePlaybackDetailsThreadAlignment.Edge) throws -> CGFloat {
        controller.collectionView.layoutSubtreeIfNeeded()
        let itemID = NativePlaybackDetailsItemID.commentThread(
            subject: .video(aid: 700_001),
            rootID: CommentID(rawValue: 5)
        )
        let indexPath = try #require(controller.dataSource?.indexPath(for: itemID))
        let frame = try #require(controller.layout.layoutAttributesForItem(at: indexPath)).frame
        switch edge {
        case .root:
            return frame.minY
        case .repliesPanel:
            let thread = try #require(controller.commentThreadsByItemID[itemID])
            return frame.minY
                + NativePlaybackCommentsItemMeasurement.repliesPanelTop(
                    thread,
                    width: frame.width,
                    textRenderer: controller.commentTextRenderer
                )
        }
    }

    func tearDown() {
        controller.tearDown()
        window.contentView = nil
    }
}
