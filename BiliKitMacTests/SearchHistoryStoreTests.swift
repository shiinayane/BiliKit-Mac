import Foundation
import Testing

@testable import BiliKit

/// 搜索历史最近在前、去重、限量并持久化，删除与清空同步落盘，读不出的历史在启动时删除。
@MainActor
struct SearchHistoryStoreTests {
    @Test
    func recordKeepsMostRecentFirstWithoutDuplicates() {
        withIsolatedDefaults { defaults in
            let store = SearchHistoryStore(defaults: defaults)

            store.record("  词一  ")
            store.record("词二")
            store.record("词一")
            store.record("   ")
            store.record(String(repeating: "长", count: 101))

            #expect(store.entries == ["词一", "词二"])
            #expect(SearchHistoryStore(defaults: defaults).entries == ["词一", "词二"])
        }
    }

    @Test
    func historyIsCappedDroppingTheOldest() {
        withIsolatedDefaults { defaults in
            let store = SearchHistoryStore(defaults: defaults)

            for index in 1...(SearchHistoryStore.maximumEntryCount + 2) {
                store.record("词\(index)")
            }

            #expect(store.entries.count == SearchHistoryStore.maximumEntryCount)
            #expect(store.entries.first == "词\(SearchHistoryStore.maximumEntryCount + 2)")
            #expect(store.entries.last == "词3")
        }
    }

    @Test
    func removeAndClearPersist() {
        withIsolatedDefaults { defaults in
            let store = SearchHistoryStore(defaults: defaults)
            store.record("词一")
            store.record("词二")

            store.remove("词一")
            #expect(SearchHistoryStore(defaults: defaults).entries == ["词二"])

            store.clear()
            #expect(store.entries.isEmpty)
            #expect(SearchHistoryStore(defaults: defaults).entries.isEmpty)
            #expect(defaults.object(forKey: "searchHistory.entries") == nil)
            #expect(defaults.object(forKey: "searchHistory.schema") == nil)
        }
    }

    /// 读不出的历史在启动时删除，不留下界面上看不到、也清除不了的数据。
    @Test(
        arguments: [
            (nil, false),
            (2, false),
            (1, true)
        ] as [(Int?, Bool)]
    )
    func unreadableHistoryIsRemovedOnLoad(schema: Int?, storesEntriesAsString: Bool) {
        withIsolatedDefaults { defaults in
            if let schema {
                defaults.set(schema, forKey: "searchHistory.schema")
            }
            if storesEntriesAsString {
                defaults.set("词一", forKey: "searchHistory.entries")
            } else {
                defaults.set(["词一"], forKey: "searchHistory.entries")
            }

            #expect(SearchHistoryStore(defaults: defaults).entries.isEmpty)
            #expect(defaults.object(forKey: "searchHistory.entries") == nil)
            #expect(defaults.object(forKey: "searchHistory.schema") == nil)
        }
    }

    @Test
    func invalidAndDuplicateEntriesAreSkipped() {
        withIsolatedDefaults { defaults in
            defaults.set(1, forKey: "searchHistory.schema")

            // 非字符串、空白与重复条目逐条丢弃，其余保留。
            defaults.set([" 词一 ", 42, "", "词一", "词二"] as [Any], forKey: "searchHistory.entries")
            #expect(SearchHistoryStore(defaults: defaults).entries == ["词一", "词二"])
        }
    }
}
