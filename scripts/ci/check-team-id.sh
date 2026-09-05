#!/bin/bash
# Apple Developer の Team ID がリポジトリに入っていないことを確かめる。
#
# docs/02「署名」: Team ID は gitignore 済みの Configurations/Local.xcconfig にだけ書く。
# Xcode の Signing & Capabilities で Team を選ぶと project.pbxproj に DEVELOPMENT_TEAM が
# 直接書き込まれ、うっかりコミットしてしまう事故が起きる ―― それをここで止める。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# コメント行(// …)は除く。Shared.xcconfig には説明として `DEVELOPMENT_TEAM = ABCDE12345` が
# 書いてあるが、それはコメントの中にある。
matches=$(git grep -nE '^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[A-Z0-9]{10}' -- \
    '*.pbxproj' '*.xcconfig' '*.xcscheme' '*.plist' '*.entitlements' || true)
if [ -n "$matches" ]; then
    fail "DEVELOPMENT_TEAM がリポジトリに入っている:"
    printf '%s\n' "$matches" >&2
else
    ok "追跡ファイルに DEVELOPMENT_TEAM の代入は無い"
fi

if git ls-files --error-unmatch Configurations/Local.xcconfig >/dev/null 2>&1; then
    fail "Configurations/Local.xcconfig が追跡されている(.gitignore の対象のはず)"
else
    ok "Configurations/Local.xcconfig は追跡されていない"
fi

finish
