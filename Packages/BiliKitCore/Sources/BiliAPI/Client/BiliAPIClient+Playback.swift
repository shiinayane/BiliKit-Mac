import BiliApplication
import BiliModels
import BiliNetworking
import Foundation

/// playurl：DASH／progressive 选择、AI 配音音轨与线路测速样本。
extension BiliAPIClient {
    /// 取得 AVC/AAC DASH 清单；仅 playurl 可按本地凭据状态选择精确授权或匿名请求。
    public func playback(
        for bvid: String,
        cid: Int64,
        quality: Int = 120
    ) async throws -> VideoPlayback {
        try await playback(
            for: bvid,
            cid: cid,
            quality: quality,
            missingCredential: .useAnonymousRequest,
            includesMachineGeneratedAudio: true
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
        let referer = Self.videoReferer(bvid)
        let resolved: AuthorizedResponse<CDNBenchmarkPlayURLPayload> =
            try await getWithAuthorizationProvenance(
                path: "/x/player/playurl",
                queryItems: [
                    URLQueryItem(name: "bvid", value: bvid),
                    URLQueryItem(name: "cid", value: String(cid)),
                    URLQueryItem(name: "qn", value: String(quality)),
                    URLQueryItem(name: "fnval", value: "976"),
                    URLQueryItem(name: "fnver", value: "0"),
                    URLQueryItem(name: "fourk", value: "1")
                ],
                referer: referer,
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
                "Referer": referer,
                "User-Agent": userAgent
            ]
        )
    }

    private func playback(
        for bvid: String,
        cid: Int64,
        quality: Int,
        missingCredential: MissingCredentialBehavior,
        includesMachineGeneratedAudio: Bool
    ) async throws -> VideoPlayback {
        guard Self.isValidBVID(bvid), cid > 0, quality > 0 else {
            throw BiliAPIError.invalidRequest
        }
        let playbackSessionEpoch = authenticatedSessionEpoch
        let referer = Self.videoReferer(bvid)
        let queryItems = [
            URLQueryItem(name: "bvid", value: bvid),
            URLQueryItem(name: "cid", value: String(cid)),
            URLQueryItem(name: "qn", value: String(quality)),
            URLQueryItem(name: "fnval", value: "976"),
            URLQueryItem(name: "fnver", value: "0"),
            URLQueryItem(name: "fourk", value: "1"),
            URLQueryItem(name: "voice_balance", value: "1")
        ]
        let resolved: AuthorizedResponse<PlayURLPayload> =
            try await getWithAuthorizationProvenance(
                path: "/x/player/playurl",
                queryItems: queryItems,
                referer: referer,
                access: .accountRead(
                    missingCredential: missingCredential,
                    mapsAuthenticationInvalidation: true
                )
            )
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
                referer: referer,
                includesMachineGeneratedAudio: includesMachineGeneratedAudio
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

    private func dashPlayback(
        payload: PlayURLPayload,
        dash: DASHPayload,
        authorizationProvenance: AuthorizationProvenance,
        playbackSessionEpoch: UInt64,
        bvid: String,
        cid: Int64,
        quality: Int,
        referer: String,
        includesMachineGeneratedAudio: Bool
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
            if includesMachineGeneratedAudio {
                audioTracks += try await machineGeneratedAudioTracks(
                    catalog: payload.languageCatalog,
                    originalAudio: audio,
                    bvid: bvid,
                    cid: cid,
                    quality: quality,
                    referer: referer,
                    sessionEpoch: playbackSessionEpoch
                )
            }
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
        referer: String,
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
            let payload: PlayURLPayload = try await get(
                path: "/x/player/playurl",
                queryItems: [
                    URLQueryItem(name: "bvid", value: bvid),
                    URLQueryItem(name: "cid", value: String(cid)),
                    URLQueryItem(name: "qn", value: String(quality)),
                    URLQueryItem(name: "fnval", value: "976"),
                    URLQueryItem(name: "fnver", value: "0"),
                    URLQueryItem(name: "fourk", value: "1"),
                    URLQueryItem(name: "cur_language", value: languageTag),
                    URLQueryItem(name: "voice_balance", value: "1")
                ],
                referer: referer,
                access: .accountRead(
                    missingCredential: .fail,
                    mapsAuthenticationInvalidation: true
                )
            )
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
