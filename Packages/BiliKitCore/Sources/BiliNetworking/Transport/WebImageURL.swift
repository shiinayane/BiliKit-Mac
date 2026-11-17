import Foundation

/// 接口返回的远端图片地址：`http:` 与协议相对地址升级为 HTTPS，再过公开 HTTPS 基线
/// `PublicHTTPSURLPolicy`；不合规时为 nil，调用方按“没有这张图”处理。
///
/// BiliAPI 映射视频封面、分段章节封面、头像、评论图片与热搜图标，BiliAuth 映射 nav 的账号头像，都只经这里；评论资源与
/// 热搜图标另须通过 BiliAPI 的 `BiliBFSImageURLPolicy`，图片管线请求前还会再检查（见 SECURITY-MODEL §4）。
package enum WebImageURL {
    package static func parse(_ value: String) -> URL? {
        let (normalized, _) = RemoteURLString.upgradingInsecureHTTP(
            RemoteURLString.resolvingProtocolRelative(value)
        )
        guard let url = URL(string: normalized),
            PublicHTTPSURLPolicy().allows(url)
        else {
            return nil
        }
        return url
    }
}
