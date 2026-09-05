# 03. アーキテクチャ

## 全体像

```
QooViewerApp (@main)
 ├─ AppStores ……………… アプリ全体で1つのストア群を束ねる箱(publish しない)
 ├─ Scenes
 │   ├─ WindowGroup "main" / "book" / "private" / "normal" …… 本を表示するウインドウ(ContentView)
 │   ├─ Settings ……………………………………………… 環境設定(SettingsView)
 │   └─ Window × 10 ………………………………………… 補助ウインドウ(単一インスタンス)
 └─ .commands ……………………………………………… メニューバー(FocusedValue 経由でウインドウと結ぶ)

ContentView(ウインドウ/タブごと)
 ├─ AppState(このウインドウの状態。本を開く/閉じる、橋渡しクロージャ、メニュー用の値)
 ├─ SidePanelBrowserState(フォルダブラウザ。本の切替をまたいで生きる)
 ├─ BookContentsBrowserState(本の中身ブラウザ。本ごとに作り直す)
 ├─ SidePanelView
 └─ ViewerView(本ごとに `.id(book.id)` で作り直す) / WelcomeView
      └─ ViewerViewModel(表示状態・ページ送り・レイアウト・ブックマーク)
           └─ PageLoader(actor。書庫のハンドル・デコード・キャッシュ・先読み)
                ├─ ArchiveReading(Zip / Rar / SevenZip の各 reader)
                ├─ NestedArchiveResolver(入れ子書庫)
                └─ PagePixelCache × 3(ページ画像・進捗バー用サムネイル・グリッド用サムネイル)
```

「アプリ全体で1つ」「ウインドウごと」「本ごと」の3つの寿命を意識してください。不具合の多くは、
この寿命の取り違え(ウインドウごとの値をアプリ全体で持つ、本ごとの資源をウインドウの寿命に
任せる、など)から生まれています。

## アプリ全体で1つのもの

`App/AppStores.swift` が `QooViewerApp.init()` で組み立て、`.environmentObject` で各シーンへ
配ります。**`AppStores` 自身は `ObservableObject` ではありません。** App 直下の `@StateObject` が
publish すると、その1回の発火で **body 全体(全 Scene + `.commands`)が再評価され、メニューバーが
丸ごと作り直される**ことが実測で分かったためです(→ MenuBarMenuGate)。メニューの内容に効く
ストアの変化だけを `MenuBarMenuRefresher` が選んで伝えます。

| 型 | 保存先 | 役割 |
|---|---|---|
| `AppPreferences` | UserDefaults | 環境設定。1プロパティ=1キー、`didSet` で即保存 |
| `RecentFilesStore` | UserDefaults | 履歴(セキュリティスコープ付きブックマーク+パスのキャッシュ) |
| `FolderAccessStore` | UserDefaults | 環境設定「フォルダのアクセス権」。起動中ずっとアクセスを開いたまま維持 |
| `FavoritesStore` | SwiftData | お気に入り(階層フォルダ付き) |
| `BookmarkStore` | SwiftData | すべての本を横断したブックマーク(「ブックマーク・レイアウトの編集」用) |
| `LayoutStore` | SwiftData | すべての本のレイアウト設定 |
| `BookMetadataStore` | SwiftData | 書誌メタデータ |
| `MetadataFormatStore` | UserDefaults(JSON) | ファイル名からメタデータを推測する3種のルール |
| `KeyBindingStore` | UserDefaults(JSON) | キー・マウスの割り当て(基本+表示モード別) |
| `LaunchCoordinator` | メモリ | 最初のウインドウ、開いている全 AppState の弱参照一覧、編集ウインドウへの値渡し |
| `ProcessResourceSampler` | メモリ | リソースモニタの CPU/メモリ/ディスクの計測 |
| `MenuBarMenuGate` / `MenuBarTracking` | メモリ | メニューが開いている間の更新の保留 |
| `ThumbnailDiskCache` / `BookPageListCache` / `TemporaryFileStore` | ディスク | actor / enum のシングルトン |
| `SettingsNavigator` / `AppAppearanceApplier` | メモリ | 環境設定の行き先、外観の適用 |

**SwiftData のストアは全部が同じ1つの `ModelContext`(`modelContainer.mainContext`)を共有します。**
分けた設計は過去に「一方のコンテキストの更新がもう一方に反映されず静かに失敗する」不具合を
起こしました(→ [06](06-persistence.md))。

## ウインドウごとのもの: AppState

`ContentView` が `@StateObject` として作り、ウインドウ/タブごとに独立しています。

- 本を開く・閉じる(`open(request:)`、`closeBook()`、`openSibling`、`openAllImagesInCurrentFolder`)。
  読み込みは世代トークン(`openToken`)で古い結果を捨て、`loadingProgress` で進捗を出す。
- `isPrivateWindow`(`let`。ウインドウの生涯変わらない)。`actsAsRegularWindow` は
  「シークレットモードで起動」のときの最初のウインドウの扱い。
- `hostWindow`(weak)、`currentBook`、`currentPageIndex`、`currentPartnerPageIndex`、
  `currentBookPages`(実効順のページ一覧。サイドパネルが追従するために公開)。
- **橋渡しクロージャ**: `performViewerAction`、`jumpToBookmark`、`jumpToPageIndex`、
  `addBookmarkAction`、`toggleBookmarkAtIndex`、`addFavoriteAction`、`openFavoriteAction`、
  `fetchResourceSnapshot`、`loadPageThumbnail`、`exportPageImage`、`hideAutoRevealedChrome`、
  `performLayoutStateChange` など。`ViewerView` が `onAppear` で登録し `onDisappear` で外す。
  同じウインドウで本を切り替えると古い `ViewerView` の `onDisappear` が新しい登録を消して
  しまうため、`activeViewerToken`(UUID)で「自分が登録したものか」を確認してから外す。
- **メニュー用の値**: `MenuCheckmarkState`(値型)にチェックマークや有効/無効の判定に必要な
  Bool をまとめ、`FocusedValue` でメニューバーへ渡す。**クラス参照ではなく値型**なのは、
  `FocusedValue` の変化検知が値の比較で行われるため(クラスを渡すと中身が変わっても
  メニューが更新されない)。

## 本ごとのもの: ViewerView / ViewerViewModel / PageLoader

`ContentView` は `ViewerView(...).id(book.id)` で、本が変わるたびにビューごと作り直します。
`ViewerViewModel` は `@StateObject`、`PageLoader` はその中の `let` です。

**資源の解放は `deinit` に任せません。** 同じウインドウで次の本を開くと、SwiftUI が古い
`ViewerView` のノード(=`@StateObject`)を1世代ぶん抱えたままにすることがあり、実測では前の本の
`PagePixelBuffer` が 27 枚(約 840MB)残っていました。`ViewerViewModel.releaseResources()` を
`onDisappear` とウインドウの `willClose` の両方から呼び、「もう表示していない」事実に紐づけて
中身を空けます(`PageLoader.releaseAllResources`、表示中の CGImage の破棄、走行中タスクの
キャンセル、開いている本の冊数の減算)。`BookLayoutEditorViewModel` / `BookContentsBrowserState`
も同じ形です。

## シーンとウインドウ

| シーン | id | 用途 |
|---|---|---|
| `WindowGroup` | `main` | 起動時に SwiftUI が自動で作る。環境設定「シークレットモードで起動」に従う。`.handlesExternalEvents(matching:)` は最初のウインドウが現れるまで `"*"`、以後は `[]` |
| `WindowGroup(for: BookOpenRequest.self)` | `book` | 常に通常ウインドウ。本を指定して開く。`.windowResizability(.contentSize)` |
| `WindowGroup(for: BookOpenRequest.self)` | `private` | 常にシークレットウインドウ |
| `WindowGroup(for: BookOpenRequest.self)` | `normal` | File ›「新規ノーマルウインドウ」専用(値なし、ウェルカム画面から)。`.automatic` |
| `Settings` | ― | 環境設定 |
| `Window` | `favoritesOrganizer` / `editBookmarks` / `editMetadata` / `epubExport` / `pdfExport` / `cbzExport` / `libraryExport` / `libraryImport` / `libraryCleanup` / `historyCleanup` | 単一インスタンスの補助ウインドウ |

すべての本のウインドウは `.restorationBehavior(.disabled)` です。macOS の標準の状態復元が、
ウインドウ0枚からの再アクティブ化で古い `NSWindow` を再利用し、「Finder から開くと一瞬出て消える/
真っ白」という不具合を起こしていたためです(検索で見つかった既知の問題)。

`Window` は `for:` による値のパラメータ化ができないため、「どの本を対象に開くか」は
`LaunchCoordinator.pendingEditorInitialFocus` のような共有オブジェクト経由で渡します。
一度作られた補助ウインドウの ViewModel は閉じてもアプリ終了まで使い回されるので、変更通知を
購読して一覧を読み直す必要があります(`BookExportViewModel` / `MetadataEditorViewModel`)。

**新しいウインドウ/タブで本を開く**経路は `BookWindowOpener.open(_:to:from:)` の1本に集約されて
います。行き先は `BookOpenDestination`(引き継ぐ新ウインドウ/必ず通常/必ずシークレット/タブ)、
使う WindowGroup は `BookWindowGroup.id(for:inheritingFrom:)` が決めます。タブにだけ
「通常/シークレットを選ぶ」版が無いのは、1枚のウインドウに記録の残るタブと残らないタブが
混ざるとタイトルバーから区別できなくなるためです。既に開いている本は
`LaunchCoordinator.openAppState(forBookAt:isPrivate:)` で**同じ性質のウインドウ**を探して前面に
出します。

Finder / Dock からの「開く」は `AppDelegate.application(_:open:)` が受け、
`FinderOpenBehavior`(置き換える/新しいタブ/新しいウインドウ)と、最前面の**同じ性質の**
コンテンツウインドウ(`frontmostContentAppState(matchingPrivacy:)`)で行き先を決めます。

## メニューバーと MenuBarMenuGate

メニューバーは `QooViewerApp` の `.commands` に全部あります。File / Edit(お気に入り・
ブックマーク・レイアウト・メタデータの編集もここ)/ View(`CommandGroup(after: .toolbar)` で
標準の View メニューへ統合)/ Move(`CommandMenu`)/ Window。

**macOS 26 では、メニューを開いている最中にメニュー項目が作り直されるとアプリが落ちます**
(`NSContextMenuImpl` の行高キャッシュの範囲外アクセスで `NSRangeException`)。SwiftUI の
`Commands` は `@FocusedValue` や `ObservableObject` の変化のたびに項目を作り直すため、
「ユーザーの操作と無関係に非同期で変わる値」(見開きのデコード完了、履歴の再検証、
お気に入りの存在確認、スライドショーの境界到達 …)がそのまま流れると危険です。

対策は3段です。

1. `MenuBarMenuGate.shared.run(key) { ... }`: メニューが開いている間は更新を保留し、閉じて
   1ランループ後にまとめて適用する。同じ key の保留は最後の1つだけ残す。
2. `MenuBarMenuGate.onMenuBarMenuDidClose(key)`: 「閉じたら一覧を最新化する」処理の登録。
   `NSMenu.didEndTrackingNotification` を各所で自前購読するとゲートとの実行順が定まらないので、
   必ずゲート経由にする。
3. **メニュー項目の数を状態で変えない**: 条件で項目を出し分けるのではなく、常に同じ項目数で
   `.disabled` にする。項目数が変わる更新は再構築を引き起こす。

同じ理由で、`RecentFilesStore` / `FavoritesStore` の `@Published` は「値が同じなら代入しない」
(`@Published` は同値でも `objectWillChange` を発火する)。原因を突き止めた手順は
[12](12-verification-and-debugging.md#メニュー再構築の現行犯逮捕) にあります。

## 通知(NotificationCenter)

SwiftData のモデルの変更は SwiftUI の再描画を自動では起こしません。このアプリでは各ストアと
`ViewerViewModel` がそれぞれ配列のキャッシュを持ち、変更した側が通知を投げ、購読側が読み直す
方式で統一しています。

| 通知名 | 投げる側 | userInfo | 購読側 |
|---|---|---|---|
| `bookmarksDidChange` | `BookmarkStore`、`ViewerViewModel` | `bookID`(全件リセット時は無し) | `ViewerViewModel`、`BookmarkStore`、書き出し・メタデータ編集の VM |
| `layoutDataDidChange` | `LayoutStore`、`ViewerViewModel`、`BookLayoutEditorViewModel` | `bookID`、任意で `focusPageKey` | `ViewerViewModel`(16ms のデバウンス)、編集 VM、書き出し VM |
| `bookMetadataDidChange` | `BookMetadataStore` | `bookID` | `ViewerViewModel`(ツールバーの表示名)、各 VM |
| `bookReadingStatesDidDelete` | `LibraryCleanupViewModel` | `bookIDs`(Set) | `ViewerViewModel`(以後その行へ書かない) |
| `pageOrderSettingDidChange` | `AppPreferences.usesFinderSortOrder` の didSet | ― | `ViewerViewModel`、編集 VM、書き出し VM |
| `recentFilesLimitDidChange` | `AppPreferences.recentFilesLimit` の didSet | ― | `RecentFilesStore` |

約束事:

- 購読は `queue: .main` で登録し、クロージャの中は `MainActor.assumeIsolated { }` で包む。
  `Task { @MainActor in }` にすると Swift 6 の並行性チェックで別の警告になるうえ、余分な
  非同期ホップが増える。
- 自分が投げた通知は `notification.object === self` で読み飛ばす(全件フェッチが二重に走る)。
- `deinit` で `removeObserver` する。`deinit` の中で `MainActor.assumeIsolated` は使わない
  (メインスレッド以外で解放された瞬間にトラップする。`SidePanelContextMenuHighlight` のコメント)。

## 並行処理の規約

- 既定隔離が `MainActor` なので、**メインアクターの外で使うものには `nonisolated` を明示する**
  (型・関数・static プロパティ・enum の計算プロパティ)。対象は `PageLoader`(actor)、
  `BookLoader` の `Task.detached`、各 Exporter、`DirectoryBrowser`、`SiblingFinder`、
  `BookMetadataDeriver`、`BookURLResolver`、`LibraryCleanupViewModel.evaluate` など。
  正典は `Services/ArchiveReading.swift` 冒頭のコメント。
- 書庫の reader(`ArchiveReading`)は `Sendable` ではなく、スレッドセーフでもない。
  **`PageLoader`(actor)の中でだけ触る。** デコード(CPU 負荷)は actor の外の `Task` で行い、
  actor をブロックしない。
- メインアクターの外へ渡す値は、SwiftData のモデルをそのまま渡さず、メインアクターにいるうちに
  `Sendable` な値(UUID・Data・String)へ写し取る(`FavoritesStore.scheduleExistenceRefresh`、
  `LibraryCleanupViewModel.ExistenceProbe`)。
- `[weak self]` で受けた self は、`await` をまたぐ前に `guard let` で強参照へ変換する。
- 結果の反映は世代番号(`generation`)で「自分が最新か」を確かめてから行う。走行中に来た要求は
  捨てずに1回ぶん覚えておき、完了後にやり直す(`needsAnotherRefresh`)。
- `@Published` の購読(`$prop.sink`)は**値が書き換わる前**(willSet)に届く。購読の中で
  同じプロパティを読むと1つ前の値になる。sink が受け取った新しい値を使う
  (`AppPreferences.pageImageCacheLimitBytes(forMB:)` のコメント)。
- セキュリティスコープ付きブックマークの解決は、未接続のボリュームで秒単位ブロックする。
  **表示のためにメインスレッドで解決しない**(→ [10](10-sandbox-and-security.md))。

## データの流れ(本を1冊開くとき)

1. 入口(ウェルカム画面・ドロップ・Finder・履歴・お気に入り・サイドパネル・隣の本)が
   `BookOpenRequest` を作る。複数の画像なら1冊のその場限りの本、それ以外は先頭1件だけ。
2. `AppState.open(request:)` が前の本のセキュリティスコープを閉じ、新しい URL を開き、
   `BookLoader.load(from:progress:)` を `Task.detached` で走らせる(→ [04](04-book-loading.md))。
3. 返ってきた `MangaBook` について、4つのストアで bookID の追従(inode による移動検知)、
   履歴の記録、`LastActiveBookStore` の更新、隣の本の一覧の再読み込みを行う。
4. `ContentView` が `ViewerView(...).id(book.id)` を作り直し、`ViewerViewModel.init` が
   レイアウト設定の適用・鍵の解決・読書位置の復元・`PageLoader` の生成を行う
   (→ [07](07-page-order-layout-bookmarks.md))。
5. `loadCurrentSpread` → `PageLoader.pageImage(at:)` → デコード → `currentImages` →
   `ViewerView.pageArea` が描画(→ [05](05-page-display-and-memory.md))。
6. 同時に本全体の下調べ(寸法・サムネイル)、EPUB/PDF/ComicInfo からの初回取り込み、
   自動レイアウトが非同期に走る。
