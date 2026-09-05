#!/bin/bash
# scripts/ci/ の各検査が共有する小さな道具。各スクリプトの先頭で `source` する。
#
# 検査は 1 つにつき 1 ファイル。どれも「リポジトリの約束事(CLAUDE.md / docs)を機械で
# 確かめる」もので、テストターゲットの代わりではない。CI(.github/workflows/check.yml)と
# 手元(コミット前に `scripts/ci/check-all.sh`)で同じものが走る。使うのは macOS と
# ubuntu の両方に最初から入っている git / jq / python3 だけ。

set -euo pipefail

# リポジトリのルートへ移動する(どこから呼ばれても同じパスで書けるように)。
cd "$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

failures=0

ok()   { printf 'ok:   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }
note() { printf 'note: %s\n' "$*"; }

# 各スクリプトの末尾で呼ぶ。失敗が 1 つでもあれば非 0 で終わる。
finish() {
    if [ "$failures" -ne 0 ]; then
        exit 1
    fi
}
