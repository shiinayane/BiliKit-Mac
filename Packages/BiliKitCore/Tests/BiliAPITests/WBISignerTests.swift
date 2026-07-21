import Foundation
import Testing
@testable import BiliAPI

struct WBISignerTests {
    @Test
    func matchesDeterministicSignatureVector() throws {
        let keys = try WBIKeyMaterial(
            imageURL: "https://images.example.invalid/wbi/0123456789abcdef0123456789abcdef.png",
            subURL: "https://images.example.invalid/wbi/fedcba9876543210fedcba9876543210.png"
        )

        let query = try WBISigner().sign(
            parameters: [
                "keyword": "macOS !'()* 测试",
                "page": "1",
                "search_type": "video",
            ],
            keys: keys,
            timestamp: 1_700_000_000
        )

        #expect(
            query
                == "keyword=macOS%20%20%E6%B5%8B%E8%AF%95&page=1&search_type=video&wts=1700000000&w_rid=96b886f375879ce6f3d9616f6644770e"
        )
    }

    @Test
    func rejectsMalformedKeyURLs() {
        #expect(throws: BiliAPIError.invalidWBIKey) {
            try WBIKeyMaterial(
                imageURL: "https://images.example.invalid/wbi/short.png",
                subURL: "https://images.example.invalid/wbi/also-short.png"
            )
        }
    }
}
