import BiliUI
import Foundation

/// 人物卡片（关注列表）唯一消费的展示值：头像、名字、一行副标题与两个可选标记。
///
/// Feature 决定副标题取认证说明还是签名，并给出标记的文案；本模块没有字符串目录，所以标记文案由调用方本地化后传入。
/// renderer 不读取 endpoint model，也不推断任何业务状态。
package struct NativePersonCardPresentation: NativeGridCardPresentation {
    /// 卡片 ID：这个人的 MID（十进制）。
    package let id: String
    package let name: String
    /// 头像的请求地址：B 站图片 CDN 的头像缩略图（`BiliImageThumbnail`，与视频卡片头像同一尺寸），不请求原图。
    package let avatarURL: URL?
    /// 名字按大会员配色（`NativeMemberNameColor`）。
    package let isVIP: Bool
    /// 名字下的一行，单行截断；nil 时不显示这一行，名字在卡片里垂直居中。
    ///
    /// 空串按 nil 处理，否则空行仍占位、名字不居中。
    package let subtitle: String?
    /// 「互相关注」角标的文字；nil 时不显示角标。
    package let mutualBadge: String?
    /// 「特别关注」的读屏名称；非 nil 时卡片尾部显示星标。
    package let specialLabel: String?

    /// 人物卡片都能打开空间页。
    package var isActivatable: Bool { true }

    package init(
        id: String,
        name: String,
        avatarURL: URL?,
        isVIP: Bool,
        subtitle: String?,
        mutualBadge: String? = nil,
        specialLabel: String? = nil
    ) {
        self.id = id
        self.name = name
        self.avatarURL = BiliImageThumbnail.url(avatarURL, size: .avatar)
        self.isVIP = isVIP
        self.subtitle = subtitle?.isEmpty == false ? subtitle : nil
        self.mutualBadge = mutualBadge
        self.specialLabel = specialLabel
    }
}

/// 人物卡片：集合项是 `NativePersonCollectionItem`，几何是 `CardGridGeometry.person`。
package enum NativePersonCardKind: NativeGridCardKind {
    package typealias Item = NativePersonCollectionItem

    package static var geometry: CardGridGeometry { .person }
}

extension CardGridGeometry {
    /// 人物卡片网格（关注列表）；卡片高度固定，与宽度无关。
    static let person = CardGridGeometry(
        // 内容边距与列距同视频网格：两种来源切换时内容左缘与列缝对齐。
        contentPadding: CardGridGeometry.video.contentPadding,
        horizontalSpacing: CardGridGeometry.video.horizontalSpacing,
        // 比视频网格的 28 小：人物卡片只有一个头像高，大行距会让列表显得稀疏；调小则相邻卡片的悬停底色几乎相接。
        verticalSpacing: 12,
        // 头像、名字、互关角标与星标排成一行至少要这么宽；调小则名字更早截断，调大则窄窗口更早减列。
        minimumCardWidth: 260,
        // 最少 1 列：一列人物仍然好读，不像视频缩略图那样单列过大，窄窗口可以退到一列。最多 4 列：再多每行的人太多，
        // 扫读时视线横跳。
        minimumColumnCount: 1,
        maximumColumnCount: 4,
        height: { _ in NativePersonCardLayout.height }
    )
}
