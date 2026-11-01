import BiliModels
import Foundation

/// 评论图片地址；带像素框时请求图床按框缩小的图，不带框为原图。
///
/// 跨 target 契约：App 的 Composition 用 BiliAPI 的评论资源 resolver 构造这个闭包（来源与缩略参数校验
/// 只在那里，见 SECURITY-MODEL §4），本 target 的评论视图与加载器只调用它；解析不出时为 nil，调用方显示
/// 占位或不显示，不自行拼地址。
public typealias CommentAssetURLResolver =
    @Sendable (CommentAssetReference, CommentAssetPixelBox?) -> URL?
