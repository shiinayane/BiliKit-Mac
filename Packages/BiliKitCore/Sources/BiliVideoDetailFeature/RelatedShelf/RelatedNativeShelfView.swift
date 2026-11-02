import BiliModels
import BiliUI
import BiliVideoCollectionUI
import SwiftUI

/// 播放页主区下方的相关推荐横排：把相关推荐投影映射为共享卡片，经卡片取图 port 加载封面；卡片菜单见 `cardMenu`。
struct RelatedNativeShelfView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.videoCardAccountWriting) private var accountWriting
    let contentIdentity: String
    let presentations: [RelatedVideoCardPresentation]
    let imagePipeline: any NativeVideoImageLoading
    let onSelect: (String) -> Void

    init(
        contentIdentity: String,
        presentations: [RelatedVideoCardPresentation],
        imagePipeline: any NativeVideoImageLoading,
        onSelect: @escaping (String) -> Void
    ) {
        self.contentIdentity = contentIdentity
        self.presentations = presentations
        self.imagePipeline = imagePipeline
        self.onSelect = onSelect
    }

    var body: some View {
        NativeVideoShelfView(
            contentIdentity: contentIdentity,
            items: Self.makePresentations(presentations),
            imagePipeline: imagePipeline,
            onSelect: onSelect,
            cardMenu: { Self.cardMenu(for: $0, openURL: openURL, writing: accountWriting) }
        )
        .ignoresSafeArea(.container, edges: .horizontal)
    }

    /// 相关推荐卡片的菜单：「添加到稍后再看」一组加「拷贝链接」「在浏览器中打开」一组，规则在共用的
    /// `NativeVideoCardMenu.video`。
    ///
    /// 卡片 ID 就是 BVID，不合法时没有菜单。`openURL` 是从环境取得的系统 `OpenURLAction`，`writing` 是 App 从环境注入的
    /// 写入口（未登录或复核中时写操作项禁用）。
    static func cardMenu(
        for card: NativeVideoCardPresentation,
        openURL: OpenURLAction,
        writing: VideoCardAccountWriting?
    ) -> NativeVideoCardMenu? {
        NativeVideoCardMenu.video(
            videoID: card.id,
            isActivatable: card.isActivatable,
            webPageURL: BVID.webPageURL(card.id),
            openURL: openURL,
            writing: writing,
            watchLater: .add
        )
    }

    static func makePresentations(
        _ presentations: [RelatedVideoCardPresentation]
    ) -> [NativeVideoCardPresentation] {
        presentations.map { presentation in
            NativeVideoCardPresentation(
                id: presentation.bvid,
                title: presentation.title,
                coverURL: presentation.coverURL,
                avatarURL: nil,
                showsAvatar: false,
                coverMetrics: [
                    NativeVideoCardMetric(
                        text: presentation.viewCountText,
                        systemImage: "play.fill"
                    ),
                    NativeVideoCardMetric(
                        text: presentation.danmakuCountText,
                        systemImage: "text.bubble.fill"
                    )
                ],
                coverTrailingText: presentation.durationText,
                footerLeadingText: presentation.ownerName,
                accessibilityLabel: presentation.accessibilityLabel,
                accessibilityHelp: VideoDetailFeatureStrings.localized("播放并替换当前视频")
            )
        }
    }
}
