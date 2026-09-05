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
| ブックマークの並べ替え | 専用の6種 | お気に入りと同じ3種×昇降 | 編集ウインドウを2ペインへ揃えた |
| 一括リネーム | 独立ウインドウ | 編集ウインドウのシート | bookID の橋渡しとフォールバック画面が不要に |
| 書き出しの出力 | 出力先へ直接 | 一時ファイル → 置き換え | 元の本と同じ場所へ書くと元が消えた |
| PDF の読み方向 | 失われる(警告バナー) | 増分更新で Catalog へ書く | CoreGraphics に API が無いが PDF 自体は書ける |
| 「情報を見る」 | サブメニュー | オーバーレイパネル | 値の先頭が揃わない。`.popover` は外へはみ出す |
| 拡大鏡の結合画像 | 常に作る | 拡大鏡 ON の間だけ | 瞬間的に 1GB |
| 自動削除 | 読書位置と一緒にブックマークも | 読書位置だけ | 手間をかけた情報を勝手に消さない |
| 全削除の範囲 | ストア・キャッシュ・履歴 | アクセス権を除くすべて(終了時に実行) | 環境設定が残る中途半端な範囲だった |

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

## 未着手・「今後の改善課題」と書かれているもの

- `ViewerViewModel.setPageLayout`: 除外を伝播範囲で「解除する」選択肢(設計コンセプト 2.3/3.3 節に
  あった「既存の除外設定を保持しますか/解除しますか」)は未実装で、常に保持する。
- 自動レイアウト(`wideImageAspectRatios`)の進捗表示とキャンセル。ヘッダー読み取りだけになって
  十分速いが、フォーマット非対応でヘッダーが読めない場合の備えとして残っている。
- 差し替え確認ダイアログの3択目「エクスポートしてから破棄する」(2.5 節)。
- `FavoriteBook.sortOrder` / `FavoriteFolder.sortOrder`: 手動ドラッグの並べ替えを再実装する
  場合に備えて値だけ保持している。
- `FavoritesLimits`(999 件・3階層)を環境設定から変えられるようにする案。
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

### 段階 5 ―― GUI 依存の経路を CI へ移す(2026-09-06 点検、着手済み)

段階 0〜4 のあと、「実機でしか確かめられない」と扱ってきた領域を依存関係の側から点検した
(ViewModels / Services / App / Views の全ファイル。点検メモ:
<https://claude.ai/code/artifact/6a10ee64-bc26-4753-bdfc-4eaa1f4ccdb3>)。結論は、**画面の
都合ではなく「共有の保存先に直結している」都合**でテストに載っていないものがかなりあり、
アプリ側に小さな口を開ければ CI へ移せる、というもの。口の作法は段階 4 で開けた 3 つと同じ
(既定値はこれまでどおり・通常経路の差分はゼロ)。

栓は 3 つで、最初の 1 つを抜くと後ろが連鎖的に開く:

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

候補(効き目の順。推奨順は A2 → A1 → A3 → A4 → B1 / B3 → B2 → B4 / B5 → C。A1 は A2 と独立):

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

**変更しなくても書ける(単に無い)テスト**: `ResourceAnomalyDetector.evaluate`、
`TitleAuthorFilenameParser`、`ContentFingerprint`、`LibraryDataPruner`、`StorageUsageScanner`、
`ImageExporter`、`PagePixelBuffer`、`ResourceHistory`、`PageLoader`(`usesThumbnailDiskCache: false`。
テストからの参照は 2 か所だけ)、`FavoritesStore` の上限と `move(folder:to:)` の循環禁止、
`BookmarkStore.resolveKeys` / `updatePageIndices` / `renameBookmarks`、`LayoutStore` の
`setPageOrderOverride` / `checkContentReplacement` / `discardLayoutData`、`MetadataEditorViewModel`
(依存 6 つすべて `InMemoryLibrary` にある)、`LaunchCoordinator.openAppState(forBookAt:isPrivate:)`、
`BookExportRowFilter`、`RGBColorValue(hexString:)`、`WelcomeQuickOpenColumn.resolved`、
`LayoutPropagationScope` の利用可否(`ViewerView` と `BookmarkListView` に二重実装 ―― まとめる価値あり)。

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

**口を開けるときの作法**: 既定値はこれまでどおり(通常経路の差分ゼロ)。時間で待たず `Task` の
ハンドルを `await` する。既定引数にメインアクター分離の型を置かない(段階 3・4 で 2 度踏んだ。
`QOO_CI_WARNINGS_AS_ERRORS=YES` で通してから push)。静的な登録簿(`ViewerViewModel.openBookIDs`、
`MenuBarMenuGate.shared`、`UserDefaults(suiteName:)`)は後始末する。

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
