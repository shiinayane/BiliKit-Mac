import Testing

@testable import BiliAPI

/// 远端文本只解码一次 HTML 实体：命名、十进制与十六进制实体还原，未知、残缺或非法码点的实体保留原文，
/// 搜索结果先去标签再解码。
struct RemoteHTMLTextTests {
    @Test(
        arguments: [
            ("Tom&#x27;s", "Tom's"),
            ("A &lt; B &gt; C", "A < B > C"),
            ("A &amp; B &quot;C&quot; &apos;D&apos;", "A & B \"C\" 'D'"),
            ("&#39;&#x27;&#X1F600;", "''😀"),
            ("A&nbsp;B", "A\u{00A0}B"),
            ("&amp;lt;", "&lt;")
        ]
    )
    func plainTextDecodesNamedDecimalAndHexEntitiesOnce(input: String, expected: String) {
        #expect(RemoteHTMLText.plainText(input) == expected)
    }

    @Test(
        arguments: [
            "&unknown;",
            "&amp",
            "&#;",
            "&#x;",
            "&#xD800;",
            "&#x110000;",
            "&#0;",
            "&#10;"
        ]
    )
    func malformedAndUnknownEntitiesRemainLiteral(value: String) {
        #expect(RemoteHTMLText.plainText(value) == value)
    }

    @Test
    func searchResultStripsMarkupBeforeDecodingEntities() {
        let title = "学习<em class=\"keyword\">macOS</em> &#x27;A&#x27; &lt;测试&gt; &amp;lt;"

        #expect(
            RemoteHTMLText.searchResult(title)
                == "学习macOS 'A' <测试> &lt;"
        )
    }
}
