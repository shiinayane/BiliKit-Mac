import Foundation

enum WebImageURL {
    static func parse(_ value: String) -> URL? {
        let normalized: String
        if value.hasPrefix("//") {
            normalized = "https:\(value)"
        } else if value.lowercased().hasPrefix("http://") {
            normalized = "https://" + value.dropFirst("http://".count)
        } else {
            normalized = value
        }
        guard let url = URL(string: normalized),
            url.scheme?.lowercased() == "https",
            url.host != nil
        else {
            return nil
        }
        return url
    }
}
