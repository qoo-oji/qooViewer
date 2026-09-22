# 07. ページの並び順・レイアウト・ブックマーク

このアプリで最も込み入った領域です。ソースの中では「設計コンセプト n 節」「実装検討
ドキュメント」という言葉で、かつて別に書かれた設計文書の章を参照していますが、その文書は
リポジトリには入っていません。本章はその内容をコードから復元したものです。

## 3つの並び順

| 名前 | 定義 | どこで使う |
|---|---|---|
| **正準順**(canonical) | ファイル名を `localizedStandardCompare`(Finder と同じ)で並べたもの | `BookLoader` が返す `MangaBook.pages`(`rawPages`)。ComicInfo のページ番号、CBZ の連番リネーム |
| **従来順**(legacy) | 1.36 以前の `.numeric` 比較(`compareLegacyPageOrder`)。ロケールを見ず、大文字始まりが先に来る | 1.36 以前に保存された行の「番号」はこの並びで記録されている。`pinPageOrderIfNeeded` の判定 |
| **実効順**(effective) | 正準順 → `pageOrderOverride`(ユーザーの並べ替え) → 除外ページの除去、をこの順に適用したもの | `ViewerViewModel.book.pages`。`Bookmark.pageIndex` / `BookReadingState.lastPageIndex` が指す空間 |

- **表示順の切り替えは無い**(2026-09-13 に撤去、改善要望7)。以前は環境設定「並び順を Finder に揃える」
  (1.37 で追加、既定 OFF → 2026-09-06 に既定 ON)が OFF のとき、実効順の名前順だけを従来順にしていた。
  UserDefaults の値(`PageOrder.retiredSettingKey`)は消していない。読むのは
  `CollectionCoverExtractor.refreshCoversForRetiredOrderSettingIfNeeded` だけで、OFF で使っていた人の
  コレクション表紙を起動時に一度だけ正準順の先頭へ合わせる(→ [14](14-library-collections.md))。
- **`EffectivePageOrder.orderedPages(for:pageOrderSource:pageOrderOverride:excludedKeys:)` が
  唯一の適用点**です。以前は `ViewerViewModel` と編集ウインドウに写しがあり、片方だけずれる
  不具合の温床でした。**渡すのは必ず正準順**(実効順を渡してはいけない)。
- `pageOrderSource == .document`(PDF/EPUB)の本は並べ替えません。
- `legacyOrderedPageKeys` は古い行の番号を鍵へ変換するためだけに使います。

## ページの鍵(pageKey)

ブックマーク・読書位置・ページ単位のレイアウトは、ページを **`PageRef.sortKey`** で指します
(→ [04](04-book-loading.md#ページの識別子))。`Bookmark.pageIndex` と
`BookReadingState.lastPageIndex` は**導出値**で、本を開くたび、並び順が変わるたびに鍵から
振り直します(`BookmarkStore.resolveKeys`、`ViewerViewModel.reloadBookmarks`)。

1.36 以前に保存された行は鍵を持たず、番号は**従来順**で記録されています。鍵へ変換するときは
必ず従来順の一覧を使い(今の並びで引くと別のページの鍵を焼き込んで復元できなくなる)、
変換は「以前から読んでいる本」に限ります(作りたての `lastPageIndex = 0` は記録ではない)。

## レイアウトのモデル

### BookLayoutSettings(本全体)

| 属性 | 意味 |
|---|---|
| `readingDirectionOverride` | 読み方向の上書き(nil なら `BookReadingState` → 環境設定の既定) |
| `forcedDisplayMode` | 見開き/単ページの強制 |
| `pageOrderOverride` | ページ順補正。鍵の並びを **JSON 文字列1カラム**で持つ(行を分けると並べ替えのたびに大量更新になる) |
| `didImportSourceLayout` | EPUB/PDF/ComicInfo のレイアウトを取り込み済みか(下記) |
| 指紋3つ | 差し替え検知(→ [06](06-persistence.md#指紋と差し替え検知)) |
| `bookmarkData` | 今開いていない本を編集ウインドウで扱うためのセキュリティスコープ付きブックマーク |
| `coverPageKey` / `coverPageDisplayName` / `externalCoverBookmarkData` / `externalCoverFileName` | 書き出しのカバー画像の上書き(→ [08](08-export-and-import.md)) |
| `contrastCorrectionEnabled` | 白黒補正(狭義のレイアウトではない) |
| `hasEpubLayoutLock` | **未使用**(スキーマ変更を避けて残してある) |

`isBookLevelSettingEmpty` は読み方向・見開き強制・ページ順補正の3つだけを見ます(カバーと
補正は「レイアウト情報がある本」の絞り込みに含めない)。

### PageLayoutOverride(ページ単位)

`(bookID, pageKey)` → `PageLayoutState`。「レイアウトなし」は行が**存在しない**ことで表します
(値として持つと「未設定」と「明示的になし」を区別できず、優先順位が複雑になる)。
`compositeKey` はデバッグ表示用で、区切りは NUL 文字(パスに現れない)。

| 状態 | 意味 | EPUB の語彙 |
|---|---|---|
| `single` | 単独で表示(前後と組まない) | `rendition:page-spread-center` |
| `spreadRight` | **画面の右**に置く | `page-spread-right` |
| `spreadLeft` | **画面の左**に置く | `page-spread-left` |
| `excluded` | 読書フローから完全に外す | (無し) |

見開き右/左は**画面上の絶対位置**です。読み方向によって「どちらと組むか」が変わります:
右開きなら「見開き右」= 読み順で先(次のページと組む起点)、「見開き左」= 2番目に読む
(直前のページと組む)。左開きは逆。以前、自動レイアウトが右開きの本で左右を逆に書いていた
報告があり、`anchor(forPageAtIndex:)` / `anchorPinStates` は読み方向で入れ替えます。

## ファイル側のレイアウトは1回だけ取り込む

EPUB(`page-progression-direction`、`rendition:spread`、ページ単位の spread プロパティ)、
PDF(`/ViewerPreferences/Direction`、`/PageLayout`)、ComicInfo.xml(`Manga`)が持つ情報は、
`LayoutStore.importSourceLayoutIfNeeded(for:)` が**初めて開いたときに1回だけ** DB へ書き、
`didImportSourceLayout` を立てます。以後は DB が権威で、ユーザーは自由に変えられます。

**以前は逆でした。** ファイルの指定が常に勝ち、読み方向・見開きのトグルは
グレーアウト(`isReadingDirectionLocked` など)していましたが、「取り込んだ結果ユーザーが何も
変えられない」のを避けるために転換し、ロックは廃止しました。今残るロックは
`isPageShiftLocked`(明示指定のある見開きを表示中は「1ページだけ送る」を無効にする)だけです。

優先順位は **DB(`BookLayoutSettings` / `PageLayoutOverride`) > `BookReadingState` > ファイル側の
ヒント(取り込みがまだ/行が無いときのフォールバック)**。`layoutHint(at:)` は DB → EPUB の順。

シークレットウインドウは取り込まない代わりに、「通常なら取り込まれていた状況(DB に上書きが
無く、保存済みの読書状態も無い)」のときだけ、ファイル側のヒントをメモリ上で適用します。

差し替えの疑い(`pendingLayoutReplacementStatus`)がある間は取り込みも自動レイアウトも
行いません(解決前に DB へ触らない約束)。解決後に改めて取り込みます。

`toggleDisplayMode` / `toggleReadingDirection` は、`BookLayoutSettings` に強制/上書きがある本
ではそちらへ書き戻します(書き戻さないと開き直すたびに元へ戻る)。無い本では
`BookReadingState` にしか残らないため、「いま開いている本を書き出す」ときは画面の表示状態
(`OpenBookDisplayState`)で補います(→ [08](08-export-and-import.md))。

## 見開きの組み方(SpreadPairing)

規則そのものは `Models/SpreadPairing.swift`(`nonisolated`)にあります。以前は
`ViewerViewModel` の 5 か所へ同じ形で書かれていました ―― どれも別々の時期に利用者報告を
受けて足されたもので、**同じ規則が別々に書かれている**という形自体が、片方だけ直して
もう片方が古いまま残る温床でした。`ViewerViewModel` 側は残っていますが、中身は
`layoutHint(at:)` と `wideImageCache` を閉包で渡して呼ぶだけです
(表引きのテストは `SpreadPairingTests` → [02](02-project-and-build.md#テストターゲットqooviewertests))。

### shouldPairWithNextPage

`targetIndex` を `targetIndex + 1` と組むか:

1. 見開きモードでなければ false。
2. `layoutHint(at:)` で両ページの明示指定を見る。読み方向に応じて「起点になれない位置」
   (右開き: center/left、左開き: center/right)、「次が単独/後ろと組む位置」(右開き:
   center/right、左開き: center/left)なら false。どちらかに明示指定があれば true。
3. 明示指定がどちらにも無いときだけ、**横長ヒューリスティック**(横÷縦 ≥ 環境設定の閾値、
   既定 1.0 なら単独)。ただし `previousDisplayedRange`(直前に表示した範囲)に `targetIndex + 1`
   が入っていれば false ―― 「1ページだけ送る」で手動でずらした組み合わせから前後へ動いたとき、
   直前の見開きの一方を無関係なページと組み直さないため。

### normalizedAnchorIndex

任意のページへ直接着地する経路(ジャンプ・再開位置・ループ折り返し・レイアウト変更後)で、
着地先が「2番目に読むページ」の指定を持つなら1つ前を起点にします(条件1)。着地先自身に
指定が無くても、直前のページが「起点」の指定を持ち、見開きモードなら同じく1つ前へ(条件2。
`honorsPredecessorClaim`)。条件2は「今の位置の描き直し」(focus 無しの `reloadLayoutData`)
では適用しません ―― 手動でずらした組み合わせが無関係な再読込で引き戻されるため。

### 歩幅(forwardStepSize / backwardStepSize)

`advance` は同期 API なので画像を読めません。明示指定だけで判定できる範囲は正しく計算し、
できない範囲は `wideImageCache`(一度でも横長判定したページの結果。鍵で持つ)を見て、
それも無ければ「今表示中の枚数」に近似します。`wideImageCache` は表示・通過・自動レイアウト・
下調べ(`primeWideImageCache` は近傍、`warmUpWideImageCacheForEntireBook` は本全体を
ヘッダー読み取りだけで)で埋まり、閾値の変更で捨てます。この仕組みは「前のページへ戻ると
単独ページを飛ばす」報告を何度か経て今の形になりました。`baseIndex` は待ち行列の末尾
(まだ表示していない目的地)を使います。

### EPUB 仕様 6.1.4 の空白ページ

見開きで相方が見つからないのに明示的な左右指定があるページは、**空白ページを挿入してでも
指定した側に置く**(EPUB Reading Systems 3.3 の MUST)。`currentSoleImageForcedSpreadPosition` と
`SpreadPageSlot.blank` がそれで、「qooViewer を EPUB 出力前のプレビューにしたい」という要望に
よります。

## 自動レイアウト(LayoutAutoCalculator)

起点(`Anchor`: 1〜2ページの鍵)から前後へ、横長ページは単独、それ以外を2枚ずつ組み、端数は末尾
へ回すパリティ計算です。入口は3つ:

- 「現在の表示を基準に自動でレイアウト」(`autoLayoutFromCurrentView`): 今の組み合わせを
  起点に本全体。実行前に確認ダイアログ(本全体を上書きするため)。
- ページ単位の操作(`setPageLayout(atIndex:to:scope:)`): `LayoutPropagationScope` で「この
  ページだけ/本全体/前だけ/後だけ」。「このページだけ」は相方の行に触れない(以前は相方も
  書き換えて「指示していないページまで変わる」報告があった)。
- 環境設定「レイアウトの保存データを持っていない本を開いたとき」(`missingLayoutAutoLayout`):
  1ページ目を単独/見開きの1枚目として本全体。**既にレイアウトがある本には何もしない**。

書き込みは `setPageLayoutStates` で1回のトランザクションにまとめ、起点の状態
(`anchorPinStates`)は計算結果を**上書きする側**でマージします(以前は先に書いていたため、
先頭ページを「見開き左」にしても `.single` に置き換わる不具合があった)。除外中のページは
計算対象から外れています(`book.pages` に含まれない)。

自動レイアウトを掛ける前に `pinPageOrderIfNeeded` で並びを固定します(ページごとのレイアウトは
隣との関係で定義されるため、名前の照合が変わっても組が壊れないように。設定を撤去した後も残しているのは、
正準順の `localizedStandardCompare` がロケール・OS の版に左右されうるため。OFF の時代に焼いた固定もそのまま効く)。
1.36 以前のレイアウトを持つ本は `legacyPinIfNeeded` で**従来順**に固定します。

## レイアウト変更の反映(reloadLayoutData)

`layoutDataDidChange` を受けると、`rawPages` から実効順を組み立て直し、`book.pages` を丸ごと差し替え、
ブックマークの番号を振り直し、表示位置を決め直します。

- 通知は1回の操作で複数届くので 16ms(1フレーム)のデバウンス。冪等なので取りこぼしても
  余分に1回走るだけ。
- `focusPageKey`(ユーザーが直接操作したページ)があれば、そのページを更新後の表示に含める。
  ただし操作対象が「今の見開きの2枚目」で、新しいデータでも2枚組が成立するなら起点を動かさない
  (削除の順序に関係なく見開きを維持する)。除外で消えたページは `PageLanding.fallbackIndex` で近くへ。
- 読み方向・見開き強制・コントラスト補正の上書きもここで即時反映(以前は開き直すまで反映されなかった)。
- `loadCurrentSpread(ignorePreviousDisplayedRange: true)`: 描き直しはページ送りではないので
  「直前のページを相方にしない」制約を掛けない(掛けると書き出し後の後始末で見開きが単ページに崩れた)。

## 編集ウインドウ(BookLayoutEditorViewModel)

「ブックマーク・レイアウトの編集」の右ペイン。ビューアとは独立に `BookLoader.load` で読み込み、
**除外ページも常に一覧に出す**(読書順の番号は無し)。

- 2段構え: 構造キャッシュがあれば行だけ先に描き、本体の読み込みが終わったら `PageLoader` を
  作ってサムネイルを後追いで埋める(`pageLoaderGeneration`)。本体が無い間はレイアウトの
  書き込みを無効化(`isBookReady`)。
- 並べ替え(ドラッグ/上下ボタン)は表示用のインデックス空間(除外ページを末尾へ回したもの)から
  真の並びへ変換する。除外ページは直前の読めるページに付いて移動する。
- 並べ替えで隣接関係が変わった `spreadLeft` / `spreadRight` は削除して警告バナーを出す
  (`single` / `excluded` は保持)。ブックマークは番号ではなくファイルに追従させる
  (`migrateBookmarkIndices`)。
- 除外を解除したページは、ファイル名基準の位置へ挿入し直す(除外中は位置がそのまま残るため)。
- `pageLayoutStates` は書き込み完了後に1回だけ確定したスナップショット(行ごとにフェッチすると
  書き込みの合間の状態を拾う)。
- `effectiveReadingDirection` はファイルのヒント > DB > 既定(`BookReadingState` は読まない)。

左ペインは `BookmarkStore.groups`(本ごとのまとめ)で、「ブックマークがある本のみ/レイアウト
情報がある本のみ」で絞り込み、ダブルクリックで本を開いてジャンプできます(今開いていない本は
`bookmarkData` から URL を解決)。

## ブックマーク

- `Bookmark`: `bookID` + `pageKey`(権威)+ `pageIndex`(導出)+ 名前 + `bookmarkData`
  (今開いていない本を開くため)+ `isEpubDerived` + inode。
- 追加は `ViewerViewModel.addBookmark(atIndex:)`。同じページには2つ付けない。名前は
  「Page N」を**作成時点の表示言語**で作る(後で言語を変えても変わらない)。
- 見開き表示中、クリック位置の無い経路(ツールバー・メニュー・キー)からの追加は
  `SpreadBookmarkTargetBehavior`(読み方向の既定側/毎回尋ねる)に従う。右クリックは
  クリックした側。
- 削除・リネームは `BookmarkStore` が直接 SwiftData を操作する(本を開いていなくても使えるため)。
  `ViewerViewModel` からは削除経路を外してある。
- **自動取り込み**: EPUB の nav.xhtml、PDF のアウトライン、ComicInfo.xml の `<Page Bookmark="">`
  から、その本にブックマークが1件も無いときだけ取り込む。`isEpubDerived = true` にして
  編集ウインドウには出さない(ビューアの一覧には出す)。ComicInfo のページ番号は**正準順**を
  指すので、実効順へ変換してから渡す。
- 「一括リネーム」シート(`BulkRenameBookmarksSheet`): 表紙・あとがき・奥付・おまけの固定名と
  連番。以前は独立ウインドウで bookID の橋渡しが要ったが、編集ウインドウのシートにして引数で
  受け取る形にした。

## 書誌メタデータ

`BookMetadata`(タイトル・著者の並び・ジャンル・イベント・原作・情報・シリーズ・巻数(表示用と並べ替え用)。
空欄は空文字)。2026-09-21 にファイル名からメタデータを作る処理を **qooMeta**(依存パッケージ。
[11](11-forked-dependencies.md))へ置き換え、qooMeta の欄を足しました(`author` は先頭の著者のまま、
2 人目以降は `additionalAuthorsRaw`。値の受け渡しは `BookMetadataValues`)。

「メタデータの編集」ウインドウは qooMeta のアプリの 3 ページ目(確認・編集)を移植したもの
(`Views/MetadataEditor/`: `MetadataWorkspace` + NSTableView の `MetadataBookTable`。右の詳細は持たない ―― 下記)。
対象(= メタデータを自動で作る本)は、開いた本・ライブラリの本(「このアプリが知っている本」、`KnownBooks`)と、
スマートライブラリの対象フォルダの中の本(`SmartLibraryCatalog.folderBookIDs()`)。ファイルブラウザの「よく使う項目」のフォルダの
中の本は、開くまで対象にしません(2026-09-22、利用者の指示)。並べた本はすべて DB に登録します(次の「解析した本はすべて登録」)。ルールセットは本ごとに
自動で選び(qooMeta の段 2 の「自動」と同じ条件。決まらない本は既定のルールセット)、ファイル名フォーマットと合致しなかった本は
一覧の上にまとめ(ファイル名をオレンジ)、帯の「表示」で絞り込めます。ツールバーから「解析の設定」「抽出の設定」(qooMeta の
規則の窓を移植した `Views/MetadataRules/`)を開きます。

**右の詳細は持たない**(利用者の指示 2026-09-21)。まとめて直す操作はすべて右クリックから: ロック / ロックを外す、1 つのシリーズに
する・巻を連番で振る(一覧の順)・シリーズから外す・巻を消す・提案に戻す、欄をまとめて変更、メタデータを再生成、
ファイル名の解析ルール(使うルールセットを切り替えるだけ。自動に戻すこともできる。変更した値は捨てず、読み直しは再生成で)、メタデータを削除(後述)。
実体の見つからない本は灰色(判定は `BookExistenceProbe`、「本ごとの保存データを削除」ウインドウと
同じ。確かめられなかった本は「無い」にしない)。保存データそのものの削除はこの窓には置かず、「本ごとの保存データを削除」ウインドウに任せる。表紙は一覧の「コレクションの表紙」の列(以前の窓と同じ `ExportCoverCell`)。

- **解析した本はすべて登録**(利用者の指示 2026-09-22。それまでの「ロック = 登録」を置き換えた)。「表示されているが保存されて
  いない」値は利用者には意味が分からない ―― そこで、ファイル名を解析した本は**いつも DB に行を持ち**、ロックは「その行を変えない」
  印になった(`BookMetadata.isLocked`。以前からある行はすべて利用者が登録したものなので、既定値はロック)。
  - ロックしていない行は、利用者が直した欄(`editsData`。qooMeta の `Confirmation`)と選んだルールセット(`ruleSet`)を持ち、
    値は「ファイル名の読み + 直した欄」から作り直されます。直した欄はすぐ DB へ書きます(青い文字)。規則を変えると、
    この窓は全冊を読み直して書き、窓の外では `AppStores` が `BookMetadataStore.reparseUnlockedRows` で全行を読み直します
    (互いを錨に。ロックした行は書かない)。「メタデータを再生成」は直した欄を捨てます。
  - ロックした行の値は、ロックしたときにしか書きません(`MetadataWorkspace.writeRows` の `lockChanged`)。鍵を外すと、見えていた
    値がすべて直した欄として残ります(外しただけで値が変わらないように)。
  - 登録する所: この窓(開いたとき `registerAll`、以後は変わった本)、スマートライブラリ(集め直すたびに、行の無い本とロックして
    いない行。`SmartLibraryCatalog.registerParsed`)、本を開いたとき(`registerParsed`。シークレットウインドウは除く)。
    除外フォルダの本は登録しません。スマートライブラリとこの窓は別の錨で読むので、同じ本に少し違う値を書くことがあります
    (後に書いたほうが残る。窓はロックと直した欄の違いだけを外の変更として受け、値の違いは受けない ―― 書き合いにならない)。
  - EPUB/PDF/ComicInfo.xml の書誌情報は、ロックしていない行に 1 冊につき 1 度だけ、直した欄として入れます(利用者が直した欄は
    変えない。`importSourceMetadata`、`didImportSourceMetadata`)。以前は「行が無い本だけ」でした。
  - 2026-09-21〜22 の下書き(drafts.json、`MetadataDraftStore`)は、起動時に 1 度だけ DB へ移してファイルを消します
    (ロックした行は変えない。読めないファイルは写しを残す)。
  - 取り消し(⌘Z。編集メニューの「取り消す」が `MetadataEditorUndoRouter` 経由でこの窓へ流れる)は、ロックしていない本の直しだけ。
  - 1 冊ぶんのシートは、変えた欄だけを直した欄にして書きます(ボタンは「保存」)。ロックした本の欄は変えさせません。
  - 保存データの JSON は、行ごとにロック・直した欄・ルールセットを書きます(`locked` が無い以前の行はロックとして入る)。
    「足す」はロックした行だけを守り、ロックしていない行は取り込む値で置き換えます。
- **登録済み = すべての欄が確定**。qooMeta へは確定した内容(シリーズがあれば `.series`、無ければ `.notInSeries`)として渡すので、
  規則を変えても登録した値は変わりません(以前からの約束)。シリーズの無い巻(「上」など)は `.notInSeries` に置き場が無いので、
  確定した欄の巻として渡します(2026-09-22 の監査。以前は落ちて、窓で見えず、鍵を掛け直すと巻の無い値で書き直された)。
  欄がすべて空の本には鍵を掛けません(DB は空の行を作らないので、印だけ付いて何も残らなかった)。錨として、ほかの本のシリーズの組にも効きます。
- **以前の版の欄で登録した行**(`BookMetadata.fieldsVersion == 0`。qooMeta へ置き換える前の 4 つの欄だけの登録、EPUB/PDF/ComicInfo
  からの取り込み、formatVersion 4 以前の保存データ)は、窓を開いたときに「空の欄だけ埋める(登録した値はロックしたまま。
  `BookMetadataStore.fillMissingFields`)/ ロックを外して解析し直す / あとで」を尋ねます。
- ツールバー(左から): すべて選択 / 選択を解除、メタデータを再生成(選んだ本のうちロックしていない本を解析・抽出し直す)、
  ロック / ロックを外す(選んだ本)、解析の設定、抽出の設定、除外フォルダ設定。
- **メタデータを削除**(右クリック。2026-09-22 に利用者の指示で作り直した): 選んだ本すべてが対象で、どの本でも押せます。
  DB の行を消し、一覧から外します。**覚えてはおかない** ―― 本を開き直す・窓を開き直すなどで解析されれば、また登録されます
  (除外フォルダへ入れる予定のフォルダの本のメタデータを消す、などが想定の使い方。利用者の指示)。以前は「登録か下書きの
  ある本だけ」が対象で、提案のままの本では淡色になり、押しても提案に戻るだけで一覧に残りました。
- **除外フォルダ**(UI 名「除外フォルダ設定」)(`MetadataRulesStore.excludedFolders`。ツールバーから。右クリックの
  「このフォルダを除外フォルダに追加」は、一覧に並ぶのは本なのにフォルダを指す項目で意味が通らない、と 2026-09-22 に外した): その中とサブフォルダの本はこの窓に
  並ばず、1 冊ぶんのシートで登録できず、本を開いたときの EPUB/PDF/ComicInfo からの取り込みもしません。登録済みのメタデータは
  消さず、除外フォルダ設定の窓の「…のメタデータを削除…」で消せます。
- 規則は `MetadataRulesStore`(コンテナの Application Support/qooMeta/settings.json。同梱の既定値との差分。スタンプの欄は
  UI を外したがデータは残してある)。
  以前の `MetadataFormatStore`(UserDefaults の 3 種の正規表現)は廃止し、既定から変えていたファイル名フォーマットだけを
  利用者のルールセット「qooViewer(以前の設定)」として 1 度だけ引き継ぎます。qooMeta の型は以前の書式より厳しい(`@title` か
  `@series` が要る・欄のあいだに区切りの文字が要る)ので、読めない書式は外してルールセットの説明に書き残し、**全部を引き継げた
  ときだけ**以前の値を消します(2026-09-22 の監査。以前は必ず消していて、1 つ混じるだけで全部失われた)。
  保存してある差分が差分としても読めない(手で直しかけた・`kind` が違う)間は、1 か所ずつの変更を断ります(「変更なし + 1 か所」で
  上書きされて消えていた)。JSON の欄が文字のまま見せて丸ごと書き直させ、「すべてを既定に戻す」は差分ごと戻します(元の設定
  ファイルの写しは読んだときに残す)。
- 1 冊ぶんのシート(`BookMetadataSheet`)の初期値は、DB か、qooMeta で 1 冊だけ読んだ提案。題の解決(`BookTitleResolver`)と
  書き出しの題・著者の初期値も同じ規則で読みます(`TitleAuthorFilenameParser` は廃止)。

4項目とも空で登録しようとすると行を作らず(あれば削除)、「登録済みだが中身が無い」行を
作りません。ツールバーの表示名は「[著者] タイトル」(タイトルだけなら「タイトル」、
タイトルが無ければファイル名)。
