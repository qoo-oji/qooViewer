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

### テストのパタンセット ―― 段階 4(引き継ぎ、2026-09-06)

`qooViewerTests` を「UI を伴わない nonisolated のパイプライン」まで広げる計画(段階 0〜4)のうち、
**段階 0(フィクスチャ・台帳・生成スクリプト・Support のビルダー・golden テスト)・
段階 1(読み込み側)・段階 2(純粋ロジック)・段階 3(書き出しのラウンドトリップ + CI の検品)は完了**
(→ [02](02-project-and-build.md#テストのフィクスチャ))。
決めごとは段階 0 と同じ ―― 共有の保存先に触れない、golden は `sortKey` の列、既知の限界は
「落ちない・数は合う」で固定、テスト全体で 60 秒以内(現状 335 テスト・約 1.9 秒)。

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
- 書き出した EPUB 14 本は EPUBCheck 5.3.0 で指摘ゼロ、ComicInfo.xml 8 本は v2.0 の XSD に適合
  (2026-09-06、手元で実測。java は Kindle Previewer 3 同梱の JRE を使った →
  [12](12-verification-and-debugging.md))。
- EPUB の本の `sortKey` は spine 上の位置(6 桁連番)で、エントリのパスは `id` に入る
  (フォルダ = 絶対パス、書庫 = エントリパス、とは違う)。書き出した EPUB を開き直して
  突き合わせるときはここを間違えやすい。

**残っているもの**

**段階 4(任意)** ―― メモリ内の `ModelContainer`(`isStoredInMemoryOnly`)を**テストが自前で作って**
`LibraryImportExportService.apply` と `LayoutStore.importSourceLayoutIfNeeded` を通す。アプリの
`mainContext` には触れない。

**段階 0 で分かったこと**: `FileManager.temporaryDirectory` は `/var → /private/var` の symlink で、
フォルダの本の sortKey は実体パスになる(`TemporaryDirectory` が実体にしてある。アプリでも
symlink 経由のパスで開くと `location(inBookAt:)` の folderPath が nil になる小さな癖がある)。
rar 7.2x は `-ma4` が無く RAR4 を作れない。

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
