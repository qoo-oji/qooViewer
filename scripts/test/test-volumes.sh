#!/bin/sh
# テスト用の使い捨てボリュームを付ける/外す(改善要望7 段階 2、2026-09-13)。
#
#   scripts/test/test-volumes.sh attach   # テストの前(スキームの Test の Pre-action から呼ばれる)
#   scripts/test/test-volumes.sh detach   # テストの後(Post-action)
#
# なぜテストの外で付けるのか: テストはサンドボックスに入ったアプリの中(TEST_HOST)で走り、そこから起動した
# hdiutil はサンドボックスに止められる(実測: `hdiutil: create failed - 装置が構成されていません`、カーネルの
# ログに `deny(1) mach-lookup com.apple.system.hdiejectd.xpc`)。一方、外で付けたボリュームへはテストから
# 読み書きできる(実測)。そこでスキームの前後の処理で付け外しし、テストは決まった名前で探す
# (qooViewerTests/Support/TestVolume.swift)。
#
# 付けるボリューム(どれも -nobrowse。Finder のサイドバーにもデスクトップにも出ない):
#   /Volumes/qooViewerTest-apfs   APFS 128MB  別ボリュームへの移動・実コピー
#   /Volumes/qooViewerTest-exfat  exFAT 64MB  renamex_np(RENAME_EXCL) が ENOTSUP を返す形式(実測)
#   /Volumes/qooViewerTest-fat32  FAT32 64MB  1 ファイル 4GB 弱の上限
#   /Volumes/qooViewerTest-tiny   APFS 20MB   空き容量の事前検査
#
# 前の実行が落ちて残ったものは attach の最初に外す。イメージは $TMPDIR の下に置き、detach で消す。
set -u

base="${TMPDIR:-/tmp}/qooViewerTestVolumes"
names="apfs exfat fat32 tiny"

detach_all() {
    for name in $names; do
        mount_point="/Volumes/qooViewerTest-$name"
        if mount | grep -q " on $mount_point ("; then
            hdiutil detach -quiet "$mount_point" >/dev/null 2>&1 || hdiutil detach -quiet -force "$mount_point" >/dev/null 2>&1
        fi
    done
    rm -rf "$base"
}

# attach_one <名前> <hdiutil -fs の形式> <MB>
attach_one() {
    image="$base/$1.dmg"
    mount_point="/Volumes/qooViewerTest-$1"
    if ! hdiutil create -quiet -size "$3m" -fs "$2" -volname "QVT$1" "$image"; then
        echo "test-volumes: could not create $1 ($2)" >&2
        return
    fi
    hdiutil attach -quiet -nobrowse -mountpoint "$mount_point" "$image" || echo "test-volumes: could not attach $1" >&2
}

attach_all() {
    detach_all
    mkdir -p "$base"
    attach_one apfs "APFS" 128
    attach_one exfat "ExFAT" 64
    attach_one fat32 "MS-DOS FAT32" 64
    attach_one tiny "APFS" 20
}

case "${1:-}" in
    attach) attach_all ;;
    detach) detach_all ;;
    *) echo "usage: $0 attach|detach" >&2; exit 2 ;;
esac
