#!/bin/bash
# 配布する qooViewer.app が、自動アップデート(Sparkle)の約束を守っているかを確かめる。
#
#   scripts/release/check-release-app.sh path/to/qooViewer.app
#
# 約束の中身は qooViewer/Info.plist と Configurations/qooViewer.entitlements のコメント(docs/10「自動アップデート」)。
# アプリ自身も起動の前に同じことを確かめる(AppUpdater.swift の UpdaterConfiguration)が、そちらは約束が崩れていると
# 「黙って更新しない」だけなので、配る前にここで止める。CI の Release ジョブ(build.yml)と、
# scripts/release/make-appcast.sh(appcast を作る前)が呼ぶ。macOS 専用(codesign / plutil)。
source "$(dirname "${BASH_SOURCE[0]}")/../ci/lib.sh"

app="${1:-}"
if [ -z "$app" ] || [ ! -d "$app" ]; then
    echo "usage: $0 path/to/qooViewer.app" >&2
    exit 2
fi
case "$app" in /*) ;; *) app="$OLDPWD/$app" ;; esac  # lib.sh がリポジトリのルートへ移動するため
info="$app/Contents/Info.plist"

# Info.plist の値(無ければ空)。
value() { plutil -extract "$1" raw -o - "$info" 2>/dev/null || true; }
expect_value() {
    local key=$1 want=$2 got
    got=$(value "$key")
    if [ "$got" = "$want" ]; then ok "$key = $want"; else fail "$key が '$got'(期待: $want)"; fi
}

# ── Info.plist ────────────────────────────────────────────────────────────────
expect_value QOOUpdaterEnabled YES
expect_value SUVerifyUpdateBeforeExtraction true
expect_value SURequireSignedFeed true
expect_value SUSignedFeedFailureExpirationInterval 0
expect_value SUEnableInstallerLauncherService true
expect_value SUEnableDownloaderService true
for key in SUEnableSystemProfiling SUEnableJavaScript; do
    got=$(value "$key")
    if [ "$got" = "true" ]; then fail "$key が true(Mac の情報を送る・スクリプトを動かす)"; else ok "$key は ON でない"; fi
done

feed=$(value SUFeedURL)
case "$feed" in
    https://*@*) fail "SUFeedURL に利用者名かパスワードが入っている" ;;
    https://?*) ok "SUFeedURL は HTTPS: $feed" ;;
    *) fail "SUFeedURL が HTTPS ではない: '$feed'" ;;
esac

key=$(value SUPublicEDKey)
key_bytes=$(printf '%s' "$key" | base64 -D 2>/dev/null | wc -c | tr -d ' ' || true)
if [ -z "$key" ]; then
    fail "SUPublicEDKey が空(generate_keys の公開鍵を Info.plist へ入れる。docs/02「リリース」)"
elif [ "$key_bytes" != "32" ]; then
    fail "SUPublicEDKey が base64 の 32 バイトではない($key_bytes バイト)"
else
    ok "SUPublicEDKey は Ed25519 の公開鍵の形"
fi

short=$(value CFBundleShortVersionString)
build=$(value CFBundleVersion)
if [ -n "$short" ] && [ "$short" = "$build" ]; then
    ok "CFBundleVersion = CFBundleShortVersionString = $short(Sparkle はこれで新旧を比べる)"
else
    fail "CFBundleVersion '$build' が CFBundleShortVersionString '$short' と違う"
fi

# generate_appcast は書庫の .app のアーキテクチャから sparkle:hardwareRequirements を決める。arm64 だけで組んだ
# zip を配ると、Intel の Mac には以後アップデートが届かない。
archs=$(lipo -archs "$app/Contents/MacOS/qooViewer" 2>/dev/null || true)
case " $archs " in
    *" arm64 "*" x86_64 "*|*" x86_64 "*" arm64 "*) ok "universal(arm64 + x86_64)" ;;
    *) fail "universal ではない: '$archs'(generic/platform=macOS で組む)" ;;
esac

# ── entitlements ──────────────────────────────────────────────────────────────
bundle_id=$(value CFBundleIdentifier)
entitlements=$(mktemp)
trap 'rm -f "$entitlements"' EXIT
if ! codesign -d --entitlements - --xml "$app" > "$entitlements" 2>/dev/null || [ ! -s "$entitlements" ]; then
    fail "entitlements を読めない(署名されていない?)"
else
    # キーに「.」が入るので plutil -extract(「.」を階層の区切りと読む)ではなく plistlib で読む。
    ent() {
        python3 -I -c 'import json, plistlib, sys
v = plistlib.load(open(sys.argv[1], "rb")).get(sys.argv[2])
print("" if v is None else json.dumps(v, separators=(",", ":")) if isinstance(v, list) else str(v).lower())' "$entitlements" "$1"
    }
    if [ "$(ent com.apple.security.app-sandbox)" = "true" ]; then ok "App Sandbox が有効"; else fail "App Sandbox が無効"; fi
    # アプリ本体は通信しない。更新の取得は Sparkle の Downloader.xpc の仕事(Info.plist のコメント)。
    if [ "$(ent com.apple.security.network.client)" = "true" ]; then
        fail "アプリ本体に com.apple.security.network.client が付いている"
    else
        ok "アプリ本体に通信の entitlement は無い"
    fi
    names=$(ent com.apple.security.temporary-exception.mach-lookup.global-name)
    expected="[\"$bundle_id-spks\",\"$bundle_id-spki\"]"
    if [ "$names" = "$expected" ]; then
        ok "mach-lookup の例外は Sparkle の 2 つだけ: $names"
    else
        fail "mach-lookup の例外が '$names'(期待: $expected)"
    fi
fi

# ── Sparkle.framework ─────────────────────────────────────────────────────────
sparkle="$app/Contents/Frameworks/Sparkle.framework"
for part in Versions/B/XPCServices/Installer.xpc Versions/B/XPCServices/Downloader.xpc Versions/B/Autoupdate Versions/B/Updater.app; do
    if [ -e "$sparkle/$part" ]; then ok "Sparkle.framework/$part がある"; else fail "Sparkle.framework/$part が無い"; fi
done
sparkle_version=$(plutil -extract CFBundleShortVersionString raw -o - "$sparkle/Resources/Info.plist" 2>/dev/null || true)
note "Sparkle $sparkle_version"
if codesign --verify --deep --strict "$app" 2>/dev/null; then
    ok "署名は有効(入れ子の Sparkle の部品を含む)"
else
    fail "codesign --verify --deep --strict が通らない"
fi

finish
