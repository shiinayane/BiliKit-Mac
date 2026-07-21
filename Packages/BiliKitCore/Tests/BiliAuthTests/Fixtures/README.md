# BiliAuth 测试 fixture

本目录中的 JSON 全部由手工编写，内容不来自真实登录响应：

- 二维码 key 以 `FIXTURE_` 开头，URL 只包含无效的 fixture 查询。
- 不包含真实 Cookie、refresh token、用户身份或成功登录结果。
- `86101`、`86090` 与 `86038` 字段形状依据 2026-07-21 的现场响应核对。
- `code=0` 的字段、URL 主机/查询键名与 Cookie 名称依据 2026-07-21 的成功扫码响应核对，所有值均为 `FIXTURE_` 假值。
- `TOP_SECRET_SHOULD_NOT_REACH_DIAGNOSTICS` 是诊断泄漏测试哨兵，不是凭据。
