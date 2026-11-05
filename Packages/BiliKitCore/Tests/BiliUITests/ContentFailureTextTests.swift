import BiliApplication
import Foundation
import Testing

@testable import BiliUI

/// 内容失败在所有页面用同一套标题与说明；只有凭据类失败随账户复核进度变化，没有专属标题的失败用来源自己的标题。
struct ContentFailureTextTests {
    private static let fallbackTitle = "无法加载观看历史"

    struct Expectation: Sendable, CustomTestStringConvertible {
        let error: ContentApplicationError
        /// nil 表示使用调用方的 fallbackTitle。
        let title: String?
        let awaitingTitle: String?
        let unknown: String
        let awaiting: String
        let finished: String

        init(
            _ error: ContentApplicationError,
            title: String?,
            awaitingTitle: String? = nil,
            message: String,
            awaiting: String? = nil,
            finished: String? = nil
        ) {
            self.error = error
            self.title = title
            self.awaitingTitle = awaitingTitle ?? title
            unknown = message
            self.awaiting = awaiting ?? message
            self.finished = finished ?? message
        }

        var testDescription: String { "\(error)" }
    }

    @Test(arguments: [
        Expectation(.invalidRequest, title: nil, message: localized("当前无法完成这次请求。")),
        Expectation(
            .authenticationRequired,
            title: localized("需要登录"),
            awaitingTitle: localized("登录状态已失效"),
            message: localized("该内容需要登录后查看。"),
            awaiting: localized("正在重新确认账户会话。"),
            finished: localized("本机没有可用的登录凭据，请重新扫码登录。")
        ),
        Expectation(
            .authenticationInvalid,
            title: localized("登录状态已失效"),
            message: localized("本地登录状态已失效，正在重新确认账户会话。"),
            awaiting: localized("正在重新确认账户会话。"),
            finished: localized("账户会话仍未恢复，请稍后重试或重新扫码登录。")
        ),
        Expectation(
            .authenticationUnavailable,
            title: localized("无法读取登录状态"),
            message: localized("无法安全读取或确认本地登录状态，请稍后重试。")
        ),
        Expectation(
            .requestRestricted,
            title: localized("请求受到限制"),
            message: localized("服务可能返回了风控页，请降低请求频率后重试。")
        ),
        Expectation(
            .contentUnavailable,
            title: localized("内容不存在或不可见"),
            message: localized("该内容可能已被删除、仍在审核，或只对部分用户可见。")
        ),
        Expectation(
            .serviceRejected(code: -352),
            title: localized("无法完成请求"),
            message: localized("服务暂时无法完成请求（代码 \(-352)）。")
        ),
        Expectation(.transportFailure, title: nil, message: localized("请检查网络连接后重试。")),
        Expectation(
            .unsupportedMedia,
            title: localized("没有可播放的游客轨道"),
            message: localized("该视频在当前服务授权范围内没有 AVPlayer 可用的 AVC/HEVC/AAC 轨道。")
        ),
        Expectation(
            .playbackUnavailable,
            title: nil,
            message: localized("服务没有返回可播放媒体，请稍后重试。")
        ),
        Expectation(
            .fullViewingEntitlementRequired,
            title: localized("当前账户没有完整观看权益"),
            message: localized("当前账户没有完整观看权益。")
        ),
        Expectation(
            .invalidResponse,
            title: nil,
            message: localized("接口数据与当前客户端预期不一致，请稍后重试。")
        ),
        Expectation(.unavailable, title: nil, message: localized("暂时无法完成请求，请稍后重试。"))
    ])
    func everyErrorHasOneWordingPerRevalidationContext(_ expectation: Expectation) {
        let contexts: [(ContentFailureText.Revalidation, String?, String)] = [
            (.unknown, expectation.title, expectation.unknown),
            (.awaiting, expectation.awaitingTitle, expectation.awaiting),
            (.finished, expectation.title, expectation.finished)
        ]
        for (revalidation, title, message) in contexts {
            let text = ContentFailureText(
                error: expectation.error,
                fallbackTitle: Self.fallbackTitle,
                revalidation: revalidation
            )

            #expect(text.title == (title ?? Self.fallbackTitle))
            #expect(text.message == message)
            #expect(
                ContentFailureText.message(for: expectation.error, revalidation: revalidation)
                    == message
            )
        }
    }
}

private func localized(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: BiliUIStrings.bundle)
}
