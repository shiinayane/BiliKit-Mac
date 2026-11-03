import BiliApplication
import BiliModels
import BiliUI
import Foundation

/// UP 主名片的读取状态；失败按空名片处理，只隐藏增强信息。
public enum VideoUploaderProfileState: Equatable, Sendable {
    case loading
    case loaded(UploaderProfile)
}

/// UP 主行里名字之下一行附加文字（粉丝与投稿数、签名）的展示形态：加载中占位、没有内容时隐藏，或单行文字。
public enum VideoUploaderLineContent: Equatable, Sendable {
    case loading
    case hidden
    case text(String)
}

/// UP 主行的关注按钮：当前账户是否已关注，以及此刻能否点按（满足写入门槛且读到了关注状态）。
public struct VideoUploaderFollowContent: Equatable, Sendable {
    public let isFollowing: Bool
    public let isEnabled: Bool

    public init(isFollowing: Bool, isEnabled: Bool) {
        self.isFollowing = isFollowing
        self.isEnabled = isEnabled
    }
}

/// 把 UP 主字段规范化为平台 renderer 可直接消费的稳定展示值。
public struct VideoUploaderHeaderContent: Equatable, Sendable {
    public let name: String
    public let avatarURL: URL?
    /// 粉丝数与投稿数，计数用 BiliUI 的紧凑格式；名片没给出两者时隐藏。
    public let stats: VideoUploaderLineContent
    public let signature: VideoUploaderLineContent
    /// 名片加载完成前按非大会员显示。
    public let isVIP: Bool
    /// 名片仍在加载；平台据此在结果到达时把变化做成过渡。
    public let isProfileLoading: Bool
    /// 关注按钮；nil 时不显示（没有 UP 主，或是窗口账户自己的视频）。
    public let follow: VideoUploaderFollowContent?

    public init(
        owner: VideoOwner,
        profileState: VideoUploaderProfileState? = nil,
        follow: VideoUploaderFollowContent? = nil
    ) {
        let normalizedName = UploaderProfileUseCase.singleLine(owner.name)
        name = normalizedName ?? VideoDetailFeatureStrings.localized("未知 UP 主")
        avatarURL = owner.avatarURL
        self.follow = follow
        switch profileState ?? .loaded(UploaderProfile()) {
        case .loading:
            stats = .loading
            signature = .loading
            isVIP = false
            isProfileLoading = true
        case .loaded(let profile):
            isProfileLoading = false
            stats = Self.statsText(profile).map { .text($0) } ?? .hidden
            signature =
                UploaderProfileUseCase.singleLine(profile.signature).map {
                    .text($0)
                } ?? .hidden
            isVIP = profile.isVIP
        }
    }

    /// “12.3万粉丝 · 456 个投稿”；只给出一项时只显示那一项。
    private static func statsText(_ profile: UploaderProfile) -> String? {
        let parts = [
            profile.followerCount.map {
                VideoDetailFeatureStrings.localized(
                    "\(VideoMetadataFormatting.compactCount($0))粉丝"
                )
            },
            profile.videoCount.map { VideoDetailFeatureStrings.localized("\($0) 个投稿") }
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
