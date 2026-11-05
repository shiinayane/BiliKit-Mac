import BiliModels
import BiliNetworking
import Foundation

/// 只留下 playurl 请求，去掉 WBI nav 等其他请求。
func playURLRequests(_ transport: StubTransport) -> [HTTPRequest] {
    transport.capturedRequests().filter { $0.url.path == "/x/player/wbi/playurl" }
}

/// 只含一条英文 AI 配音的语言目录。
var machineGeneratedEnglishCatalog: [String: Any] {
    [
        "support": true,
        "items": [
            [
                "lang": "en",
                "title": "English（AI）",
                "production_type": 2
            ]
        ]
    ]
}

/// 一个视频轨、一个音轨的 DASH playurl 响应；可附带语言目录、当前语言与制作类型。
///
/// `audioPath` 为 nil 时 `dash.audio` 是 `null`，即没有音轨的稿件。
func semanticAudioResponse(
    audioPath: String?,
    languageCatalog: [String: Any]? = nil,
    currentLanguage: String? = nil,
    currentProductionType: Int? = nil
) throws -> HTTPResponse {
    var data: [String: Any] = [
        "dash": [
            "video": [
                [
                    "id": 32,
                    "codecid": 7,
                    "codecs": "avc1.64001f",
                    "mime_type": "video/mp4",
                    "bandwidth": 500_000,
                    "width": 1_280,
                    "height": 720,
                    "frame_rate": "30",
                    "base_url": "https://media.fixture.bilivideo.com/video.m4s",
                    "backup_url": [],
                    "segment_base": [
                        "initialization": "0-99",
                        "index_range": "100-199"
                    ]
                ]
            ],
            "audio": audioPath.map { audioPath -> Any in
                [
                    [
                        "id": 30_280,
                        "codecid": 0,
                        "codecs": "mp4a.40.2",
                        "mime_type": "audio/mp4",
                        "bandwidth": 192_000,
                        "base_url":
                            "https://media.fixture.bilivideo.com/\(audioPath)",
                        "backup_url": [],
                        "segment_base": [
                            "initialization": "0-99",
                            "index_range": "100-199"
                        ]
                    ]
                ]
            } ?? NSNull()
        ]
    ]
    if let languageCatalog {
        data["language"] = languageCatalog
    }
    if let currentLanguage {
        data["cur_language"] = currentLanguage
    }
    if let currentProductionType {
        data["cur_production_type"] = currentProductionType
    }
    return HTTPResponse(
        statusCode: 200,
        headers: ["Content-Type": "application/json"],
        body: try JSONSerialization.data(
            withJSONObject: ["code": 0, "data": data],
            options: [.sortedKeys]
        )
    )
}

extension VideoPlayback {
    /// DASH 播放的清单，progressive 为 nil；只供本 target 的断言取用。
    var dashManifest: PlaybackManifest? {
        guard case .dash(let manifest) = media else { return nil }
        return manifest
    }
}
