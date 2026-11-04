import AppKit
import BiliApplication
import BiliModels
import Testing

@testable import BiliVideoDetailFeature

/// 楼中楼的对话入口、面板状态与过渡。
///
/// 翻页列表里回复别人的回复带「查看对话」，点按交出这条回复；看对话时顶部换成「返回全部回复」、底部「加载更多」，
/// 回复行不再提供入口。面板状态变化都让这一行重载，原地重配时只有新出现的回复淡入。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct PlaybackSidebarReplyDialogTests: PlaybackSidebarFixtures {
    @Test
    func pageListOffersViewConversationAndDialogModeOffersBackAndLoadMore() throws {
        let base = comment(id: 32, message: "回复别人的回复")
        let reply = BiliModels.Comment(
            id: base.id,
            rootID: CommentID(rawValue: 3),
            parentID: CommentID(rawValue: 31),
            dialogID: CommentID(rawValue: 31),
            payload: base.payload
        )
        var state = PlaybackCommentReplyState()
        state.isExpanded = true
        state.replies = [reply]
        state.totalCount = 2
        var shownDialogs: [BiliModels.Comment] = []
        var closedCount = 0
        let item = NativePlaybackCommentThreadItem()

        func configure(_ state: PlaybackCommentReplyState) {
            let row = NativePlaybackCommentThreadPresentation(
                subject: .video(aid: 700_001),
                thread: commentThread(id: 3, message: "根评论", replyCount: 2),
                replyState: state
            )
            configureThreadItem(
                item,
                with: row,
                onShowDialog: { shownDialogs.append($0) },
                onCloseDialog: { closedCount += 1 }
            )
        }

        func visibleButton(_ title: String) -> NSButton? {
            descendants(of: item.view).compactMap { $0 as? NSButton }
                .first { !$0.isHidden && $0.title == title }
        }

        // 翻页加载中原页的回复还在，入口不先消失。
        state.isLoading = true
        configure(state)
        #expect(visibleButton(VideoDetailFeatureStrings.localized("查看对话")) != nil)

        state.isLoading = false
        configure(state)
        try #require(visibleButton(VideoDetailFeatureStrings.localized("查看对话"))).performClick(nil)
        #expect(shownDialogs == [reply])
        #expect(visibleButton(VideoDetailFeatureStrings.localized("返回全部回复")) == nil)

        var dialog = PlaybackCommentDialogState(dialogID: CommentID(rawValue: 31))
        dialog.replies = [reply]
        dialog.hasLoadedFirstPage = true
        dialog.nextFloor = 3
        state.dialog = dialog
        configure(state)
        #expect(visibleButton(VideoDetailFeatureStrings.localized("查看对话")) == nil)
        #expect(visibleButton(VideoDetailFeatureStrings.localized("加载更多")) != nil)
        try #require(visibleButton(VideoDetailFeatureStrings.localized("返回全部回复"))).performClick(nil)
        #expect(closedCount == 1)

        // 对话到底却没有可显示的回复：给一句说明，不留空白面板。
        var emptyDialog = PlaybackCommentDialogState(dialogID: CommentID(rawValue: 31))
        emptyDialog.hasLoadedFirstPage = true
        state.dialog = emptyDialog
        configure(state)
        let message = VideoDetailFeatureStrings.localized("这串对话暂时没有可显示的回复")
        #expect(
            descendants(of: item.view).compactMap { $0 as? NSTextField }
                .contains { !$0.isHidden && $0.stringValue == message }
        )
        #expect(visibleButton(VideoDetailFeatureStrings.localized("加载更多")) == nil)
    }

    /// 同一条目原地重配时，新出现的回复行带上淡入动画；回复不变的重配沿用原来的行、不重新淡入，复用后的首次配置不带。
    @Test
    func inPlaceReconfigureFadesInOnlyNewReplyRows() {
        let item = NativePlaybackCommentThreadItem()
        func configure(_ state: PlaybackCommentReplyState) -> [NativePlaybackCommentRowView] {
            let row = NativePlaybackCommentThreadPresentation(
                subject: .video(aid: 700_001),
                thread: commentThread(id: 3, message: "根评论", replyCount: 2),
                replyState: state
            )
            configureThreadItem(item, with: row)
            // 第一行是根评论，其余是面板里的回复行。
            return Array(
                descendants(of: item.view).compactMap { $0 as? NativePlaybackCommentRowView }
                    .dropFirst()
            )
        }
        func fades(_ rows: [NativePlaybackCommentRowView]) -> [Bool] {
            rows.map { $0.layer?.animationKeys()?.isEmpty == false }
        }
        let fadesAreAllowed = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var state = PlaybackCommentReplyState()
        state.isExpanded = true
        state.replies = [comment(id: 31, message: "第一页")]
        state.totalCount = 2

        #expect(fades(configure(state)) == [false])

        state.replies = [comment(id: 32, message: "第二页")]
        state.pageNumber = 2
        let secondPage = configure(state)
        #expect(fades(secondPage) == [fadesAreAllowed])

        let unchanged = configure(state)
        #expect(unchanged.count == secondPage.count)
        #expect(zip(unchanged, secondPage).allSatisfy { $0 === $1 })

        item.prepareForReuse()
        state.replies = [comment(id: 33, message: "复用后")]
        #expect(fades(configure(state)) == [false])
    }

    /// 原地重配时仍显示的回复沿用原来的行视图，新回复的行按回复顺序排在子视图里（读屏按这个顺序朗读）。
    @Test
    func reconfigureKeepsRowsOfRepliesStillShownInReplyOrder() {
        let item = NativePlaybackCommentThreadItem()
        func configure(_ replyIDs: [Int64]) -> [NativePlaybackCommentRowView] {
            var state = PlaybackCommentReplyState()
            state.isExpanded = true
            state.replies = replyIDs.map { comment(id: $0, message: "回复 \($0)") }
            state.totalCount = 10
            configureThreadItem(
                item,
                with: NativePlaybackCommentThreadPresentation(
                    subject: .video(aid: 700_001),
                    thread: commentThread(id: 4, message: "根评论", replyCount: 10),
                    replyState: state
                )
            )
            // 第一行是根评论，其余是面板里按子视图顺序排列的回复行。
            return Array(
                descendants(of: item.view).compactMap { $0 as? NativePlaybackCommentRowView }
                    .dropFirst()
            )
        }

        let before = configure([41, 42])
        let after = configure([43, 41, 42])

        #expect(after.map { $0.commentForLayout?.id.rawValue } == [43, 41, 42])
        #expect(after[1] === before[0])
        #expect(after[2] === before[1])
    }

    /// 进出对话、对话加载状态变化都改变这一行的 revision，侧栏据此重载这一行。
    @Test
    func dialogStateChangesTheThreadRevision() {
        let thread = commentThread(id: 3, message: "根评论", replyCount: 2)
        var state = PlaybackCommentReplyState()
        state.isExpanded = true
        func revision(_ state: PlaybackCommentReplyState) -> Int {
            NativePlaybackCommentThreadPresentation(
                subject: .video(aid: 700_001),
                thread: thread,
                replyState: state
            ).revision
        }
        let pageList = revision(state)

        var dialog = PlaybackCommentDialogState(dialogID: CommentID(rawValue: 31))
        dialog.isLoading = true
        state.dialog = dialog
        let loadingDialog = revision(state)
        dialog.isLoading = false
        dialog.hasLoadedFirstPage = true
        state.dialog = dialog
        let loadedDialog = revision(state)

        #expect(Set([pageList, loadingDialog, loadedDialog]).count == 3)

        // 加载提示延迟露出时只有这个标记变化，同样要让这一行重载。
        state.isLoading = true
        let quietLoading = revision(state)
        state.isLoadingStatusVisible = true
        #expect(revision(state) != quietLoading)
    }

    /// 同一楼原地重配时只有之前没显示过的回复淡入；换了一楼或刚复用都不淡入。
    @Test
    func onlyNewlyShownRepliesOfTheSameThreadFadeIn() {
        let root = CommentID(rawValue: 3)
        let ids = (31...33).map { CommentID(rawValue: $0) }
        func fading(
            previousRoot: CommentID?,
            previous: [CommentID],
            next: [CommentID]
        ) -> Set<CommentID> {
            NativePlaybackCommentRepliesPanelView.newlyShownReplyIDs(
                previousRootID: previousRoot,
                previousReplyIDs: Set(previous),
                rootID: root,
                replyIDs: next
            )
        }

        #expect(fading(previousRoot: root, previous: [ids[0], ids[1]], next: ids) == [ids[2]])
        #expect(fading(previousRoot: root, previous: [], next: ids) == Set(ids))
        #expect(fading(previousRoot: root, previous: ids, next: ids).isEmpty)
        #expect(fading(previousRoot: CommentID(rawValue: 4), previous: [], next: ids).isEmpty)
        #expect(fading(previousRoot: nil, previous: [], next: ids).isEmpty)
    }
}
