#!/usr/bin/env python3
"""ファイル名のバイト列を自分で決めて zip を書く。

`zip` コマンドも Python の zipfile も、文字列のファイル名を UTF-8(または cp437)へ寄せてしまい、
「CP932 のまま・UTF-8 フラグ無し」という古い Windows/Mac の zip は作れない。ZipArchiveReader の
EntryNameDecoder はまさにその書庫を相手にするので、ここでは ZIP の構造(ローカルヘッダ・セントラル
ディレクトリ・EOCD)を直接書く。日時は固定(2026-01-01 00:00)、圧縮は無し(stored)。

    make-legacy-zip.py OUT.zip [--truncate BYTES] ENTRY...

    ENTRY は ENCODING:NAME=PATH の形。
        ENCODING  cp932 / euc_jp / cp949 / big5 / utf8 / utf8flag(UTF-8 + 汎用フラグ bit 11)
        NAME      書庫内のパス(UTF-8 で書く。末尾が / ならディレクトリエントリで PATH は空)
        PATH      中身のファイル
    ENTRY を 1 つも渡さなければ EOCD だけの空の zip になる。
    --truncate BYTES は、出来上がりの先頭 BYTES バイトだけを書く(壊れた書庫を作る)。
"""
import struct
import sys
import zlib

DOS_DATE = ((2026 - 1980) << 9) | (1 << 5) | 1  # 2026-01-01
DOS_TIME = 0
UTF8_FLAG = 1 << 11


def encode_name(encoding: str, name: str):
    if encoding == "utf8flag":
        return name.encode("utf-8"), UTF8_FLAG
    if encoding == "utf8":
        return name.encode("utf-8"), 0
    return name.encode(encoding), 0


def build(entries):
    local = bytearray()
    central = bytearray()
    for encoding, name, path in entries:
        is_dir = name.endswith("/")
        data = b"" if is_dir else open(path, "rb").read()
        raw_name, flags = encode_name(encoding, name)
        crc = zlib.crc32(data) & 0xFFFFFFFF
        offset = len(local)
        header = struct.pack(
            "<IHHHHHIIIHH", 0x04034B50, 20, flags, 0, DOS_TIME, DOS_DATE, crc, len(data), len(data), len(raw_name), 0
        )
        local += header + raw_name + data
        external_attributes = 0x10 if is_dir else 0
        central += struct.pack(
            "<IHHHHHHIIIHHHHHII",
            0x02014B50, 20, 20, flags, 0, DOS_TIME, DOS_DATE, crc, len(data), len(data),
            len(raw_name), 0, 0, 0, 0, external_attributes, offset,
        ) + raw_name
    eocd = struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, len(entries), len(entries), len(central), len(local), 0)
    return bytes(local + central + eocd)


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    out = argv[1]
    rest = argv[2:]
    truncate = None
    if rest and rest[0] == "--truncate":
        truncate = int(rest[1])
        rest = rest[2:]
    entries = []
    for spec in rest:
        encoding, _, remainder = spec.partition(":")
        name, _, path = remainder.partition("=")
        if not encoding or not name:
            sys.exit(f"ENTRY の形が違う: {spec}")
        entries.append((encoding, name, path))
    data = build(entries)
    if truncate is not None:
        data = data[:truncate]
    with open(out, "wb") as f:
        f.write(data)


if __name__ == "__main__":
    main(sys.argv)
