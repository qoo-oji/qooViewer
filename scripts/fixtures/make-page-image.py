#!/usr/bin/env python3
"""ページ画像(番号を色に埋めた単色 PNG)を書く。

テスト側の PageImageFactory(qooViewerTests/Support/PageImageFactory.swift)と同じ約束事:
    R = ページ番号(1〜255)、G = 0x66、B = 0x99
通常は 8x12 px、--wide なら 24x12 px(見開き判定で「横長」になるページ)。
外部ライブラリ無し(zlib だけ)。tIME 等の可変チャンクは書かないので、同じ引数なら同じバイト列になる。

    make-page-image.py OUT.png NUMBER [--wide]
"""
import struct
import sys
import zlib


def chunk(tag: bytes, data: bytes) -> bytes:
    body = tag + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


def png(width: int, height: int, rgb: bytes) -> bytes:
    row = b"\x00" + rgb * width  # フィルタ 0(None)
    raw = row * height
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)  # 8bit / truecolor
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__)
    out, number = argv[1], int(argv[2])
    if not 1 <= number <= 255:
        sys.exit("NUMBER は 1〜255")
    wide = "--wide" in argv[3:]
    data = png(24 if wide else 8, 12, bytes([number, 0x66, 0x99]))
    with open(out, "wb") as f:
        f.write(data)


if __name__ == "__main__":
    main(sys.argv)
