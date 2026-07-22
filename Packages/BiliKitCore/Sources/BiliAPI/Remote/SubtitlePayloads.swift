import BiliModels
import Foundation

struct SubtitleCatalogPayload: Decodable, Sendable {
    let needsLogin: Bool?
    let subtitle: SubtitleCollectionPayload?

    private enum CodingKeys: String, CodingKey {
        case needsLogin = "need_login_subtitle"
        case subtitle
    }

    func resources() throws -> [SubtitleRemoteTrack] {
        guard needsLogin != true else {
            throw BiliAPIError.authorizationRequired
        }
        let payloads = subtitle?.subtitles ?? []
        guard payloads.count <= 128 else {
            throw BiliAPIError.invalidSubtitleData
        }

        var seen = Set<String>()
        return try payloads.compactMap { payload in
            guard let resource = try payload.resourceIfAvailable() else {
                return nil
            }
            guard seen.insert(resource.track.id).inserted else {
                throw BiliAPIError.invalidSubtitleData
            }
            return resource
        }
    }
}

struct SubtitleCollectionPayload: Decodable, Sendable {
    let subtitles: [SubtitleTrackPayload]
}

struct SubtitleTrackPayload: Decodable, Sendable {
    let numericID: Int64?
    let stringID: String?
    let languageCode: String
    let displayName: String
    let subtitleURL: String
    let aiType: Int?

    private enum CodingKeys: String, CodingKey {
        case numericID = "id"
        case stringID = "id_str"
        case languageCode = "lan"
        case displayName = "lan_doc"
        case subtitleURL = "subtitle_url"
        case aiType = "ai_type"
    }

    func resourceIfAvailable() throws -> SubtitleRemoteTrack? {
        guard let subtitleURL = Self.nonempty(subtitleURL) else {
            return nil
        }
        let id = stringID.flatMap(Self.nonempty)
            ?? numericID.map(String.init)
        guard let id,
              id.count <= 128,
              let languageCode = Self.nonempty(languageCode),
              languageCode.count <= 64,
              let displayName = Self.nonempty(displayName),
              displayName.count <= 128,
              let url = Self.url(subtitleURL)
        else {
            throw BiliAPIError.invalidSubtitleData
        }
        guard SubtitleURLPolicy().allows(url) else {
            throw BiliAPIError.untrustedSubtitleOrigin
        }
        return SubtitleRemoteTrack(
            track: SubtitleTrack(
                id: id,
                languageCode: languageCode,
                displayName: displayName,
                kind: (aiType ?? 0) > 0 ? .automatic : .standard
            ),
            url: url
        )
    }

    private static func nonempty(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func url(_ value: String) -> URL? {
        let absolute = value.hasPrefix("//") ? "https:\(value)" : value
        return URL(string: absolute)
    }
}

struct SubtitleBodyPayload: Decodable, Sendable {
    let body: [SubtitleCuePayload]

    func cues() throws -> [SubtitleCue] {
        guard body.count <= 20_000 else {
            throw BiliAPIError.invalidSubtitleData
        }
        var previousStart = -Double.infinity
        var totalTextLength = 0
        return try body.map { payload in
            let cue = try payload.cue()
            guard cue.startSeconds >= previousStart else {
                throw BiliAPIError.invalidSubtitleData
            }
            previousStart = cue.startSeconds
            totalTextLength += cue.text.count
            guard totalTextLength <= 1_000_000 else {
                throw BiliAPIError.invalidSubtitleData
            }
            return cue
        }
    }
}

struct SubtitleCuePayload: Decodable, Sendable {
    let startSeconds: Double
    let endSeconds: Double
    let content: String

    private enum CodingKeys: String, CodingKey {
        case startSeconds = "from"
        case endSeconds = "to"
        case content
    }

    func cue() throws -> SubtitleCue {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard startSeconds.isFinite,
              endSeconds.isFinite,
              startSeconds >= 0,
              endSeconds > startSeconds,
              endSeconds <= 86_400,
              !text.isEmpty,
              text.count <= 4_096
        else {
            throw BiliAPIError.invalidSubtitleData
        }
        return SubtitleCue(
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            text: text
        )
    }
}

struct SubtitleRemoteTrack: Sendable {
    let track: SubtitleTrack
    let url: URL
}
