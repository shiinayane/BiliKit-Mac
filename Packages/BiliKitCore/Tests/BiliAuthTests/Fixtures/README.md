# BiliAuth 测试 fixture

本目录中的 JSON 全部由手工编写，内容不来自真实登录响应：

- 二维码 key 以 `FIXTURE_` 开头，URL 只包含无效的 fixture 查询。
- 不包含真实 Cookie、refresh token、用户身份或成功登录结果。
- `86101` 字段形状依据 2026-07-21 的匿名现场响应核对。
- 未确认的扫码成功、已扫码未确认和过期状态不进入 fixture；人工验证后再补充全假值样本。
- `TOP_SECRET_SHOULD_NOT_REACH_DIAGNOSTICS` 是诊断泄漏测试哨兵，不是凭据。
