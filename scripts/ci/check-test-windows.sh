#!/bin/bash
# テストはウインドウを利用者の画面に出さない(2026-10-25。docs/02「テストのウインドウ」)。
#
# テストはアプリの中(TEST_HOST)で走るので、テストが出したウインドウ・シートはそのまま利用者の画面に出る。出ている長さは並行の
# 混み具合で変わり、手元の見張り(本物の確認ダイアログが出たらテストを止める)が試験用のウインドウを確認ダイアログと取り違えて
# 全テストを止めた。テストのウインドウ・シート・アラートは qooViewerTests/Support/TestWindows.swift(透明で、クリックを受けない)で
# 作り、出すのもそこ(`isShown:`)で行う。ここでは、それ以外の場所でウインドウ・アラートを作る・前へ出す書き方を断る。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

found=$(git ls-files 'qooViewerTests/*.swift' | grep -v '^qooViewerTests/Support/TestWindows\.swift$' | while read -r file; do
    awk -v file="$file" '
        { code = $0; sub(/^[ \t]+/, "", code) }
        code !~ /^\/\// && $0 ~ /(NSWindow|NSPanel|NSAlert)\(|\.orderFront(Regardless)?\(|\.makeKeyAndOrderFront\(/ {
            printf "%s:%d: %s\n", file, NR, code
        }
    ' "$file"
done)
if [ -n "$found" ]; then
    fail "テストでウインドウを直に作る・前へ出している。TestWindows.window(size:…, isShown:) / .panel(size:) / .alert(messageText:) を使う(利用者に見えないように作る):"
    printf '%s\n' "$found" >&2
else
    ok "テストのウインドウ・アラートはすべて TestWindows で見えないように作っている"
fi

finish
