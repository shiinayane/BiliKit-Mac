import BiliModels
import BiliNetworking
import Foundation

/// 评论正文：文字、表情、接口标出的链接、图片与 @ 成员，映射为 `CommentContent`。
///
/// 图片超过 9 张整条失败；单个表情、链接、图片或成员异常时只丢弃该项。
/// `message` 在解码时就还原 HTML 实体（见 `RemoteHTMLText`），之后的表情、链接与 @ 范围都按还原后的文字计算，
/// 与界面显示的文字一致。
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
        message = RemoteHTMLText.plainText(try container.decode(String.self, forKey: .message))
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
                [LossyDecodable<CommentPicturePayload>].self,
                forKey: .pictures
            ) ?? []
        pictures = lossyPictures.map(\.value)
        pictureCount = lossyPictures.count
        members =
            container.decodeLossyIfPresent(
                [LossyDecodable<CommentMentionPayload>].self,
                forKey: .members
            )?.compactMap(\.value) ?? []
    }

    func model() throws -> CommentContent {
        guard pictureCount <= 9 else {
            throw BiliAPIError.decodingFailed
        }
        let emotes = mappedEmotes()
        let mappedPictures = mappedPictures()
        let jumpLinks = jumpURLs.flatMap { rawLabel, payload -> [CommentLink] in
            // 键是正文里的一段原文；正文已还原实体，键也还原一次才能在正文里定位，键本身没有转义时不受影响。
            let label = RemoteHTMLText.plainText(rawLabel)
            let target: CommentLinkTarget
            let title: String?
            let icon: CommentAssetReference?
            if payload.isWordSearch {
                // 搜的就是正文里看到的这段文字，不取 `pc_url` 里的参数；接口给的标题与图标也不用，看到什么就搜什么
                // （见 SECURITY-MODEL §4）。
                guard let keyword = CommentRemoteLink.searchKeyword(label: label) else { return [] }
                target = .search(keyword: keyword)
                title = nil
                icon = nil
            } else {
                guard let linkTarget = CommentRemoteLink.target(payload.destination(label: label))
                else { return [] }
                target = linkTarget
                title = payload.displayTitle(label: label, target: linkTarget)
                icon = payload.icon
            }
            return ranges(of: label).prefix(payload.matchesOnce ? 1 : .max).map {
                CommentLink(range: $0, target: target, title: title, icon: icon)
            }
        }
        var mentionTargetsByToken: [String: [CommentAuthorID: CommentAuthor]] = [:]
        for member in members where !member.mid.isEmpty && !member.name.isEmpty {
            let token = member.name.hasPrefix("@") ? member.name : "@\(member.name)"
            let id = CommentAuthorID(rawValue: member.mid)
            guard mentionTargetsByToken[token]?[id] == nil else { continue }
            mentionTargetsByToken[token, default: [:]][id] = CommentAuthor(
                id: id,
                name: String(token.dropFirst()),
                avatar: commentAvatarReference(member.avatar)
            )
        }
        let mentionLinks = mentionTargetsByToken.flatMap { token, targets -> [CommentLink] in
            // 接口不给 mention 的正文位置；同名对应多个账号时不能安全猜测目标。
            guard targets.count == 1, let target = targets.values.first else { return [] }
            return ranges(of: token).map {
                CommentLink(range: $0, target: .member(target))
            }
        }
        let markedLinks = Self.nonoverlappingLinks(jumpLinks + mentionLinks)
        let links =
            (markedLinks
            + CommentTextLinkDetector.links(
                in: message,
                excluding: markedLinks.map(\.range) + emotes.map(\.range)
            ))
            .sorted { $0.range.location < $1.range.location }
        return CommentContent(
            message: message,
            emotes: emotes,
            links: links,
            pictures: mappedPictures,
            pictureCount: pictureCount
        )
    }

    /// 按出现位置映射正文图片，同一地址共用一个资源引用。
    ///
    /// 这里只经 `WebImageURL` 规范并拒绝 userinfo；来源规则由 `BiliCommentAssetResolver`
    /// 在解析图片地址时用 `BiliBFSImageURLPolicy` 复核（见 SECURITY-MODEL §4）。
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
}

/// 正文里一个表情记号对应的图片地址、文字与尺寸信息。
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

/// 表情尺寸：1 为普通、2 为大表情，其他值按未知处理。
struct CommentEmoteMetaPayload: Decodable, Sendable {
    let size: Int?
}

/// 评论图片的地址与像素尺寸。
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

/// 正文里 @ 到的用户：MID、昵称与头像。
struct CommentMentionPayload: Decodable, Sendable {
    let mid: String
    let name: String
    let avatar: String?

    private enum CodingKeys: String, CodingKey {
        case mid
        case name = "uname"
        case avatar
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mid = try container.decodeIntegerText(forKey: .mid)
        name = try container.decode(String.self, forKey: .name)
        // 头像只用于空间头部，异常时按没有头像处理，不影响 @ 链接本身。
        avatar = try? container.decodeIfPresent(String.self, forKey: .avatar)
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
