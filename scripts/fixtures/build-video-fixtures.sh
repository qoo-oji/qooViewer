#!/bin/bash
# 動画のフィクスチャ(qooViewerTests/Fixtures/video/)を作り直す。
#
#   FFMPEG=/path/to/ffmpeg scripts/fixtures/build-video-fixtures.sh
#
# 手元でだけ走らせる(CI では走らせない)。ffmpeg の出力は版で変わるため、作り直したものは台帳(manifest.json)の
# sha256 ごとコミットする。build-fixtures.sh とは別にしてあるのは、ffmpeg が要るのがここだけだから
# (2026-09-29 に作ったときは ffmpeg 7.1。`pip install imageio-ffmpeg` の同梱のものを使った)。
#
# どれも ffmpeg のテスト用の絵(testsrc2)を数コマだけ入れた、縦横を読むためのファイル。名前が中身の縦横。
#   *-160x90    画素が正方形の 160×90
#   *-sar       144×96 の画素を 32:27 で見せる(表示は 16:9 = 171×96)
#   *-rot90     160×90 に 90° の回転の指定(表示は 90×160)
set -euo pipefail
cd "$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

FFMPEG=${FFMPEG:-/opt/homebrew/bin/ffmpeg}
[ -x "$FFMPEG" ] || { echo "見つからない: $FFMPEG(FFMPEG=… で指定する)" >&2; exit 1; }
OUT=$PWD/qooViewerTests/Fixtures/video
mkdir -p "$OUT"

# make NAME SIZE [ffmpeg の出力側の引数...]
make() {
    local name=$1 size=$2; shift 2
    "$FFMPEG" -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=$size:rate=10" -frames:v 3 -an \
        -map_metadata -1 -fflags +bitexact -flags:v +bitexact "$@" "$OUT/$name"
}
SAR=(-vf "setsar=32/27")

make h264-160x90.mp4 160x90 -c:v libx264 -pix_fmt yuv420p
make h264-sar.mp4 144x96 -c:v libx264 -pix_fmt yuv420p "${SAR[@]}"
make h264-160x90.mkv 160x90 -c:v libx264 -pix_fmt yuv420p
make h264-sar.mkv 144x96 -c:v libx264 -pix_fmt yuv420p "${SAR[@]}"
make mpeg4-160x90.avi 160x90 -c:v mpeg4
make mpeg4-sar.avi 144x96 -c:v mpeg4 "${SAR[@]}"
make wmv2-160x90.wmv 160x90 -c:v wmv2
make wmv2-sar.wmv 144x96 -c:v wmv2 "${SAR[@]}"
make flv1-160x90.flv 160x90 -c:v flv
make theora-160x90.ogv 160x90 -c:v libtheora -q:v 3
make theora-sar.ogv 144x96 -c:v libtheora -q:v 3 "${SAR[@]}"
# rv10 は縦横が 16 の倍数でなければならない。
make rv10-160x96.rm 160x96 -c:v rv10
# 回転の指定は入力側のオプションなので、作った mp4 を写し直して付ける。
"$FFMPEG" -hide_banner -loglevel error -y -display_rotation 90 -i "$OUT/h264-160x90.mp4" -an -c:v copy \
    -map_metadata -1 -fflags +bitexact "$OUT/h264-rot90.mp4"

python3 scripts/fixtures/update-manifest.py
