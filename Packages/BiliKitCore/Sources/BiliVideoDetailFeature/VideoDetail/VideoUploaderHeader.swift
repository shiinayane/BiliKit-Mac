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

/// 关注按钮（播放页侧栏的 AppKit 按钮、整页空间页头部的 SwiftUI 按钮）的标题、图标与读屏值，两处共用这一份。
///
/// 标题说明现状：「关注」前是加号，「已关注」前是三条横线（点开是菜单）；读屏标签固定为「关注」，值说明是否已关注。
enum UploaderFollowButtonLabel {
    static var accessibilityLabel: String { VideoDetailFeatureStrings.localized("关注") }

    static func title(isFollowing: Bool) -> String {
        isFollowing
            ? VideoDetailFeatureStrings.localized("已关注")
            : VideoDetailFeatureStrings.localized("关注")
    }

    static func systemImage(isFollowing: Bool) -> String {
        isFollowing ? "line.3.horizontal" : "plus"
    }

    static func accessibilityValue(isFollowing: Bool) -> String {
        isFollowing
            ? VideoDetailFeatureStrings.localized("已关注")
            : VideoDetailFeatureStrings.localized("未关注")
    }
}

/// UP 主头像的显示档：决定请求的缩略尺寸与取图用途。
///
/// 两者由同一档给出，不会出现请求大图却按小头像的上限解码（或反过来）。
public enum VideoUploaderAvatarSize: Equatable, Sendable {
    /// 播放侧栏 UP 主名片（48pt）。
    case regular
    /// 整页空间页头部（72pt）。
    case large

    var thumbnail: BiliImageThumbnail.Size {
        switch self {
        case .regular: .avatar
        case .large: .largeAvatar
        }
    }

    var purpose: VideoDetailImagePurpose {
        switch self {
        case .regular: .avatar
        case .large: .largeAvatar
        }
    }
}

/// 把 UP 主字段规范化为平台 renderer 可直接消费的稳定展示值。
public struct VideoUploaderHeaderContent: Equatable, Sendable {
    public let name: String
    /// 头像的请求地址：按 `avatarSize` 取的 B 站图片 CDN 头像缩略图（`BiliImageThumbnail`），不请求原图。
    public let avatarURL: URL?
    /// 加载 `avatarURL` 时用的取图用途，与请求的缩略尺寸成对。
    public let avatarPurpose: VideoDetailImagePurpose
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
        follow: VideoUploaderFollowContent? = nil,
        avatarSize: VideoUploaderAvatarSize = .regular
    ) {
        let normalizedName = UploaderProfileUseCase.singleLine(owner.name)
        name = normalizedName ?? VideoDetailFeatureStrings.localized("未知 UP 主")
        avatarURL = BiliImageThumbnail.url(owner.avatarURL, size: avatarSize.thumbnail)
        avatarPurpose = avatarSize.purpose
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
