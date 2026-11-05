import BiliNetworking
import Testing

/// query 的键与值按 RFC 3986 unreserved 以外全部编码（`+` 不保留），按给定顺序以 `&` 拼接。
struct URLQueryUnreservedEncodingTests {
    @Test
    func queryEncodesNamesAndValuesInOrder() {
        let query = URLQueryUnreservedEncoding.query([
            ("keyword", "C++ 猫"),
            ("a b", "x=y&z"),
            ("empty", ""),
            ("safe", "A-z_0.9~")
        ])

        #expect(
            query
                == "keyword=C%2B%2B%20%E7%8C%AB&a%20b=x%3Dy%26z&empty=&safe=A-z_0.9~"
        )
        #expect(URLQueryUnreservedEncoding.query([]) == "")
    }
}
