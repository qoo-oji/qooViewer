#!/bin/bash
# コミットするフィクスチャ(qooViewerTests/Fixtures/)を作り直す。
#
#   scripts/fixtures/build-fixtures.sh
#
# 手元でだけ走らせる(CI では走らせない)。rar は GitHub のランナーに無く、7z/rar の出力は版で
# 変わるため、作り直したものは台帳(manifest.json)の sha256 ごとコミットする。台帳の更新は末尾で
# update-manifest.py が行う(howMade / purpose / book の記述は残す)。
#
# ページ画像は make-page-image.py(番号を色に埋めた 8x12 px の PNG)。書庫の中でページ番号が
# 重ならないよう、章ごとに番号をずらしてある(ch01 = 1〜3、ch02 = 4〜6 など)。書き出しの
# ラウンドトリップで「どのページがどこへ行ったか」を色で追うため。
#
# 使う道具: python3 / ditto / zip / xattr / sips(macOS 標準)、7zz と rar(Homebrew)。
set -euo pipefail
cd "$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

SCRIPTS=scripts/fixtures
OUT=$PWD/qooViewerTests/Fixtures
SEVENZIP=${SEVENZIP:-/opt/homebrew/bin/7zz}
RAR=${RAR:-/opt/homebrew/bin/rar}
for tool in "$SEVENZIP" "$RAR"; do
    [ -x "$tool" ] || { echo "見つからない: $tool" >&2; exit 1; }
done

WORK=$(mktemp -d -t qoo-fixtures)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"/{zip,7z,rar,nested,pdf}

# ── ページ画像 ───────────────────────────────────────────────────────────────
page()      { mkdir -p "$(dirname "$1")"; python3 "$SCRIPTS/make-page-image.py" "$@"; }  # page DEST NUMBER [--wide]
jpeg_page() {                                                             # jpeg_page DEST NUMBER
    page "$WORK/tmp-page.png" "$2"
    sips -s format jpeg -s formatOptions 90 "$WORK/tmp-page.png" --out "$1" > /dev/null
}
# pages DIR START COUNT [EXT]: DIR に 001.EXT〜 を COUNT 枚、番号は START から
pages() {
    local dir=$1 start=$2 count=$3 ext=${4:-png}
    mkdir -p "$dir"
    local i
    for ((i = 0; i < count; i++)); do
        local name; name=$(printf '%03d.%s' "$((i + 1))" "$ext")
        if [ "$ext" = jpg ]; then jpeg_page "$dir/$name" "$((start + i))"; else page "$dir/$name" "$((start + i))"; fi
    done
}

# ── 書庫を作る道具 ────────────────────────────────────────────────────────────
zip_cli()   { (cd "$2" && zip -q -r -X "$1" .); }                          # zip_cli OUT SRCDIR(ディレクトリエントリ付き・NFC)
zip_ditto() { (cd "$(dirname "$2")" && ditto -c -k --sequesterRsrc --keepParent "$(basename "$2")" "$1"); }
legacy_zip() { python3 "$SCRIPTS/make-legacy-zip.py" "$@"; }             # legacy_zip OUT [--truncate N] ENC:NAME=PATH...
sevenzip()  { local out=$1 src=$2; shift 2; (cd "$src" && "$SEVENZIP" a -bso0 -bsp0 "$@" "$out" ./*); }
rar_a()     { local out=$1 src=$2; shift 2; (cd "$src" && "$RAR" a -idq -r "$@" "$out" ./*); }
make_pdf()  { python3 "$SCRIPTS/make-pdf.py" "$@"; }

SRC=$WORK/src
mkdir -p "$SRC"

# ── zip ──────────────────────────────────────────────────────────────────────
# Finder の「圧縮」相当(ditto --sequesterRsrc)。拡張属性を付けたファイルは __MACOSX/._ に写る。
pages "$SRC/B_src" 1 3 jpg
xattr -w qoo.fixture 1 "$SRC/B_src"/*.jpg
zip_ditto "$OUT/zip/zip-ditto.cbz" "$SRC/B_src"

# Info-ZIP の zip(ディレクトリエントリを含む。フォルダごとにまとまる並びの確認にも使う)
pages "$SRC/zipcli/vol1" 1 2
pages "$SRC/zipcli/vol2" 3 2
page  "$SRC/zipcli/cover.png" 5
zip_cli "$OUT/zip/zip-zipcli.cbz" "$SRC/zipcli"

# 大文字小文字・アンダースコア・ハイフンの混在(1.37 の報告と同じ形。並び順の設定で並びが変わる本)
pages "$SRC/mixedcase" 1 3
legacy_zip "$OUT/zip/zip-mixed-case.cbz" \
    "utf8flag:_Cover.PNG=$SRC/mixedcase/001.png" \
    "utf8flag:Page_0001.png=$SRC/mixedcase/002.png" \
    "utf8flag:page-0002.png=$SRC/mixedcase/003.png"

# レガシーな文字コード(UTF-8 フラグ無し)。EntryNameDecoder の対象。
pages "$SRC/legacy" 1 3
legacy_zip "$OUT/zip/zip-cp932-noflag.zip" \
    "cp932:第1巻/001ページ.png=$SRC/legacy/001.png" \
    "cp932:第1巻/002ページ.png=$SRC/legacy/002.png" \
    "cp932:第1巻/表紙.png=$SRC/legacy/003.png"
legacy_zip "$OUT/zip/zip-cp932-short-names.zip" \
    "cp932:あ.png=$SRC/legacy/001.png" \
    "cp932:い.png=$SRC/legacy/002.png" \
    "cp932:う.png=$SRC/legacy/003.png"
legacy_zip "$OUT/zip/zip-eucjp-noflag.zip" \
    "euc_jp:第1巻/001ページ.png=$SRC/legacy/001.png" \
    "euc_jp:第1巻/002ページ.png=$SRC/legacy/002.png" \
    "euc_jp:第1巻/表紙.png=$SRC/legacy/003.png"
legacy_zip "$OUT/zip/zip-cp949-noflag.zip" \
    "cp949:제1권/001쪽.png=$SRC/legacy/001.png" \
    "cp949:제1권/002쪽.png=$SRC/legacy/002.png" \
    "cp949:제1권/표지.png=$SRC/legacy/003.png"
legacy_zip "$OUT/zip/zip-big5-noflag.zip" \
    "big5:第1卷/001頁.png=$SRC/legacy/001.png" \
    "big5:第1卷/002頁.png=$SRC/legacy/002.png" \
    "big5:第1卷/封面.png=$SRC/legacy/003.png"
legacy_zip "$OUT/zip/zip-utf8-noflag.zip" \
    "utf8:日本語/001.png=$SRC/legacy/001.png" \
    "utf8:日本語/002.png=$SRC/legacy/002.png" \
    "utf8:日本語/003.png=$SRC/legacy/003.png"
# 名前の頭に ASCII を付けてあるのは、正準順(localizedStandardCompare)がロケール依存だから ――
# 「日本語」と「第1巻」の前後は日本語ロケールと英語ロケールで入れ替わり、golden が CI で落ちた
# (2026-09-05)。並びを ASCII で決めておけば、確かめたいこと(両方の名前が正しく戻ること)は
# そのままにロケールに左右されなくなる。
legacy_zip "$OUT/zip/zip-mixed-utf8-cp932.zip" \
    "utf8flag:a-日本語/001.png=$SRC/legacy/001.png" \
    "cp932:b-第1巻/001ページ.png=$SRC/legacy/002.png" \
    "cp932:b-第1巻/002ページ.png=$SRC/legacy/003.png"
# 既知の限界: 1 つの書庫に CP932 と CP949 が混在すると一方に倒れる(docs/04)
legacy_zip "$OUT/zip/zip-mixed-cp932-cp949.zip" \
    "cp932:第1巻/001.png=$SRC/legacy/001.png" \
    "cp949:제1권/001.png=$SRC/legacy/002.png"
# 既知の限界: NFC と NFD で同名のエントリは後勝ちで 1 ページになる(zip-filename-unicode-normalization)
legacy_zip "$OUT/zip/zip-nfc-nfd-same-name.zip" \
    "utf8flag:001.png=$SRC/legacy/001.png" \
    $'utf8flag:\xe3\x81\x8c.png='"$SRC/legacy/002.png" \
    $'utf8flag:\xe3\x81\x8b\xe3\x82\x99.png='"$SRC/legacy/003.png"

# 壊れている・中身が無い
legacy_zip "$OUT/zip/zip-empty.cbz"
printf 'no images here\n' > "$SRC/readme.txt"
legacy_zip "$OUT/zip/zip-no-images.cbz" "utf8flag:readme.txt=$SRC/readme.txt"
legacy_zip "$OUT/zip/zip-truncated.cbz" --truncate 300 \
    "utf8flag:001.png=$SRC/legacy/001.png" \
    "utf8flag:002.png=$SRC/legacy/002.png" \
    "utf8flag:003.png=$SRC/legacy/003.png"
printf 'This is not a zip archive.\n' > "$OUT/zip/zip-not-a-zip.cbz"

# ── 7z ───────────────────────────────────────────────────────────────────────
pages "$SRC/7z-flat" 1 3 jpg
sevenzip "$OUT/7z/7z-flat.cb7" "$SRC/7z-flat" -ms=off
pages "$SRC/7z-solid" 1 5
sevenzip "$OUT/7z/7z-solid.cb7" "$SRC/7z-solid" -ms=on
sevenzip "$OUT/7z/7z-solid-lzma1.7z" "$SRC/7z-solid" -ms=on -m0=LZMA
sevenzip "$OUT/7z/7z-store.7z" "$SRC/7z-solid" -m0=Copy
pages "$SRC/7z-ja/第1巻" 1 3
sevenzip "$OUT/7z/7z-japanese-names.7z" "$SRC/7z-ja"
pages "$SRC/7z-dirs/vol1" 1 2
pages "$SRC/7z-dirs/vol2" 3 2
sevenzip "$OUT/7z/7z-with-dirs.cb7" "$SRC/7z-dirs"

# ── rar ──────────────────────────────────────────────────────────────────────
pages "$SRC/rar-flat" 1 3 jpg
rar_a "$OUT/rar/rar-flat.cbr" "$SRC/rar-flat" -ma5
# RAR4(-ma4)は rar 7.2x で作れなくなった(オプション自体が無い)。RAR4 の書庫は、実物が手に入った
# ときに手で置いて台帳に howMade を書く。
pages "$SRC/rar-solid" 1 5
rar_a "$OUT/rar/rar-solid.cbr" "$SRC/rar-solid" -ma5 -s
rar_a "$OUT/rar/rar-encrypted.cbr" "$SRC/rar-flat" -ma5 -phunter2
pages "$SRC/rar-ja/第1巻" 1 3
rar_a "$OUT/rar/rar-japanese-names.cbr" "$SRC/rar-ja" -ma5
pages "$SRC/rar-dirs/vol1" 1 2
pages "$SRC/rar-dirs/vol2" 3 2
rar_a "$OUT/rar/rar-with-dirs.cbr" "$SRC/rar-dirs" -ma5

# ── 入れ子の書庫 ─────────────────────────────────────────────────────────────
INNER=$WORK/inner
mkdir -p "$INNER"
pages "$SRC/ch01" 1 3
pages "$SRC/ch02" 4 3
zip_cli  "$INNER/ch01.cbz" "$SRC/ch01"
zip_cli  "$INNER/ch02.cbz" "$SRC/ch02"
sevenzip "$INNER/ch01.cb7" "$SRC/ch01"
sevenzip "$INNER/ch02.cb7" "$SRC/ch02"
rar_a    "$INNER/ch01.cbr" "$SRC/ch01" -ma5
rar_a    "$INNER/ch02.cbr" "$SRC/ch02" -ma5

nest() { # nest NAME FILES... : 中身をまとめた作業フォルダを返す
    local dir=$SRC/nest-$1; shift
    mkdir -p "$dir"
    cp "$@" "$dir/"
    echo "$dir"
}
zip_cli "$OUT/nested/nested-zip-in-zip.cbz" "$(nest zz "$INNER/ch01.cbz" "$INNER/ch02.cbz")"
zip_cli "$OUT/nested/nested-7z-in-zip.cbz"  "$(nest 7z "$INNER/ch01.cb7" "$INNER/ch02.cb7")"
zip_cli "$OUT/nested/nested-rar-in-zip.cbz" "$(nest rz "$INNER/ch01.cbr" "$INNER/ch02.cbr")"
sevenzip "$OUT/nested/nested-zip-in-7z.cb7" "$(nest z7 "$INNER/ch01.cbz" "$INNER/ch02.cbz")"
rar_a    "$OUT/nested/nested-zip-in-rar.cbr" "$(nest zr "$INNER/ch01.cbz" "$INNER/ch02.cbz")" -ma5

# 3 段(外側 1〜3 ページ + level2.cbz(4〜6 + level3.cbz(7〜8)))
pages "$SRC/level3" 7 2
zip_cli "$INNER/level3.cbz" "$SRC/level3"
pages "$SRC/level2" 4 3
cp "$INNER/level3.cbz" "$SRC/level2/"
zip_cli "$INNER/level2.cbz" "$SRC/level2"
pages "$SRC/depth3" 1 3
cp "$INNER/level2.cbz" "$SRC/depth3/"
zip_cli "$OUT/nested/nested-depth3.cbz" "$SRC/depth3"

# 直下の画像と書庫の同居
page "$SRC/loose/cover.png" 7
cp "$INNER/ch01.cbz" "$SRC/loose/"
zip_cli "$OUT/nested/nested-with-loose-pages.cbz" "$SRC/loose"

# サブフォルダの中の書庫(sortKey に chapters/ が付く)
mkdir -p "$SRC/subfolder/chapters"
cp "$INNER/ch01.cbz" "$INNER/ch02.cbz" "$SRC/subfolder/chapters/"
zip_cli "$OUT/nested/nested-in-subfolder.cbz" "$SRC/subfolder"

# 入れ子の中の __MACOSX(内側を ditto で作る)
pages "$SRC/inner-ditto/ch01" 1 3
xattr -w qoo.fixture 1 "$SRC/inner-ditto/ch01"/*.png
zip_ditto "$INNER/ch01-ditto.cbz" "$SRC/inner-ditto/ch01"
zip_cli "$OUT/nested/nested-appledouble-inside.cbz" "$(nest ad "$INNER/ch01-ditto.cbz")"

# 書庫の中に a.zip というファイルと a.zip/ というフォルダが同居(sortKey は一致し id は違う。docs/04)
page "$SRC/same/001.png" 2
legacy_zip "$OUT/nested/nested-same-name-file-and-folder.cbz" \
    "utf8flag:a.zip=$INNER/ch01.cbz" \
    "utf8flag:a.zip/001.png=$SRC/same/001.png"

# 壊れた内側の書庫は飛ばして、残りだけで本になる
legacy_zip "$INNER/broken.cbz" --truncate 300 \
    "utf8flag:001.png=$SRC/ch01/001.png" "utf8flag:002.png=$SRC/ch01/002.png" "utf8flag:003.png=$SRC/ch01/003.png"
zip_cli "$OUT/nested/nested-broken-inner.cbz" "$(nest broken "$INNER/broken.cbz" "$INNER/ch02.cbz")"

# ── PDF ──────────────────────────────────────────────────────────────────────
make_pdf "$OUT/pdf/pdf-r2l-twopageleft.pdf" --pages 3 --direction R2L --page-layout TwoPageLeft
make_pdf "$OUT/pdf/pdf-l2r-singlepage.pdf"  --pages 2 --direction L2R --page-layout SinglePage
make_pdf "$OUT/pdf/pdf-plain.pdf"           --pages 3
make_pdf "$OUT/pdf/pdf-outline.pdf"         --pages 4 --outline --title "テスト本" --author "作者" --keywords "fixture"

# ── 台帳 ─────────────────────────────────────────────────────────────────────
find "$OUT" -name .DS_Store -delete
python3 "$SCRIPTS/update-manifest.py"
