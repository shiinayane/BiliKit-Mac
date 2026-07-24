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
            Button("重试", action: retry)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("failure.retry")
        }
    }
}

extension GuestFlowFailure {
    var title: String {
        switch self {
        case let .content(error):
            error.guestTitle
        case .playback:
            "无法准备播放"
        }
    }

    var message: String {
        switch self {
        case let .content(error):
            error.guestMessage
        case .playback:
            "当前媒体轨道或网络响应无法交给系统播放器。"
        }
    }
}

extension GuestApplicationError {
    var guestTitle: String {
        switch self {
        case .requestRestricted, .serviceRejected:
            "请求受到限制"
        case .unsupportedMedia:
            "没有可播放的游客轨道"
        default:
            "无法加载内容"
        }
    }

    var guestMessage: String {
        switch self {
        case .invalidRequest:
            "请求参数无效，请重新选择内容。"
        case .requestRestricted:
            "服务可能返回了风控页，请降低请求频率后重试。"
        case let .serviceRejected(code):
            "服务暂时无法完成请求（代码 \(code)）。"
        case .transportFailure:
            "请检查网络连接后重试。"
        case .unsupportedMedia:
            "该视频在当前游客画质下没有 AVPlayer 可用的 AVC/AAC 轨道。"
        case .invalidResponse:
            "接口数据与当前客户端预期不一致，请稍后重试。"
        case .unavailable:
            "暂时无法完成请求，请稍后重试。"
        }
    }
}
