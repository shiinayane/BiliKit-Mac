import BiliApplication
import BiliModels
import BiliUI
import BiliVideoCollectionUI
import SwiftUI

/// 首页推荐、热门与搜索网格的卡片菜单：三个来源的网格包装都把它交给 `NativeVideoGridView` 的 `cardMenu`。
///
/// 「添加到稍后再看」「收藏到…」一组（`writing` 为 App 从环境注入的写入口，未登录或复核中时禁用）加「拷贝链接」「在
/// 浏览器中打开」一组，规则在共用的 `NativeVideoCardMenu.video`；卡片 ID 就是 BVID，不合法时没有菜单。首页推荐另给
/// `recommendation`，写操作一组末尾多出「不感兴趣 ▸」或「撤销不感兴趣」。`openURL` 是网格包装从环境取得的系统
/// `OpenURLAction`。无状态。
enum BrowseVideoCardMenu {
    /// 首页推荐卡片的反馈状态：没标过时可以说「不感兴趣」（需要卡片给出原因），标过时可以撤销。
    enum RecommendationFeedbackState {
        case notDisliked(RecommendedVideo)
        case disliked(RecommendationFeedback)
    }

    @MainActor
    static func menu(
        for card: NativeVideoCardPresentation,
        openURL: OpenURLAction,
        writing: VideoCardAccountWriting?,
        recommendation: RecommendationFeedbackState? = nil
    ) -> NativeVideoCardMenu? {
        NativeVideoCardMenu.video(
            videoID: card.id,
            isActivatable: card.isActivatable,
            webPageURL: BVID.webPageURL(card.id),
            openURL: openURL,
            writing: writing,
            watchLater: .add,
            additionalWriteItems: recommendation.map { feedbackItems($0, writing: writing) } ?? []
        )
    }

    /// 「不感兴趣 ▸」（子项是卡片给出的原因，名字原样显示）或「撤销不感兴趣」；没有写入口、或卡片没给原因时为空。
    @MainActor
    private static func feedbackItems(
        _ state: RecommendationFeedbackState,
        writing: VideoCardAccountWriting?
    ) -> [NativeVideoCardMenu.Item] {
        guard let writing else { return [] }
        let isEnabled = writing.isAvailable()
        switch state {
        case .disliked(let feedback):
            return [
                NativeVideoCardMenu.Item(
                    id: "undoNotInterested",
                    title: VideoCardMenuText.undoNotInterested,
                    systemImage: "arrow.uturn.backward",
                    isEnabled: isEnabled
                ) { writing.cancelRecommendationDislike(feedback) }
            ]
        case .notDisliked(let video):
            guard let target = VideoWriteTarget(bvid: video.bvid) else { return [] }
            // 原因 id 在同一张卡片里唯一（解码时已去重），读屏操作按它找回这一项。
            let children = video.dislikeReasons.map { reason in
                NativeVideoCardMenu.Item(
                    id: "notInterested.\(reason.id)",
                    title: reason.name,
                    systemImage: "eye.slash",
                    isEnabled: isEnabled
                ) {
                    writing.dislikeRecommendation(
                        RecommendationFeedback(target: target, reason: reason)
                    )
                }
            }
            guard !children.isEmpty else { return [] }
            return [
                NativeVideoCardMenu.Item(
                    id: "notInterested",
                    title: VideoCardMenuText.notInterested,
                    systemImage: "hand.thumbsdown",
                    submenu: children
                )
            ]
        }
    }
}
