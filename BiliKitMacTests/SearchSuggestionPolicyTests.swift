import Testing

@testable import BiliKit

/// 搜索联想把最多 3 条历史放在前面并跳过历史里已有的词，空白或过长的输入不请求联想。
struct SearchSuggestionPolicyTests {
    @Test
    func historyComesFirstAndSuggestionsSkipItsWords() {
        let sections = SearchSuggestionPolicy.sections(
            for: "  mac ",
            history: ["MacBook 评测", "原神", "Mac Mini", "macOS 开发", "macOS 26"],
            suggestions: ["macbook", "mac mini", "macstudio"]
        )

        // 历史按最近在前取包含输入的词，最多 3 条；两区去重同样不区分大小写。
        #expect(sections.history == ["MacBook 评测", "Mac Mini", "macOS 开发"])
        #expect(sections.suggestions == ["macbook", "macstudio"])
    }

    @Test(arguments: [("mac", true), ("  ", false), (String(repeating: "长", count: 101), false)])
    func onlySearchableInputRequestsSuggestions(input: String, requests: Bool) {
        #expect(SearchSuggestionPolicy.requestsSuggestions(for: input) == requests)
    }

    @Test(arguments: ["", "   "])
    func blankInputHasNoSections(input: String) {
        let sections = SearchSuggestionPolicy.sections(
            for: input,
            history: ["原神"],
            suggestions: ["原神"]
        )

        #expect(sections == SearchSuggestionPolicy.Sections(history: [], suggestions: []))
    }
}
