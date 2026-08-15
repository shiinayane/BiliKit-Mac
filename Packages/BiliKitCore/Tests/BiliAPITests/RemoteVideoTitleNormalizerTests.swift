import Testing

@testable import BiliAPI

struct RemoteVideoTitleNormalizerTests {
    @Test
    func plainTextDecodesNamedDecimalAndHexEntitiesOnce() {
        let cases = [
            ("Tom&#x27;s", "Tom's"),
            ("A &lt; B &gt; C", "A < B > C"),
            ("A &amp; B &quot;C&quot; &apos;D&apos;", "A & B \"C\" 'D'"),
            ("&#39;&#x27;&#X1F600;", "''😀"),
            ("A&nbsp;B", "A\u{00A0}B"),
            ("&amp;lt;", "&lt;"),
        ]

        for (input, expected) in cases {
            #expect(RemoteVideoTitleNormalizer.plainText(input) == expected)
        }
    }

    @Test
    func malformedAndUnknownEntitiesRemainLiteral() {
        let cases = [
            "&unknown;",
            "&amp",
            "&#;",
            "&#x;",
            "&#xD800;",
            "&#x110000;",
            "&#0;",
            "&#10;",
        ]

        for value in cases {
            #expect(RemoteVideoTitleNormalizer.plainText(value) == value)
        }
    }

    @Test
    func searchResultStripsMarkupBeforeDecodingEntities() {
        let title = "学习<em class=\"keyword\">macOS</em> &#x27;A&#x27; &lt;测试&gt; &amp;lt;"

        #expect(
            RemoteVideoTitleNormalizer.searchResult(title)
                == "学习macOS 'A' <测试> &lt;"
        )
    }
}
