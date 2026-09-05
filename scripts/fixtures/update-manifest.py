#!/usr/bin/env python3
"""qooViewerTests/Fixtures/manifest.json の sha256 とサイズを、実ファイルから書き直す。

台帳の「作り方(howMade)」「何のためか(purpose)」「期待する結果(book)」は人が書くもので、
このスクリプトは触らない(無いファイルの項目は消し、新しいファイルには空の項目を足して知らせる)。
build-fixtures.sh の最後に呼ばれるほか、フィクスチャを 1 つ手で差し替えたときにも単独で使える。
"""
import hashlib
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FIXTURES = os.path.join(ROOT, "qooViewerTests", "Fixtures")
MANIFEST = os.path.join(FIXTURES, "manifest.json")
IGNORED = {"manifest.json", ".DS_Store", "README.md"}


def files_on_disk():
    for dirpath, _dirnames, filenames in os.walk(FIXTURES):
        for name in sorted(filenames):
            if name in IGNORED or name.startswith("._"):
                continue
            path = os.path.join(dirpath, name)
            yield os.path.relpath(path, FIXTURES).replace(os.sep, "/"), path


def main():
    manifest = {"schemaVersion": 1, "limits": {"maxFileBytes": 200 * 1024, "maxTotalBytes": 2 * 1024 * 1024},
                "fixtures": {}}
    if os.path.exists(MANIFEST):
        with open(MANIFEST, encoding="utf-8") as f:
            manifest = json.load(f)
    old = manifest.get("fixtures", {})
    new = {}
    added, removed = [], []
    for relative, path in files_on_disk():
        with open(path, "rb") as f:
            data = f.read()
        entry = dict(old.get(relative, {}))
        if relative not in old:
            added.append(relative)
            entry.setdefault("howMade", "")
            entry.setdefault("purpose", "")
        entry["bytes"] = len(data)
        entry["sha256"] = hashlib.sha256(data).hexdigest()
        # 読みやすい順に並べ直す
        ordered = {k: entry[k] for k in ("bytes", "sha256", "howMade", "purpose") if k in entry}
        ordered.update({k: v for k, v in entry.items() if k not in ordered})
        new[relative] = ordered
    for relative in old:
        if relative not in new:
            removed.append(relative)
    manifest["fixtures"] = dict(sorted(new.items()))
    with open(MANIFEST, "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
        f.write("\n")
    total = sum(e["bytes"] for e in new.values())
    print(f"{len(new)} fixtures, {total} bytes -> {os.path.relpath(MANIFEST, ROOT)}")
    for relative in added:
        print(f"  new (howMade / purpose を書くこと): {relative}")
    for relative in removed:
        print(f"  removed: {relative}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
