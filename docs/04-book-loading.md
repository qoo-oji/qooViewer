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
3. フォルダなら `ShelfFolderResolver.resolvedBookURLAsync` で**実際に開く1冊**へ解決する
   (下記「棚のフォルダ」)。セキュリティスコープは要求どおりフォルダのほうで開いてあるので、
   中のファイルへはそのまま到達できる。
4. `loadingProgress` を立てて `BookLoader.load(from:)` を待つ。`BookLoadingOverlay` は 400ms
   待ってから出る(普通の本は一瞬で開くので、無条件に出すと点滅する)。
5. 成功したら `reconcileBookIDIfMoved(book:)` を `FavoritesStore` / `BookmarkStore` /
   `LayoutStore` / `BookMetadataStore` / `CollectionStore` の5つで呼ぶ(同一ボリューム内の
   移動・リネームに inode で追従。コレクションはファイル名の表示もここで追従する。
   → [06](06-persistence.md#移動リネームへの追従))。
6. 履歴(`RecentFilesStore.record`)と `LastActiveBookStore.record`。記録するのは
   **`book.sourceURL`**(=解決後の1冊)で、要求された URL ではない。シークレットウインドウと
   その場限りの本では行わない。
7. `currentBook` を差し替える → `ContentView` が `ViewerView` を作り直す。
8. `reloadSiblingBooks()`(「次の本へ/前の本へ」の一覧を `SiblingFinder` で作り直す)。

## 棚のフォルダ ―― 開くのは先頭の1冊

ユーザー報告(2026-09-06): 書庫・PDF・EPUB が並んだフォルダをドロップすると、中の全ファイルを
走査して1冊にまとめるため表示が遅く、履歴にもフォルダのほうが残る。期待は「先頭の本を直接
ドロップしたのと同じ動作」。`ShelfFolderResolver` が、開く直前にフォルダを1冊へ解決します
(判定に使うのはフォルダの一覧だけで、中の書庫・PDF は開きません)。

| フォルダの中身 | 開くもの |
|---|---|
| 直下に画像がある | そのフォルダ全体で1冊(従来どおり。中の書庫・PDF・EPUB のページも含む) |
| 本のファイルが無く、画像フォルダだけが並ぶ | そのフォルダ全体で1冊(章ごとに画像を分けた本) |
| 直下に書庫・PDF・EPUB がある(棚) | 並び順の先頭の1冊。**画像フォルダも1冊として競う** |
| 本を直接持たない中間フォルダだけ | 1段ずつ降りて、最初に見つかった本(深さ上限8) |

「本」の定義(開ける形式のファイル、または上の表の 1 行目・2 行目のフォルダ ―― `ShelfFolderResolver.isBookEntry`)と
並び順(`SiblingBookOrder`)は、棚に並ぶ本(`role`。コレクションへの追加・自動登録フォルダ)・`SiblingFinder`(次の本・前の本)・
スマートライブラリの走査(`SmartLibraryScanner`)で共有します ―― 棚を開く → 「次の本へ」で2冊目、という並びが
サイドパネルの見た目と一致します。2026-09-22 の監査までは、章ごとに画像を分けた本(2 行目)を棚・次の本が数えず、
スマートライブラリは章を 1 冊ずつ、画像フォルダの本の中の書庫も別の本として並べていました。
パッケージ(`.app`・`.rtfd` など)は本でも棚でもありません(一覧に出さず、中へ降りず、フォルダの本の読み込みでも中を読まない)。
棚の先頭が画像の本ではない EPUB(小説など)なら、棚を開いたときに限り、同じ棚の次の本へ進みます(`AppState.open`)。

## BookLoader ―― 形式ごとの分岐

`BookLoader.load(from:progress:)` は `Task.detached` の中で動きます(走査と展開は遅い)。

| 入力 | 処理 | ページ順の由来 |
|---|---|---|
| フォルダ | `loadFolder` → `collectPages(inFolder:)` を再帰。中に書庫・PDF・EPUB があれば中まで辿る | `.fileName`(正準順) |
| zip/cbz/rar/cbr/7z/cb7 | `loadArchive` → `makeArchiveReader` → `collectPages(at:)`。中の書庫・PDF・EPUB も再帰 | `.fileName` |
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
  エントリのパス(入れ子は親のパスを `/` で連結)、PDF/EPUB はゼロ埋めの連番(`%06d`。
  `BookLoader.documentPageSortKey`)。

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
  `SevenZipArchiveReader`(SevenZip.swift フォーク)。ネットワークボリューム上の zip は `CentralDirectoryZipReader`(下の
  「ネットワークボリューム上の書庫」)。`ArchiveKind` と `makeArchiveReader(url:)` /
  `makeArchiveReader(kind:data:)` で作る。
- `imageExtensions`(Info.plist と一致させる)、`archiveExtensions`、`isExcludedArchiveEntry`。
  後者は 2 つの判定の OR で、書庫のエントリを数え上げる側(`BookLoader.collectPages`)と
  本の中身ブラウザ(`BookInternalBrowsing`)が**必ず同じものを使う**(片方だけに足すと、
  ページには無いものが一覧にだけ並ぶ)。
  - `isAppleDoubleEntry`: `__MACOSX/` と `._*` を除く(除かないと `._001.jpg` がページになる)。
  - `isHiddenArchiveEntry`: パスの要素のどれかが `.` で始まるものを除く。フォルダの本は
    `FileManager` の列挙を `.skipsHiddenFiles` 付きで呼んでおり、隠しファイルも隠しフォルダの
    中身も(そこへ降りていかないので)最初から見えない。同じ中身を書庫に固めた途端に
    `.hidden/001.jpg` がページになるのは非対称なので、書庫の側でも揃える。書庫のエントリには
    隠し属性に当たるものが実質無く(zip の DOS 属性は読んでいない)、判定できるのは名前だけ。
  - どちらも「ユーザーが自分で開いたもの」には効かない。隠しフォルダや隠しファイルそのものを
    ドロップ / ダイアログで開いた場合は普通に開く(列挙が外すのは中身だけ)。
- reader は `Sendable` ではない。`PageLoader` の中でだけ触る。

### ネットワークボリューム上の書庫(読み込み層、2026-09-24)

ネットワーク越しのボリューム(マウントの `MNT_LOCAL` が立っていない。`NetworkVolumeReading`)にある書庫と PDF は、
`makeArchiveReader(kind:url:)` / `openPDFDocument(at:)` が**読み込み層 `StagedFileSource` を通して**読みます。ローカル・外付けの
ディスクは従来どおり各ライブラリが直接開きます。検討・実測・経緯は [plans/network-volume-study.md](plans/network-volume-study.md)。

- **なぜ**: ネットワーク越しの読みは 1 回ごとに往復を待つ。ZIPFoundation の一覧はエントリごとにローカルヘッダーを読み、unrar は
  ファイルごとのヘッダーを 2 回の素の `read()` で読むので、200 ページの本で数百〜数千回の往復になっていた(1 往復 5ms の模擬で、
  cbz の最初の見開きまで 10.5 秒)。リースを出す実物の NAS では、1.71 でも**アイコン表示でサムネイルを作った後の本だけ**は速く開いた
  (サムネイル作りが一覧を読み、それが Mac 側のキャッシュに残る)。Finder やリスト表示から開く本には下読みが無く、1.71 で約 2 秒、
  読み込み層で 0.4〜0.65 秒([plans/network-volume-study.md](plans/network-volume-study.md) §10.5)。
- **読み込み層**: ファイルを 64KB のブロックに分けて手元の一時ファイル(`TemporaryFileStore` のセッションのディレクトリ)へ写す。
  足りない部分は連続する並びごとに 1 回の大きな読みで取り寄せ、順読みには読んだ量に応じて先読みし(上限 4MB)、ビューアで開いた本は
  手が空いたら残りを裏で順に取り寄せる(`stagesWholeFile`。PageLoader だけ)。全部揃えばネットワーク上のファイルは閉じる。
  **読み終えた写しは残さない**(利用者の判断 2026-09-24)。同じファイルは登録簿(`StagedFileRegistry`)で共有し、使われなくなってから
  30 秒・直近 4 本までは残す(BookLoader → PageLoader の受け渡しのため。記述子を溜めないよう本数に上限)。
- **形式ごと**: zip・cbz・epub は自前の `CentralDirectoryZipReader`(一覧を中央ディレクトリだけから作る。ZIPFoundation と答えを一致させて
  あり、違うのは「途中のローカルヘッダーだけが壊れた書庫」を一覧に含めることだけ ―― 型コメント)。rar・7z はフォークの「呼び出し側の
  関数から読む」入口([11](11-forked-dependencies.md))。PDF は `CGDataProvider` の直接読み出しで(`CGPDFDocument(url)` は mmap する)。
- **ページのキーは変わらない**。読み込み層は reader の中の話で、`ArchiveLocator` はネットワーク上のパスのまま。
- 隠し設定 `qooViewer.pref.networkVolumeStagedReading = false` で従来の読み方に戻せる(逃げ道)。テストは作業フォルダを
  `NetworkVolumeReading.treatAsRemoteForTesting` で「ネットワーク上」に見立てる(`NetworkVolumeReadingTests`、`FixtureArchive.Input.staged`)。
- フォルダの本(ページが別々のファイル)は対象外。ページの寸法を `CGImageSourceCreateWithURL`(mmap しうる)で読むのは残っている。

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
- 「ファイルに無かった」ことを覚える(`Entry.sourceProbe`、2026-09-25)。ComicInfo.xml・EPUB の目次・PDF のアウトライン・
  EPUB/PDF の書誌情報は、取り込めたときだけ DB に印が付くので、何も持たない本は開くたびに探し直していた(PDF は 2〜3 回
  開き直して解析)。指紋が同じ間だけ「無かった」を信じ、ファイルが変われば項目ごと捨てる。`BookMetadata.didImportSourceMetadata`
  を立てて代わりにしないのは、印の無い行だけが掃除の対象(`isParsedOnly`)だから。シークレットウインドウと
  `cachesPageList: false` の読み込みでは読み書きしない。

開くたびの `store` は、前と同じ中身なら書き直さない(鍵を並べて書く `.sortedKeys` なのでバイト列が揃う。更新日時は
刈り込みに使うので、古いときだけ触る ―― `DiskCacheAccessStamp`)。

環境設定「キャッシュ」から容量の確認と削除ができます。EPUB は `folderPath` を持たない
(古いキャッシュに残っていても読まない)。

## フォルダ・書庫の中の PDF と EPUB

ユーザー報告(2026-09-06)を受けて、**フォルダや書庫の中に置かれた PDF・EPUB も、その位置へ
中身が展開されたかのように1冊のページ一覧へ統合**します(zip/cbz・rar・7z が以前からそうなって
いたのと同じ扱い)。以前は画像と書庫しか拾わず、PDF・EPUB は読み飛ばしていました。

対象になるのは「1冊として開くフォルダ」(上記の表の1・2行目)と書庫の中です。棚のフォルダは
そもそも1冊にまとめないので、ここは通りません。

- ページ順はそのファイル自身のもの(PDF はページ番号、EPUB は spine)。`sortKey` は
  そのファイルまでの接頭辞 + ゼロ埋めの連番(`…/chapters/vol1.pdf/000003`)で、書庫の入れ子と
  同じ組み立て方。`id` は、その PDF/EPUB を単体で開いたときと同じ形。
- EPUB は zip コンテナなので、ページは `PageSource.archive`(その EPUB を指す `ArchiveLocator`)。
  書庫の中の EPUB は入れ子の書庫とまったく同じ経路(`openTransient`)で開きます。
- PDF のページは `PageSource.pdf(container:pageIndex:)`。`PDFContainer` が `.file`(ディスク上)か
  `.entry`(書庫の中)かを持ちます。`.entry` は CGPDFDocument をバイト列から作るため中身が常駐
  するので、`PageLoader` はメモリ上の PDF を3本までしか抱えません(上限は書庫内エントリと同じ
  512MB/本)。書庫の中の PDF を含む本は、構造キャッシュの高速経路(復元にページ番号が要る)から
  外れて通常の読み込みになります。
- 本そのものは依然としてフォルダ/書庫なので `pageOrderSource` は `.fileName` のまま、
  `sourceLayoutHint`(読み方向・見開き強制)も引き継ぎません。ページ単位の見開き指定
  (`PageRef.epubSpreadPosition`)だけは、その EPUB のぶんがそのまま効きます。
- サイドパネル下段の本の中身ブラウザにも並び、踏み込むとそのファイルのページ一覧
  (`BookEntryLevel.documentPages`)になります。行の `matchKey` は `BookLoader.documentPageSortKey`
  と同じ式で組み立てます(食い違うとページへ飛べません)。
- 「本の中のどこか」(`PageLocation.folderPath`)は、その PDF/EPUB ファイルまでの道順
  (`chapters/vol1.epub`)。EPUB の中のフォルダ(`OEBPS/Images/`)は従来どおり畳んで捨てます。

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

**一覧から開いた本は、一覧の並びをたどる**(2026-09-22、利用者の指示)。ライブラリのコレクション(ホームの中・サイドパネルの
ツリー)とスマートライブラリから開いた本は、要求に**そのとき見えていた並び**(検索・絞り込み・並べ替えの後。スマート
ライブラリの束はその位置に中の本を巻の順に展開)を `BookSequence` として載せ(`BookOpenRequest.sequence`。新しいタブ/
ウインドウへも渡る)、`AppState.bookSequence` に置く。「次の本へ」「前の本へ」(キー・メニュー・最後/最初のページでの移動)は
これがあれば `openInSequence` でこの並びをたどり、見つからない本は飛ばし、**端では止まる**(同じフォルダの本へは戻らない ――
絞り込んだ範囲の外へ出ないため)。コレクションの本は項目のブックマークから(`CollectionStore.existingURL(fromBookmark:)`)、
スマートライブラリの本はパスから開く。**確かめはすべて FileIO の上で、1 冊ごとに期限つき**(`BookSequence.Probe`、
`AppState.sequenceProbeLimit` = 5 秒。2026-09-22 の 2 回目の監査): 1 クリックで 1 冊を確かめる一覧と違い、ここは見つからない本を
飛ばして残りの候補を順に試すので、以前のようにメインで確かめると「候補の数 × ネットワークの待ち」ぶん止まりえた。期限を過ぎたら
**先へ進まずに止めて鳴らす**(飛ばすと、眠っていたディスクが起きれば開けた本を黙って越える)。繋がっていないボリューム上の
パスはマウント表の綴りだけで飛ばす。並びは開いた時点の写しで、一覧の側で後から絞り込みを
変えても開いている本の並びは変わらない。**一覧の外から本を開く(履歴・ファイルブラウザ・ドロップなど)と消え**、本を閉じても
消える。たどって開いた本では並びを持ったまま位置だけが進む。
