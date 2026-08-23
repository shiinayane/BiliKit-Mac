import BiliApplication

extension VideoSearchOrder {
    var apiValue: String {
        switch self {
        case .relevance: "totalrank"
        case .mostPlayed: "click"
        case .newest: "pubdate"
        case .mostDanmaku: "dm"
        case .mostFavorited: "stow"
        }
    }
}

extension VideoDurationFilter {
    var apiValue: String { String(rawValue) }
}
