# 06. 永続化 ―― 何をどこに保存するか

## 一覧

| 何 | どこ | 担当 | 寿命・上限 |
|---|---|---|---|
| 読書位置(最後のページ・見開き/単ページ・読み方向・表示モード)+指紋 | SwiftData `BookReadingState` | `ViewerViewModel` が直接 | 環境設定「データを保持する本の数」(既定 500 冊)を超えたら古い順に自動削除 |
| ブックマーク | SwiftData `Bookmark` | `BookmarkStore` / `ViewerViewModel` | 無制限(自動削除しない) |
| レイアウト(本全体) | SwiftData `BookLayoutSettings` | `LayoutStore` | 無制限 |
| レイアウト(ページ単位) | SwiftData `PageLayoutOverride` | `LayoutStore` | 無制限 |
| お気に入り | SwiftData `FavoriteBook` / `FavoriteFolder` | `FavoritesStore` | 上限 999 件、フォルダ3階層(`FavoritesLimits`) |
| 書誌メタデータ | SwiftData `BookMetadata` | `BookMetadataStore` | 無制限 |
| 環境設定 | UserDefaults(`qooViewer.pref.*`) | `AppPreferences` | ― |
| 履歴 | UserDefaults(`recentBookEntries` + 旧 `recentBookBookmarks`) | `RecentFilesStore` | 環境設定「履歴の保存件数」(既定 30) |
| フォルダのアクセス権 | UserDefaults(`qooViewer.grantedFolderBookmarks`) | `FolderAccessStore` | 全削除でも残す |
| 最後に開いていた本 | UserDefaults | `LastActiveBookStore` | 1件 |
| キー・マウスの割り当て | UserDefaults(JSON、`*.v1` キー) | `KeyBindingStore` | ― |
| メタデータ推測ルール | UserDefaults(JSON) | `MetadataFormatStore` | ― |
| フォルダ選択パネルの前回位置・固定の保存先 | UserDefaults(ブックマーク) | `LastUsedFolderMemory` | ― |
| 環境設定で最後に開いていた画面 | UserDefaults | `SettingsNavigator.selectedPaneDefaultsKey` | ― |
| サムネイル | `~/Library/Caches/...` | `ThumbnailDiskCache` | 既定 OFF、上限 200MB |
| 本の構造とページ寸法 | `~/Library/Caches/...` | `BookPageListCache` | 環境設定「キャッシュ」で削除 |
| 入れ子書庫の一時ファイル | コンテナの `tmp/<pid>/` | `TemporaryFileStore` | 本を閉じる/起動時の掃除で消える |

すべての本ごとのデータの鍵は **bookID = パス文字列**です。パスが変わっても追従できるように、
各モデルは inode 番号とデバイス番号(`FileNodeIdentifier`)も持ちます(下記)。

## SwiftData の使い方 ―― 踏んだ落とし穴と規約

`QooViewerApp.modelContainer` が1つの `ModelContainer` を作り、**`mainContext` を全ストアと
`@Environment(\.modelContext)` が共有**します。

1. **`ModelContext` を増やさない。** 以前、ストアごとにコンテキストを分けていたところ、一方の
   コンテキストのオブジェクトへの更新・削除がもう一方に反映されず、静かに失敗していた。
2. **`@Attribute(.unique)` を付けない。** 同じコンテキストへ短時間に複数回 `insert()+save()`
   すると、一意制約を持つエンティティの upsert 処理が原因と思われる形で**既存の無関係な行が
   消える**不具合があった(1ページ目を設定した直後に2ページ目を設定すると1ページ目の設定が
   消える、と再現)。一意性はストア側が insert 前に既存行を確認して保証している。
   `Bookmark.id` / `FavoriteBook.id` のように毎回 `UUID()` を新規生成するだけのものも同様。
3. **`#Predicate` で絞り込まない。** `#Predicate<BookReadingState> { $0.bookID == bookID }` の
   ような絞り込みが、レイアウト変更直後などに**0件を誤って返す**ことが実機で確認された
   (キャプチャしたローカル変数名がモデルのプロパティ名と同名なのが関係している可能性が高い)。
   全件フェッチして Swift 側で filter し、各ストアが辞書のキャッシュ
   (`cachedSettingsByBookID` など)を持って insert/delete のたびに差分を反映する。
   例外は `FavoritesStore.reload()` の `parent == nil` / `folder == nil`(こちらは問題なく動いている)。
4. **後から属性を追加するときは、宣言時のデフォルト値を必ず付ける**(`var updatedAt: Date = Date()`)。
   無いと、その属性が無かった頃のデータを開く際に「Validation error missing attribute values
   on mandatory destination attribute」で起動できなくなる(`FavoriteBook.updatedAt` で実際に踏んだ)。
   スキーマの変更はライトウェイトマイグレーションで済む範囲に留める。
5. **永続化属性の名前を変えない・消さない。** `BookLayoutSettings.hasEpubLayoutLock`(未使用)、
   `Bookmark.isEpubDerived`(PDF のアウトライン由来にも使う)は、意味が変わったが名前を変えると
   マイグレーションになるためそのまま。
6. `FavoriteFolder` / `FavoriteBook` に `Identifiable` を付けない(付けると MainActor 自動分離の
   影響で `PersistentModel` に適合しないというビルドエラー)。`ForEach(..., id: \.id)` で使う。
7. `save()` の失敗を `try?` で握りつぶす箇所が多いが、ストアは `lastSaveErrorMessage` に残して
   `NSLog` する(Console.app で追える)。
8. **ストアが開けないときの復旧**: `modelContainer` の生成に失敗すると、起動時に「保存データを
   削除して作り直すか」を尋ねる `NSAlert` を出す。削除は `pendingStoreResetDefaultsKey` を立てて
   **終了時/次回起動時に**、SwiftData の実ファイル(sqlite + -wal/-shm)を `FileManager` で消す
   (開いている接続が無い時点で行うため)。
9. **削除済みオブジェクトへ書かない。** `ViewerViewModel` は自分の本の `BookReadingState` を
   握ったままページ送りのたびに書くので、「本ごとの保存データの削除」がその行を消したら
   `bookReadingStatesDidDelete` を投げて以後書かせない(`readingStateDiscarded`)。
   `LibraryDataPruner` も今開いている本(`ViewerViewModel.openBookIDs`)は消さない。
10. 保存はまとめて行う。ページ送りのたびの `save()` は 400ms デバウンス(`persistState`)、
    本を閉じるときに `flushPendingSave()`。一括登録(`upsertAll`、`forceAddFavorites`、
    `setPageLayoutStates`、`clearPageLayoutStates`)は保存と通知を1回にする(JSON 読み込みが
    1行ごとに SQLite へ書いて非常に遅かった)。

## 指紋と差し替え検知

bookID(パス)が同じでも中身が別物になっていることがあります(同じ名前で別の本を落とし直した、
フォルダの中身を入れ替えた)。`ContentFingerprint` = ページ数・更新日時・ファイルサイズ
(フォルダは nil)を軽量な指紋として使います。

- `BookReadingState` は開くたびに指紋を記録し、1つでも違えば「差し替えられた」とみなして
  古い読書位置とブックマークを捨て、初めて開く本として扱う(記録が無い古い行は差し替えなし扱い)。
- `BookLayoutSettings` も指紋を持ち、差し替えの疑いがあれば確認ダイアログ
  (`ViewerViewModel.pendingLayoutReplacementStatus`)を出す。解決(そのまま使う=指紋を更新/
  破棄=行を削除)まで DB のレイアウトには一切触れない(取り込みも自動レイアウトも見送る)。
  ページ数が一致するときだけ「そのまま使う」が選べる。シークレットウインドウでは検知しない
  (解決がどちらも DB 書き込みで、答えようがないため)。

## 移動・リネームへの追従

4つのモデル(`Bookmark` / `BookLayoutSettings` / `BookMetadata` / `FavoriteBook`)は作成時の
`FileNodeIdentifier`(inode + デバイス番号)を持ち、本を開くたびに各ストアの
`reconcileBookIDIfMoved(book:)` が「現在のパスに行が無く、同じ inode の行がある」なら bookID を
書き換えます(同一ボリューム内の移動・リネームだけ。ボリュームをまたぐ移動は諦める)。
識別子を持たない古い行は、本を開けた(=アクセス権がある)タイミングで `backfill*` が補完します。
JSON 読み込みの重複判定も inode を使います。

## 通知と自己エコー

各ストアは変更後に通知を投げ、購読側が読み直します(→ [03](03-architecture.md#通知notificationcenter))。
`ViewerViewModel` は自分が投げた通知を `object === self` で読み飛ばし、`reloadLayoutData` は
「マネージドオブジェクトは既に新しい値になっていて変更前が読めない」ため、自分の現在値
(`isContrastCorrectionEnabled` / `readingDirection` / `displayMode`)との比較で差分を取ります。

## UserDefaults のストア

### AppPreferences

- 1プロパティ=1キー(`qooViewer.pref.*`)、`didSet` で即保存。**init 内の代入では didSet が
  走らない**ので、init の最後で `applyThumbnailDiskCacheSettings()` と外観の適用を明示的に呼ぶ。
- 「初期設定に戻す」は、その画面のキーを UserDefaults から消し、`AppPreferences()` をもう1つ作り、
  その画面ぶんだけコピーする(`resetToDefaults(_:)`)。**既定値の正典は init の `?? 既定値` だけ**
  にし、2箇所に散らばらせないため。設定を1つ増やしたら `keys(for:)` と `apply(_:for:)` の
  両方へ足す(足し忘れるとその項目だけ戻らない。「文字の影」だけ戻らない、という報告があった)。
  画面の置き場所と `keys(for:)` は必ず揃える。
- **値を下げるとデータが消える設定(保持件数2つ)は「初期設定に戻す」の対象外**。
- 旧キー(`loopBehavior` → `firstPageBehavior` / `lastPageBehavior`、`interpolationQuality` の
  `"low"`)は init で読み替え、**旧キーはその場で削除**する(残すと「初期設定に戻す」のたびに
  復活する)。読み替えた値は UserDefaults へ直接書く(init 内の代入では保存されない)。
- nonisolated なコードから読む設定(並び順・履歴件数・シークレットモード既定・入れ子書庫の
  予算)は、`static let` のキー/既定値を公開し、そちらが UserDefaults を直接読む
  (`PageOrder.usesFinderOrder`、`RecentFilesStore.maxCount`、`AppPreferences.isPrivateModeDefault`)。
  `AppPreferences` のプロパティ自身を読んでよいのは環境設定画面のトグルだけ。

### RecentFilesStore

- 保存形式は新形式(ブックマーク+パス+フォルダかどうか)。旧形式(ブックマークの配列だけ)も
  **保存のたびに併せて書き続ける**(古いバージョンへ戻しても履歴が消えないように。片道の互換)。
- **一覧の表示ではブックマークを一切解決しない。** 解決は選ばれて開くとき(`resolveForOpening`)
  だけ。再検証はアプリのアクティブ化とボリュームのマウント/アンマウントで非同期に行う。
  以前はメニューを開く直前に全件を同期解決していて、AppKit のメニュー更新に間に合わず
  「ウインドウ」メニューの標準項目が丸ごと欠ける不具合があった。
- 重複判定はパス同士。同じ実体がブックマーク違いで2件入りうるので、削除はブックマークと
  パスの両方で照合する。

### FolderAccessStore

セキュリティスコープ付きブックマークの一覧を持ち、起動中ずっと `startAccessing` を維持。
`reload()` のたびに差分だけを開閉する(以前は init で1回開くだけで、追加直後のフォルダを
開かず、呼び出し側が自前で `startAccessing` して漏らしていた)。祖先が許可済みなら追加しない、
子孫の許可は冗長として取り除く。全削除でもこのキーだけは書き戻す。

### KeyBindingStore

- 基本(`fitToScreen`)と表示モード別の上書き(`fitWidth` / `fitWidthSplit` / `noScale`)を
  別の辞書で持つ。キーは `RemappableKey.id` / `MouseTrigger.id`(読める文字列)。
- 保存キーは `*.v1`。マウスの形式を変えたときは新しいキーに書き、旧キーは**読むだけで書き換えない**
  (取り下げても元に戻る)。
- 値は1件ずつ解決する(`resolveActions`)。辞書ごと `[String: ViewerAction]` にデコードすると
  知らない操作名1つで丸ごと既定値に戻ってしまう。改名した操作は `renamedActions` で読み替える。
- `fillingMissingDefaults`: 保存データに無い既定(後から足した操作)を、「そのキーが未使用で、
  その操作に割り当てが1つも無い」ときだけ補う。表示モード別の上書きには適用しない
  (項目が無いこと自体が「基本へフォールバック」の意味)。

### LastActiveBookStore / LastUsedFolderMemory / MetadataFormatStore

いずれもセキュリティスコープ付きブックマークや JSON を保存する小さな仕組みで、
`AppPreferences` の「単純な値を1キーに」というパターンに合わないため分離してあります。

## シークレットウインドウとその場限りの本

正典は `AppState.isPrivateWindow` のコメントです。要約:

- **ウインドウ単位の `let`**(Chrome のシークレットウインドウに倣った)。通常ウインドウと並行して使える。
- true のとき書かないもの: 履歴・最後に開いていた本・読書状態・ブックマーク/お気に入り/
  レイアウト/メタデータの登録と編集・EPUB/PDF/ComicInfo からの自動取り込み・サムネイルの
  ディスクキャッシュ・**構造キャッシュ(読みもしない**。同じ本でも開き方で挙動が変わるのを
  避けるため)・bookID の追従と識別子の補完。
- 既存データの**読み取り**(ブックマークへのジャンプ、保存済みレイアウトでの表示)は行う。
  書き込みを伴う UI は消さずにグレーアウトする(これがアプリ全体の約束)。
- **その場限りの本**(`MangaBook.isTransient`)は通常ウインドウでも同じものを書かない
  (`skipsPersistence = isPrivateWindow || book.isTransient`)。sourceURL が先頭1枚の画像で
  しかなく、本の識別子として使えないため。
- **フォルダのアクセス権だけは例外**(本の記録ではなく権限そのものなので、どちらでも保存してよい)。
- シークレットウインドウ固有: 履歴の**表示**も隠す、タイトルの「(シークレット)」表記。
  その場限りの本には適用しない。
- 実装: `ViewerViewModel` は DB に挿入しない独立した `BookReadingState` を使い(書いても残らない)、
  `persistState` でも `save()` を呼ばない。ファイル由来のブックマーク・メタデータは
  `ephemeralBookmarks` / `ephemeralMetadata`(メモリ上)に置いて合成する。`resolveKeys` は
  `persists: false` で「あるべき番号」を返すだけにし、表示用の独立コピーへ反映する
  (共有コンテキストのマネージドオブジェクトは save せずに書き換えても自動保存される)。
- 新しい永続化経路を足すときは、`isPrivateWindow` のコメントに列挙したうえで同じガードを入れる
  (`grep -rn "skipsPersistence\|isPrivateWindow"`)。

## 削除とリセット

| 操作 | 場所 | 範囲 |
|---|---|---|
| 本ごとの保存データの削除 | 環境設定「リセット」→「保存データの削除」ウインドウ | 選んだ本の読書位置・ブックマーク・レイアウト・メタデータ・お気に入り。実在判定は3値(exists/missing/unknown)で、アクセス権が無くて確認できない本を「消えた」と誤解させない |
| 履歴の削除 | 同「履歴の削除」ウインドウ | 選んだ履歴。ブックマークは解決しない |
| ブックマークの全削除など | 各編集ウインドウ | ― |
| すべてのデータを削除 | 環境設定「リセット」 | **フォルダのアクセス権を除く、このアプリがディスクに保存したすべて**(ストアの実ファイル・2つのキャッシュ・UserDefaults)。予約(`pendingFullResetDefaultsKey`)して**終了時**に実行し、次回起動時にも再確認する(開いたまま消すと didSet やウインドウ位置の保存が書き戻す)。実行前の確認と、実行後の終了は必須 |
| 書き出し後の後始末 | 環境設定「レイアウト」形式ごとの「保存データ/履歴: 削除」 | 書き出した本のぶんだけ |
