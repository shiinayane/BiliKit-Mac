# BiliAPI 测试 fixture

本目录中的 JSON 均为手写、脱敏的最小 contract fixture：

- 标识符、标题、详情、作者和统计数据为虚构值。
- 图片地址只使用 `example.invalid`；媒体地址必须通过生产 CDN allowlist，使用虚构的 `*.fixture.bilivideo.com`。
- 不包含 Cookie、token、WBI 签名、实时响应 body 或带签名媒体 URL。
- `uploader-card.json` 只包含虚构身份、自写签名与有效大会员状态，用于固定公开 card DTO 边界。
- `uploader-videos.json` 是 App 端空间投稿（`/x/v2/space/archive/cursor`）的形状，字段名、`has_next`、`next_cursor`、
  `order` 与条目的 `param`／`goto`／秒数时长依据匿名实测；条目值为虚构：`"--"` 隐藏统计、联合投稿、一条无效 BV、一条非
  稿件（`goto=live`）与一条缺发布时间的稿件，最后一条的 `param` 是下一批游标。
- `watchlater.json` 是稍后再看的最小形状：普通、已看完、分组占位行（`aid` 为 0）、番剧、只有 `pgc_label`
  的影视、整数形式的课程标记、已失效、字段不全的失效行（标题为空、`owner` 为 null、`add_at` 为 0）与课程行（作者名为空、缺时长与加入时间），以及只带 `redirect_url` 的普通条目，内容均为虚构值。
- `favorite-folders.json` 是自己创建的收藏夹列表的最小形状：默认公开夹、私密非默认夹、带其他 `attr` 位的公开夹，
  以及 `id` 为 0 与缺 `attr` 的两行，内容均为虚构值。
- `favorite-resources.json` 是收藏夹内一页的最小形状：普通视频（`http:` 封面）、仅自己可见、`attr` 标出与只靠标题识别的
  失效视频、合集与失效合集、音频、带分类名与空分类名的 `ogv`、未知类型，以及没有任何标识的一行，内容均为虚构值。
- 热门、详情、分 P、playurl、nav WBI key 与搜索字段形状依据 2026-07-21 的匿名接口响应重新核对，但内容不是线上响应副本。

M4 fixture 同样全部为手写假值：

- `subtitle-catalog.json`：单轨字幕目录，远端地址固定为 `example.invalid`。
- `subtitle-body.json`：两条虚构 cue，不来自任何线上字幕。
- `danmaku-segment-minimal.hex`：自制最小 protobuf wire 样本，只包含虚构标识和正文。
- `danmaku-segment-truncated.hex`：声明长度大于实际数据的截断输入。
- `m4-error.json` 与 `m4-error.html`：用于固定 JSON/HTML 错误页失败关闭。

空响应与超大响应由测试在内存中构造，避免提交没有语义的空文件或大体积 fixture。
