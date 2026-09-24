import BiliApplication
import BiliModels
import BiliNetworking
import Foundation

/// playurl：DASH／progressive 选择、AI 配音音轨与线路测速样本。
///
/// 三处调用共用同一个 WBI 签名管线；只有本地明确无凭据的播放请求才带游客参数。
extension BiliAPIClient {
    private static let playURLPath = "/x/player/wbi/playurl"
    /// 与 Web 播放页一致的固定参数；fnval 976 只请求本项目能消费的 DASH 形状。
    ///
    /// gaia 两项与 PiliPlus 一致，不分登录状态都带。
    private static let playURLBaseParameters = [
        "fnval": "976",
        "fnver": "0",
        "fourk": "1",
        "web_location": "1315873",
        "gaia_source": "pre-load",
        "isGaiaAvoided": "true"
    ]
    /// 只用于本地无凭据的匿名请求：`try_look=1` 让游客可取得 720P/1080P。
    private static let guestPlayURLParameters = ["try_look": "1"]
    private static let riskControlInteractionParameter = #"{"ds":[],"wh":[0,0,0],"of":[0,0,0]}"#
    private static let riskControlRandomAlphabet = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    )

    /// Web 播放页随 wbi playurl 上报的 WebGL 环境字段。
    ///
    /// 服务端只校验字段存在，缺失时返回 -352／v_voucher；与 PiliPlus、yt-dlp 一样每次用随机值，
    /// 不上报本机真实环境。
    static func playURLRiskControlParameters() -> [String: String] {
        [
            "dm_img_list": "[]",
            "dm_img_str": randomRiskControlString(length: 16...64),
            "dm_cover_img_str": randomRiskControlString(length: 32...128),
            "dm_img_inter": riskControlInteractionParameter
        ]
    }

    /// 随机字符串的 base64 去掉末两位，与 yt-dlp 的构造一致。
    private static func randomRiskControlString(length: ClosedRange<Int>) -> String {
        let text = String(
            (0..<Int.random(in: length)).map { _ in
                riskControlRandomAlphabet[Int.random(in: riskControlRandomAlphabet.indices)]
            }
        )
        return String(Data(text.utf8).base64EncodedString().dropLast(2))
    }

    /// 取得 AVC/AAC DASH 清单；仅 playurl 可按本地凭据状态选择精确授权或匿名请求。
    public func playback(
        for bvid: String,
        cid: Int64,
        quality: Int = 120
    ) async throws -> VideoPlayback {
        guard Self.isValidBVID(bvid), cid > 0, quality > 0 else {
            throw BiliAPIError.invalidRequest
        }
        let playbackSessionEpoch = authenticatedSessionEpoch
        let referer = Self.videoReferer(bvid)
        let parameters = ["voice_balance": "1"]
        let resolved: AuthorizedResponse<PlayURLPayload>
        do {
            resolved = try await signedPlayURL(
                bvid: bvid,
                cid: cid,
                quality: quality,
                parameters: parameters,
                access: .accountRead(
                    missingCredential: .fail,
                    mapsAuthenticationInvalidation: true
                )
            )
        } catch BiliAPIError.authorizationRequired {
            // 本地明确无凭据：同一 endpoint 匿名请求，并且只有这里带游客参数。
            resolved = try await signedPlayURL(
                bvid: bvid,
                cid: cid,
                quality: quality,
                parameters: parameters.merging(Self.guestPlayURLParameters) { $1 },
                access: .anonymous
            )
            try requireAuthenticatedSessionEpoch(playbackSessionEpoch)
        }
        let payload = resolved.payload

        if let dash = payload.dash {
            return try await dashPlayback(
                payload: payload,
                dash: dash,
                authorizationProvenance: resolved.authorizationProvenance,
                playbackSessionEpoch: playbackSessionEpoch,
                bvid: bvid,
                cid: cid,
                quality: quality,
                referer: referer
            )
        }

        guard let durl = payload.durl else {
            throw BiliAPIError.noPlayableMedia
        }
        let segment: DURLPayload
        switch durl {
        case .empty:
            throw BiliAPIError.unsupportedProgressiveMedia(.empty)
        case .multiple:
            throw BiliAPIError.unsupportedProgressiveMedia(.multipleSegments)
        case .single(let payload):
            segment = payload
        }
        guard payload.format?.lowercased() == "mp4" else {
            throw BiliAPIError.unsupportedProgressiveMedia(.unsupportedContainer)
        }
        if resolved.authorizationProvenance == .authenticated {
            try requireAuthenticatedSessionEpoch(playbackSessionEpoch)
        }
        return VideoPlayback(
            media: .progressive(try segment.model()),
            mediaHeaders: [
                "Referer": referer,
                "User-Agent": userAgent
            ],
            resumeMetadata:
                resolved.authorizationProvenance == .authenticated
                ? payload.resumeMetadata : nil
        )
    }

    /// 测速样本必须来自当前账户可消费的 playurl；没有凭据时失败而不匿名降级。
    func authenticatedPlaybackForCDNBenchmark(
        for bvid: String,
        cid: Int64,
        quality: Int = 120
    ) async throws -> CDNBenchmarkPlayback {
        guard Self.isValidBVID(bvid), cid > 0, quality > 0 else {
            throw BiliAPIError.invalidRequest
        }
        let playbackSessionEpoch = authenticatedSessionEpoch
        let resolved: AuthorizedResponse<CDNBenchmarkPlayURLPayload> =
            try await signedPlayURL(
                bvid: bvid,
                cid: cid,
                quality: quality,
                parameters: [:],
                access: .accountRead(
                    missingCredential: .fail,
                    mapsAuthenticationInvalidation: true
                )
            )
        try requireAuthenticatedSessionEpoch(playbackSessionEpoch)
        let video = try resolved.payload.dash.video
            .filter(\.isAVCVideo)
            .map { try $0.model(kind: .video) }
        guard !video.isEmpty else { throw BiliAPIError.noAVCVideo }
        try requireAuthenticatedSessionEpoch(playbackSessionEpoch)
        return CDNBenchmarkPlayback(
            videoRepresentations: video,
            mediaHeaders: [
                "Referer": Self.videoReferer(bvid),
                "User-Agent": userAgent
            ]
        )
    }

    /// 每次尝试都用当前 WBI key 重新签名；签名被拒时刷新 key 并只重试一次。
    private func signedPlayURL<Payload: Decodable & Sendable>(
        bvid: String,
        cid: Int64,
        quality: Int,
        parameters: [String: String],
        access: RequestAccess
    ) async throws -> AuthorizedResponse<Payload> {
        var signedParameters = Self.playURLBaseParameters
        signedParameters["bvid"] = bvid
        signedParameters["cid"] = String(cid)
        signedParameters["qn"] = String(quality)
        signedParameters.merge(parameters) { $1 }
        return try await withWBIKeyRefresh(retryingHTTPForbidden: false) { forceKeyRefresh in
            let keys = try await wbiKey(forceRefresh: forceKeyRefresh)
            let query = try wbiSigner.sign(
                parameters: signedParameters.merging(Self.playURLRiskControlParameters()) { $1 },
                keys: keys,
                timestamp: timestampProvider()
            )
            return try await getWithAuthorizationProvenance(
                url: try endpoint(path: Self.playURLPath, percentEncodedQuery: query),
                referer: Self.videoReferer(bvid),
                access: access
            )
        }
    }

    private func dashPlayback(
        payload: PlayURLPayload,
        dash: DASHPayload,
        authorizationProvenance: AuthorizationProvenance,
        playbackSessionEpoch: UInt64,
        bvid: String,
        cid: Int64,
        quality: Int,
        referer: String
    ) async throws -> VideoPlayback {
        let video = try dash.video
            .filter(\.isAVCVideo)
            .map { try $0.model(kind: .video) }
        let audio = try dash.audio
            .filter(\.isAACAudio)
            .map { try $0.model(kind: .audio) }
        guard !video.isEmpty else { throw BiliAPIError.noAVCVideo }
        guard !audio.isEmpty else { throw BiliAPIError.noAACAudio }

        var audioTracks = [
            PlaybackAudioTrack(
                id: "original",
                displayName: "原声",
                role: .original,
                isDefault: true,
                isAutoselect: true,
                loudnessMetadata: payload.volume?.model,
                representations: audio
            )
        ]
        if authorizationProvenance == .authenticated {
            try requireAuthenticatedSessionEpoch(playbackSessionEpoch)
            audioTracks += try await machineGeneratedAudioTracks(
                catalog: payload.languageCatalog,
                originalAudio: audio,
                bvid: bvid,
                cid: cid,
                quality: quality,
                sessionEpoch: playbackSessionEpoch
            )
            try requireAuthenticatedSessionEpoch(playbackSessionEpoch)
        }

        return VideoPlayback(
            media: .dash(
                PlaybackManifest(
                    videoRepresentations: video,
                    audioTracks: audioTracks
                )
            ),
            mediaHeaders: [
                "Referer": referer,
                "User-Agent": userAgent
            ],
            resumeMetadata:
                authorizationProvenance == .authenticated
                ? payload.resumeMetadata : nil
        )
    }

    private func machineGeneratedAudioTracks(
        catalog: AudioLanguageCatalogPayload?,
        originalAudio: [MediaRepresentation],
        bvid: String,
        cid: Int64,
        quality: Int,
        sessionEpoch: UInt64
    ) async throws -> [PlaybackAudioTrack] {
        let items = catalog?.validatedMachineGeneratedItems() ?? []
        guard !items.isEmpty else { return [] }
        var usedPaths = Self.mediaResourcePaths(originalAudio)
        var displayNames: Set<String> = ["原声"]
        var tracks: [PlaybackAudioTrack] = []
        tracks.reserveCapacity(items.count)
        for item in items {
            try Task.checkCancellation()
            try requireAuthenticatedSessionEpoch(sessionEpoch)
            guard let languageTag = item.validatedLanguageTag,
                let displayName = item.validatedDisplayName
            else {
                continue
            }
            let payload: PlayURLPayload = try await signedPlayURL(
                bvid: bvid,
                cid: cid,
                quality: quality,
                parameters: [
                    "cur_language": languageTag,
                    "voice_balance": "1"
                ],
                access: .accountRead(
                    missingCredential: .fail,
                    mapsAuthenticationInvalidation: true
                )
            ).payload
            try requireAuthenticatedSessionEpoch(sessionEpoch)
            guard let dash = payload.dash,
                payload.currentLanguage == languageTag,
                payload.currentProductionType == item.productionType
            else {
                continue
            }
            let representations: [MediaRepresentation]
            do {
                representations = try dash.audio
                    .filter(\.isAACAudio)
                    .map { try $0.model(kind: .audio) }
            } catch {
                continue
            }
            let paths = Self.mediaResourcePaths(representations)
            guard !representations.isEmpty, !paths.isEmpty,
                paths.isDisjoint(with: usedPaths),
                displayNames.insert(displayName).inserted
            else {
                continue
            }
            usedPaths.formUnion(paths)
            tracks.append(
                PlaybackAudioTrack(
                    id: "machine-generated:\(languageTag)",
                    displayName: displayName,
                    languageTag: languageTag,
                    role: .machineGenerated,
                    isDefault: false,
                    isAutoselect: true,
                    loudnessMetadata: payload.volume?.model,
                    representations: representations
                )
            )
        }
        return tracks
    }

    private static func mediaResourcePaths(
        _ representations: [MediaRepresentation]
    ) -> Set<String> {
        Set(
            representations.flatMap(\.urlCandidates).compactMap { url in
                URLComponents(
                    url: url,
                    resolvingAgainstBaseURL: false
                )?.percentEncodedPath
            }.filter { !$0.isEmpty }
        )
    }
}
