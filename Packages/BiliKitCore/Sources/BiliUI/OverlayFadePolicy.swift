import Foundation

/// 浮在内容上的小控件出现与消失的淡入淡出时长：播放器上的“从头播放”、加载转圈与弹幕输入胶囊，
/// 侧栏与 UP 主空间的「返回顶部」按钮，以及相关推荐横排的左右翻页按钮共用这一个值。
///
/// 0.2 秒够看出是渐变而不是闪现，又短到不拖慢后续操作；调长会让按钮在已经不该点的时候还停留在画面上，
/// 调短就和直接显隐没有区别。“减弱动态效果”开启时由各调用方直接显隐，不读这个值。
public enum OverlayFadePolicy {
    public static let durationSeconds: TimeInterval = 0.2
}
