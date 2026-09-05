# 02. プロジェクト構成・ビルド・運用の約束

## リポジトリの構成

```
qooViewer/
├── qooViewer.xcodeproj/          Xcode プロジェクト(共有スキーム付き。Package.resolved もここ)
├── qooViewer/
│   ├── App/                      QooViewerApp(全シーンとメニューバー)、AppStores
│   ├── Models/                   値型・列挙・SwiftData モデル(約50ファイル)
│   ├── Services/                 読み込み・デコード・書き出し・OS との橋渡し(nonisolated が多い)
│   ├── ViewModels/               ObservableObject(ストア・画面ごとの状態)
│   ├── Views/                    SwiftUI ビュー(Export/ と Settings/ のサブフォルダあり)
│   ├── Resources/Localizable.xcstrings   文字列カタログ(英語ベース+日本語)
│   └── Info.plist                書類の型(下記)
├── qooViewerTests/               単体テスト(Swift Testing、下記)。Fixtures/ に本のフィクスチャと台帳、Support/ にビルダー
├── Configurations/Shared.xcconfig  署名の Team ID を外出しするための設定(下記)。CI 用の警告設定もここ
├── .github/workflows/            CI(build.yml / check.yml、下記)。dependabot.yml も
├── scripts/ci/                   約束事の検査スクリプト(check-all.sh がまとめて走らせる。CI と手元で共用)
├── scripts/fixtures/             テストのフィクスチャを作り直すスクリプト(手元だけ。下記)
├── docs/                         この仕様書
├── README.md / MANUAL.md / CHANGELOG.md / LICENSE(MIT) / CLAUDE.md
├── .gitattributes                pbxproj と xcstrings は `-text merge=binary`、MANUAL/CHANGELOG は linguist-documentation
└── .gitignore                    Local.xcconfig、DerivedData など
```

Swift のコードは約 6 万行(2026-09 時点)。「Standard MVVM」と呼んでいますが、実態は

- **Models** = 永続化する型と、UI と Services の両方が使う語彙(列挙・値型)
- **Services** = メインアクターに縛られない処理(ファイル・書庫・画像・書き出し)
- **ViewModels** = アプリ全体で1つのストアと、画面ごとの状態オブジェクト
- **Views** = 画面。ビューの中に AppKit へ降りる小さな `NSViewRepresentable` が多数ある

という分け方です(→ [03](03-architecture.md))。

## ビルド

GUI アプリなので、確かめ方の中心は Xcode で `Cmd+R` して動かすことです
(→ [12](12-verification-and-debugging.md))。単体テストは `qooViewerTests` に少しだけあります(下記)。

```sh
xcodebuild -project qooViewer.xcodeproj -scheme qooViewer -configuration Debug build
xcodebuild -project qooViewer.xcodeproj -scheme qooViewer -configuration Release build
xcodebuild -project qooViewer.xcodeproj -scheme qooViewer -configuration Debug \
  -destination 'platform=macOS' test
```

依存パッケージは SwiftPM で自動解決されます(→ [11](11-forked-dependencies.md))。

### テストターゲット(qooViewerTests)

Swift Testing の単体テストです(2026-09-05 追加)。アプリを TEST_HOST にした
`com.apple.product-type.bundle.unit-test` で、`@testable import qooViewer` でアプリの型を直接見ます。
ビルド設定はアプリ側と揃えてあります(`SWIFT_VERSION = 5.0`、`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`)。

対象は **UI を伴わない `nonisolated` のパイプライン** です(2026-09-05 に「純粋ロジックだけ」から
広げました)。拡張子の判定・並び順のような純粋な関数に加えて、書庫の読み取り → `BookLoader` →
`PageRef` までの経路と、EPUB / PDF の構造解決を、下記のフィクスチャで通します。画面の自動操作
(AX 経由)は再現性が低いので載せません(→ [12](12-verification-and-debugging.md))。

いまある suite(2026-09-05 時点、83 テスト・約 1.1 秒):

| suite | 見るもの |
| --- | --- |
| `PageOrderTests` / `ArchiveClassificationTests` | 正準順・表示順の比較、拡張子の判定 |
| `FixtureBookTests` | コミット済みの本 42 冊を開いて台帳の `book` と突き合わせる(golden) |
| `GeneratedFixtureTests` | テストの中で作る本(フォルダ・zip・EPUB・PDF)を開く |
| `ArchiveReaderTests` | `ArchiveReading` の適合(zip / 7z / rar × ファイル入力 / メモリ入力) |
| `NestedArchiveResolverTests` | 入れ子の書庫の予算・行き先・一時ファイルの寿命・LRU |
| `ZipEntryNameTests` | UTF-8 フラグ無しの zip のファイル名の補正(`EntryNameDecoder` の黒箱) |
| `BookLoaderBehaviorTests` | 中止・進み具合・メモリ予算・`load(imageFiles:)` |
| `BookInternalBrowsingTests` | 本の中身ブラウザの `matchKey` と並び |
| `EpubStructureTests` / `PDFStructureTests` | spine / Catalog / 書誌メタデータ / 目次 |

残っている段階(2〜4)は [13](13-history-and-known-limitations.md#テストのパタンセット--段階-24引き継ぎ2026-09-05)。

**テストは共有の保存先に触れません。** TEST_HOST は実物のアプリなので、手元では自分の履歴・
キャッシュ・SwiftData と同じコンテナで走ります。本を開くときは `FixtureBook.load`
(`BookLoader.load(cachesPageList: false)` を固定)を通し、`UserDefaults.standard`・
`BookPageListCache.shared`・`ThumbnailDiskCache.shared`・`modelContainer.mainContext` は読みも
書きもしません。並び順の設定が絡むところは `EffectivePageOrder` の `usesFinderOrderOverride:` を
明示します。

手元でテストを回すときは通常の署名のままで(`CODE_SIGNING_ALLOWED=NO` を付けない)。署名の無い
TEST_HOST はビルドごとに別のアプリとして扱われ、起動のたびに macOS がリムーバブルボリュームへの
アクセス許可を聞き直します。

**テストターゲットもアプリと同じ既定分離(MainActor)です。** `@Test(arguments:)` に渡す引数は
Swift Testing がメインアクター外で評価し、`onProgress` のような callback も読み込みのタスクの中から
呼ばれるので、そこに出す `static` プロパティやヘルパー型には `nonisolated` を付けます。手元のビルドでは
**警告どまり**ですが CI は警告をエラーにするので、push する前に CI と同じ形で通しておくこと:

```sh
xcodebuild -project qooViewer.xcodeproj -scheme qooViewer -configuration Debug \
  -destination 'platform=macOS' QOO_CI_WARNINGS_AS_ERRORS=YES build-for-testing
```

#### テストのフィクスチャ

`qooViewerTests/Fixtures/` に小さな「本」を置き、台帳 `manifest.json` に **sha256・作り方
(`howMade`)・何のためか(`purpose`)・本として開いたときの期待(`book`)** を書きます。
`FixtureBookTests` が台帳の全冊を `BookLoader` で開き、`book.sortKeys`(`PageRef.sortKey` の列
= DB の pageKey、→ [04](04-book-loading.md#ページの識別子))と突き合わせます。並びを固定しない
ものは `pageCount`、開けないことが正しいものは `error`(`noPages` / `unreadable`)。

書庫として直接開くもの(reader の適合テスト)には `archive` も書きます ―― `entries` は
`listFilePaths()` が返すはずの**全件**で、値はページ画像に埋めた番号(`PageImageFactory` の R)、
**0 は画像ではないエントリ**(`__MACOSX/._*`、入れ子の書庫)。暗号化された書庫には
`"encrypted": true`。`ArchiveReaderTests` がこれを使い、取り出したバイト列が本当にそのエントリの
ものかを**中身の番号**で確かめます。

**golden はロケールに左右されない名前で作ること。** 正準順は `localizedStandardCompare` なので、
異なる文字体系が混ざった名前の前後は OS の言語で変わります(CI は英語、手元は日本語)。
`zip-mixed-utf8-cp932.zip` は名前の頭を `a-` / `b-` にして並びを ASCII で決めてあります。

- **コミットするもの**: 外部ツールや生のバイト列が要るもの ―― rar / 7z、UTF-8 フラグ無しの zip
  (CP932 / EUC-JP / CP949 / Big5)、Finder の「圧縮」相当(`__MACOSX/._*` 入り)、入れ子の書庫、
  壊れた書庫、Document Catalog に読み方向を書いた PDF。ページ画像は 8x12 px の単色 PNG で、
  **R = ページ番号**(書き出しの後で中身から順序を追えるように)。上限は 1 ファイル 200 KB・
  合計 2 MB。
- **テストの中で作るもの**: フォルダの本(`FixtureFolder`)、UTF-8 の zip(`ZipFixtureBuilder`)、
  EPUB(`EpubFixtureBuilder`: spine / spread / 読み方向 / 名前空間の書き方を選べる)、画像を貼った
  PDF(`PDFFixtureBuilder`)。git のファイル名正規化や隠しファイルの扱いに左右されないよう、
  名前そのものを試すものはこちら。`qooViewerTests/Support/` にあります。

作り直しは `scripts/fixtures/build-fixtures.sh`(手元だけ。`7zz` と `rar` が要る。rar 7.2x は RAR4
を作れないので、RAR4 の書庫は実物が手に入ったときに手で置く)。`make-legacy-zip.py` はファイル名の
バイト列を決めて zip を直接書き、`make-pdf.py` は xref を計算して小さな PDF を書きます。
台帳の sha256 は `update-manifest.py` が書き、`scripts/ci/check-fixtures.sh` が「ファイルと台帳が
1 対 1」「sha256 一致」「上限」「howMade / purpose が空でない」「`archive.entries` が空でない」を
見ます。

フィクスチャを増やすときは: (1) `build-fixtures.sh` に作り方を足す(または手で置く)、
(2) `update-manifest.py` を走らせ、台帳に `howMade` / `purpose` / `book` を書く、
(3) `xcodebuild test` で `FixtureBookTests` が通ることを確かめる。`Fixtures/` は pbxproj の
`explicitFolders`(フォルダ参照)なので、ファイルを置くだけでバンドルに入ります。

既知の限界もテストで固定してあります(落ちない・ページ数は合う、の形)。zip のファイル名の文字コード
判定は Foundation の自動判定に頼るため、**EUC-JP は当たらず(単バイトの文字コードとして「読めて」
しまう)、CP949 は Shift-JIS / GB18030 に倒れます**(2026-09-05 に発見。判定は `likelyLanguageKey`
を渡さない限りロケール寄りで、Big5 は日本語ロケールでは当たる)。→ [13](13-history-and-known-limitations.md)

`MARKETING_VERSION` はこのターゲットには置いていません。アプリ側の Debug / Release の2か所だけで
持ち、`scripts/ci/check-version.sh` がその2つの一致を見ています。

### CI

GitHub Actions(2026-09-05 導入)。push のたびに「clone してビルドできる」ことと「約束事が守られている」ことを GitHub 上で確かめます。
門番(required status check)にはしていません。main へ直接 push する運用なので、失敗は
Actions タブと GitHub のメール通知で見ます。README にバッジも付けていません。

| ワークフロー | ランナー | 内容 |
|---|---|---|
| `.github/workflows/build.yml` | `macos-26` + Xcode 26.6(`DEVELOPER_DIR` で固定) | Debug / Release の 2 ジョブ。依存解決後に `Package.resolved` が変わらないこと、警告ゼロでビルドできること。Debug は `qooViewerTests` を実行し、ビルドした .app を 15 秒起動して生存を確認、Release は universal(arm64 + x86_64)と署名を検品して zip を artifact(14 日)に残す |
| `.github/workflows/check.yml` | `ubuntu-latest` | `scripts/ci/check-all.sh`。Team ID の混入、Info.plist の書類の型とコードの拡張子の一致、`Localizable.xcstrings` の妥当性、`MARKETING_VERSION` の整合(タグ push 時はタグと CHANGELOG の見出しも)、テストのフィクスチャと台帳の一致、フォークのピン、改行コード、`docs/` のリンク切れ、actionlint |

決めごと:

- **警告はエラー**。CI は `QOO_CI_WARNINGS_AS_ERRORS=YES` を `xcodebuild` に渡し、`Shared.xcconfig` が
  それを `SWIFT_TREAT_WARNINGS_AS_ERRORS` / `GCC_TREAT_WARNINGS_AS_ERRORS` に流します。間接参照に
  しているのは、`SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` を直接渡すと SwiftPM の依存パッケージ(Xcode が
  `-suppress-warnings` を付ける)にも効いて `Conflicting options` で落ちるためです。手元では変数が
  未定義なので警告は警告のままです。
- **署名は検証用**。Debug は `CODE_SIGNING_ALLOWED=NO`、Release は ad-hoc(`CODE_SIGN_IDENTITY=-`)。
  配布用の zip は今まで通り手元で Apple Development 証明書(Personal Team)で作ります。署名の主体を
  バージョン間で変えないためで、CI の zip は配布しません。
- **Xcode の版はワークフローで明示**。ランナーの既定 Xcode は四半期ごとに上がるので、手元の Xcode を
  上げたら `build.yml` の `DEVELOPER_DIR` も一緒に上げます(ランナーに入っている版は
  actions/runner-images の `macos-26-arm64-Readme.md` で確認)。
- **Actions は SHA で固定**。`.github/dependabot.yml` が月 1 回、新しい版を PR で知らせます。
  Swift パッケージは対象外(フォークは revision を手で動かす、→ [11](11-forked-dependencies.md))。
- **テストはビルドと分ける**。Debug ジョブは `build-for-testing` → `test-without-building` の2段で、
  どちらで落ちたのかがログで分かるようにしています。署名していない .app にテストバンドルを
  差し込む形になりますが(`CODE_SIGNING_ALLOWED=NO`)、手元で同じ条件で通ることを確認済みです。
- 検査の本体はリポジトリ内のスクリプトで、手元でも同じものが走ります(→ [12](12-verification-and-debugging.md#基本))。

### 主要なビルド設定(project.pbxproj)

| 設定 | 値 | 意味 |
|---|---|---|
| `MACOSX_DEPLOYMENT_TARGET` | 15.0 | macOS 15 以降。macOS 26 専用 API は `#available` で分岐(`ScrollEdgeEffect`) |
| `SWIFT_VERSION` | 5.0 | **言語モードは Swift 5**(Swift 6 モードではない)。ただし下の2つで Swift 6 相当の隔離チェックが効く |
| `SWIFT_DEFAULT_ACTOR_ISOLATION` | MainActor | **何も書かなければメインアクター隔離**。メインアクターの外で使う型・関数は `nonisolated` 必須 |
| `SWIFT_APPROACHABLE_CONCURRENCY` | YES | Xcode 26 の「Approachable Concurrency」一式 |
| `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY` | YES | 暗黙のモジュール再エクスポートに頼らない |
| `ENABLE_APP_SANDBOX` | YES | App Sandbox。`.entitlements` ファイルは無く、ビルド設定から生成される |
| `ENABLE_HARDENED_RUNTIME` | YES | 公証の前提 |
| `ENABLE_USER_SELECTED_FILES` | readwrite | ユーザーが選んだファイル/フォルダの読み書き |
| `PRODUCT_BUNDLE_IDENTIFIER` | com.qooProject.qooViewer | 変えると SwiftData のストア・UserDefaults・キャッシュの場所が変わる |
| `MARKETING_VERSION` | 1.41(2026-09-05 時点) | アプリのバージョン。Debug/Release 両方にある |
| `CURRENT_PROJECT_VERSION` | 1 | ビルド番号は使っていない |

ネットワークの entitlement はありません。このアプリは一切通信しません。

「Swift 5 モード + 既定隔離 MainActor」という組み合わせがこのプロジェクトの最大の落とし穴です。
Swift 6 モードのようなデータ競合の完全検査はされませんが、**隔離のミスマッチは厳しくエラーに
なります**。`Services/ArchiveReading.swift` 冒頭のコメントが正典で、`PageLoader`(actor)や
`Task.detached` から触る型・関数・static プロパティは `nonisolated` を明示しています。
Models にも `nonisolated enum` / `nonisolated struct` が多いのはそのためです
(→ [03](03-architecture.md#並行処理の規約))。

### 署名(Configurations/Shared.xcconfig)

リポジトリには `DEVELOPMENT_TEAM` を**意図的に含めていません**。特定の開発者のアカウントに
結び付いた値をコミットすると、clone した他の人が「その Team のアカウントが無い」でビルドできなく
なるためです。Team を設定しなくても「Sign to Run Locally」でビルド・実行できます。

自分のアカウントで署名したいときは、`Configurations/Local.xcconfig`(gitignore 済み)に
`DEVELOPMENT_TEAM = XXXXXXXXXX` と書きます。`Shared.xcconfig` が `#include? "Local.xcconfig"`
(無ければ黙って無視)で取り込みます。Xcode の Signing & Capabilities で Team を選ぶ方法は
`project.pbxproj` へ直接書き込まれてコミット事故につながるので使いません。

配布物は公証(notarization)していません。初回起動時の Gatekeeper の扱いは README の冒頭に
書いてあります。

### Info.plist(書類の型)

`CFBundleDocumentTypes` に3グループあります。

1. 書庫・PDF・EPUB(`CFBundleTypeExtensions` で列挙)
2. フォルダ(`LSItemContentTypes` = `public.folder`、`LSHandlerRank` = None)
3. 画像ファイル(`CFBundleTypeExtensions` で列挙、`LSHandlerRank` = None)

Info.plist の中のコメントに書いてある要点:

- Dock アイコンへのドロップと Finder の「このアプリケーションで開く」は、ここに宣言された型しか
  受け付けない。
- 画像の拡張子の一覧は `ArchiveReading.swift` の `imageExtensions` と**必ず一致させる**。
- 画像グループには `LSItemContentTypes` を併記しない(UTI 側が優先されて拡張子側が無視される)。
- `LSHandlerRank None` は「開けるが既定のハンドラ候補にはならない」。画像の既定アプリを
  奪わないため。

## ローカライズ

- 文字列は `Resources/Localizable.xcstrings`(String Catalog)。英語がベースで、日本語訳を持つ。
- 表示言語(`AppPreferences.displayLanguage`)は **OS のロケールと独立**に選べる。SwiftUI の
  `Text` は各ウインドウの**内容ビュー**に付けた `.environment(\.locale, ...)` で切り替わる
  (Scene に付けても中身に届かない)。
- コードで組み立てる文字列は必ず `String(localized:language:)`(`Models/AppLanguage.swift` の
  拡張)を使う。Foundation の `String(localized:locale:)` は**翻訳の選択には関わらず**書式にしか
  効かない(この取り違えが監査で見つかり、全箇所を置き換えた経緯がある)。ラベルを `language:` に
  してあるのは、同じ間違いを二度としないため。
- ロケールの取り方は3通り: View の中は `@Environment(\.locale)`、ViewModel は
  `preferences.effectiveLocale`、nonisolated なサービス層や環境設定を作る前のコードは
  `AppLanguage.currentLocale`(UserDefaults を直接読む)。
- ウインドウのタイトルは `Window(String(localized:..., language:), id:)` のように **String で渡す**。
  `Window("key", id:)` だと OS の言語で解決されてしまう。
- メニューバーと OS のダイアログは実行中に切り替えられない。選んだ言語をアプリ自身の
  `AppleLanguages` に書いて、**次回起動から**揃える(`AppLanguage.applyAppleLanguagesOverride`)。
  「システムに従う」へ戻したときは、自分が書いた印(`overrideMarkerKey`)があるときだけ消す
  (ユーザーがシステム設定でアプリごとの言語を指定している場合を壊さないため)。
- Xcode でビルドすると `Localizable.xcstrings` にキーの追加・並び替えの差分が出ます。
  **戻さずにそのままコミットします**(戻すと次のビルドでまた出る)。
- 2文以上の説明文(ホバーの吹き出し)は、**日本語訳にだけ**文の切れ目(「。」の後ろ)で改行を
  入れてあります。macOS のテキスト描画は日本語を単語の途中でも折り返すため。読点では
  改行しません(`Views/Settings/SettingsControls.swift` 冒頭参照)。
- 拡張子(CBZ/ZIP など)や固有名詞は翻訳対象にせず `Text(verbatim:)` で出します。

## 運用の約束(CLAUDE.md の要約)

- **README.md / MANUAL.md / CHANGELOG.md は、その変更について明示的に指示されたときだけ更新する。
  `git commit` とリリースタグ(`vX.YY`)も同様。**
- CHANGELOG は Keep a Changelog 形式・日本語・**ユーザーから見える影響だけ**(実装の詳細は書かない)。
  `[Unreleased]` を先頭に置く。
- コミットメッセージは英語で簡潔に、箇条書きをコードブロックに入れる。
- `MARKETING_VERSION` と CHANGELOG の見出しは独立に管理されている(常に同期しているとは限らない)。
  タグは `vX.YY`、CHANGELOG の見出しは `[X.YY]`。
- 既存のコメントを消さない。変更したら更新する。
- すりガラスの面に UI を足したら、文字の輪郭の扱いをその変更の中で決める(→ [09](09-ui-and-windows.md))。
- SwiftUI/AppKit 自体の不具合と疑ったら、試行錯誤の前に検索する。

## CLAUDE.md との関係

CLAUDE.md は AI アシスタント向けの作業指針で、依存関係・規約の要約を持ちます。2026-09-05 に
UniversalCharsetDetection の記述を削除し、フォークのピン方法と本仕様書への参照を追記して
現状に揃えました。設計上の判断を変えたときは、CLAUDE.md とこの `docs/` の両方を更新してください
(どちらも README/MANUAL/CHANGELOG の「勝手に更新しない」規則の対象外です)。
