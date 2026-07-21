import Foundation
import Testing
@testable import BiliAPI

struct BiliMediaURLPolicyTests {
    @Test(
        arguments: [
            "https://upos-sz-mirrorali.bilivideo.com/video.m4s",
            "https://mcdn.bilivideo.cn/audio.m4s",
            "https://edge.szbdyd.com/video.m4s",
            "https://upos-hz-mirrorakam.akamaized.net/video.m4s",
            "https://media.example.invalid/fixture.m4s",
        ]
    )
    func acceptsAuditedMediaHostFamilies(_ value: String) throws {
        let url = try #require(URL(string: value))
        #expect(BiliMediaURLPolicy().allows(url))
    }

    @Test(
        arguments: [
            "http://upos-sz-mirrorali.bilivideo.com/video.m4s",
            "https://user@upos-sz-mirrorali.bilivideo.com/video.m4s",
            "https://upos-sz-mirrorali.bilivideo.com:8443/video.m4s",
            "https://127.0.0.1/video.m4s",
            "https://2130706433/video.m4s",
            "https://0177.0.0.1/video.m4s",
            "https://0x7f000001/video.m4s",
            "https://[::1]/video.m4s",
            "https://router.local/video.m4s",
            "https://bilivideo.com.attacker.example/video.m4s",
            "https://cdn.example.com/video.m4s",
            "https://upos-sz-mirrorali.bilivideo.com/video.m4s#fragment",
        ]
    )
    func rejectsUntrustedOrLocalMediaOrigins(_ value: String) throws {
        let url = try #require(URL(string: value))
        #expect(!BiliMediaURLPolicy().allows(url))
    }
}
