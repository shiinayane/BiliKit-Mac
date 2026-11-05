import BiliApplication
import BiliModels
import BiliNetworking
import Foundation

/// playurl：DASH／progressive 选择、AI 配音音轨与线路测速样本。
///
/// 三处调用共用同一个 WBI 签名管线；只有本地明确无凭据的播放请求才带游客参数。
extension BiliAPIClient {
    /// playurl 的固定参数。
    ///
    /// fnval 2000 请求 DASH、HDR、4K、杜比音频、杜比视界与 8K（不含 AV1 位 2048）；服务端只返回账户与
    /// 稿件实际有的档位，映射时再按 `DASHVideoLadder` 取用。gaia 两项与 PiliPlus 一致，不分登录状态都带。
    private static let playURLBaseParameters = [
        "fnval": "2000",
        "fnver": "0",
        "fourk": "1",
        "web_location": "1315873",
        "gaia_source": "pre-load",
        "isGaiaAvoided": "true"
    ]
    /// playurl 请求的清晰度 `qn`：127 是 8K 档，服务端按账户权限与稿件实际档位返回不高于它的全部
    /// DASH 档位，播放器再自适应选择；较早视频只有 FLV 时按不高于它的最高 MP4 重取一次。
    static let requestedPlaybackQuality = 127
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

    /// 取得 DASH 清单（视频 HEVC 或 AVC、音频 AAC）；仅 playurl 可按本地凭据状态选择精确授权或匿名请求。
    public func playback(
        for bvid: String,
        cid: Int64
    ) async throws -> VideoPlayback {
        guard BVID.isValid(bvid), cid > 0 else {
            throw BiliAPIError.invalidRequest
        }
        let quality = Self.requestedPlaybackQuality
        // 进入时记录认证 epoch：带凭据得到的 playurl、续播位置与 AI 配音在使用前都与它比对，
        // 不一致抛 `CancellationError`，不把两个会话的结果拼进同一次播放。
        let playbackSessionEpoch = authenticatedSessionEpoch
        let referer = try Self.videoReferer(bvid)
        var resolved = try await resolvedPlayURL(
            bvid: bvid,
            cid: cid,
            quality: quality,
            playbackSessionEpoch: playbackSessionEpoch
        )
        // 较早视频没有 DASH，请求的清晰度可能只有 FLV；改用不高于请求的最高 MP4 清晰度重取一次。
        if resolved.payload.dash == nil, !resolved.payload.hasProgressiveMP4Format,
            let mp4Quality = resolved.payload.progressiveMP4Qualities.filter({ $0 < quality }).max()
        {
            resolved = try await resolvedPlayURL(
                bvid: bvid,
                cid: cid,
                quality: mp4Quality,
                playbackSessionEpoch: playbackSessionEpoch
            )
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
        guard payload.hasProgressiveMP4Format else {
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

    /// 按本地凭据状态请求 playurl：有凭据时精确授权，本地明确无凭据时同一 endpoint 匿名请求。
    private func resolvedPlayURL(
        bvid: String,
        cid: Int64,
        quality: Int,
        playbackSessionEpoch: UInt64
    ) async throws -> AuthorizedResponse<PlayURLPayload> {
        do {
            return try await signedPlayURL(
                bvid: bvid,
                cid: cid,
                quality: quality,
                parameters: [:],
                access: .accountRead(missingCredential: .fail)
            )
        } catch BiliAPIError.authorizationRequired {
            // 本地明确无凭据：同一 endpoint 匿名请求，并且只有这里带游客参数。
            let resolved: AuthorizedResponse<PlayURLPayload> = try await signedPlayURL(
                bvid: bvid,
                cid: cid,
                quality: quality,
                parameters: Self.guestPlayURLParameters,
                access: .anonymous
            )
            try requireAuthenticatedSessionEpoch(playbackSessionEpoch)
            return resolved
        }
    }

    /// 测速样本必须来自当前账户可消费的 playurl；没有凭据时失败而不匿名降级。
    func authenticatedPlaybackForCDNBenchmark(
        for bvid: String,
        cid: Int64
    ) async throws -> CDNBenchmarkPlayback {
        guard BVID.isValid(bvid), cid > 0 else {
            throw BiliAPIError.invalidRequest
        }
        let playbackSessionEpoch = authenticatedSessionEpoch
        let resolved: AuthorizedResponse<CDNBenchmarkPlayURLPayload> =
            try await signedPlayURL(
                bvid: bvid,
                cid: cid,
                quality: Self.requestedPlaybackQuality,
                parameters: [:],
                access: .accountRead(missingCredential: .fail)
            )
        try requireAuthenticatedSessionEpoch(playbackSessionEpoch)
        // 测速只比较线路吞吐，样本固定取 AVC，与播放选了哪种编码无关。
        let video = try resolved.payload.dash.video
            .filter { $0.videoCodec == .avc }
            .map { try $0.model(kind: .video) }
        guard !video.isEmpty else { throw BiliAPIError.noSupportedVideo }
        try requireAuthenticatedSessionEpoch(playbackSessionEpoch)
        return CDNBenchmarkPlayback(
            videoRepresentations: video,
            mediaHeaders: [
                "Referer": try Self.videoReferer(bvid),
                "User-Agent": userAgent
            ]
        )
    }

    /// 每次尝试都用当前 WBI key 与新的随机风控字段重新签名；重试与会话变化的处理见 `signedRequest`。
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
        return try await signedRequest(
            path: BiliAccountReadPath.playURL,
            parameters: {
                signedParameters.merging(Self.playURLRiskControlParameters()) { $1 }
            },
            send: { url in
                try await getWithAuthorizationProvenance(
                    url: url,
                    referer: try Self.videoReferer(bvid),
                    access: access
                )
            }
        )
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
        let video = try DASHVideoLadder(dash.video)
        let remoteAudio = dash.audio ?? []
        let audio = try remoteAudio.filter { $0.audioCodec == .aac }.map {
            try $0.model(kind: .audio)
        }
        // `dash.audio` 为 null 或空是稿件本身没有声音，只播视频；列出了音频却没有 AAC 才算不支持。
        guard remoteAudio.isEmpty || !audio.isEmpty else { throw BiliAPIError.noAACAudio }
        var audioTracks: [PlaybackAudioTrack] = []
        // 没有原声就没有可以并列的配音，不请求配音目录里的语言。
        if !audio.isEmpty {
            audioTracks.append(
                .original(
                    representations: audio,
                    dolby: dash.originalDolbyAudio,
                    lossless: dash.originalLosslessAudio
                )
            )
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
        }

        return VideoPlayback(
            media: .dash(
                PlaybackManifest(
                    videoRepresentations: video.primary,
                    fallbackVideoRepresentations: video.fallback,
                    hdrVideoCandidates: video.hdrCandidates,
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

    /// 账户可用的 AI 配音音轨；配音是附加内容，原声已经可播放。
    ///
    /// 某个语言的请求失败（风控、网络、业务拒绝、本地授权不可用等）时停止后续语言的配音请求，只返回
    /// 已经拿到的音轨，不让整次播放失败；失败的语言本身至多经过一次 WBI 重试。凭据失效与会话变化仍向上
    /// 抛出，交给账户复核与取消。
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
        var displayNames: Set<String> = [PlaybackAudioTrack.originalDisplayName]
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
            let payload: PlayURLPayload
            do {
                payload = try await signedPlayURL(
                    bvid: bvid,
                    cid: cid,
                    quality: quality,
                    parameters: ["cur_language": languageTag],
                    access: .accountRead(missingCredential: .fail)
                ).payload
            } catch is CancellationError {
                throw CancellationError()
            } catch BiliAPIError.authenticationInvalid {
                throw BiliAPIError.authenticationInvalid
            } catch {
                break
            }
            try requireAuthenticatedSessionEpoch(sessionEpoch)
            guard let dash = payload.dash,
                payload.currentLanguage == languageTag,
                payload.currentProductionType == item.productionType
            else {
                continue
            }
            let representations: [MediaRepresentation]
            do {
                representations = try (dash.audio ?? [])
                    .filter { $0.audioCodec == .aac }
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
                    // 不参与系统自动选择：否则开着自动媒体选择时，语言等于界面语言的配音会在起播时压过原声。
                    isAutoselect: false,
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
