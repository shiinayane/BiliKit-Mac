import BiliModels
import Foundation
import Testing

@testable import BiliAPI

/// 固定评论正文自识别：纯文字里的视频网址、BV／av 号、b23.tv 短链与时间戳成为链接，句读、不成对括号、
/// 表情与中文不算进网址，嵌在单词里或通不过 HTTPS 复核的不识别，时间戳与官方网页评论区认同一段文字，
/// 接口已标出的范围优先，范围按 UTF-16 计算。
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

    /// 时间戳与官方网页评论区认同一段文字、跳到同一秒数：前后紧挨什么都不影响，冒号半角全角都认，
    /// 各段不限 60，四段时取前三段；是否超出视频时长到显示时再判断。
    @Test(
        arguments: [
            (
                "1:23 处，还有 01:02:03 和 120:00，以及（12:34）", ["1:23", "01:02:03", "120:00", "12:34"],
                [83, 3_723, 7_200, 754]
            ),
            ("哈哈哈:00:11", ["00:11"], [11]),
            ("2：05、1：02：03", ["2：05", "1：02：03"], [125, 3_723]),
            (
                "p1:23 x264:10 3:45s 4:56this", ["1:23", "264:10", "3:45", "4:56"],
                [83, 15_850, 225, 296]
            ),
            ("1:60 1:60:00 1234:56", ["1:60", "1:60:00", "1234:56"], [120, 7_200, 74_096]),
            ("12:34:56:78 1:234", ["12:34:56", "1:23"], [45_296, 83])
        ]
    )
    func timestampsMatchOfficialTokenizer(message: String, texts: [String], seconds: [Int]) {
        let links = detected(message)

        #expect(links.map(\.text) == texts)
        #expect(links.map(\.target) == seconds.map { .timestamp(seconds: $0) })
    }

    /// `N#` 前缀与官方一样指第 N 个分 P，连同前缀成为一个链接；`#` 前没有数字时只认后面的时间。
    ///
    /// 序号是否超出视频的分 P 数到显示时再判断。
    @Test(
        arguments: [
            ("2#01:23", ["2#01:23"], [(83, 2)]),
            ("看 1#1:02:03 和 12#0:30", ["1#1:02:03", "12#0:30"], [(3_723, 1), (30, 12)]),
            ("0#00:10 #01:23", ["0#00:10", "01:23"], [(10, 0), (83, nil)])
        ] as [(String, [String], [(Int, Int?)])]
    )
    func pagePrefixesTargetThatPage(message: String, texts: [String], targets: [(Int, Int?)]) {
        let links = detected(message)

        #expect(links.map(\.text) == texts)
        #expect(links.map(\.target) == targets.map { .timestamp(seconds: $0.0, page: $0.1) })
    }

    /// 不成为时间戳链接：秒不是两位、全角数字、网址里的时间、秒数或分 P 序号溢出。
    @Test(
        arguments: [
            "1:2",
            "3:2",
            "16:9",
            "１：２３",
            "https://example.com/a?at=10:30",
            "9999999999999999:59:59",
            "99999999999999999999#01:23"
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
