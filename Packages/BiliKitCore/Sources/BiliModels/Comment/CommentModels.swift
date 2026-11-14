import Foundation

/// 评论区所属对象（评论接口的 `type` 与 `oid`），是评论读取 port 的请求键。
///
/// 目前只用视频（`type` 1，`oid` 为 aid）；`BiliAPIClient` 请求前拒绝其他 `type` 与非正 `oid`，
/// 映射时 `oid`／`type` 与之不符的评论按解码失败处理。
public struct CommentSubjectIdentity: Sendable, Equatable, Hashable {
    public let type: Int
    public let oid: Int64

    public static func video(aid: Int64) -> Self {
        Self(type: 1, oid: aid)
    }

    public init(type: Int, oid: Int64) {
        self.type = type
        self.oid = oid
    }
}

/// 根评论列表的排序：`hot` 按热度、`latest` 按时间，请求时分别映射为接口 `mode` 3 与 2。
public enum CommentSort: Sendable, Equatable, Hashable {
    case hot
    case latest
}

/// 评论的 `rpid`；BiliAPI 映射时只接受正数。
public struct CommentID: Sendable, Equatable, Hashable {
    public let rawValue: Int64

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }
}

/// 评论作者或 @ 用户的 MID，按接口给的字符串原样保留。
///
/// 只有 `memberID` 解析出正整数时才可进入空间或生成空间链接。
public struct CommentAuthorID: Sendable, Equatable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// 只由十进制数字组成的正整数 MID；其他形状（含符号、空白、溢出）为 nil。
    ///
    /// 成员外链与评论作者进入空间共用这一判定。
    public var memberID: Int64? {
        Int64(positiveDecimal: rawValue)
    }
}

extension Int64 {
    /// 只由 ASCII 十进制数字组成的正整数；含符号、空白、非 ASCII 数字或溢出时为 nil。
    ///
    /// 评论里的 MID、av 号与分 P 序号共用这一判定。
    package init?(positiveDecimal text: some StringProtocol) {
        guard !text.isEmpty,
            text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
            let value = Int64(text), value > 0
        else { return nil }
        self = value
    }
}

/// 请求评论图片时希望图片缩进的像素框；不带框表示请求原图。
public struct CommentAssetPixelBox: Sendable, Equatable, Hashable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// 评论头像、表情、正文图片与链接图标的进程内不透明引用；远端 URL 只由 BiliAPI 的 adapter
/// 解析和消费。
///
/// 映射时只经 `WebImageURL` 升级为 HTTPS、过公开 HTTPS 基线并拒绝 userinfo，图床来源尚未校验；
/// `BiliCommentAssetResolver` 解析时才执行 `BiliBFSImageURLPolicy`（见 SECURITY-MODEL §4），
/// Feature 不得绕过解析器直接读取 `remoteURL`。
public struct CommentAssetReference: Sendable, Equatable, Hashable {
    package let remoteURL: URL

    package init(remoteURL: URL) {
        self.remoteURL = remoteURL
    }
}

/// 评论与简介里外链和 b23.tv 短链的进程内不透明引用；远端 URL 只由 BiliAPI 的 adapter 读取。
///
/// 映射时 `CommentRemoteLink` 只认带 host、无 userinfo 的 HTTPS 地址；用户点击后外链再经
/// `BiliCommentLinkResolver` 的公开 HTTPS 复核，短链再由 `BiliShortLinkResolver` 收窄为
/// `https://b23.tv/{短码}` 才发请求（见 SECURITY-MODEL §4）。
public struct CommentExternalLinkReference: Sendable, Equatable, Hashable {
    package let remoteURL: URL

    package init(remoteURL: URL) {
        self.remoteURL = remoteURL
    }
}

/// 作者公开的性别；接口值“男”“女”之外（含“保密”与缺失）都是 `unspecified`。
public enum CommentAuthorSex: Sendable, Equatable, Hashable {
    case male
    case female
    case unspecified
}

/// 作者的认证：接口 `official_verify.type` 0 为个人、1 为机构，附认证说明；其他取值不算认证。
public enum CommentVerification: Sendable, Equatable, Hashable {
    case personal(description: String?)
    case organization(description: String?)
}

/// 评论作者或正文里 @ 的用户，由 BiliAPI 的评论与简介映射产生，评论行与空间入口消费。
///
/// @ 用户只有 MID、昵称与头像，其余字段取缺省值；`isUploader` 表示作者 MID 与评论接口给出的 UP 主
/// MID 相同。
public struct CommentAuthor: Sendable, Equatable, Hashable {
    public let id: CommentAuthorID
    public let name: String
    public let avatar: CommentAssetReference?
    public let sex: CommentAuthorSex
    /// 用户等级；映射时只保留 0–6，超出或缺失为 nil。
    public let level: Int?
    public let isHardcoreMember: Bool
    public let isVIP: Bool
    public let verification: CommentVerification?
    public let isUploader: Bool

    public init(
        id: CommentAuthorID,
        name: String,
        avatar: CommentAssetReference? = nil,
        sex: CommentAuthorSex = .unspecified,
        level: Int? = nil,
        isHardcoreMember: Bool = false,
        isVIP: Bool = false,
        verification: CommentVerification? = nil,
        isUploader: Bool = false
    ) {
        self.id = id
        self.name = name
        self.avatar = avatar
        self.sex = sex
        self.level = level
        self.isHardcoreMember = isHardcoreMember
        self.isVIP = isVIP
        self.verification = verification
        self.isUploader = isUploader
    }
}

/// UTF-16 索引范围，与 Foundation attributed string 和远端 span 对齐。
public struct CommentTextRange: Sendable, Equatable, Hashable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

/// 正文里一处表情原文及其图片；同一表情出现多次时每处一条，映射时去掉互相重叠的范围。
public struct CommentEmote: Sendable, Equatable, Hashable {
    public let text: String
    public let range: CommentTextRange
    public let asset: CommentAssetReference
    public let size: CommentEmoteSize

    public init(
        text: String,
        range: CommentTextRange,
        asset: CommentAssetReference,
        size: CommentEmoteSize = .unknown
    ) {
        self.text = text
        self.range = range
        self.asset = asset
        self.size = size
    }
}

/// 表情的显示规格，对应接口 `meta.size` 1 与 2；`unknown` 时评论正文保留表情原文、不换成图片。
public enum CommentEmoteSize: Sendable, Equatable, Hashable {
    case standard
    case large
    case unknown
}

/// 评论正文或视频简介里一段链接的去向，由 BiliAPI 的评论与简介映射分类产生。
///
/// 各去向的分类规则与点击前复核见 SECURITY-MODEL §4「评论与简介外链」「评论与简介短链」。
public enum CommentLinkTarget: Sendable, Equatable, Hashable {
    /// 站内视频；`page` 是链接里的分 P 序号（从 1 开始），`startSeconds` 是链接里的起播秒数（`t=`），
    /// 没有时为 nil。
    case video(bvid: String, page: Int?, startSeconds: Int?)
    /// 正文里的时间戳；在当前视频正在播的分 P 里跳到该秒数。
    case timestamp(seconds: Int)
    /// 正文里 @ 的用户；只填 MID、昵称与头像，进入空间时与评论作者走同一入口。
    case member(CommentAuthor)
    /// 指向 UP 主空间的链接；只有 MID，名字与头像由空间层另行取得。
    case space(memberID: Int64)
    /// b23.tv 短链；点击后才解析出真正的去向，解析失败时按外链打开原短链。
    case shortLink(CommentExternalLinkReference)
    /// 其他 HTTPS 外链；只在用户点击后经公开 HTTPS 复核交给系统打开。
    case external(CommentExternalLinkReference)
}

/// 正文里一段链接：UTF-16 范围与去向，可带接口给的显示标题和前置图标。
public struct CommentLink: Sendable, Equatable, Hashable {
    public let range: CommentTextRange
    public let target: CommentLinkTarget
    /// 接口给的显示标题，有标题时正文里这段原文（多为网址）显示为标题。
    ///
    /// 正文自己识别的链接没有标题。
    public let title: String?
    /// 接口给的前置小图标，显示在链接文字前。
    public let icon: CommentAssetReference?

    public init(
        range: CommentTextRange,
        target: CommentLinkTarget,
        title: String? = nil,
        icon: CommentAssetReference? = nil
    ) {
        self.range = range
        self.target = target
        self.title = title
        self.icon = icon
    }
}

/// 评论正文里的一张图片，由 BiliAPI 的 `CommentContentPayload` 映射产生，评论图片格子与预览消费。
///
/// `position` 是它在接口图片数组里的下标，无法映射的图片在评论行留下空位；宽高只保留正数，
/// 缺失时为 nil。
public struct CommentImage: Sendable, Equatable, Hashable {
    public let asset: CommentAssetReference
    public let position: Int?
    public let pixelWidth: Int?
    public let pixelHeight: Int?

    public init(
        asset: CommentAssetReference,
        position: Int? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) {
        self.asset = asset
        self.position = position
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// 一条评论的正文：原文、表情、链接与图片，由 BiliAPI 的 `CommentContentPayload` 映射产生。
///
/// `links` 按位置排序；表情与链接的范围都是 `message` 的 UTF-16 范围。
public struct CommentContent: Sendable, Equatable {
    public let message: String
    public let emotes: [CommentEmote]
    public let links: [CommentLink]
    public let pictures: [CommentImage]
    /// 接口给出的图片数，含无法映射的项；评论行按它预留格子，BiliAPI 映射时超过 9 张整条失败。
    public let pictureCount: Int

    public init(
        message: String,
        emotes: [CommentEmote] = [],
        links: [CommentLink] = [],
        pictures: [CommentImage] = [],
        pictureCount: Int? = nil
    ) {
        self.message = message
        self.emotes = emotes
        self.links = links
        self.pictures = pictures
        self.pictureCount = pictureCount ?? pictures.count
    }
}

/// 评论只留占位、不展示正文的原因。
///
/// BiliAPI 映射时被折叠为 `folded`，接口标记不可见为 `unavailable`，非零 `state` 原样放进
/// `unknown`。
public enum CommentUnavailableReason: Sendable, Equatable, Hashable {
    case folded
    case unavailable
    case unknown(rawValue: Int)
}

/// 评论的来源标记，评论行据此显示置顶与 UP 主点赞标签；BiliAPI 按根评论页的置顶 ID 与
/// `reply_control.up_like` 映射。
public enum CommentProvenance: Sendable, Equatable, Hashable {
    case adminPinned
    case uploaderPinned
    case uploaderLiked
    /// 当前账户在本窗口刚发出的评论；只由评论 ViewModel 在发出成功后本地加上，接口映射不产生它。
    case postedByViewer
}

/// 当前账户对一条评论的表态：接口 `action` 0 为无、1 为已赞、2 为已踩；未登录时接口恒给 0。
///
/// 赞与踩互斥：服务端点赞会同时取消点踩，反之亦然。
public enum CommentReaction: Sendable, Equatable, Hashable {
    case none
    case liked
    case disliked
}

/// 可见评论的作者、正文、发布时间、IP 属地、计数、来源标记与当前账户的表态；映射时点赞数与回复数只接受非负值。
///
/// 可变的字段只由评论 ViewModel 在本地改写：`likeCount` 与 `viewerReaction` 随乐观点赞、点踩与回滚，`replyCount` 与
/// `provenance` 在插入刚发出的回复时（根评论回复数加一、新评论加上 `.postedByViewer`）；其余字段只来自接口。
public struct CommentDetails: Sendable, Equatable {
    public let author: CommentAuthor
    public let content: CommentContent
    public let createdAt: Date
    public let location: String?
    public var likeCount: Int64
    public var replyCount: Int
    public var provenance: [CommentProvenance]
    public var viewerReaction: CommentReaction

    public init(
        author: CommentAuthor,
        content: CommentContent,
        createdAt: Date,
        location: String? = nil,
        likeCount: Int64,
        replyCount: Int = 0,
        provenance: [CommentProvenance] = [],
        viewerReaction: CommentReaction = .none
    ) {
        self.author = author
        self.content = content
        self.createdAt = createdAt
        self.location = location
        self.likeCount = likeCount
        self.replyCount = replyCount
        self.provenance = provenance
        self.viewerReaction = viewerReaction
    }
}

/// 一条评论要么可展示，要么只剩占位原因；被折叠、不可见或状态异常的评论不携带作者与正文。
public enum CommentPayload: Sendable, Equatable {
    case available(CommentDetails)
    case unavailable(CommentUnavailableReason)
}

/// 根评论列表与楼中楼里的一条评论，由 BiliAPI 的 `CommentReplyPayload` 映射产生。
///
/// `rootID`／`parentID`／`dialogID` 在接口给 0 或缺失时为 nil，根评论三者都为 nil。
///
/// `dialogID` 是这条回复所在对话起头的那条回复：直接回复根评论的回复就是它自己，回复别人的回复沿用被回复者的对话。
public struct Comment: Sendable, Equatable, Identifiable {
    public let id: CommentID
    public let rootID: CommentID?
    public let parentID: CommentID?
    public let dialogID: CommentID?
    /// 乐观表态与本地插入时由评论 ViewModel 改写 `CommentDetails` 的可变字段。
    public var payload: CommentPayload

    public init(
        id: CommentID,
        rootID: CommentID? = nil,
        parentID: CommentID? = nil,
        dialogID: CommentID? = nil,
        payload: CommentPayload
    ) {
        self.id = id
        self.rootID = rootID
        self.parentID = parentID
        self.dialogID = dialogID
        self.payload = payload
    }

    /// 回复的是楼中楼里的另一条回复（而不是根评论），可以查看它所在的那串对话。
    public var isReplyInDialog: Bool {
        guard let rootID, let parentID, let dialogID else { return false }
        return parentID != rootID && dialogID != id
    }
}

/// 根评论与它的楼中楼预览，`id` 取根评论 ID。
///
/// 预览只含属于该根评论的回复，按 ID 去重、至多 2 条；完整楼中楼另经回复分页读取。
public struct CommentThread: Sendable, Equatable, Identifiable {
    public var id: CommentID { root.id }

    public var root: Comment
    public var replyPreview: [Comment]

    public init(root: Comment, replyPreview: [Comment] = []) {
        self.root = root
        self.replyPreview = replyPreview
    }
}
