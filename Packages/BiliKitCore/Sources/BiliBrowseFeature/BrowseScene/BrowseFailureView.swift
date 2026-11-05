import BiliApplication
import BiliUI
import SwiftUI

/// Browse 页面（推荐、热门、搜索）的整页失败：把内容失败交给共享的 `ContentFailureView`。
struct BrowseFailureView: View {
    let title: String
    let message: String
    /// nil 时不提供重试（需要登录、内容不存在或不可见）。
    let retry: (() -> Void)?

    /// `isAwaitingRevalidation` 是模型的 `isAwaitingAuthenticationRevalidation`。
    init(error: ContentApplicationError, isAwaitingRevalidation: Bool, retry: @escaping () -> Void)
    {
        let text = error.browseFailureText(isAwaitingRevalidation: isAwaitingRevalidation)
        title = text.title
        message = text.message
        self.retry = error.isRetryable ? retry : nil
    }

    var body: some View {
        ContentFailureView(title: title, message: message, retry: retry)
    }
}

extension ContentApplicationError {
    /// 没有专属标题的失败统称“无法加载内容”。
    ///
    /// 凭据失效总会让 Browse 请求一次复核（`BrowseViewModel`）：复核进行中说“正在重新确认”，复核结束、离开过页面或
    /// 复核后的重载仍失败时给静态说明，不再声称仍在确认。其余失败与复核无关。
    func browseFailureText(isAwaitingRevalidation: Bool) -> ContentFailureText {
        let revalidation: ContentFailureText.Revalidation =
            if requiresAccountRevalidation {
                isAwaitingRevalidation ? .awaiting : .finished
            } else {
                .unknown
            }
        return ContentFailureText(
            error: self,
            fallbackTitle: BrowseFeatureStrings.localized("无法加载内容"),
            revalidation: revalidation
        )
    }
}
