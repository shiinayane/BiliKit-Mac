#!/bin/sh

set -eu

# 从 stdin 读取变更路径：全部是 Markdown 时选 static，其余情况（含无变更）选 app。
awk 'NF { seen = 1; if ($0 !~ /\.md$/) other = 1 }
    END { print ((seen && !other) ? "static" : "app") }'
