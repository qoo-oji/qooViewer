# 04. 本を開く ―― ページ一覧ができるまで

## BookOpenRequest ―― 何冊の本にするか

ドロップ・Finder・Dock・「開く」パネル・サイドパネル・履歴・お気に入り、どの入口から来ても、
渡された URL の束はまず `BookOpenRequest.init(openingCandidates:)` に通します。判定はここ1箇所です。

- 全部が画像ファイルなら **1冊のその場限りの本**(`MangaBook.BookOrigin.imageFiles`)。
  1枚でも複数枚でも同じ扱い。上限 1000 枚(それ以上は先頭 1000 枚)。並びは
  `naturalOrderSortedByPath`(正準順)。
- それ以外(フォルダ・書庫・PDF・EPUB が混ざる)なら**先頭の1件だけ**。ただし、ウインドウへのドロップ・「開く…」パネル・
  ファイルブラウザ(`AppState.open(urls:)`)と Dock・Finder(`application(_:open:)`)・「新規ウインドウで開く…」は、その前に
  **下調べする**(2026-09-27、`DroppedBooks`。ホームの操作の統一):
  - 複数なら、本だけを自然順に並べて(棚のフォルダは中の本に展開、中間フォルダは奥の最初の本)先頭を開き、残りを
    `BookSequence` に載せて「次の本・前の本」でたどる(コレクション・スマートライブラリから開いたときと同じ。下の「隣の本」)。
    画像 1 枚・空のフォルダ・対応しないファイルは並びに入れず、数を知らせる(`AppState.postViewerNotice`。「新規ウインドウで
    開く…」だけは知らせない ―― 開く先のウインドウが後から決まるため)。以前は先頭の 1 件だけを開き、残りを黙って捨てていた。
  - 1 件で、開けないもの(空のフォルダ・本を含まないフォルダ・対応しないファイル)なら開かずに知らせる(ドロップ・パネル・
    ファイルブラウザ・Dock・Finder・「新規ウインドウで開く…」)。以前は読み込みでエラーになり、**表示中の本まで閉じていた**。
    「新規ウインドウで開く…」(と本の窓に焦点が無いときの ⌘O)は Dock・Finder と同じ `ExternalOpenPreparation.prepare` を通し、開けるものが
    無ければ**窓を作らずに**手前の窓(無ければアラート)へ知らせる(2026-10-04 の監査 O-6。以前は本が 1 冊も見つからないと下調べ前の要求の
    まま新しい窓を作り、そこでエラーを出していた)。開くか・知らせる文は `ExternalOpenPreparation.prepareForNewWindow` が決める(テストが
    メニューの通る道で確かめられるように。レビュー R6-6)。読めないフォルダ(許可が無い)は
    「分からない」として従来どおり開きに行く(アクセスを求める導線がその先にある)。
  - **Dock・Finder からの「開く」は何回かに分かれて届く**(2026-09-27、実測)。LaunchServices は書類の種類ごとに別の
    `application(_:open:)` で届ける(書庫 3 冊とテキスト 1 つなら 2 回。間隔はコールド起動で約 50ms、起動済みで約 320ms)。
    最初の回から 1 秒のあいだに届いた回は 1 つにまとめ直し(`AppDelegate.externalOpenGroup`)、先の回をもう開いていれば同じ
    ウインドウで開き直す。本を渡されて起動したときは 200ms 待ってから始める。以前は回ごとに別の「開く」として扱い、起動時に
    ホームと本のウインドウが 2 枚残ったり、先の回の本が後の回に置き換えられたりした。下調べは `ExternalOpenPreparation`。
    **先の回をシークレットウインドウへ回したときは、その本と一緒に回した並びの本を控えて(`routedPrivatelyPaths` ←
    `ExternalOpenPreparation.routedPaths(of:)`。並びの本はレビューの R6-3)まとめ直しから除き、残りをふつうの「開く」として
    開く**(2026-10-04 の監査 O-9)。以前は回した元の窓(本を出していない)を「先の回を開いたウインドウ」と控え、まとめ直した並びを
    そこで開き直してまた回していたので、一緒に渡したノーマルの本がどこにも開かれず並びにも残らなかった(実測)。
  - **待ってから本を開く入口は「開く意図」で照合し、後から頼んだ方が勝つ**(2026-10-04 の監査 O-7・SP-10、レビューの R6-1。
    `AppState.OpenIntent`)。待ち始めるときに `beginOpenIntent()` で意図を進め、待った後に `isStillWanted(_:)` で照合し、開くときは
    `open(request:intent:)` へ渡す(`open` も照合する)。その場で頼まれた `open(request:)`・利用者の中止(`cancelOpen()`)も意図を
    進める。読み込みの失敗・棚の本を別の窓へ譲る(`abandonLoad`)・`closeBook()`(スライドショーの末尾・書き出しの後の動作でも
    呼ばれる)は進めない。照合に落ちた結果は、利用者が後から別の本を頼んだので**鳴らさず知らせない**。
    - 開く先の窓が待った後で決まる入口(ブックマーク・レイアウトの編集ウインドウ・Finder から開いた本)は
      `beginOpenIntentForAnyWindow()`(番号はアプリ全体の 1 本の時計)で取り、決まった窓で照合する。待っていた結果を
      開くときは意図の番号を引き継ぐ(新しい番号にすると、別の窓の意図として待っている入口まで捨てる)。焦点の無いメニューの
      「最近使った項目」は開く先の窓を押した時点で決めるので、その窓の `beginOpenIntent()`(置き換えるときだけ。レビューの RC-7 で
      記述を実装に合わせた)。
    - 窓を作った要求は、窓を作ると頼んだ時点で時計から番号を取り(`AppState.noteWindowCreatingRequest`。窓を作る所 ――
      `BookWindowOpener.presentNewWindow`・`QooViewerApp.openInNewWindow` ―― が `openWindow` の直前に呼ぶ)、作られた窓が最初の要求を
      開くときに引き取る(開いた回数は数えない)。それより前に取られた窓をまたぐ意図はその窓では通らない(レビューの RC-2。以前は
      新しい窓の番号が 0 のままで、編集ウインドウの「開く」が NAS の本を待つ間に作った本 B の窓で照合に通り、B が置き換わった)。
      窓が出た時点で新しく振らないのは、頼んだ後・窓が出る前に取られた意図(Finder から続けて届いた回)まで捨てさせないため。
      通り抜けの入れ替え先の控え(docs/06)は窓が開いた後に取るので外れない。
    - 何も頼まれていない入口(サイドパネルのフォルダブラウザの通り抜けで画像を映す・起動時に前回の本を開き直す・スライドショーの
      末尾や書き出しの後の動作(設定どおりに動くとき)で次の本へ進む ―― `openSibling(after:claimsOpenIntent: false)`)は
      `openIntentWithoutClaiming()` で控えるだけ(先に頼まれた本を捨てさせない。控えた後にその窓で頼まれた・開いたら降りる)。
    - 新しいタブ・ウインドウへ開く入口は、その窓の本と競わないので意図を進めず照合もしない。待つ仕事を持つ入口でも、ほかの
      「開く」で取り消さない(編集ウインドウの `PendingBookOpens`: 置き換える「開く」同士は後が勝ち、新しいタブ・ウインドウへの
      「開く」は 1 件ずつ持って、ウインドウを閉じたときだけ取り消す。レビューの RC-3 ―― 1 つの箱で持つと、続けて 2 冊を新しい
      タブで開いたとき先の 1 冊が黙って開かれなかった)。
    - ファイルブラウザのリンクの先が画像フォルダなら、リンクを解き始めたときの意図を引き継いで照合する(新しく取らない。レビューの
      RC-1)。書き出しの後の「毎回確認」のシートで選んだ「次の本へ」は、利用者がその場で頼んだものなので意図を進める(RC-5)。
    - 以前は `openRequestToken`(`open(request:)` と `cancelOpen()` で進む)を控えて照合していた。待ち始めても何も進めないので、
      待つ入口が 2 つ重なると先に終わった方が開き、後から頼んだ方が黙って捨てられた(眠っている NAS の本をドロップ → 下調べの間に
      コレクションの本を押す → ドロップの本が出る)。照合の無い入口(ファイルブラウザの画像フォルダ・リンク、サイドパネルの
      通り抜け、編集ウインドウの「開く」)もあった。下調べは `FileIO` の上(`Task.detached` をやめた)。次/前の本は表示中の本も見る。
      コレクションの確かめは `CollectionItemOpenTracker.resolve(stillWanted:)` に渡す(機能が切られていても開かない)。
  - **本を渡されて起動したときの主ウインドウには本を開かない**(`AppDelegate.isLaunchingToOpenDocuments`)。そのウインドウは
    SwiftUI が起動の「開く」を受けて作ったもので、起動から 0.3 秒ほど経ってからそこへ本を開くと、以後タイトルが一切変わらなく
    なることがある(`.navigationTitle` の値は変わっても NSWindow へ届かない。6 回中 5 回。ふつうに起動した主ウインドウ・起動済みの
    ウインドウでは起きない)。新しい本のウインドウで開き、空の主ウインドウは従来どおり後始末で閉じる。
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
棚の先頭が画像の本ではない EPUB(小説など)なら、同じ棚の次の本へ進みます(`AppState.open`)。次の本・前の本(一覧の並びを含む)でも
同じ向きへ飛ばして次を試します(2026-10-04 の監査 O-1・決定 2 の (c)。以前は棚を開いたときに限っていて、次の本が小説の EPUB だと
そこで止まった ―― 下の「隣の本」)。

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
  足りない部分は連続する並びごとに 1 回の大きな読みで取り寄せ、順読みには読んだ量に応じて先読みし(上限 4MB)、本をめくる画面
  (ビューア・ブックマークとレイアウトの編集)で開いた本は、手が空いたら残りを裏で順に取り寄せる(`PageLoader(stagesWholeFile: true)`)。
  全部揃えばネットワーク上のファイルは閉じる。
  - **裏の取り寄せは頼み(`StagedFillLease`)を持っている間だけ**(2026-09-27 の監査)。reader・PDF の提供役が頼みを出所として持ち、
    手放すと次の区切り(2MB)で止まる。以前は PageLoader が常に頼み、止める人もいなかったので、コレクションの表紙・ファイルブラウザの
    表紙ページのサムネイルを 1 枚作るたびに本を丸ごと取り寄せ、閉じた後も登録簿の猶予の間は取り寄せ続けていた。書き出しは全ページを
    順に読むので、要るぶんの取り寄せ(先読みつき)で足りる。
  - 一時ファイルの置き場所の空きが 1GB を切ったら裏の取り寄せをやめる。手元へ書けなかった読みは、ネットワークから読んだバイト列を
    そのまま返す(空きが尽きてもページは読める)。
  - 登録簿はネットワーク上のファイルを**ロックの外で**開く(応答しない共有のファイルを開くと約 30 秒戻らず、ロックを持ったままだと
    ほかの共有の本の読みまで待たされた)。
  **読み終えた写しは残さない**(利用者の判断 2026-09-24)。同じファイルは登録簿(`StagedFileRegistry`)で共有し、使われなくなってから
  30 秒・直近 4 本までは残す(BookLoader → PageLoader の受け渡しのため。記述子を溜めないよう本数に上限)。
- **形式ごと**: zip・cbz・epub は自前の `CentralDirectoryZipReader`(一覧を中央ディレクトリだけから作る。ZIPFoundation と答えを一致させて
  あり、意図した違いは 2 つ ―― 型コメント)。rar・7z はフォークの「呼び出し側の関数から読む」入口([11](11-forked-dependencies.md))。
  PDF は `CGDataProvider` の直接読み出しで(`CGPDFDocument(url)` は mmap する)。
  - zip の 2 つ目の違い(2026-09-27 の監査): **EOCD を探すのは末尾から 22+65535 バイト(コメントの最大長)まで**。ZIPFoundation と同じく
    上限なしで探していたときは、zip ではないファイル(中身が RAR の .cbz・途中までコピーされた zip)1 本ごとにファイル全体を取り寄せ、
    窓を前へ連結し続けてメモリに載せていた(254MB で最大フットプリント約 15GB。アイコン表示のサムネイル作りだけで起きた)。末尾に
    64KB を超えるゴミの付いた zip だけは、ローカルでは開けてネットワーク上では開けない。
  - 書庫の中の値(位置・大きさ。ZIP64 の拡張欄は任意の 64 ビット値)は、足し算・変換があふれない形で扱う(細工・破損した書庫で
    trap していた。2026-09-27)。
  - **rar は読み取りの失敗を覚えて投げ直す**(`RarArchiveReader.ReadFailureLog`、2026-09-27)。unrar は DLL として組むと読み取りの失敗を
    「書庫がそこで終わった」として扱うので、ネットワークの瞬断でページの少ない本として開き、「中身が差し替わった本」と判断されて読書位置と
    残りのページのブックマークが消え、短い一覧が構造キャッシュにも残っていた。7z はフォークが失敗を読み取りのエラーとして返す。
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
  (LRU の追い出しに寿命を握られないため)。削除は呼び出し側が持つ ―― 書き出した `BookContentsBrowserState` は開く側へ渡すまでだけ持ち
  (`handOffTemporaryFile`)、**その本を表示するウインドウの `AppState` が引き受ける**(`ownedTemporaryCopies`。表示中の本・直前の本・読み込み中の本の
  どれでもなくなったら消し、ウインドウを閉じたら残りも消す)。2026-10-04 の監査 SP-4(実測)まではブラウザが持ち続け、本が替わった直後に
  古い本のブラウザが解放されて消したので、開いたばかりの本のページが真っ黒になった。一時コピーの本ではサイドパネルのフォルダブラウザを
  再アンカーしない(親はアプリの一時フォルダ)。
- 本の中身ブラウザで**除外したページ**の画像の行は淡く描き、押しても鳴らすだけ(`ImageClickResult.excludedPage`。どの階層でも同じ ―― 以前は
  フォルダの本では何もせず、本そのものの書庫では本を開き直し、入れ子の書庫では一時コピーを新しい本として開いた)。「新しい本として開く」に
  なるのは、本のページでもない画像(入れ子の深さ・大きさの上限で読み込まなかった書庫の中など)だけ。
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
  `cachesPageList: false` の読み込みでは読み書きしない。**覚えるのは「読めたうえで無かった」ときだけ**で、読めなかった
  (NAS の瞬断・本を開いてすぐ閉じて PageLoader が解放された)ときは覚えない(2026-09-26 のレビューで直した。以前は読めなかった
  ことも「無い」と覚え、ファイルが変わるまで取り込みが試されなくなった)。そのために読み手が「無い」と「読めなかった」を分けて
  答える: `ComicInfoResolver.Lookup`、`EpubStructureResolver.resolveMetadataIfReadable` / `resolveTableOfContentsIfReadable`、
  `PDFStructureResolver.resolveMetadataIfReadable` / `resolveOutlineIfReadable`(nil = 読めなかった)。
- ComicInfo.xml は、本そのものが zip・rar なら PageLoader が開いている reader で読む(一覧を取り直さない)。**7z だけは actor の外で
  別の reader で読む**(2026-09-27 の監査): ソリッドなので、表示用の reader で名前順の後ろ(ブロックの末尾)にある ComicInfo.xml を
  読むと、actor の上でブロックを丸ごと伸長してページの読みを止め、伸長器が末尾へ進んで次のページが後方読みになった。

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

**スライドショーが最後のページに達したときも「最後のページで」に従う**(2026-09-27、利用者の指示。cooViewer と同じ ――
cooViewer のスライドショーは手でページを送るのと同じ処理を呼び、最後のページでは「ループ」の設定で分かれて、「しない」のとき
だけ止まる。coo-ona/cooViewer の `Controller.m` `lockedImageDisplay`)。以前は設定に関係なく止まるだけで、MANUAL もそう書いていた。
`ViewerViewModel.handleSlideshowReachedEnd` が振り分ける: ループは先頭へ戻して続ける。「次の本へ」「次の本の最初のページへ」は
このビューアのスライドショーを止め、`PageBoundaryRequest.openSiblingBook(continuesSlideshow: true)` で頼む。次の本は同じウインドウに
**新しいビューア**として出るので、続きは `AppState.pendingStartsSlideshow` に積んで引き継ぐ(`pendingInitialEdge` と同じ扱い ――
`open(request:…)` が毎回上書きし、失敗・棚の読み替えで別のウインドウへ譲ったときは戻し、`ViewerView.handleOnAppear` が読んで
`clearPendingInitialPage()` で捨てる)。次の本が無ければ何も開かないので、止まったまま。ホームへ戻る・タブ/ウインドウを閉じる・
何もしないは止めてから、その動作。「毎回確認」は止めてからシートを出す(選んだ動作でスライドショーは続けない)。

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

**次の本・前の本が開けないとき**(2026-10-04 の監査 O-1・SP-2、決定 2):
- **画像の本でない EPUB は飛ばして、同じ向きの次を試す**(`open(request:step:)` の `BookStep`)。同じフォルダの兄弟は `SiblingFinder` で、
  一覧の並びは残りの位置を `openInSequence` と同じ確かめ(FileIO・1 冊ごとの期限・繋がっていないボリュームは触らずに飛ばす)で順に
  試し、着いた位置を `bookSequence` にする(`sequence.moved(to:)`)。飛ばした先がシークレットフォルダの本なら、そこでシークレット
  ウインドウへ回す(着いた位置の並びを渡す)。開けた本は「直前の本」とウインドウの値にも、元の要求(開けなかった EPUB)ではなく
  実際に開いた本で残る。期限切れは鳴らして止める。**飛ばした先の本のセキュリティスコープは、候補を替えるたびに開き直す**
  (`AppState.adoptCandidateScope`。2026-10-04 のレビューの R7-1)。一覧の並びの本はコレクションの項目のブックマークから解いた URL で、
  確かめ終えるとスコープを閉じて返ってくる ―― 以前は要求の URL(飛ばした EPUB)のぶんしか開かず、ブックマークが唯一の許可の本だと
  読めなかった。開けたら飛ばした本のぶんは閉じる(棚の読み替えは棚のフォルダのスコープで読むので残す)。
- **今の本を置き換える読み込みが失敗したら、どの入口でも今の本を残して知らせる**(壊れた書庫・端まで EPUB だった、など)。
  セキュリティスコープ・一覧の並び・着地の指定を表示中の本のぶんへ戻し(`restoreState`)、「“名前”を開けませんでした。理由」をビューアの
  トーストに出す。以前は今の本を閉じてホームとエラーにしていた(「直前の本へ戻る」で戻ってもまた同じ本で閉じ、先へ進めなかった)。
  本を出していない窓(ホーム・本のために作った窓)では従来どおりホームにエラーを出す。
- ノーマルの窓で回した本(シークレットフォルダの本)は越えたことにする(`passedOverBook`。[06](06-persistence.md)「シークレットフォルダ」)。
