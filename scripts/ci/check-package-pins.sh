#!/bin/bash
# Package.resolved のピンが、docs/11 の約束どおりになっていることを確かめる。
#
# フォーク 2 本(SevenZip.swift / Unrar.swift)は、作者のフォークの所定 branch を
# revision で固定している。うっかり本家に戻る・branch 名が変わる・revision が短縮形になる、
# といった事故をここで止める。revision そのものが取得できるかは build.yml が確かめる。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

file=qooViewer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

if ! jq empty "$file" 2>/dev/null; then
    fail "$file が JSON として読めない"
    finish
fi

expect_fork() {
    local identity=$1 location=$2 branch=$3
    local pin
    pin=$(jq -c --arg id "$identity" '.pins[] | select(.identity == $id)' "$file")
    if [ -z "$pin" ]; then
        fail "$identity が Package.resolved に無い"
        return
    fi
    local got_location got_branch got_revision
    got_location=$(jq -r '.location' <<<"$pin")
    got_branch=$(jq -r '.state.branch // ""' <<<"$pin")
    got_revision=$(jq -r '.state.revision // ""' <<<"$pin")
    if [ "$got_location" != "$location" ]; then
        fail "$identity の location が $got_location(期待: $location)"
    elif [ "$got_branch" != "$branch" ]; then
        fail "$identity の branch が '$got_branch'(期待: $branch)"
    elif ! [[ "$got_revision" =~ ^[0-9a-f]{40}$ ]]; then
        fail "$identity の revision が 40 桁の SHA ではない: '$got_revision'"
    else
        ok "$identity: $branch @ ${got_revision:0:10}"
    fi
}

expect_fork sevenzip.swift https://github.com/qoo-oji/SevenZip.swift streaming-extract
expect_fork unrar.swift    https://github.com/qoo-oji/Unrar.swift    memory-archive

zip_version=$(jq -r '.pins[] | select(.identity == "zipfoundation") | .state.version // ""' "$file")
if [ -n "$zip_version" ]; then
    ok "zipfoundation: version $zip_version"
else
    fail "zipfoundation が version で固定されていない"
fi

finish
