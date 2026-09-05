#!/bin/bash
# リポジトリの約束事の検査をまとめて走らせる。コミット前に手元で、CI では check.yml が呼ぶ。
#
#   scripts/ci/check-all.sh          # 通常
#   scripts/ci/check-all.sh v1.42    # タグを打つ前に、バージョンと CHANGELOG の見出しも確かめる
#
# 個々の検査は同じフォルダの check-*.sh(1 検査 1 ファイル)。単独でも実行できる。
# ビルドそのものは対象外(build.yml / Xcode で行う)。

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

tag="${1:-}"
failed=()

run() {
    local script=$1; shift
    printf '\n== %s ==\n' "$script"
    if ! "./$script" "$@"; then
        failed+=("$script")
    fi
}

run check-team-id.sh
run check-extensions.sh
run check-xcstrings.sh
run check-version.sh "$tag"
run check-package-pins.sh
run check-eol.sh
run check-docs-links.sh
run check-workflows.sh

printf '\n'
if [ "${#failed[@]}" -eq 0 ]; then
    echo "all checks passed"
else
    echo "failed: ${failed[*]}" >&2
    exit 1
fi
