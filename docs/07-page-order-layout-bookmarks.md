# 07. ページの並び順・レイアウト・ブックマーク

このアプリで最も込み入った領域です。ソースの中では「設計コンセプト n 節」「実装検討
ドキュメント」という言葉で、かつて別に書かれた設計文書の章を参照していますが、その文書は
リポジトリには入っていません。本章はその内容をコードから復元したものです。

## 3つの並び順

| 名前 | 定義 | どこで使う |
|---|---|---|
| **正準順**(canonical) | ファイル名を `localizedStandardCompare`(Finder と同じ)で並べたもの | `BookLoader` が返す `MangaBook.pages`(`rawPages`)。ComicInfo のページ番号、CBZ の連番リネーム |
| **従来順**(legacy) | 1.36 以前の `.numeric` 比較。ロケールを見ず、大文字始まりが先に来る | 1.36 以前に保存された行の「番号」はこの並びで記録されている |
| **実効順**(effective) | 環境設定「並び順を Finder に揃える」 → `pageOrderOverride`(ユーザーの並べ替え) → 除外ページの除去、をこの順に適用したもの | `ViewerViewModel.book.pages`。`Bookmark.pageIndex` / `BookReadingState.lastPageIndex` が指す空間 |

- `PageOrder.usesFinderOrder` は UserDefaults を直接読む(既定 OFF。nonisolated なコードが読むため、
  `AppPreferences` を引数で配らない)。トグルの didSet は保存してから `pageOrderSettingDidChange`
  を投げ、開いている本・編集ウインドウ・書き出しウインドウがその場で並べ直す。
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

## 見開きの組み方(ViewerViewModel)

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
隣との関係で定義されるため、後から「Finder に揃える」を切り替えても組が壊れないように)。
1.36 以前のレイアウトを持つ本は `legacyPinIfNeeded` で**従来順**に固定します。

## レイアウト変更の反映(reloadLayoutData)

`layoutDataDidChange` を受けると、`rawPages` から実効順を組み立て直し、`book.pages` を丸ごと差し替え、
ブックマークの番号を振り直し、表示位置を決め直します。

- 通知は1回の操作で複数届くので 16ms(1フレーム)のデバウンス。冪等なので取りこぼしても
  余分に1回走るだけ。
- `focusPageKey`(ユーザーが直接操作したページ)があれば、そのページを更新後の表示に含める。
  ただし操作対象が「今の見開きの2枚目」で、新しいデータでも2枚組が成立するなら起点を動かさない
  (削除の順序に関係なく見開きを維持する)。除外で消えたページは `fallbackIndex` で近くへ。
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

`BookMetadata`(著者・タイトル・シリーズ・巻数、すべて文字列。空欄は空文字)。
「メタデータの編集」ウインドウ(`MetadataEditorViewModel`)は「このアプリが知っている本」
(読書履歴・お気に入り・ブックマーク・レイアウト・メタデータのどれかに記録がある本)を全部並べ、
未登録の行はファイル名から推測した値を出します(`BookMetadataDeriver`:
除外文字列で削る → ファイル名フォーマット(`@author` / `@title` / `@ignore`)で著者とタイトル →
巻数フォーマット(正規表現、末尾一致)でシリーズと巻数)。ルールは `MetadataFormatStore`
(UserDefaults)にあり、既定値はユーザー指定の 12 種のフォーマット・7 本の巻数ルール・3 本の除外
です。推測は数千行になりうるためメインアクターの外で行い、ルールが変わったら
`revision` で捨てます。登録済みの行はルールを変えても影響を受けません。

4項目とも空で登録しようとすると行を作らず(あれば削除)、「登録済みだが中身が無い」行を
作りません。ツールバーの表示名は「[著者] タイトル」(タイトルだけなら「タイトル」、
タイトルが無ければファイル名)。
