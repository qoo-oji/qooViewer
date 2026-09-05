# 11. 依存ライブラリとフォーク

qooViewer は3つの Swift パッケージに依存します。うち2つは開発者自身のフォークで、
`Package.resolved` の revision で固定しています。

| パッケージ | 参照先 | 固定方法 | 用途 |
|---|---|---|---|
| ZIPFoundation | `weichsel/ZIPFoundation` | バージョン 0.9.20 | zip / cbz / EPUB(zip コンテナ)の読み取り、CBZ / EPUB の書き出し |
| SevenZip.swift | **`qoo-oji/SevenZip.swift`** ブランチ `streaming-extract` | revision `979634b` | 7z / cb7 の読み取り |
| Unrar.swift | **`qoo-oji/Unrar.swift`** ブランチ `memory-archive` | revision `2fb14dc` | rar / cbr の読み取り |

フォークの作業ツリーは、開発機ではリポジトリの隣(`../SevenZip.swift`、`../Unrar.swift`)にあり、
どちらも `origin` = qoo-oji、`upstream` = mtgto(本家)という remote 構成です。各フォークには
それぞれ自身の記録(`docs/StreamingExtraction.md`、`docs/MemoryArchive.md`、いずれも日本語)と
テストがあります。本章はそれらの要約と、**qooViewer 側から見た理由**を書きます。
フォーク側の docs のほうが実装の細部は詳しいので、変更するときは必ずそちらも読んでください。

どちらのフォークも **upstream へ還元する予定はなく、フォークとして育てる前提**です。

---

## SevenZip.swift フォーク(`streaming-extract`)

### 何が問題だったか

本家の `Archive.extract(entry:)` は LZMA SDK の `SzArEx_Extract` を使います。これは、エントリを
1つ取り出すために、そのエントリが属する**ソリッドブロック(7z の "folder")全体**をひとつの
バッファへ伸長し、別のブロックを要求するか `Archive` が解放されるまで保持し続けます。
7-Zip の既定はソリッド圧縮なので、GB 級の cb7 では **GB 単位のメモリが本を開いている間ずっと
常駐**し、しかもページ1枚を見るたびにブロック丸ごとの伸長が走っていました。

qooViewer はメモリ使用量を実測で詰めていく方針なので(→ [05](05-page-display-and-memory.md))、
ライブラリの外側では対処できないこの常駐が最後に残った大物でした。

### 何を加えたか

フォークのコミット順に:

| コミット | 内容 |
|---|---|
| `91f5110` Add streaming extraction with bounded memory | 引き出し型(pull 型)のブロックデコーダ `7zFolderStream.{h,c}`(C)と Swift API `ArchiveStreaming.swift`。メモリを「デコーダの状態(LZMA 辞書)+数百 KB」に抑える。設計は The Unarchiver(XADMaster)の `CSStreamHandle` / `XAD7ZipParser` を手本にした |
| `42950ba` Add opening archives held in memory | `Archive(data:)`。メモリ上のバッファを読む `ISeekInStream` 実装(`7zMemInStream.{h,c}`)。入れ子の 7z を一時ファイルに書き出さずに開くため |
| `381c826` Fix filter tails, read backwards from the dictionary, verify file CRCs | BCJ 等のフィルタ末尾の持ち越しの不具合修正、LZMA 辞書の範囲内での後方読み(replay)、ファイル単位の CRC 検証 |
| `81730ce` Add a history ring … → `979634b` Revert | 辞書の外へ戻るための履歴リングを一度足したが、**撤回**。「メモリを減らすためのフォークに、別のバッファを足すのは筋が通らない」という判断。qooViewer 側で後方読みを出さない設計にした(下記) |

追加・変更したファイルの一覧と API の詳細は `docs/StreamingExtraction.md` にあります。要点:

```swift
// エントリを順にチャンクで受け取る(false を返すと途中で止まる)
try archive.read(entry: entry, chunkSize: 1 << 16) { chunk -> Bool in ... }
// エントリ全体、または先頭 maxByteCount バイトだけ
let data = try archive.readData(entry: entry)
let head = try archive.readData(entry: entry, maxByteCount: 4096)
// 保持しているブロックデコーダを解放する(次はブロック先頭からやり直し)
archive.discardFolderStream()
// いま保持しているデコーダのメモリ(辞書+バッファ)
let bytes = archive.residentDecoderBytes
```

- 既存の公開 API(`init(path:)` / `entries` / `extract(entry:)`)は変えていない。
- `Archive` は「最後に読んだブロックのデコーダ」を1つだけ保持する。書庫順に読む限りブロックは
  1回しか伸長されない。前方はそのまま読み進め、後方は **Copy(無圧縮)ブロック内か、フィルタ無し
  LZMA/LZMA2 の辞書(通常 16〜64MB)の範囲内なら伸長せずに戻れる**。それ以外はブロック先頭から
  やり直し。
- 対応するコーダ構成は 7zDec.c が扱うもののうち BCJ2 を除く全部(Copy / LZMA / LZMA2 / PPMd +
  フィルタ1段)。非対応(BCJ2 など)は `SZ_ERROR_UNSUPPORTED` を返し、**Swift 側が従来の
  `extract` へフォールバック**する。つまり `read` が読める範囲は `extract` 以上。
- `Z7_PPMD_SUPPORT` を有効にした(本家は未定義で、PPMd 圧縮の 7z は `extract` でも失敗していた)。
- `Archive(data:)` は渡された `Data` を**1回コピー**する(`Archive` が長く生きるオブジェクトで、
  `Data` のポインタは `withUnsafeBytes` の外で安定しないため)。
- `LZMAError` を public にし `.unsupported` / `.decodeFailed(code:)` を追加。deinit でファイルを
  閉じる(本家は閉じていなかった)。
- `include/sevenzip.h` に足す関数は `static inline` にする(通常の関数定義だと Swift 側の
  重複シンボルになる)。
- `SzFolderStream_Create` に渡す `ISzAlloc` は値で複製して保持する(Swift の `&allocImp` は
  呼び出しの間しか有効でなく、最初の実装で SIGBUS を起こした)。
- 実測(308MB・JPEG 130 枚のソリッド LZMA2、Apple M4): 全エントリを書庫順に読むと
  `extract` 8.2 s / 364MB に対し `readData` 8.3 s / **88MB**。中間の1エントリだけなら
  8.3 s / 311MB に対し 5.4 s / **35MB**。速度は同じ(LZMA SDK のデコーダの速さそのもの)。

### qooViewer 側の使い方と約束事

`Services/SevenZipArchiveReader.swift` がこのフォークの利用者です。ここで決めていること:

- `data(at:)` は `readData(entry:)`、先頭だけ要る `dataPrefix(at:maxByteCount:)` は
  `readData(entry:maxByteCount:)`、`extract(to:maxByteCount:)` は `read(entry:chunkSize:)` で
  流しながら書く。
- `residentDecompressionBufferBytes` を `residentDecoderBytes` から返し、リソースモニタの
  「7z デコーダ」として表示する(`ResourceMonitorSnapshot.sevenZipDecoderBytes`)。本を閉じれば
  `releaseAllResources` → reader 解放で消える。
- 入れ子の 7z は、予算(環境設定「入れ子書庫をメモリに置く上限」)に収まるなら `Archive(data:)`
  でメモリから開く。収まらなければ一時ファイル(→ [04](04-book-loading.md#入れ子の書庫))。

**ソリッド 7z で後方読みを出さない約束事**(履歴リングを撤回した代わりに、読む側で守る):

1. 本を開いた直後の下調べ(寸法の取得とサムネイル生成)は、**専用の reader で書庫順**に行う
   (`PageLoader.beginWholeBookScan` / `scanPage` / `endWholeBookScan`)。表示用の reader と
   混ぜない。順序は「現在位置から末尾まで、次に先頭から現在位置の手前まで」。前後交互は禁物
   (実測: 250MB・100 ページの cb7 を中央から再開して 275 秒 → 書庫順で 10 秒)。
2. 調べた寸法は構造キャッシュ(`BookPageListCache.pageSizes`)へ永続化し、2回目以降は書庫に
   触らない(`PageLoader.persistPageSizesIfNeeded`)。
3. 先読みは**進行方向だけ**(`PageLoader.prefetch(direction:)`)。逆方向のページは辞書の範囲を
   超えるとブロック先頭からのやり直しになるため。
4. ページのヘッダー情報(寸法・形式)は、表示のために読んだバイト列から取る。ヘッダーのためだけに
   書庫へ戻らない。
5. 「後方」の基準はデコーダの位置であって、表示中のページではない。

これらは [05](05-page-display-and-memory.md#ソリッド-7z-の読み方) にも書いてあります。
7z に触るアクセス順を変えたら、**「ブロック先頭からのやり直し回数」を数えて**確かめてください
(`archive.folderStreamRestartCount`。計測方法は [12](12-verification-and-debugging.md))。

### 既知の制限

- BCJ2 はストリーミングせず `extract` に任せる(x86 実行ファイル向けの構成で、画像用途では出ない)。
- BZip2 / Deflate / 7zAES は 7zDec.c 側にも実装が無く、どちらの経路でも読めない。
- `Archive` はスレッドセーフではない(本家と同じ)。qooViewer では `PageLoader`(actor)の中で
  しか触らない。

### これから直すもの(フォーク側の変更が要る。2026-09-05 時点で未着手)

どちらもフォークへコミット → push → `Package.resolved` の `revision` を手で書き換え → 
`xcodebuild -resolvePackageDependencies`(下記「ピンの更新手順」)。まとめて 1 回で済ませられます。

1. **エントリの更新日時が常に nil**(本家から引き継いだ取り違え)。`Archive.init` の
   `if SevenZip_SzBitWithVals_Check(&db.MTime, i) == 0 { …mtime を読む… } else { mtime = nil }` は
   条件が逆で、`SzBitWithVals_Check` は**値がある**ときに非 0 を返します(`7z.h` のマクロ)。
   そのため書庫が更新日時を持っていても(`7zz l -slt` では見える)`Entry.modified` は常に nil で、
   コンテキストメニュー「情報を見る」の日時が 7z の本だけ空になります。さらに、値が**無い**書庫では
   `db.MTime.Vals[i]` を読んでしまうので、`Defs` が NULL の書庫(`-mtm=off` 等)ではクラッシュしうる。
   `!= 0` へ直すのが修正。2026-09-05、`ArchiveReaderTests.entryDates` で発見(現状の振る舞いを
   テストで固定してある)。
2. **`folderStreamRestartCount` を public にする**。「ブロック先頭からのやり直し回数」は今 internal
   なので、`SevenZipArchiveReader` から読めません。public にして reader に読み取り専用プロパティを
   足せば、「書庫順に読めばやり直し 0 回」を単体テストの回帰にできます
   (→ [13](13-history-and-known-limitations.md#テストのパタンセット--段階-14引き継ぎ2026-09-05))。

---

## Unrar.swift フォーク(`memory-archive`)

### 何が問題だったか

unrar の公開 API(`RAROpenArchiveEx`)は書庫を**ファイルパスでしか**受け取れません。そのため、
書庫の中に入っている RAR(入れ子)を読むには、いったん一時ファイルへ書き出す必要がありました。
入れ子の zip はメモリから開けるのに rar / 7z だけ必ずディスクに出る、という非対称があり、
一時ファイルの寿命管理と容量計上を複雑にしていました。

### 何を加えたか

コミット `2fb14dc` "Add reading archives held in memory" の1つ。

- 同梱の unrar ソース(C++)の `File` クラスにメモリモード(`MemData` / `MemSize` / `MemPos`、
  `OpenMemory()` / `IsMemory()`)を足し、実際の I/O が集約されている `DirectRead` / `RawSeek` と
  `Tell` / `Close` / `IsOpened` だけを分岐させた。DLL の `DataSet` は `Archive` を値で持つため
  サブクラスで差し替えられず、`File` 自身に持たせるしかなかった。
- `Archive::OpenMemory()`(QuickOpen のキャッシュを捨ててから `File::OpenMemory`)。
- `MergeArchive`(次巻へ移る処理)は、メモリモードでは冒頭で失敗を返す。もとの実装は次巻を
  パスで開こうとして失敗するたびにコールバックへ `UCM_CHANGEVOLUME` を投げて再試行するため、
  Unrar.swift のコールバック(0 = 続行を返す)と組み合わさると**無限ループ**になる(実装中に
  実際に起きた)。
- `dll.cpp` の `RAROpenArchiveEx` を `OpenArchiveCommon` に共通化し、
  `RAROpenArchiveMem(RAROpenArchiveDataEx*, const void*, size_t)` を追加。
- Swift 側に `Archive.Source`(`.file(URL)` / `.memory(Data)`)、`init(data:password:)`、
  `init(source:password:)`。開いて閉じる処理を `withOpenArchive` に共通化。
- Unrar.swift は `entries()` / `extract()` / `comment()` のたびに書庫を開いて閉じる作りなので、
  メモリ版は各操作を `data.withUnsafeBytes { ... }` の中で完結させ、**バイト列をコピーしない**
  (SevenZip.swift 側が1回コピーするのと対照的。あちらは `Archive` が開いたまま生きるため)。
- C++ 側のパッチには `[qoo-oji fork]` のコメントで印を付けてある(数十行)。
- `fileURL` は保持プロパティから計算プロパティになった(メモリから開いた場合は `memory:` という
  プレースホルダ URL。判別は `source` を見る)。

### qooViewer 側の使い方

`Services/RarArchiveReader.swift` がこのフォークの利用者で、`ArchiveReading` に
`init(data:)` 相当の入口があります。入れ子の rar も 7z と同じく、予算内ならメモリから、
超えれば一時ファイルから開きます(`NestedArchiveResolver`)。

### 既知の制限

- 分割ボリューム(multi-volume)はメモリからは辿れない(最初の巻に収まるエントリの一覧は取れるが、
  次巻にまたがる取り出しはエラー)。ファイルから開いた場合も本家の時点で非対応。
- **Unicode 名を一切持たない極めて古い RAR4 のファイル名は文字化けする。** unrar ライブラリが
  書庫を読んだ時点でバイト列をシステムのロケール(UTF-8)として解釈してしまい、qooViewer 側から
  生のバイト列に手が届かないため、ライブラリの外側では対処できない(README にも記載)。
  zip では `EntryNameDecoder` が生のバイト列に触れるので同じ問題は起きない。
- `Archive` はスレッドセーフではない(本家と同じ)。

---

## 削除した依存: UniversalCharsetDetection

2026-09-01(コミット `5eaca7f`)まで、zip のファイル名の文字コード判定に uchardet の Swift
ラッパー `UniversalCharsetDetection` を使っていました。本家パッケージが uchardet を
`git://cgit.freedesktop.org/...` のサブモジュールとして参照しており、このプロトコルは配信終了で
誰も解決できないため、URL だけを差し替えたフォークを使っていました。

しかし実測すると、日本語ファイル名 60 件を1件ずつ判定して**正解は5件**、韓国語・中国語は 0 件
(`UHC` のように IANA 名として解決できない名前を返し、その場合は補正自体が行われない)という
成績で、Foundation の `NSString.stringEncoding(for:...)` に**書庫全体を連結して1回**渡す方式なら
日本語(CP932 / EUC-JP)・韓国語(CP949)・中国語(GBK / Big5)とも全件正しく戻せました。
依存ごと削除し、判定結果は「そのエンコーディングで実際に読めるか」を検証してから採用する
形にしてあります(`Services/ZipArchiveReader.swift` の `EntryNameDecoder`)。

(CLAUDE.md の古い記述は 2026-09-05 に修正済みです。)

---

## ピンの更新手順

フォークはブランチ名で参照していますが、`Package.resolved` には revision も記録されており、
Xcode はその revision を使います。フォークを更新したら:

1. フォークのリポジトリで変更をコミットし、`origin` の該当ブランチへ push する。
2. `qooViewer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` の該当
   `revision` を**手で**新しいコミットハッシュに書き換える。
3. `xcodebuild -resolvePackageDependencies -project qooViewer.xcodeproj -scheme qooViewer` を
   実行して DerivedData のチェックアウトを更新する(Xcode の File › Packages › Update to Latest
   Package Versions でもよいが、ZIPFoundation まで上がるので注意)。
4. ビルドして動かす。

**ローカルのフォークをパスで参照する形にはしていません。** clone した人が同じものをビルド
できるように、必ず GitHub 上の revision を指すようにしてあります。

### upstream への追従

- SevenZip.swift: upstream の更新は主に LZMA SDK の差し替え(`Sources/CsevenZip/` 一式)。
  `7zFolderStream.c` は SDK の公開 API(`SzGetNextFolderItem`、`LzmaDec_*`、`Lzma2Dec_*`、
  `Ppmd7*`、`Bra.h`、`Delta.h`)だけに依存しているので、`git fetch upstream && git merge upstream/main`
  のあと、これらのシグネチャが変わっていないか確認して `swift test` を通す。
- Unrar.swift: unrar の新版を年に数回取り込む。パッチは `[qoo-oji fork]` の印を頼りに当て直し、
  `swift test` を通す。

どちらも、フォーク側のテスト(SevenZip 26 件・Unrar 25 件、2026-09 時点)が通ることを確認してから
上の手順でピンを更新してください。
