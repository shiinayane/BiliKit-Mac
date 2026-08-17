import BiliBrowseFeature
import BiliModels
import Foundation

struct NativePlaybackSidebarContent: Equatable {
    let bvid: String
    let uploader: VideoUploaderHeaderContent
    let summary: String
    let selection: PlaybackSelectionProjection
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
    case commentsUnavailable(bvid: String)
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
        result.append((.comments, [.commentsUnavailable(bvid: content.bvid)]))
        return result
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
        return changed
    }
}
