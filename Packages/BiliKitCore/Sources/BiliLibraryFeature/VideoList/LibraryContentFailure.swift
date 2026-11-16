import BiliApplication
import BiliUI
import Foundation

/// 资料库来源（观看历史、稍后再看、关注、收藏夹）的失败呈现：整页失败视图与胶囊里的一行说明。
///
/// 资料库的凭据失败总会请求账户复核：复核进行中说“正在重新确认”，结束仍失败时给静态说明（文案在 BiliUI 的
/// `ContentFailureText`）。只把模型的复核进度映射到文案；重试动作由调用方给出，只在错误可重试时提供。
@MainActor
struct LibraryContentFailure {
    /// 模型的 `isAwaitingAuthenticationRevalidation`。
    let isAwaitingRevalidation: Bool
    let locale: Locale

    func message(for error: ContentApplicationError) -> String {
        ContentFailureText.message(for: error, revalidation: revalidation, locale: locale)
    }

    /// 整页失败；没有专属标题的失败用来源的 `fallbackTitle`。
    func view(
        _ error: ContentApplicationError,
        fallbackTitle: String,
        retry: @escaping () -> Void
    ) -> ContentFailureView {
        let text = ContentFailureText(
            error: error,
            fallbackTitle: fallbackTitle,
            revalidation: revalidation,
            locale: locale
        )
        return ContentFailureView(
            title: text.title,
            message: text.message,
            retry: error.isRetryable ? retry : nil
        )
    }

    private var revalidation: ContentFailureText.Revalidation {
        isAwaitingRevalidation ? .awaiting : .finished
    }
}
