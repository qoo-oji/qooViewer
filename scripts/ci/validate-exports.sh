#!/bin/bash
# qooViewer が書き出した EPUB / ComicInfo.xml を、外部の検品ツールにかける。
#
#   scripts/ci/validate-exports.sh <結果バンドル.xcresult>
#
# 素材は qooViewerTests の書き出しテスト(EpubExportTests / CbzExportTests)が**添付ファイルとして**
# 残した実物。テストは「読み込み側で開き直せること」までしか見られない ―― 自分の書いたものを
# 自分で読めるのは当たり前で、EPUB リーダーや Komga/Kavita が受け取れるかは別の話なので、
# 仕様に照らす役は外の実装(EPUBCheck / XSD)に任せる。
#
# 添付にしている理由(スキームの環境変数でも、シェルの環境変数でも、テストホストへは
# 渡らなかった)は qooViewerTests/Support/ExportHarness.swift の ExportArtifacts のコメント。
# 取り出したファイルの名前は Xcode が付け直す(テスト名 + 連番)ので、**拡張子で振り分ける**。
#
# 検品する道具:
#   - EPUB: EPUBCheck(W3C)。環境変数 EPUBCHECK_JAR に jar のパスを入れる。CI は
#     build.yml が sha256 を固定して取ってくる。手元で使うなら jar を落として
#     EPUBCHECK_JAR=… を渡す(java が要る。Kindle Previewer 3 に同梱の JRE でも動く)。
#   - ComicInfo.xml: ComicInfo v2.0 の XSD(qooViewerTests/Fixtures/comicinfo/、MIT)。
#     xmllint は macOS にも ubuntu にも最初から入っている。
#
# EPUBCHECK_JAR / xmllint / java が無ければ、その検品だけを飛ばす(検品できたものはする)。
# **素材が 1 つも取り出せなかったときは失敗にする** ―― 添付の仕組みが静かに壊れて
# 「0 件を検品して合格」になるのが、この手の検査で一番ありがちな壊れ方のため。
#
# 動くのは macOS の bash 3.2 でも同じ。空の配列を `set -u` の下で展開できないので、
# 件数を先に見てから触る。
original_pwd="$PWD"
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# lib.sh がリポジトリのルートへ移動するので、相対パスで渡された結果バンドルを先に絶対パスにする。
result_bundle="${1:-}"
case "$result_bundle" in
    ""|/*) ;;
    *) result_bundle="$original_pwd/$result_bundle" ;;
esac
if [ -z "$result_bundle" ]; then
    echo "usage: $0 <結果バンドル.xcresult>" >&2
    exit 2
fi
if [ ! -e "$result_bundle" ]; then
    fail "結果バンドルが無い: $result_bundle"
    finish
    exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# xcresulttool は「添付の無いテスト」を 1 件ずつ報告するので、通常の出力は捨てる。
if ! xcrun xcresulttool export attachments --path "$result_bundle" --output-path "$work" > "$work/export.log" 2>&1; then
    cat "$work/export.log" >&2
    fail "添付ファイルを取り出せなかった: $result_bundle"
    finish
    exit 1
fi

epubs=()
while IFS= read -r line; do epubs+=("$line"); done < <(find "$work" -name "*.epub" -type f | sort)
xmls=()
while IFS= read -r line; do xmls+=("$line"); done < <(find "$work" -name "*.xml" -type f ! -name "manifest.json" | sort)

if [ "${#epubs[@]}" -eq 0 ] && [ "${#xmls[@]}" -eq 0 ]; then
    fail "検品する素材が 1 つも無い(書き出しテストが添付を残していない)"
    finish
    exit 1
fi

# 添付は「どのテストのものか」を manifest.json が持っている。失敗したときに追えるよう、
# 取り出したファイル名 -> テスト名の対応を作っておく。
declare -a origin_keys=() origin_values=()
if [ -f "$work/manifest.json" ]; then
    while IFS=$'\t' read -r exported test_identifier; do
        origin_keys+=("$exported")
        origin_values+=("$test_identifier")
    done < <(python3 -c '
import json, sys
for test in json.load(open(sys.argv[1], encoding="utf-8")):
    for attachment in test.get("attachments", []):
        print(attachment.get("exportedFileName", ""), test.get("testIdentifier", "?"), sep="\t")
' "$work/manifest.json")
fi

origin_of() {
    local name index=0
    name=$(basename "$1")
    if [ "${#origin_keys[@]}" -eq 0 ]; then
        printf '%s' "$name"
        return
    fi
    for index in "${!origin_keys[@]}"; do
        if [ "${origin_keys[$index]}" = "$name" ]; then
            printf '%s' "${origin_values[$index]}"
            return
        fi
    done
    printf '%s' "$name"
}

# ---- EPUB: EPUBCheck ----------------------------------------------------------
if [ "${#epubs[@]}" -eq 0 ]; then
    note "EPUB の添付が無い"
elif [ -z "${EPUBCHECK_JAR:-}" ]; then
    note "EPUBCHECK_JAR が無いので EPUBCheck は飛ばす(${#epubs[@]} ファイル)"
elif ! command -v java > /dev/null; then
    note "java が無いので EPUBCheck は飛ばす(${#epubs[@]} ファイル)"
else
    epub_failures=0
    for epub in ${epubs[@]+"${epubs[@]}"}; do
        # --quiet でも警告・エラーは出る。何も出なければ指摘なし。
        if ! output=$(java -jar "$EPUBCHECK_JAR" --quiet "$epub" 2>&1) || [ -n "$output" ]; then
            fail "EPUBCheck: $(origin_of "$epub")"
            printf '%s\n' "$output" >&2
            epub_failures=$((epub_failures + 1))
        fi
    done
    if [ "$epub_failures" -eq 0 ]; then
        ok "EPUBCheck: 指摘なし(${#epubs[@]} ファイル)"
    fi
fi

# ---- ComicInfo.xml: XSD -------------------------------------------------------
schema="qooViewerTests/Fixtures/comicinfo/ComicInfo_v2.0.xsd"
if [ "${#xmls[@]}" -eq 0 ]; then
    note "ComicInfo.xml の添付が無い"
elif ! command -v xmllint > /dev/null; then
    note "xmllint が無いので ComicInfo の検査は飛ばす(${#xmls[@]} ファイル)"
elif [ ! -f "$schema" ]; then
    fail "スキーマが無い: $schema"
else
    xml_failures=0
    for xml in ${xmls[@]+"${xmls[@]}"}; do
        if ! output=$(xmllint --noout --schema "$schema" "$xml" 2>&1); then
            fail "ComicInfo v2.0 の XSD に合わない: $(origin_of "$xml")"
            printf '%s\n' "$output" >&2
            xml_failures=$((xml_failures + 1))
        fi
    done
    if [ "$xml_failures" -eq 0 ]; then
        ok "ComicInfo v2.0 の XSD: 指摘なし(${#xmls[@]} ファイル)"
    fi
fi

finish
