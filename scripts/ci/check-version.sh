#!/bin/bash
# アプリのバージョン表記の整合を確かめる。
#
# - MARKETING_VERSION は project.pbxproj の Debug / Release 両方にあり、同じ値でなければ
#   ならない(CLAUDE.md)。Xcode の General タブで直すと両方変わるが、手で片方だけ直す事故がある。
# - CHANGELOG.md には常に `## [Unreleased]` がある(Keep a Changelog)。
# - 引数にタグ名(vX.YY)を渡したときは、MARKETING_VERSION = X.YY で、CHANGELOG に `## [X.YY]`
#   の見出しがあることも確かめる。CI はタグの push でこれを渡す(check.yml)。
#   手元では `scripts/ci/check-version.sh v1.42` のようにタグを打つ前に確かめられる。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

tag="${1:-}"

versions=$(grep -E '^[[:space:]]*MARKETING_VERSION = ' qooViewer.xcodeproj/project.pbxproj \
    | sed -E 's/.*= *([^;]+);.*/\1/' | sort -u)
count=$(printf '%s\n' "$versions" | grep -c . || true)
if [ "$count" -eq 1 ]; then
    ok "MARKETING_VERSION は全構成で $versions"
else
    fail "MARKETING_VERSION が構成ごとに違う: ${versions//$'\n'/ }"
fi

if grep -qE '^## \[Unreleased\]' CHANGELOG.md; then
    ok "CHANGELOG.md に [Unreleased] がある"
else
    fail "CHANGELOG.md に '## [Unreleased]' の見出しが無い"
fi

if [ -n "$tag" ]; then
    case "$tag" in
        v[0-9]*) version="${tag#v}" ;;
        *) fail "タグ名の形が vX.YY ではない: $tag"; finish ;;
    esac
    if [ "$versions" = "$version" ]; then
        ok "タグ $tag と MARKETING_VERSION が一致"
    else
        fail "タグ $tag に対して MARKETING_VERSION は $versions"
    fi
    if grep -qE "^## \[$(printf '%s' "$version" | sed 's/\./\\./g')\]" CHANGELOG.md; then
        ok "CHANGELOG.md に [$version] の見出しがある"
    else
        fail "CHANGELOG.md に '## [$version]' の見出しが無い"
    fi
fi

finish
