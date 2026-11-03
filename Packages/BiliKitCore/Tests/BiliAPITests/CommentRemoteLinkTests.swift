import BiliModels
import Foundation
import Testing

@testable import BiliAPI

/// 固定评论链接分类：站内视频（含 av 号、分 P 与起播秒数）与空间投稿页在应用内打开，合规 b23.tv 短链
/// 点击时只用短码解析，其余地址保持公开 HTTPS 外链；jump_url 的搜索词与无网页地址的条目不成链接，
/// 标题、图标与 `match_once` 跟随链接，形状异常时按缺省处理。
@Suite("Comment remote links")
struct CommentRemoteLinkTests {
    /// 桌面版、手机版与裸域的视频地址都在应用内播放；av 号换算为 BV 号，分 P 只接受正整数。
    @Test(
        arguments: [
            ("https://www.bilibili.com/video/BV1FixtureA1", "BV1FixtureA1", nil),
            ("https://m.bilibili.com/video/BV1FixtureA1/", "BV1FixtureA1", nil),
            ("https://bilibili.com/video/BV1FixtureA1?p=3", "BV1FixtureA1", 3),
            ("//www.bilibili.com/video/av170001", "BV17x411w7KC", nil),
            ("https://WWW.bilibili.com/video/AV2/?p=2", "BV1xx411c7mD", 2),
            ("https://www.bilibili.com/video/BV1FixtureA1?p=0", "BV1FixtureA1", nil),
            ("https://www.bilibili.com/video/BV1FixtureA1?p=abc", "BV1FixtureA1", nil),
            ("https://www.bilibili.com/video/BV1FixtureA1?p=+3", "BV1FixtureA1", nil),
            (
                "https://www.bilibili.com/video/BV1FixtureA1?p=99999999999999999999",
                "BV1FixtureA1", nil
            )
        ] as [(String, String, Int?)]
    )
    func videoAddressesOpenInApp(value: String, bvid: String, page: Int?) {
        #expect(
            CommentRemoteLink.target(value) == .video(bvid: bvid, page: page, startSeconds: nil)
        )
    }

    /// 链接里的起播秒数 `t` 与分 P 一样只认正整数；小数与 `1m30s` 这类写法忽略。
    @Test(
        arguments: [
            ("?p=2&t=30", 2, 30),
            ("?t=90", nil, 90),
            ("?t=0", nil, nil),
            ("?t=12.5", nil, nil),
            ("?t=1m30s", nil, nil)
        ] as [(String, Int?, Int?)]
    )
    func startSecondsComeFromTheTParameter(query: String, page: Int?, startSeconds: Int?) {
        #expect(
            CommentRemoteLink.target("https://www.bilibili.com/video/BV1xx411c7mD\(query)")
                == .video(bvid: "BV1xx411c7mD", page: page, startSeconds: startSeconds)
        )
    }

    @Test(
        arguments: [
            ("https://space.bilibili.com/123456", Int64(123456)),
            ("https://space.bilibili.com/123456/?spm_id_from=comment", 123456),
            ("https://space.bilibili.com/123456/video", 123456),
            ("https://space.bilibili.com/123456/upload/video", 123456),
            ("https://m.bilibili.com/space/42", 42)
        ] as [(String, Int64)]
    )
    func spaceAddressesOpenTheSpaceInApp(value: String, memberID: Int64) {
        #expect(CommentRemoteLink.target(value) == .space(memberID: memberID))
    }

    /// 不能确定站内目标的地址都按公开 HTTPS 外链处理。
    ///
    /// 包括形状不合法的视频号或 MID、编码过的分隔符、带端口或多余路径段的地址，以及空间里投稿列表
    /// 以外、应用内没有对应页面的子页面（合集、收藏夹、动态）。
    @Test(arguments: [
        "https://www.bilibili.com/video/av0",
        "https://www.bilibili.com/video%2FBV1FixtureA1",
        "https://www.bilibili.com:8443/video/BV1FixtureA1",
        "https://www.bilibili.com/video/BV1FixtureA1/extra",
        "https://space.bilibili.com/123456/channel/collectiondetail?sid=9",
        "https://space.bilibili.com/123456/favlist?fid=1",
        "https://space.bilibili.com/123456/dynamic",
        "https://m.bilibili.com/space/abc",
        "https://b23.tv/",
        "https://b23.tv/abc/def",
        "https://b23.tv/abcdefghijklmnopq",
        "https://b23.tv/ab-cd",
        "https://b23.tv:8443/AbCd123",
        "https://bili2233.cn/AbCd123",
        "https://www.bilibili.com/video/av2251799813685248",
        "https://www.bilibili.com/video/av12x",
        "https://space.bilibili.com/0",
        "https://space.bilibili.com/abc",
        "https://search.bilibili.com/all?keyword=BV1FixtureA1"
    ])
    func malformedInternalAddressesStayExternal(value: String) {
        guard case .external(let reference) = CommentRemoteLink.target(value) else {
            Issue.record("形状不合法的站内地址应保持为外部链接")
            return
        }
        #expect(reference.remoteURL == URL(string: value))
    }

    /// 合规的 b23.tv 短链点击后才解析；请求地址只保留短码，去掉 query 与 fragment。
    @Test(
        arguments: [
            ("https://b23.tv/AbCd123", "https://b23.tv/AbCd123"),
            ("//B23.TV/AbCd123?share_source=copy#x", "https://b23.tv/AbCd123"),
            ("https://b23.tv/BV1xx411c7mD/", "https://b23.tv/BV1xx411c7mD")
        ]
    )
    func shortLinksAreResolvedOnClick(value: String, requestURL: String) throws {
        guard case .shortLink(let reference) = CommentRemoteLink.target(value) else {
            Issue.record("合规的 b23.tv 地址应识别为短链")
            return
        }
        let url = reference.remoteURL
        #expect(CommentRemoteLink.shortLinkRequestURL(url)?.absoluteString == requestURL)
    }

    /// 搜索词链接（标记为布尔或 0／1）与没有网页地址的条目不生成链接，正文按普通文字显示。
    @Test
    func wordSearchAndAddresslessJumpURLsStayPlainText() throws {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "message": "关键词 热词 网页 应用 视频",
                "jump_url": [
                    "关键词": [
                        "pc_url": "//search.bilibili.com/all?keyword=%E5%85%B3",
                        "extra": ["is_word_search": true]
                    ],
                    "热词": [
                        "pc_url": "//search.bilibili.com/all?keyword=%E7%83%AD",
                        "extra": ["is_word_search": 1]
                    ],
                    "网页": ["pc_url": "", "title": "网页链接"],
                    "应用": ["app_url_schema": "bilibili://video/170001"],
                    "视频": [
                        "pc_url": "https://www.bilibili.com/video/BV1FixtureA1",
                        "extra": ["is_word_search": false]
                    ]
                ]
            ]
        )
        let payload = try JSONDecoder().decode(CommentContentPayload.self, from: data)

        let links = try payload.model().links

        #expect(links.map(\.target) == [.video(bvid: "BV1FixtureA1", page: nil, startSeconds: nil)])
        #expect(links.map(\.range) == [CommentTextRange(location: 13, length: 2)])
    }

    /// 正文里的网址本身作键、`pc_url` 为空（实测 b23.tv 短链就是这种形状）时退回用键；键不是
    /// HTTPS 网址时不生成链接。
    @Test
    func emptyPCURLFallsBackToAnAddressKey() throws {
        let short = "https://b23.tv/Jf3cvv2"
        let video = "https://www.bilibili.com/video/BV1xx411c7mD"
        let insecure = "http://example.com/a"
        let data = try JSONSerialization.data(
            withJSONObject: [
                "message": "\(short) \(video) \(insecure)",
                "jump_url": [
                    short: [
                        "pc_url": "", "title": "视频标题", "prefix_icon": "https://i0.hdslb.com/a.png"
                    ],
                    video: ["title": "视频标题"],
                    insecure: ["pc_url": ""]
                ]
            ]
        )
        let payload = try JSONDecoder().decode(CommentContentPayload.self, from: data)

        let targets = try payload.model().links.map(\.target)

        #expect(targets.count == 2)
        guard case .shortLink(let reference) = targets.first else {
            Issue.record("键为 b23.tv 网址、pc_url 为空时应识别为短链")
            return
        }
        #expect(reference.remoteURL.absoluteString == short)
        #expect(targets.last == .video(bvid: "BV1xx411c7mD", page: nil, startSeconds: nil))
    }

    /// 接口给的标题与前置图标跟随链接；标题去掉首尾空白、与原文相同时不替换；`match_once` 只链接
    /// 第一处。
    @Test
    func jumpURLTitleIconAndMatchOnceFollowTheLink() throws {
        let short = "https://b23.tv/Jf3cvv2"
        let data = try JSONSerialization.data(
            withJSONObject: [
                "message": "\(short) 视频 \(short) 视频",
                "jump_url": [
                    short: [
                        "pc_url": "",
                        "title": " 韩语版《朋友的酒》 ",
                        "prefix_icon": "https://i0.hdslb.com/bfs/activity-plat/static/icon.png",
                        "match_once": true
                    ],
                    "视频": [
                        "pc_url": "https://www.bilibili.com/video/BV1xx411c7mD",
                        "title": "视频"
                    ]
                ]
            ]
        )
        let payload = try JSONDecoder().decode(CommentContentPayload.self, from: data)

        let links = try payload.model().links

        // 第二处短链不再由接口标出（match_once），按正文自识别成为没有标题的链接。
        #expect(links.map(\.range.location) == [0, 23, 26, 49])
        #expect(links.first?.title == "韩语版《朋友的酒》")
        #expect(
            links.first?.icon?.remoteURL.absoluteString
                == "https://i0.hdslb.com/bfs/activity-plat/static/icon.png"
        )
        #expect(links.dropFirst().allSatisfy { $0.title == nil && $0.icon == nil })
    }

    /// 接口标题与正文一样还原 HTML 实体；还原后与正文相同时不替换。
    @Test
    func jumpURLTitleIsDecodedBeforeComparingWithTheText() throws {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "message": "看这个 A&amp;B",
                "jump_url": [
                    "看这个": [
                        "pc_url": "https://www.bilibili.com/video/BV1xx411c7mD",
                        "title": "Tom&#x27;s &lt;朋友&gt;"
                    ],
                    "A&amp;B": [
                        "pc_url": "https://www.bilibili.com/video/BV1FixtureA1",
                        "title": "A&amp;B"
                    ]
                ]
            ]
        )
        let payload = try JSONDecoder().decode(CommentContentPayload.self, from: data)

        let links = try payload.model().links

        #expect(links.map(\.title) == ["Tom's <朋友>", nil])
    }

    /// 站外链接不替换标题：正文保留真实网址，点击前能看到域名；图标照常带上。
    @Test
    func externalLinksKeepTheirAddressText() throws {
        let address = "https://example.com/shop"
        let data = try JSONSerialization.data(
            withJSONObject: [
                "message": address,
                "jump_url": [
                    address: [
                        "pc_url": address,
                        "title": "商品名",
                        "prefix_icon": "https://i0.hdslb.com/bfs/icon.png"
                    ]
                ]
            ]
        )
        let payload = try JSONDecoder().decode(CommentContentPayload.self, from: data)

        let link = try #require(try payload.model().links.first)

        #expect(link.title == nil)
        #expect(link.icon != nil)
    }

    /// 标题、图标与 `match_once` 形状异常时按缺省处理，链接照常生成。
    @Test
    func malformedDisplayFieldsKeepTheLink() throws {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "message": "视频",
                "jump_url": [
                    "视频": [
                        "pc_url": "https://www.bilibili.com/video/BV1xx411c7mD",
                        "title": 42,
                        "prefix_icon": ["x"],
                        "match_once": "yes"
                    ]
                ]
            ]
        )
        let payload = try JSONDecoder().decode(CommentContentPayload.self, from: data)

        let links = try payload.model().links

        #expect(links.map(\.target) == [.video(bvid: "BV1xx411c7mD", page: nil, startSeconds: nil)])
        #expect(links.first?.title == nil)
        #expect(links.first?.icon == nil)
    }

    /// `extra` 形状异常时按普通链接处理，不拖累整条 jump_url。
    @Test
    func malformedExtraKeepsTheLink() throws {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "message": "视频",
                "jump_url": [
                    "视频": [
                        "pc_url": "https://www.bilibili.com/video/BV1FixtureA1",
                        "extra": "unexpected"
                    ]
                ]
            ]
        )
        let payload = try JSONDecoder().decode(CommentContentPayload.self, from: data)

        #expect(
            try payload.model().links.map(\.target) == [
                .video(bvid: "BV1FixtureA1", page: nil, startSeconds: nil)
            ]
        )
    }
}
