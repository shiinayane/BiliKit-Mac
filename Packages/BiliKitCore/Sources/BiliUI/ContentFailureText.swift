import BiliApplication
import Foundation

/// `ContentApplicationError` 的唯一失败文案：各 Feature 与 App 的紧凑失败提示都从这里取标题和说明。
///
/// 只拥有措辞；是否给重试由 `ContentApplicationError.isRetryable` 决定，是否复核账户由 App 按
/// `requiresAccountRevalidation` 协调。没有专属标题的错误用调用方传入的 `fallbackTitle`，让每个来源
/// 说出自己加载的是什么。App 只需要单行说明，所以只有 `message(for:revalidation:locale:)` 公开。
public struct ContentFailureText: Sendable, Equatable {
    /// 页面所知的账户复核进度，决定凭据类失败的标题与说明。
    public enum Revalidation: Sendable, Equatable {
        /// 页面不跟踪复核：凭据失效时说明“正在重新确认”，复核由 App 统一发起。
        case unknown
        /// 本页请求的复核尚未结束。
        case awaiting
        /// 复核已结束而本页仍然失败。
        case finished
    }

    package let title: String
    package let message: String

    package init(
        error: ContentApplicationError,
        fallbackTitle: String,
        revalidation: Revalidation = .unknown,
        locale: Locale = .current
    ) {
        title =
            Self.title(for: error, revalidation: revalidation, locale: locale) ?? fallbackTitle
        message = Self.message(for: error, revalidation: revalidation, locale: locale)
    }

    /// 只显示一行说明的紧凑布局用它：说明已经区分风控、凭据失效、凭据读不到与网络。
    public static func message(
        for error: ContentApplicationError,
        revalidation: Revalidation = .unknown,
        locale: Locale = .current
    ) -> String {
        switch error {
        case .invalidRequest:
            BiliUIStrings.localized("当前无法完成这次请求。", locale: locale)
        // 只按账户读取的页面里，本地没有凭据同样说明窗口的登录状态已过期，也会请求复核。
        case .authenticationRequired where revalidation == .awaiting,
            .authenticationInvalid where revalidation == .awaiting:
            BiliUIStrings.localized("正在重新确认账户会话。", locale: locale)
        case .authenticationRequired where revalidation == .finished:
            BiliUIStrings.localized("本机没有可用的登录凭据，请重新扫码登录。", locale: locale)
        case .authenticationRequired:
            BiliUIStrings.localized("该内容需要登录后查看。", locale: locale)
        case .authenticationInvalid where revalidation == .finished:
            BiliUIStrings.localized("账户会话仍未恢复，请稍后重试或重新扫码登录。", locale: locale)
        case .authenticationInvalid:
            BiliUIStrings.localized("本地登录状态已失效，正在重新确认账户会话。", locale: locale)
        // 账户复核失败（网络或 Keychain 不可用）也落到这一态，措辞不能只说读取凭据。
        case .authenticationUnavailable:
            BiliUIStrings.localized("无法安全读取或确认本地登录状态，请稍后重试。", locale: locale)
        case .requestRestricted:
            BiliUIStrings.localized("服务可能返回了风控页，请降低请求频率后重试。", locale: locale)
        case .contentUnavailable:
            BiliUIStrings.localized("该内容可能已被删除、仍在审核，或只对部分用户可见。", locale: locale)
        case .serviceRejected(let code):
            BiliUIStrings.localized("服务暂时无法完成请求（代码 \(code)）。", locale: locale)
        case .transportFailure:
            BiliUIStrings.localized("请检查网络连接后重试。", locale: locale)
        case .unsupportedMedia:
            BiliUIStrings.localized("该视频在当前服务授权范围内没有 AVPlayer 可用的 AVC/HEVC/AAC 轨道。", locale: locale)
        case .fullViewingEntitlementRequired:
            BiliUIStrings.localized("当前账户没有完整观看权益。", locale: locale)
        case .playbackUnavailable:
            BiliUIStrings.localized("服务没有返回可播放媒体，请稍后重试。", locale: locale)
        case .invalidResponse:
            BiliUIStrings.localized("接口数据与当前客户端预期不一致，请稍后重试。", locale: locale)
        case .unavailable:
            BiliUIStrings.localized("暂时无法完成请求，请稍后重试。", locale: locale)
        }
    }

    /// nil 表示这类错误没有专属标题，由调用方的 `fallbackTitle` 说明加载的是什么。
    private static func title(
        for error: ContentApplicationError,
        revalidation: Revalidation,
        locale: Locale
    ) -> String? {
        switch error {
        // 复核进行中说明是“正在重新确认”，标题不能同时说“需要登录”。
        case .authenticationRequired where revalidation == .awaiting, .authenticationInvalid:
            BiliUIStrings.localized("登录状态已失效", locale: locale)
        case .authenticationRequired:
            BiliUIStrings.localized("需要登录", locale: locale)
        case .authenticationUnavailable:
            BiliUIStrings.localized("无法读取登录状态", locale: locale)
        case .requestRestricted:
            BiliUIStrings.localized("请求受到限制", locale: locale)
        case .serviceRejected:
            BiliUIStrings.localized("无法完成请求", locale: locale)
        case .contentUnavailable:
            BiliUIStrings.localized("内容不存在或不可见", locale: locale)
        case .unsupportedMedia:
            BiliUIStrings.localized("没有可播放的游客轨道", locale: locale)
        case .fullViewingEntitlementRequired:
            BiliUIStrings.localized("当前账户没有完整观看权益", locale: locale)
        case .invalidRequest, .transportFailure, .playbackUnavailable, .invalidResponse,
            .unavailable:
            nil
        }
    }
}
