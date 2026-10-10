#!/bin/bash
# 公開したリリースを、利用者のアプリと同じ URL から取り直して確かめる(リリースの最後の手順。docs/02「リリース」)。
#
#   scripts/release/verify-published.sh vX.YY [手元の qooViewer.zip]
#
# - https://github.com/qoo-oji/qooViewer/releases/latest/download/appcast.xml(アプリの SUFeedURL)を取る
#   = そのリリースが「Latest」になっていて、appcast.xml が添付されていること
# - appcast の版が vX.YY で、ダウンロード先がそのタグの qooViewer.zip であること
# - appcast と zip の署名が、リポジトリの Info.plist の SUPublicEDKey で確かめられること(verify-update-signatures.swift)
# - 手元の zip を渡したら、公開した zip と同じバイト列であること
set -euo pipefail

repo=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
tag="${1:-}"
local_zip="${2:-}"
case "$tag" in v[0-9]*) ;; *) echo "usage: $0 vX.YY [path/to/qooViewer.zip]" >&2; exit 2 ;; esac
version="${tag#v}"
feed=$(plutil -extract SUFeedURL raw -o - "$repo/qooViewer/Info.plist")
key=$(plutil -extract SUPublicEDKey raw -o - "$repo/qooViewer/Info.plist")
expected_url="https://github.com/qoo-oji/qooViewer/releases/download/$tag/qooViewer.zip"

die() { echo "error: $*" >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

curl -fsSL --proto '=https' "$feed" -o "$work/appcast.xml" || die "appcast を取れない: $feed(Latest のリリースに appcast.xml が添付されているか)"
read -r got_version got_url < <(python3 -I - "$work/appcast.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
item = ET.parse(sys.argv[1]).getroot().find("./channel/item")
print(item.findtext("sparkle:version", namespaces=ns), item.find("enclosure").get("url"))
PY
)
[ "$got_version" = "$version" ] || die "Latest の appcast の版が $got_version(期待: $version)"
[ "$got_url" = "$expected_url" ] || die "ダウンロード先が $got_url(期待: $expected_url)"
echo "ok: Latest の appcast は ${version}、ダウンロード先 $got_url"

curl -fsSL --proto '=https' "$got_url" -o "$work/qooViewer.zip" || die "zip を取れない: $got_url"
xcrun swift "$repo/scripts/release/verify-update-signatures.swift" "$work/appcast.xml" "$work/qooViewer.zip" "$key" \
    || die "公開したものの署名が Info.plist の公開鍵で確かめられない"

if [ -n "$local_zip" ]; then
    a=$(shasum -a 256 "$local_zip" | cut -d' ' -f1)
    b=$(shasum -a 256 "$work/qooViewer.zip" | cut -d' ' -f1)
    [ "$a" = "$b" ] || die "公開した zip が手元の zip と違う"
    echo "ok: 公開した zip は手元の zip と同じ(SHA-256 $a)"
fi
echo "公開したリリース $tag は、利用者のアプリが受け付ける形になっている"
