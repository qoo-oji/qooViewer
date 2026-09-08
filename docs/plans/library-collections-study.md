# 改善要望5 検討メモ ―― お気に入りの廃止・ウェルカム画面の再構成(ライブラリ/コレクション)・ウェルカム画面へ戻る操作

検討日: 2026-09-08 / ブランチ: `feature/library-collections` / 元の要望: `Memo/qooViewer改善要望 5.md`

イメージは Kindle.app のコレクション機能(ユーザー補足)。角丸の正方形にカバー3列×2段、右下に冊数バッジ、
下に名前。クリックでコレクションの中(カバーが並ぶだけの画面)へ。

このメモは「作る前の検討」。コードはまだ触っていない。§5 の質問に答えをもらってから着手する。

---

## 0. 要点

| 要望 | 結論 | 規模感 |
|---|---|---|
| お気に入りの廃止(コードは残す) | **フラグ1つ(`FavoritesFeature.isEnabled = false`)で入り口をすべて塞ぐ**。モデル・ストア・JSON・テストはそのまま。スキーマからも消さない(消すとマイグレーション)。 | 小(入り口 12 か所前後の分岐) |
| ウェルカム画面の再構成 + ライブラリ/コレクション | 新しい SwiftData モデル3つ(`BookLibrary` / `BookCollection` / `CollectionItem`)と `CollectionStore`。カバーは**登録時に1回だけ抽出してディスクへ保存**。既存の「カバー画像の上書き」(`BookLayoutSettings.coverPageKey` / `externalCoverBookmarkData`)を**そのまま正典**にし、メタデータ編集シートと「メタデータの編集」ウインドウからも同じものを書く。 | 大(新規 4〜6 千行。既存の `WelcomeView` は作り直し) |
| ウェルカム画面へ戻る操作 | `ViewerAction.returnToWelcome` を追加(既定の割り当て無し)。実体は既存の `PageBoundaryBehavior.returnToWelcome` と同じ経路(`flushPendingSave()` → `AppState.closeBook()`)。サイドパネルのスイッチ左端とツールバー左端にボタン。 | 小 |

「ライブラリ」という語は既にコード内で **保存データ全体**の意味に使われている(`LibraryImportExportService` /
`LibraryCleanupViewModel` / `LibraryDataPruner` = 「保存データの書き出し/読み込み/削除」)。ユーザー向けの語は要望どおり
「ライブラリ」で通し、コード側の新しい型は `BookLibrary` / `CollectionStore` のように **`Library` 単独を型名にしない**
(用語の約束「同じものを別の語で呼ばない」の裏返しで、「違うものを同じ語で呼ばない」)。

---

## 1. お気に入りの無効化

### 1.1 方針

- `Models/FavoritesFeature.swift`(新規)に `enum FavoritesFeature { static let isEnabled = false }` を置く。
  復活させるときはここを `true` に戻すだけ。**削除ではなく分岐**なので、削除して復活させるときの
  「何を消したか分からない」問題が起きない。
- **消さないもの**: `FavoriteBook` / `FavoriteFolder`(スキーマ。`QooViewerApp.modelSchema` からも外さない)、
  `FavoritesStore`(`AppStores` で生成し続ける。`LibraryCleanupViewModel` / `LibraryImportExportService` /
  `MetadataEditorViewModel` / `InMemoryLibrary` が初期化子で要求している)、`FavoritesLimitTests` などのテスト、
  JSON スキーマの `favorites`(既存の書き出しファイルを読めなくしない)。
- UI 文言(環境設定の help に出てくる "favorites, bookmarks and reading history" など)は**この段階では触らない**。
  String Catalog の差分を最小にし、コレクションの文言をまとめて入れるときに一緒に見直す。

### 1.2 塞ぐ入り口(`grep -rn -i favorite` から洗い出したもの)

| 入り口 | 場所 | 対応 |
|---|---|---|
| 編集メニューの3項目(追加/削除トグル・編集…・一覧サブメニュー) | `QooViewerApp.swift:891-931` | `if FavoritesFeature.isEnabled` で丸ごと出さない(`Divider` の対も) |
| ツールバーの星ボタン、右クリックメニューの2項目 | `ViewerView.swift:1996-2005`, `2116-2125` | 同上 |
| キー・マウス設定の一覧 | `KeyBindingSettingsView.swift:57`(`favoriteGroup`)、`KeyBindingStore.swift:125-126`(既定 ⌥A/⌥B) | `favoriteGroup` を `hidden` へ(既に `showFavoritesList` がそうなっている前例)。既定の割り当ては `fillingMissingDefaults` の都合で**辞書からは消さず**、`perform(_:)` 側で無視する |
| `perform(.toggleFavorite / .showFavoritesList / .showFavoritesOrganizer)` | `ViewerView.swift:3952-3959` | フラグが false なら何もしない |
| サイドパネル「ブックマーク」モードの上段(お気に入りツリー) | `SidePanelView.swift:345`, `1165-` | 上段を出さず、ブックマーク一覧に全高を使う(履歴モードと同じ1列) |
| ウェルカム画面の「最近のお気に入り」列 | `WelcomeView.swift` | 画面ごと作り直すので消える |
| 環境設定「一般」の「最近のお気に入りを表示」、「本を開く」の「お気に入りから」 | `GeneralSettingsView.swift:100`, `OpeningSettingsView.swift:45` | 行を出さない。`AppPreferences` のキーと `keys(for:)` は残す(消すと「初期設定に戻す」の対象から外れるだけで害は無いが、復活時に戻し忘れる) |
| 「お気に入りの編集」ウインドウ(`Window(id: "favoritesOrganizer")`) | `QooViewerApp.swift:1172` | シーン自体は残してよい(入り口が無ければ開かない)が、`openWindow(id:)` の呼び出し元4か所(メニュー・サイドパネル・`perform`)を塞ぐ |
| 「保存データの書き出し/読み込み」のお気に入りのチェックボックス | `LibraryExportWindow` / `LibraryImportWindow` | チェックボックスを隠し、書き出しには**含めず**、読み込みも**無視**する(見えないデータを JSON に混ぜない。DB の登録自体は残るので復活時に困らない。→ 実装計画 §1.2) |
| 「保存データの削除」ウインドウのお気に入り列 | `LibraryCleanupWindow` / `LibraryCleanupViewModel` | 列を隠す。削除の実体(`removeFavorites(forBookID:)`)は残す(残骸を掃除できるように) |
| 「見つからないお気に入り」アラート | `ContentView.swift:614-650`, `AppState.missingFavorite` | 到達不能になるだけ。触らない |
| `AppState.isCurrentBookFavorited` の算出 | `ContentView.swift:360` | `false` 固定にする(お気に入りの変更でメニューバー全体が作り直される経路が1つ減る) |
| 環境設定「リセット」の全削除 | `ResetDataSettingsView` | そのまま(残骸も消す) |

`docs/06` の一覧表・`docs/09` の「ウェルカム画面」「サイドパネル」・`docs/13` に「無効化した。データとコードは残っている」を書く。

### 1.3 既存データをどうするか(→ §5 Q1)

お気に入りが見えなくなると、登録済みのデータは「保存データの書き出し」でしか取り出せなくなる。選択肢:

- **A. 何もしない**(データは残るが見えない)。要望の文面どおり。
- **B. 初回起動時に1回だけコレクションへ移す**: フォルダ1つ→コレクション1つ(3階層は「親/子」の名前で平らにする)、
  ルート直下の本→「お気に入り」コレクション。移した後もお気に入りのデータは消さない。
  カバー抽出は登録時ではなく後述の「未取得のカバーを背景で埋める」経路に任せる。

推奨は **B**(自分の登録が黙って消えたように見えるのが一番困る)。ただし件数が多いとカバー抽出に時間がかかるので、
移行は「ライブラリの初期化」の一部として1回だけ、確認無しで行う想定。

---

## 2. ライブラリ/コレクション

### 2.1 データモデル(SwiftData、既存ストアと同じ `mainContext`)

```
BookLibrary        id: UUID, name: String, sortOrder: Int, createdAt: Date
  └ BookCollection id: UUID, name: String, createdAt: Date, updatedAt: Date, library: BookLibrary?
      └ CollectionItem id: UUID, bookID: String(パス), bookmarkData: Data, title: String,
                       addedAt: Date, sortOrder: Int, inodeNumber/volumeDeviceNumber: Int64?,
                       coverStatus: Int(0=未取得 / 1=取得済み / 2=失敗), collection: BookCollection?
```

- **既存の約束に全部従う**(docs/06): `@Attribute(.unique)` を付けない(一意性はストアが insert 前に確認)、
  `#Predicate` で絞らず全件フェッチ+辞書キャッシュ、`Identifiable` を付けない(`ForEach(..., id: \.id)`)、
  後から足す属性は宣言時デフォルト必須、名前は変えない。
- 関係(`library` / `collection`)は `FavoriteFolder.parent` / `FavoriteBook.folder` と同じ Optional の親参照。
  削除は親→子のカスケード(`deleteRule: .cascade`。`FavoriteFolder.children` と同じ)。
- `CollectionItem.bookID` はパス。同じ本が別のコレクションに入るのは可(行が2つ)。同じコレクションに同じ本は不可
  (ストアが弾く。パス一致 or inode 一致)。
- 移動・リネームへの追従: 他の4モデルと同じ `reconcileBookIDIfMoved(book:)` / `backfill*` を `CollectionStore` に持たせ、
  `AppState.open` の既存の呼び出し列(`AppState.swift:977` 付近)に1行足す。
- 「ライブラリ」の初期状態(1つだけ、名前「ライブラリ」)は、`CollectionStore.reload()` が0件なら作る(ローカライズ済みの
  既定名。以後は普通の行なので名前変更可)。**「どのライブラリを選んでいたか」「開いていたコレクション」は
  UserDefaults**(`qooViewer.pref.*` ではなく `WelcomeLibraryState` 専用のキー。環境設定の「初期設定に戻す」の対象外)。
- 並び順(名前/作成日/更新日 × 昇降)は **`FavoritesSortOption` をそのまま流用**(まさにこの3×2)。コレクション一覧用と
  コレクションの中用の2キーを UserDefaults に持つ(ブックマークが `FavoritesSortOption` を流用しているのと同じ)。
- `updatedAt` の意味: コレクションは「本の追加・削除・名前変更」で更新。本(`CollectionItem`)の「更新日」は
  `addedAt` と同じ扱いで十分(要望の並び替え3種はコレクション一覧のものを「コレクションの中でも同じ」と言っているので、
  本については 名前/追加日/追加日 になる。→ §5 Q6)。

### 2.2 カバー画像

要望: 「本を追加したら先頭の画像をカバーとして取得。全登録ファイルから毎回読み直すのは非現実的」。

- **保存先はディスク(`~/Library/Application Support/<bundleID>/CollectionCovers/<CollectionItem.id>.jpg`)**、
  SwiftData の `Data` 属性には入れない。理由:
  1. `Caches` ではない(OS に消されると「非現実的」な読み直しが起きる)。`ThumbnailDiskCache` とは別物。
  2. 行の中に blob を持つと `fetch` の全件読みでメモリに乗る(999 冊 × 50KB ≒ 50MB。`#Predicate` を使わない規約と相性が悪い)。
  3. `@Attribute(.externalStorage)` は隠しディレクトリ(`.default.store_SUPPORT/_EXTERNAL_DATA`)に散り、
     「すべてのデータを削除」(`QooViewerApp.swift:166` の sqlite/-wal/-shm 削除)が拾わない。専用フォルダなら
     全削除・本ごとの削除・起動時の孤児掃除(行の無いファイルを消す)を明示的に書ける。
- 形式: JPEG 品質 0.8、長辺 **512px**(コレクションの中のグリッドで最大サイズにしても Retina で足りる。
  タイルの 3×2 はここから縮小)。Retina 対応で 2 サイズ持つ必要は無い。
- **横長の画像は保存時に縦長(2:3)へトリミングする**(要望追加 2026-09-09): 右開きなら左側、左開きなら右側を残す
  (見開き1枚の画像なら表紙にあたる側)。読み方向はその本の実効値(DB の上書き > 環境設定の既定)。どちら側を切ったかを
  `CollectionItem.coverCropSide` に記録し、既定の読み方向や本の上書きが変わったら該当する本だけ作り直す(実装計画 §3.4・§3.5)。
  自動で決めた側が気に入らない本のために、メタデータ編集シート/「メタデータの編集」ウインドウのカバー画像の右クリックから
  **左端・中央・右端**を明示的に選べる(`BookLayoutSettings.coverCropAnchorRaw`、nil = 自動。明示した本は読み方向の変更に追従しない)。
  この指定はコレクションのグリッド表示だけに効き、EPUB/CBZ の書き出しのカバーはトリミングしない。
- **何を「先頭の画像」とするか**: 既存の書き出しのカバー決定ロジックをそのまま使う。
  `BookLayoutSettings.coverPageKey` / `externalCoverBookmarkData` があればそれ、無ければ
  `EffectivePageOrder.orderedPages(...)`(並べ替え・除外を反映した実効1ページ目)。
  `BookExportViewModel.resolveDefaultCoverName` / `resolveCoverOverride` が同じことをしているので、
  **`Services/CoverImageResolver.swift`(新規、`nonisolated`)へ切り出して両方から使う**。
- 抽出の実装: `BookLoader.load(from:)`(構造キャッシュがあれば速い)→ `PageLoader(book:)` →
  `gridThumbnail(at: index, maxPixelSize: 512, usesDiskCache: false)`。PDF/EPUB もこれで済む
  (EPUB の `cover-image` プロパティは `EpubStructureResolver` が今は見ていない。1ページ目=表紙が普通なので今回は追わない)。
  ソリッド 7z は先頭エントリなので安い。1冊1回、追加パネルの中で進捗を出しながら順に行う(キャンセル可)。
- **上書きが変わったら作り直す**: `layoutDataDidChange`(bookID 付き)を購読し、`hasCoverOverride` / `coverPageKey` /
  `externalCoverFileName` の直前の値との差分で再抽出(`ViewerViewModel.reloadLayoutData` と同じ「自分の現在値と比べる」方式)。
  これでメタデータ編集シート・「メタデータの編集」ウインドウ・EPUB/CBZ 書き出しウインドウのどこでカバーを変えても
  コレクションの表示に反映される。
- 抽出に失敗した本(アクセス権が無い・壊れている)は `coverStatus = 2` のプレースホルダ(灰色+形式バッジ)。
  「未取得」(`0`)の行(JSON 読み込み直後、§1.3-B の移行直後)は、ウェルカム画面が表示されている間に背景で
  1冊ずつ埋める(同時1、表示中の行を優先)。

### 2.3 ストアと他機能との接続

`ViewModels/CollectionStore.swift`(新規、`FavoritesStore` の写し)。通知名 `.collectionsDidChange`(userInfo に bookID)。

| つなぐ先 | やること |
|---|---|
| `AppStores` / `QooViewerApp.modelSchema` / `InMemoryLibrary` | 生成・スキーマ・テスト用コンテナに追加 |
| `MetadataEditorViewModel.collectKnownBookIDs` | コレクションの本を「知っている本」に含める |
| `BookExportViewModel.resolveURL` / `LibraryCleanupViewModel` の bookmarkData 解決 | `collectionStore.anyBookmarkData(forBookID:)` を解決の列に足す(お気に入りが今その役をしている) |
| `LibraryCleanupViewModel` / `LibraryCleanupWindow` | 「コレクション」列(所属数)と、本ごとの削除で所属も消す(お気に入りと同じ扱い)。カバーファイルも消す |
| `LibraryImportExportService` / `LibraryJSONSchema` | `formatVersion 4`: `libraries: [{name, collections: [{name, createdAt, books: [{path, bookmark, inode, title, addedAt}]}]}]`。**カバーは含めない**(50MB になる)。読み込み後は `coverStatus = 0` で背景抽出。上書き/統合の方針は他と同じ `ImportPolicy` |
| 「すべてのデータを削除」 | `CollectionCovers/` フォルダも消す(`QooViewerApp.swift` の全削除に1行) |
| シークレットウインドウ(`AppState.isPrivateWindow`) | コレクションの**表示と開くのは可**、追加・作成・編集・並び替えの保存は**グレーアウト**(アプリ全体の約束: 書き込みを伴う UI は消さず無効化)。`isPrivateWindow` のコメントの列挙に「コレクションの登録・編集・カバー抽出」を足す |
| その場限りの本(`MangaBook.isTransient`) | 登録対象外(sourceURL が先頭1枚の画像でしかない) |
| `MenuBarMenuRefresher` | `allObjectWillChangePublishers` に足す(足さないとメニューが古いまま。ただしコレクションはメニューに出ないので、実は**足さない**方が正しいかもしれない ―― `FavoritesStore` の publish がメニュー全体を作り直していた轍を踏まない。足さない方向で) |

### 2.4 画面構成と状態の置き場所

```
ContentView
 └ (currentBook == nil) WelcomeView(作り直し)
     ├ WelcomeTopBar(細い帯)
     │   [本を開く][履歴から開く]   ライブラリA  ライブラリB …            [+]
     └ WelcomeLibraryPane(広い面)
         ├ CollectionGridView(コレクション一覧)      右上: [+][編集][並び替え][━━●━━]
         │   └ CollectionTile(角丸正方形 3×2 カバー + 冊数バッジ + 名前)
         └ CollectionDetailView(コレクションの中)      左上: [←] 名前   右上: [+][編集][並び替え][━━●━━]
             └ CoverCell(カバーのみ。実体が無ければ暗く)
   シート: CollectionNameSheet(名前入力) / AddBooksPanel(本を追加) / BookMetadataSheet(メタデータ+カバー)
   ポップオーバー: RecentBooksPopover(履歴から開く)
```

- **状態(`WelcomeLibraryState`、`ObservableObject`)は `ContentView` が `@StateObject` で持つ**(WelcomeView は本を開くと
  消えるため。戻ってきたとき同じコレクションを開いた状態にする = Kindle と同じ)。選択中ライブラリ・開いている
  コレクション・編集モード・スライダー値・並び順を持ち、UserDefaults に保存するのは選択中ライブラリと2つの並び順と
  2つのサイズだけ。
- 「本を開く」= 既存の `appState.openWithPanel()`。「履歴から開く」= `.popover` に `RecentFilesStore.entries` の一覧
  (サイドパネル履歴モード `SidePanelHistorySectionView` の行と同じ見た目、右クリックで「履歴から削除」)。
  シークレットウインドウでは履歴を見せない約束なので**ボタンを無効化**。2つのボタンは `fixedSize` した幅の大きい方に
  揃える(`ViewThatFits` ではなく、実測 `MetadataButtonWidthEstimator` と同じ方式)。
- ライブラリのタブ: 左クリックで切替、右クリックで「名前を変更…」(+ Q2 次第で「削除…」)。`+` は名前入力シートを
  出して追加(空欄不可・重複不可はコレクションと同じ規則)。
- 既存の `WelcomeView` の「シークレットウインドウの説明」「ドラッグ&ドロップでも開ける」の文言は、下の面の
  空状態(「表示するコレクションがありません」)の脇に残す。**列幅の実測(`WelcomeQuickOpenWidth`)とそのテストは不要になる**
  (`docs/13` の「private を外した」記録も更新)。

### 2.5 ドラッグ&ドロップの経路

`BookFileDropTarget` のコメントは「受け口はウインドウ全体に1つ(`ContentView.applyFileDropTarget`)」を要求している。
ウェルカム画面ではドロップの意味が状態で変わる(非編集=開く / 編集モード=コレクション作成 / コレクションの中=追加)ので、
**受け口は1つのまま、振り分けを `AppState` 経由で差し替える**:

```swift
// AppState(ビューアが performViewerAction を登録するのと同じ形)
var welcomeDropHandler: (([URL]) -> Bool)?   // true を返したら「開く」に回さない
```

`WelcomeView` が onAppear で登録し、onDisappear で外す(`activeViewerToken` と同じトークン方式は不要。ウェルカム画面は
1ウインドウに同時に1つしか無い)。**シート(`AddBooksPanel`)は別 NSWindow なので ContentView の受け口が届かない** ――
そこだけ自前の `.onDrop` を持つ(`BookFileDropTarget` のコメントに例外として追記する)。

ドロップされた URL の分類(編集モード・追加パネル共通、`Services/CollectionDropClassifier.swift` 新規、`nonisolated`):

| ドロップされたもの | 判定 | 編集モード(一覧) | 追加パネル / コレクションの中 |
|---|---|---|---|
| 書庫 / PDF / EPUB のファイル | `isArchiveFile` / `isPDFFile` / `isEpubFile` | 本として、名前入力シート(本は入力済み) | 追加 |
| 画像が直下にあるフォルダ | `DirectoryBrowser.listing(...).containsImageFile` | 同上 | 追加 |
| 画像フォルダだけが並ぶフォルダ(章分け) | `ShelfFolderResolver` の規則2 | 同上(1冊) | 追加(1冊) |
| 直下に本があるフォルダ(棚) | `ShelfFolderResolver` の規則3 | **フォルダ名を入れた**名前入力シート。作成後は直下の本を全部追加(並びは `SiblingBookOrder`。`ShelfFolderResolver` が使う一覧と同じ) | **無視**(要望: 画像フォルダでないフォルダは無視) |
| それ以外(本の無いフォルダ、画像1枚) | ― | 無視 | 無視 |

`ShelfFolderResolver.firstBook` の判定を「先頭1冊」ではなく「直下の本の一覧」を返す形に一般化して共有する
(`resolvedBookURL` は今のまま、その上に `books(in:)` を足す)。複数アイテムを同時にドロップしたら、本は全部追加、
棚は1つ目だけ名前の既定値に使う(→ §5 Q4)。

サンドボックス: ドロップ/NSOpenPanel で得た URL はそのセッションでアクセス可能なので、`CollectionItem.bookmarkData` は
その場で作れる(`FavoritesStore.makeBookmarkData` と同じ)。棚フォルダの子も、親にアクセスできている間なら
子のブックマークを作れる。カバー抽出も同じ場で行う(**後回しにするとアクセス権が無くなる**。これが「登録時に抽出」の
もう1つの理由で、§2.2 の「背景で埋める」経路は `FolderAccessStore` の許可か bookmarkData の解決が効く本にしか使えない)。

### 2.6 名前入力シートと「本を追加」パネル

- `CollectionNameSheet`: `TextField` + 下に「キャンセル」「作成」の2ボタン(同幅。`.frame(minWidth:)` を揃える)。
  空欄 → 「コレクション名を入力してください」、同じライブラリに同名 → 「すでに同じ名前のコレクションが存在しています」を
  欄の下に赤字で出して `作成` を無効化(押させてから弾くのではなく、押せない+理由を表示。要望の「表示して拒否」を満たす)。
  比較は前後の空白を除いた完全一致(→ §5 Q3)。ライブラリの `+` と、ライブラリ/コレクションの「名前を変更」も同じシート
  (タイトルとボタン名だけ差し替え)。
- `AddBooksPanel`(シート): 上に「本を追加…」(NSOpenPanel、複数選択、ファイル+フォルダ可)、中央がドロップ面兼
  追加済み一覧(カバーの抽出進捗つき)、下に [完了]。「1冊も追加せずに完了」= コレクション作成の取り消し
  (**コレクション行は本が1冊入った時点で初めて insert** する。作ってから消すより、名前だけ持って待つ方が
  `save()` の回数も通知も減る)。編集モードのドロップから来た場合は、シートを開いた時点で既に本が入っている。
  コレクションの中の `+` からも同じパネル(その場合は「完了」で閉じるだけ)。

### 2.7 コレクション一覧グリッド

- `LazyVGrid(columns: [.adaptive(minimum: tileSize)])`。タイルの大きさはスライダー(120〜320pt、既定 180)。
  SwiftUI の Lazy コンテナは画面外セルを解放しないので、カバー画像は
  `LazyCellImageBudget`(`ThumbnailGridView` が使っているもの)で画面外のものを手放す。
- タイル: `RoundedRectangle(cornerRadius: tileSize * 0.08, style: .continuous)` の中に 3×2 の `Grid`。6冊未満は空スロット。
  右下に冊数のバッジ(塗り地つきなので輪郭不要)。名前は下に1行(中央省略)。
- 編集ボタン: `SidePanelNavButton` と同じ見た目。編集モード中は塗り(選択中のモードボタンと同じアクセント地)+
  アイコンを `checkmark` にして「終了」と分かるようにする(要望の「ボタン表示を変化」)。
- 編集モードの右クリック: 「名前を変更…」「削除…」(確認アラート。中の本は消えるがファイルには触れない旨)。
  非編集モードでは右クリックメニューを**付けない**(空のメニューを出さない、`WelcomeView` の既存コメントの方針)。
- 並び替えボタン: `Menu` に `FavoritesSortOption.Field` の3つ+昇順/降順(サイドパネルの並べ替えメニューと同じ形)。
- 空状態: 「表示するコレクションがありません」+ 既存の「ドラッグ&ドロップでも開ける」の案内。

### 2.8 コレクションの中

- 左上に戻るボタン(`chevron.backward`)+ コレクション名(編集モード中だけ `TextField`。Return で確定、空欄・重複なら元に戻す)。
- カバーのグリッド(セル幅はスライダー 80〜300pt)。**名前は出さない**(要望)。ツールチップ(`.help`)には出す。
  実体が無い本は `opacity(0.35)` + 形式バッジ(`existenceByFavoriteID` と同じ非同期の存在確認を `CollectionStore` にも持つ。
  アクティブ化・マウントで再確認。一覧の表示中にブックマークを解決しない ―― `RecentFilesStore` と同じ理由)。
- クリック → `appState.open(url:)`(ブックマーク解決→見つからなければ `Favorite Not Found` と同じ形のアラート
  「コレクションから削除」付き)。開くウインドウ/タブの選択は不要(ウェルカム画面 = 本を開いていない窓なので、その窓で開く)。
- 編集モードの右クリック: 「コレクションから削除」「メタデータを編集…」。
- ドロップ → 追加(§2.5)。`+` → NSOpenPanel。

### 2.9 メタデータ編集シートとカバー画像

要望の核: 「ここで登録したメタデータはメタデータ編集ウインドウと同じくロック」「ファイル名から解析した初期値」
「カバー画像もここで設定でき、EPUB 書き出しウインドウにも反映」「『メタデータの編集』にもカバーの項目を足す」。

- **ロック = `BookMetadata` の行がある**(既存の定義そのまま)。シートの [登録] は `BookMetadataStore.upsert`、
  初期値は登録済みなら DB、未登録なら `BookMetadataDeriver.derive(baseName:rules:)`。`MetadataEditorViewModel.Draft` /
  `makeInitialDraft` をそのまま使いたいので、1行分の Draft の生成を `MetadataEditorViewModel` から
  `static func` に切り出す(ウインドウ用の ViewModel をシートのために丸ごと作らない)。
- **カバーの正典は既存の `BookLayoutSettings.coverPageKey` / `externalCoverBookmarkData`**(新しい保存先を作らない)。
  だから EPUB/CBZ 書き出しウインドウには何もしなくても反映される。シート下部のカバー表示は `CollectionCovers/` の画像
  (上書きを変えたら §2.2 の再抽出で更新される)。
  - 画像ファイルのドロップ → `LayoutStore.setExternalCover`。
  - 右クリック →「本の中の画像を選ぶ…」(既存 `ExportCoverPickerContent` のページ一覧をそのまま出す)、
    「ファイルを選ぶ…」(NSOpenPanel、`.image`)、「既定に戻す」(`clearCoverOverride`)。
  - `ExportCoverPickerContent` / `ExportCoverCell` は `BookExportViewModel` に結び付いているので、カバー関連
    (`resolvedCoverNames` / `refreshCoverName` / `setCover` / `setExternalCover` / `resetCover` / `loadBookForCoverPicker`)を
    **`CoverOverrideController`(新規 `ObservableObject`)へ移し、`BookExportViewModel` はそれを持つ**形にする。
    `LayoutStore.setCoverPageKey(for: MangaBook, ...)` / `setExternalCover(for: MangaBook, ...)` は `MangaBook` を要求するので、
    シートから使うには `bookID` + `sourceURL` 版の overload が要る(`existingOrNewSettings` が inode を取るために URL を使う)。
- **「メタデータの編集」ウインドウにカバー列を足す**: `ExportCoverCell` と同じセル(表示名+▾、ポップオーバーでページ一覧/
  ファイル選択/既定に戻す)。列幅は他の列と同じく実測。ウインドウは本を開かないので URL は
  `BookExportViewModel.resolveURL` と同じ解決の列(bookmark/layout/metadata/collection の bookmarkData)で取る。
- 4欄以外(ComicInfo 由来の項目など)は出さない(要望どおり著者・タイトル・シリーズ・巻数)。

### 2.10 すりガラス面の輪郭(CLAUDE.md の約束)

ウェルカム画面は `PanelSurface.welcome` なので、新しい部品は全部この表で決めてから作る:

| 部品 | 対応 |
|---|---|
| 上の帯のボタン文字・ライブラリ名・空状態の文言・コレクション名・冊数以外の素の文字/アイコン | `.panelOutlinedContent()` |
| 選択中のライブラリ(アクセント地)・編集モード中の編集ボタン | `.panelOutlinedAccent(in:)` |
| カバー画像・冊数バッジ(塗り地)・名前入力欄 | 何もしない |
| 2つのスライダー | `.panelControlWell()` |
| シート・ポップオーバー・コンテキストメニューの中身 | 何もしない |

確認は「ライト+黒100%」「ダーク+白100%」の面で(確認後は面の設定を元に戻す)。

### 2.11 ローカライズ・用語

新しい文字列は 40 前後(ボタン・メニュー・空状態・シート・エラー・ツールチップ)。用語は用語表に足す:
**ライブラリ / コレクション / 本を追加 / コレクションから削除 / 履歴から開く**。「登録」はメタデータの語をそのまま。

---

## 3. ウェルカム画面へ戻る操作

- `ViewerAction.returnToWelcome` を追加。表示名は `PageBoundaryBehavior.returnToWelcome` と同じ "Return to Welcome Screen"
  (String Catalog に既にある)。`perform(_:)` の実体は `ViewerView.swift:1138-1143` と**同じ2行**
  (`viewModel.flushPendingSave()` → `appState.closeBook()`)。3か所目になるので `private func returnToWelcome()` にまとめる。
- キー設定: `bookNavigationGroup` の末尾。マウス設定: `assignableActions` の `.previousBook, .nextBook` の後。
  既定の割り当てはどちらも無し(`fillingMissingDefaults` は「割り当てが無い操作」を補わないので、既定辞書に入れなければよい)。
- サイドパネル: `SidePanelModeSwitcher` の左に **モードではない**ボタン(`books.vertical`。ウェルカム画面のアイコンと揃える)。
  `SidePanelView` は `AppState` を参照しない作りなので、`onReturnToWelcome: (() -> Void)?` を足し、`ContentView` が
  `currentBook != nil` のときだけ渡す(nil なら無効表示)。押しても `mode` は変えない。等分幅から外し、モードボタンと
  同じ高さ・正方形に近い幅で、間に細い区切り。
- ツールバー: `ViewerView.toolbar` の `HStack` 先頭に同じアイコンのボタン(`.panelIconButtonLabel()`、`.help("Return to Welcome Screen")`)。
  ページ送りの chevron 群と紛れないよう、間隔をひとつ広めに。
- `docs/09` の入力の節とサイドパネルの節に追記。

---

## 4. 触るファイル(見積り)

新規: `Models/FavoritesFeature.swift`, `Models/BookLibrary.swift`, `Models/BookCollection.swift`, `Models/CollectionItem.swift`,
`ViewModels/CollectionStore.swift`, `ViewModels/WelcomeLibraryState.swift`, `ViewModels/CoverOverrideController.swift`,
`Services/CoverImageResolver.swift`, `Services/CollectionCoverStore.swift`, `Services/CollectionDropClassifier.swift`,
`Views/Welcome/WelcomeView.swift`(置き換え), `WelcomeTopBar.swift`, `RecentBooksPopover.swift`, `CollectionGridView.swift`,
`CollectionTile.swift`, `CollectionDetailView.swift`, `CollectionNameSheet.swift`, `AddBooksPanel.swift`, `BookMetadataSheet.swift`,
`docs/14-library-collections.md`(実装後に docs/README から辿れる形で)。

変更: `QooViewerApp.swift`(スキーマ・メニュー・全削除), `AppStores.swift`, `AppState.swift`(drop handler, reconcile, open),
`ContentView.swift`(状態の所有、drop 振り分け、SidePanel の閉包), `ViewerView.swift`(戻るボタン、perform、お気に入り), `SidePanelView.swift`,
`ViewerAction.swift`, `KeyBindingSettingsView.swift`, `MouseBindingSettingsView.swift`, `KeyBindingStore.swift`,
`GeneralSettingsView.swift`, `OpeningSettingsView.swift`, `LayoutStore.swift`(bookID 版 overload), `BookExportViewModel.swift`(カバーを controller へ),
`Export/ExportWindowContent.swift`, `MetadataEditorViewModel.swift` / `MetadataEditorWindow.swift`(カバー列、Draft の切り出し),
`LibraryImportExportService.swift` / `LibraryJSONSchema.swift`(v4), `LibraryCleanupViewModel.swift` / `LibraryCleanupWindow.swift`,
`LibraryExportWindow.swift` / `LibraryImportWindow.swift`, `ShelfFolderResolver.swift`(一覧版), `BookFileDropTarget.swift`(コメント),
`Localizable.xcstrings`, `qooViewerTests/Support/InMemoryLibrary.swift`, docs 06/09/13。

テスト(既存の型に倣う): `CollectionStoreTests`(重複・ライブラリ違いの同名・カスケード・reconcile・並び)、
`CollectionDropClassifierTests`(フィクスチャのフォルダで棚/本/無視)、`CoverImageResolverTests`(上書き/除外/並べ替えの反映。
フィクスチャの golden と突き合わせ)、`LibraryJSONSchemaTests` に v4 の往復、`LibraryImportTests` に読み込み後の `coverStatus`、
`WelcomeQuickOpen*` のテストは削除。

---

## 5. 決めてほしいこと → 決定(2026-09-08)

| # | 質問 | 決定 |
|---|---|---|
| Q1 | 既存のお気に入りをコレクションへ1回だけ移すか(§1.3) | **移さない**(A)。データは残るが見えない |
| Q2 | ライブラリの削除を右クリックに足すか | **足す**(2つ以上あるときだけ、確認あり、中のコレクションごと消える) |
| Q3 | コレクション名の重複判定 | **前後の空白を除いた完全一致**(大文字小文字を区別) |
| Q4 | 棚フォルダのドロップで入れる本の範囲。複数の棚を同時にドロップしたら | **直下だけ**。複数なら**キューに積んで1つずつ順番に**名前入力シート→作成を繰り返す |
| Q5 | コレクションから本を開く先 | 左クリックは**そのウインドウ**。右クリックに「開く / 新規ノーマルウインドウで開く / 新規シークレットウインドウで開く / 新規タブで開く」(既存の `BookOpenContextMenuItems` と同じ4つ) |
| Q6 | コレクションの中の「更新日順」 | **「追加日順」**にする(メニューにもそう出す) |
| Q7 | カバーの保存先 | **Application Support のファイル**。本・コレクション・ライブラリを削除したら**一緒に消す** |
| Q8 | 着手順 | (1) お気に入り無効化 → (2) 戻る操作 → (3) モデル/ストア/カバー/JSON/テスト → (4) 帯と一覧 → (5) コレクションの中とメタデータ/カバー |

実装の詳細は [library-collections-plan.md](library-collections-plan.md)。
