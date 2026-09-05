# 04. 本を開く ―― ページ一覧ができるまで

## BookOpenRequest ―― 何冊の本にするか

ドロップ・Finder・Dock・「開く」パネル・サイドパネル・履歴・お気に入り、どの入口から来ても、
渡された URL の束はまず `BookOpenRequest.init(openingCandidates:)` に通します。判定はここ1箇所です。

- 全部が画像ファイルなら **1冊のその場限りの本**(`MangaBook.BookOrigin.imageFiles`)。
  1枚でも複数枚でも同じ扱い。上限 1000 枚(それ以上は先頭 1000 枚)。並びは
  `naturalOrderSortedByPath`(正準順)。
- それ以外(フォルダ・書庫・PDF・EPUB が混ざる)なら**先頭の1件だけ**。
- `recordsInHistory`: フォルダブラウザで「通り抜けただけのフォルダ」を履歴に残さないための旗。
- ランダムな値を含まない(同じ入力から同じ request ができる。`WindowGroup(for:)` の値として
  使うため)。

## AppState.open(request:) の流れ

1. 進行中の読み込みがあれば `openToken` を進めて結果を捨てる(`cancelOpen` も同じ)。
2. 前の本の `securityScopedBookURLs` を閉じ、新しい URL を開く。開けなければ
   `ensureAccess`(フォルダのアクセス権を求めるパネル)へ。
3. `loadingProgress` を立てて `BookLoader.load(from:)` を待つ。`BookLoadingOverlay` は 400ms
   待ってから出る(普通の本は一瞬で開くので、無条件に出すと点滅する)。
4. 成功したら `reconcileBookIDIfMoved(book:)` を `FavoritesStore` / `BookmarkStore` /
   `LayoutStore` / `BookMetadataStore` の4つで呼ぶ(同一ボリューム内の移動・リネームに
   inode で追従。→ [06](06-persistence.md#移動リネームへの追従))。
5. 履歴(`RecentFilesStore.record`)と `LastActiveBookStore.record`。シークレットウインドウと
   その場限りの本では行わない。
6. `currentBook` を差し替える → `ContentView` が `ViewerView` を作り直す。
7. `reloadSiblingBooks()`(「次の本へ/前の本へ」の一覧を `SiblingFinder` で作り直す)。

## BookLoader ―― 形式ごとの分岐

`BookLoader.load(from:progress:)` は `Task.detached` の中で動きます(走査と展開は遅い)。

| 入力 | 処理 | ページ順の由来 |
|---|---|---|
| フォルダ | `loadFolder` → `collectPages(inFolder:)` を再帰。中に書庫があれば `collectPages(at:)` で中まで辿る | `.fileName`(正準順) |
| zip/cbz/rar/cbr/7z/cb7 | `loadArchive` → `makeArchiveReader` → `collectPages(at:)`。中の書庫も再帰 | `.fileName` |
| PDF | `loadPDF`(`CGPDFDocument`)。ページ数ぶんの `PageRef` | `.document` |
| EPUB | `loadEpub`(`EpubStructureResolver`)。spine の順に画像を解決 | `.document` |
| 画像ファイル群 | `load(imageFiles:)` | `.fileName` |

**`pageOrderSource` は `MangaBook` を作り直すとき必ず引き継いでください。** `.document` の本
(PDF/EPUB)を名前順に並べ替えてはいけません。`origin` も同様で、落とすとその場限りの本が
通常の本と誤認され、右クリックの「本の書き出し」が有効になって1ページだけのファイルが黙って
できます(`ViewerViewModel.prepareBook` のコメント)。

書庫の展開サイズには上限があります(コミット `f2a635f`。細工されたファイルでのクラッシュ防止。
`ArchiveReading.extract(to:maxByteCount:)` / `dataPrefix`)。

## ページの識別子

`PageRef` は次の2つの文字列を持ちます。**どちらも決して変えてはいけません。**

- `id` = `"\(idPrefix)#\(path)"`: ビューの識別と `initialPageID`(「同じフォルダの画像を
  すべて開く」で元の画像へ着地する)に使う。
- `sortKey` = `"\(prefix)/\(path)"`: **DB の `pageKey`** に使う(ブックマーク・レイアウト・
  読書位置がこの文字列でページを指す)。フォルダの本ならファイルの絶対パス、書庫なら
  エントリのパス(入れ子は親のパスを `/` で連結)、PDF/EPUB はゼロ埋めの連番(`%06d`)。

`id` と `sortKey` で区切り文字が違うのは、書庫の中に `a.zip` というファイルと `a.zip/` という
フォルダが同居するような本で、`sortKey` が偶然一致しうるためです(`id` は衝突しない)。
`sortKey` をキーにする辞書は `uniquingKeysWith` で「最初の1件を採る」形にしてあります。

`PageSource`(`.file(URL)` / `.archive(locator, path)` / `.pdf(URL, pageIndex)` / EPUB)と
`PageLocation`(本の直下からの相対パス。表示用)も `PageRef` から引けます。

## MangaBook

| プロパティ | 意味 |
|---|---|
| `id` | bookID。**パス文字列そのもの**(`sourceURL.path`)。DB のすべての本ごとのデータの鍵 |
| `title` / `displayName(locale:)` | 表示名。画像群の本だけ「(N images)」を添える |
| `sourceURL` | 実体。画像群の本では先頭1枚の画像 |
| `pages` | `var`。除外・並べ替えの反映で差し替える |
| `pageOrderSource` | `.fileName` / `.document` |
| `sourceLayoutHint` | EPUB/PDF が持つ読み方向・見開き強制(`SourceLayoutHint`)。ComicInfo からも作る |
| `origin` | `.fileSystem` / `.imageFiles` |
| `isTransient` | 画像群の本。DB へ書かない |
| `isIdentifiedBySourceURL` | 「同じ本を開いているウインドウ」の判定に使えるか(画像群の本は不可) |

## 書庫の読み取り(ArchiveReading)

```swift
protocol ArchiveReading {
    func listFilePaths() throws -> [String]
    func data(at path: String) throws -> Data
    func dataPrefix(at path: String, maxByteCount: Int) throws -> Data
    func entryDates() -> [String: Date]            // 「情報を見る」用
    func entryUncompressedSize(at:) -> Int?
    func extract(to url: URL, path: String, maxByteCount: Int) throws
    var residentDecompressionBufferBytes: Int { get }
}
```

- `ZipArchiveReader`(ZIPFoundation)、`RarArchiveReader`(Unrar.swift フォーク)、
  `SevenZipArchiveReader`(SevenZip.swift フォーク)。`ArchiveKind` と `makeArchiveReader(url:)` /
  `makeArchiveReader(kind:data:)` で作る。
- `imageExtensions`(Info.plist と一致させる)、`archiveExtensions`、`isAppleDoubleEntry`
  (`__MACOSX/` と `._*` を除く。除かないと `._001.jpg` がページになる)。
- reader は `Sendable` ではない。`PageLoader` の中でだけ触る。

### zip のファイル名の文字コード

古い日本語 Windows/Mac の zip は UTF-8 フラグが無く、ZIPFoundation は codepage437 として読んで
文字化けします。`EntryNameDecoder` は、化けていそうなパスを codepage437 で元のバイト列に戻し、
**書庫全体を連結して1回**だけ Foundation の `NSString.stringEncoding(for:...)` に判定させます
(1件ずつだと短い名前で外れる: 60 件中 46 件しか戻せなかった)。判定結果はアルゴリズム非公開で
OS 更新で変わりうるので、「そのエンコーディングで実際に読めるか」を検証し、読めなければ
決め打ちの候補順、最後は補正なしへ落とします。UTF-8 はバイト列で厳密に検証できるので
エントリ単位で先に拾います。限界: 1つの書庫に CP932 と CP949 が混在すると一方に倒れる。

以前使っていた UniversalCharsetDetection を捨てた経緯は [11](11-forked-dependencies.md#削除した依存-universalcharsetdetection)。

### rar のファイル名

Unicode 名を持たない古い RAR4 は文字化けします。unrar ライブラリが読んだ時点で UTF-8 として
解釈してしまい、生のバイト列に触れないためです。ライブラリの外側では対処できません。

## 入れ子の書庫

書庫の中の書庫、フォルダの中に並んだ書庫は、どの深さでも1冊の本の一部として辿ります。

- **`ArchiveLocator`** = `rootURL` + `nestedPath`(親から順のエントリパスの列)。ページの
  `PageSource.archive` が持つ座標。
- **`NestedArchiveResolver`**: 座標から reader を得る係。親 reader から中の書庫のバイト列を
  取り出し、`Limits.standard(inMemoryBytes:)` の予算に収まればメモリのまま(`makeArchiveReader(kind:data:)`。
  3形式とも可)、超えれば一時ファイルへ書き出して開く。開いた書庫は LRU(`maxOpenReaders` = 8)
  で保持し、メモリ予算・一時ファイル予算(max(256MB, 予算×2))・単一ファイル上限(4GB)を超えたら
  古いものから捨てる。**スレッド安全性を持たせない代わりに所有者ごとに1インスタンス**
  (`PageLoader` 用と `BookContentsBrowserState` 用は別)。
- `openTransient`: `BookLoader` の走査中と、サイドパネルの中身ブラウザが踏み込むときは
  LRU に載せない(履歴が寿命を持つ)。
- `materializeToIndependentFile`: 「新しい本として開く」ために独立したコピーを書き出す
  (LRU の追い出しに寿命を握られないため)。削除は呼び出し側が持つ。
- **`TemporaryFileStore`**: 一時ファイルの置き場(`~/Library/Containers/<bundle id>/Data/tmp`
  配下、起動ごとの pid 付きディレクトリ)と後始末。`deinit` は本を開いたまま終了すると走らない
  ため(実際に 11 日ぶん・120 個・8.4GB が残っていた)、**起動時に他の pid のディレクトリを
  掃除**する。リソースモニタは「前の起動の残骸」と「本を開いていないのに残っている」を異常として
  出す(`ResourceAnomaly.staleTemporaryFiles` / `orphanTemporaryFiles`)。
- `TemporaryArchiveFile` の `deinit` が削除を持つ(最後の持ち主が手放した瞬間に消える)。

環境設定「入れ子書庫をメモリに置く上限」(既定 256MB、0 で常に一時ファイル)がこれらの予算の
唯一の入口です。上限を2つ3つ並べても意味が伝わらないので、一時ファイルの上限もここから
導いています。

## 構造キャッシュ(BookPageListCache)

`BookLoader.load` の結果(ページの `sortKey` / `displayName` / `folderPath`、および下調べで分かった
ページの寸法)を、bookID をキーにディスクへ保存します(`schemaVersion` 3、指紋は mtime+size)。

使い道:

- 「ブックマーク・レイアウトの編集」の右ペインを、本体の読み込みを待たずに描く
  (`BookLayoutEditorViewModel.load` の2段構え)。
- 書き出しウインドウのカバー列の「実質的な先頭ページ」名(`resolveDefaultCoverName`)。
- 一括リネームの「表紙」ブックマークの鍵。
- ソリッド 7z の下調べを2回目以降スキップする(`pageSizes`)。

環境設定「キャッシュ」から容量の確認と削除ができます。EPUB は `folderPath` を持たない
(古いキャッシュに残っていても読まない)。

## PDF と EPUB

- **PDF**: 表示は `CGPDFDocument`(`PageLoader.renderPDFPage`、描画倍率あり)。アウトライン・
  書誌情報・`/ViewerPreferences/Direction`・`/PageLayout` は `PDFStructureResolver`(PDFKit)で
  読み、初回オープン時に取り込む。中の画像の取り出し(書き出し用)は `PDFImageExtractor`。
- **EPUB**: `EpubStructureResolver` が container.xml → package document → spine の順に画像を
  解決し、`page-spread-left/right` / `rendition:page-spread-center` を `PageRef.epubSpreadPosition`
  に、`page-progression-direction` / `rendition:spread` を `sourceLayoutHint` に入れる。
  目次は nav.xhtml(`toc.ncx` へのフォールバックは未対応)。書誌は dc:* と calibre の meta。
  **Foundation の `XMLDocument` の XPath は `namespace-uri()` が壊れている**ため、名前空間の
  判定は `uri` / `localName` で行う(実測で確認した Foundation の不具合)。
- どちらも `MangaBook` 自体は目次やアウトラインを保持しないため、取り込みは
  `ViewerViewModel.init` から `Task.detached` で読み直す(初回だけ DB へ書くので、2回目以降は
  早期に抜ける)。

## 隣の本(次の本へ/前の本へ、同じフォルダのファイルを開く)

`SiblingFinder`(nonisolated)が、本の親フォルダの一覧を `DirectoryBrowser` と同じ照合で
並べます。並び順は `SiblingBookOrder`: 既定は名前順で同じ種類(フォルダの本同士/ファイルの本同士)
に限る。環境設定「フォルダブラウザの並べ替えに合わせる」が ON ならパネルの並びをそのまま辿る
(種類を混ぜる)。**サイドパネル機能が OFF のときはこの設定を無視**する(見えない設定に従わせない)。
`AppPreferences.siblingBookOrder` がその打ち消しを一手に引き受け、読む側はそこだけを見ます。

「次の本の最初のページへ」「前の本の最後のページへ」は `AppState.pendingInitialEdge` に積み、
`ViewerViewModel.init` が読書位置より優先して着地させます。
