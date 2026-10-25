#!/bin/bash
# テストの待ち方の約束を確かめる(2026-10-25 の CI の監査。docs/02「テストの待ち方」)。
#
# CI(3 vCPU の仮想マシンで、テストを 8 本ずつ並べて走らせる)では、手元では起きない遅れと順序が出る。そこで落ちていたのは
# 「起きたこと」を短い締め切りで待つテストだった(sleep の後に起きたことを確かめる・1〜5 秒で調べ続ける・Task.yield を数十回)。
# - 「成り立つまで待つ」は Support/Eventually.swift の `eventually` / `eventuallyHere` / `OneShotSignal.wait` を使い、締め切りは
#   `TestPatience.condition`(長い。成り立てばすぐ抜ける)。テストの中で短い締め切りを書かない。
# - それでも `Task.sleep` / `Task.yield` を書くときは、その行か直前の行に理由の印 `// 待ち: …` を付ける
#   (起きないこと・周回・時刻・間隔・見立て など)。印の無いものは、起きたことを時間で待っている疑いがある。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unmarked=$(git ls-files 'qooViewerTests/*.swift' | grep -v '^qooViewerTests/Support/Eventually\.swift$' | while read -r file; do
    awk -v file="$file" '
        { code = $0; sub(/^[ \t]+/, "", code) }
        code !~ /^\/\// && $0 ~ /Task\.(sleep|yield)\(/ && $0 !~ /\/\/ 待ち:/ && previous !~ /\/\/ 待ち:/ {
            printf "%s:%d: %s\n", file, NR, code
        }
        { previous = $0 }
    ' "$file"
done)
if [ -n "$unmarked" ]; then
    fail "テストの Task.sleep / Task.yield に理由の印(// 待ち: …)が無い。起きたことを待つなら eventually / eventuallyHere を使う:"
    printf '%s\n' "$unmarked" >&2
else
    ok "テストの Task.sleep / Task.yield にはすべて理由の印がある"
fi

# 締め切りを短く書いた待ち(TestPatience より短い秒数)。
short=$(git ls-files 'qooViewerTests/*.swift' | xargs grep -nE '(eventually|eventuallyHere|\.wait)\(timeout: *\.(milliseconds\(|seconds\(([0-9]|[12][0-9])\))' || true)
if [ -n "$short" ]; then
    fail "テストの待ちに短い締め切りを書いている(TestPatience.condition に任せる):"
    printf '%s\n' "$short" >&2
else
    ok "テストの待ちに短い締め切りは無い"
fi

finish
