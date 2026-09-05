#!/bin/bash
# 改行コードが .gitattributes の約束どおりに保管されていることを確かめる。
#
# 既定は「リポジトリ内では LF」。Xcode が丸ごと書き戻すファイル(pbxproj / xcstrings /
# xcscheme / xcworkspacedata)は -text で Git に改行を触らせない。どれかが CRLF や混在で
# 入ると、次に Xcode が書き戻したときに全行差分になる。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# i/ はインデックス(リポジトリ側)の状態。crlf と mixed は不許可。
bad=$(git ls-files --eol | awk '$1 == "i/crlf" || $1 == "i/mixed" { print }' || true)
if [ -n "$bad" ]; then
    fail "CRLF または混在の改行がリポジトリに入っている:"
    printf '%s\n' "$bad" >&2
else
    ok "追跡ファイルに CRLF / 混在の改行は無い"
fi

untouched=$(git ls-files --eol -- '*.pbxproj' '*.xcstrings' '*.xcscheme' '*.xcworkspacedata' \
    | awk '$3 !~ /-text/ { print }' || true)
if [ -n "$untouched" ]; then
    fail "Xcode が書き戻すファイルに -text が付いていない:"
    printf '%s\n' "$untouched" >&2
else
    ok "Xcode が書き戻すファイルは -text"
fi

finish
