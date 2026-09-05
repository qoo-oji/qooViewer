# ComicInfo.xml のスキーマ(第三者のファイル)

`ComicInfo_v2.0.xsd` は anansi-project/comicinfo の v2.0 スキーマをそのまま置いたもの。
qooViewer が書き出した CBZ の `ComicInfo.xml` を、CI が `xmllint --schema` にかけるために使う
(`scripts/ci/validate-exports.sh`)。**テストからは読まない** ―― 検品ツールの入力なので、
中身の解釈は xmllint に任せる。

- 出所: https://github.com/anansi-project/comicinfo `schema/v2.0/ComicInfo.xsd`(2026-09-06 取得)
- ライセンス: MIT License, Copyright (c) 2021 anansi-project
- 版を上げるときは、ファイルを差し替えてから `scripts/fixtures/update-manifest.py` を走らせる
  (sha256 は台帳 `../manifest.json` が持つ)。qooViewer が書き出すのは v2.0 相当なので、
  ドラフトの v2.1 ではなく v2.0 を使う。
