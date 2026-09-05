#!/bin/bash
# テストのフィクスチャ(qooViewerTests/Fixtures/)が台帳(manifest.json)と一致することを確かめる。
#
# フィクスチャは外部ツール(rar / 7zz)や生のバイト列で作った小さなバイナリで、作り直しは手元でしか
# できない(scripts/fixtures/build-fixtures.sh)。ここで見るのは:
#   - ファイルと台帳の項目が 1 対 1 で対応していること(片方だけ増えた・消えたを検知する)
#   - sha256 が一致すること(知らないうちに差し替わっていない)
#   - 大きさの上限(1 ファイル / 合計)を超えていないこと
#   - 作り方(howMade)と何のためか(purpose)が書かれていること ―― 由来の分からないバイナリを増やさない
#   - 本のフィクスチャ(book)には期待する結果(sortKeys か error)があること
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

python3 - <<'EOF'
import hashlib, json, os, sys

fixtures = "qooViewerTests/Fixtures"
manifest_path = os.path.join(fixtures, "manifest.json")
ignored = {"manifest.json", ".DS_Store", "README.md"}
failures = []

with open(manifest_path, encoding="utf-8") as f:
    manifest = json.load(f)
limits = manifest["limits"]
entries = manifest["fixtures"]

on_disk = {}
for dirpath, _dirs, names in os.walk(fixtures):
    for name in names:
        if name in ignored or name.startswith("._"):
            continue
        path = os.path.join(dirpath, name)
        on_disk[os.path.relpath(path, fixtures).replace(os.sep, "/")] = path

for relative in sorted(set(on_disk) - set(entries)):
    failures.append(f"台帳に無いファイル: {relative}(scripts/fixtures/update-manifest.py を走らせる)")
for relative in sorted(set(entries) - set(on_disk)):
    failures.append(f"ファイルが無い台帳の項目: {relative}")

total = 0
for relative in sorted(set(entries) & set(on_disk)):
    entry = entries[relative]
    with open(on_disk[relative], "rb") as f:
        data = f.read()
    total += len(data)
    if hashlib.sha256(data).hexdigest() != entry.get("sha256"):
        failures.append(f"sha256 が台帳と違う: {relative}")
    if len(data) != entry.get("bytes"):
        failures.append(f"サイズが台帳と違う: {relative}")
    if len(data) > limits["maxFileBytes"]:
        failures.append(f"1 ファイルの上限 {limits['maxFileBytes']} バイトを超えている: {relative} ({len(data)})")
    for key in ("howMade", "purpose"):
        if not str(entry.get(key, "")).strip():
            failures.append(f"{key} が空: {relative}")
    book = entry.get("book")
    if book is not None and not ({"sortKeys", "pageCount", "error"} & set(book)):
        failures.append(f"book に sortKeys / pageCount / error のどれも無い: {relative}")
if total > limits["maxTotalBytes"]:
    failures.append(f"合計の上限 {limits['maxTotalBytes']} バイトを超えている ({total})")

if failures:
    for line in failures:
        print("FAIL:", line, file=sys.stderr)
    sys.exit(1)
print(f"ok:   {len(entries)} fixtures / {total} bytes は台帳どおり")
EOF
