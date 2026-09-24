# ネットワークボリューム上の本を開く速さ ―― 検討メモ

検討日: 2026-09-24 / 元の要望: 「ネットワークボリューム上の cbz を開くと、表示まで時間がかかる。ローカルディスクなら今の仕組み、
ネットワークボリュームなら低速ストレージ用の仕組みに切り替えて体感速度を上げたい」(途中で「cbz に限らず cbr・cb7 も同じように」)。

このメモは「作る前の検討」。原因の実測、Web の一次資料、試作による効果測定、設計案と段階分けをまとめる。
§0〜§9 は検討時点(2026-09-24)の記録。**決定と実装の状況は §10**(2026-09-25)、**実物の NAS での計測は §10.5**。

---

## 0. 要点

- **「全部ダウンロードしてから表示」ではなかった。** cbz 1 冊を開くあいだに、**同じ書庫の一覧を 3 回、順番に取り直していた**
  (うち 1 回は**メインスレッド**)。一覧 1 回は ZIPFoundation の作りで「エントリ数 × 1〜2 往復」になる。1 往復 5ms(Wi-Fi 程度)・
  キャッシュ無しの模擬で、ダブルクリックから 1 ページ目のバイトが揃うまで **9.7 秒**、うち 2.7 秒は UI が固まっていた(§2)。
- **形式によらない「読み込み層」を 1 つ作り、3 形式の reader をすべてそこへ通す**(§4)。ネットワーク上のファイルを
  64KB 単位のブロックで取り寄せて手元の一時ファイルに貯め、飛び飛びの読み(索引・ヘッダー)は必要なぶんだけ、順読み(伸長)は先回りして
  大きく、手が空いたら残りを先頭から順に取り寄せる。**全部揃えば以後はローカルディスクと同じ**。
  - zip(cbz・epub): 一覧を**中央ディレクトリだけから作る自前の reader**。ZIPFoundation の一覧・取り出しと**完全一致**
    (テストのフィクスチャ全件+境界ケース 22 本、**実際の蔵書 8,266 本で差異 0**。§5.1)。
  - 7z(cb7)・rar(cbr): フォーク 2 本に「呼び出し側の関数から読む」入口を足す(メモリ入力の入口と同じ形、各 60〜80 行)。
    伸長・一覧はライブラリのまま、**読み方だけ**が変わる。
- 試作での効果(Wi-Fi 相当の 5ms・40MB/s・キャッシュ無し、200 ページ・約 190MB の合成本。ダブルクリックから最初の見開きが画面に出るまで、
  アプリ本体で計測。§3.4):

  | 本 | 今 | 読み込み層+形式によらない修正 | 参考: 遅延なし |
  |---|---|---|---|
  | cbz | 10.46 秒 | **0.44 秒** | 0.48 秒 |
  | cbr(rar 7 の既定。Quick Open あり) | 1.25 秒 | **0.50 秒** | 0.51 秒 |
  | cbr(Quick Open なし=古い rar) | 8.71 秒 | **2.20 秒** | 0.53 秒 |
  | cb7(ソリッド) | 0.91 秒 | **0.82 秒** | 0.84 秒 |

  全ページを読み通す時間(本全体の下調べ・ページ送りが先へ進む速さ)も、cbz 84 → 7.1 秒、cbr 15.7 → 7.2 秒、Quick Open の無い cbr
  100 秒超 → 8.7 秒、cb7 15.2 → 5.5 秒(ローカル 4.9 秒)。有線 LAN・遅い回線でも、1 ページ目が遅くなる組み合わせは無い(§3.3)。
- 形式によらない**アプリ側の無駄**(一覧の 3 重取り、メインスレッドでの一覧、全ページ下調べが表示を待たせる)は、読み込み層とは
  別に直す(§4.5)。こちらはローカルの本にも効く小さな修正。
- ローカルの本は**今の経路のまま**(切り替えは「ネットワークボリューム上か」で 1 箇所。§4.1)。
- 決めてほしいこと(§8): 読み終えた写しを手元に残すか(残すなら上限)、フォーク 2 本への変更、段階の順番。

---

## 1. 調べ方

### 1.1 模擬ネットワーク(sudo なし・実機の NAS なし)

この Mac にはネットワークボリュームが無く、sudo も使えないので、**読み取りのシステムコールを横取りする共有ライブラリ**
(`DYLD_INSERT_LIBRARIES`)で模擬した。指定したフォルダの下のファイルへの `read`/`pread` ごとに

- どのスレッドが・どこを・何バイト読んだかを記録し、
- 「1 往復 RTT + バイト数 ÷ 帯域」だけ待たせる(帯域は 1 本の回線を先着順に共有する)。

**キャッシュ無し(=SMB サーバがリースを出さない最悪の場合)**を基本にした。リースが出る NAS では 2 回目以降の同じ場所の読みが
手元のカーネルのキャッシュで済む(§2.3)。

アプリ本体は bundle id を変えた Debug ビルド(`com.qooProject.qooViewer.nettest`、Hardened Runtime を外して ad-hoc 署名。
コンテナが別なので本番・Debug のデータには触れない)に同じライブラリを差し込んで、合成した本(ノイズの JPEG 200 枚、約 190MB。
実在の名前は使っていない)を `open -a` で開いて計った。reader 単体は、実物のソースを symlink で取り込んだ SwiftPM の CLI で計った
(docs/12「書き出しの検証」と同じ取り込み方)。

**模擬の限界**: 実物の smbfs の先読み・キャッシュの振る舞いは再現していない(最悪側に倒した)。NAS の HDD のスピンアップ(数秒〜十数秒)も
入っていない。実機の NAS での確認手順は §7。

**模擬の落とし穴(記録)**: 裏の取り寄せを `.utility` の QoS のスレッドで回すと、macOS が低 QoS のスレッドの `usleep` をまとめて
(timer coalescing)**1 回の模擬往復に約 50ms 上乗せ**した(1MB ずつ 197 回の取り寄せが 16.4 秒 → QoS を上げると 6.8 秒)。
本物のネットワーク待ちはタイマーではないのでこの上乗せは起きない。以下の数字は裏のスレッドの QoS を上げて計ったもの。

### 1.2 Web の一次資料(要点。出典は §9)

- **smbfs のキャッシュはサーバのリース次第**。`smbfs_vnop_read` はリースがあれば UBC(先読み付き)、無ければ毎回サーバへ直接読む。
  Samba は現行の既定でリースを出すが、古い NAS のファームウェアでは出ないものがある。**カーネルの先読みは順読みにしか効かない**
  (飛び飛びの小さな読みは毎回 1 往復)。
- smbfs は大きな `read()` を 256KB〜1MB の要求に分けて**並べて**送る(最大 8 本)。**1 回の大きな読み ≒ 1 往復+転送時間**。
  `F_RDADVISE` は smbfs では ENOTSUP、`F_NOCACHE` はキャッシュを完全に外す(小さな読みには逆効果)。
- ZIPFoundation 0.9.20: 一覧(`Archive.makeIterator`)は**エントリごとにローカルヘッダーへシークして読む**(データ記述子付きなら
  もう 1 回)。`setvbuf` を 16KB にしているため、Apple の Libc は**シークのたびにバッファを捨てる**(大きさが最適値と違うと
  シークの最適化を切る)。取り出しも既定 16KB ずつ。**任意の I/O を差し込む口は無い**(Readium はこのために ZIPFoundation を
  フォークし、リモートでは 6MB のバッファで読んでいる)。
- **ImageIO(`CGImageSourceCreateWithURL`)と `CGPDFDocument(url)` はファイルを mmap する**(ローカルでは確認。SMB では未確認)。
  Apple は「ネットワーク上のファイルを mmap すると、切断時にバスエラーで落ちうる」と明記している。`Data(contentsOf:)` の
  `.mappedIfSafe` はネットワーク上なら mmap せず 1 回の `read()` で読む。
- rar5 は**ファイルごとのヘッダーが本全体に散らばる**。末尾近くに写しを置く Quick Open(rar 7 の既定では置かれる)があれば
  一覧は数回の読みで済む。unrar はヘッダーを「7 バイト+残り」の 2 回の素の `read()` で読む。
- 7z は索引が末尾にまとまっている(一覧は数往復)。ソリッドはブロックの先頭から順に伸長するので順読み。
- 読み取り専用で開いたファイルは他のクライアントの読み書き・改名・削除を妨げない(共有モードは全許可)。ただしリースのある
  サーバでは、閉じても最大 30 秒ハンドルが残る(遅延クローズ)。
- 他のビューア: YACReader は開いたあと裏で全エントリを書庫の順に取り出してメモリに持つ。Simple Comic はソリッドを一時フォルダへ
  展開。VLC は `MNT_LOCAL` で判定して「ネットワーク用のキャッシュ」に切り替える。**「ネットワーク上か」の判定は `statfs` の
  `MNT_LOCAL`(=`URLResourceKey.volumeIsLocalKey`)が Apple の推奨**(NW09)。

---

## 2. 原因(実測)

### 2.1 cbz を開いたときに起きていること(5ms・40MB/s・キャッシュ無し、アプリ本体)

| 時刻 | 誰が | 何を | 読み取り回数 |
|---|---|---|---|
| 0.0〜3.2 秒 | `BookLoader`(裏) | 一覧 | 401 |
| 3.3〜6.0 秒 | **サイドパネル下段(`BookContentsBrowserState.init`)、メインスレッド** | 一覧 | 401 |
| 6.1〜9.2 秒 | `PageLoader`(actor)の最初の reader | 一覧 | 401 |
| 6.1〜9.2 秒 | `importComicInfoIfNeeded`(裏、同時) | 一覧 | 401 |
| 9.7 秒 | `PageLoader` | **1 ページ目のバイトが揃う** | 60(16KB ずつ) |
| 以後 54 秒 | `PageLoader` | 本全体の下調べ(全ページの先頭 128KB)+先読み | 2,105 |

- 一覧 1 回 = 中央ディレクトリ + **全ページのローカルヘッダー**(Finder の「圧縮」で作った zip はデータ記述子も) = ページ数の 2〜3 倍の読み。
- サイドパネル下段の一覧は**メインスレッドで同期に**取っている(`ContentView.updateBookContentsBrowserForCurrentBook` →
  `BookContentsBrowserState.init` → `NestedArchiveResolver.openRootArchive`)。ネットワーク上では数秒の固まりになる。
  しかもこの間、ビューアの初期化(メインアクターのタスク)も待たされるので、`PageLoader` の開始が遅れる。
- `importComicInfoIfNeeded` は「ブックマークが 1 件も無い本」では**開くたびに**書庫を開き直す(`needsBookmarks = bookmarks.isEmpty`)。
- `PageLoader` の書庫の読み出しは actor の上の同期 I/O。表示するページ・先読み・全ページの下調べが同じ列に並ぶ。

reader 単体(CLI)で分けると:

| 処理(142MB・200 ページ) | 読み取り回数 | 5ms・40MB/s | 1ms・100MB/s |
|---|---|---|---|
| 一覧 1 回(`zip -0`) | 401 | 2.2 秒 | 0.5 秒 |
| 一覧 1 回(Finder の圧縮) | 601 | 3.3 秒 | 0.7 秒 |
| 全ページの先頭 128KB | 2,001 | 10.8 秒 | 2.3 秒 |
| 参考: **ファイル丸ごと 4MB ずつ順に** | 35 | **3.9 秒** | 1.5 秒 |

**今の読み方では、一覧+下調べだけでファイル丸ごとのコピーより時間がかかる。**

### 2.2 cbr・cb7(アプリ本体、同じ条件)

| 本 | 1 ページ目のバイト | その後 |
|---|---|---|
| cbr(rar 7 の既定。Quick Open あり) | 0.52 秒 | ページごとに書庫を開き直すが、Quick Open のおかげで 1 ページ約 8 回の読み |
| **cbr(Quick Open なし)** | **7.7 秒** | ページを読むたびにヘッダーを先頭から辿り直す。60 秒で 63 ページ分しか進まない |
| **cbr(ソリッド)** | 0.85 秒 | ページごとに書庫の先頭から伸長し直す(k ページ目で約 k MB の転送)。40 秒で 24 ページ分 |
| cb7(ソリッド) | 0.30 秒 | 本全体の下調べ(専用 reader)で 160MB を読む |

- `RarArchiveReader` はフォークの作りどおり**操作のたびに書庫を開き直す**。Quick Open が無いとヘッダーの辿り直しが毎回走る。
- ソリッド rar のページごとの伸長し直しは**ローカルでも起きている**(40 ページで 5.3 秒。CPU)。ネットワークではそのたびに転送が重なる。
- cb7 は索引が末尾なので最初のページは今でも速い。遅いのは「伸長(CPU)と転送が直列」になる通読(ローカル 4.9 秒 → 15 秒)。

### 2.3 リースが出る NAS なら

同じ模擬でブロックキャッシュ(64KB+順読みの先読み)を入れると、2 回目以降の一覧が手元で済み、cbz の 1 ページ目は **2.2 秒**
(1 回目の一覧ぶん)。リースがあっても**最初の一覧の往復**は残る。

---

## 3. 試作と効果

### 3.1 試作したもの(scratchpad。本体は未変更)

| 試作 | 中身 |
|---|---|
| `CentralDirectoryZipReader` | 末尾(EOCD+コメント+ZIP64 の位置)を 1 回で読み、中央ディレクトリを 1 回で読んで一覧を作る。ローカルヘッダーは取り出すときにデータと同じ 1 回の読みで。伸長は ZIPFoundation の公開 API(`Data.decompress`)をそのまま使う。パスの復号・種類の判定・EOCD の探し方・ZIP64 の拾い方・暗号化エントリで一覧が止まること・同名は先を採ることまで ZIPFoundation と `ZipArchiveReader` に合わせた |
| `StagedFileSource`(読み込み層) | §4.2 |
| フォーク(手元の複製) | Unrar: `File` に `OpenCallback`(`DirectRead`/`RawSeek`/`Tell` を呼び出し側の関数へ)、`RAROpenArchiveCallback`、Swift 側 `Archive.Source.reader(PositionalReader)`。SevenZip: `CCallbackInStream`(`ISeekInStream`)と `Archive(reader:)`。どちらも既存のメモリ入力と同じ形 |
| アプリ側(複製) | `makeArchiveReader(kind:url:)` で「ネットワーク上なら読み込み層+各 reader」、サイドパネル下段の一覧を省く(上限の見積り用)、ComicInfo を `PageLoader` の reader で読む、zip の索引の使い回し、取り出しのバッファを大きく |

### 3.2 アプリ本体での効果(cbz、5ms・40MB/s・キャッシュ無し)

| 構成 | 1 ページ目のバイト | 本全体の下調べ |
|---|---|---|
| 今 | 9.66 秒 | 2,105 回・54 秒 |
| 形式によらない修正だけ(一覧の 3 重取り・メインスレッド・ComicInfo・取り出しのバッファ) | 2.85 秒 | 206 回・6.7 秒 |
| 中央ディレクトリの reader だけ | 0.16 秒 | 205 回・7.9 秒 |
| 両方 | 0.13 秒 | 206 回・5.5 秒 |

(読み込み層まで入れたアプリ全体の数字は §3.4)

### 3.3 reader 単体、回線の違い

reader 単体(計測用 CLI、合成本 200 ページ・約 190MB。「今」= `makeArchiveReader` の今の reader、「層」= 読み込み層経由)。
「1 ページ目」は一覧+1 ページ目の取り出しまで、「通読」は全ページを順に取り出し終えるまで(本全体の下調べに相当)。

| 回線(1 往復・帯域) | 本 | 1 ページ目 今 → 層 | 通読 今 → 層 |
|---|---|---|---|
| 有線 LAN(0.5ms・110MB/s) | cbz(`zip -0`) | 0.39 → 0.02 秒 | 10.7 → 2.7 秒 |
| | cbz(Finder の圧縮) | 0.57 → 0.02 秒 | 12.9 → 3.4 秒 |
| | cbr(Quick Open あり) | 0.03 → 0.02 秒 | 3.6 → 2.8 秒 |
| | cbr(Quick Open なし) | 0.29 → 0.32 秒 | 30.1 → 3.1 秒 |
| | cb7 | 0.05 → 0.05 秒 | 7.2 → 4.8 秒 |
| Wi-Fi(5ms・40MB/s) | cbz(`zip -0`) | 3.07 → 0.05 秒 | 84 → 7.1 秒 |
| | cbz(Finder の圧縮) | 5.14 → 0.05 秒 | 100 → 8.3 秒 |
| | cbr(Quick Open あり) | 0.19 → 0.05 秒 | 15.7 → 7.2 秒 |
| | cbr(Quick Open なし) | 3.06 → 1.75 秒 | 100 秒超 → 8.7 秒 |
| | cbr(ソリッド、40 ページ) | ― | 200 秒超 → 5.4 秒(ローカル 5.3 秒) |
| | cb7 | 0.10 → 0.14 秒 | 15.2 → 5.5 秒(ローカル 4.9 秒) |
| 遅い回線・VPN(15ms・10MB/s) | cbz(`zip -0`) | 10.4 → 0.16 秒 | 60 秒超 → 24.5 秒 |
| | cbz(Finder の圧縮) | 15.1 → 0.17 秒 | 60 秒超 → 25.6 秒 |
| | cbr(Quick Open あり) | 0.61 → 0.18 秒 | 54.3 → 24.6 秒 |
| | cbr(Quick Open なし) | 8.8 → 5.7 秒 | 60 秒超 → 28.8 秒 |
| | cb7 | 0.32 → 0.41 秒 | 45.6 → 18.6 秒 |

- **どの回線でも、1 ページ目が目に見えて遅くなる組み合わせは無い**(cb7 の遅い回線で 0.09 秒、Quick Open なしの有線で 0.03 秒の増え ―― 64KB 単位の
  取り寄せぶん)。通読はすべて短くなり、層の通読はほぼ「ファイルの大きさ ÷ 帯域」(190MB ÷ 40MB/s ≈ 4.8 秒)に張り付く。
- Quick Open の無い rar だけは、一覧にファイル数ぶんの往復が要る(ヘッダーが本全体に散らばっているため。1 回 64KB)。
- ソリッド rar の「ページごとに先頭から伸長し直す」CPU の重さは層では消えない(ローカルと同じになるだけ)。これは今のローカルの本でも
  起きている別の問題(§4.5 の外。フォークの「全件を 1 回で読む」`forEachEntry` を使う余地がある)。

### 3.4 アプリ本体、3 形式(読み込み層あり)

ダブルクリック(`open -a`)から**最初の見開きを画面に出すまで**(試作の複製に 1 行だけ時刻の記録を入れて計測。Wi-Fi 相当の 5ms・40MB/s・
キャッシュ無し。各 1 回)。参考に、同じビルドを遅延なし(ローカルと同じ速さ)で開くと 0.48〜0.84 秒(ウインドウの用意・デコードなど、
アプリ側の固定の時間)。

| 本 | 今 | 形式によらない修正だけ | + 読み込み層 | (遅延なし) |
|---|---|---|---|---|
| cbz | 10.46 秒 | 3.63 秒 | **0.44 秒** | 0.48 秒 |
| cbr(Quick Open あり) | 1.25 秒 | 1.10 秒 | **0.50 秒** | 0.51 秒 |
| cbr(Quick Open なし) | 8.71 秒 | 6.31 秒 | **2.20 秒** | 0.53 秒 |
| cb7 | 0.91 秒 | 1.17 秒 | **0.82 秒** | 0.84 秒 |

cbz・Quick Open 付きの cbr・cb7 は、ネットワーク上でも**ローカルとほぼ同じ時間**で最初の見開きが出る。(cb7 の「修正だけ」が今より遅いのは
1 回ずつの計測のばらつきの範囲と見ている ―― cb7 には効かない修正だけを入れた構成)

---

## 4. 設計

### 4.1 切り替えの判定と場所

- **判定**: `statfs` の `f_flags` に `MNT_LOCAL` が無い(=SMB・AFP・NFS・WebDAV・macFUSE の既定など)。`MountTable.isRemote` が
  既に同じことをしているので、それを使う。**型名(smbfs 等)の許可リストにはしない**(FSKit のモジュールは自分で型名を名乗る)。
- 判定は**本の実体(書庫ファイル)を開くとき 1 回**。途中で変わらない。
- 入れない(今の経路のまま): ローカル・外付けディスク(USB の HDD も「ローカル」で遅いが、往復は短く帯域もある)。
  iCloud Drive などの「中身がまだ手元に無い」ファイル(dataless)は別の問題(読むとダウンロードが始まる)なので今回は対象外。
- 切り替えの**場所は 1 つ**: `makeArchiveReader(kind:url:)`(と、そこを通っていない直接の生成 4 箇所をここへ寄せる:
  `BookLoader.loadEpub`、`ViewerViewModel` の EPUB 目次・書誌、`BookThumbnailer`)。`BookLoader`・`PageLoader`・サイドパネル・
  ComicInfo・一覧の絵・コレクションの表紙・ファイルブラウザの展開は、すべてここを通るので**呼び出し側は変えない**。
- 環境設定に「ネットワーク上の本の読み方: 自動(既定)/ 使わない」を置く(不具合のときに今の経路へ戻せる逃げ道)。
  テストは判定を差し替えて、ローカルのフィクスチャで読み込み層の経路を通す。

### 4.2 読み込み層(`StagedFileSource`)

```
reader(zip 自前 / 7z・rar フォーク) ── read(at:count:) ──▶ StagedFileSource ──▶ 手元の一時ファイル(スパース)
                                                               │ 足りないブロックだけ
                                                               ▼
                                                    ネットワーク上のファイル(pread)
```

- ファイルを **64KB のブロック**に分け、手元にあるブロックをビットで覚える。
- **前景の読み**(reader から): 足りないブロックを「連続する並びごとに 1 回の大きな pread」で取り寄せ、一時ファイルへ書いてから返す。
  - **先読みの幅は「この順読みの並びで実際に読んだ量」**まで(上限 4MB)。ヘッダーを「7 バイト+残り」と 2 回に分けて読む unrar の
    ような小さな続き読みでは広げない(試作の途中で、これを呼び出し回数で数えていたら Quick Open の無い rar の一覧が 4.6 秒に
    なった。量で数えて 1.7 秒)。伸長器の順読みでは読むほど倍々に広がる。
  - 同じブロックを 2 つのスレッドが同時に取りに行かない(取り寄せ中なら終わるのを待つ)。
- **裏の取り寄せ**: 残りのブロックを、前景が最後に読んだ位置の先から順に 2MB ずつ。
  - 最初の前景の読みが済むまで始めない(開いた直後の索引の読みを邪魔しない)。
  - 前景が**飛び飛びに**取り寄せている間(索引・ヘッダーを辿る間)は譲る。取り寄せ中のブロックを前景が待っていることも「前景の需要」に数える。
  - 前景が**順に流れている**(先読みの幅が上限に達した)間は、その先を取りに行く ―― 7z の伸長(CPU)と転送が重なる
    (cb7 の通読 16 秒 → 5.5 秒。ローカルは 4.9 秒)。
- 揃ったら以後の読みはすべて一時ファイル(ローカルディスク)から。ネットワーク上のファイルの記述子はその時点で閉じてよい
  (SMB のハンドルを本を開いている間ずっと握らない。今は FILE* を開きっぱなし)。
- 一時ファイルは `Caches`(サンドボックスのコンテナの中)。起動時に残骸を消す。空き容量が足りなければ(`volumeAvailableCapacityForOpportunisticUsage`)
  裏の取り寄せをせず、前景の読みだけにする。

### 4.3 共有・寿命・写しの扱い

- **同じファイルは 1 つの読み込み層を共有する**(登録簿。鍵はパス+大きさ+更新日時+ファイル番号+ボリューム UUID)。
  `BookLoader` が取り寄せた索引を、`PageLoader`・サイドパネル・ComicInfo がそのまま手元から読む。
- **寿命**: 最後の利用者が手放してから猶予(試作は 30 秒)まで残す。`BookLoader` が読み終えて手放した直後に `PageLoader` が開く、
  の間で捨てないため。本を閉じたら裏の取り寄せを止める。
- **裏の取り寄せを誰が頼むか**: ビューアで本を開いたときだけ。一覧の絵・コレクションの表紙・メタデータの取り込みなど「最初の数ページ
  だけ」の読みは前景の読みだけにする(フォルダを表示しただけで中の本を全部ダウンロードしないように)。
- **写しを残すか**(§8 で決める): 残せば、同じ本を開き直したとき一覧も含めて最初からローカル(ネットワークは「変わっていないか」の
  stat 1 回だけ)。上限付きの LRU(環境設定「キャッシュ」に上限を置く)。**シークレットウインドウでは残さない**(記録を残さない約束。
  共有もしない ―― シークレット用は別の層を作り、閉じたら消す)。保存データの書き出しには入れない(アプリが作り直せるもの)。
- **中身が変わっていないか**: 開くときに鍵(大きさ・更新日時・ファイル番号)で確かめる。読んでいる途中でサーバ側が書き換わる場合は
  今と同じく検知しない(今も同じ危険がある)。取り寄せ完了時にもう一度 stat して、変わっていたら写しを捨てる。
- **切断**: 取り寄せ済みのブロックは読める。未取得の読みは失敗 → そのページは「読めなかったページ」(今と同じ扱い)。

### 4.4 形式ごとのつなぎ方

| 形式 | reader | 一覧の往復 | 備考 |
|---|---|---|---|
| zip・cbz・epub | 自前の `CentralDirectoryZipReader`(読み込み層経由) | 1〜2 回 | ZIPFoundation は書く側(書き出し・圧縮)で引き続き使う。フォークしない |
| 7z・cb7 | フォークの `Archive(reader:)` | 数回 | ソリッドの伸長は順読み → 裏の先読みと重なる。本全体の下調べ(専用 reader)も同じ層から読む |
| rar・cbr | フォークの `Archive(source: .reader(...))` | Quick Open ありで数回、なしでファイル数に比例(1 回 64KB) | 操作のたびの開き直しは手元から読むので軽い |
| PDF | `CGDataProvider(directInfo:...)` で読み込み層から | ― | `CGPDFDocument(url)` の mmap をネットワーク上でやめる(切断時のバスエラー対策を兼ねる) |
| 入れ子の書庫 | 今のまま(親から取り出してメモリか一時ファイル) | ― | 親が読み込み層を通るので、取り出しも手元から |
| フォルダの本 | 読み込み層は使わない(ページが別々のファイル) | ― | ネットワーク上では寸法の読み取りを `CGImageSourceCreateWithURL`(mmap)から先頭バイトの `Data` へ、ページの読み出しを actor の外へ |

### 4.5 形式によらない修正(ローカルの本にも効く)

1. **サイドパネル下段の一覧をメインスレッドから外す**(`BookContentsBrowserState` の作成を非同期に)。ネットワーク上で数秒の固まり。
2. **ComicInfo の取り込みは `PageLoader` の reader で読む**(`sourceComicInfo(bookSourceURL:)` が既にある)。加えて、
   「ブックマークが無い本は開くたびに読む」条件を見直す(ComicInfo.xml が無いと分かった本は次から読まない)。
3. **一覧の使い回し**: 読み込み層を通さないローカルの zip でも、`BookLoader` が読んだ索引を `PageLoader` が使い回せば一覧は 1 回で済む
   (試作は「パス+大きさ+更新日時+inode」を鍵に ZIPFoundation の `Entry` 一覧を 8 冊ぶん持つだけ)。
4. **取り出しのバッファ**: `ZipArchiveReader.data(at:)` は既定 16KB。エントリの大きさ(上限 4MB)にすれば 1 ページ 1 回の `read()`。
5. **本全体の下調べは表示の後に**: 下調べ・先読みが最初の見開きの読み出しと同じ actor の列に並ぶ。最初の見開きを出してから始める
   (ネットワーク上の本では、読み込み層の取り寄せがある程度進むまで待ってもよい)。

---

## 5. 互換性

### 5.1 zip の一覧・中身が変わらないこと

- `ZipArchiveReader`(ZIPFoundation)と `CentralDirectoryZipReader` の結果を、一覧・書庫順の項目(種類・大きさ・日時)・各エントリの
  大きさ・日時・中身のバイト列・逐次読み・先頭読みで突き合わせた:
  - テストのフィクスチャ(zip/cbz/epub 25 本)と自作の境界ケース 22 本(ZIP64 を 2 通り・データ記述子・CP932/CP949/Big5/EUC-JP の
    名前・UTF-8 フラグ無しの UTF-8・暗号化(全部/途中)・同名エントリ・書庫コメント・Deflate64/BZip2・先頭にゴミ・途中で切れた・
    zip でない・空・ディレクトリと記号リンク): **41 本一致、両方開けない 5 本**。
  - **実際の蔵書 8,266 本**(先頭・中央・末尾のエントリの中身まで): **8,263 本一致、差異 0、両方開けない 3 本**。
- **意図した違いは 1 つだけ**: 中央ディレクトリは無事で途中のローカルヘッダーだけが壊れた書庫。ZIPFoundation はそこで一覧を
  打ち切るが、新しい reader は一覧に含め、そのページの読み出しで失敗する(ページ数が増え、壊れたページが「読めないページ」になる)。
- 先頭読み(`dataPrefix`)は「少なくとも要求量、全体の先頭と一致」という約束で一致(ZIPFoundation 版は 16KB 単位で多めに返す)。
- CRC: ZIPFoundation の `Archive.extract(_:consumer:)` は CRC を**計算するが照合しない**(照合するのは `FileManager.unzipItem` だけ)。
  今の `ZipArchiveReader.readEntry` のコメント「CRC はライブラリの既定どおり検証する」は実態と違う。新しい reader も照合しない
  (壊れかけの書庫のページが今は表示できているので、ここで失敗させると挙動が変わる)。コメントは実装のときに直す。

### 5.2 そのほか

- **ページのキー(`PageRef.id`・`sortKey`)・本の ID は変わらない**。読み込み層は reader の中の話で、`ArchiveLocator` の `rootURL` は
  ネットワーク上のパスのまま。保存データ・移動の追従・ページ一覧のキャッシュ・寸法の永続化に影響しない。
- 7z・rar は一覧・伸長ともライブラリのまま(読み方だけが変わる)ので、名前・順序・中身は同じ。フォークのテストに「ファイルから」と
  「呼び出し側の関数から」で同じ結果になることを足す。
- サンドボックス: 記述子はセキュリティスコープが開いている間に開く。開いた記述子はその後も使える。一時ファイルはコンテナの中。
- ファイル操作(`FileOperationService`)で本が移動・改名されても、登録簿の鍵はパスなので古い写しは使われなくなるだけ(誤った本を
  読むことはない)。開いている本の操作はそもそも断っている。
- シークレットウインドウ: 写しを残さない・共有しない(§4.3)。

---

## 6. 段階分け(案)

| 段階 | 中身 | 効く範囲 | テスト |
|---|---|---|---|
| 1 | 形式によらない修正(§4.5 の 1〜5) | ローカルもネットワークも | サイドパネル下段がメインで書庫を開かないこと、開くときの一覧の回数、ComicInfo の取り込みが今と同じ結果 |
| 2 | 判定(§4.1)と `CentralDirectoryZipReader`+読み込み層(zip だけ) | ネットワーク上の cbz・zip・epub | 差分テスト(ZIPFoundation と全フィクスチャで一致)、読み込み層の単体(ブロックの境界・同時読み・切断・中止・揃ったあと手元だけ)、判定を差し替えた `BookLoader`→`PageRef` のゴールデン一致 |
| 3 | フォーク 2 本の入口 → 7z・rar も読み込み層へ | cb7・cbr | フォーク側のテスト、アプリ側のフィクスチャのゴールデン一致(ファイル/読み込み層) |
| 4 | 写しを残す(LRU・上限の設定・シークレット除外)、PDF・フォルダの本(§4.4) | 開き直し、PDF | 永続化の往復、上限での追い出し、シークレットで残らないこと |

段階 1 だけで cbz の最初のページは 9.7 秒 → 約 2.9 秒、段階 2 まで入れば約 0.1 秒(§3.2)。

---

## 7. まだ確かめていないこと・実機での確認

- **実物の SMB での数字**(リースの有無で変わる)。→ リースを出す NAS では §10.5 で測った。リースを出さない NAS は未確認。手順案: 使い捨ての合成本(ノイズの JPEG 200 枚。実在の名前を使わない)を NAS へ置き、
  このメモの計測 CLI(scratchpad の `netbench`)で「今の reader」と「読み込み層」を交互に 3 回ずつ。ネットワークボリュームの
  TCC ダイアログが出るので、利用者が操作できるときに行う。
- smbfs で ImageIO・CGPDFDocument が本当に mmap するか(ローカルでしか確かめていない)。
- NAS の HDD のスピンアップ中の振る舞い(最初の読みが 10 秒ほど止まる)。読み込み中の表示・中止が効くことを確かめる。
- Wi-Fi のつなぎ替え・スリープ復帰で記述子が使えなくなったときの復帰(開き直し)。

---

## 8. 決めてほしいこと

1. **読み終えた写しを手元に残すか**。残すなら既定の上限(案: 2GB、環境設定「キャッシュ」)。残さない場合も、本を開いている間は手元の
   一時ファイルに貯める(閉じたら消す)。
2. **フォーク 2 本(Unrar.swift・SevenZip.swift)に「呼び出し側の関数から読む」入口を足すこと**。docs/11 の「フォークが何を変えたか」に
   1 項ずつ増える。本家へ提案する場合は 1 件 1 PR。
3. **段階の順番**。案は §6 のとおり 1 → 2 → 3 → 4。段階 1 だけ先に入れても効果が大きい。
4. 環境設定の逃げ道(「ネットワーク上の本の読み方: 自動/使わない」)を表に出すか、隠し設定にするか。

---

## 9. 出典

- SMB クライアント: [smbfs_vnops.c](https://github.com/apple-oss-distributions/SMBClient/blob/main/kernel/smbfs/smbfs_vnops.c)(`smbfs_vnop_read`・遅延クローズ)、
  [smbfs_node.c](https://github.com/apple-oss-distributions/SMBClient/blob/main/kernel/smbfs/smbfs_node.c)(リースとキャッシュ)、
  [smbfs_vfsops.c](https://github.com/apple-oss-distributions/SMBClient/blob/main/kernel/smbfs/smbfs_vfsops.c)(最大 I/O 16MiB)、
  [smbclient_internal.h](https://github.com/apple-oss-distributions/SMBClient/blob/main/lib/smbclient/smbclient_internal.h)(要求の大きさと並列数)、
  [smbfs_smb_2.c](https://github.com/apple-oss-distributions/SMBClient/blob/main/kernel/smbfs/smbfs_smb_2.c)(共有モード)、
  [xnu vfs_cluster.c](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/vfs/vfs_cluster.c)(先読み)、
  [smb.conf(5)](https://www.samba.org/samba/docs/current/man-html/smb.conf.5.html)(Samba の既定)
- mmap: [Mapping Files Into Memory](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemAdvancedPT/MappingFilesIntoMemory/MappingFilesIntoMemory.html)、
  [swift-foundation Data+Reading.swift](https://github.com/swiftlang/swift-foundation/blob/main/Sources/FoundationEssentials/Data/Data%2BReading.swift)
- 判定: [Apple Q&A NW09](https://developer.apple.com/library/mac/qa/nw09/_index.html)、[TN3150](https://developer.apple.com/documentation/technotes/tn3150-getting-ready-for-data-less-files)、
  [VLC modules/access/file.c](https://github.com/videolan/vlc/blob/master/modules/access/file.c)
- ZIPFoundation 0.9.20: [Archive.swift](https://github.com/weichsel/ZIPFoundation/blob/0.9.20/Sources/ZIPFoundation/Archive.swift)、
  [Archive+Reading.swift](https://github.com/weichsel/ZIPFoundation/blob/0.9.20/Sources/ZIPFoundation/Archive%2BReading.swift)、
  Libc の [setvbuf.c](https://github.com/apple-oss-distributions/Libc/blob/main/stdio/FreeBSD/setvbuf.c)・[fseek.c](https://github.com/apple-oss-distributions/Libc/blob/main/stdio/FreeBSD/fseek.c)・[fread.c](https://github.com/apple-oss-distributions/Libc/blob/main/stdio/FreeBSD/fread.c)、
  Readium のフォーク [readium/ZIPFoundation](https://github.com/readium/ZIPFoundation)・[ZIPFoundationArchiveFactory.swift](https://github.com/readium/swift-toolkit/blob/develop/Sources/Shared/Toolkit/ZIP/ZIPFoundation/ZIPFoundationArchiveFactory.swift)
- rar・7z: [RAR technote](https://www.rarlab.com/technote.htm)、[7zFormat.txt](https://github.com/ip7z/7zip/blob/main/DOC/7zFormat.txt)
- 他のビューア: [YACReader comic.cpp](https://github.com/YACReader/yacreader/blob/develop/common/comic.cpp)、[Simple Comic TSSTManagedGroup.m](https://github.com/MaddTheSane/Simple-Comic/blob/arc/Classes/Managed%20Objects/TSSTManagedGroup.m)、[mpv manual](https://mpv.io/manual/master/)

---

## 10. 決定と実装(2026-09-25)

### 10.1 決まったこと(利用者の回答)

1. 読み終えた写しは**残さない**(本を開いている間だけ一時ファイルに貯め、使われなくなったら消す)。
2. フォーク 2 本に入口を足してよい → Unrar.swift `485f7d3`・SevenZip.swift `f93e3eb` を push。
3. 段階の順番は §6 の案どおり。
4. (追加の指摘)本全体の寸法の下調べは、**設定された枚数の先読みを終えてから**始める。

### 10.2 実装したもの

| 段階 | 中身 | 主な場所 |
|---|---|---|
| 1 | サイドパネル下段の最上位の一覧を裏で取る / ComicInfo の取り込みは PageLoader が開いている書庫で読む / zip の 1 ページを 1 回の `read()` で / 本全体の下調べは最初の見開きと先読みの後(最大 10 秒待つ) | `BookContentsBrowserState.make(book:)`、`PageLoader.bookArchiveComicInfo()`、`ZipArchiveReader.data(at:)`、`ViewerViewModel.warmUpWideImageCacheForEntireBook(after:)` |
| 2 | 判定(`MountTable.isRemote`)と読み込み層、zip・cbz・epub の `CentralDirectoryZipReader`。`ZipArchiveReader(url:)` を直接作っていた 4 箇所を `makeArchiveReader` へ寄せた | `NetworkVolumeReading`、`StagedFileSource`(+`StagedFileRegistry`)、`CentralDirectoryZipReader` |
| 3 | rar・7z もネットワーク上では読み込み層を通す(フォークの入口) | `RarArchiveReader.init(source:)`、`SevenZipArchiveReader.init(source:)` |
| 4 | PDF をネットワーク上では `CGDataProvider` の直接読み出しで開く(mmap をやめる) | `openPDFDocument(at:stagesWholeFile:)` |

写しを残さない決定なので、§4.3 の「写しの LRU・上限の設定」は作っていない。環境設定の逃げ道は**隠し設定**
(`qooViewer.pref.networkVolumeStagedReading`)にした(§8 の 4 は回答が無かったので、画面を増やさない側)。

### 10.3 実装中に分かったこと

- **ZIP64 の拡張欄の位置 0**: ZIPFoundation は ZIP64 の拡張欄の値が 0 だと 32 ビットの欄(0xFFFFFFFF)を使う。先頭のエントリ(位置 0)を
  ZIP64 の欄で書いた書庫では、そこでローカルヘッダーを読めずに一覧が止まる。新しい reader は「読まなくても分かる失敗(ファイルの終わりより
  後ろ)」でだけ同じく止まるようにした(テストで作った書庫で見つけた)。本番の reader で蔵書 8,266 本を突き合わせ直して差異 0。
- **記述子の上限**: 読み込み層は 1 本で記述子を 2 つ持つ。猶予(30 秒)の間すべて残すと、ネットワーク上のフォルダの一覧の絵だけで
  本の数 × 2 が溜まる。猶予で残すのは直近 4 本までにし、手元の一時ファイルは最初の取り寄せで作るようにした。
- **unrar の `ErrHandler`(既存の不具合)**: テストを並べて走らせると、rar の読みがときどき `badData` / `unknown` で失敗した。
  ファイルから読む従来の経路でも起き、記述子の数(2,560 のうち約 40)とも無関係。unrar の結果を持つ `ErrHandler` がプロセスに 1 つで、
  **別のスレッドの失敗が成功した読みの戻り値になる**のが原因だった(フォークのテストで再現: 400 周で 8 回)。フォークで `thread_local` にして
  直した(Unrar.swift `70fe20d`。[11](../11-forked-dependencies.md))。アプリでも、壊れた rar の一覧の絵と別の rar の本の読み出しが重なれば
  起きうるものだった。
- **同じ sortKey の 2 ページ**: `nested-same-name-file-and-folder.cbz` の 2 ページ(入れ子の `a.zip` の中と、`a.zip` という名前のフォルダの
  中)は sortKey が同じで、並びが書庫の一覧の順(辞書の順。プロセスごとに変わる)で決まる。ローカル同士でも入れ替わる既存の性質で、
  テストは id ごとに比べる。
- **模擬の注意(再掲)**: 裏の取り寄せのスレッドは `.utility`。低 QoS のスレッドの `usleep` は timer coalescing で延びるので、模擬では
  裏の取り寄せが実際より遅く見える(本物のネットワーク待ちには当たらない)。

### 10.4 テスト

- `NetworkVolumeReadingTests`: zip 系フィクスチャ全件で ZIPFoundation と同じ答え、境界ケース(ZIP64 2 通り・コメント・先頭のゴミ・同名・
  暗号化・ZIPFoundation の書いたディレクトリと記号リンク)、意図した違い(壊れたローカルヘッダー)、読み込み層(任意の位置・大きさ、
  8 スレッド同時、全部揃ったら元のファイルが消えても読める・解放で一時ファイルが消える、止めた後、登録簿の共有と本数の上限)、
  ネットワーク上とみなした書庫の本(zip・rar・7z・epub 全件)と PDF がローカルと同じページ一覧・同じバイト列・同じ描画。
- `ArchiveReaderTests` の入力に `.staged`(読み込み層経由)を足し、台帳の一覧・中身の突き合わせを 3 形式とも読み込み層でも通す。
- フォーク: Unrar.swift 38 件(`ReaderArchiveTests`・`ConcurrencyTests` を追加)、SevenZip.swift 39 件(`ReaderArchiveTests` を追加)。
- 全体 1,627 件が通る(並べて走らせて、ErrHandler の修正後 8 回連続)。

### 10.5 実物の NAS での計測(2026-09-25)

SMB でマウントした実物の NAS(リースを出す。2 回目以降の同じ場所の読みは Mac 側のキャッシュから返る)の蔵書で測った。本の名前は
記録していない(件数・大きさ・秒数だけ)。

**アプリ全体、「開く」から最初の見開きまで。** 1.71 と今の版に「最初の見開きを描いた時刻」を書く 1 行だけを足した Debug ビルドで、
まだ読まれていない本を 1 回に 1 冊ずつ。

| 形式 | 1.71 | 今の版 |
|---|---|---|
| cbz(`open -a`) | 0.51〜1.51 秒 | 0.48〜0.75 秒 |
| cbr(Quick Open 無し) | 約 1.1〜1.4 秒 | 約 1.1〜1.4 秒 |

Quick Open のある cbr は両版で差が無かった。Quick Open の無い rar はヘッダーを書庫の頭から順にたどるしかなく(§2.2)、どちらでも残る。途中で「今の版の cbr が遅い」ように見えた
ことがあったが、本ごとの大きさ・位置のばらつきだった(同じ本で順番を入れ替えて測り直すと差は無い)。CLI(reader 単体)の最初のページは
今の reader 0.06〜1.97 秒 → 読み込み層 0.08〜0.15 秒。

**Finder から開くと遅い、ファイルブラウザからだと 1.71 でも速い(利用者の体感)。** 開いたあとは同じ `AppState.open(request:)` を通るので、
差は開く前にある。526〜707MB の cbz 12 冊(48 項目のフォルダ 2 つ)を、条件 × 版ごとに 2 冊ずつ。Debug の保存データ(`/` の許可がある)を
シークレットモードで使い、何も記録していない。Finder の代わりは `open -a`(アプリに届く「開く」は同じ)。開く直前に本のどれだけが
Mac 側のキャッシュにあるかを、ファイルを読まずに `mmap` + `mincore` で数えた(smbfs でも数えられる)。

| 開き方 | 1.71 | 今の版 | 開く直前にキャッシュにあった割合 |
|---|---|---|---|
| Finder(`open -a`)。ホームはローカルのフォルダ | 1.90 / 2.24 秒 | 0.36 / 0.61 秒 | 0% |
| ファイルブラウザのリスト表示でダブルクリック | 2.22 / 2.37 秒 | 0.57 / 0.65 秒 | 0% |
| アイコン表示でサムネイルが出てからダブルクリック | 0.52 / 0.72 秒 | 0.45 / 0.65 秒 | 約 3%(1.71 のサムネイル) |

- 1.71 で速かったのは**アイコン表示だけ**。リスト表示は Finder と同じく遅い。アイコン表示のサムネイル作り(`BookThumbnailer`)が本の
  一覧と先頭の画像を読み(1 冊 20MB 前後)、それがキャッシュに残るので、開いたときの一覧の細かい往復がキャッシュから返る。
  Finder から開く本にはこの下読みが無い。
- 今の版は下読みが無くても開き方によらず 0.4〜0.65 秒。今の版のサムネイル作りは中央ディレクトリから一覧を取るので、読むのは約 0.7%
  だった(1 例)。
- アプリを起動していない状態から Finder で開く場合の起動時間は測っていない(どの版でも同じく加わる)。

計り方の落とし穴(次に測る人へ):

- Finder に `open … using` で scratchpad のアプリを指定すると、Finder がアプリを解決できず「アプリケーション "(null)" には … を開く
  アクセス権がありません」のダイアログを出す(利用者の画面に出る)。`open -a` を使う。
- アプリの PID は `pgrep -f` で取らない(自分のコマンド行に当たる)。System Events の `unix id of first process whose bundle identifier is …`。
- リスト表示の行は AX の `AXScrollToVisible` では見えるところへ来ない。スクロールバーの `AXValue` を「行番号 ÷(行数 − 1)」にする。
- アイコン表示の項目は名前の無い `AXGroup` で、`AXIndex` は**リスト表示の行番号 + 1**。対応は「アイコン表示で 1 回クリック → リスト表示に
  戻して選ばれた行」で番号だけで確かめる。
- 開いた本が本当に目的の本かは、開いた後にその本のキャッシュの割合が増えたかで確かめる(番号がずれていた 2 回は、ほかの本が開いて
  目的の本は 0 のままだった)。
- `defaults write` にかっこを含むパスを渡すときは `-string` を付ける。付けないと解釈に失敗し、エラーにパスがそのまま出る。

### 10.6 まだ確かめていないこと

- フォルダの本の寸法の読み取り(`CGImageSourceCreateWithURL`)がネットワーク上で mmap するか、するなら Data 経由に替えるか。

