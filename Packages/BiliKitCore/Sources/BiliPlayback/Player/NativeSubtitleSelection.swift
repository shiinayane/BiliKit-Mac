@preconcurrency import AVFoundation
import Foundation

/// 用户上次选中的原生字幕选项（系统属性列表的二进制编码），重新开启字幕时优先恢复同一选项。
struct NativeSubtitleSelectionPreference: Sendable {
    let propertyListData: Data?
}

/// 原生字幕的开关与选项恢复；只写本 engine 的字幕切换操作 ID 与上次选中的字幕。
extension AVPlayerEngine {
    public func toggleNativeSubtitles() async -> NativeSubtitleToggleResult {
        guard let item = player.currentItem else {
            return .unavailable
        }
        let operationID = UUID()
        let generation = loadGeneration
        subtitleToggleOperationID = operationID

        do {
            guard
                let group = try await item.asset.loadMediaSelectionGroup(
                    for: .legible
                ),
                !Task.isCancelled,
                subtitleToggleOperationID == operationID,
                loadGeneration == generation,
                player.currentItem === item
            else {
                finishSubtitleToggle(operationID)
                return .unavailable
            }

            if let selected = item.currentMediaSelection.selectedMediaOption(
                in: group
            ) {
                guard group.allowsEmptySelection else {
                    finishSubtitleToggle(operationID)
                    return .unavailable
                }
                lastSubtitleSelection = Self.subtitlePreference(for: selected)
                item.select(nil, in: group)
                finishSubtitleToggle(operationID)
                return .disabled
            }

            guard
                let option = Self.subtitleOption(
                    in: group,
                    restoring: lastSubtitleSelection
                )
            else {
                finishSubtitleToggle(operationID)
                return .unavailable
            }
            item.select(option, in: group)
            lastSubtitleSelection = Self.subtitlePreference(for: option)
            finishSubtitleToggle(operationID)
            return .enabled(label: option.displayName)
        } catch {
            finishSubtitleToggle(operationID)
            return .unavailable
        }
    }

    static func subtitlePreference(
        for option: AVMediaSelectionOption
    ) -> NativeSubtitleSelectionPreference {
        NativeSubtitleSelectionPreference(
            propertyListData: try? PropertyListSerialization.data(
                fromPropertyList: option.propertyList(),
                format: .binary,
                options: 0
            )
        )
    }

    /// 开启字幕时选哪一项：能恢复上次的选项就恢复，否则按系统偏好语言排序取第一项。
    ///
    /// 系统可能在字幕菜单里插入不在 BiliKit 目录里的翻译轨（例如有英文字幕时翻成界面语言），按系统排序取
    /// 字幕时可能选中它；没有公开 API 可以排除它。
    static func subtitleOption(
        in group: AVMediaSelectionGroup,
        restoring preference: NativeSubtitleSelectionPreference?
    ) -> AVMediaSelectionOption? {
        let playable = AVMediaSelectionGroup.playableMediaSelectionOptions(
            from: group.options
        )
        guard !playable.isEmpty else { return nil }
        if let preference {
            if let data = preference.propertyListData,
                let propertyList = try? PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                ),
                let exact = group.mediaSelectionOption(
                    withPropertyList: propertyList
                ),
                exact.isPlayable
            {
                return exact
            }
        }
        let preferred = AVMediaSelectionGroup.mediaSelectionOptions(
            from: playable,
            filteredAndSortedAccordingToPreferredLanguages:
                Locale.preferredLanguages
        )
        return preferred.first ?? playable.first
    }
}
