#!/bin/bash
# docs/ の Markdown にある相対リンクの先が実在することを確かめる。
#
# docs/README「本書はソースを指す地図」。ファイル名の変更や章の分割でリンクが切れても
# 誰も気づかないので、ここで拾う。見出しアンカー(#…)は確かめない(見出しの書き換えで
# 頻繁に変わるうえ、切れても致命的ではない)。http(s) と mailto は対象外。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

python3 - <<'EOF'
import os, re, sys

link = re.compile(r"\]\(([^)\s]+)\)")
failed = 0
checked = 0
for root, _, files in os.walk("docs"):
    for name in sorted(files):
        if not name.endswith(".md"):
            continue
        path = os.path.join(root, name)
        text = open(path, encoding="utf-8").read()
        for target in link.findall(text):
            if target.startswith(("http://", "https://", "mailto:", "#")):
                continue
            target = target.split("#", 1)[0]
            checked += 1
            resolved = os.path.normpath(os.path.join(root, target))
            if not os.path.exists(resolved):
                failed += 1
                print("FAIL: %s → %s が存在しない" % (path, target), file=sys.stderr)
if failed == 0:
    print("ok:   docs/ の相対リンク %d 件はすべて実在する" % checked)
sys.exit(1 if failed else 0)
EOF
