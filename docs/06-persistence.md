# 06. 永続化 ―― 何をどこに保存するか

## 一覧

| 何 | どこ | 担当 | 寿命・上限 |
|---|---|---|---|
| 読書位置(最後のページ・見開き/単ページ・読み方向・表示モード)+指紋 | SwiftData `BookReadingState` | `ViewerViewModel` が直接 | 環境設定「データを保持する本の数」(既定 500 冊)を超えたら古い順に自動削除 |
| ブックマーク | SwiftData `Bookmark` | `BookmarkStore` / `ViewerViewModel` | 無制限(自動削除しない) |
| レイアウト(本全体) | SwiftData `BookLayoutSettings` | `LayoutStore` | 無制限 |
| レイアウト(ページ単位) | SwiftData `PageLayoutOverride` | `LayoutStore` | 無制限 |
| お気に入り(**無効化中**) | SwiftData `FavoriteBook` / `FavoriteFolder` | `FavoritesStore` | 上限 999 件、フォルダ3階層(`FavoritesLimits`)。改善要望5で UI の入り口をすべて閉じた(`FavoritesFeature.isEnabled == false`)。モデル・ストア・ウインドウ・JSON は残してあり、フラグを true に戻せば以前の登録がそのまま見える |
| 書誌メタデータ | SwiftData `BookMetadata` | `BookMetadataStore` | 無制限 |
| ライブラリ / コレクション / その中の本 | SwiftData `BookLibrary` / `BookCollection` / `CollectionItem` | `CollectionStore` | 無制限。ライブラリは必ず1つ以上(既定のライブラリは名前を持たず表示言語で組み立てる)。→ [14](14-library-collections.md) |
| コレクション表紙(表示用) | `~/Library/Application Support/<bundle id>/CollectionCovers/<itemID>.jpg` | `CollectionCoverStore` | **キャッシュではない**(消えると登録した本を全冊読み直す)。長辺768px。上限も自動削除も無し。行と一緒に消す。起動時に孤児を掃除 |
| コレクション表紙(元画像) | `~/Library/Application Support/<bundle id>/CollectionCoverSources/<uuid>.jpg` | `CollectionCoverSourceStore` | 利用者が「ファイルを選ぶ…」で指定した画像の複製(長辺1536px)。**作り直せない**(元ファイルは捨てられているかもしれない)。`BookLayoutSettings.shelfCoverImageFileName` から参照し、起動時に孤児を掃除 |
| ホームの表示の状態 | UserDefaults(`qooViewer.welcome.*`) | `WelcomeLibraryState` | 選択中のライブラリ・並び順2つ・大きさ2つ・本棚/ファイルブラウザのモード。`qooViewer.pref.*` ではないので「初期設定に戻す」の対象外、全削除では消える |
| ファイルブラウザの表示の状態 | UserDefaults(`qooViewer.fileBrowser.*`、リストの列の幅と並びは `NSTableView … qooViewer.fileBrowser.list`) | `FileBrowserState` | 表示形式・アイコンの大きさ・左の幅・隠したリストの列・最後に表示したフォルダ(パスだけ)・一括リネームの前回の入力(JSON)。後ろの 2 つはシークレットウインドウでは書かない。「初期設定に戻す」の対象外。並べ替えの基準と向きはサイドパネルのフォルダブラウザと共通の `qooViewer.pref.folderBrowserSortKey` / `…Direction`。→ [15](15-file-browser.md#保存するもの) |
| よく使う項目 | UserDefaults(`qooViewer.fileBrowser.favoriteLocations`、JSON) | `FavoriteLocationStore` | パスだけ(読む権限は `FolderAccessStore`)。上限なし |
| 自動リネームの規則・除外・実行ログ | UserDefaults(`qooViewer.fileBrowser.autoRename.rules` JSON / `.excludedPaths` 配列 / `.activityLog` JSON) | `AutoRenameStore` / `AutoRenameActivityLog` | 規則 20・規則ごとの対象 20・除外 2000・ログ 500。対象はパス・ボリュームの UUID・**セキュリティスコープの無い**ブックマーク(移動の提案用)を持ち、読む権限は `FolderAccessStore`。SwiftData ではないので世代は増えない。「初期設定に戻す」の対象外、全削除では消える。保存データの書き出しには含めない。→ [15](15-file-browser.md#自動リネーム2026-09-15ユーザー要望) |
| 「置き換える」の退避の記録 | コンテナの `Application Support/FileOperations/replace-backups.json` | `ReplaceBackupJournal` | 置き換えの最中だけ 1 件ずつあり、片付けたら消す(空ならファイルごと)。落ちて残ったものは次の起動で `ReplaceBackupRecovery` が戻す。「すべてのデータを削除」で消える(終了時。→ [15](15-file-browser.md#保存するもの)) |
| 環境設定 | UserDefaults(`qooViewer.pref.*`) | `AppPreferences` | ― |
| 履歴 | UserDefaults(`recentBookEntries` + 旧 `recentBookBookmarks`) | `RecentFilesStore` | 環境設定「履歴の保存件数」(既定 30) |
| フォルダのアクセス権 | UserDefaults(`qooViewer.grantedFolderBookmarks`) | `FolderAccessStore` | 全削除でも残す |
| 最後に開いていた本 | UserDefaults | `LastActiveBookStore` | 1件 |
| キー・マウスの割り当て | UserDefaults(JSON、`*.v1` キー) | `KeyBindingStore` | ― |
| メタデータの規則・除外フォルダ | Application Support/qooMeta/settings.json | `MetadataRulesStore` | ― |
| メタデータの下書き(ロックしていない値) | Application Support/qooMeta/drafts.json | `MetadataDraftStore` | ― |
| スマートライブラリ(対象フォルダ・スマートコレクション・ピン留め) | UserDefaults(JSON、`qooViewer.smartLibrary.store`) | `SmartLibraryStore` | ― |
| スマートライブラリの前回の一覧(写し。消えても集め直せる) | Application Support/SmartLibrary/catalog.json | `SmartLibraryCatalog` | ― |
| フォルダ選択パネルの前回位置・固定の保存先 | UserDefaults(ブックマーク) | `LastUsedFolderMemory` | ― |
| 環境設定で最後に開いていた画面 | UserDefaults | `SettingsNavigator.selectedPaneDefaultsKey` | ― |
| コレクションのタイル | `~/Library/Caches/<bundle id>/CollectionTiles/<collectionID>-<署名>.jpg` | `CollectionTileImageStore` | **カバーから作り直せるキャッシュ**。上限 128MB、超えたら古いものから。1コレクションにつき新しい2枚まで。起動時に孤児を掃除 |
| サムネイル | `~/Library/Caches/...` | `ThumbnailDiskCache` | 既定 OFF、上限 200MB |
| ファイルブラウザの絵 | `~/Library/Caches/<bundle id>/FileBrowserThumbnails/<2 文字>/<鍵のハッシュ>.jpg` | `FileBrowserThumbnailDiskCache` | **既定 ON**、上限 200MB(環境設定「キャッシュ」)。鍵はボリューム + inode + 更新日時 + サイズ(→ [15](15-file-browser.md#サムネイル段階-7a7b2026-09-14)) |
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
11. **モデルを変えたら、スキーマの世代を1つ足す**(`StoreSchemaGuard.generations`)。足し忘れは
    `StoreSchemaGuardTests` が落とす。理由は次の節。
12. **足した列は、ディスク上の使い捨てストアで「書く → 閉じる → 開き直す」を通す**
    (`StorePersistenceTests` / `DisposableStore`)。メモリ内のストア(`InMemoryLibrary`)は
    開き直しも移行も通らない。

### 古いアプリで新しいストアを開くと、列が黙って消える(2026-09-11 の事故と対策)

**何が起きたか。** 1.55 で足したコレクション表紙の3列(`BookLayoutSettings.shelfCover*`)が、
131冊ぶん丸ごと空になった。1.55 で分離の移行を済ませた数時間後、`/Applications` に残っていた
**1つ前の qooViewer を起動した**(統一ログでアプリのパスを確認)。SwiftData は、ストアとモデルが
食い違うと**向きを問わず**軽量マイグレーションをかける ―― 新しい列を知らない古いモデルへの
「移行」は、その列を中身ごと削除する。エラーも警告も出ない。その後 1.55 を入れ直して列は戻ったが
中身は空で、起動時の孤児掃除が、参照を失った表紙の元画像(`CollectionCoverSources`)まで消した。
棚の表示は別に焼いた JPEG(`CollectionCovers`)なので何も変わらず、書き出しの一覧から消えたことで
初めて気づいた(改善要望6)。

同じ種類の事故は以前にもあった(同じバンドルIDの古いビルドが同じストアを開いてリレーションが
壊れた。`QooViewerApp.deleteStoreFiles` のコメント)。

**切り分けで分かったこと。**

- 使い捨てのストアで再現する: 新しいモデルで書く → 古いモデルで開く(**成功する**) → 新しいモデルで
  開き直すと、古いモデルが知らない列だけが空(`StoreSchemaGuardTests.olderModelSilentlyDropsNewerColumns`)
- 1.55 のコード自体は正しく保存していた。1.54 時代のストアの写しに分離の移行(アプリと同じ
  `CollectionCoverExtractor` の初期化)と zip の読み込みを通し、開き直して全件残ることを確認した
- **SQLite の持続履歴(`ACHANGE.ZCOLUMNS`)で「どの列が書かれたか」を読むのは当てにならない。**
  事故の後で見ると、移行も読み込みも `updatedAt` しか書いていないように見え、「保存されなかった」と
  一度誤診した。移行でエンティティの列の並びが変わると、古い履歴の列番号は意味を失う。
  当時の作業ログに残っていた「移行直後・読み込み直後の DB の件数」(131件入っていた)で覆った

**対策。**

| 対策 | どこ | 何を防ぐか |
|---|---|---|
| 開く前の番人 | `StoreSchemaGuard` / `QooViewerApp.confirmOpeningNewerStoreIfNeeded` | 新しいアプリが使ったストアを古いアプリが開こうとしたら、開かずに尋ねる(既定は終了) |
| スキーマの世代の表 | `StoreSchemaGuard.generations` + `StoreSchemaGuardTests` | 世代の上げ忘れ(番人の判定材料が古くなる) |
| 使い捨てストアのテスト | `DisposableStore` / `StorePersistenceTests` | 足した列が開き直しで残らない・前のバージョンのストアから移行できない |
| 前のバージョンのスキーマの写し | `SchemaSnapshot_1_54`(指紋を 1.54 時代の実物と照合) | 古いアプリを実際に走らせずに「前のバージョンのストア」を作る(テストホストはアプリそのもので、起動した瞬間に本物のストアを開くため、古いビルドを走らせること自体が事故になる) |
| 表紙の元画像の隔離 | `CollectionCoverSourceStore.sweepOrphans` | 参照が間違って消えたときに、作り直せない画像まで即座に消える(隔離した時刻を刻めなかったファイルは隔離から戻す ―― 元の更新時刻で期限を判定されてその場で消えるため) |

**番人の判定**(`StoreSchemaGuard.verdict`、純粋関数):

1. ストアが無い・いまのモデルと同じ版の指紋 → 開く(移行が起きない)
2. UserDefaults `qooViewer.store.schemaGeneration`(開けたときに記録する、**大きいほうを残す**)が
   自分の世代より大きい → **止める**
3. ストアのメタデータに、いまのモデルが知らないエンティティがある → **止める**(記録が消えていても分かる)
4. それ以外 → 古いストアからの移行なので開く

版の指紋は `NSManagedObjectModel.makeManagedObjectModel(for:)` の `entityVersionHashesByName` と、
ストアのメタデータの `NSStoreModelVersionHashes`。**両者が一致すること**(SwiftData がストアへ書く
ものと、番人がモデルから計算するものが同じであること)もテストで押さえてある。

**限界。** 番人を持たないバージョン(1.55 以前)へ戻したときは止められない。

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

5つのモデル(`Bookmark` / `BookLayoutSettings` / `BookMetadata` / `FavoriteBook` /
`CollectionItem`)は作成時の `FileNodeIdentifier` を持ち、本を開くたびに各ストアの
`reconcileBookIDIfMoved(book:)` が「現在のパスに行が無く、同じファイルの行がある」なら bookID を
書き換えます(同一ボリューム内の移動・リネームだけ。ボリュームをまたぐ移動は諦める)。
JSON 読み込みの重複判定も同じ識別子を使います。

**アプリ自身が移した・名前を変えた本は、開くのを待たずに付け替える**(2026-09-19。`BookRecordRelocator` / `BookRelocationPlan`)。
ファイルブラウザの操作・取り消し・自動リネームは `FileOperationService` を通り、新旧のパスが `FileSystemChange.relocations` で届くので、
5 つのストアの行と読書位置(`BookReadingState`)の `bookID` を新しいパスへ書き換える。フォルダごと動かした中の本もまとめて、
**別ボリュームへの移動でも**(inode とブックマークは新しい場所で取り直す ―― それまでは追えず、棚で「見つからない」本になって次の起動の
掃除の候補に挙がった)。移った先のパスにすでに行があるストアでは付け替えない(上の追従と同じ規則)。
ただし**「置き換える」で移した・写した行き先**(`FileSystemChange.replaced`)は、付け替えの前にそこにあった本の保存データを消す
(2026-09-22 の監査。残すと、新しい本が古い本の読書位置・ブックマーク・メタデータを引き継ぎ、移してきた本の保存データは
「移った先に行がある」で取り残された。置き換えられた本はゴミ箱へ行っており、ゴミ箱の中の本は「無い」扱い)。取り消しで
置き換えを戻しても、消した保存データは戻らない。取り消しで戻せば同じ仕組みで元へ戻る。
棚のキャプションは、付いていたのがファイル名から決まる題のときだけ新しい名前にする。テストの中で走るアプリでは繋がない。
**アプリの外(Finder)で動かした本も、開くのを待たずに付け替える**(2026-09-22、利用者の指示)。それまでは開いたときの追従だけで、
その間に次のことが起きていた: 読書位置が消えて 1 ページ目から始まる(開いたときの追従は 5 つのストアだけで、読書位置は付け替えず古い行が
残り続けた)、直したメタデータとロックが新しい名前に付いてこない(解析した本はすべて登録するので新しいパスに読みだけの行が先にでき、
「移った先に行がある」で追従をやめた)、ライブラリのキャプション・タイトル・並べ替え・検索が古いまま、ブックマーク・レイアウトの編集や
掃除のウインドウに古い名前で並ぶ、自動で追加するフォルダの走査が毎回その本を足そうとする。いまの経路:
- コレクションの実在確認(`CollectionStore.scheduleExistenceRefresh`)が記録と別のパスに本を見つけたら、`onBooksFoundAtNewPaths` →
  `AppStores.relocateBooksMovedOutsideTheApp` → `BookRecordRelocator`。
- それ以外の本(ライブラリ機能が OFF ならコレクションの本も)は、起動後に `ExternalMoveSweeper` が各ストアのブックマークを解決して探す
  (`BookExistenceProbe.locateAtRecordedPath` の `movedTo`。繋がっていないボリュームの本は見ない)。
- メタデータの編集ウインドウも開いたときに同じことをする(取りこぼしの受け皿)。
- 同じ本はこの起動の間に 1 度だけ試す(移った先に行があって付け替わらないストアがあると、実在確認のたびに繰り返すため)。
- 開いたときの追従でも、5 つのストアの `reconcileBookIDIfMoved` が返す元のパスから読書位置を付け替える(`BookRecordRelocator.relocateReadingStates`)。
- **メタデータだけは「移った先に行がある」の例外**: 移った先の行が読みだけ(`isParsedOnly`)で、元の行がそうでなければ、元の行で置き換える
  (`reconcileBookIDIfMoved` と `applyBookRelocation` の両方)。
- ブックマークを持たない記録(読書位置だけの本)は追えない。

**フォルダの本は、ページの鍵も付け替える**(2026-09-21。`PageKeyRelocation`、Services/BookRelocation.swift)。フォルダの本の `PageRef.sortKey` は
**絶対パス**(中の書庫・PDF のページも、その書庫の絶対パスが頭に付く)なので、本が動くと `bookID` だけでなく鍵の頭も変わる。鍵で持っている保存データ ――
`PageLayoutOverride.pageKey`・`BookLayoutSettings.coverPageKey` / `shelfCoverPageKey` / `pageOrderOverride`(ページの並べ替え)・`Bookmark.pageKey`・
`BookReadingState.lastPageKey` ―― は、
上の 2 つの経路(`reconcileBookIDIfMoved` と `applyBookRelocation`)で `bookID` と一緒に書き換える。それまでは `bookID` しか付け替えておらず、フォルダの本を
移す・名前を変えると、ページ単位のレイアウトと「本の中のページ」で選んだ表紙が黙って外れ、ブックマークは番号へ落ちていた(鍵が合わないので、並びが
変わると別のページを指す)。書庫・PDF・EPUB の本の鍵は本の中で閉じている(`/` で始まらない)ので無関係。
並べ替えは最初の版で漏れていた(同日の監査の M1): 鍵が合わないと `EffectivePageOrder` が黙って正準順へ戻し、付いてきたページ単位の見開きの指定が
別の並びに当たって組み合わせが崩れた(`pinPageOrderIfNeeded` が自動で固定した本も同じ)。並べ替えを書き換えた結果が既にある鍵と重なったら、先に出てきたほうを残す。
- **それ以前に移した本の行は、開いたときに直す**(`PageKeyRelocation.repairs` → `LayoutStore` / `BookmarkStore` の `repairStalePageKeys`。
  `AppState.open` が追従の直後に呼ぶ)。漏れた鍵は「昔の本のパス + 相対パス」で、昔のパスは分からないので、いまの本のページの相対パスで終わる鍵から
  候補を出し、漏れた鍵の全部に共通する候補が**ちょうど 1 つ**のときだけ直す。2 通りに読めるとき(昔のフォルダ名と同じ名前のサブフォルダに同じ名前の
  画像がある等)は推測せず何もしない。読書位置の鍵は直さない ―― 合わなければ番号で開き、ページを送った時点でいまの鍵に書き直される。
- `PageLayoutOverride.compositeKey`(`bookID` + NUL + `pageKey`)は、**保存して読み直すと NUL の手前で切れて戻ってくる**(2026-09-21 の実測)。
  もともとデバッグ表示用でどこからも読まれないので害は無いが、照合や検査に使ってはいけない。

識別子は **inode + ボリューム**の組で、ボリュームの同定は `volumeUUID`
(`.volumeUUIDStringKey`)を主、デバイス番号(`st_dev`)を控えとします。**デバイス番号は
マウント順で変わります** ―― 他のボリュームを先に挿しただけで変わることをディスクイメージで
実測しました(2026-09-10。同一ファイル・無変更で `st_dev` が 16777249 → 16777253)。
これに気づく前は外付けの本で5つのストアの追従がすべて黙って失敗しえたので、UUID を主に変えて
あります。`==` は「両方が UUID を持つときだけ UUID で、片方でも欠けていればデバイス番号で」
比べるため**推移的ではありません**(だから `hash(into:)` は inode だけを混ぜる。
この型を `Set` に入れてよいのは重複判定の用途だけ)。経緯と実測値は
`FileNodeIdentifier` の型コメントが正典です。

識別子を持たない古い行と、**UUID を持たない行**(UUID を記録する前に保存されたもの)は、本を
開けた(=アクセス権がある)タイミングで各ストアの `backfillFileNodeIdentifier` が書き足します
(対象の判定は `FileNodeIdentifier.needsBackfill`)。`AppState.open` はこれを**5つのストア
すべて**に対して呼びます ―― 1つでも漏らすと、外付けの本で追従するストアとしないストアが
混ざります。

`CollectionItem` だけは bookID と一緒に **`title` も新しいファイル名へ書き換えます**
(`MangaBook.title` をそのまま入れる。棚のカバー下キャプションを「ファイル名」にしていると、
古い名前が残ったままになるため)。`FavoriteBook.title` は触りません ―― お気に入りには表示名を
自分で付け替える操作があり、ユーザーが付けた名前を上書きしてはいけないからです。コレクションの
本にその操作はありません。`BookCollection.updatedAt`(棚の並び「更新順」の基準)も進めません。

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
- 外観タブの設定は `AppearanceSettings` が持つ(2026-09-22。ノーマルウインドウ用とシークレットウインドウ用の 2 揃い)。
  ノーマルの揃いは従来のキーのまま、シークレットの揃いは同じキーの末尾に `.privateWindow`。「初期設定に戻す」は揃いごと
  (`AppearanceSettings.resetToDefaults()` と `allKeys`。足し忘れは `AppearanceSettingsTests` が名前を挙げて落とす)。
  シークレットの揃いを初めて使うときにノーマルから写したかは `qooViewer.pref.privateAppearanceInitialized` に記録する
  (→ [09](09-ui-and-windows.md)「その他の小さな約束」)。
- 旧キー(`loopBehavior` → `firstPageBehavior` / `lastPageBehavior`、`interpolationQuality` の
  `"low"`)は init で読み替え、**旧キーはその場で削除**する(残すと「初期設定に戻す」のたびに
  復活する)。読み替えた値は UserDefaults へ直接書く(init 内の代入では保存されない)。
- nonisolated なコードから読む設定(履歴件数・シークレットモード既定・入れ子書庫の
  予算)は、`static let` のキー/既定値を公開し、そちらが UserDefaults を直接読む
  (`RecentFilesStore.maxCount`、`AppPreferences.isPrivateModeDefault`)。
  `AppPreferences` のプロパティ自身を読んでよいのは環境設定画面のトグルだけ。
- **撤去した設定のキーは UserDefaults から消さない**(古い版を起動した人の設定を壊さないため。
  プロパティと `keys(for:)` からは外すので「初期設定に戻す」でも消えない)。2026-09-13 に撤去したもの:
  `qooViewer.pref.usesFinderSortOrder`(並び順を Finder に揃える。`PageOrder.retiredSettingKey` として
  表紙の一度きりの作り直しだけが読む)、`qooViewer.pref.showSidePanelOnWelcome`(ウェルカム画面でも
  表示する)、`qooViewer.pref.showRecentFilesOnWelcome`(最近開いた本を表示する)。どれも読まれていない。

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

### LastActiveBookStore / LastUsedFolderMemory

いずれもセキュリティスコープ付きブックマークや JSON を保存する小さな仕組みで、
`AppPreferences` の「単純な値を1キーに」というパターンに合わないため分離してあります。

フォルダを選ぶパネル(書き出し先・固定の保存先)の開始位置は、選んだフォルダではなく**前回パネルを閉じた時点で見ていた場所**
(`LastUsedFolderMemory.folderPanelStartDirectory(current:)`。キー `….panelDirectory` にパスで持つ ―― 開始位置に権限は要らず、
親フォルダにはブックマークを作る権限が無い)。選んだフォルダそのものから始めると、中に入った状態で開くため
(2026-09-17、ユーザー指摘。よく使う項目の「＋」・自動リネームの「フォルダを追加…」・自動登録フォルダの「選択…」も同じ動き)。

## シークレットウインドウとその場限りの本

正典は `AppState.isPrivateWindow` のコメントです。要約:

- **ウインドウ単位の `let`**(Chrome のシークレットウインドウに倣った)。通常ウインドウと並行して使える。
- true のとき書かないもの: 履歴・最後に開いていた本・読書状態・ブックマーク/お気に入り/
  レイアウト/メタデータの登録と編集・コレクションへの登録と編集(ホームの編集モードに
  入れない。カバーの指定も変えられない)・EPUB/PDF/ComicInfo からの自動取り込み・サムネイルの
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
- ファイルブラウザ(改善要望7)は、ファイル操作そのものは許し、よく使う項目・最後に表示したフォルダ・一括リネームの前回の入力を書かない。
  自動リネームの規則も、シークレットウインドウの右クリック・ホームメニューからは作らせない(設定ウインドウ自体はアプリに 1 つで、どのウインドウにも属さない)
  (決定事項 Q8)。絵のディスクキャッシュ(`FileBrowserThumbnailDiskCache`)も書かない(読むのは許す。2026-09-14 まではシークレット
  ウインドウでも書いていた。→ [15](15-file-browser.md#シークレットウインドウ))。
- 新しい永続化経路を足すときは、`isPrivateWindow` のコメントに列挙したうえで同じガードを入れる
  (`grep -rn "skipsPersistence\|isPrivateWindow"`)。

## 削除とリセット

| 操作 | 場所 | 範囲 |
|---|---|---|
| 本ごとの保存データの削除 | 環境設定「リセット」→「保存データの削除」ウインドウ | 選んだ本の読書位置・ブックマーク・レイアウト・メタデータ・お気に入り・コレクションの登録(コレクション表紙も)。実在判定は3値(exists/missing/unknown)で、アクセス権が無くて確認できない本を「消えた」と誤解させない |
| 履歴の削除 | 同「履歴の削除」ウインドウ | 選んだ履歴。ブックマークは解決しない |
| ブックマークの全削除など | 各編集ウインドウ | ― |
| すべてのデータを削除 | 環境設定「リセット」 | **フォルダのアクセス権を除く、このアプリがディスクに保存したすべて**(ストアの実ファイル・キャッシュ・コレクション表紙の2つの保管庫・ファイルブラウザの「置き換える」の退避の記録・UserDefaults)。予約(`pendingFullResetDefaultsKey`)して**終了時**に実行し、次回起動時にも再確認する(開いたまま消すと didSet やウインドウ位置の保存が書き戻す)。起動時の再確認は**どのストアよりも先**(`AppStores.init` の先頭。以前は環境設定などが読み終えた後の `modelContainer` の中だけで、書き戻されて環境設定が残っていた)、対象も予約時と同じ範囲(表紙の元画像・札のキャッシュを含む)。実行前の確認と、実行後の終了は必須 |
| 書き出し後の後始末 | 環境設定「レイアウト」形式ごとの「保存データ/履歴: 削除」 | 書き出した本のぶんだけ |
