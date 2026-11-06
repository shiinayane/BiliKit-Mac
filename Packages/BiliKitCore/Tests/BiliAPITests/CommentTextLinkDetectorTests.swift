import BiliModels
import Foundation
import Testing

@testable import BiliAPI

/// 固定评论正文自识别：纯文字里的视频网址、BV／av 号、b23.tv 短链与时间戳成为链接，句读、不成对括号、
/// 表情与中文不算进网址，嵌在单词里或通不过 HTTPS 复核的不识别，接口已标出的范围优先，范围按 UTF-16 计算。
@Suite("Comment text link detector")
struct CommentTextLinkDetectorTests {
    private func detected(_ message: String) -> [(text: String, target: CommentLinkTarget)] {
        let source = message as NSString
        return CommentTextLinkDetector.links(in: message, excluding: []).map {
            (
                source.substring(
                    with: NSRange(location: $0.range.location, length: $0.range.length)
                ),
                $0.target
            )
        }
    }

    /// 纯文字的视频网址、BV 号与 av 号都在应用内播放；紧邻的中文与全角标点不算进链接。
    @Test
    func videoReferencesInPlainTextOpenInApp() {
        let links = detected(
            "看这个BV1xx411c7mD，还有av170001和https://www.bilibili.com/video/BV17x411w7KC?p=2。"
        )

        #expect(
            links.map(\.text) == [
                "BV1xx411c7mD", "av170001", "https://www.bilibili.com/video/BV17x411w7KC?p=2"
            ]
        )
        #expect(
            links.map(\.target) == [
                .video(bvid: "BV1xx411c7mD", page: nil, startSeconds: nil),
                .video(bvid: "BV17x411w7KC", page: nil, startSeconds: nil),
                .video(bvid: "BV17x411w7KC", page: 2, startSeconds: nil)
            ]
        )
    }

    /// 带协议头与不带协议头的 b23.tv 都识别为短链（实测评论里的写法是 `https://b23.tv/…（中文`）。
    @Test
    func shortLinksInPlainTextAreResolvedOnClick() {
        let links = detected("韩语版 https://b23.tv/Jf3cvv2（助力） 和 b23.tv/AbCd123。")

        #expect(links.map(\.text) == ["https://b23.tv/Jf3cvv2", "b23.tv/AbCd123"])
        for link in links {
            guard case .shortLink = link.target else {
                Issue.record("\(link.text) 应识别为短链")
                continue
            }
        }
    }

    /// 网址末尾的句读与不成对的括号不算进网址；成对的括号保留。
    @Test(
        arguments: [
            ("见 https://example.com/a.", "https://example.com/a"),
            ("(https://example.com/a)", "https://example.com/a"),
            ("https://example.com/wiki/A_(B)!", "https://example.com/wiki/A_(B)"),
            ("链接：https://example.com/a?x=1&y=2，完", "https://example.com/a?x=1&y=2")
        ]
    )
    func trailingPunctuationIsNotPartOfTheURL(message: String, url: String) {
        let links = detected(message)

        #expect(links.map(\.text) == [url])
        guard case .external(let reference)? = links.first?.target else {
            Issue.record("公开 HTTPS 外链应保持为外链")
            return
        }
        #expect(reference.remoteURL.absoluteString == url)
    }

    /// `http` 网址只在指向站内目标时升级；其余 `http` 与通不过公开 HTTPS 复核的地址不显示为链接。
    @Test
    func insecureOrUnsafeAddressesStayPlainText() {
        let links = detected(
            "http://www.bilibili.com/video/BV1xx411c7mD http://example.com/a https://127.0.0.1/a https://localhost/a"
        )

        #expect(links.map(\.text) == ["http://www.bilibili.com/video/BV1xx411c7mD"])
        #expect(links.first?.target == .video(bvid: "BV1xx411c7mD", page: nil, startSeconds: nil))
    }

    /// 嵌在别的单词或标记里的不识别：前后紧挨字母或数字、不合法的 av 号、网址里的 BV 号不重复识别。
    @Test(
        arguments: [
            "xBV1xx411c7mD",
            "BV1xx411c7mDx",
            "BV1xx411c7m",
            "nav123",
            "av0",
            "av123x",
            "javahttps://example.com",
            "AV1编码",
            "Av8",
            "av1234",
            "user@b23.tv/AbCd123",
            "xhttps://example.com",
            "example.com/b23.tv/AbCd123",
            "b23.tv/"
        ]
    )
    func embeddedOrMalformedTokensStayPlainText(message: String) {
        #expect(detected(message).isEmpty)
    }

    /// 网址后紧跟表情（评论里最常见的写法）：表情不算进网址。
    @Test(arguments: ["https://b23.tv/AbCd123[doge]", "https://b23.tv/AbCd123[笑哭]"])
    func emotesRightAfterAURLAreNotPartOfIt(message: String) {
        let links = detected(message)

        #expect(links.map(\.text) == ["https://b23.tv/AbCd123"])
        guard case .shortLink? = links.first?.target else {
            Issue.record("表情前的短链应识别为短链")
            return
        }
    }

    /// 不能成为链接的网址整段占位，里面的视频号或短链不会被单独标成链接。
    @Test(
        arguments: [
            "http://example.com/video/av170001",
            "https://127.0.0.1/BV1xx411c7mD",
            "http://example.com/?u=b23.tv/AbCd123"
        ]
    )
    func idsInsideRejectedURLsStayPlainText(message: String) {
        #expect(detected(message).isEmpty)
    }

    @Test(arguments: ["B23.TV/AbCd123", "HTTPS://b23.tv/AbCd123"])
    func shortLinksAreCaseInsensitiveInTheHost(message: String) {
        guard case .shortLink? = detected(message).first?.target else {
            Issue.record("\(message) 应识别为短链")
            return
        }
    }

    /// 原样中文路径在中文处截断：紧跟中文的网址写法更常见，取舍在这里固定。
    @Test
    func rawChinesePathEndsTheURL() {
        #expect(
            detected("https://example.com/wiki/哔哩哔哩").map(\.text) == ["https://example.com/wiki/"]
        )
    }

    /// 时间戳：`m:ss`（分钟最多 3 位）与 `h:mm:ss`，分隔符半角、全角冒号都认，后面紧跟字母或中文照常识别；
    /// 是否超出视频时长到显示时再判断。
    @Test
    func timestampsInPlainText() {
        let links = detected(
            "1:23 处，还有 01:02:03 和 120:00，以及（12:34）、2：05、1：02：03、3:45s、4:56this"
        )

        #expect(
            links.map(\.text) == [
                "1:23", "01:02:03", "120:00", "12:34", "2：05", "1：02：03", "3:45", "4:56"
            ]
        )
        #expect(
            links.map(\.target) == [
                .timestamp(seconds: 83),
                .timestamp(seconds: 3_723),
                .timestamp(seconds: 7_200),
                .timestamp(seconds: 754),
                .timestamp(seconds: 125),
                .timestamp(seconds: 3_723),
                .timestamp(seconds: 225),
                .timestamp(seconds: 296)
            ]
        )
    }

    /// 不是时间的写法不识别：秒不是两位或不小于 60、比例、更长的数字串、前面紧挨字母、全角数字、网址里的时间。
    @Test(
        arguments: [
            "1:2",
            "1:60",
            "3:2",
            "16:9",
            "1234:56",
            "12:34:56:78",
            "1:60:00",
            "１：２３",
            "p1:23",
            "x264:10",
            "12：34：56：78",
            "p1：23",
            "https://example.com/a?at=10:30"
        ]
    )
    func nonTimestampsStayPlainText(message: String) {
        #expect(
            !detected(message).contains { link in
                if case .timestamp = link.target { return true }
                return false
            }
        )
    }

    /// 接口已标出的链接（jump_url、@ 提及）覆盖的文字不再识别；范围按 UTF-16 计算。
    @Test
    func markedLinksWinAndRangesAreUTF16() throws {
        let message = "😀BV1xx411c7mD av170001"
        let marked = CommentLink(
            range: CommentTextRange(location: 2, length: 12),
            target: .video(bvid: "BV1xx411c7mD", page: 1, startSeconds: nil)
        )

        let links = CommentTextLinkDetector.links(in: message, excluding: [marked.range])

        #expect(links.map(\.range) == [CommentTextRange(location: 15, length: 8)])
        #expect(links.map(\.target) == [.video(bvid: "BV17x411w7KC", page: nil, startSeconds: nil)])
    }

    /// 接入评论正文映射：识别结果与 jump_url 链接合并，按出现位置排序。
    @Test
    func contentMappingMergesDetectedLinksInOrder() throws {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "message": "av170001 网页 BV17x411w7KC",
                "jump_url": ["网页": ["pc_url": "https://www.bilibili.com/opus/42"]]
            ]
        )
        let payload = try JSONDecoder().decode(CommentContentPayload.self, from: data)

        let links = try payload.model().links

        #expect(
            links.map(\.range) == [
                CommentTextRange(location: 0, length: 8),
                CommentTextRange(location: 9, length: 2),
                CommentTextRange(location: 12, length: 12)
            ]
        )
        #expect(links.first?.target == .video(bvid: "BV17x411w7KC", page: nil, startSeconds: nil))
        #expect(links.last?.target == .video(bvid: "BV17x411w7KC", page: nil, startSeconds: nil))
    }
}
