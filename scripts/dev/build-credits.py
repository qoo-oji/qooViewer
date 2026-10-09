#!/usr/bin/env python3
"""依存ライブラリのライセンス文から qooViewer/Resources/Credits.rtf を作る(2026-10-10)。

    python3 -I scripts/dev/build-credits.py            # 作り直す(手元。依存の checkout が要る)
    python3 -I scripts/dev/build-credits.py --check    # 版の食い違いだけを見る(CI。checkout は要らない)

Credits.rtf はアプリのリソースに入り、macOS の標準の「qooViewer について」に表示される。配る .app には依存ライブラリが
入っている(Sparkle.framework はそのまま、ほかは静的にリンク)ので、MIT・BSD・zlib・unRAR のライセンスが求める表記を
配布物そのものに持たせるため(README のリンクだけでは「配布物に付ける文書」にならない)。

- 文面は各 checkout のライセンスのファイルを**そのまま**写す(要約しない)。どのファイルを写すかは PACKAGES に書く。
- 依存を足した・版を動かしたら作り直す。--check(scripts/ci/check-credits.sh)は Package.resolved の依存がすべて、
  今の版で Credits.rtf に載っていることを確かめる(PACKAGES に無い依存は落とす ―― 足したらここへも足すこと)。
- RTF にするのは、HTML から作った文字列は文字色が黒に固定され、ダークモードの「qooViewer について」で読めなくなるため。
  色を指定しない RTF なら、パネルの文字色(明暗に追従)で描かれる。
"""

import argparse
import glob
import json
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RESOLVED = os.path.join(REPO, "qooViewer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
OUTPUT = os.path.join(REPO, "qooViewer/Resources/Credits.rtf")

# identity(Package.resolved)→ 表示名・写すファイル(checkout からの相対パス)・添える一文
PACKAGES = [
    {
        "identity": "sparkle",
        "name": "Sparkle",
        "files": ["LICENSE"],  # 中で使う bsdiff・sais-lite・ed25519・SUSignatureVerifier のライセンスもこの中にある
        "notes": [],
    },
    {
        "identity": "zipfoundation",
        "name": "ZIPFoundation",
        "files": ["LICENSE"],
        "notes": [],
    },
    {
        "identity": "sevenzip.swift",
        "name": "SevenZip.swift",
        "files": ["LICENSE.txt"],
        "notes": [
            "Includes C code from 7-Zip / LZMA SDK by Igor Pavlov, placed in the public domain.",
            "Streaming extraction and in-memory archive support added in the qoo-oji fork: Copyright (c) 2026 qoo, MIT License (the same terms as above).",
        ],
    },
    {
        "identity": "unrar.swift",
        "name": "Unrar.swift",
        "files": ["LICENSE.txt", "Sources/Cunrar/license.txt", "Sources/Cunrar/acknow.txt"],
        "notes": [
            "Includes the UnRAR source code by Alexander L. Roshal (modified in the qoo-oji fork). "
            "The UnRAR code may not be used to develop a RAR (WinRAR) compatible archiver or to re-create the RAR compression algorithm.",
            "BLAKE2 code by Samuel Neves, dedicated to the public domain.",
        ],
    },
    {
        "identity": "qoometa",
        "name": "qooMeta",
        "files": ["LICENSE"],
        "notes": [],
    },
]


def load_pins():
    with open(RESOLVED, encoding="utf-8") as f:
        return {pin["identity"]: pin for pin in json.load(f)["pins"]}


def label(package, pin):
    """Credits.rtf に書く版の表記。--check はこの文字列があるかで食い違いを見る(ASCII だけなので RTF でもそのまま残る)。"""
    state = pin["state"]
    if "version" in state:
        version = state["version"]
    else:
        version = "%s branch, revision %s" % (state["branch"], state["revision"][:12])
    return "%s %s (%s)" % (package["name"], version, pin["location"])


def find_checkouts(pins):
    """Package.resolved の revision と HEAD が一致する checkout の集まりを DerivedData から探す。"""
    pattern = os.path.expanduser("~/Library/Developer/Xcode/DerivedData/qooViewer-*/SourcePackages/checkouts")
    for root in sorted(glob.glob(pattern)):
        ok = True
        for package in PACKAGES:
            path = os.path.join(root, os.path.basename(pins[package["identity"]]["location"]))
            try:
                head = subprocess.run(["git", "-C", path, "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
            except (subprocess.CalledProcessError, FileNotFoundError):
                ok = False
                break
            if head != pins[package["identity"]]["state"]["revision"]:
                ok = False
                break
        if ok:
            return root
    return None


def rtf_escape(text):
    out = []
    for ch in text:
        code = ord(ch)
        if ch in "\\{}":
            out.append("\\" + ch)
        elif ch == "\n":
            out.append("\\line\n")
        elif ch == "\t":
            out.append("\\tab ")
        elif code < 0x80:
            out.append(ch)
        else:
            # RTF の \u は符号付き 16 ビット。BMP の外はサロゲートの組にする。
            units = [code] if code <= 0xFFFF else [0xD800 + ((code - 0x10000) >> 10), 0xDC00 + ((code - 0x10000) & 0x3FF)]
            for unit in units:
                out.append("\\u%d?" % (unit - 0x10000 if unit > 0x7FFF else unit))
    return "".join(out)


LIST_MARKER = __import__("re").compile(r"^(\d+\.|\*|-|=+$|-+$)")


def reflow(text):
    """ライセンス文の 80 文字前後の改行を段落ごとにつなぐ(文面は変えず、改行と行頭の空白だけを詰める)。

    「について」パネルの文字の欄は幅が狭く(約 270pt)、等幅のまま写すと 1 行が途中で折り返されて読めなかった(2026-10-10 に撮って確かめた)。
    空行は段落の区切り、箇条の頭(「1.」「*」「-」)と区切り線は新しい行として残す。飾り文字(unRAR の見出し)の段落は等幅のまま返す。
    返り値は (等幅か, 行の並び)。
    """
    blocks = []
    for paragraph in text.split("\n\n"):
        lines = [line.rstrip() for line in paragraph.split("\n") if line.strip()]
        if not lines:
            continue
        if any("****" in line or "~~~~" in line for line in lines):
            blocks.append((True, lines))
            continue
        joined = []
        for line in lines:
            stripped = line.strip()
            if joined and not LIST_MARKER.match(stripped):
                joined[-1] += " " + stripped
            else:
                joined.append(stripped)
        blocks.append((False, joined))
    return blocks


def build(checkouts, pins):
    parts = [
        "{\\rtf1\\ansi\\ansicpg1252\\deff0{\\fonttbl{\\f0\\fswiss Helvetica;}{\\f1\\fmodern Menlo;}}\n",
        "\\f0\\fs20 ",
        rtf_escape("qooViewer uses the following software. / qooViewer は次のソフトウェアを使っています。"),
        "\\par\\par\n",
    ]
    for package in PACKAGES:
        pin = pins[package["identity"]]
        parts.append("\\pard\\b\\f0\\fs22 %s\\b0\\par\n" % rtf_escape(label(package, pin)))
        for note in package["notes"]:
            parts.append("\\f0\\fs18 %s\\par\n" % rtf_escape(note))
        for relative in package["files"]:
            path = os.path.join(checkouts, os.path.basename(pin["location"]), relative)
            with open(path, encoding="utf-8", errors="strict") as f:
                text = f.read().strip("\n")
            for monospaced, lines in reflow(text):
                font = "\\f1\\fs11" if monospaced else "\\f0\\fs18"
                parts.append("\\pard\\sa60%s %s\\par\n" % (font, rtf_escape("\n".join(lines))))
            parts.append("\\par\n")
        parts.append("\\par\n")
    parts.append("}\n")
    return "".join(parts)


def check(pins):
    try:
        with open(OUTPUT, encoding="utf-8") as f:
            credits = f.read()
    except FileNotFoundError:
        print("FAIL: %s が無い(scripts/dev/build-credits.py で作る)" % os.path.relpath(OUTPUT, REPO), file=sys.stderr)
        return 1
    failed = 0
    known = {package["identity"] for package in PACKAGES}
    for identity in sorted(set(pins) - known):
        print("FAIL: %s が Credits の一覧(build-credits.py の PACKAGES)に無い" % identity, file=sys.stderr)
        failed += 1
    for package in PACKAGES:
        pin = pins.get(package["identity"])
        if pin is None:
            print("FAIL: %s が Package.resolved に無い(依存を外したなら PACKAGES からも外す)" % package["identity"], file=sys.stderr)
            failed += 1
            continue
        if rtf_escape(label(package, pin)) not in credits:
            print("FAIL: Credits.rtf の %s が今の版ではない(scripts/dev/build-credits.py で作り直す)" % package["name"], file=sys.stderr)
            failed += 1
        else:
            print("ok:   Credits.rtf に %s" % label(package, pin))
    return 1 if failed else 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--checkouts", help="SourcePackages/checkouts(省略時は DerivedData から探す)")
    args = parser.parse_args()
    pins = load_pins()
    if args.check:
        return check(pins)
    checkouts = args.checkouts or find_checkouts(pins)
    if not checkouts:
        print("error: Package.resolved の revision どおりの checkout が見つからない(Xcode で一度ビルドする)", file=sys.stderr)
        return 1
    with open(OUTPUT, "w", encoding="ascii", newline="\n") as f:
        f.write(build(checkouts, pins))
    print("wrote %s" % os.path.relpath(OUTPUT, REPO))
    return check(pins)


if __name__ == "__main__":
    sys.exit(main())
