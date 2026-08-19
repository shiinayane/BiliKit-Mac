# ADR 0010：播放侧栏使用单一 AppKit 评论渲染链

- 状态：已接受
- 日期：2026-08-17
- 关联：ADR 0004、ADR 0006、ADR 0009

## 背景

真实长评论列表同时包含可变高度正文、可选择文本、楼中楼分页和连续侧栏 resize。生产数据验证表明，
`ScrollView + LazyVStack` 在这一组合下会产生不收敛的 SwiftUI transaction／AttributeGraph 工作和
大量小分配；`NSCollectionView` 每行嵌入 `NSHostingView` 并调用 `fittingSize` 也会把全表重测放大到
秒级。早期简单 fixture 对 `LazyVStack` 的正向结果不足以覆盖这些真实条件。

## 决策

播放状态的整个上下文侧栏由一个 `NSScrollView + NSCollectionView` 拥有纵向滚动链。上传者、简介、
分区／选集／分 P、评论 header、评论 thread 和分页 footer 都是原生 AppKit item，不在评论行或
section 中嵌入 `NSHostingView`。

- `PlaybackCommentsViewModel` 继续唯一拥有 subject、排序、主评论分页、楼中楼分页、并发上限、取消和
  generation；renderer 只消费主线程 presentation 并回送用户意图。
- 评论使用 AID 建立 `type=1` subject；同 BVID 的 CID 切换不重置评论，A → B、排序切换和 reset
  由 subject／generation 隔离迟到结果。
- diffable snapshot 使用稳定的 subject + root `CommentID`，不使用 index 身份。正文和回复正文使用
  可选择、不可编辑、不可独立滚动的 `NSTextView`／TextKit；已验证的视频链接由 text view delegate
  回送现有播放导航。成员提及与其他 `jump_url` 也只回送不透明 target：成员页由正整数 MID 生成
  B 站空间页，其他目标经公开 HTTPS 形状策略复核后才交给系统 `OpenURLAction`；App 不预取、不跟随
  重定向，也不向浏览器目标附加 Cookie。
- layout 高度缓存键为 item identity、宽度桶和内容 revision，容量上限为 2,048，使用 O(1) LRU。
  append 复用旧高度，只测新增或 revision 改变的 row；resize 先按宽度比例估算并恢复 RowID +
  relativeY，再以最多 32 行一批精测，新 resize 会取消旧批次。
- 只有 viewport 真正贴底时，append 才继续贴底；其余更新、楼中楼展开和 resize 均恢复语义 anchor。
- 评论头像消费当前评论 `member.avatar`，inline 自定义表情消费 `content.emote` 注解，正文图片消费
  `content.pictures`；三者都先映射为
  不透明资源引用，再由 `BiliAPI` adapter 在加载前验证精确 CDN 来源。渲染复用既有匿名、有界图片
  管线，不从不透明引用反推 URL，也不增加第二条图片网络链。头像保持固定行内尺寸；正文图片根据
  API 宽高元数据在最多 364 pt、4 pt 间距的有界流式布局中预先确定最多九张图片的 frame，图片本体
  保持 6 pt 圆角且没有外围卡片。缺失或无效元数据使用稳定占位，加载成功或失败都不改变行高。
  cell 离屏、复用和 teardown 时取消等待者。
- 正文图片点击只从 sidebar 回送当前评论的有效资源序列、所选位置与焦点恢复动作。`AppShellView`
  在当前窗口内容上呈现一个原生 AppKit 模态预览，不把预览嵌入 sidebar 的滚动链，也不创建新窗口、
  Quick Look 临时文件或第二条图片网络链。sidebar 与预览共用 `AppWindowOwner` 持有的匿名、有界图片
  管线；切换 BVID、返回来源页、关闭预览或关闭窗口时分别取消当前等待者并隔离迟到结果，用户关闭后
  将键盘焦点恢复到原图片按钮。

## 不采用

- `ScrollView + LazyVStack` 作为生产评论容器：已被真实长列表、TextKit 和 resize 证据推翻。
- `List`：曾出现 `NSTableView` delegate reentrancy 风险，且不能提供本边界所需的确定性 anchor 与
  分批测量控制。
- 每评论一层 `NSHostingView`：会重新引入全表 `fittingSize` 和 SwiftUI transaction 成本。
- 新增 `BiliCommentRendering`／Shared target：AppKit renderer 只有 App target 这一个真实调用方；
  domain、use case 与 ViewModel 已分别位于现有层级。

## 影响

原生 sidebar controller 的 snapshot、layout、focus、teardown 和 accessibility 职责增加，需要用
unit／renderer 契约与真人 VoiceOver、Full Keyboard Access、连续 resize 和真实网络分别验证。
build、AX tree 或合成性能数字不能替代这些证据。评论写入仍不在本决策范围。
