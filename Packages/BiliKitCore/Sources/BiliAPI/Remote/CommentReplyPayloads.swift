import BiliModels
import BiliNetworking
import Foundation

/// 楼中楼分页接口（`/x/v2/reply/reply`）的 data：页码信息与本页回复。
///
/// 只保留属于请求根评论的回复并按 ID 去重；页码信息不合规时整页失败。
struct CommentReplyListPayload: Decodable, Sendable {
    let page: CommentReplyPagePayload
    let replies: [LossyDecodable<CommentReplyPayload>]
    let upper: CommentUpperPayload?

    private enum CodingKeys: String, CodingKey {
        case page
        case replies
        case upper
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        page = try container.decode(CommentReplyPagePayload.self, forKey: .page)
        replies =
            try container.decodeIfPresent(
                [LossyDecodable<CommentReplyPayload>].self,
                forKey: .replies
            ) ?? []
        upper = container.decodeLossyIfPresent(CommentUpperPayload.self, forKey: .upper)
    }

    func page(
        subject: CommentSubjectIdentity,
        rootID: CommentID
    ) throws -> CommentRemoteReplyPage {
        guard page.number > 0, page.size > 0, page.count >= 0 else {
            throw BiliAPIError.decodingFailed
        }
        let uploaderID = upper.map { String($0.mid) }
        var seen: Set<CommentID> = []
        let models = replies.compactMap(\.value).compactMap { payload -> Comment? in
            guard
                let comment = try? payload.model(
                    subject: subject,
                    uploaderID: uploaderID,
                    adminPinnedID: nil,
                    uploaderPinnedID: nil
                ), comment.rootID == rootID,
                seen.insert(comment.id).inserted
            else { return nil }
            return comment
        }
        return CommentRemoteReplyPage(
            rootID: rootID,
            replies: models,
            pageNumber: page.number,
            pageSize: page.size,
            totalCount: page.count
        )
    }
}

/// 一页楼中楼映射后的结果：所属根评论、回复与页码信息。
struct CommentRemoteReplyPage: Sendable {
    let rootID: CommentID
    let replies: [BiliModels.Comment]
    let pageNumber: Int
    let pageSize: Int
    let totalCount: Int
}

/// 楼中楼的页码、每页条数与回复总数。
struct CommentReplyPagePayload: Decodable, Sendable {
    let number: Int
    let size: Int
    let count: Int

    private enum CodingKeys: String, CodingKey {
        case number = "num"
        case size
        case count
    }
}

/// 「查看对话」接口（`/x/v2/reply/dialog/cursor`）的 data：本页楼层游标、整串对话的楼层范围与本页回复。
///
/// 是否到底只在这里判断一次：接口没有“已到底”字段，原始回复为空、或本页最大楼层追上整串对话的最大楼层时到底；
/// 没到底却缺下一页起点、或起点没有越过本页时整页按解码失败，不悄悄当作到底截断对话。空页可以省略楼层信息。
/// 只保留属于请求根评论的回复并按 ID 去重；明确属于别的对话的行丢弃，缺 `dialog` 的行（已删除、折叠的占位常省略
/// 字段）照样保留，请求本来就按对话查询。
struct CommentDialogListPayload: Decodable, Sendable {
    let cursor: CommentDialogCursorPayload?
    let dialog: CommentDialogRangePayload?
    let replies: [LossyDecodable<CommentReplyPayload>]
    let upper: CommentUpperPayload?

    private enum CodingKeys: String, CodingKey {
        case cursor
        case dialog
        case replies
        case upper
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cursor = try container.decodeIfPresent(CommentDialogCursorPayload.self, forKey: .cursor)
        dialog = try container.decodeIfPresent(CommentDialogRangePayload.self, forKey: .dialog)
        replies =
            try container.decodeIfPresent(
                [LossyDecodable<CommentReplyPayload>].self,
                forKey: .replies
            ) ?? []
        upper = container.decodeLossyIfPresent(CommentUpperPayload.self, forKey: .upper)
    }

    func page(
        subject: CommentSubjectIdentity,
        rootID: CommentID,
        dialogID: CommentID
    ) throws -> CommentRemoteDialogPage {
        let nextFloor = try nextFloor()
        let uploaderID = upper.map { String($0.mid) }
        var seen: Set<CommentID> = []
        let models = replies.compactMap(\.value).compactMap { payload -> Comment? in
            guard
                let comment = try? payload.model(
                    subject: subject,
                    uploaderID: uploaderID,
                    adminPinnedID: nil,
                    uploaderPinnedID: nil
                ), comment.rootID == rootID,
                comment.dialogID == nil || comment.dialogID == dialogID,
                seen.insert(comment.id).inserted
            else { return nil }
            return comment
        }
        return CommentRemoteDialogPage(
            rootID: rootID,
            dialogID: dialogID,
            replies: models,
            nextFloor: nextFloor
        )
    }

    /// 下一页的起点楼层，到底时为 nil。
    private func nextFloor() throws -> Int? {
        guard !replies.isEmpty else { return nil }
        guard let cursor, let dialog, cursor.maxFloor >= 0, dialog.maxFloor >= 0 else {
            throw BiliAPIError.decodingFailed
        }
        guard cursor.maxFloor < dialog.maxFloor else { return nil }
        guard let next = cursor.next, next > cursor.maxFloor else {
            throw BiliAPIError.decodingFailed
        }
        return next
    }
}

/// 一页对话映射后的结果：所属根评论与对话、回复与下一页起点楼层（到底时为 nil）。
struct CommentRemoteDialogPage: Sendable {
    let rootID: CommentID
    let dialogID: CommentID
    let replies: [BiliModels.Comment]
    let nextFloor: Int?
}

/// 「查看对话」本页的楼层游标：本页最大楼层与下一页的起点楼层。
struct CommentDialogCursorPayload: Decodable, Sendable {
    let maxFloor: Int
    let next: Int?

    private enum CodingKeys: String, CodingKey {
        case maxFloor = "max_floor"
        case next
    }
}

/// 整串对话的楼层范围，只用最大楼层判断是否到底。
struct CommentDialogRangePayload: Decodable, Sendable {
    let maxFloor: Int

    private enum CodingKeys: String, CodingKey {
        case maxFloor = "max_floor"
    }
}

/// 单条评论（根评论或回复）的原始字段，映射为 `Comment` 或带预览回复的 `CommentThread`。
///
/// 评论对象（oid／type）与请求不符即失败；不可见、被折叠或状态非 0 的评论映射为不可见占位。
struct CommentReplyPayload: Decodable, Sendable {
    let rpid: Int64?
    let oid: Int64?
    let type: Int?
    let root: Int64?
    let parent: Int64?
    let dialog: Int64?
    let state: Int?
    let ctime: Int64?
    let like: Int64?
    /// 当前账户的表态（0 无、1 已赞、2 已踩）；未登录恒为 0，形状不对按无表态处理。
    let action: Int?
    let rcount: Int?
    let member: CommentMemberPayload?
    let content: CommentContentPayload?
    let replies: [LossyDecodable<CommentReplyPayload>]
    let replyControl: CommentReplyControlPayload?
    let invisible: Bool?
    let folder: CommentFolderPayload?

    private enum CodingKeys: String, CodingKey {
        case rpid
        case oid
        case type
        case root
        case parent
        case dialog
        case state
        case ctime
        case like
        case action
        case rcount
        case member
        case content
        case replies
        case replyControl = "reply_control"
        case invisible
        case folder
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rpid = try container.decodeIfPresent(Int64.self, forKey: .rpid)
        oid = try container.decodeIfPresent(Int64.self, forKey: .oid)
        type = try container.decodeIfPresent(Int.self, forKey: .type)
        root = try container.decodeIfPresent(Int64.self, forKey: .root)
        parent = try container.decodeIfPresent(Int64.self, forKey: .parent)
        dialog = container.decodeLossyIfPresent(Int64.self, forKey: .dialog)
        state = try container.decodeIfPresent(Int.self, forKey: .state)
        ctime = try container.decodeIfPresent(Int64.self, forKey: .ctime)
        like = try container.decodeIfPresent(Int64.self, forKey: .like)
        action = container.decodeLossyIfPresent(Int.self, forKey: .action)
        rcount = try container.decodeIfPresent(Int.self, forKey: .rcount)
        member = container.decodeLossyIfPresent(CommentMemberPayload.self, forKey: .member)
        content = container.decodeLossyIfPresent(CommentContentPayload.self, forKey: .content)
        replies =
            container.decodeLossyIfPresent(
                [LossyDecodable<CommentReplyPayload>].self,
                forKey: .replies
            ) ?? []
        replyControl = container.decodeLossyIfPresent(
            CommentReplyControlPayload.self,
            forKey: .replyControl
        )
        invisible = container.decodeLossyIfPresent(Bool.self, forKey: .invisible)
        folder = container.decodeLossyIfPresent(CommentFolderPayload.self, forKey: .folder)
    }

    func thread(
        subject: CommentSubjectIdentity,
        uploaderID: String?,
        adminPinnedID: Int64?,
        uploaderPinnedID: Int64?
    ) throws -> CommentThread {
        guard root == nil || root == 0, parent == nil || parent == 0 else {
            throw BiliAPIError.decodingFailed
        }
        let root = try model(
            subject: subject,
            uploaderID: uploaderID,
            adminPinnedID: adminPinnedID,
            uploaderPinnedID: uploaderPinnedID
        )
        var seen: Set<CommentID> = []
        let preview: [BiliModels.Comment] = replies.compactMap(\.value).compactMap {
            let reply = try? $0.model(
                subject: subject,
                uploaderID: uploaderID,
                adminPinnedID: nil,
                uploaderPinnedID: nil
            )
            guard let reply, reply.rootID == root.id,
                seen.insert(reply.id).inserted
            else { return nil }
            return reply
        }
        return CommentThread(root: root, replyPreview: Array(preview.prefix(2)))
    }

    func model(
        subject: CommentSubjectIdentity,
        uploaderID: String?,
        adminPinnedID: Int64?,
        uploaderPinnedID: Int64?
    ) throws -> BiliModels.Comment {
        guard let rpid, rpid > 0 else { throw BiliAPIError.decodingFailed }
        guard oid == nil || oid == subject.oid,
            type == nil || type == subject.type
        else { throw BiliAPIError.decodingFailed }
        let id = CommentID(rawValue: rpid)
        if invisible == true || folder?.isFolded == true {
            return BiliModels.Comment(
                id: id,
                rootID: positiveID(root),
                parentID: positiveID(parent),
                dialogID: positiveID(dialog),
                payload: .unavailable(folder?.isFolded == true ? .folded : .unavailable)
            )
        }
        if let state, state != 0 {
            return BiliModels.Comment(
                id: id,
                rootID: positiveID(root),
                parentID: positiveID(parent),
                dialogID: positiveID(dialog),
                payload: .unavailable(.unknown(rawValue: state))
            )
        }
        guard oid == subject.oid, type == subject.type,
            let member, let content, let ctime, ctime >= 0,
            let like, like >= 0, let rcount, rcount >= 0
        else { throw BiliAPIError.decodingFailed }

        var provenance: [CommentProvenance] = []
        if rpid == adminPinnedID { provenance.append(.adminPinned) }
        if rpid == uploaderPinnedID { provenance.append(.uploaderPinned) }
        if replyControl?.upLike == true { provenance.append(.uploaderLiked) }
        return BiliModels.Comment(
            id: id,
            rootID: positiveID(root),
            parentID: positiveID(parent),
            dialogID: positiveID(dialog),
            payload: .available(
                CommentDetails(
                    author: try member.model(uploaderID: uploaderID),
                    content: try content.model(),
                    createdAt: Date(timeIntervalSince1970: TimeInterval(ctime)),
                    location: replyControl?.normalizedLocation,
                    likeCount: like,
                    replyCount: rcount,
                    provenance: provenance,
                    viewerReaction: action == 1 ? .liked : action == 2 ? .disliked : .none
                )
            )
        )
    }

    private func positiveID(_ value: Int64?) -> CommentID? {
        guard let value, value > 0 else { return nil }
        return CommentID(rawValue: value)
    }
}

/// 评论作者：MID、昵称、头像、性别、等级、大会员、认证与硬核会员标记。
struct CommentMemberPayload: Decodable, Sendable {
    let mid: String
    let name: String
    let avatar: String?
    let sex: String?
    let level: CommentLevelPayload?
    let vip: MemberVIPPayload?
    let official: CommentOfficialPayload?
    let isHardcoreMember: Bool

    private enum CodingKeys: String, CodingKey {
        case mid
        case name = "uname"
        case avatar
        case sex
        case level = "level_info"
        case vip
        case official = "official_verify"
        case isHardcoreMember = "is_senior_member"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mid = try container.decodeIntegerText(forKey: .mid)
        name = try container.decode(String.self, forKey: .name)
        avatar = container.decodeLossyIfPresent(String.self, forKey: .avatar)
        sex = container.decodeLossyIfPresent(String.self, forKey: .sex)
        level = container.decodeLossyIfPresent(CommentLevelPayload.self, forKey: .level)
        vip = container.decodeLossyIfPresent(MemberVIPPayload.self, forKey: .vip)
        official = container.decodeLossyIfPresent(CommentOfficialPayload.self, forKey: .official)
        isHardcoreMember = container.decodeLossyBool(forKey: .isHardcoreMember) ?? false
    }

    func model(uploaderID: String?) throws -> CommentAuthor {
        guard !mid.isEmpty, !name.isEmpty else { throw BiliAPIError.decodingFailed }
        let verification: CommentVerification?
        switch official?.type {
        case 0:
            verification = .personal(description: official?.description)
        case 1:
            verification = .organization(description: official?.description)
        default:
            verification = nil
        }
        let authorSex: CommentAuthorSex
        switch sex {
        case "男": authorSex = .male
        case "女": authorSex = .female
        default: authorSex = .unspecified
        }
        return CommentAuthor(
            id: CommentAuthorID(rawValue: mid),
            name: name,
            avatar: commentAvatarReference(avatar),
            sex: authorSex,
            level: level.flatMap {
                (0...6).contains($0.currentLevel) ? $0.currentLevel : nil
            },
            isHardcoreMember: isHardcoreMember,
            isVIP: vip?.isActive == true,
            verification: verification,
            isUploader: mid == uploaderID
        )
    }
}

/// 评论作者与 @ 用户的头像：只接受可解析、不带 userinfo 的图片地址，其余视为没有头像。
func commentAvatarReference(_ value: String?) -> CommentAssetReference? {
    value
        .flatMap(WebImageURL.parse)
        .flatMap { url -> CommentAssetReference? in
            guard url.user == nil, url.password == nil else { return nil }
            return CommentAssetReference(remoteURL: url)
        }
}

/// 作者的当前等级；映射时只接受 0–6。
struct CommentLevelPayload: Decodable, Sendable {
    let currentLevel: Int

    private enum CodingKeys: String, CodingKey {
        case currentLevel = "current_level"
    }
}

/// 作者的认证类型（0 个人、1 机构）与认证说明。
struct CommentOfficialPayload: Decodable, Sendable {
    let type: Int
    let description: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case description = "desc"
    }
}
