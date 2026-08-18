public enum CommentPresentationFormatting {
    public static func compactCount(_ count: Int64) -> String {
        VideoMetadataFormatting.compactCount(count)
    }

    public static func compactCount(_ count: Int) -> String {
        VideoMetadataFormatting.compactCount(Int64(clamping: count))
    }

    public static func pageCount(totalCount: Int, pageSize: Int) -> Int {
        guard totalCount > 0, pageSize > 0 else { return 1 }
        return (totalCount - 1) / pageSize + 1
    }
}
