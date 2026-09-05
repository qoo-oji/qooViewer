# 08. 書き出しと読み込み

## 本の書き出し(EPUB / PDF / CBZ)

### 共通の流れ(BookExportViewModel)

3形式は元々3つの独立したウインドウ+ViewModel のコピーでしたが、CBZ を足す時点で共通部分を
基底クラス `BookExportViewModel` へ集約し、各形式は `format` と `export(_:to:)` だけを持つ
サブクラス(`EpubExportViewModel` / `PDFExportViewModel` / `CbzExportViewModel`)になりました。
画面側も `ExportWindowContent` + `ExportWindowConfiguration` が共通で、形式が決めるのは
`BookExportFormat` の switch だけです(形式を増やすときに触るのは原則そのファイルだけ)。

1. **対象一覧**: レイアウト・ブックマーク・メタデータ(EPUB/CBZ はカバー上書きも)のどれかを持つ本。
   実在確認(`BookURLResolver`)はメインアクターの外で行い、結果が返るまで直前の一覧を出したまま
   (以前はウインドウを開くだけで、未接続ボリュームの本の数だけ秒単位ブロックした)。
   `bookmarksDidChange` / `layoutDataDidChange` / `bookMetadataDidChange` / `pageOrderSettingDidChange`
   で読み直す(ウインドウは単一インスタンスで ViewModel が使い回されるため)。
2. **絞り込み**(`BookExportRowFilter`): 保存データの3種は AND のチェックボックス、ファイル形式は
   単一選択。**絞り込みは見え方だけを変え、チェック(選択)には触れない**。「すべて選択」は
   表示中の行だけ。
3. **タイトル・著者**: メタデータ DB > `TitleAuthorFilenameParser` の推測、を初期値にして編集可。
4. **カバー**(EPUB/CBZ): 既定は実質的な先頭ページ(構造キャッシュがあれば読み込みなしで解決)。
   本の中のページか、本に含まれない外部ファイルを指定できる(外部ファイルは本の一部として
   扱わず、ビューアには現れない)。
5. **空き容量**: `volumeAvailableCapacityKey` を優先(`ForImportantUsage` は Finder の表示より
   ずっと小さい値を返して誤警告した)。元のサイズ×1.2 未満なら警告。
6. **実行**(`runExport`): 進捗・キャンセル・同名ファイルの確認(残りにも適用)・失敗の集約。
   **必ず一時ファイルへ書いてから置き換える** ―― 出力先に元の本と同じ場所を選ぶ(cbz を cbz として
   書き出す)と、Exporter が最初に既存ファイルを消すため元の本が読めなくなり、元も出力も失われた。
   一時ファイルは出力先と同じフォルダ(置き換えがリネームで済み、失敗しても中途半端なファイルが
   残らない)。
7. **材料**(`PreparedBook`): 生の `MangaBook`、`pageOrderOverride`、ページ単位の状態、
   見開き強制、**常に確定した読み方向**(上書きが無ければ環境設定の既定。Apple Books は
   `page-progression-direction` が無いと LTR として開く)、鍵で解決したブックマーク、カバー、
   タイトル・著者、メタデータ。
8. 出力する言語タグは表示言語から(`exportLanguageCode`。EPUB の `und` を Kindle Previewer が
   弾いたため)。

### いま開いている本を書き出す(右クリック)

`BookExportViewModel(loadsEligibleRows: false)` で一覧を通らず、**保存データの有無に関わらず**
書き出します。URL はユーザーが実際に開いたもの(`directSourceURLs`)、読み方向と見開きは
画面の表示状態(`OpenBookDisplayState`。DB > 画面 > 既定)で補います。

- 環境設定「レイアウト」の形式ごとの「保存先」が「保存先を設定」なら、**何も尋ねずに**その
  フォルダへ書き出す(要望の中心: 新しい本を開く → 書き出す → 次の本、を操作なしで繰り返す)。
  「毎回確認」ならメニューを選んだその場でフォルダ選択パネル → `OpenBookExportSheet`。
- 書き出しオプション(連番リネーム・除外ページを含める・CBZ の Volume)の**開いた直後の値**も
  環境設定の形式ごとの既定値から(画面のトグルは1回限りの上書き)。
- 終わったら `BookExportCompletionBehavior`(何もしない/次の本の最初のページ/次の本/本を閉じる/
  ウェルカム画面/毎回確認)。選択肢と文言は「最後のページで」と意図的に同じ。
- 後始末: 形式ごとの「保存データ: 削除」「履歴: 削除」。読書位置は `ViewerViewModel.discardReadingState()`
  (行を握っているため。以後書かない)、残りはストア経由、履歴は `RecentFilesStore.remove`。
- シートが出ている最中にウインドウを閉じられると、同名確認の `continuation` が永久に待つため
  `cancel()` で `.skip` として再開する。

### EPUB(EpubExporter)

- 固定レイアウト(`rendition:layout` = pre-paginated)。ページごとに画像を包む XHTML。
- spine の `itemref` に `page-spread-left/right` / `rendition:page-spread-center` を、
  `PageLayoutState.asEpubEquivalentSpreadPosition` で書く。`page-progression-direction` は常に出す。
- Kindle 向けの meta(`fixed-layout` / `original-resolution` / `primary-writing-mode` など)と
  `cover` の guide。
- シリーズは calibre(`calibre:series` / `calibre:series_index`)と EPUB3(`belongs-to-collection`
  / `group-position`)の両方。`group-position` は数値必須なので `exportableSeriesIndex`
  (数値に解釈できるときだけ。整数なら整数表記)。
- ファイル名は NFC 正規化(`BookExportShared.nfcNormalizedForExport`)。フォルダの本の NFD 名が
  そのまま zip に入ると読めないリーダーがあるため。
- JPEG/PNG/GIF 以外(WebP など)は PNG へ変換する(EPUB のコア画像形式に合わせる)。
- `dc:language` は表示言語のコード。
- 検証は epubcheck と Kindle Previewer 3 の CLI(→ [12](12-verification-and-debugging.md))。

### PDF(PDFExporter)

- `CGPDFContext` で作る。JPEG は再圧縮せず `passthrough` で埋め込む。
- CoreGraphics には `/ViewerPreferences`(読み方向)・`/PageLayout`(見開き)・XMP を書く API が
  無いため、**書き終えたあとに `PDFCatalogAugmenter` が増分更新で Catalog へ書き加える**。
  XMP には dc:title/creator と calibre の `series` / `series_index`(`PDFXMPMetadata`)。
- ページ単位のレイアウト(このページだけ単独/左右)は PDF に対応する概念が無く、失われる
  (以前の「見開き情報は失われる」バナーは、本全体の読み方向と見開き強制が入るようになった時点で外した)。
- カバーの概念が無いのでカバー列は出さない。

### CBZ(CbzExporter)

- 画像は無圧縮(stored)で zip へ。連番リネームは**既定 ON**(CBZ には読み順のメタデータが無く、
  リーダーはファイル名の並びだけでページ順を決めるため)。
- `ComicInfo.xml` は **v2.0 の XSD の要素順**で書く(v2.1 は草案で XSD が無い)。空の要素は出さない
  (Komga は空文字を「値がある」と解釈する)。中身が1つも無ければ同梱しない。
- `Manga` = `YesAndRightToLeft` で右開き(Komga が右開き表示に切り替える唯一の項目)。
  読むときは `Yes` を左開きと解釈しない(方向未指定の意味)。
- `Number` は文字列(「上」「下」もそのまま)。`Volume` は**巻数ではない**(Komga はシリーズ名へ
  連結、Kavita は巻として扱う)ので、オプション「Volume にも書き出す」(既定 OFF)。
- `<Pages>`: `Type="FrontCover"`(カバー)、`Bookmark`(ブックマーク名をそのまま往復)、
  `DoublePage`(「1枚に見開き2ページ分」の意味なので、qooViewer の `single` から変換)。
  ページ番号は **0 始まりで正準順**。
- 元の本(cbz/cbr/cb7・フォルダ)に `ComicInfo.xml` があれば、qooViewer が生成しない項目
  (出版社・あらすじなど)を引き継ぐ(`ComicInfoResolver`)。読み込み側の初回取り込みも同じ型。

## 画像の書き出し(ImageExporter)

- 「このページ/左のページ/右のページ」: 元のバイト列をそのまま(`PageLoader.exportableImage`)。
  **PDF のページは中の画像が JPEG なら .jpg、可逆なら .png**(以前は `rawImageData` が PDF で
  常に nil になり「画像を読み込めませんでした」になっていた)。拡張子は保存パネルを出す前に
  `exportableImageFileExtension` で決める。
- 「見開きを結合して書き出す」: フル解像度の2枚を画面の左右の順で1枚に(`combinedCGImage`。
  拡大鏡の結合画像と同じ関数)。
- メニューバー経由は `ImageExportKind`(クリック位置が無いので単ページ/左/右/結合の項目を
  並べる)、右クリックはクリック位置から対象を決める。
- ページ一覧・サイドパネルからの「画像を書き出す」は `PageContextMenuItems` で、書庫や PDF の
  中のページ(Finder で実物を示せないもの)にだけ出す。

## ライブラリデータの JSON 書き出し・読み込み

`LibraryImportExportService` と `LibraryJSONSchema`(`formatVersion` 3)。qooViewer 専用の
1ファイルで、お気に入り(フォルダ階層)・ブックマーク・レイアウト・メタデータ・メタデータの
推測ルールを選んで出し入れします。

- 本の照合は **bookID(パス)と inode の両方**。パスが変わっていても同じファイルなら
  「登録済み」と判定し、ローカルのセキュリティスコープ付きブックマークから現在の URL を解決する。
- 読み込みの方針はカテゴリごとに「上書き(置き換え)/マージ/無視」。推測ルールだけは
  「置き換え/無視」(マージという選択肢が無い。取り込むと自分の設定を丸ごと置き換える)。
- 書き込みは一括(`forceAddFavorites`、`BookmarkStore.addBookmarks`、`upsertAll`、
  `setPageLayoutStates`)。1件ずつだと SQLite への書き込みが行数ぶん走って非常に遅かった。
- 書き出し時にファイルが見つからなかった本は、カテゴリをまたいで重複なく1つのリストで見せる。
- 書き出し側は、書き出す本の URL を解決できたタイミングで識別子の補完(`backfill*`)も行う。
- 読み込み画面は、ファイルを選ぶ前後で部品を増減させない(選んだ瞬間にレイアウトが跳ねるため。
  無効化だけで対応)。

## 掃除のウインドウ

- 「保存データの削除」(`LibraryCleanupWindow`): 本1冊単位。実在判定は3値+「確認中」で
  非同期。チェックは絞り込みをまたいで積み上がる。
- 「履歴の削除」(`HistoryCleanupWindow`): 対になる画面で、形を揃えてある。ブックマークは解決しない。
