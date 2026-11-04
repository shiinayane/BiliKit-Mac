import Foundation
import Testing

@testable import BiliVideoCollectionUI

/// 网格卡片缓存只为新追加或变化的条目生成卡片，其余位置沿用上次的结果，输出顺序与来源一致。
@MainActor
@Suite
struct NativeVideoCardCacheTests {
    @Test
    func onlyAppendedOrChangedSourcesAreRebuilt() {
        let cache = NativeVideoCardCache<String>()
        var built: [String] = []
        func cards(_ sources: [String]) -> [String] {
            cache.cards(for: sources) { source in
                built.append(source)
                return NativeVideoCardPresentation(
                    id: source,
                    title: source,
                    coverURL: nil,
                    avatarURL: nil,
                    showsAvatar: false,
                    footerLeadingText: "",
                    accessibilityLabel: source
                )
            }
            .map(\.id)
        }

        #expect(cards(["a", "b"]) == ["a", "b"])
        #expect(cards(["a", "b", "c", "d"]) == ["a", "b", "c", "d"])
        #expect(cards(["a", "x", "c", "d"]) == ["a", "x", "c", "d"])

        #expect(built == ["a", "b", "c", "d", "x"])
    }
}
