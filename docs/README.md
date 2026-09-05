# qooViewer 仕様書

このフォルダは、qooViewer を将来引き継ぐ人のための仕様書です。ユーザー向けの説明は
リポジトリ直下の [README.md](../README.md)(概要・ビルド方法)と [MANUAL.md](../MANUAL.md)
(操作説明)にあり、変更の履歴は [CHANGELOG.md](../CHANGELOG.md) にあります。ここではそれらと
重複しない、**「どう作られているか」と「なぜそうなったか」**を書きます。

## 読む順番

| # | ファイル | 内容 |
|---|---|---|
| 01 | [01-overview.md](01-overview.md) | このアプリが何で、何を大事にして作られているか。設計原則と用語 |
| 02 | [02-project-and-build.md](02-project-and-build.md) | リポジトリ構成・ビルド設定・署名・サンドボックス・ローカライズ・運用の約束 |
| 03 | [03-architecture.md](03-architecture.md) | 全体構造。アプリ全体で1つのもの/ウインドウごとのもの、シーン構成、橋渡しの仕組み、並行処理の規約 |
| 04 | [04-book-loading.md](04-book-loading.md) | 本(フォルダ・書庫・PDF・EPUB)を開いてページ一覧を作るまで。入れ子書庫、ページの識別子 |
| 05 | [05-page-display-and-memory.md](05-page-display-and-memory.md) | ページ画像のデコード・キャッシュ・先読み・メモリ管理。ソリッド7zの扱い |
| 06 | [06-persistence.md](06-persistence.md) | 何をどこに保存するか。SwiftData の落とし穴、シークレットウインドウ、リセット |
| 07 | [07-page-order-layout-bookmarks.md](07-page-order-layout-bookmarks.md) | ページの並び順・見開きの組み方・レイアウト設定・ブックマークの鍵 |
| 08 | [08-export-and-import.md](08-export-and-import.md) | EPUB/PDF/CBZ の書き出し、画像の書き出し、ライブラリデータ(JSON)の書き出し・読み込み |
| 09 | [09-ui-and-windows.md](09-ui-and-windows.md) | 画面の構成、入力の扱い、パネルの見た目、補助ウインドウの共通の形、環境設定の方針 |
| 10 | [10-sandbox-and-security.md](10-sandbox-and-security.md) | サンドボックス下でファイルに触るための約束事 |
| 11 | [11-forked-dependencies.md](11-forked-dependencies.md) | 独自にフォークした依存ライブラリ(SevenZip.swift / Unrar.swift)に、何のためにどんな変更を加えたか |
| 12 | [12-verification-and-debugging.md](12-verification-and-debugging.md) | テストターゲットが無いこのアプリを、どうやって検証・計測・デバッグしてきたか |
| 13 | [13-history-and-known-limitations.md](13-history-and-known-limitations.md) | 主な方針転換の履歴、既知の制限、未着手の課題 |

急いでいるなら 01 → 03 → 06 → 11 の順に読めば、壊しやすい場所の見当が付きます。

## この仕様書の書き方

- **ソースコードのコメントが一次資料**です。このアプリの Swift ファイルには、機能の「何」だけでなく
  「なぜ」(過去の不具合、採らなかった案、プラットフォームの癖)が日本語で書き込まれています。
  本書は、それらを横断して読めるように整理した地図であり、コードのコメントを置き換えるものでは
  ありません。細部で食い違ったら、コードのコメントのほうが新しいと考えてください。
- 本文中の `型名.メンバー名` は、`qooViewer/` 配下のソースの該当箇所を指します。ファイル名を
  探すときは `grep -rn "型名" qooViewer/` で見つかります。
- 「ユーザー要望」「ユーザー報告」「監査で指摘」という言葉は、コードのコメントの語法をそのまま
  使っています。前者2つは開発者自身(=このアプリの唯一のユーザー)からの要望・不具合報告、
  「監査」はコード全体を読み直して見つけた問題を指します。
- 日付は 2026 年のものです(このリポジトリの最初のコミットは 2026-07-26)。

## 引き継いだ人がまず守るべきこと

1. [CLAUDE.md](../CLAUDE.md) の「Working conventions」を読む。特に **README/MANUAL/CHANGELOG を
   勝手に更新しない・勝手にコミットしない・既存のコメントを消さない** の3つ。
   (`CLAUDE.md` と `docs/` は、設計判断を変えたときに一緒に更新する側です。)
2. SwiftData のモデルに `@Attribute(.unique)` を付けない、`ModelContext` を増やさない
   (→ [06](06-persistence.md))。
3. `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` の下では、メインアクターの外で使う型・関数に
   `nonisolated` を明示する(→ [03](03-architecture.md#並行処理の規約))。
4. 依存ライブラリのフォークは `Package.resolved` の revision を手で書き換えて固定している
   (→ [11](11-forked-dependencies.md#ピンの更新手順))。
5. すりガラスの面に文字やアイコンを載せたら、文字の輪郭の扱いを決める
   (→ [09](09-ui-and-windows.md#パネルの面と文字の輪郭))。
