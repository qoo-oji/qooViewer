#!/bin/bash
# Localizable.xcstrings(String Catalog)が壊れていないことを確かめ、翻訳の抜けを数える。
#
# Xcode はこのファイルを丸ごと書き戻す(.gitattributes で merge=binary にしている理由)。
# 衝突の手直しなどで JSON として壊れると、全文言が英語に戻るだけで、ビルドは通ってしまう。
# `plutil -lint` は plist 用で JSON を読めないため jq で確かめる。
#
# 未訳・stale の件数は報告だけで落とさない(2026-09-05 時点: 未訳 3 / stale 6)。
# 0 になったら「増えたら落とす」に変える。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

file=qooViewer/Resources/Localizable.xcstrings

if ! jq empty "$file" 2>/dev/null; then
    fail "$file が JSON として読めない"
    finish
fi
ok "$file は JSON として妥当"

source_language=$(jq -r '.sourceLanguage' "$file")
if [ "$source_language" != "en" ]; then
    fail "sourceLanguage が en ではない: $source_language"
fi

missing=$(jq '[.strings | to_entries[]
    | select(.value.shouldTranslate != false)
    | select(.value.localizations.ja == null)] | length' "$file")
stale=$(jq '[.strings | to_entries[] | select(.value.extractionState == "stale")] | length' "$file")
translated=$(jq '[.strings | to_entries[] | select(.value.localizations.ja.stringUnit.state == "translated")] | length' "$file")
note "ja: 訳済 $translated / 未訳 $missing / stale $stale"

finish
