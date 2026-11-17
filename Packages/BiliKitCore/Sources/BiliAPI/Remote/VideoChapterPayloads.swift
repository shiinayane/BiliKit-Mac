import BiliModels
import BiliNetworking
import Foundation

/// 播放器信息（`/x/player/wbi/v2`）里的分段章节 `view_points`。
///
/// 解码失败、起止不合法或没有标题的段跳过；起点相同的只留响应里的第一段（章节以起点区分），再按起点排序。没有这个字段时是
/// 空列表；超过 `maximumChapterCount` 段按响应异常处理，整份当作没有章节。
struct VideoChapterCatalogPayload: Decodable, Sendable {
    /// 章节段数上限：UP 主设置的章节通常几到几十段；每段一张卡片与一个菜单项，超出时不按这份数据铺开界面。
    static let maximumChapterCount = 128

    let viewPoints: [LossyDecodable<VideoChapterPayload>]?

    private enum CodingKeys: String, CodingKey {
        case viewPoints = "view_points"
    }

    func chapters() -> [VideoChapter] {
        let payloads = viewPoints ?? []
        guard payloads.count <= Self.maximumChapterCount else { return [] }
        var seenStarts = Set<Int>()
        let chapters = payloads.compactMap { $0.value?.chapter() }
        let unique = chapters.filter { seenStarts.insert($0.startSeconds).inserted }
        return unique.sorted { $0.startSeconds < $1.startSeconds }
    }
}

/// 分段章节的一段；封面地址按接口图片的公开 HTTPS 规则解析，不合规时这一章只缺封面（见 SECURITY-MODEL §4）。
struct VideoChapterPayload: Decodable, Sendable {
    let from: Int?
    let to: Int?
    let content: String?
    let imgUrl: String?

    func chapter() -> VideoChapter? {
        guard let from, let to, from >= 0, to > from,
            let title = content?.trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty
        else { return nil }
        return VideoChapter(
            startSeconds: from,
            endSeconds: to,
            title: title,
            coverURL: imgUrl.flatMap(WebImageURL.parse)
        )
    }
}
