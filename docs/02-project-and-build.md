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
├── Configurations/Shared.xcconfig  署名の Team ID を外出しするための設定(下記)
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

CLI のテストターゲットはありません。GUI アプリなので、Xcode で `Cmd+R` して動かして確かめます
(→ [12](12-verification-and-debugging.md))。

```sh
xcodebuild -project qooViewer.xcodeproj -scheme qooViewer -configuration Debug build
xcodebuild -project qooViewer.xcodeproj -scheme qooViewer -configuration Release build
```

依存パッケージは SwiftPM で自動解決されます(→ [11](11-forked-dependencies.md))。

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
