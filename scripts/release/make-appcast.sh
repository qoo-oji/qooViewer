#!/bin/bash
# 配布する zip から、Sparkle の appcast.xml(更新情報)を作って署名する。手元専用(秘密鍵はキーチェーンにある)。
#
#   scripts/release/make-appcast.sh path/to/qooViewer.zip [出力先フォルダ]
#
# 手順の全体は docs/02「リリース」。このスクリプトは**アップロードしない**(出来上がった appcast.xml を確かめてから、
# 表示されるコマンドで自分で上げる)。
#
# やること:
#   1. zip の中の qooViewer.app を check-release-app.sh にかける(署名の確かめを緩めた・鍵の無いビルドを配らない)
#   2. アプリの SUPublicEDKey が、キーチェーンにある秘密鍵の公開鍵と一致することを確かめる
#      (別の鍵で署名すると、今の利用者のアプリはこの更新を受け付けない)
#   3. CHANGELOG.md の `## [X.YY]` をリリースノートとして埋め込み、generate_appcast で appcast を作る
#      (書庫の EdDSA 署名と、appcast そのものの署名。アプリが SURequireSignedFeed を求めるので後者も付く)
#   4. 出来た appcast の署名・版・ダウンロード先を確かめる
#
# 環境変数:
#   SPARKLE_BIN          Sparkle の道具(generate_appcast / generate_keys / sign_update)のフォルダ。
#                        省略時は Xcode の DerivedData から、Package.resolved で固定した版のものを探す。
#   SPARKLE_KEY_ACCOUNT  キーチェーンの鍵のアカウント名(既定: generate_keys の既定の ed25519)
#   SPARKLE_ED_KEY_FILE  キーチェーンの代わりに秘密鍵のファイルを使う(generate_keys -x で書き出したもの)。
#                        **リポジトリの中のファイルは拒む**(うっかりコミットしないため)。
set -euo pipefail

repo=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
zip="${1:-}"
out="${2:-}"
if [ -z "$zip" ] || [ ! -f "$zip" ]; then
    echo "usage: $0 path/to/qooViewer.zip [output-dir]" >&2
    exit 2
fi
zip=$(cd "$(dirname "$zip")" && pwd)/$(basename "$zip")
# appcast のダウンロード先はリリースの添付ファイルの名前で決まる(…/download/vX.YY/qooViewer.zip)。
[ "$(basename "$zip")" = "qooViewer.zip" ] || { echo "error: zip の名前は qooViewer.zip にする(リリースの添付ファイル名)" >&2; exit 2; }
out=${out:-$(dirname "$zip")}
mkdir -p "$out"
out=$(cd "$out" && pwd)
account="${SPARKLE_KEY_ACCOUNT:-ed25519}"
key_file="${SPARKLE_ED_KEY_FILE:-}"
repo_url="https://github.com/qoo-oji/qooViewer"

die() { echo "error: $*" >&2; exit 1; }

# 署名の鍵の渡し方(generate_appcast / sign_update 共通)。
if [ -n "$key_file" ]; then
    [ -f "$key_file" ] || die "SPARKLE_ED_KEY_FILE が無い: $key_file"
    key_file=$(cd "$(dirname "$key_file")" && pwd -P)/$(basename "$key_file")
    case "$key_file" in
        "$(cd "$repo" && pwd -P)"/*) die "秘密鍵のファイルがリポジトリの中にある。外へ移す(コミットすると誰でも更新を偽造できる)" ;;
    esac
    key_args=(--ed-key-file "$key_file")
else
    key_args=(--account "$account")
fi

# ── Sparkle の道具 ────────────────────────────────────────────────────────────
pinned=$(jq -r '.pins[] | select(.identity == "sparkle") | .state.version' \
    "$repo/qooViewer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
if [ -z "${SPARKLE_BIN:-}" ]; then
    for dir in "$HOME"/Library/Developer/Xcode/DerivedData/qooViewer-*/SourcePackages; do
        [ -x "$dir/artifacts/sparkle/Sparkle/bin/generate_appcast" ] || continue
        # その DerivedData が固定した版を取ってきたものか(古いビルドの残りを使わない)。
        got=$(git -C "$dir/checkouts/Sparkle" describe --tags --exact-match 2>/dev/null || true)
        if [ "$got" = "$pinned" ]; then SPARKLE_BIN="$dir/artifacts/sparkle/Sparkle/bin"; break; fi
    done
fi
[ -n "${SPARKLE_BIN:-}" ] && [ -x "$SPARKLE_BIN/generate_appcast" ] \
    || die "Sparkle $pinned の道具が見つからない。Xcode で一度ビルドするか、SPARKLE_BIN を指定する"
echo "Sparkle tools: $SPARKLE_BIN (pinned $pinned)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# ── 1. 配る .app を確かめる ──────────────────────────────────────────────────
mkdir "$work/extracted"
ditto -x -k "$zip" "$work/extracted"
app="$work/extracted/qooViewer.app"
[ -d "$app" ] || die "zip の最上位に qooViewer.app が無い(ditto -c -k --keepParent で作る)"
"$repo/scripts/release/check-release-app.sh" "$app" || die "check-release-app.sh が通らない"

version=$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")
tag="v$version"
app_key=$(plutil -extract SUPublicEDKey raw -o - "$app/Contents/Info.plist")

# ── 2. 鍵の一致 ──────────────────────────────────────────────────────────────
# 別の鍵で署名した更新は、利用者のアプリが受け付けない。キーチェーンなら先に公開鍵を比べる(初回は許可のダイアログが
# 出る。-p は公開鍵だけを表示する)。鍵ファイルのときは公開鍵を取り出す手段が無いので、4 で署名をアプリの鍵で確かめて分かる。
if [ -z "$key_file" ]; then
    keychain_key=$("$SPARKLE_BIN/generate_keys" --account "$account" -p) || die "キーチェーンに鍵(アカウント $account)が無い"
    [ "$keychain_key" = "$app_key" ] \
        || die "アプリの SUPublicEDKey とキーチェーンの鍵(アカウント $account)が違う。この鍵で署名した更新は、利用者のアプリが受け付けない"
    echo "ok: SUPublicEDKey はキーチェーンの鍵と一致"
fi

# ── 3. appcast を作る ────────────────────────────────────────────────────────
grep -qE "^## \[${version//./\\.}\]" "$repo/CHANGELOG.md" || die "CHANGELOG.md に ## [$version] が無い"
mkdir "$work/archives"
cp "$zip" "$work/archives/qooViewer.zip"
# CHANGELOG の該当の節(見出しの次の行から、次の ## の前まで)。generate_appcast は同じ名前の .md をリリースノートにする。
awk -v head="## [$version]" '
    index($0, head) == 1 { on = 1; next }
    on && /^## \[/ { exit }
    on { print }
' "$repo/CHANGELOG.md" > "$work/archives/qooViewer.md"
[ -s "$work/archives/qooViewer.md" ] || die "CHANGELOG.md の ## [$version] が空"

"$SPARKLE_BIN/generate_appcast" \
    "${key_args[@]}" \
    --download-url-prefix "$repo_url/releases/download/$tag/" \
    --embed-release-notes \
    --maximum-deltas 0 \
    --link "$repo_url/releases" \
    "$work/archives"

appcast="$work/archives/appcast.xml"
[ -f "$appcast" ] || die "appcast.xml ができていない"

# ── 4. 出来たものを確かめる ──────────────────────────────────────────────────
"$SPARKLE_BIN/sign_update" "${key_args[@]}" --verify "$appcast" || die "appcast の署名を確かめられない"
# 利用者のアプリが実際に使う鍵(配る .app の SUPublicEDKey)で、Sparkle とは別の実装で確かめ直す。
xcrun swift "$repo/scripts/release/verify-update-signatures.swift" "$appcast" "$work/archives/qooViewer.zip" "$app_key" \
    || die "appcast か書庫の署名が、アプリの公開鍵で確かめられない"
python3 -I - "$appcast" "$version" "$repo_url/releases/download/$tag/qooViewer.zip" <<'PY' || die "appcast の中身が期待と違う"
import sys
import xml.etree.ElementTree as ET
path, version, url = sys.argv[1:]
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
items = ET.parse(path).getroot().findall("./channel/item")
assert len(items) == 1, f"item が {len(items)} 個"
item = items[0]
assert item.findtext("sparkle:version", namespaces=ns) == version, "sparkle:version が違う"
enclosure = item.find("enclosure")
assert enclosure is not None, "enclosure が無い"
assert enclosure.get("url") == url, f"ダウンロード先が {enclosure.get('url')}"
assert enclosure.get("{%s}edSignature" % ns["sparkle"]), "書庫の EdDSA 署名が無い"
assert item.find("sparkle:releaseNotesLink", ns) is None, "リリースノートが埋め込みになっていない"
print(f"ok: appcast の item は {version} の 1 つ、ダウンロード先 {url}、署名あり")
PY

cp "$appcast" "$out/appcast.xml"
cat <<EOF

appcast.xml: $out/appcast.xml

確かめたら、リリース $tag に zip と一緒に上げる(このリリースが「Latest」であること —— アプリは
$repo_url/releases/latest/download/appcast.xml を読む):

    gh release upload $tag "$zip" "$out/appcast.xml"

上げた後は appcast.xml を書き換えないこと(署名が合わなくなり、アプリは更新を受け付けない)。
EOF
