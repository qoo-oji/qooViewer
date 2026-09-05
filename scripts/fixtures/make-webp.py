#!/usr/bin/env python3
"""単色のページ画像を、可逆(VP8L)の WebP として書く。

    make-webp.py DEST NUMBER [--wide]

make-page-image.py と同じ約束事 ―― R = ページ番号、G = 0x66、B = 0x99、通常 8x12 px、
横長は 24x12 px。

■ なぜ自前で書くのか
macOS には WebP の**エンコーダ**が無い(ImageIO の書き出し形式にも `sips --formats` の
Writable にも WebP は無く、cwebp も標準では入っていない)。一方 qooViewer は webp を
`imageExtensions` に入れているので、ImageDecoder の回帰には本物の WebP が要る。

■ どう書いているか
可逆 WebP(VP8L)は、5 つのハフマン木(緑・赤・青・アルファ・距離)をそれぞれ
「記号が 1 つだけの単純符号」にできる。記号が 1 つの木は 1 記号あたり 0 ビットを消費するため、
**単色の画像なら画素のデータが 1 ビットも要らない**。ヘッダーと 5 つの符号定義だけで
1 枚の画像になる(この方法で作ったファイルは 32 バイト)。
仕様は WebP Lossless Bitstream Specification の "5.2 Decoding of Meta Prefix Codes" ほか。
"""
import struct
import sys

WIDTH = 8
WIDE_WIDTH = 24
HEIGHT = 12
GREEN = 0x66
BLUE = 0x99


class BitWriter:
    """VP8L のビットストリームは、各バイトの下位ビットから詰めていく。"""

    def __init__(self):
        self.bits = []

    def put(self, value, count):
        for index in range(count):
            self.bits.append((value >> index) & 1)

    def data(self):
        out = bytearray()
        for start in range(0, len(self.bits), 8):
            byte = 0
            for offset, bit in enumerate(self.bits[start:start + 8]):
                byte |= bit << offset
            out.append(byte)
        return bytes(out)


def write_single_symbol_code(writer, symbol):
    """記号が 1 つだけの「単純符号」。この木を通る記号はビットを消費しない。"""
    writer.put(1, 1)  # simple code
    writer.put(0, 1)  # 記号数 - 1 == 0
    if symbol <= 1:
        writer.put(0, 1)  # 最初の記号は 1 ビット
        writer.put(symbol, 1)
    else:
        writer.put(1, 1)  # 最初の記号は 8 ビット
        writer.put(symbol, 8)


def solid_lossless_webp(width, height, red, green, blue, alpha=255):
    writer = BitWriter()
    writer.put(width - 1, 14)
    writer.put(height - 1, 14)
    writer.put(0, 1)  # alpha_is_used(手がかりに過ぎないので 0 でよい)
    writer.put(0, 3)  # version
    writer.put(0, 1)  # 変換なし
    writer.put(0, 1)  # カラーキャッシュなし
    writer.put(0, 1)  # メタハフマン画像なし
    for symbol in (green, red, blue, alpha, 0):  # 緑・赤・青・アルファ・距離の順
        write_single_symbol_code(writer, symbol)

    payload = b"\x2f" + writer.data()  # 0x2f = VP8L のシグネチャ
    if len(payload) % 2:
        payload += b"\x00"  # RIFF のチャンクは偶数バイト
    chunk = b"VP8L" + struct.pack("<I", len(payload)) + payload
    body = b"WEBP" + chunk
    return b"RIFF" + struct.pack("<I", len(body)) + body


def main():
    args = [a for a in sys.argv[1:] if a != "--wide"]
    wide = "--wide" in sys.argv[1:]
    if len(args) != 2:
        print(__doc__, file=sys.stderr)
        return 1
    dest, number = args[0], int(args[1])
    width = WIDE_WIDTH if wide else WIDTH
    with open(dest, "wb") as f:
        f.write(solid_lossless_webp(width, HEIGHT, number, GREEN, BLUE))
    return 0


if __name__ == "__main__":
    sys.exit(main())
