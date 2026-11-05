#!/bin/sh

set -eu

pattern='(qrcode_key.{0,32}[=:][^[:space:]]*[A-Za-z0-9_-]{24,}|auth_code.{0,32}[=:][^[:space:]]*[A-Fa-f0-9]{32}|access_token.{0,16}[=:][^[:space:]]*[A-Za-z0-9_-]{20,}|SESSDATA=[A-Za-z0-9%_-]{20,}|bili_jct=[A-Fa-f0-9]{32}|refresh_token.{0,16}[=:][^[:space:]]*[A-Za-z0-9_-]{20,})'

matches="$(
    git grep --untracked -n -E "$pattern" -- . ':!Scripts/check-secrets.sh' 2>/dev/null \
        | grep -v -E 'FIXTURE|<redacted>|TOP_SECRET_SHOULD_NOT_REACH_DIAGNOSTICS|0{32}' \
        || true
)"

if [ -n "$matches" ]; then
    echo "秘密模式检查失败：发现疑似二维码 key、auth_code、Cookie、access token 或 refresh token 值" >&2
    echo "$matches" >&2
    exit 1
fi

echo "秘密模式检查通过"
