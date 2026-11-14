import BiliApplication
import BiliModels
import CoreGraphics
import Foundation

/// 侧栏一次呈现的全部内容：UP 主名片、简介、选集与评论的投影。
///
/// 由 `NativePlaybackSidebarView` 从 `VideoViewModel` 与 `PlaybackCommentsViewModel` 读出；只是值，不拥有任何状态。
struct NativePlaybackSidebarContent: Equatable {
    let bvid: String
    let uploader: VideoUploaderHeaderContent
    let summary: String
    let summaryLinks: [CommentLink]
    let selection: PlaybackSelectionProjection
    let comments: NativePlaybackCommentsPresentation
    /// 简介与评论正文里时间戳可跳转的上限（不含）：播放器就绪的分 P 的可跳转时长
    /// （`VideoContext.seekableDurationSeconds`）；加载中或时长未知时为 nil，时间戳都按普通文字显示。
    let timestampLimitSeconds: Int?
}

/// 盖在侧栏内容上的状态层：加载中、可重试的失败或不可用。
///
/// 除 `.none` 外都挡住内容，集合视图隐藏并交出焦点。
enum NativePlaybackSidebarOverlay: Equatable {
    case none
    case loading(label: String)
    case failure(title: String, message: String)
    case unavailable(title: String, message: String)

    var blocksContent: Bool {
        self != .none
    }
}

extension NativePlaybackSidebarOverlay {
    static func resolve(
        state: VideoLoadState,
        hasPresentedContent: Bool
    ) -> Self {
        if hasPresentedContent {
            switch state {
            case .loading:
                return .loading(label: VideoDetailFeatureStrings.localized("正在加载所选视频上下文"))
            case .failed(_, let failure):
                return failureOverlay(for: failure)
            case .idle, .loadingPage, .preparingPlayback, .ready, .failedPage:
                return .none
            }
        }

        switch state {
        case .loading, .loadingPage, .preparingPlayback:
            return .loading(label: VideoDetailFeatureStrings.localized("正在加载视频上下文"))
        case .failed(_, let failure), .failedPage(_, _, let failure):
            return failureOverlay(for: failure)
        case .idle:
            return .unavailable(
                title: VideoDetailFeatureStrings.localized("没有播放上下文"),
                message: VideoDetailFeatureStrings.localized("返回来源页并重新选择视频。")
            )
        case .ready:
            return .none
        }
    }

    /// 不可重试的失败（需要登录、内容不存在或不可见）不给重试按钮。
    private static func failureOverlay(for failure: VideoLoadFailure) -> Self {
        failure.isRetryable
            ? .failure(title: failure.title, message: failure.message)
            : .unavailable(title: failure.title, message: failure.message)
    }
}

/// 侧栏控制器的输入：内容（可能为空）与覆盖层；分区、条目身份与变化的条目都由它推导。
struct NativePlaybackSidebarPresentation: Equatable {
    let content: NativePlaybackSidebarContent?
    let overlay: NativePlaybackSidebarOverlay
}

/// 集合视图的语义分区；顺序固定为名片、简介、选集、评论，没有内容的分区不出现。
enum NativePlaybackSidebarSectionID: Hashable {
    case uploader
    case summary
    case selection
    case comments
}

/// diffable 数据源的条目身份。
///
/// 视频相关的条目按 BVID 区分，评论按评论对象（subject）与根评论 ID 区分：换视频或换评论对象时身份变化、整项
/// 替换，同一对象内追加的评论保持原有身份，行高缓存与阅读锚点据此延续。
enum NativePlaybackSidebarItemID: Hashable {
    case uploader(bvid: String)
    case summary(bvid: String)
    case selection(bvid: String)
    case commentsHeader(subject: CommentSubjectIdentity?)
    case commentsState(subject: CommentSubjectIdentity?, kind: NativePlaybackCommentsStateKind)
    case commentThread(subject: CommentSubjectIdentity, rootID: CommentID)
    case commentsFooter(subject: CommentSubjectIdentity)
}

/// 评论区没有评论列表时显示的状态行。
enum NativePlaybackCommentsStateKind: Hashable {
    case idle
    case loading
    case empty
    case closed
    /// 是否给重试只由 `CommentReadError.isRetryable` 决定。
    case failed(CommentReadError)
}

/// 一个分区及其条目，供更新策略比较当前快照与下一快照。
struct NativePlaybackSidebarSnapshotSection: Equatable {
    let id: NativePlaybackSidebarSectionID
    let items: [NativePlaybackSidebarItemID]
}

/// 一次呈现更新落到集合视图的方式，由 `NativePlaybackSidebarCollectionUpdatePolicy` 选出。
enum NativePlaybackSidebarCollectionUpdateStrategy: Equatable {
    case none
    case reloadChangedItems
    case appendComments
    case replaceSnapshot
}

/// 选择更新方式：结构不变只重载变化的行；评论在页脚之前追加时走追加路径（先更新布局，再在时长 0 的动画组里按差异插入，阅读位置不跳）；其余整体替换快照。
///
/// 上一个快照还在应用中时一律整体替换，避免在未完成的快照上做增量。
enum NativePlaybackSidebarCollectionUpdatePolicy {
    static func resolve(
        current: [NativePlaybackSidebarSnapshotSection],
        next: [NativePlaybackSidebarSnapshotSection],
        changedItemIDs: Set<NativePlaybackSidebarItemID>,
        hasSnapshotInFlight: Bool
    ) -> NativePlaybackSidebarCollectionUpdateStrategy {
        guard !hasSnapshotInFlight else { return .replaceSnapshot }
        if current == next {
            return changedItemIDs.isEmpty ? .none : .reloadChangedItems
        }
        if appendsCommentsBeforeStableFooter(current: current, next: next) {
            return .appendComments
        }
        return .replaceSnapshot
    }

    private static func appendsCommentsBeforeStableFooter(
        current: [NativePlaybackSidebarSnapshotSection],
        next: [NativePlaybackSidebarSnapshotSection]
    ) -> Bool {
        guard current.count == next.count else { return false }
        var appendedComments = false
        for (previousSection, nextSection) in zip(current, next) {
            guard previousSection.id == nextSection.id else { return false }
            guard previousSection.id == .comments else {
                guard previousSection.items == nextSection.items else { return false }
                continue
            }
            let previousItems = previousSection.items
            let nextItems = nextSection.items
            guard previousItems.count >= 2,
                nextItems.count > previousItems.count,
                previousItems.first == nextItems.first,
                previousItems.last == nextItems.last,
                Array(nextItems.prefix(previousItems.count - 1))
                    == Array(previousItems.dropLast())
            else { return false }
            let insertedItems = nextItems[
                (previousItems.count - 1)..<(nextItems.count - 1)
            ]
            guard
                insertedItems.allSatisfy({ itemID in
                    if case .commentThread = itemID { return true }
                    return false
                })
            else { return false }
            appendedComments = true
        }
        return appendedComments
    }
}

extension NativePlaybackSidebarPresentation {
    var sections: [(id: NativePlaybackSidebarSectionID, items: [NativePlaybackSidebarItemID])] {
        guard let content else { return [] }
        var result: [(id: NativePlaybackSidebarSectionID, items: [NativePlaybackSidebarItemID])] = [
            (.uploader, [.uploader(bvid: content.bvid)])
        ]
        if !content.summary.isEmpty {
            result.append((.summary, [.summary(bvid: content.bvid)]))
        }
        if !content.selection.isHidden {
            result.append((.selection, [.selection(bvid: content.bvid)]))
        }
        result.append((.comments, commentItems(content.comments)))
        return result
    }

    private func commentItems(
        _ comments: NativePlaybackCommentsPresentation
    ) -> [NativePlaybackSidebarItemID] {
        var items: [NativePlaybackSidebarItemID] = [
            .commentsHeader(subject: comments.subject)
        ]
        switch comments.rootState {
        case .idle:
            items.append(.commentsState(subject: comments.subject, kind: .idle))
        case .loading:
            items.append(.commentsState(subject: comments.subject, kind: .loading))
        case .empty:
            items.append(.commentsState(subject: comments.subject, kind: .empty))
        case .failed(.closed):
            items.append(.commentsState(subject: comments.subject, kind: .closed))
        case .failed(let error):
            items.append(.commentsState(subject: comments.subject, kind: .failed(error)))
        case .loaded:
            guard let subject = comments.subject else {
                items.append(.commentsState(subject: nil, kind: .idle))
                return items
            }
            items.append(
                contentsOf: comments.threads.map {
                    .commentThread(subject: subject, rootID: $0.thread.id)
                }
            )
            items.append(.commentsFooter(subject: subject))
        }
        return items
    }

    var itemIDs: [NativePlaybackSidebarItemID] {
        sections.flatMap(\.items)
    }

    var snapshotSections: [NativePlaybackSidebarSnapshotSection] {
        sections.map {
            NativePlaybackSidebarSnapshotSection(id: $0.id, items: $0.items)
        }
    }

    func changedItemIDs(
        comparedTo previous: NativePlaybackSidebarPresentation
    ) -> Set<NativePlaybackSidebarItemID> {
        guard let previousContent = previous.content,
            let content,
            previousContent.bvid == content.bvid
        else { return [] }

        var changed: Set<NativePlaybackSidebarItemID> = []
        if previousContent.uploader != content.uploader {
            changed.insert(.uploader(bvid: content.bvid))
        }
        // 分 P 时长变化只影响时间戳是否显示为链接，不改变行高；只重新配置含时间戳的简介与评论。
        let timestampLimitChanged =
            previousContent.timestampLimitSeconds != content.timestampLimitSeconds
        if previousContent.summary != content.summary
            || previousContent.summaryLinks != content.summaryLinks
            || (timestampLimitChanged
                && NativePlaybackTextLinks.containsTimestamp(content.summaryLinks))
        {
            changed.insert(.summary(bvid: content.bvid))
        }
        if previousContent.selection != content.selection {
            changed.insert(.selection(bvid: content.bvid))
        }
        if previousContent.comments.sort != content.comments.sort
            || previousContent.comments.totalCount != content.comments.totalCount
            || previousContent.comments.sortIsEnabled != content.comments.sortIsEnabled
        {
            changed.insert(.commentsHeader(subject: content.comments.subject))
        }
        let previousThreads = Dictionary(
            uniqueKeysWithValues: previousContent.comments.threads.map {
                ($0.thread.id, ($0.revision, $0.reactionRevision))
            }
        )
        for thread in content.comments.threads
        where (timestampLimitChanged && thread.containsTimestampLinks)
            || previousThreads[thread.thread.id]?.0 != thread.revision
            || previousThreads[thread.thread.id]?.1 != thread.reactionRevision
        {
            changed.insert(
                .commentThread(subject: thread.subject, rootID: thread.thread.id)
            )
        }
        if previousContent.comments.footer != content.comments.footer,
            let subject = content.comments.subject
        {
            changed.insert(.commentsFooter(subject: subject))
        }
        return changed
    }
}

/// 换到另一个视频（BVID 变化且新值非空）时侧栏回到顶部；同一视频内的更新保持阅读位置。
enum NativePlaybackSidebarIdentityPolicy {
    static func resetsToTop(
        previousBVID: String?,
        nextBVID: String?
    ) -> Bool {
        nextBVID != nil && previousBVID != nextBVID
    }
}

/// 评论分页或页脚变化时按评论锚点保持相对位置，而不是跟随底部：同一评论对象、同一排序、都已加载，且页脚
/// 变化，或新列表更长并以旧列表为前缀。
enum NativePlaybackCommentsAnchorPolicy {
    static func preservesRelativePosition(
        previous: NativePlaybackCommentsPresentation?,
        next: NativePlaybackCommentsPresentation?
    ) -> Bool {
        guard let previous, let next, previous.subject != nil,
            previous.subject == next.subject, previous.sort == next.sort,
            previous.rootState == .loaded, next.rootState == .loaded
        else { return false }

        if previous.footer != next.footer { return true }
        let previousIDs = previous.threads.map { $0.thread.id }
        let nextIDs = next.threads.map { $0.thread.id }
        return nextIDs.count > previousIDs.count
            && Array(nextIDs.prefix(previousIDs.count)) == previousIDs
    }
}

/// 判断视口是否贴在底部；贴底时更新后继续贴底，否则按语义锚点恢复。
enum NativePlaybackSidebarAnchorPolicy {
    /// 距底部 2pt 以内算贴底：吸收布局取整误差，又不会把离底部还有一行的位置误判为贴底。
    private static let bottomTolerance: CGFloat = 2

    static func isBottomPinned(
        contentHeight: CGFloat,
        viewport: NSRect
    ) -> Bool {
        let maximumY = max(0, contentHeight - viewport.height)
        guard maximumY > bottomTolerance else { return false }
        return maximumY - viewport.minY <= bottomTolerance
    }
}
