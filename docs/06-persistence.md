# 06. 永続化 ―― 何をどこに保存するか

## 一覧

| 何 | どこ | 担当 | 寿命・上限 |
|---|---|---|---|
| 読書位置(最後のページ・見開き/単ページ・読み方向・表示モード)+指紋 | SwiftData `BookReadingState` | `ViewerViewModel` が直接 | 環境設定「データを保持する本の数」(既定 500 冊)を超えたら古い順に自動削除。保存データの書き出しに入る(2026-09-23 → [08](08-export-and-import.md#2026-09-23-に足した-4-カテゴリ)) |
| ブックマーク | SwiftData `Bookmark` | `BookmarkStore` / `ViewerViewModel` | 無制限(自動削除しない) |
| レイアウト(本全体) | SwiftData `BookLayoutSettings` | `LayoutStore` | 無制限 |
| レイアウト(ページ単位) | SwiftData `PageLayoutOverride` | `LayoutStore` | 無制限 |
| お気に入り(**無効化中**) | SwiftData `FavoriteBook` / `FavoriteFolder` | `FavoritesStore` | 上限 999 件、フォルダ3階層(`FavoritesLimits`)。改善要望5で UI の入り口をすべて閉じた(`FavoritesFeature.isEnabled == false`)。モデル・ストア・ウインドウ・JSON は残してあり、フラグを true に戻せば以前の登録がそのまま見える。無効の間は実体の確かめ直し・メニューを閉じたときの読み直しを始めない(2026-09-25) |
| 書誌メタデータ | SwiftData `BookMetadata` | `BookMetadataStore` | 無制限 |
| ライブラリ / コレクション / その中の本 | SwiftData `BookLibrary` / `BookCollection` / `CollectionItem` | `CollectionStore` | 無制限。ライブラリは必ず1つ以上(既定のライブラリは名前を持たず表示言語で組み立てる)。→ [14](14-library-collections.md) |
| コレクション表紙(表示用) | `~/Library/Application Support/<bundle id>/CollectionCovers/<itemID>.jpg` | `CollectionCoverStore` | **キャッシュではない**(消えると登録した本を全冊読み直す)。長辺768px。上限も自動削除も無し。行と一緒に消す。起動時に孤児を掃除 |
| コレクション表紙(元画像) | `~/Library/Application Support/<bundle id>/CollectionCoverSources/<uuid>.jpg` | `CollectionCoverSourceStore` | 利用者が「ファイルを選ぶ…」で指定した画像の複製(長辺1536px)。**作り直せない**(元ファイルは捨てられているかもしれない)。`BookLayoutSettings.shelfCoverImageFileName` から参照し、起動時に孤児を掃除 |
| ホームの表示の状態 | UserDefaults(`qooViewer.welcome.*`) | `WelcomeLibraryState` | 選択中のライブラリ・並び順2つ・大きさ2つ・本棚/ファイルブラウザのモード。`qooViewer.pref.*` ではないので「初期設定に戻す」の対象外、全削除では消える |
| ファイルブラウザの表示の状態 | UserDefaults(`qooViewer.fileBrowser.*`、リストの列の幅と並びは `NSTableView … qooViewer.fileBrowser.list`) | `FileBrowserState` | 表示形式・アイコンの大きさ・左の幅・隠したリストの列・最後に表示したフォルダ(パスだけ)・一括リネームの前回の入力(JSON)。後ろの 2 つはシークレットウインドウでは書かない。「初期設定に戻す」の対象外。並べ替えの基準と向きはサイドパネルのフォルダブラウザと共通の `qooViewer.pref.folderBrowserSortKey` / `…Direction`。→ [15](15-file-browser.md#保存するもの) |
| よく使う項目 | UserDefaults(`qooViewer.fileBrowser.favoriteLocations`、JSON) | `FavoriteLocationStore` | パスだけ(読む権限は `FolderAccessStore`)。上限なし。保存データの書き出しに入る(2026-09-23 → [08](08-export-and-import.md#2026-09-23-に足した-4-カテゴリ)) |
| 自動リネームの規則・除外・実行ログ | UserDefaults(`qooViewer.fileBrowser.autoRename.rules` JSON / `.excludedPaths` 配列 / `.activityLog` JSON) | `AutoRenameStore` / `AutoRenameActivityLog` | 規則 20・規則ごとの対象 20・除外 2000・ログ 500。対象はパス・ボリュームの UUID・**セキュリティスコープの無い**ブックマーク(移動の提案用)を持ち、読む権限は `FolderAccessStore`。SwiftData ではないので世代は増えない。「初期設定に戻す」の対象外、全削除では消える。**保存データの書き出しには規則と対象が入る**(2026-09-23。ボリュームの UUID・ブックマーク・確認の印は落とす → [08](08-export-and-import.md#2026-09-23-に足した-4-カテゴリ))。→ [15](15-file-browser.md#自動リネーム2026-09-15ユーザー要望) |
| 「置き換える」の退避の記録 | コンテナの `Application Support/FileOperations/replace-backups.json` | `ReplaceBackupJournal` | 置き換えの最中だけ 1 件ずつあり、片付けたら消す(空ならファイルごと)。落ちて残ったものは次の起動で `ReplaceBackupRecovery` が戻す。「すべてのデータを削除」で消える(終了時。→ [15](15-file-browser.md#保存するもの)) |
| 環境設定 | UserDefaults(`qooViewer.pref.*`) | `AppPreferences` | 保存データの書き出しに入る(2026-09-23。キーは接頭辞で拾う → [08](08-export-and-import.md#2026-09-23-に足した-4-カテゴリ)) |
| 履歴 | UserDefaults(`recentBookEntries` + 旧 `recentBookBookmarks`) | `RecentFilesStore` | 環境設定「履歴の保存件数」(既定 30)。**保存データの書き出しには入らない**(アクセス権と同じ理由) |
| フォルダのアクセス権 | UserDefaults(`qooViewer.grantedFolderBookmarks`) | `FolderAccessStore` | 全削除でも残す。**保存データの書き出しには入らない**(書き出した端末でしか意味を持たないブックマーク) |
| 最後に開いていた本 | UserDefaults | `LastActiveBookStore` | 1件 |
| キー・マウスの割り当て | UserDefaults(JSON、`*.v1` キー) | `KeyBindingStore` | 保存データの書き出しに入る(2026-09-23。環境設定と同じカテゴリ) |
| メタデータの規則 | Application Support/qooMeta/settings.json | `MetadataRulesStore` | 以前の除外フォルダ(`excludedFolders`)は読むだけで、起動時に 1 度だけシークレットフォルダへ移して空にする |
| シークレットフォルダ | UserDefaults(`qooViewer.secretFolders`、パスの配列。移行の印 `qooViewer.secretFolders.didMigrateLegacy` / 知らせの印 `…migrationNoticePending`) | `SecretFolderStore` | **`qooViewer.pref.*` には置かない**(「初期設定に戻す」で黙って消えると記録が再開する)。保存データの書き出しには「環境設定」のカテゴリと一緒に入る(取り込みは足すだけ。→ [08](08-export-and-import.md#シークレットフォルダformatversion-7)) |
| メタデータの下書き(ロックしていない値) | Application Support/qooMeta/drafts.json | `MetadataDraftStore` | ― |
| スマートライブラリ(対象フォルダ・スマートコレクション・ピン留め) | UserDefaults(JSON、`qooViewer.smartLibrary.store`) | `SmartLibraryStore` | 保存データの書き出しに入る(2026-09-23。対象フォルダはパスだけ) |
| スマートライブラリの前回の一覧(写し。消えても集め直せる) | Application Support/SmartLibrary/catalog.json | `SmartLibraryCatalog` | ― |
| メタデータ生成の母体の記録(コレクション・スマートライブラリの本のパス。写し) | Application Support/MetadataCorpus/corpus.json | `MetadataCorpusStore` | 「すべてのデータを削除」で消える(2026-09-23 の 3 回目の監査の中 11 まで残っていた) |
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
  古い読書位置を捨て、先頭から始める(記録が無い古い行は差し替えなし扱い)。**読み方向・見開き/単ページ・拡大縮小は
  引き継ぎ、ブックマークは `pageKey` が今の本にもあるものを残す**(2026-09-25。以前はどちらもすべて捨てていたが、判定は
  ページ数・更新日時・大きさを見るだけで、表紙を 1 枚足した・メタデータを書き足したといった同じ本のままの変化でも起きる)。
- **ページ数は除外・並べ替えを当てる前の本で数える**(2026-09-25)。1.71 までは読書位置の側だけ除外を当てた後の本で
  数えていて、記録は開いたときにしか書かないので、読んでいる途中でページを除外すると次に開いたとき「差し替え」と判断され、
  読書位置・読み方向・ブックマークが消えていた(「右開き/左開きが記憶されない」の報告の原因の 1 つ)。1.71 までの行は
  除外後の枚数を持つので、その枚数とも一致すれば同じ本とみなし、除外前の枚数に記録し直す。
- **フォルダの本は更新日時を比べない**(ページ数だけ。`ContentFingerprint.Snapshot.isDirectory`、2026-09-25)。フォルダの
  更新日時は中の項目の増減・改名で変わり、Finder が書く `.DS_Store` やネットワーク・FAT の `._` ファイルでも変わる。一方、
  中の画像を上書きしただけでは変わらない ―― 中身の目印にならない。比べていたため、Finder でフォルダを表示しただけで
  読書位置とブックマークが消えていた(同じ報告のもう 1 つの原因)。同じ枚数の別の本へ丸ごと入れ替えたフォルダは検知できない
  (受け入れた死角)。レイアウトの確認ダイアログも同じ規則になる。書庫・PDF・EPUB は従来どおり 3 点で比べる。
- `BookLayoutSettings` も指紋を持ち、差し替えの疑いがあれば確認ダイアログ
  (`ViewerViewModel.pendingLayoutReplacementStatus`)を出す。解決(そのまま使う=指紋を更新/
  破棄=狭義のレイアウトを消して指紋を今の中身で記録し直す)まで DB のレイアウトには一切触れない(取り込みも自動レイアウトも見送る)。
  破棄は 2026-10-04 の監査 BE-2 まで行ごと消していて、確認文が言わないコレクション表紙・切り出し位置・書き出し用のカバー・補正まで
  失わせていた(`LayoutStore.discardPageLayout`。行が残るので、指紋を記録し直さないと次に開くたびにまた尋ねる)。
  ページ数が一致するときだけ「そのまま使う」が選べる。シークレットウインドウでは検知しない
  (解決がどちらも DB 書き込みで、答えようがないため)。Esc は「そのまま使う」(何も失わない側。2026-09-26、docs/09「その他の
  小さな約束」)。

## 読書位置の行への書き込み(`ViewerViewModel.persistState`)

- 読み方向・見開き/単ページ・拡大縮小は、**そのビューアで変わった項目だけ**を書く(`persistedDisplaySettings` と比べる。
  2026-09-25)。「次の本へ」などは、その本が別のウインドウで開いていても自分のウインドウで開くので、同じ本を 2 つのビューアが
  開き、同じ行を握ることがある。以前は毎回すべての項目を書いていて、片方で変えた向きを、もう片方がページを送るたびに書き
  戻していた。読書位置(`lastPageIndex` / `lastPageKey`)は最後に読んだビューアのものを残す(従来どおり)。
- 環境設定「開始ページ」の「読み終えた本のみ最初から」は、**最後に表示していた画面に最後のページが写っていたか**
  (`BookReadingState.isAtLastPage`)で判定する(2026-09-27、環境設定の点検で見つけた)。以前は読書位置の番号だけを見ていて
  (`>= ページ数 - 1`)、見開きの最後の画面で閉じた本(記録されるのは見開きの先のページ = ページ数 - 2)が当たらず、見開き表示では
  この設定が働かなかった。番号での判定も残す(`isAtLastPage` を足す前の行は false のまま)。
- ComicInfo.xml の読み方向の取り込み(`importComicInfoIfNeeded`)は非同期で、読み終える前に利用者が向きを変えていたら
  (`hasUserChangedReadingDirection`)、ファイルの向きではなく利用者の向きを上書きとして記録して取り込み済みにする(見送ると
  次に開いたときにまた取り込んでしまう)。

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
ただし**「置き換える」で移した・写した行き先**(`FileSystemChange.replaced`)は、そこにあった本の保存データを新しい本に
引き継がせない(2026-09-22 の監査。残すと、新しい本が古い本の読書位置・ブックマーク・メタデータを引き継ぎ、移してきた本の保存データは
「移った先に行がある」で取り残された)。置き換えられた本が**ゴミ箱へ行った**なら、保存データもゴミ箱の中のパスへ付け替える
(`replacedIntoTrash`。ゴミ箱の中の本は「無い」扱い)。⌘Z で項目をゴミ箱から戻すと、`returnedFromTrash` で保存データも元へ戻る。
2026-09-23 の 3 回目の監査(中 1)までは一式を消していて、フォルダを置き換えると配下の全冊のコレクションの所属・ブックマーク・ロックが
取り消しでも戻らなかった。ゴミ箱へ行かなかった(ゴミ箱の無い場所ですぐに消した・隠し項目として残した)ものだけ、付け替えの前に消す。
どちらの知らせも読むのは `BookRecordRelocator` だけ(よく使う項目などを「ゴミ箱へ移った」と付いていかせないため `relocations` と分けた)。
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
- 見つけた一覧は「記録したパス → 今のパス」を同じ時点で並べた写しなので、**互いにつながない**
  (`FileSystemChange.foundOutsideTheApp` / `relocationsAreSimultaneous`: パスごとにいちばん深く当たる組を 1 つだけ当てる)。
  アプリの中の操作は起きた順に届くので、これまでどおりつなぐ。2026-09-23 の 3 回目の監査まで写しもつないでいて、Finder で
  2 巻 → 3 巻、1 巻 → 2 巻と振り直すと 1 巻の保存データが今の 3 巻に付き、入れ替えでは互いのデータが残っていた。
- 開いたときの追従でも、5 つのストアの `reconcileBookIDIfMoved` が返す元のパスから読書位置を付け替える(`BookRecordRelocator.relocateReadingStates`)。
- **メタデータだけは「移った先に行がある」の例外**: 移った先の行が読みだけ(`isParsedOnly`)で、元の行がそうでなければ、元の行で置き換える
  (`reconcileBookIDIfMoved` と `applyBookRelocation` の両方)。
- ブックマークを持たない記録(読書位置だけの本)は追えない。
- **パスだけで覚えているフォルダの設定**(シークレットフォルダ ―― 2026-10-03 より前はメタデータの除外フォルダ ―― ・スマートライブラリの対象フォルダ・コレクションの自動登録フォルダ)も
  付いていく(2026-09-22、利用者の指示)。設定の保存形式は変えず、パス → ブックマークの控え(`FolderSettingBookmarks`、UserDefaults)を
  別に持ち、起動時・アプリに戻ったとき・ボリュームを付けたときに解決して、動いていればアプリの中での移動と同じ `relocate(using:)` に通す
  (その中の本の保存データも同じ組で付け替える)。控えはアプリから離れるときと確かめた後に作る(ファイル選択のパネルで選んだ場所は
  その起動の間は読めるので、足した直後に Finder で名前を変えても間に合う)。以前の版で足した、読めない場所の設定は控えを作れず、パスだけのまま。

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

通知は**どの本のものかを付ける**(2026-09-25 の監査)。本を問わない通知は開いている全冊のビューアに全件のフェッチと組み直しをさせる
(付け替えは移動・リネームのたびに起きる)ので、`LayoutStore` / `BookmarkStore` の付け替え(`applyBookRelocation`)は付け替えた本の ID を
`BookRelocationPlan.relocatedBookIDsUserInfoKey` で付け、ビューアは `ViewerViewModel.notificationConcerns` で自分の本(新旧どちらか)の
ものだけ受ける。本を開くときの Bookmark の全件フェッチ・ファイルの識別子(`FileNodeIdentifier`)は 1 回ずつにして、5 つのストアの
`reconcileBookIDIfMoved(book:knownIdentifier:)` へ同じ値を渡す(以前は全件フェッチが 2〜3 回、識別子が最大 7 回)。差し替えと判断して
ブックマークを消したときも `.bookmarksDidChange` を出す(以前は出さず、編集ウインドウの一覧が消えた行を持ち続けた)。
`BookMetadataStore.allRecords()` は `revision` が同じ間は控えを返す。

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
- ホイールの振る舞い・スクロール量の設定(`setWheelBehavior` / `setScrollStep`)は、値が変わらなければ何もせず、変わった 1 つの
  塊だけを書く(2026-09-25。以前は全部の辞書を毎回書き直した)。
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
  書き込みを伴う UI は消さずにグレーアウトする(これがアプリ全体の約束)。**項目ごと消すのは、相手の機能(ライブラリ・スマートライブラリ・
  ファイルブラウザ)が OFF のときだけ**(2026-09-23、利用者の決定。それまでビューア・サイドパネルの「コレクションに登録」「スマートライブラリの
  対象に追加」、コレクションとスマートライブラリの「メタデータの編集…」「コレクションを作成/登録」はシークレットウインドウで消していた)。
  アラートの中の削除ボタン(「お気に入りから削除」「コレクションから削除」)は淡色にできないので出さないまま。
- **どのウインドウにも属さない編集ウインドウ**(「ブックマーク・レイアウトの編集」「お気に入りの編集」)は、「今読んでいる本」を
  `LaunchCoordinator.activeRecordableBookAppState`(シークレットウインドウと記録を残さない本を除く)から取る。これらは「ウインドウ」
  メニューからも開けるので、編集メニューを淡色にしても入り口は塞がらない ―― 2026-09-23 の監査まではシークレットウインドウの本を一覧に
  足して選び、ブックマーク・レイアウトを DB へ書けた(ページ一覧・サムネイルのキャッシュも)。通常のウインドウで作った保存データのある本は
  元から一覧に載り、それを編集するのは保存データの編集なので止めない。
- **本の書き出し**はシークレットウインドウでもできる(保存データを書かない)が、ページ一覧のディスクキャッシュは読み書きしない
  (`BookExportViewModel.usesPageListCache`。書き出し本体とカバー欄の両方。2026-09-23 まではどちらも既定のまま使っていた)。
- メニューバーのグレーアウトは `isPrivateWindow || currentBookLeavesNoRecord`(`MenuCheckmarkState`)。実際に断る側
  (`skipsPersistence`)と同じ条件 ―― 2026-09-23 まではメニューだけ `isTransient` を見ていて、一時フォルダに書き出した入れ子の書庫では
  押せるのに何も起きなかった。
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
  `FileBrowserState.isPrivate` は ContentView が `@StateObject` を作る時点で渡す(タブバーの「＋」のタブは、つなぐのが正当なタブと
  分かった後なので、2026-09-23 までは「シークレットモードで起動」のときに「＋」のタブが記録を書いていた。`ContentView.connectWindowState`)。
  自動リネームの規則も、シークレットウインドウの右クリック・ホームメニューからは作らせない(設定ウインドウ自体はアプリに 1 つで、どのウインドウにも属さない)
  (決定事項 Q8)。絵のディスクキャッシュ(`FileBrowserThumbnailDiskCache`)も書かない(読むのは許す。2026-09-14 まではシークレット
  ウインドウでも書いていた。→ [15](15-file-browser.md#シークレットウインドウ))。
- 新しい永続化経路を足すときは、`isPrivateWindow` のコメントに列挙したうえで同じガードを入れる
  (`grep -rn "skipsPersistence\|isPrivateWindow"`)。本を開かずに本のパスや中身を書く経路なら、シークレットフォルダの判定
  (`SecretFolderStore.isSecretAppWide`)も入れる(下の節)。

### シークレットフォルダ(2026-10-03)

利用者の要望で、メタデータの編集ウインドウの「除外フォルダ設定」(メタデータの登録だけを止めていた)を作り直した。調査・決定事項の
全体は [plans/secret-folder-plan.md](plans/secret-folder-plan.md)。

- **指定したフォルダの中(サブフォルダを含む)の本は、どの窓で開いても保存データに何も残さない。** 判定は窓ではなく本の場所で、
  開いた時点の値を本に持たせる(`MangaBook.isInSecretFolder`。`AppState.open` が読み込んだ直後に入れる)。表示している間に一覧が
  変わっても、次に開いたときから効く。
- 開いた本への書き込みは **`MangaBook.leavesNoRecord` に入れるだけ**で止まる。既存のコードは「窓がシークレット」(`isPrivateWindow`
  ―― 履歴の表示・ほかの本やフォルダへの操作)と「表示中の本が何も残さない」(`leavesNoRecord` ―― その本への書き込み)を既に分けて
  いた(その場限りの本のため)ので、窓の性質は**元のモードのまま**になる(利用者の決定: サイドパネルの履歴も隠さない)。
  `isPrivateWindow` を可変にする案は、約 180 か所の仕分けが要り、この振る舞いにも合わないので採らなかった。
- 見た目だけは実効の値で切り替える: 外観の揃い(`ContentView.showsAsPrivate` ―― **ビューアに出ている本**で決める。次の本の最初の
  見開きが揃うまで前の本を出しておくので、`currentBook` で替えると前の本が一瞬新しい外観になる)、タイトルの「(シークレット)」
  (こちらは題の本の名前と揃えて `currentBook` で決める)、ノーマルの窓で切り替わったときの知らせ。
- 同じ本の開き直しでシークレットかが変わったときは、ビューアを作り直す(`ViewerHandoff.viewIdentity` ―― ビューモデルの
  `skipsPersistence` は作るときに決まる)。
- 判定は `SecretFolderStore.Matcher`(フォルダを NFC・`/private` 抜き・末尾の `/` 抜きにそろえ、UTF-8 のバイト列で比べる)。
  **何冊も続けて確かめる所は 1 度作って使い回す**(2026-10-04 の監査: 以前は 1 冊ごとにフォルダの側も正規化し直し、正準等価で比べる
  `String.hasPrefix` で比べていたので、スマートライブラリの集め直し・メタデータ生成のたびにメインで 5 万冊・5 フォルダあたり約 0.4 秒。
  いまは約 0.07 秒)。ストアの `matcher` は `folders` より先に替える(`$folders` の知らせは値が替わる前に届くので、受け手が尋ねても
  新しい一覧で答える。受け手の `AppStores` の記録し直しも、届いた一覧で判定する)。
- 本を開かずに書く所は場所で断る(`SecretFolderStore.isSecretAppWide`。アプリの一覧の写しで、テストの作ったストアは書かない):
  `BookLoader.load` のページ一覧キャッシュ(全経路が通る 1 か所)、ファイルブラウザの絵のディスクキャッシュ
  (`FileBrowserThumbnailProvider`)、動画の絵の先作り、コレクションへの追加(`CollectionStore.makePendingItems` と自動登録フォルダ。
  保存データの読み込みは特別扱いしない)、表紙の抽出、表紙の指定(`CoverOverrideController.allowsCoverChanges`)、スマートライブラリの
  一覧と `catalog.json`、メタデータ生成の母体と `MetadataCorpusStore`、書き出し・「ブックマーク・レイアウトの編集」のキャッシュ。
- 既存の保存データは**読むが書かない**(シークレットウインドウと同じ)。移動への追従・保存データの読み込みも特別扱いしない。
  環境設定のペイン(`SecretFolderSettingsView`)でフォルダごとの冊数を出し、`BookSavedDataEraser` と履歴の削除でまとめて消せる
  (「保存データの削除」ウインドウと同じく取り消せない。確認のアラートでそう伝える)。
- 移行: 以前の一覧(`MetadataRulesStore` の settings.json の `excludedFolders`)は起動時に 1 度だけ移し、最初に**見えている窓**へ
  知らせる。済んだ印は利用者が答えたときに付ける(Finder から開いた起動では最初の窓が隠れたまま閉じられるので)。
- **「常にシークレットウインドウで開く」**(環境設定、既定 OFF。`AppPreferences.secretFolderBooksOpenPrivately` と開き先
  `SecretFolderPrivatePlacement` ―― いちばん手前のシークレットウインドウのタブ / その窓の本と入れ替え / 毎回新しいシークレット
  ウインドウ。前の 2 つはシークレットウインドウが無ければ新しく作る)。ON なら、ノーマルの窓からシークレットフォルダの本を開こうと
  すると、その本をシークレットウインドウへ回し、ノーマルの窓は今の中身のまま。判定は `BookWindowOpener.shouldOpenPrivately`。
  - **新しい窓を作る所は、作る前に回す**(`BookWindowOpener.open` と `QooViewerApp.openInNewWindow`)。ノーマルの窓は一瞬も出ない。
    Finder から本を渡されての起動では、透明にしてある主ウインドウ(`hideLaunchWindowWhenShown`)は回した先の窓が出た後の後始末で
    閉じる(CGWindowList で、透明のまま閉じることを実測)。新しいシークレットウインドウは**回さなければ出ていた位置**に出す
    (主ウインドウの代わりなら前回終了時の位置。ずらすと意味も無くずれたように見える ―― 利用者の指摘。今の画面に載らない位置なら
    使わない `visibleFrameOrNil`。タブで開くつもりだった要求は、元の窓に重ならないようずらした位置)。`onOpened` は回した先が開き
    終えてから呼ぶ(編集ウインドウが本も出ないまま閉じないように)。
  - 今の窓で開く所(`AppState.open`。次/前の本・サイドパネル・ホーム・ドロップ・履歴・Finder からの使い回し)は窓を作らないので、
    `AppState.privateRedirect` を出し、`ContentView` が受けて `BookWindowOpener.openSecretBookPrivately` を呼ぶ(`OpenWindowAction`
    は AppState に持たせない約束)。棚を読み替えた先がシークレットフォルダの本だったときもここで分かる(本を開くためだけに作られた
    窓で、まだ一度も本を出していなければ閉じる ―― **閉じるのは窓を作った要求の読み込みから回したときだけ**(`PrivateRedirect.
    closesUnusedWindow`。2026-10-04 の監査: 最初の本が開けずにホームへ戻った窓から後で開いた本を回したとき、使っていた窓が閉じた)。
    この形だけは窓が一瞬出る。棚の EPUB を飛ばして進んだ先も見る。棚のフォルダの
    アクセスは `SecurityScopedHandoff` で回した先へ渡す)。着地の指定(前の本の最後のページへ等)とスライドショーは、今ある
    シークレットウインドウで入れ替えるときだけ引き継ぐ(新しい窓・タブは自分で要求を開くので渡す口が無い)。
  - 設定は static(`AppPreferences.opensSecretFolderBooksPrivately` / `currentSecretFolderPrivatePlacement`)で読む。窓を作る所が
    インスタンスを持たないため。テストの中では常に OFF。
- **WindowGroup の値は表示中の本に揃える**(`ContentView.windowValue` / `WindowValueSync`。同日、実機で判明): `openWindow(id:value:)` は
  同じ値の窓があれば新しく作らずにそれを前へ出すだけなので、値が作ったときの本のままだと、別の本へ移った窓が「その本の窓」として前に
  出て、本は開かなかった(「入れ替え」の後に入れ替えられた本を新しいシークレットウインドウで開けなかった。次の本へ移った窓でも同じ)。
  本を閉じてホームに戻ったら・最初の本が出ずに読み込みが終わったら値は nil(読み込み中は触らない)。

## 削除とリセット

| 操作 | 場所 | 範囲 |
|---|---|---|
| 本ごとの保存データの削除 | 環境設定「リセット」→「保存データの削除」ウインドウ | 選んだ本の読書位置・ブックマーク・レイアウト・メタデータ・お気に入り・コレクションの登録(コレクション表紙も)。実在判定は3値(exists/missing/unknown)で、アクセス権が無くて確認できない本を「消えた」と誤解させない |
| 履歴の削除 | 同「履歴の削除」ウインドウ | 選んだ履歴。ブックマークは解決しない |
| ブックマークの全削除など | 各編集ウインドウ | 「レイアウトをすべて削除」は**狭義のレイアウト**(読み方向・見開き強制・ページ順・ページ単位の設定)だけ。コレクション表紙・切り出し位置・書き出し用のカバー・コントラスト補正は残す(`LayoutStore.discardPageLayout`。2026-10-04 の監査 BE-2 まで行ごと消していた) |
| すべてのデータを削除 | 環境設定「リセット」 | **フォルダのアクセス権を除く、このアプリがディスクに保存したすべて**(ストアの実ファイル・キャッシュ・コレクション表紙の2つの保管庫・ファイルブラウザの「置き換える」の退避の記録・UserDefaults)。予約(`pendingFullResetDefaultsKey`)して**終了時**に実行し、次回起動時にも再確認する(開いたまま消すと didSet やウインドウ位置の保存が書き戻す)。起動時の再確認は**どのストアよりも先**(`AppStores.init` の先頭。以前は環境設定などが読み終えた後の `modelContainer` の中だけで、書き戻されて環境設定が残っていた)、対象も予約時と同じ範囲(表紙の元画像・札のキャッシュを含む)。実行前の確認と、実行後の終了は必須 |
| 書き出し後の後始末 | 環境設定「レイアウト」形式ごとの「保存データ/履歴: 削除」 | 書き出した本のぶんだけ。保存データはブックマーク・狭義のレイアウト・メタデータ・読書位置で、お気に入り・コレクションの登録・コレクション表紙・切り出し位置は残す(2026-10-04 の決定 7) |
