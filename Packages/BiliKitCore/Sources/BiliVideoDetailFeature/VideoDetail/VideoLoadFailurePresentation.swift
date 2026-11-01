import BiliApplication
import BiliUI
import Foundation

/// 播放页失败的唯一措辞与重试判断：主区失败视图（`VideoPlaybackView`）与 App 的播放详情区都只读这里。
/// 内容失败交给 BiliUI 的 `ContentFailureText`，播放准备失败用本 Feature 自己的文案。
extension VideoLoadFailure {
    public var isRetryable: Bool {
        switch self {
        case .content(let error):
            error.isRetryable
        case .playback:
            true
        }
    }

    public var title: String {
        switch self {
        case .content(let error):
            error.videoDetailFailureText.title
        case .playback:
            VideoDetailFeatureStrings.localized("无法准备播放")
        }
    }

    public var message: String {
        switch self {
        case .content(let error):
            error.videoDetailFailureText.message
        case .playback:
            VideoDetailFeatureStrings.localized("当前媒体轨道或网络响应无法交给系统播放器。")
        }
    }
}

extension ContentApplicationError {
    /// 播放页不跟踪账户复核进度；没有专属标题的失败统称“无法加载内容”。
    fileprivate var videoDetailFailureText: ContentFailureText {
        ContentFailureText(
            error: self,
            fallbackTitle: VideoDetailFeatureStrings.localized("无法加载内容")
        )
    }
}
