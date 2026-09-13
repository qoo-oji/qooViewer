# 13. 経緯・既知の制限・未着手の課題

## 経緯(主な方針転換)

正確な変更履歴は [CHANGELOG.md](../CHANGELOG.md)(0.95 → 1.41、2026-07-26 〜 2026-09-04、
ほぼ毎日リリース)にあります。ここには、コードのコメントに残っている**方針の転換**だけを、
「以前どうだったか → なぜ変えたか」の形で並べます。引き継いだあとに「元に戻したくなる」ものは
たいていここにあり、戻すと同じ不具合が再発します。

| 領域 | 以前 | 今 | 理由 |
|---|---|---|---|
| SwiftData のコンテキスト | ストアごとに分けていた | `mainContext` を全員で共有 | 一方の更新がもう一方に反映されず静かに失敗 |
| 一意制約 | `@Attribute(.unique)` | 付けない。アプリ側で保証 | 連続 insert+save で無関係な行が消えた |
| 絞り込みフェッチ | `#Predicate` | 全件フェッチ+辞書 | 0件を誤って返す事象 |
| EPUB/PDF のレイアウト | ファイルの指定が常に勝ち、トグルをロック | 初回に1回だけ取り込み、以後 DB | 取り込んだ結果ユーザーが何も変えられない |
| ページの並び | `.numeric` 比較(従来順) | Finder と同じ照合(正準順)。設定で切替 | `_Com-title-cover.JPG` のような名前で Finder と食い違い、大文字小文字で並びが丸ごと変わった |
| ブックマークの指し先 | ページ番号 | 鍵(`sortKey`)。番号は導出 | 並び替え・除外で別のページに付いているように見えた |
| ページ画像のキャッシュ | NSCache に CGImage | 厳密 LRU に mmap の画素バッファ | 上限の3倍に膨らみ、解放しても戻らなかった |
| 7z の読み取り | ブロック丸ごと伸長(本家) | ストリーミング(フォーク) | GB 級の常駐 |
| 7z の後方読み | 履歴リングで辞書の外へも戻れるようにした | 撤回。読む側が書庫順を守る | メモリを減らすためのフォークにバッファを足すのは筋が通らない |
| 入れ子の rar/7z | 必ず一時ファイル | 予算内ならメモリから(フォーク) | 一時ファイルの寿命と容量の管理が複雑 |
| zip のファイル名 | uchardet(1件ずつ) | Foundation(書庫全体で1回) | 60件中5件しか正解しなかった。本家の URL も解決不能 |
| 履歴の再検証 | メニューを開く直前に同期で全件 | アクティブ化とマウントで非同期 | AppKit のメニュー更新に間に合わず標準項目が欠けた |
| メニューの更新 | 即時 | `MenuBarMenuGate` で保留 | macOS 26 でメニューを開いている最中の再構築が落ちる |
| App 直下のストア | `@StateObject` | publish しない箱 | 1回の発火で全 Scene と全メニューが再評価された |
| ウインドウの状態復元 | 既定 | `.restorationBehavior(.disabled)` | 0枚からの再オープンで古い NSWindow が再利用され一瞬出て消えた |
| 起動時のウインドウの大きさ・位置 | `.defaultSize` は固定値、復元は表示後 | `.defaultSize` / `.defaultPosition` にも前回の値を渡す | 900x640 で出てから前回の大きさへ広がり、中身も 6 列 → 14 列で組み直された |
| 「隠す」3つ(ツールバー / プログレスバー / サイドパネル) | `onAppear` で環境設定から写す | `AppState` を作る時点で渡す | 隠してあるパーツが最初の1フレームだけ現れ、閉じる様子が見えた |
| コレクションのタイル | セルごとにカバーを読む | 焼いた1枚を切り分ける + 最初のフレームには載せない | 札 100 枚の画面で 600 回のファイル読み・復号・タスクになっていた |
| 焼いた札の切り分け | body のたびに `cropping` | 控えて同じオブジェクトを返す | 毎回別オブジェクトになり、サイドパネルの表示のたびに画面中の画像がクロスフェードした |
| 資源の解放 | `deinit` 任せ | `releaseResources()` を `onDisappear`/`willClose` から | SwiftUI が古い `@StateObject` を1世代抱える |
| キー入力 | `.onKeyPress` | NSEvent ローカルモニタ | 環境によって矢印キーが届かない |
| マウスの設定 | トリガー(4択)→操作 | 操作→トリガー(複数可)。語彙を拡張 | キーボードと向きが逆の UI が同居していた |
| 環境設定の形 | `TabView`(8タブ) | 2ペイン(`SettingsPane`) | タブバーの限界。1語縛りのラベル |
| 環境設定の説明文 | 行の下に常時表示 | ラベルに吸収、残りは ⓘ の吹き出し | 説明で画面が埋まり認知コストが高い |
| 「外観」「レイアウト」 | 1枚に全セクション | 面ごと/形式ごとの子ページ | 同じ行名が繰り返され見分けられない |
| 見開き分割の表示名 | 「見開き分割」 | 「横幅に合わせる(単ページ)」 | 画像を切る機能だと誤解された |
| 補間品質 | 高/標準/低 | 高/標準 | 標準と低は描画が同一だった |
| サムネイルのディスクキャッシュ | 黙って常時 ON | 既定 OFF、上限と使用量を表示 | 数百 MB 溜まっていた |
| 最初/最後のページの挙動 | 共通の1設定 | 前後で別の設定 | 「最後だけ閉じたい」が表せない |
| お気に入りの開き方 | 毎回サブメニューで選ぶ | 環境設定の1箇所 | Finder から開くときと同じ考え方 |
| お気に入りそのもの | メニュー・ツールバー・サイドパネル・ウェルカム画面に出ていた | `FavoritesFeature.isEnabled == false` で入り口を全部閉じる。コード・データ・JSON は残す | ライブラリ/コレクションに置き換えるため(改善要望5)。消すと保存済みの登録と過去の書き出しファイルを失うので、隠すだけにした |
| ウェルカム画面 | 「開く…」+ 最近開いたファイル / 最近のお気に入りの2列 | ライブラリ/コレクションの本棚。履歴は「履歴から開く」ボタンへ | 改善要望5(→ [14](14-library-collections.md)) |
| コレクションの編集 | 作成・追加・ライブラリの操作も編集モードの中 | 編集モードが決めるのはクリック/ドロップの意味とゴミ箱だけ | 「棚を作る・本を入れるのは最初にやることなのにモードの奥に隠れていた」 |
| カバーの切り出し | 抽出時に 2:3 へ切って保存 | 切らずに保存し、比と位置は表示時に効かせる | 比をライブラリごとに選べるようにしたら、トグル1つで全冊の読み直しになった |
| カバーの残す位置 | 「自動(読み方向から決める)」があった | 上/左・中央・下/右の3値。nil はライブラリに従う | 上下の切り出しに読み方向は何も言えず、読み方向を変えるとカバーが変わるのは予想しにくい |
| 本を別のコレクションへ移す | 右クリックにあった | 無し(足してから外す) | 自動登録フォルダを持つ棚から移すと次の走査で戻ってくる |
| 自動登録フォルダの契機 | 人の操作だけ(見にきたときに走査)、10秒より新しいものは見送る | FSEvents で監視 + 「書き込みが止まったか」の判定 | 「コピーした瞬間に増えてほしい」―― 画面を見ながらコピーする |
| 既定のライブラリの名前 | 作った時点の文字列を DB に保存 | 名前を持たず表示言語で組み立てる | 日本語訳を入れる前に起動した環境が「Library」のまま直らなかった |
| ブックマークの並べ替え | 専用の6種 | お気に入りと同じ3種×昇降 | 編集ウインドウを2ペインへ揃えた |
| 一括リネーム | 独立ウインドウ | 編集ウインドウのシート | bookID の橋渡しとフォールバック画面が不要に |
| 書き出しの出力 | 出力先へ直接 | 一時ファイル → 置き換え | 元の本と同じ場所へ書くと元が消えた |
| PDF の読み方向 | 失われる(警告バナー) | 増分更新で Catalog へ書く | CoreGraphics に API が無いが PDF 自体は書ける |
| 「情報を見る」 | サブメニュー | オーバーレイパネル | 値の先頭が揃わない。`.popover` は外へはみ出す |
| 拡大鏡の結合画像 | 常に作る | 拡大鏡 ON の間だけ | 瞬間的に 1GB |
| 自動削除 | 読書位置と一緒にブックマークも | 読書位置だけ | 手間をかけた情報を勝手に消さない |
| 全削除の範囲 | ストア・キャッシュ・履歴 | アクセス権を除くすべて(終了時に実行) | 環境設定が残る中途半端な範囲だった |
| 古いアプリでストアを開く | 何もしない(SwiftData が黙って移行) | 開く前に世代を確かめ、新しいストアなら尋ねる(`StoreSchemaGuard`) | 1つ前の qooViewer を起動しただけで、1.55 で足した表紙の列が131冊ぶん消えた(→ [06](06-persistence.md#古いアプリで新しいストアを開くと列が黙って消える2026-09-11-の事故と対策)) |
| SwiftData のテスト | メモリ内のストアだけ | ディスク上の使い捨てストアで開き直しと移行も通す | メモリ内では「開き直したら何が残るか」を一度も通らず、上の事故に気づけなかった |
| 表紙の元画像の掃除 | 参照が無ければ即削除 | 30日隔離し、参照が戻れば戻す | 参照のほうが間違って消えたとき、作り直せない画像まで消えた |

## 既知の制限

コードのコメントで「制限」「未対応」と明記されているもの。

- **rar**: Unicode 名を持たない古い RAR4 のファイル名は文字化けする(ライブラリの外で対処不能)。
  分割ボリュームは非対応(メモリからは特に)。
- **zip**: 1つの書庫にレガシーな文字コードが2種類以上混在すると一方に倒れる。単一の文字コードでも、
  Foundation の自動判定に頼るため **EUC-JP は当たらず**(Baltic / Latin-1 のような単バイトの文字コードとして
  「読めて」しまう)、**CP949 は Shift-JIS / GB18030 に倒れる**(2026-09-05、テストのフィクスチャで発見。
  `NSString.stringEncoding(for:)` は `likelyLanguageKey` を渡さないとロケール寄りに判定する)。どちらも
  `qooViewerTests/Fixtures/manifest.json` に「ページ数だけ」の期待として固定してある。
- **7z**: BCJ2 はブロック丸ごと伸長にフォールバック。BZip2 / Deflate / 暗号化は読めない。
  辞書の外への後方ジャンプはブロック先頭からやり直し(読む側が書庫順を守る前提)。
  (エントリの更新日時が常に nil だった件 ―― 2026-09-05 に `ArchiveReaderTests.entryDates` で
  発見し、フォーク側で修正済み → [11](11-forked-dependencies.md#upstream-から直したもの2026-09-05))。
- **並び順はロケール依存**: 正準順は `localizedStandardCompare`(Finder と同じ照合)なので、
  異なる文字体系が混ざった名前の前後は OS の言語で入れ替わる(例: 「日本語」と「第1巻」は
  日本語ロケールと英語ロケールで逆になる)。アプリとしては Finder に合わせている以上これが正しく、
  テストの golden 側で「名前の頭を ASCII にして並びを決める」ことで避けている(2026-09-05、
  CI が英語ロケールで走って発覚)。
- **EPUB**: 固定レイアウトの画像 EPUB のみ。目次は nav.xhtml だけ(`toc.ncx` へのフォールバック
  未対応)。
- **PDF の書き出し**: ページ単位のレイアウト(このページだけ単独/左右)は PDF に概念が無く失われる。
  カバー指定は無い。
- **棚のフォルダ**(2026-09-06 のユーザー報告で対応 →
  [04](04-book-loading.md#棚のフォルダ--開くのは先頭の1冊)): 書庫・PDF・EPUB が直下に置かれた
  フォルダは、まとめて1冊としては開けない(先頭の1冊が開く)。章ごとに書庫へ分けた本を
  つないで読む道は無くなった(ユーザーの判断。以前はドロップがその唯一の入口だった)。
  画像フォルダだけが並ぶフォルダは従来どおり1冊のまま。
- **フォルダ/書庫の中の PDF・EPUB**(2026-09-06 のユーザー報告で対応 →
  [04](04-book-loading.md#フォルダ書庫の中の-pdf-と-epub)): 統合できるが、書庫の中の PDF は
  中身をメモリへ載せてしか開けない(`PageLoader` は 3 本まで)。そうした本は構造キャッシュの
  高速経路からも外れる。フォルダの本そのものには読み方向・見開き強制のヒントを持ち込まない
  (どの PDF/EPUB のものを採るべきか決められないため。ページ単位の見開き指定だけは効く)。
  上段のフォルダブラウザで「フォルダを1冊として開く」導線が出るのは今も**直下に画像がある
  フォルダだけ**で、書庫だけ・PDF だけのフォルダは(従来どおり)ドロップで開く。
- **ComicInfo.xml**: v2.1 草案の要素(`Translator` / `Tags` / `StoryArcNumber` / `GTIN`)は扱わない。
  `Volume` の意味はサーバーによって違う(Komga vs Kavita)。
- **その場限りの本**: 最大 1000 枚。sourceURL が先頭1枚なので「同じ本を開いているウインドウ」の
  判定に使えない。本の書き出しはグレーアウト。
- **本の中身ブラウザ**: ネストした書庫の中で見つけた、`BookLoader` が読んでいない画像は
  「新しい本として開く」だけ(そのページへ厳密にジャンプしない)。
- **並び順**: 「Finder に揃える」を後から切り替えても、レイアウトのある本は当時の並びに固定される
  (`pinPageOrderIfNeeded`)。
- **履歴の互換**: 新形式→旧バージョン→新形式の往復で、旧バージョンで増えた履歴は消える。
- **フォークの `Archive`** はスレッドセーフではない(`PageLoader` の中でだけ触る)。
- **コレクション**(→ [14](14-library-collections.md)): 自動登録フォルダはパスだけを持つので、フォルダを
  移動・リネームすると自動登録は静かに止まる(選び直せば直る)。FSEvents はネットワークボリュームでは
  飛ばないため、そこでは従来の契機(アクティブ化・画面の表示)まで反映が遅れる。自動登録フォルダの中の
  本をコレクションから外しても次の走査でまた入る(除外リストは作らない、というユーザーの判断)。
  実機で残っている見た目: すりガラス面を 100% で塗ると札の角丸の板が面に溶けて境界が消える(カバーと
  名前は読める)、新しいウインドウで選択中のライブラリが帯のスクロール範囲の外にあるとどれも選ばれて
  いないように見える、「本が見つかりません」のアラートに OK とキャンセルが並ぶ(お気に入り側と同じ形)。
  カバーの位置指定がシートに反映されない件(2026-09-09)は、再現しなくなった状態でしか確認できていない。

## 未着手・「今後の改善課題」と書かれているもの

- `ViewerViewModel.setPageLayout`: 除外を伝播範囲で「解除する」選択肢(設計コンセプト 2.3/3.3 節に
  あった「既存の除外設定を保持しますか/解除しますか」)は未実装で、常に保持する。
- 自動レイアウト(`wideImageAspectRatios`)の進捗表示とキャンセル。ヘッダー読み取りだけになって
  十分速いが、フォーマット非対応でヘッダーが読めない場合の備えとして残っている。
- 差し替え確認ダイアログの3択目「エクスポートしてから破棄する」(2.5 節)。
- `FavoriteBook.sortOrder` / `FavoriteFolder.sortOrder`: 手動ドラッグの並べ替えを再実装する
  場合に備えて値だけ保持している。
- `FavoritesLimits`(999 件・3階層)を環境設定から変えられるようにする案(お気に入りは無効化中なので、
  復活させるときに一緒に判断する)。
- 補助ウインドウの純正風リスタイル(ツールバーへクロームを移す計画、2026-08-29 立案)は、
  「一覧ウインドウの共通の形」として大半が実装済み。残りは各ウインドウのコメントで確認。
- 環境設定「レイアウト」の形式ページを、アプリの他の場所から名指しで開く経路
  (`SettingsNavigator` に `appearanceTarget` 相当が無い)。

### テストのパタンセット ―― 段階 0〜4(完了、2026-09-06)

`qooViewerTests` を「UI を伴わない経路」まで広げる計画(段階 0〜4)は**全段階が完了**しました
(→ [02](02-project-and-build.md#テストターゲットqooviewertests))。
決めごとは段階 0 と同じ ―― 共有の保存先に触れない、golden は `sortKey` の列、既知の限界は
「落ちない・数は合う」で固定、テスト全体で 60 秒以内(現状 361 テスト・約 2.1 秒)。

**段階 1 でできたもの(2026-09-05)**
- `ArchiveReaderTests` ―― `ArchiveReading` の適合テスト。台帳に `archive`(`listFilePaths` の全件と、
  各エントリのページ番号)を持つ 12 のフィクスチャ × ファイル入力 / メモリ入力で、一覧・取り出し
  (中身の番号まで)・`dataPrefix`・`entryUncompressedSize`・`entryDates`・`extract`(上限超過で
  `entryTooLarge`・書きかけを残さない)・ソリッド書庫の順読み / 逆読み・`residentDecompressionBufferBytes`・
  暗号化 rar・開けないファイルを見る。
- `NestedArchiveResolverTests` ―― 予算の導出、メモリ / 一時ファイルの行き先、一時ファイルの寿命
  (`OpenArchive` を手放すと消える)、LRU、`openTransient` が LRU に載らないこと、
  `materializeToIndependentFile`。
- `ZipEntryNameTests` ―― `EntryNameDecoder` の黒箱(`ZipArchiveReader.listFilePaths` 越し)。
- `BookLoaderBehaviorTests` ―― 中止、`onProgress`、メモリ予算 0 でも同じ本になること、
  `load(imageFiles:)`。
- `BookInternalBrowsingTests` ―― `matchKey` が `PageRef.sortKey` と一致すること、仮想フォルダ /
  入れ子の書庫 / 実フォルダの見分け、`__MACOSX` の除外、並びが本のページ順であること。
- `EpubStructureTests` / `PDFStructureTests` ―― spine 順・見開き・読み方向・書き方の揺れ・書誌
  メタデータ・目次 / アウトライン。

**段階 1 で分かったこと**
- 7z のエントリの更新日時が常に nil だった(フォーク側の取り違え。同日に直して pin を更新した)。
- 正準順はロケール依存で、CI(英語)と手元(日本語)で golden が食い違いうる(同上)。
- `URL.resolvingSymlinksInPath()` は symlink を解いた後に先頭の `/private` を**外す**ため、
  サンドボックス無しで走る CI では `/var/folders/…` を返し、`FileManager` の列挙が返す
  `/private/var/folders/…` と食い違う。テストの作業フォルダは `canonicalPathKey` で実体にする
  (`qooViewerTests/Support/TemporaryDirectory.swift`)。
- `dataPrefix` の打ち切りは伸長のチャンク単位なので、小さなフィクスチャでは「頼んだバイト数ちょうど」
  にはならない(効き目は実物の本での実測の話)。

**段階 2 でできたもの(2026-09-06、84 → 301 テスト)**
suite の一覧は [02](02-project-and-build.md#テストターゲットqooviewertests)。計画に挙げた対象は
すべて入っている ―― `EffectivePageOrder` / `BookOpenRequest` / `ComicInfoXML`・`ComicInfoResolver` /
`MetadataFormatCompiler`・`BookMetadataDeriver` の既定ルール表 / `LayoutAutoCalculator` /
`PageLayoutState ↔ PageSpreadPosition` / `PagePixelCache` / `BookPageListCache.Entry` の旧版 JSON /
`ThumbnailDiskCache.trimThreshold` / `TemporaryFileStore.isStaleEntry` / `ImageDecoder` /
`ContrastCorrector` / `DirectoryBrowser.sortedEntries` / `SiblingFinder` / `FileNodeIdentifier` /
`QooLibraryExportFile` の往復と版 2 / `RemappableKey`・`MouseTrigger` / `String(localized:language:)`。

計画から変えたところ:
- **旧版の JSON はフィクスチャにしなかった**(`Fixtures/json/` を作っていない)。読めるテキストなので、
  期待値の隣にテストの中へ直接書いたほうが分かりやすい(`LibraryJSONSchemaTests`)。
- **avif はコミットした**。計画では「手元に encoder が無い」としていたが、実際は ImageIO からも
  `sips` からも書ける。それでも実物を置いたのは、将来書けなくなっても気付けるようにするため。
  webp は本当にエンコーダが無いので、`scripts/fixtures/make-webp.py` で自前で書いている
  (単色なら画素のデータが 0 ビットで済む VP8L の性質を使う。→ [02](02-project-and-build.md#テストのフィクスチャ))。

**段階 2 で分かったこと**
- **時間で待つテストは、テストが増えると壊れる。** `BookLoaderBehaviorTests` の中止のテストは
  「進み具合の通知で `Thread.sleep(0.2)`、100ms 後に中止」だった。`Thread.sleep` は協調スレッドを
  塞ぐので、並行して走るテストが増えると**テスト側の `Task.sleep` が再開する前に読み込みが走り切り**、
  必ず落ちるようになった(84 → 264 テストで再現)。中止の合図を走査そのもの(通知の中)から出す形へ
  直した ―― 速さに依存しない。新しく足すテストでも、時間で待つ形は避けること。
- `AppleLanguages` は NSGlobalDomain にもあるので、アプリの領域から消しても
  `stringArray(forKey:)` は OS の値へ抜けて返る。「消えたこと」を見るには
  `persistentDomain(forName:)` でその領域を直接覗く。
- ヘッダーに巨大な寸法を書いただけの画像(`ImageDecoder.hasAcceptablePixelCount` を試したい)は
  **フィクスチャにできない**。ImageIO は実データの無い PNG / JPEG に寸法を返さず(判定は素通しの
  `true` になり、単に「壊れた画像」として nil になる)、実データを持たせると 200KB の上限を超える
  (4 億画素を単色で deflate しても 1MB 超)。あの判定はテストで固定していない。

**段階 3 でできたもの(2026-09-06、301 → 335 テスト)**
`CbzExportTests` / `EpubExportTests` / `PDFExportTests` と `Support/ExportHarness.swift`
(`ExportSource` / `ExportInputs` / `ExportArtifacts`)。suite ごとの中身は
[02](02-project-and-build.md#テストターゲットqooviewertests)。CI には Debug ジョブへ
「Set up EPUBCheck」「Validate exported files」を足し、検品の本体は
`scripts/ci/validate-exports.sh`(手元でも同じものが走る)。

計画から変えたところ:
- **`QOO_TEST_OUTPUT_DIR` は使えなかった**。3 通りとも実測で駄目だった ―― スキームの環境変数の
  値に `$(QOO_TEST_OUTPUT_DIR)` と書いてもビルド設定へは展開されず(テスト側には `$(…)` という
  文字列がそのまま届く)、xcodebuild を起動したシェルの環境変数はテストホストへまったく
  引き継がれず、手元の TEST_HOST は署名済み = サンドボックスの中なのでコンテナの外のパスへは
  書けない(CI は `CODE_SIGNING_ALLOWED=NO` で書けてしまうため、**手元でだけ静かに失敗する**形に
  なるところだった)。**Swift Testing の添付ファイル**(`Attachment.record`)に替えた ―― 結果
  バンドルに入り、サンドボックスの中でも残り、CI は `xcrun xcresulttool export attachments` で
  取り出す。取り出し先での名前は Xcode が付け直す(テスト名 + 連番)ので、検品は**拡張子で
  振り分ける**。
- **EPUBCheck は 5.3.0**(計画時の最新は 5.2.1)。zip の sha256 で固定して `actions/cache` に載せる。
- **`PDFCatalogAugmenter` の 2 回 apply は「成功する」ではなく「断られる」が正解だった**。
  追記済みの Catalog には `/Metadata`・`/PageLayout`・`/ViewerPreferences` が既にあり、単純に足すと
  項目が重複するため、`readLayout` が意図的に `unsupportedStructure` を投げる。テストは
  **ファイルが 1 バイトも変わらないこと**(壊れた PDF だけが残らないこと)を見る形にした。

**段階 3 で分かったこと**
- **非可逆な形式の色は、同じコードでも手元と CI で違う。** `ImageDecoderTests` の heic は
  手元(macOS 26.6)では誤差ゼロなのに、CI(macos-26 のランナー)では 4 ずれて落ちた
  (段階 2 のコミットから CI が赤いままだった)。可逆な形式(png / gif / bmp / tif)は誤差ゼロで
  見て、非可逆(jpg / heic)だけ幅を持たせる形に直した ―― あの試験で見たいのは
  「そのページの画像が返ること」であって encoder の色再現ではない。
- 書き出した EPUB 14 本は EPUBCheck 5.3.0 で指摘ゼロ、ComicInfo.xml 8 本は v2.0 の XSD に適合
  (2026-09-06、手元で実測。java は Kindle Previewer 3 同梱の JRE を使った →
  [12](12-verification-and-debugging.md))。
- EPUB の本の `sortKey` は spine 上の位置(6 桁連番)で、エントリのパスは `id` に入る
  (フォルダ = 絶対パス、書庫 = エントリパス、とは違う)。書き出した EPUB を開き直して
  突き合わせるときはここを間違えやすい。

**段階 4 でできたもの(2026-09-06、335 → 361 テスト)**
`LibraryImportTests` / `SourceLayoutImportTests` と `Support/InMemoryLibrary.swift`
(`isStoredInMemoryOnly` の `ModelContainer` をテストが自前で作り、その `mainContext` の上に
アプリと同じ 5 つのストアを載せたもの)。suite ごとの中身は
[02](02-project-and-build.md#テストターゲットqooviewertests)。

計画から変えたところ ―― **アプリ側に「テストのための口」を 3 つ開けた**。どれも既定値は
これまでどおりで、通常の経路の挙動は変えていない:
- `QooViewerApp.modelSchema` を private から通常のアクセスレベルへ(テストが同じスキーマから
  メモリ内のコンテナを作るため。モデル型の一覧をテストへ書き写すと、アプリにモデルを足したとき
  テストだけ古いスキーマのまま静かにずれる)。
- `LibraryImportExportService.apply` / `buildExportFile` に `cachesPageList:`(既定 true)。
  取り込みは本を読み直すため、これが無いとテスト用の本が実物のアプリの
  `BookPageListCache` へ残る。
- `MetadataFormatStore.init(defaults:)`(既定 `.standard`)。フォーマット定義だけは SwiftData では
  なく `UserDefaults` にあるため、テストは専用の suite を渡す。

**段階 4 で分かったこと**
- **SwiftData の一括削除は、mandatory な逆リレーションがあると全件ぶん失敗する。**
  このハーネスで見つけた実バグ(同日に修正済み)。`FavoritesStore.deleteAllFavorites()` の
  `try? modelContext.delete(model: FavoriteBook.self)` が
  `Constraint trigger violation: Batch delete failed due to mandatory OTO nullify inverse on
  FavoriteBook/folder` を投げて 1 件も消えず(`try?` で握り潰されていた)、実際に消えていたのは
  続く `delete(model: FavoriteFolder.self)` のカスケード = **フォルダの中の本だけ**。
  つまり「保存データの読み込み」でお気に入りに**上書き**を選ぶと、ルート直下の古い登録が
  そのまま残っていた(環境設定「リセット」はストアの実ファイルごと消す別経路なので無関係)。
  直し方は、一括削除をやめてフェッチした行を 1 件ずつ `modelContext.delete(_:)`(上限 999 件)。
  回帰テストは `LibraryImportTests.overwriteAlsoDeletesRootLevelFavorites`。
  **`delete(model:)` を新しく書くときは、その型が mandatory な逆リレーションを持たないか確かめること。**
- **`ModelContext` を作るなら `container.mainContext`。** アプリと同じく 1 つのコンテキストを
  4 つのストアで共有する形にしないと、片方の変更がもう片方から見えない(CLAUDE.md /
  [06](06-persistence.md))。テスト用のコンテナは別物なので、これでアプリの保存先には触れない。
- **メインアクターのストアをテストの中で作ると、走っているアプリ側にも少しだけ触れる。**
  `FavoritesStore` / `BookmarkStore` は固定のキーで `MenuBarMenuGate.shared` へ登録するので、
  テストのストアがアプリのストアの登録を置き換える(影響はテストホストのメニューの更新だけで、
  保存されるものは無い)。ブックマークの書き込みが投げる `.bookmarksDidChange` も同じで、
  アプリ側は自分の保存先を読み直すだけ。
- **既定引数の式はメインアクターの外として検査される**(段階 3 と同じ落とし穴を再び踏んだ)。
  `func f(_ selection: X = .everything)` は、`X` がメインアクターに分離された型だと書けない。
  手元では警告どまりなので、`QOO_CI_WARNINGS_AS_ERRORS=YES` で通すまで気付けない。

**段階 0 で分かったこと**: `FileManager.temporaryDirectory` は `/var → /private/var` の symlink で、
フォルダの本の sortKey は実体パスになる(`TemporaryDirectory` が実体にしてある。アプリでも
symlink 経由のパスで開くと `location(inBookAt:)` の folderPath が nil になる小さな癖がある)。
rar 7.2x は `-ma4` が無く RAR4 を作れない。

### 段階 5 ―― GUI 依存の経路を CI へ移す(2026-09-06。A1〜C5 すべて実装済み、361 → 487 テスト)

段階 0〜4 のあと、「実機でしか確かめられない」と扱ってきた領域を依存関係の側から点検した
(ViewModels / Services / App / Views の全ファイル。点検メモ:
<https://claude.ai/code/artifact/6a10ee64-bc26-4753-bdfc-4eaa1f4ccdb3>)。結論は、**画面の
都合ではなく「共有の保存先に直結している」都合**でテストに載っていないものがかなりあり、
アプリ側に小さな口を開ければ CI へ移せる、というもの。口の作法は段階 4 で開けた 3 つと同じ
(既定値はこれまでどおり・通常経路の差分はゼロ)。

**A1〜C5 は 2026-09-06 にすべて実装した**(実績は各項の「◯ でできたもの」)。下の表は当初の
計画で、開けた口と載せた検証の記録として残してある。残っているのは表の下の
「変更しなくても書けるテスト」と「実機に残すもの」だけ。

栓は 3 つで、最初の 1 つを抜くと後ろが連鎖的に開く(3 つとも A2 / A3 で抜いた):

1. **`AppPreferences` が共有の保存先と直結している。** `UserDefaults.standard` の直接参照が
   91 か所、`init()` の最後で `ThumbnailDiskCache.shared.configure`(設定 OFF なら実物の
   キャッシュを消す入口)と `AppAppearanceApplier.shared.apply` を呼ぶため、テストで
   `AppPreferences()` を作れない。ほとんどの ViewModel がこの型を受け取るので、ここが最初の栓。
2. **ディスクキャッシュの ON/OFF が `skipsPersistence` と一体。** `ViewerViewModel` は
   `PageLoader(usesThumbnailDiskCache: !skipsPersistence)` で作るため、「DB(メモリ内)には
   書きたいがディスクには書きたくない」というテストの要求を表せない。
3. **完了の合図が無い `Task`。** `ViewerViewModel.init` が投げる 4 つの `Task` と、
   `advance()` の待ち行列(`Task.sleep(pageFlipFrameDuration)` を挟む)を待つ口が無い。
   段階 2 の教訓どおり時間で待ってはいけないので、ハンドルを `await` できる形が要る。

候補(効き目の順。この順に実装した: A2 → A1 → A3 → A4 → B1 → B3 → B2 → B4 → B5 → C1〜C5):

| # | 対象 | 開ける口 | 載る検証 |
| --- | --- | --- | --- |
| A1 | `ViewerViewModel` の見開きの組判定 | `shouldPairWithNextPage` / `backwardStepSize` / `forwardStepSize` / `spreadPairStillDisplayable` / `normalizedAnchorIndex` に 4 回コピーされている規則を `nonisolated` な純粋型へ移す(入力: displayMode / readingDirection / pageCount / hint / isWide) | 利用者報告 6 件ぶんの規則を表引きで固定。`fallbackIndex` と `jump(toPercentile:)` も同居 |
| A2 | `AppPreferences` | `init(defaults: UserDefaults = .standard)`、`.standard` 91 か所を `defaults` へ、`defaults !== .standard` なら 3 つの副作用(ディスクキャッシュ・外観・`AppleLanguages`)を呼ばない。`resetToDefaults` の中の `AppPreferences()` も `defaults` を渡す | `migrateLoopBehaviorIfNeeded` の 4 分岐と「読んだその場で旧キーを消す」こと、初回起動の既定読み方向、**面ごとの「初期設定に戻す」の網羅**(`Keys` 82 個が `keys(for:)` と `apply(_:for:)` の両方にあるか。コメント自身が足し忘れを警告している) |
| A3 | `ViewerViewModel` 全体 | `usesDiskCaches: Bool? = nil`(既定 `!skipsPersistence`)、起動時の `Task` と `pageFlipTask` をまとめて `await` する `settle()` | 開始ページの決定(`reopenBehavior` × 前回位置 × `initialEdge` × `initialPageID`)、差し替え検知と古い行の削除、鍵の解決、`advance` の着地と境界、`addBookmark` の重複除去、`toggleDisplayMode` の書き戻し先、`reloadLayoutData(focusPageKey:)`、`skipsPersistence` の契約。テストは必ず `releaseResources()` で静的な登録簿から外す |
| A4 | `KeyBindingStore` | `init(defaults:)`、`fillingMissingDefaults` / `migratedLegacyMouseBindings` を `nonisolated static`(internal)に | 旧 4 択の読み替え、既定の補完の 2 条件(モード別には適用しない)、`resolvedClickAction` の優先順位(位置 > 全体、モード別 > 基本)、保存 → 読み直し |
| B1 | `BookLayoutEditorViewModel` | 読み込み済みの本から行を組む `load(book:)`(`BookPageListCache.shared` と `BookLoader.load(from:)` の既定 `cachesPageList` を避ける) | `movePages` で除外ページが直前の読めるページに付いて動くこと、`applyNewOrder` が隣の変わった見開き左右だけ解除すること、ブックマーク番号の移行、伝播範囲 |
| B2 | `BookExportViewModel` | `exportOne` から「材料集め」を `prepare(row:book:) -> PreparedBook` として分離。書き込みはテスト用サブクラスの `export` で差し替え | 読み方向の優先順位(DB > 開いている本 > 既定)、鍵なしブックマーク、出力先が元ファイルと同じでも元が消えないこと(一時ファイル → `replaceItemAt`) |
| B3 | `LibraryCleanupViewModel` | `FolderAccessStore.init(defaults:)`(B5 と共通) | 6 つの保存先の合算、`deleteAllData(forBookIDs:)` が 6 つすべてから消すこと(段階 4 の `deleteAllFavorites` と同じ性質の経路) |
| B4 | `AppState.open(request:)` | `openTask` を `private(set)` にして待てるように | `isPrivateWindow` のコメントに列挙された「何を書かないか」の契約(reconcile × 4・backfill・履歴・`cachesPageList`)、`recordsInHistory`、上限超過、失敗時 |
| B5 | `RecentFilesStore` / `FolderAccessStore` | `init(defaults:)` | 旧形式からの移行・パスでの重複除去・上限・「`entries` が空でも保存済みを消す」、`add(url:)` の祖先/子孫の整理と `isAncestor` の区切り単位の比較 |
| C1 | `ViewerView` の表示倍率とスロット | `slots(forOrderedImages:)` / `referenceHeight` / `displayWidth` / `totalContentSize` / `renderScale` / `scrollContentSize` を `CGSize` を受ける `nonisolated enum` へ | 4 つの表示モードの倍率(`fitWidthSplit` の分割判定・`maxUpscale`)、空白スロットの挿入 |
| C2 | `ProgressBarView` | `visibleRange` / `pageIndex(atX:)` / `highlightSlot` を純粋関数へ | RTL の反転、端での詰め |
| C3 | `BulkRenameBookmarksSheet` | `previewNames` と `applyRenaming` に二重実装されている命名規則を 1 つの関数に | 表紙・最後の除外 → 連番 → `pageIndex` 順。プレビューと結果のずれ |
| C4 | `QooViewerApp` のストア復旧 | `removeOrphanedAuxiliaryStoreFiles` を internal に、`performPendingStoreResetIfNeeded` に `(defaults:storeURL:cacheDirectories:)` | 本体が無いときだけ `-wal`/`-shm` を消すこと、全削除で `FolderAccessStore.defaultsKey` だけ戻ること |
| C5 | `ThumbnailDiskCache` / `BookPageListCache` | `init(directory:)` | 刈り込み、OFF で消えること、`store` → 読み直しの往復、ページ寸法の指紋照合 |

**変更しなくても書ける(単に無い)テスト**(→ **段階 6 ですべて実装した**。下の「段階 6」参照):
`ResourceAnomalyDetector.evaluate`、
`TitleAuthorFilenameParser`、`ContentFingerprint`、`LibraryDataPruner`、`StorageUsageScanner`、
`ImageExporter`、`PagePixelBuffer`、`ResourceHistory`、`PageLoader`(`usesThumbnailDiskCache: false`。
テストからの参照は 2 か所だけ)、`FavoritesStore` の上限と `move(folder:to:)` の循環禁止、
`BookmarkStore.resolveKeys` / `updatePageIndices` / `renameBookmarks`、`LayoutStore` の
`setPageOrderOverride` / `checkContentReplacement` / `discardLayoutData`、`MetadataEditorViewModel`
(依存 6 つすべて `InMemoryLibrary` にある)、`LaunchCoordinator.openAppState(forBookAt:isPrivate:)`、
`BookExportRowFilter`、`RGBColorValue(hexString:)`、`WelcomeQuickOpenColumn.resolved`、
`LayoutPropagationScope` の利用可否(`ViewerView` と `BookmarkListView` に二重実装 ―― まとめる価値あり)。

このうち 2 つは、実際には**アプリ側に手を入れないと書けなかった** ―― `WelcomeQuickOpenColumn` /
`WelcomeQuickOpenWidth` は `WelcomeView.swift` の中で `private` だったこと、`LayoutPropagationScope` の
利用可否は 2 つの View の `private func` に閉じていたこと。どちらも段階 5 と同じ作法で開けた
(下の「段階 6」)。

**実機に残すもの**: `QooViewerApp.performExternalOpen` / `BookWindowOpener`(タブ化・配置・状態復元)、
`MenuBarMenuGate` と `FocusedValue` 経由のメニュー状態、`ViewerView` のイベントモニタ・クロームの
自動非表示・ルーペ、すりガラスの面の文字の縁取り。

**A2 でできたもの(2026-09-06、361 → 378 テスト)**
`AppPreferences.init(defaults: UserDefaults = .standard)`。`UserDefaults.standard` の直接参照 91 か所を
保存先のプロパティへ替え、`static` の補助(すりガラスの面・書き出しの形式ごと)には `defaults:` を
足した。テストは `Support/PreferencesSuite.swift`(その場限りの suite)と
`Support/AppPreferencesProbe.swift`(Mirror での総なめと下ごしらえ)、`AppPreferencesTests`。
suite の中身は [02](02-project-and-build.md#テストターゲットqooviewertests)。

計画から変えたのは 1 点 ―― **`AppleLanguages` は「呼ばない」ではなく `defaults` へ流す**ことにした。
渡された suite の中で完結するので実物のアプリには効かず、書かれたことをテストから見られる。
保存先の外へ出ていくもの(`ThumbnailDiskCache.shared`・`NSApp.appearance`・
`.pageOrderSettingDidChange` / `.recentFilesLimitDidChange` の 2 つの通知)だけを
`sharesGlobalState`(= `defaults === .standard`)で止める。通知を足したのは計画に無かったぶん
(受け手が実物の保存先を読み直して切り詰めるため)。

**A2 で分かったこと**
- **「初期設定に戻す」の網羅は、保存先を見るだけでは確かめられない。** `keys(for:)` に無く
  `apply(_:for:)` にある設定(= ユーザー報告「文字の影だけリセットされない」の形)は、`apply` が
  渡す `AppPreferences()` が**消し忘れたキーの古い値を読み直す**ので、画面の値も保存先も
  「戻っていない」で一致してしまう。テスト側に**画面ごとの担当表**を別に持ち、戻った後の値を
  出荷時の既定値(空の suite から作ったインスタンス)と突き合わせる形にした。抜けを入れて
  実際に落ちること(`panelSurfaceContentShadowLevel` と `filmstripFontSize` を `keys(for:)` から
  外す)まで確かめてある。
- **`@Published` は Mirror で総なめにできる。** `_x: Published<T>` の `storage` が
  `.value(T)` の列挙になっている(`$x` を購読すると `.publisher` へ移るので、テストは購読しない)。
  設定を 1 つ足したときに、テスト側の書き写しが古いまま静かに素通りするのを防げる。
  辞書の `description` は順序が変わるので、要素を並べ替えてから文字列にすること。
- `Binding.wrappedValue` を使うテストのヘルパーには `import SwiftUI` が要る
  (`MemberImportVisibility` が有効なので、`@testable import` だけでは見えない)。

**A1 でできたもの(2026-09-06、378 → 391 テスト)**
`Models/SpreadPairing.swift`(`nonisolated enum SpreadPairing` / `enum PageLanding`)。
`ViewerViewModel` の 5 か所へ同じ形で書かれていた「隣り合う 2 ページが組になるか」の規則を
`explicitPairing(first:second:readingDirection:)` 1 つにまとめ、`shouldPairWithNextPage` /
`backwardStepSize` / `forwardStepSize` / `spreadPairStillDisplayable` / `normalizedAnchorIndex` は
そこを呼ぶだけにした。`fallbackIndex` と数字キーのジャンプは `PageLanding` へ。テストは
`SpreadPairingTests`(表引き)。規則の説明は [07](07-page-order-layout-bookmarks.md#見開きの組み方spreadpairing)。

**A1 で分かったこと**
- **画像の横長判定は閉包で渡す。** 本体(`isWideImage`)は判定結果をキャッシュへ書き込む
  副作用を持つので、`Bool` を渡す形にすると「明示指定で結論が出たら評価しない」という
  順序が崩れる。テストは呼ばれたかどうかを見ている。
- `nonisolated` な型から `DisplayMode` / `ReadingDirection` / `PageSpreadPosition` を
  引数に取るのは、既定分離が `MainActor` でもそのまま通る(列挙のケースと合成された
  `Equatable` は分離されない)。`ReadingDirection` などを `nonisolated` にする必要は無かった。

**A3 でできたもの(2026-09-06、391 → 405 テスト)**
`ViewerViewModel` に口を 2 つ ―― `usesDiskCaches: Bool? = nil`(既定 `!skipsPersistence`。
`PageLoader(usesThumbnailDiskCache:)` へ渡る。サムネイルとページ寸法の両方がこの 1 つで
決まる)と `settle()`(起動時に投げた Task・ページ送り・再読込を待ち合わせる)。テストは
`Support/ViewerHarness.swift` と `ViewerViewModelTests`。

**A3 で分かったこと**
- **待ち合わせの終わりは「Task が無い」では判定できない。** `reloadTask` は終わっても nil に
  戻らない(「前のを止める」ためだけのハンドル)ので、`settle()` は表示の世代
  (`loadGeneration`)が進んだかどうかで見る。`Task` は構造体なので `===` で同一性を比べられない。
- `hasSavedReadingState` は private のままにした。「初めて開く本として扱われたか」は
  保存された行(`lastPageIndex` が作りたての 0)と `needsResumeConfirmation` から見えるので、
  テストのために可視性を上げる必要は無かった ―― **口は必要なものだけ開ける**。
- ビューアのテストは実際に画像をデコードするので、suite 全体の時間は 2.6 秒のまま
  (並行して走る)だが、単独で回すと 0.3 秒ぶんそこに乗る。

**A4 でできたもの(2026-09-06、405 → 415 テスト)**
`KeyBindingStore.init(defaults:)` と、純粋な 2 つ(`fillingMissingDefaults` /
`migratedLegacyMouseBindings`)を private から internal へ。テストは `KeyBindingStoreTests`。
`fillingMissingDefaults` は `nonisolated` にできたが、`migratedLegacyMouseBindings` は
`MouseTrigger.id`(メインアクター分離)を引くので internal どまり ―― **必要なぶんだけ開ける**。

**B1 でできたもの(2026-09-06、415 → 423 テスト)**
`BookLayoutEditorViewModel.load(book:usesDiskCaches:)`(読み込み済みの本から行を組む)。
通常の `load()` は `BookPageListCache.shared` を読み、その先の `BookLoader.load(from:)` は
既定でそこへ書き戻すため、テストからは実物のキャッシュに触れずに行を用意できなかった。
テストは `BookLayoutEditorTests`。

**B1 で分かったこと**
- **読み方向が絡むテストは、必ず本ごとの上書きで明示する。** 既定はシステムの言語から決まる
  (手元は右開き・CI は左開き)ので、見開き左右の期待値がそのままでは環境で食い違う。
- ストア(`BookmarkStore`)は自分のキャッシュを持つので、テストの下ごしらえも
  `modelContext.insert` ではなく**ストアの API を通す**こと。直接入れた行は
  `updatePageIndices` の対象にならない。

**B3 でできたもの(2026-09-06、423 → 428 テスト)**
`FolderAccessStore.init(defaults:)`、`BookmarkStore.releaseResources()` /
`FavoritesStore.releaseResources()`(張った購読を外す)、`InMemoryLibrary.close()`。
テストは `LibraryCleanupTests`。

**B3 で分かったこと**
- **テスト用のストアは、他のテストの通知で目を覚ます。** `.bookmarksDidChange` は
  `NotificationCenter.default` へのアプリ全体の放送なので、**捨てられている最中の**
  メモリ内ライブラリのストアがこれで `reload()` を始め、解放されかけた保存先へフェッチして
  **テストホストが落ちた**(SwiftData の中で EXC_BREAKPOINT。並行して 5 つのライブラリを
  作っては捨てるテストで再現し、ライブラリを生かしたままにすると再現しなくなることで確認)。
  `BookmarkStore` は deinit で購読を外しているが**間に合わない** ―― 解放がメインスレッド
  以外で始まると、メインキューでの通知の処理と重なる。`close()` で、コンテナが解放される
  より前に、メインアクターの上で外す。
- お気に入りの登録は**実体のあるファイル**でないと失敗する
  (`FavoritesStore.makeBookmarkData` がセキュリティスコープ付きブックマークを作れない)。
  `bookID` だけの本ではテストにならない。

**B2 でできたもの(2026-09-06、428 → 435 テスト)**
`BookExportViewModel.exportOne` を `prepare(row:book:displayState:)`(材料集め)と
`write(_:to:)`(一時ファイル → 置き換え)へ分けた。`exportOne` はこの 2 つを呼ぶだけ。
テストは `BookExportViewModelTests`(書き込みはサブクラスの `export` で差し替える)。

**B2 で分かったこと**
- 「いま開いている本の表示状態」は private の格納プロパティだったので、`prepare` の**引数**に
  した。可視性を上げるより、値を渡す形にするほうが素直で、優先順位もその場で読める。
- 同名ファイルの確認は `resolveOverwrite(_:applyToRemaining: true)` を**先に**呼んでおけば、
  待ち合わせ(継続)を作らずに素通りする。時間で待つ形を避けられる。

**B4 でできたもの(2026-09-06、435 → 441 テスト)**
`AppState.openTask` を `private(set)` に(テストが `await openTask?.value` で待てるように)、
`AppState.init(isPrivateWindow:usesPageListCache:)`(既定 true)。あわせて
`RecentFilesStore.init(defaults:)`(B5 と共通の口)。テストは `AppStateOpenTests`。

**B4 で分かったこと**
- 完了の反映は `MenuBarMenuGate.shared.run` を通るが、メニューを追跡していなければ**その場で
  走る**ので、テストからは `openTask` を待つだけでよい。
- 画像の枚数の上限は、読み込みを始める前に弾く(`openTask` は作られない)。テストも
  実在しないパスを並べるだけで通せる ―― 上限の判定はパスの数しか見ない。

**B5 でできたもの(2026-09-06、441 → 450 テスト)**
`RecentFilesStore.init(defaults:)`(B4 で入れたもの)と `FolderAccessStore.init(defaults:)`
(B3 で入れたもの)に対するテスト ―― `RecentFilesAndAccessTests`。アプリ側の新しい口は無い。

**B5 で分かったこと**
- **`standardizedFileURL` は先頭の `/private` を「実在するときだけ」外す**
  (`NSString.standardizingPath` の仕様)。`FolderAccessStore.isAncestor` がこれで比較していた
  ため、許可済みフォルダ(実在 → `/var/…`)と**見つからない本**のパス(実在しない →
  `/private/var/…`)が食い違い、配下にあるのに「覆われていない」と判定されていた。この判定は
  `LibraryCleanupViewModel` が見つからない本に対しても行うので実際に効く経路。先頭の `private`
  を必ず外して揃える形に直した(`normalizedComponents`)。**手元では素通りする** ―― サンドボックスの
  コンテナ配下には `/private` が出ないため。CI(サンドボックス無し、作業フォルダが
  `/private/var/folders/…`)で落ちて分かった。テストは**実在しないファイル**で確かめること。
- `RecentFilesStore` は `init` で非同期の再検証(`scheduleRefresh`)を投げるが、実体のある
  ファイルを記録するぶんには結果が変わらないので、待ち合わせの口は要らなかった。旧形式からの
  移行(パスの穴埋め)だけはこの再検証が担うため、そこは「一覧が空でも保存済みは消える」
  という形で確かめている。
- セキュリティスコープ付きブックマークは、テストホスト(サンドボックスあり)でも
  **コンテナの中のファイル/フォルダ**なら作れる。お気に入り・履歴・アクセス権のテストは
  作業フォルダの中で完結する。

**C1 でできたもの(2026-09-06、450 → 460 テスト)**
`Models/PageAreaLayout.swift`(`nonisolated enum`)。`ViewerView` の private な幾何の計算
(`slots(forOrderedImages:)` / `referenceHeight` / `displayWidth` / `referenceAspectRatio` /
`totalContentSize` / `renderScale` / `scrollContentSize`)を、**画像ではなく寸法(`CGSize`)**を
受ける形で出した。`ViewerView` 側の同名の関数は `SpreadPageSlot.layoutSlot` で写して呼ぶだけ。
テストは `PageAreaLayoutTests`。

**C1 で分かったこと**
- 空白スロットの挿入は「何番目の実画像か / 空白か」の列(`Placement`)として出せる ――
  画像そのものを持ち込まずに規則だけを取り出せた。

**C2 でできたもの(2026-09-06、460 → 466 テスト)**
`Models/FilmstripLayout.swift`(`nonisolated enum`)。`ProgressBarView` の
`pageIndex(atX:width:)` / `highlightSlot(atX:width:)` / `visibleRange(centeredOn:slot:)` を
移した。テストは `FilmstripLayoutTests`。**読み方向の反転はページ番号にだけ効き、
スロット(画面上の位置)には効かない** ―― この非対称が要で、表引きで固定した。

**C3 でできたもの(2026-09-06、466 → 473 テスト)**
`Models/BulkBookmarkRenaming.swift`(`nonisolated enum`)。`BulkRenameBookmarksSheet` の
`previewNames` と `applyRenaming` に**二重に書かれていた**命名規則を 1 つにまとめ、両方から
呼ぶようにした(プレビューと結果がずれる余地を無くす)。画面側に残るのは、先頭ページに
ブックマークが無いときの自動追加(DB への書き込み)と、翻訳の解決だけ。
テストは `BulkBookmarkRenamingTests`。

**C4 でできたもの(2026-09-06、473 → 478 テスト)**
`QooViewerApp.removeOrphanedAuxiliaryStoreFiles(at:)` を internal に、
`performPendingStoreResetIfNeeded` に 4 つの引数(`defaults` / `storeURL` / `domainName` /
`cacheDirectories`。既定はどれも実際のアプリのもの)。テストは `StoreRecoveryTests`。
**この処理は実物のストア・キャッシュ・環境設定を消す**ので、テストは必ず作業フォルダと
その場限りの suite を渡す。

**C5 でできたもの(2026-09-06、478 → 487 テスト)**
`ThumbnailDiskCache.init(directory:)` / `BookPageListCache.init(directory:)`(`shared` の
`private init()` は既定の保存先を作る形のまま)、`ThumbnailDiskCache.trimIfNeeded(in:maxTotalBytes:)`
を internal に。テストは `DiskCacheTests`。

**C5 で分かったこと**
- 設定 OFF での**ディレクトリごとの削除**は `Task.detached` の投げっぱなしなので、完了を待つ口が
  無い。テストで固定できたのは「OFF のあいだは書きも読みもしない」ところまで。刈り込みは
  `trimIfNeeded` を直接呼んで確かめる ―― `store` 経由では 1MB 書かないと発火しない
  (`trimThreshold` の下限)。

**口を開けるときの作法**: 既定値はこれまでどおり(通常経路の差分ゼロ)。時間で待たず `Task` の
ハンドルを `await` する。既定引数にメインアクター分離の型を置かない(段階 3・4 で 2 度踏んだ。
`QOO_CI_WARNINGS_AS_ERRORS=YES` で通してから push)。静的な登録簿(`ViewerViewModel.openBookIDs`、
`MenuBarMenuGate.shared`、`UserDefaults(suiteName:)`)は後始末する。

### 段階 6 ―― 「変更しなくても書けるテスト」を消化する(2026-09-06。487 → 712 テスト)

段階 5 の表の下に残していた 15 項目をすべて実装した。suite の一覧は
[02](02-project-and-build.md#テストターゲットqooviewertests)。

**アプリ側に開けた口は 2 つだけ**(どちらも既定の挙動は変わらない):

| 口 | 何のため |
| --- | --- |
| `WelcomeQuickOpenItem` / `WelcomeQuickOpenColumn` / `WelcomeQuickOpenWidth` の `private` を外す(`minColumn` などの定数も) | ウェルカム画面の列幅の計算をテストから呼ぶため。使うのは今も `WelcomeView.swift` の中だけ |
| `MetadataEditorViewModel.releaseResources()` | 張った 3 つの通知の購読を deinit を待たずに外す(下の「分かったこと」) |

**まとめた重複が 1 つ**: 伝播範囲の選択肢の絞り込みが `ViewerView.availableScopes(forPageIndex:)` と
`BookmarkListView.availableScopes(forPageKey:)` に二重に書かれていたのを、
`LayoutPropagationScope.available(forIndex:lastIndex:)` へ寄せた。違うのは「どの空間の位置で
見るか」だけ(ビューアはページ番号、編集ウインドウは除外ページを除いた読書順)なので、位置は
呼び出し側が解決して渡す。両方の View に残っているのは、その解決だけを行う薄い包み。

**段階 6 で分かったこと(実測)**

- **`UTType(filenameExtension:)` は知らない拡張子に対しても nil を返さない。** `dyn.…` という
  動的な UTI を作って返すので、`ImageExporter.contentType(forExtension:)` にあった
  「解決できなければ JPEG へフォールバック」(`?? .jpeg`)は**一度も効いていなかった**。
  「書けるか」は `CGImageDestinationCopyTypeIdentifiers()` に照らし、動的な UTI も弾いて判定する
  (`ImageExporter.canWrite(fileExtension:)`)。
- **見開きの結合が webp のページだと必ず失敗していた(同日に修正)。** 結合後の形式は「読み順で先の
  ページ」に揃えるが、ページとして開ける拡張子(`imageExtensions`)のうち **webp だけは ImageIO に
  エンコーダが無い**(`CGImageDestinationCopyTypeIdentifiers()` に含まれない。他の 9 つ
  ―― jpg/jpeg/png/gif/bmp/heic/tif/tiff/avif ―― はすべて書ける)。そのため webp の本で
  「見開きを結合してエクスポート」を選ぶと `.combineFailed`(「結合した画像を作れませんでした」)
  になっていた。**書けない形式は PNG(可逆)へ倒す**ようにした ―― `EpubExporter` が EPUB へ
  素通しできない形式を PNG へ変換するのと同じ考え方で、どのみち結合は再エンコードが避けられない
  以上、可逆形式なら画質を落とさない。
  倒す場所は **`mergedFileExtension` の 1 箇所だけ**。保存パネルに出す名前・`allowedContentTypes`・
  実際のエンコードの 3 つがすべてそこから決まるので、「中身は PNG なのに名前は `.webp`」が
  起きない。`combine` 自身は書けない形式を渡されたら黙って倒さず失敗させる(倒すとその食い違いが
  起きるため)。単一ページの書き出しは**生データの複製**なので対象外 ―― webp のページは webp の
  まま保存できる。回帰テストは `ImageExporterTests`
  (`everySupportedPageFormatCanBeExportedAsASpread` / `aWebPSpreadIsExportedAsPNG`)。
- **Swift の `String` の `==` は正規等価で比べる。** NFD の「が」と NFC の「が」は文字列としては
  等しいので、NFC 正規化のテストは `unicodeScalars` の列で見る。`URL(fileURLWithPath:)` を通すと
  Foundation がその場で NFC へ直してしまうため、正規化の経路を試せるのは**書庫の中のエントリ名**
  (ただの `String`)だけ。
- **通知を購読する ViewModel も `releaseResources()` が要る。** `MetadataEditorViewModel` は
  `bookmarksDidChange` / `layoutDataDidChange` / `bookMetadataDidChange` を購読しており、
  テストがこれを作っては捨てると、**別のテストが投げた通知で目を覚まし、捨てられている最中の
  `ModelContainer` へ `collectKnownBookIDs()` がフェッチしに行って SwiftData がトラップする**
  (クラッシュレポートで確認。`EXC_BREAKPOINT`、スタックは
  `NSNotificationCenter post` → `MetadataEditorViewModel.reload` → SwiftData)。
  `InMemoryLibrary.close()` と同じ話で、`deinit` では間に合わない。
  **通知を購読する型をテストから作るときは、必ず購読を外す口を用意すること。**
- **`FavoritesStore` / `BookmarkStore` の一覧の並びは `UserDefaults.standard` の並び順設定に従う。**
  `sortOption` の `didSet` は `.standard` へ書き戻すので、テストから設定し直すと利用者の設定を
  書き換えてしまう。一覧の**並び**は当てにせず、顔ぶれ(`Set`)で見る。
- **`AppPreferences.isPrivateModeDefault` も `.standard` を読む。** `AppState.actsAsRegularWindow` が
  これを見るので、シークレットウインドウが絡む判定は環境で変わる。`LaunchCoordinatorTests` は
  `openAppState(forBookID:)` を通常ウインドウでだけ試している。
- **`#expect` の中の配列リテラル同士の `==` は曖昧になることがある。** 片方を `let widths: [Int] = …` と
  型注釈付きの変数へ出せば通る。

### 段階 7 ―― 計画に無かった未カバーを拾う(2026-09-06。712 → 758 テスト)

段階 6 で計画ぶんを消化したあと、`Services/` `ViewModels/` `Models/` の全ファイルを「その型の名前が
テストのどこにも出てこないか」で機械的に洗った。設定の enum のように `AppPreferencesTests` が
Mirror で間接的に押さえているものを除くと、**段階 5 の項目表に最初から入っていなかった**
未カバーが 5 つ残っていた。効き目の順に上 3 つを実装した。

| # | 対象 | 開けた口 | 載せた検証 |
| --- | --- | --- | --- |
| 1 | `BookURLResolver` | 不要(`static`・`nonisolated`) | 3 つのストアへの問い合わせの連鎖を写したものなので、**優先順位と素のパスへのフォールバックがどの段階で効くか**。特に「メタデータ側の候補は素のパスが実在しない本にしか効かない」という、読み流すと気付かない分岐 |
| 2 | `LastUsedFolderMemory` / `LastActiveBookStore` | `init(defaults:)` / 3 つの関数の `defaults:`(既定 `.standard`) | 保存されるのが**パスの文字列ではなくブックマーク**であること(サンドボックスでは次の起動でパスへアクセスできない)、表示用のパスを別のキーへ控えること、忘れると 2 つとも消えること、記録した本が消えていたら復元しないこと |
| 3 | `SidePanelBrowserState` | `reloadTask` を `private(set)` に(`AppState.openTask` と同じ口) | 履歴スタックと上へ移動、本を開いたときの再アンカー(画像を直接開いた本だけもう 1 階層上)、パネル内クリックの見送り、読み込みの結果(一覧・「直下に画像があるか」・アクセス権が要るかを空フォルダと区別すること)、ディスクを読み直さない並べ替え |

**残した 2 つ**(どちらも先に仕様の判断が要るとして送った。→ **段階 8 で実装した**):

- `SecurityScopedHandoff` ―― 10 秒で解放する受け渡し。**時間で待つテストは書けない**(段階 2 の
  教訓)ので、期限を注入できる口を先に決める必要がある。
- `CbzExportViewModel` / `EpubExportViewModel` / `PDFExportViewModel` ―― 基底の
  `BookExportViewModel` は `BookExportViewModelTests` で押さえてある。形式ごとの薄い差分だけが
  未カバーで、`prepare`/`write` の分離をサブクラス側にも広げるかどうかから決まる。

**段階 7 で分かったこと(実測)**

- **`URL` の `==` は末尾の `/` を区別する。** `deletingLastPathComponent()` が返す親フォルダは
  末尾に `/` が付くが、`appendingPathComponent(_:)`(`isDirectory` を指定しない形)で作った
  URL には付かない。同じ場所を指していても等しくならないので、フィクスチャのフォルダは
  `isDirectory: true` で作るか、`path` で比べる。
- **画像を「フォルダとして開く」と `.fileSystem`、「ファイルとして開く」と `.imageFiles`。**
  `MangaBook.origin` はこの 2 つで変わり、フォルダブラウザの再アンカー先(親か、もう 1 階層上か)も
  そこで分岐する。画像の並んだフォルダを `BookLoader.load(from:)` で開いても `.imageFiles` には
  ならない ―― その本を作るのは `BookLoader.load(imageFiles:)` だけ。

### 段階 8 ―― 先送りにした 2 つを片付ける(2026-09-06。758 → 773 テスト)

段階 7 で「先に仕様の判断が要る」として送った 2 つを、判断のうえ実装した。

| # | 対象 | 判断 | 載せた検証 |
| --- | --- | --- | --- |
| 1 | `SecurityScopedHandoff` | 猶予を引数(`releaseAfter:`、既定は従来どおり 10 秒)にし、解放の Task を `@discardableResult` で返す。返す値は**実際に閉じた URL** | 開けた URL だけを**1 本の**Task がまとめて閉じること(URL 1 つにつき Task 1 本を作らないこと)、開けなかった URL には手を出さないこと、渡す URL が無ければ Task を作らないこと、猶予がウインドウの出現待ち(0.5 秒)よりずっと長いこと |
| 2 | `CbzExportViewModel` / `EpubExportViewModel` / `PDFExportViewModel` | サブクラス側は分けない。`prepare` → `write` の往復で**実物を書き出して読み直す**(詰め替えをスタブで受け止めると、間違えてもテストが通る) | どの Exporter が呼ばれるか(拡張子・その形式として開き直せること)、オプションが出力まで届くこと(除外ページ・CBZ の `Volume`・言語)、巻数の書き方の違い、カバーの上書きが PDF には渡らないこと、開いた直後のオプションが環境設定の既定から始まること |

**段階 8 で分かったこと(実測)**

- **スコープを開けるかどうかは、サンドボックスの有無で変わる**(CI で 1 回落として分かった)。
  手元(署名あり = サンドボックスの中)では素の file URL は
  `startAccessingSecurityScopedResource()` が false を返し、その場でセキュリティスコープ付き
  ブックマークを作って解決し直した URL だけが true を返す。**サンドボックスの外(CI は署名無し)
  では素の file URL でも true が返る** ―― 消費するサンドボックスが無いため。期待値を
  「素の URL は対象から外れる」と決め打ちにすると CI でだけ落ちるので、**その環境に聞いてから
  組む**(`opensScope` で開ける URL を選び出す)。「環境で変わる既定値は明示する」の新しい例。
- **開けたスコープが閉じたかどうかを外から読む API は無い。** そこで `begin` の返す Task の値を
  「実際に閉じた URL」にした。テストはそれを見て収支を確かめる。
- **`#require` は入れ子にできない**(マクロの再帰展開になってコンパイルが通らない)。
  `try #require(f(try #require(g())))` は 1 つずつ `let` へ解く。
- **`struct` の `init` で、プロパティを初期化し終える前にクロージャへ `self` の値を渡せない**
  (`plain = try (0..<n).map { temp.file(…) }` は「初期化前に捕まえた」で止まる)。先にローカルへ
  作ってから代入する。
- **`ComicInfo` の `Number` は xs:string、`Volume` は xs:int。** だから CBZ だけが生の
  `seriesIndex` を渡し(「上」もそのまま `Number` に書ける)、EPUB / PDF は
  `exportableSeriesIndex`(数値として読めるときだけ)を渡す ―― この違いを出力の側から固定できた。
  `Volume` に書く指定でも、数値でなければ入らない。

### 引き継ぎ(2026-09-06 時点)

**いまの状態**: `qooViewerTests` は 773 テスト・77 suite(手元で約 10 秒)。段階 0〜8 はすべて
実装済みで、CI(Build の Debug / Release と Check)は緑。suite ごとの中身は
[02](02-project-and-build.md#テストターゲットqooviewertests)。

**アプリ側に開けた口(段階 5)**。どれも既定値はこれまでどおりで、通常経路の差分はゼロ:

| 口 | 何のため |
| --- | --- |
| `AppPreferences.init(defaults:)` / `KeyBindingStore.init(defaults:)` / `FolderAccessStore.init(defaults:)` / `RecentFilesStore.init(defaults:)` | `UserDefaults` の保存先をその場限りの suite へ |
| `ThumbnailDiskCache.init(directory:)` / `BookPageListCache.init(directory:)` | ディスクキャッシュの保存先を作業フォルダへ |
| `ViewerViewModel(usesDiskCaches:)` / `AppState(usesPageListCache:)` / `BookLayoutEditorViewModel.load(book:usesDiskCaches:)` | DB へは書くがディスクキャッシュには触れない、を表す |
| `ViewerViewModel.settle()` / `AppState.openTask`(`private(set)`) | 起動時に投げた `Task` を待ち合わせる |
| `BookmarkStore.releaseResources()` / `FavoritesStore.releaseResources()` | 張った購読を外す(下の「必ず守ること」参照) |
| `BookExportViewModel.prepare(row:book:displayState:)` / `write(_:to:)` | 材料集めと書き込みを分ける |
| `QooViewerApp.performPendingStoreResetIfNeeded(defaults:storeURL:domainName:cacheDirectories:)` / `removeOrphanedAuxiliaryStoreFiles(at:)` | 実物のストア・キャッシュ・環境設定を消さずに確かめる |
| `MetadataEditorViewModel.releaseResources()`(段階 6) | 張った通知の購読を deinit を待たずに外す |
| `WelcomeQuickOpenColumn` / `WelcomeQuickOpenWidth` から `private` を外す(段階 6) | ウェルカム画面の列幅の計算を呼べるようにする |
| `LastUsedFolderMemory.init(defaults:)` / `LastActiveBookStore` の `defaults:`(段階 7) | ブックマークで覚えた場所の保存先を、その場限りの suite へ |
| `SidePanelBrowserState.reloadTask`(`private(set)`、段階 7) | フォルダ一覧の読み込みを待ち合わせる |
| `SecurityScopedHandoff.begin(_:releaseAfter:)` が解放の `Task` を返す(`@discardableResult`、段階 8) | 10 秒の猶予を差し替え、解放し終えた合図を処理そのものから受け取る |

純粋型へ出したのは `SpreadPairing` / `PageLanding` / `PageAreaLayout` / `FilmstripLayout` /
`BulkBookmarkRenaming`(いずれも `Models/`、`nonisolated`)。段階 6 では
`LayoutPropagationScope.available(forIndex:lastIndex:)` を足した(2 つの View の二重実装をまとめたもの)。
画面や ViewModel 側は、そこを呼ぶだけの薄い包みとして残してある。

**テストの土台**(`qooViewerTests/Support/`): `Fixtures` / `FixtureBook`(台帳付きの本)、
`FixtureFolder` ほかのビルダー、`TemporaryDirectory`(作業フォルダ)、`InMemoryLibrary`(メモリ内の
SwiftData + 5 つのストア)、`PreferencesSuite`(その場限りの `UserDefaults`)、
`AppPreferencesProbe`(Mirror での総なめ)、`ViewerHarness`(本を開く一式)、`ExportHarness`。

**必ず守ること**(どれも実際に踏んだもの):

- **共有の保存先に触れない。** `UserDefaults.standard` / `*.shared` のキャッシュ /
  `QooViewerApp.modelContainer.mainContext` は不可。上の口を使う。
- **`InMemoryLibrary` は `defer { library.close() }`。** 外さないと、捨てられている最中のストアが
  他のテストの `.bookmarksDidChange` で目を覚まし、テストホストごと落ちる(B3 参照)。
- **時間で待たない。** `settle()` / `await openTask?.value` のように、合図は処理そのものから出す
  (段階 2 参照)。
- **環境で変わる既定値は明示する。** 読み方向の既定はシステムの言語から決まる(手元は右開き、
  CI は左開き)。見開き左右が絡むテストは本ごとの上書きで固定する(B1 参照)。
- **パスは実在の有無で形が変わる。** `standardizedFileURL` は先頭の `/private` を実在するときだけ
  外す。手元(サンドボックスのコンテナ配下)では出ない食い違いが CI で出る(B5 参照)。
- **push する前に `QOO_CI_WARNINGS_AS_ERRORS=YES` で通す。** 手元では警告どまりのものが CI では
  エラーになる(段階 3・4 参照)。`scripts/ci/check-all.sh` も同じく push 前に。

**残っている作業**:

1. **「実機に残すもの」**(ウインドウの生成・タブ化・状態復元、メニューの状態、`ViewerView` の
   イベントモニタ・クロームの自動非表示・ルーペ、すりガラスの面の文字の縁取り、
   `LaunchCoordinator.frontmostContentAppState`)。意図的に CI へ載せない ―― 確かめ方は
   [12](12-verification-and-debugging.md)。
2. **固定できないと分かっているもの**: `ImageDecoder.hasAcceptablePixelCount`(200KB の
   フィクスチャ上限内で「ヘッダーだけ巨大」な画像が作れない。段階 2 参照)、
   `StorageUsageScanner` の中断パス、`ProcessResourceSampler` 本体(Timer + RunLoop)。
   7z のアクセス順(ブロック先頭からのやり直し回数)は qooViewerTests ではなく
   フォーク側の実測ハーネスの担当。

段階 0〜8 で計画していたぶんは、これで打ち止め。次に足すとしたら、テストの無い経路を
新しく見つけたときか、利用者報告の回帰を固定するとき。

## 古くなった記述・ファイル(2026-09-05 に整理済み)

- `CLAUDE.md` の UniversalCharsetDetection と「SevenZip.swift は main を追跡」の記述は修正した。
- 中身が空だった `Models/BookmarkSortOption.swift` は削除した(`FavoritesSortOption` を流用している。
  プロジェクトはファイルシステム同期グループなので pbxproj の変更は不要)。
- `FavoritesNSMenuBridge` のコメントが「参考として残してある」としていた
  `FavoritesListPopoverContent.swift` は既に存在しないため、コメントを「削除済み」に改めた。
- コードのコメントが参照する「設計コンセプト n 節」「実装検討ドキュメント」「favorites_feature_
  assessment.md」「Task #82」は、リポジトリに入っていない過去の設計文書・作業記録への参照。
  内容は本仕様書 [07](07-page-order-layout-bookmarks.md) 等に復元してある。
- `BookLayoutSettings.hasEpubLayoutLock` は未使用の永続化属性(スキーマ変更を避けて意図的に残置)。
