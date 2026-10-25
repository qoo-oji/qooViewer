#!/bin/bash
# 配布する qooViewer.app が、自動アップデート(Sparkle)と通信の約束を守っているかを確かめる。
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
if [[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]]; then
    ok "universal($archs)"
else
    fail "universal ではない: '$archs'(generic/platform=macOS で組む)"
fi

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
    # アプリ本体は通信しない。更新の取得は Sparkle の Downloader.xpc、StackNest の本の API への要求は
    # StackNestConnector.xpc の仕事(Info.plist のコメント・docs/10)。
    for key in com.apple.security.network.client com.apple.security.network.server; do
        if [ "$(ent "$key")" = "true" ]; then fail "アプリ本体に $key が付いている"; else ok "アプリ本体に $key は無い"; fi
    done
    names=$(ent com.apple.security.temporary-exception.mach-lookup.global-name)
    expected="[\"$bundle_id-spks\",\"$bundle_id-spki\"]"
    if [ "$names" = "$expected" ]; then
        ok "mach-lookup の例外は Sparkle の 2 つだけ: $names"
    else
        fail "mach-lookup の例外が '$names'(期待: $expected)"
    fi
fi

# ── ATS ───────────────────────────────────────────────────────────────────────
# アプリ本体は通信しないので、ATS の例外を一切持たない。
if plutil -extract NSAppTransportSecurity xml1 -o - "$info" >/dev/null 2>&1; then
    fail "アプリ本体の Info.plist に NSAppTransportSecurity がある(本体は通信しない)"
else
    ok "アプリ本体の Info.plist に NSAppTransportSecurity は無い"
fi

# ── StackNestConnector.xpc(StackNest の本の API への要求だけを出す。docs/10「StackNest の本と通信」)────────────
connector="$app/Contents/XPCServices/StackNestConnector.xpc"
connector_info="$connector/Contents/Info.plist"
if [ ! -d "$connector" ]; then
    fail "Contents/XPCServices/StackNestConnector.xpc が無い"
else
    connector_id=$(plutil -extract CFBundleIdentifier raw -o - "$connector_info" 2>/dev/null || true)
    service_name=$(value QOOStackNestConnectorService)
    if [ -n "$connector_id" ] && [ "$connector_id" = "$service_name" ] && [ "$connector_id" = "$bundle_id.StackNestConnector" ]; then
        ok "StackNestConnector のバンドル ID = QOOStackNestConnectorService = $connector_id"
    else
        fail "StackNestConnector のバンドル ID '$connector_id' が QOOStackNestConnectorService '$service_name'・'$bundle_id.StackNestConnector' と合わない"
    fi
    connector_archs=$(lipo -archs "$connector/Contents/MacOS/StackNestConnector" 2>/dev/null || true)
    if [[ " $connector_archs " == *" arm64 "* && " $connector_archs " == *" x86_64 "* ]]; then
        ok "StackNestConnector は universal($connector_archs)"
    else
        fail "StackNestConnector が universal ではない: '$connector_archs'"
    fi
    connector_entitlements=$(mktemp)
    if ! codesign -d --entitlements - --xml "$connector" > "$connector_entitlements" 2>/dev/null || [ ! -s "$connector_entitlements" ]; then
        fail "StackNestConnector の entitlements を読めない"
    else
        # 持ってよいのは App Sandbox と外への接続だけ(ファイル・待ち受け・その他の例外は持たない)。開発用の署名が足す
        # get-task-allow は数えない(本体と同じく、ここでは見ない)。
        keys=$(python3 -I -c 'import plistlib, sys
print(",".join(sorted(k for k in plistlib.load(open(sys.argv[1], "rb")) if k != "com.apple.security.get-task-allow")))' "$connector_entitlements")
        allowed="com.apple.security.app-sandbox,com.apple.security.network.client"
        if [ "$keys" = "$allowed" ]; then
            ok "StackNestConnector の entitlements は App Sandbox と外への接続だけ"
        else
            fail "StackNestConnector の entitlements が '$keys'(期待: $allowed)"
        fi
        values=$(python3 -I -c 'import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
print(d.get("com.apple.security.app-sandbox") is True and d.get("com.apple.security.network.client") is True)' "$connector_entitlements")
        if [ "$values" = "True" ]; then ok "StackNestConnector の App Sandbox と外への接続は true"; else fail "StackNestConnector の entitlements の値が true でない"; fi
    fi
    rm -f "$connector_entitlements"
    # ATS で許すのはローカルへの平文の HTTP だけ。
    ats=$(python3 -I -c 'import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb")).get("NSAppTransportSecurity")
print(sorted(d.items()) if isinstance(d, dict) else d)' "$connector_info")
    if [ "$ats" = "[('NSAllowsLocalNetworking', True)]" ]; then
        ok "StackNestConnector の ATS は NSAllowsLocalNetworking だけ"
    else
        fail "StackNestConnector の ATS が $ats(期待: NSAllowsLocalNetworking だけ)"
    fi
fi

# ── NetworkVolumeConnector.xpc(LAN の SMB サーバを探し、そのマウントを NetFS に頼むだけ。docs/10「ネットワークのサーバとボリュームの接続」)
netconn="$app/Contents/XPCServices/NetworkVolumeConnector.xpc"
netconn_info="$netconn/Contents/Info.plist"
if [ ! -d "$netconn" ]; then
    fail "Contents/XPCServices/NetworkVolumeConnector.xpc が無い"
else
    netconn_id=$(plutil -extract CFBundleIdentifier raw -o - "$netconn_info" 2>/dev/null || true)
    netconn_service=$(value QOONetworkVolumeConnectorService)
    if [ -n "$netconn_id" ] && [ "$netconn_id" = "$netconn_service" ] && [ "$netconn_id" = "$bundle_id.NetworkVolumeConnector" ]; then
        ok "NetworkVolumeConnector のバンドル ID = QOONetworkVolumeConnectorService = $netconn_id"
    else
        fail "NetworkVolumeConnector のバンドル ID '$netconn_id' が QOONetworkVolumeConnectorService '$netconn_service'・'$bundle_id.NetworkVolumeConnector' と合わない"
    fi
    netconn_archs=$(lipo -archs "$netconn/Contents/MacOS/NetworkVolumeConnector" 2>/dev/null || true)
    if [[ " $netconn_archs " == *" arm64 "* && " $netconn_archs " == *" x86_64 "* ]]; then
        ok "NetworkVolumeConnector は universal($netconn_archs)"
    else
        fail "NetworkVolumeConnector が universal ではない: '$netconn_archs'"
    fi
    netconn_entitlements=$(mktemp)
    if ! codesign -d --entitlements - --xml "$netconn" > "$netconn_entitlements" 2>/dev/null || [ ! -s "$netconn_entitlements" ]; then
        fail "NetworkVolumeConnector の entitlements を読めない"
    else
        # 持ってよいのは App Sandbox と外への接続だけ(StackNestConnector と同じ。get-task-allow は数えない)。
        keys=$(python3 -I -c 'import plistlib, sys
print(",".join(sorted(k for k in plistlib.load(open(sys.argv[1], "rb")) if k != "com.apple.security.get-task-allow")))' "$netconn_entitlements")
        allowed="com.apple.security.app-sandbox,com.apple.security.network.client"
        if [ "$keys" = "$allowed" ]; then
            ok "NetworkVolumeConnector の entitlements は App Sandbox と外への接続だけ"
        else
            fail "NetworkVolumeConnector の entitlements が '$keys'(期待: $allowed)"
        fi
        values=$(python3 -I -c 'import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
print(d.get("com.apple.security.app-sandbox") is True and d.get("com.apple.security.network.client") is True)' "$netconn_entitlements")
        if [ "$values" = "True" ]; then ok "NetworkVolumeConnector の App Sandbox と外への接続は true"; else fail "NetworkVolumeConnector の entitlements の値が true でない"; fi
    fi
    rm -f "$netconn_entitlements"
    # URLSession を使わないので ATS の例外は持たない。
    if plutil -extract NSAppTransportSecurity xml1 -o - "$netconn_info" >/dev/null 2>&1; then
        fail "NetworkVolumeConnector の Info.plist に NSAppTransportSecurity がある(URLSession は使わない)"
    else
        ok "NetworkVolumeConnector の Info.plist に NSAppTransportSecurity は無い"
    fi
fi

# 依存ライブラリのライセンス文(「qooViewer について」に出る。docs/11「ライセンス表記」)。配布物に表記を持たせるために入れている。
if [ -s "$app/Contents/Resources/Credits.rtf" ]; then ok "Credits.rtf(依存ライブラリのライセンス文)がある"; else fail "Credits.rtf が無い"; fi

# ── Sparkle.framework ─────────────────────────────────────────────────────────
sparkle="$app/Contents/Frameworks/Sparkle.framework"
for part in Versions/B/XPCServices/Installer.xpc Versions/B/XPCServices/Downloader.xpc Versions/B/Autoupdate Versions/B/Updater.app; do
    if [ -e "$sparkle/$part" ]; then ok "Sparkle.framework/$part がある"; else fail "Sparkle.framework/$part が無い"; fi
done
sparkle_version=$(plutil -extract CFBundleShortVersionString raw -o - "$sparkle/Resources/Info.plist" 2>/dev/null || true)
note "Sparkle $sparkle_version"
if codesign --verify --deep --strict "$app" 2>/dev/null; then
    ok "署名は有効(入れ子の Sparkle の部品・StackNestConnector・NetworkVolumeConnector を含む)"
else
    fail "codesign --verify --deep --strict が通らない"
fi

finish
