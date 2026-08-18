import BiliModels
import Foundation

struct CommentMainPayload: Decodable, Sendable {
    let cursor: CommentCursorPayload
    let replies: [LossyCommentReplyPayload]
    let topReplies: [LossyCommentReplyPayload]
    let top: CommentTopPayload?
    let upper: CommentUpperPayload?

    private enum CodingKeys: String, CodingKey {
        case cursor
        case replies
        case topReplies = "top_replies"
        case top
        case upper
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cursor = try container.decode(CommentCursorPayload.self, forKey: .cursor)
        replies =
            try container.decodeIfPresent(
                [LossyCommentReplyPayload].self,
                forKey: .replies
            ) ?? []
        topReplies =
            container.decodeLossyIfPresent(
                [LossyCommentReplyPayload].self,
                forKey: .topReplies
            ) ?? []
        top = container.decodeLossyIfPresent(CommentTopPayload.self, forKey: .top)
        upper = container.decodeLossyIfPresent(CommentUpperPayload.self, forKey: .upper)
    }

    func page(for subject: CommentSubjectIdentity) throws -> CommentRemoteRootPage {
        let uploaderID = upper.map { String($0.mid) }
        let adminPinnedID = top?.admin?.value?.rpid
        let uploaderPinnedID = top?.upper?.value?.rpid
        let pinnedReplies = [top?.admin?.value, top?.upper?.value].compactMap { $0 }
        let candidates =
            pinnedReplies
            + topReplies.compactMap(\.value)
            + replies.compactMap(\.value)
        var seen: Set<CommentID> = []
        var threads: [CommentThread] = []
        for payload in candidates {
            guard
                let thread = try? payload.thread(
                    subject: subject,
                    uploaderID: uploaderID,
                    adminPinnedID: adminPinnedID,
                    uploaderPinnedID: uploaderPinnedID
                ), seen.insert(thread.id).inserted
            else { continue }
            threads.append(thread)
        }

        let nextOffset = cursor.paginationReply?.nextOffset
        if !cursor.isEnd, nextOffset?.isEmpty != false {
            throw BiliAPIError.decodingFailed
        }
        return CommentRemoteRootPage(
            threads: threads,
            totalCount: max(cursor.allCount, threads.count),
            nextOffset: cursor.isEnd ? nil : nextOffset,
            isEnd: cursor.isEnd
        )
    }
}

struct CommentReplyListPayload: Decodable, Sendable {
    let page: CommentReplyPagePayload
    let replies: [LossyCommentReplyPayload]
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
                [LossyCommentReplyPayload].self,
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

struct CommentRemoteRootPage: Sendable {
    let threads: [CommentThread]
    let totalCount: Int
    let nextOffset: String?
    let isEnd: Bool
}

struct CommentRemoteReplyPage: Sendable {
    let rootID: CommentID
    let replies: [BiliModels.Comment]
    let pageNumber: Int
    let pageSize: Int
    let totalCount: Int
}

struct CommentCursorPayload: Decodable, Sendable {
    let allCount: Int
    let isEnd: Bool
    let paginationReply: CommentPaginationReplyPayload?

    private enum CodingKeys: String, CodingKey {
        case allCount = "all_count"
        case isEnd = "is_end"
        case paginationReply = "pagination_reply"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allCount = try container.decode(Int.self, forKey: .allCount)
        isEnd = try container.decode(Bool.self, forKey: .isEnd)
        paginationReply = container.decodeLossyIfPresent(
            CommentPaginationReplyPayload.self,
            forKey: .paginationReply
        )
    }
}

struct CommentPaginationReplyPayload: Decodable, Sendable {
    let nextOffset: String

    private enum CodingKeys: String, CodingKey {
        case nextOffset = "next_offset"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode(String.self, forKey: .nextOffset) {
            nextOffset = value
        } else {
            nextOffset = String(try container.decode(Int64.self, forKey: .nextOffset))
        }
    }
}

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

struct CommentUpperPayload: Decodable, Sendable {
    let mid: Int64
}

struct CommentTopPayload: Decodable, Sendable {
    let admin: LossyCommentReplyPayload?
    let upper: LossyCommentReplyPayload?
}

struct LossyCommentReplyPayload: Decodable, Sendable {
    let value: CommentReplyPayload?

    init(from decoder: any Decoder) throws {
        value = try? CommentReplyPayload(from: decoder)
    }
}

struct CommentReplyPayload: Decodable, Sendable {
    let rpid: Int64?
    let oid: Int64?
    let type: Int?
    let root: Int64?
    let parent: Int64?
    let state: Int?
    let ctime: Int64?
    let like: Int64?
    let rcount: Int?
    let member: CommentMemberPayload?
    let content: CommentContentPayload?
    let replies: [LossyCommentReplyPayload]
    let replyControl: CommentReplyControlPayload?
    let invisible: Bool?
    let folder: CommentFolderPayload?

    private enum CodingKeys: String, CodingKey {
        case rpid
        case oid
        case type
        case root
        case parent
        case state
        case ctime
        case like
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
        state = try container.decodeIfPresent(Int.self, forKey: .state)
        ctime = try container.decodeIfPresent(Int64.self, forKey: .ctime)
        like = try container.decodeIfPresent(Int64.self, forKey: .like)
        rcount = try container.decodeIfPresent(Int.self, forKey: .rcount)
        member = container.decodeLossyIfPresent(CommentMemberPayload.self, forKey: .member)
        content = container.decodeLossyIfPresent(CommentContentPayload.self, forKey: .content)
        replies =
            container.decodeLossyIfPresent(
                [LossyCommentReplyPayload].self,
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
                payload: .unavailable(folder?.isFolded == true ? .folded : .unavailable)
            )
        }
        if let state, state != 0 {
            return BiliModels.Comment(
                id: id,
                rootID: positiveID(root),
                parentID: positiveID(parent),
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
            payload: .available(
                CommentDetails(
                    author: try member.model(uploaderID: uploaderID),
                    content: try content.model(),
                    createdAt: Date(timeIntervalSince1970: TimeInterval(ctime)),
                    location: replyControl?.normalizedLocation,
                    likeCount: like,
                    replyCount: rcount,
                    provenance: provenance
                )
            )
        )
    }

    private func positiveID(_ value: Int64?) -> CommentID? {
        guard let value, value > 0 else { return nil }
        return CommentID(rawValue: value)
    }
}

struct CommentMemberPayload: Decodable, Sendable {
    let mid: String
    let name: String
    let avatar: String?
    let sex: String?
    let level: CommentLevelPayload?
    let vip: CommentVIPPayload?
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
        if let value = try? container.decode(String.self, forKey: .mid) {
            mid = value
        } else {
            mid = String(try container.decode(Int64.self, forKey: .mid))
        }
        name = try container.decode(String.self, forKey: .name)
        avatar = container.decodeLossyIfPresent(String.self, forKey: .avatar)
        sex = container.decodeLossyIfPresent(String.self, forKey: .sex)
        level = container.decodeLossyIfPresent(CommentLevelPayload.self, forKey: .level)
        vip = container.decodeLossyIfPresent(CommentVIPPayload.self, forKey: .vip)
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
        let avatarReference =
            avatar
            .flatMap(WebImageURL.parse)
            .flatMap { url -> CommentAssetReference? in
                guard url.user == nil, url.password == nil else { return nil }
                return CommentAssetReference(remoteURL: url)
            }

        return CommentAuthor(
            id: CommentAuthorID(rawValue: mid),
            name: name,
            avatar: avatarReference,
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

struct CommentLevelPayload: Decodable, Sendable {
    let currentLevel: Int

    private enum CodingKeys: String, CodingKey {
        case currentLevel = "current_level"
    }
}

struct CommentVIPPayload: Decodable, Sendable {
    let type: Int?
    let status: Int?

    var isActive: Bool { status == 1 }

    private enum CodingKeys: String, CodingKey {
        case type = "vipType"
        case status = "vipStatus"
    }
}

struct CommentOfficialPayload: Decodable, Sendable {
    let type: Int
    let description: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case description = "desc"
    }
}

struct CommentContentPayload: Decodable, Sendable {
    let message: String
    let emote: [String: CommentEmotePayload]
    let jumpURLs: [String: CommentJumpURLPayload]
    let pictures: [CommentPicturePayload?]
    let pictureCount: Int
    let members: [CommentMentionPayload]

    private enum CodingKeys: String, CodingKey {
        case message
        case emote
        case jumpURLs = "jump_url"
        case pictures
        case members
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decode(String.self, forKey: .message)
        emote =
            container.decodeLossyIfPresent(
                LossyStringDictionary<CommentEmotePayload>.self,
                forKey: .emote
            )?.values ?? [:]
        jumpURLs =
            container.decodeLossyIfPresent(
                LossyStringDictionary<CommentJumpURLPayload>.self,
                forKey: .jumpURLs
            )?.values ?? [:]
        let lossyPictures =
            container.decodeLossyIfPresent(
                [LossyCommentPicturePayload].self,
                forKey: .pictures
            ) ?? []
        pictures = lossyPictures.map(\.value)
        pictureCount = lossyPictures.count
        members =
            container.decodeLossyIfPresent(
                [LossyCommentMentionPayload].self,
                forKey: .members
            )?.compactMap(\.value) ?? []
    }

    func model() throws -> CommentContent {
        guard pictureCount <= 9 else {
            throw BiliAPIError.decodingFailed
        }
        let emotes = mappedEmotes()
        let mappedPictures = mappedPictures()
        let jumpLinks = jumpURLs.flatMap { label, payload -> [CommentLink] in
            guard let target = CommentRemoteURL.linkTarget(payload.url) else { return [] }
            return ranges(of: label).map { CommentLink(range: $0, target: target) }
        }
        var mentionTargetsByToken: [String: Set<CommentAuthorID>] = [:]
        for member in members where !member.mid.isEmpty && !member.name.isEmpty {
            let token = member.name.hasPrefix("@") ? member.name : "@\(member.name)"
            mentionTargetsByToken[token, default: []].insert(
                CommentAuthorID(rawValue: member.mid)
            )
        }
        let mentionLinks = mentionTargetsByToken.flatMap { token, targets -> [CommentLink] in
            // 接口不给 mention 的正文位置；同名对应多个账号时不能安全猜测目标。
            guard targets.count == 1, let target = targets.first else { return [] }
            return ranges(of: token).map {
                CommentLink(range: $0, target: .member(target))
            }
        }
        let links = Self.nonoverlappingLinks(jumpLinks + mentionLinks)
        return CommentContent(
            message: message,
            emotes: emotes,
            links: links,
            pictures: mappedPictures,
            pictureCount: pictureCount
        )
    }

    private func mappedPictures() -> [CommentImage] {
        var assetByURL: [URL: CommentAssetReference] = [:]
        return pictures.enumerated().compactMap { position, payload in
            guard let payload else { return nil }
            guard let url = WebImageURL.parse(payload.url),
                url.user == nil,
                url.password == nil
            else { return nil }
            let asset = assetByURL[url] ?? CommentAssetReference(remoteURL: url)
            assetByURL[url] = asset
            return CommentImage(
                asset: asset,
                position: position,
                pixelWidth: Self.positiveDimension(payload.width),
                pixelHeight: Self.positiveDimension(payload.height)
            )
        }
    }

    private static func positiveDimension(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private func mappedEmotes() -> [CommentEmote] {
        var assetByURL: [URL: CommentAssetReference] = [:]
        var result: [CommentEmote] = []

        for (token, payload) in emote {
            guard !token.isEmpty,
                payload.text == nil || payload.text == token,
                let url = WebImageURL.parse(payload.url),
                url.user == nil,
                url.password == nil
            else { continue }

            let asset = assetByURL[url] ?? CommentAssetReference(remoteURL: url)
            assetByURL[url] = asset
            let size: CommentEmoteSize =
                switch payload.meta?.size {
                case 1: .standard
                case 2: .large
                default: .unknown
                }
            result.append(
                contentsOf: ranges(of: token).map {
                    CommentEmote(
                        text: token,
                        range: $0,
                        asset: asset,
                        size: size
                    )
                }
            )
        }

        let sorted = result.sorted {
            if $0.range.location != $1.range.location {
                return $0.range.location < $1.range.location
            }
            if $0.range.length != $1.range.length {
                return $0.range.length > $1.range.length
            }
            return $0.text < $1.text
        }
        var nonoverlapping: [CommentEmote] = []
        for candidate in sorted {
            guard let previous = nonoverlapping.last else {
                nonoverlapping.append(candidate)
                continue
            }
            guard candidate.range.location >= previous.range.location + previous.range.length
            else { continue }
            nonoverlapping.append(candidate)
        }
        return nonoverlapping
    }

    private func ranges(of token: String) -> [CommentTextRange] {
        guard !token.isEmpty else { return [] }
        let source = message as NSString
        var searchRange = NSRange(location: 0, length: source.length)
        var result: [CommentTextRange] = []
        while searchRange.length > 0 {
            let range = source.range(of: token, options: [], range: searchRange)
            guard range.location != NSNotFound else { break }
            result.append(CommentTextRange(location: range.location, length: range.length))
            let next = NSMaxRange(range)
            searchRange = NSRange(location: next, length: source.length - next)
        }
        return result
    }

    private static func nonoverlappingLinks(_ links: [CommentLink]) -> [CommentLink] {
        let sorted = links.sorted {
            if $0.range.location != $1.range.location {
                return $0.range.location < $1.range.location
            }
            if $0.range.length != $1.range.length {
                return $0.range.length > $1.range.length
            }
            return linkOrderKey($0.target) < linkOrderKey($1.target)
        }
        var result: [CommentLink] = []
        for link in sorted {
            guard let previous = result.last else {
                result.append(link)
                continue
            }
            guard link.range.location >= previous.range.location + previous.range.length
            else { continue }
            result.append(link)
        }
        return result
    }

    private static func linkOrderKey(_ target: CommentLinkTarget) -> String {
        switch target {
        case .video(let bvid):
            "0:\(bvid)"
        case .member(let authorID):
            "1:\(authorID.rawValue)"
        case .external(let reference):
            "2:\(reference.remoteURL?.absoluteString ?? "")"
        }
    }
}

struct CommentEmotePayload: Decodable, Sendable {
    let url: String
    let text: String?
    let meta: CommentEmoteMetaPayload?

    private enum CodingKeys: String, CodingKey {
        case url
        case text
        case meta
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        text = container.decodeLossyIfPresent(String.self, forKey: .text)
        meta = container.decodeLossyIfPresent(CommentEmoteMetaPayload.self, forKey: .meta)
    }
}

struct CommentEmoteMetaPayload: Decodable, Sendable {
    let size: Int?
}

struct CommentJumpURLPayload: Decodable, Sendable {
    let pcURL: String?
    let appURL: String?

    var url: String? { pcURL ?? appURL }

    private enum CodingKeys: String, CodingKey {
        case pcURL = "pc_url"
        case appURL = "app_url"
    }
}

struct CommentPicturePayload: Decodable, Sendable {
    let url: String
    let width: Int?
    let height: Int?

    private enum CodingKeys: String, CodingKey {
        case url = "img_src"
        case width = "img_width"
        case height = "img_height"
    }
}

struct CommentMentionPayload: Decodable, Sendable {
    let mid: String
    let name: String

    private enum CodingKeys: String, CodingKey {
        case mid
        case name = "uname"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode(String.self, forKey: .mid) {
            mid = value
        } else {
            mid = String(try container.decode(Int64.self, forKey: .mid))
        }
        name = try container.decode(String.self, forKey: .name)
    }
}

struct CommentReplyControlPayload: Decodable, Sendable {
    let location: String?
    let upLike: Bool?

    var normalizedLocation: String? {
        guard let location else { return nil }
        return
            location
            .replacingOccurrences(of: "IP属地：", with: "")
            .replacingOccurrences(of: "IP属地:", with: "")
    }

    private enum CodingKeys: String, CodingKey {
        case location
        case upLike = "up_like"
    }
}

struct CommentFolderPayload: Decodable, Sendable {
    let isFolded: Bool?

    private enum CodingKeys: String, CodingKey {
        case isFolded = "is_folded"
    }
}

private enum CommentRemoteURL {
    static func linkTarget(_ value: String?) -> CommentLinkTarget? {
        guard let components = components(value), let host = components.host?.lowercased()
        else { return nil }
        let parts = components.path.split(separator: "/")
        if host == "www.bilibili.com", parts.count >= 2,
            parts[0] == "video", BiliAPIClient.isValidBVID(String(parts[1]))
        {
            return .video(bvid: String(parts[1]))
        }
        guard let url = components.url else { return nil }
        return .external(CommentExternalLinkReference(remoteURL: url))
    }

    private static func components(_ value: String?) -> URLComponents? {
        guard var value, !value.isEmpty else { return nil }
        if value.hasPrefix("//") { value = "https:\(value)" }
        guard let components = URLComponents(string: value),
            components.scheme?.lowercased() == "https",
            components.host != nil,
            components.user == nil,
            components.password == nil
        else { return nil }
        return components
    }
}

private struct LossyStringDictionary<Value>: Decodable, Sendable
where Value: Decodable & Sendable {
    let values: [String: Value]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var values: [String: Value] = [:]
        for key in container.allKeys {
            if let value = try? container.decode(Value.self, forKey: key) {
                values[key.stringValue] = value
            }
        }
        self.values = values
    }
}

private struct LossyCommentPicturePayload: Decodable, Sendable {
    let value: CommentPicturePayload?

    init(from decoder: any Decoder) throws {
        value = try? CommentPicturePayload(from: decoder)
    }
}

private struct LossyCommentMentionPayload: Decodable, Sendable {
    let value: CommentMentionPayload?

    init(from decoder: any Decoder) throws {
        value = try? CommentMentionPayload(from: decoder)
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

extension KeyedDecodingContainer {
    fileprivate func decodeLossyIfPresent<Value: Decodable>(
        _ type: Value.Type,
        forKey key: Key
    ) -> Value? {
        try? decodeIfPresent(type, forKey: key)
    }

    fileprivate func decodeLossyBool(forKey key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            switch value {
            case 0: return false
            case 1: return true
            default: return nil
            }
        }
        return nil
    }
}
