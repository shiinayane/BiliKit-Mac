import AppKit
import BiliModels
import Foundation

/// 评论作者与正文 @ 用户进入 UP 主空间的入口规则：只有正整数 MID 的用户有入口。
enum NativePlaybackCommentAuthorSpace {
    static func isOpenable(_ author: CommentAuthor) -> Bool {
        author.id.memberID != nil
    }

    /// 正文链接的去向：@ 提及在应用内打开空间（未登录时空间层显示登录提示），其他链接交给原有处理。
    static func openLink(
        _ target: CommentLinkTarget,
        openSpace: (CommentAuthor) -> Void,
        otherwise: (CommentLinkTarget) -> Void
    ) {
        if case .member(let user) = target {
            openSpace(user)
            return
        }
        otherwise(target)
    }

    /// 头像经评论资源解析器取得，沿用评论头像的来源限制；解析失败时空间头部显示占位。
    static func owner(
        for author: CommentAuthor,
        resolveAvatar: CommentAssetURLResolver
    ) -> VideoOwner? {
        guard let id = author.id.memberID else { return nil }
        return VideoOwner(
            id: id,
            name: author.name,
            avatarURL: author.avatar.flatMap {
                resolveAvatar($0, NativePlaybackCommentAssetSizing.pixelBox(for: .avatar))
            }
        )
    }
}

/// 评论行的作者入口：头像与昵称可点进入空间，昵称同时提供 VoiceOver 操作。
///
/// 指针与 VoiceOver 走同一个入口；评论不可见、作者 MID 不合法或没有空间入口时整块不可点。
/// 正文、徽章与元数据不在区域内，正文链接与选择不受影响。
@MainActor
final class NativePlaybackCommentAuthorEntry {
    private let region = NativeClickRegion()
    private weak var avatar: NSView?
    private weak var nameLabel: NSTextField?
    private var open: (() -> Void)?

    func attach(to host: NSView, avatar: NSView, nameLabel: NSTextField) {
        self.avatar = avatar
        self.nameLabel = nameLabel
        region.attach(to: host) { [weak self] in self?.open?() }
    }

    /// 评论不可见或行被复用时传 nil，清掉入口。
    func configure(author: CommentAuthor?, onOpen: ((CommentAuthor) -> Void)?) {
        if let author, let onOpen, NativePlaybackCommentAuthorSpace.isOpenable(author) {
            open = { onOpen(author) }
        } else {
            open = nil
        }
        nameLabel?.setAccessibilityCustomActions(
            open == nil
                ? []
                : [
                    NSAccessibilityCustomAction(name: VideoDetailFeatureStrings.localized("查看空间")) {
                        [weak self] in
                        guard let open = self?.open else { return false }
                        open()
                        return true
                    }
                ]
        )
        updateLayout()
    }

    /// 宿主布局后调用，按头像与昵称的当前位置更新可点区域。
    func updateLayout() {
        guard open != nil, let avatar, let nameLabel else {
            region.setRects([])
            return
        }
        region.setRects([avatar.frame, nameLabel.frame])
    }
}
