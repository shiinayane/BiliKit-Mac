/// 网格回送给来源的意图：近尾翻页、选中卡片、按卡片取菜单。
///
/// 由 `NativeGridView` 按调用方传入的闭包构造，Coordinator 每次 `update` 整体换成最新的一份，`reset()` 换成
/// `inert`，之后的回调都落空。只是闭包的集合，不持有状态；新增回调时在这里加字段。
struct NativeGridActions<Presentation> {
    /// 视野底边接近内容底部时请求下一页；由 `NearEndPagination` 判定每个尾标只调用一次。
    let onNearEnd: () -> Void
    /// 激活一张可激活的卡片（点击、回车／空格、读屏按下）；参数是卡片 ID。
    let onSelect: (String) -> Void
    /// 按卡片给出菜单描述（`NativeVideoCardMenu`），nil 表示这张卡片没有菜单。
    let cardMenu: (Presentation) -> NativeVideoCardMenu?

    /// 拆除后的网格用它替换回调。
    static var inert: Self {
        Self(onNearEnd: {}, onSelect: { _ in }, cardMenu: { _ in nil })
    }
}
