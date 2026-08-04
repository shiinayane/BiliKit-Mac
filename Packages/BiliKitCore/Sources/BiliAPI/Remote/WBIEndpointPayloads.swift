import Foundation

struct WBIImagePayload: Decodable, Sendable {
    let imageURL: String
    let subURL: String

    private enum CodingKeys: String, CodingKey {
        case imageURL = "img_url"
        case subURL = "sub_url"
    }
}

struct NavigationPayload: Decodable, Sendable {
    let wbiImage: WBIImagePayload

    private enum CodingKeys: String, CodingKey {
        case wbiImage = "wbi_img"
    }
}
