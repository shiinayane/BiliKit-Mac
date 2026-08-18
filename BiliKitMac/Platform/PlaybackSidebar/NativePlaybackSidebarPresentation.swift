import BiliBrowseFeature
import BiliModels
import Foundation

struct NativePlaybackSidebarContent: Equatable {
    let bvid: String
    let uploader: VideoUploaderHeaderContent
    let summary: String
    let selection: PlaybackSelectionProjection
    let comments: NativePlaybackCommentsPresentation
}

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
        state: GuestVideoState,
        hasPresentedContent: Bool
    ) -> Self {
        if hasPresentedContent {
            switch state {
            case .loading:
                return .loading(label: "正在加载所选视频上下文")
            case .failed(_, let failure):
                return .failure(title: failure.title, message: failure.message)
            case .idle, .loadingPage, .preparingPlayback, .ready, .failedPage:
                return .none
            }
        }

        switch state {
        case .loading, .loadingPage, .preparingPlayback:
            return .loading(label: "正在加载视频上下文")
        case .failed(_, let failure), .failedPage(_, _, let failure):
            return .failure(title: failure.title, message: failure.message)
        case .idle:
            return .unavailable(
                title: "没有播放上下文",
                message: "返回来源页并重新选择视频。"
            )
        case .ready:
            return .none
        }
    }
}

struct NativePlaybackSidebarPresentation: Equatable {
    let content: NativePlaybackSidebarContent?
    let overlay: NativePlaybackSidebarOverlay
}

enum NativePlaybackSidebarSectionID: Hashable {
    case uploader
    case summary
    case selection
    case comments
}

enum NativePlaybackSidebarItemID: Hashable {
    case uploader(bvid: String)
    case summary(bvid: String)
    case selection(bvid: String)
    case commentsHeader(subject: CommentSubjectIdentity?)
    case commentsState(subject: CommentSubjectIdentity?, kind: NativePlaybackCommentsStateKind)
    case commentThread(subject: CommentSubjectIdentity, rootID: CommentID)
    case commentsFooter(subject: CommentSubjectIdentity)
}

enum NativePlaybackCommentsStateKind: Hashable {
    case idle
    case loading
    case empty
    case failed
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
        case .failed:
            items.append(.commentsState(subject: comments.subject, kind: .failed))
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
        if previousContent.summary != content.summary {
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
                ($0.thread.id, $0.revision)
            }
        )
        for thread in content.comments.threads
        where previousThreads[thread.thread.id] != thread.revision {
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
