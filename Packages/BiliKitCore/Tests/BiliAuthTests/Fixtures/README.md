# BiliAuth 测试 fixture

本目录中的 JSON 全部由手工编写，内容不来自真实登录响应：

- TV 端扫码的 `auth_code` 用全零的 32 位十六进制，URL 只指向这个假码；其余值以 `FIXTURE_` 开头或是 `42` 这类假数。
- 不包含真实 Cookie、access token、refresh token、用户身份或成功登录结果。
- 取码响应、`86039` 未扫码与 `code=0` 成功响应的字段形状依据现场扫码核对：成功正文的键集合（含 `token_info`、`sso`、
  `hint`）、`cookie_info` 只有白名单的 5 个 Cookie、每个 Cookie 带 `http_only`／`expires`／`secure` 三个数字字段、
  `domains` 的 5 项均与现场一致；成功 fixture 另加一个 `unknown_cookie` 用来测白名单过滤，`secure` 的取值是假设。
- `86090` 与 `86038` 现场没有出现，沿用未扫码响应的形状（`data` 为 null）。
- `TOP_SECRET_SHOULD_NOT_REACH_DIAGNOSTICS` 是诊断泄漏测试哨兵，不是凭据。
