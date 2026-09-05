#!/bin/bash
# Info.plist の書類の型と、コードが対応している拡張子の一覧が一致することを確かめる。
#
# Info.plist のコメント: 「画像の拡張子の一覧は ArchiveReading.swift の imageExtensions と
# 必ず一致させる」。Dock へのドロップと Finder の「このアプリケーションで開く」は
# Info.plist に宣言された型しか受け付けないので、片方だけ増やすと「コードは読めるのに
# 開けない」(またはその逆)になる。書庫の型も同じ(archiveExtensions + pdf + epub)。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

python3 - <<'EOF'
import plistlib, re, sys

def swift_set(name):
    src = open("qooViewer/Services/ArchiveReading.swift", encoding="utf-8").read()
    m = re.search(r"let %s: Set<String> = \[([^\]]*)\]" % name, src)
    if not m:
        sys.exit("FAIL: ArchiveReading.swift に %s の宣言が見つからない" % name)
    return set(re.findall(r'"([^"]+)"', m.group(1)))

with open("qooViewer/Info.plist", "rb") as f:
    plist = plistlib.load(f)
types = {t["CFBundleTypeName"]: set(t.get("CFBundleTypeExtensions", []))
         for t in plist["CFBundleDocumentTypes"]}

failed = False
def compare(label, declared, expected):
    global failed
    if declared == expected:
        print("ok:   %s: Info.plist とコードの拡張子が一致(%d 種)" % (label, len(expected)))
    else:
        failed = True
        print("FAIL: %s: Info.plist とコードの拡張子が食い違う" % label, file=sys.stderr)
        print("      Info.plist だけ: %s" % sorted(declared - expected), file=sys.stderr)
        print("      コードだけ:      %s" % sorted(expected - declared), file=sys.stderr)

compare("Image", types.get("Image", set()), swift_set("imageExtensions"))
compare("Comic Archive", types.get("Comic Archive", set()), swift_set("archiveExtensions") | {"pdf", "epub"})
sys.exit(1 if failed else 0)
EOF
