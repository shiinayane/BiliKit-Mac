import BiliApplication
import SwiftUI

struct BrowseFailureView: View {
    let title: String
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button(BrowseFeatureStrings.localized("重试"), action: retry)
                .buttonStyle(.borderedProminent)
        }
    }
}

extension GuestVideoFailure {
    public var title: String {
        switch self {
        case .content(let error):
            error.guestTitle
        case .playback:
            BrowseFeatureStrings.localized("无法准备播放")
        }
    }

    public var message: String {
        switch self {
        case .content(let error):
            error.guestMessage
        case .playback:
            BrowseFeatureStrings.localized("当前媒体轨道或网络响应无法交给系统播放器。")
        }
    }
}

extension GuestApplicationError {
    var guestTitle: String {
        switch self {
        case .authenticationInvalid:
            BrowseFeatureStrings.localized("登录状态已失效")
        case .authenticationUnavailable:
            BrowseFeatureStrings.localized("无法读取登录状态")
        case .requestRestricted, .serviceRejected:
            BrowseFeatureStrings.localized("请求受到限制")
        case .unsupportedMedia:
            BrowseFeatureStrings.localized("没有可播放的游客轨道")
        default:
            BrowseFeatureStrings.localized("无法加载内容")
        }
    }

    var guestMessage: String {
        switch self {
        case .invalidRequest:
            BrowseFeatureStrings.localized("请求参数无效，请重新选择内容。")
        case .authenticationInvalid:
            BrowseFeatureStrings.localized("本地登录状态已失效，正在重新确认账户会话。")
        case .authenticationUnavailable:
            BrowseFeatureStrings.localized("无法安全读取本地登录凭据，请稍后重试。")
        case .requestRestricted:
            BrowseFeatureStrings.localized("服务可能返回了风控页，请降低请求频率后重试。")
        case .serviceRejected(let code):
            BrowseFeatureStrings.localized("服务暂时无法完成请求（代码 \(code)）。")
        case .transportFailure:
            BrowseFeatureStrings.localized("请检查网络连接后重试。")
        case .unsupportedMedia:
            BrowseFeatureStrings.localized("该视频在当前服务授权范围内没有 AVPlayer 可用的 AVC/AAC 轨道。")
        case .invalidResponse:
            BrowseFeatureStrings.localized("接口数据与当前客户端预期不一致，请稍后重试。")
        case .unavailable:
            BrowseFeatureStrings.localized("暂时无法完成请求，请稍后重试。")
        }
    }
}
