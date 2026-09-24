import Testing

@testable import BiliApplication

struct BVIDDeduplicationTests {
    @Test(
        arguments: [
            ([], [], []),
            (["BV1A", "BV1B"], [], ["BV1A", "BV1B"]),
            (["BV1A", "BV1B", "BV1A"], [], ["BV1A", "BV1B"]),
            (["BV1B", "BV1C"], ["BV1A", "BV1B"], ["BV1C"]),
            (["BV1A", "BV1A"], ["BV1A"], []),
            (["BV1C", "BV1D", "BV1C", "BV1A"], ["BV1A"], ["BV1C", "BV1D"])
        ] as [([String], [String], [String])]
    )
    func keepsFirstOccurrenceInOrderAndDropsExisting(
        page: [String],
        existing: [String],
        expected: [String]
    ) {
        #expect(page.uniquedByBVID(after: existing) { $0 } == expected)
    }
}
