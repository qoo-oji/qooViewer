#!/bin/bash
# 蔵書のフォルダ名・ファイル名、個人の絶対パスがリポジトリに入っていないことを確かめる。
#
# 改善要望7の最重要事項(CLAUDE.md「個人情報の流出防止」)。本体は check-private-terms.py:
#   - 手元にある禁止語の一覧(リポジトリの外。scripts/dev/build-private-terms.py が作る)との一致
#   - `/Users/<名前>/…` `/Volumes/<ボリューム>/<フォルダ>…` の実在しそうな絶対パス(CI でも動く)
# に加えて、ここでは**一覧そのものが追跡されていない**ことを見る(check-team-id.sh の
# Local.xcconfig と同じ考え方)。git hook(scripts/git-hooks/)からは引数付きで同じ本体を呼ぶ。
# lib.sh がリポジトリのルートへ cd するので、本体の場所は先に絶対パスで控える。
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$script_dir/lib.sh"

tracked=$(git ls-files | grep -i -E 'private-terms.*\.txt$|\.local$' || true)
if [ -n "$tracked" ]; then
    fail "禁止語の一覧(またはローカル専用ファイル)が追跡されている:"
    printf '%s\n' "$tracked" >&2
else
    ok "禁止語の一覧・ローカル専用ファイルは追跡されていない"
fi

if python3 "$script_dir/check-private-terms.py" "$@"; then
    :
else
    fail "個人の名前・パスの検査に失敗した(上の FAIL 行)"
fi

finish
