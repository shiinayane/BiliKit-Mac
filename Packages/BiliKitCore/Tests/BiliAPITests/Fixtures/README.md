# BiliAPI 测试 fixture

本目录中的 JSON 均为手写、脱敏的最小 contract fixture：

- 标识符、标题、详情、作者和统计数据为虚构值。
- 图片与媒体地址只使用 `example.invalid`。
- 不包含 Cookie、token、WBI 签名、实时响应 body 或带签名媒体 URL。
- 热门、详情、分 P、playurl、nav WBI key 与搜索字段形状依据 2026-07-21 的匿名接口响应重新核对，但内容不是线上响应副本。

M4 fixture 同样全部为手写假值：

- `subtitle-catalog.json`：单轨字幕目录，远端地址固定为 `example.invalid`。
- `subtitle-body.json`：两条虚构 cue，不来自任何线上字幕。
- `danmaku-segment-minimal.hex`：自制最小 protobuf wire 样本，只包含虚构标识和正文。
- `danmaku-segment-truncated.hex`：声明长度大于实际数据的截断输入。
- `m4-error.json` 与 `m4-error.html`：用于固定 JSON/HTML 错误页失败关闭。

空响应与超大响应由测试在内存中构造，避免提交没有语义的空文件或大体积 fixture。
