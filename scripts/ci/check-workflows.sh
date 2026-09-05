#!/bin/bash
# GitHub Actions のワークフロー(.github/workflows/*.yml)を actionlint で確かめる。
#
# actionlint はどの OS にも標準では入っていないので、無ければ飛ばす(CI は check.yml が
# 固定した版を入れてから呼ぶ)。手元で使うなら `brew install actionlint` するか、
# 環境変数 ACTIONLINT にバイナリのパスを入れる。shellcheck があれば run: の中身も見る。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

actionlint="${ACTIONLINT:-$(command -v actionlint || true)}"
if [ -z "$actionlint" ]; then
    note "actionlint が無いのでワークフローの検査は飛ばす"
    exit 0
fi

args=(-no-color)
if [ -n "${SHELLCHECK:-}" ]; then
    args+=(-shellcheck "$SHELLCHECK")
fi
if "$actionlint" "${args[@]}" .github/workflows/*.yml; then
    ok "actionlint: 指摘なし($(find .github/workflows -name "*.yml" | wc -l | tr -d " ") ファイル)"
else
    fail "actionlint が指摘を出した"
fi

finish
