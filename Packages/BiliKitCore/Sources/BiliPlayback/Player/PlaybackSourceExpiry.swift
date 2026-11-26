@preconcurrency import AVFoundation
import Foundation

/// 当前 item 媒体地址的有效期：继续播放、拖动与播放中失败时据此判断要不要先换源。
///
/// 由 `AVPlayerEngine` 在 item 就绪时按 `PlaybackRequest.mediaExpiresAt` 建立，release 时换回 `unchecked`。地址带
/// CDN 签名的 `deadline`（实测约 120 分钟），过期后分段请求被拒，loopback 回 502，item 随之失败。
struct PlaybackSourceExpiry {
    /// 距离过期不到这么久就先换源。
    ///
    /// 取 5 分钟：继续播放或拖动之后，AVPlayer 还会按缓冲策略往后取几十秒到几分钟的分段，余量要盖住这段时间，
    /// 否则刚恢复播放不久就因地址过期失败、只能靠失败兜底；本机与 CDN 几分钟内的时钟偏差也落在里面。调大会让
    /// 更早的继续播放多一次 playurl 请求，调小则更容易在恢复播放后不久失败。
    static let refreshLeadTime: TimeInterval = 5 * 60

    static let unchecked = PlaybackSourceExpiry(refreshDeadline: nil)

    /// 从这一刻起需要换源；nil 表示不检查。
    private let refreshDeadline: Date?

    private init(refreshDeadline: Date?) {
        self.refreshDeadline = refreshDeadline
    }

    /// `isReplacement` 表示 item 来自换源。
    ///
    /// 换源得到的地址一就绪就已在余量内，说明本机时钟比 CDN 快、重取也不会更新，这个 item 不再检查；否则每次
    /// 继续播放都会重取一次，播放中的失败也会无限换源。首次加载的 item 照常检查，时钟偏快时最多多换一次源。
    init(expiresAt: Date?, installedAt now: Date, isReplacement: Bool) {
        guard let expiresAt else {
            self.init(refreshDeadline: nil)
            return
        }
        let refreshDeadline = expiresAt.addingTimeInterval(-Self.refreshLeadTime)
        // `Date` 只用 `<` 比较（见 ARCHITECTURE「平台与命名」）；这里与下面的取反都包含相等。
        self.init(
            refreshDeadline: isReplacement && !(now < refreshDeadline) ? nil : refreshDeadline
        )
    }

    func requiresRefresh(at now: Date) -> Bool {
        refreshDeadline.map { !(now < $0) } ?? false
    }
}

/// 已发出换源事件、等待 `refreshSource` 时被推迟的播放意图：从哪里继续，以及换源后是否继续播放。
///
/// 由 `AVPlayerEngine` 持有，release 时清除。等待期间的继续播放、暂停与拖动改写它而不动旧 item。
struct PendingSourceRefresh {
    var positionSeconds: Double
    var resumesPlayback: Bool
}

/// 一次换源要在新 item 上接续的状态，由 `refreshSource` 在释放旧 item 前取得。
struct PlaybackSourceContinuation {
    let positionSeconds: Double
    let resumesPlayback: Bool
    let mediaSelection: NativeMediaSelectionSnapshot
}

/// 当前 item 的音频与字幕选项组，就绪时读取一次，供换源时同步记下选择。
///
/// 失败的 item 不一定还能读出选项组，所以不等到换源时才读。progressive 媒体没有选项组。
struct NativeMediaSelectionGroups {
    static let none = NativeMediaSelectionGroups(audible: nil, legible: nil)

    let audible: AVMediaSelectionGroup?
    let legible: AVMediaSelectionGroup?

    static func load(from asset: AVAsset) async -> NativeMediaSelectionGroups {
        NativeMediaSelectionGroups(
            audible: try? await asset.loadMediaSelectionGroup(for: .audible),
            legible: try? await asset.loadMediaSelectionGroup(for: .legible)
        )
    }

    /// 记下 `item` 上的音轨与字幕选择；`subtitlePreference` 是关闭字幕前最后选中的一项。
    func snapshot(
        of item: AVPlayerItem,
        subtitlePreference: NativeSubtitleSelectionPreference?
    ) -> NativeMediaSelectionSnapshot {
        let selection = item.currentMediaSelection
        return NativeMediaSelectionSnapshot(
            audio: audible.flatMap(selection.selectedMediaOption(in:)).map(
                MediaSelectionOptionMatch.init
            ),
            subtitle: legible.flatMap(selection.selectedMediaOption(in:)).map(
                MediaSelectionOptionMatch.init
            ),
            subtitlePreference: subtitlePreference
        )
    }

    /// 在新 item 上选回同一音轨与字幕。
    ///
    /// 找不到对应选项（例如新清单没有那条 AI 配音）时保持默认：原声、字幕关闭。
    func restore(_ snapshot: NativeMediaSelectionSnapshot, on item: AVPlayerItem) {
        if let audible, let option = snapshot.audio?.option(in: audible) {
            item.select(option, in: audible)
        }
        if let legible, let option = snapshot.subtitle?.option(in: legible) {
            item.select(option, in: legible)
        }
    }
}

/// 换源前选中的音轨与字幕。
struct NativeMediaSelectionSnapshot {
    /// nil 表示没有音频选项组；换源后保持默认原声。
    let audio: MediaSelectionOptionMatch?
    /// nil 表示字幕关闭。
    let subtitle: MediaSelectionOptionMatch?
    /// 关闭字幕前最后选中的一项，再次开启字幕时恢复（见 `toggleNativeSubtitles`）。
    let subtitlePreference: NativeSubtitleSelectionPreference?
}

/// 在另一个 asset 的同类选项组里找回同一选项的依据：显示名与扩展语言标记。
///
/// 换源后 master playlist 按同样的音轨与字幕重新生成，但属于另一个 asset。两者都来自 playlist 的 NAME 与
/// LANGUAGE，重新生成时不变，同一组里也不重复（AI 配音的显示名映射时已去重）。不用系统属性列表：新清单少了某条
/// 配音时它可能指向另一条选项。
struct MediaSelectionOptionMatch {
    let displayName: String
    let extendedLanguageTag: String?

    init(_ option: AVMediaSelectionOption) {
        displayName = option.displayName
        extendedLanguageTag = option.extendedLanguageTag
    }

    func option(in group: AVMediaSelectionGroup) -> AVMediaSelectionOption? {
        group.options.first {
            $0.isPlayable
                && $0.displayName == displayName
                && $0.extendedLanguageTag == extendedLanguageTag
        }
    }
}
