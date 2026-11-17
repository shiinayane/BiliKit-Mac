import Foundation

/// UP 主设置的一段分段章节：起止秒数、标题与章节封面。
///
/// 只在设置了分段章节的视频里有；按所属分 P（CID）读取，秒数是该分 P 内的位置。
public struct VideoChapter: Sendable, Equatable, Identifiable {
    public let startSeconds: Int
    public let endSeconds: Int
    public let title: String
    public let coverURL: URL?

    public var id: Int { startSeconds }

    public init(startSeconds: Int, endSeconds: Int, title: String, coverURL: URL?) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.title = title
        self.coverURL = coverURL
    }
}
