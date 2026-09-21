# ライブラリ/ファイルブラウザの ON/OFF ―― 抜け漏れのコード監査(2026-09-21)

環境設定「一般」▸「ホーム」の 2 つの設定(`AppPreferences.libraryFeatureEnabled` / `fileBrowserFeatureEnabled`。
[14](../14-library-collections.md)「ライブラリ機能の ON/OFF」、[15](../15-file-browser.md)「ファイルブラウザ機能の ON/OFF」)について、
OFF の間に隠す・無効にする・止めるはずのものに抜けが無いかを調べた記録。§0〜§6 は**調べた時点の記録**で、そのときは何も直していない
(対象のコミットは `839891b`)。**同じ日に修正した ―― 何をどう直し、何を直さなかったかは §7。**

## 0. 調べ方と、根拠の強さ

設定を読んでいる場所を grep するのではなく、**機能の側から入り口と仕事を全部挙げ、それぞれが OFF の間に届くか**を追った。4 つの観点を並行で
調べ、重要な指摘は別に読み直して裏を取った。

| 観点 | 挙げたもの |
|---|---|
| ライブラリ OFF の画面 | メニューバーの全メニュー、割り当てられるアクション、ビューア、サイドパネル、ファイルブラウザの右クリック、シート、環境設定、ドロップ、ウインドウの要求とタイトル |
| ライブラリ OFF の裏の仕事 | `CollectionStore` / `CollectionCoverExtractor` / `CollectionAutoFolderScanner` / `HomeMenuDirectoryStore` の呼び出し元と契機(起動・アクティブ化・ボリューム・FSEvents・`FileSystemChange`・レイアウトの通知・本を開く) |
| ファイルブラウザ OFF の画面 | 「Finder で開く」の全箇所とその対、メニューバー、`Window` シーン、`.browse` の要求、ジェスチャ、環境設定、切り替えた瞬間に開いているもの |
| ファイルブラウザ OFF の裏の仕事 | `FileBrowserState` の生成から解放まで、`AutoRenameService` の `start` / `stop`、動画サムネイルの先回り、サムネイルのキャッシュ、起動時の仕事 |
| 2 つの組み合わせ | `WelcomeLibraryState.constrained` の表、実行中の切り替え、保存しないモード、ウインドウの要求 |

凡例 ―― **確認** = 該当のコードを読み直して確かめた / **報告** = 並行の調査の報告のまま(読み直していない。直す前に確かめること) /
**実機** = 動かして確かめる必要がある。**どれも実機では未確認**(ビルドも実行もしていない)。

## 1. 構造上の原因

入り口を隠す・項目を消す仕事は、1 件(§2 F1)を除いて抜けが無かった。抜けは**「実行中に OFF へ切り替えた瞬間の後始末」**に集まっている。

`AutoRenameService.stop()` と `CollectionCoverExtractor.cancelAll()` は、この設定ができるまで**テストと終了時にしか呼ばれなかった**。
どちらも「予約を取り消す」だけで、(a) 取り消しを受けた側が取り消しを見ていない、(b) 取り消した Task の変数を nil に戻さない、
(c) 止まっているあいだに外から呼ばれる口に「止まっている」の確認が無い。終了時にはどれも問題にならなかったが、本番で「止めてまた動かす」
ようになって表に出た。**新しく「実行中に止める」口を足すときは、止められる側をこの 3 点で読み直すこと。**

## 2. 指摘 ―― 直す必要があるもの

優先は F1 → L1 → F2。

### F1. 自動リネームが、ファイルブラウザ OFF の間も動き出す(重要)

**入り口が残っている。**
- 環境設定「ファイルブラウザ」の「自動リネームの設定…」は設定を見ずにウインドウを開く(`Views/FileBrowserSettingsView.swift:25-27`)。**確認**。
  「ホーム」メニューの同じ項目は消してある(`App/HomeMenuCommands.swift:80-85`)ので食い違っている。
- 「自動リネームの設定」の `Window` シーンに `.commandsRemoved()` が無い(`App/QooViewerApp.swift:1710-1721`)。**確認**。`Window` は宣言するだけで
  「ウインドウ」メニューに項目が並ぶ(2026-09-09 にお気に入りで実測。`favoritesOrganizerScene` のコメント)ので、そこからも開けるはず。**実機**。
- OFF にした時点で開いていたこのウインドウを閉じる処理が無い(`dismissWindow` の呼び出しが 0 件)。**報告**。
- `AppStores.applyFileBrowserFeature` のコメントと docs/15 の「規則を作る・止める画面がファイルブラウザにしか無い」は、事実と合っていない。

**サービスに「止まっている」の確認が無い。**
- `refreshAvailability()`(`Services/AutoRename/AutoRenameService.swift:345`)は `isStarted` を見ない。パスの末尾(`:420-421`)は無条件に
  `updateWatcher()` と `scheduleScansForChangedTargets()` を呼び、`updateWatcher()` は `watcher == nil` なら FSEvents の監視を張り直す(`:558-569`)。**確認**。
- `handle` / `scheduleRun` / `runPendingWork` も `isStarted` を見ない(`runPendingWork` が見るのは読み取り専用だけ。`:639`)。**報告**(`:639` は**確認**)。

**引き金。**
- 設定ウインドウの対象の行の「アクセスを許可」(`Views/AutoRename/AutoRenameSettingsWindow.swift:562` が `refreshAvailability()` を直に呼ぶ)。**確認**。
- 移動の提案の「更新」(`Views/AutoRename/AutoRenameSheets.swift:168` → `applyMoveSuggestions` → `refreshAvailability()`)。**確認**(呼び出しまで)。
  `stop()` は `moveSuggestions` を消さないので、提案の帯は OFF の間も出たまま。**報告**。
- 確認のシートの `confirm(targetIDs:)`(同 `:81`)。中が走査まで進むかは**未確認**。
- 実行ログの「元の名前に戻す」(同 `:268` → `service.restore`)は、OFF の間も名前を変える。利用者が押す操作なので害は小さい。**報告**。

**影響**: 読み取り専用が OFF で確認済みの対象があると、機能 OFF のまま裏で名前を変え続ける。OFF で起動した場合は `isPausedForReadOnly` が
false のまま(立てるのは `start` だけ)なので、読み取り専用 ON でも監視と走査までは走る(名前の変更は `:639` で止まる)。**報告**。

**直し方の案**: `refreshAvailability` / `updateWatcher` / `handle` / `scheduleRun` / `runPendingWork` の入口に `guard isStarted`。ボタンは OFF の間
出さないか、ウインドウに「ファイルブラウザが OFF なので止まっている」の帯(読み取り専用の帯 `AutoRenameSettingsWindow.swift:166-171` と同じ形)。
シーンに `.commandsRemoved()`(ON の間の入り口は「ホーム」メニュー・右クリック・環境設定にある。`@SceneBuilder` は条件分岐できない)。
コメントと docs/15 の「画面がファイルブラウザにしか無い」も直す。

### F2. `AutoRenameService.stop()` の後始末が足りない(起きる時間の幅は狭い)

- **ON へ戻しても走査が二度と動かなくなる。** `stop()`(`:168-180`)は `runScheduled` を取り消すだけで nil に戻さない。取り消された Task は
  `guard let self, !Task.isCancelled else { return }`(`:604`)で抜け、次の行の `self.runScheduled = nil` を通らない。以後 `scheduleRun()` の
  `guard runScheduled == nil`(`:600`)が弾き続け、アプリを終えるまで走査も名前の変更もしない。起きるのは、走査の予約から 0.3 秒
  (`coalescingDelay`)のあいだに OFF にしたとき。**確認**。
- `missingRecheckTask` も同じ形(`:409-416`。幅は約 1 秒)。見つからない対象の 2 回目の確認が予約されなくなる。**確認**。
- 走っている `runPendingWork` / `process` は `Task.isCancelled` を見ないので最後まで名前を変え、`process` の中の `scheduleRecheck` が `stop()` の
  後に新しい予約を作る。**報告**。
- 進行中の可用性のパスは取り消されても完走し、末尾(`:420`)が `stop()` で下ろした監視を張り直す。典型は「ON にしてすぐ OFF」(`start` は
  全部の対象を確かめるので、対象が大きいと数秒かかる)。**報告**。
- `missingSince` が `stop` / `start` をまたいで残り、再開の最初のパスで「1 秒置いて確かめ直す」を飛ばして対象を OFF にしうる。
  `availability` / `targetsAwaitingConfirmation` / `isPausedForReadOnly` も古い値のまま公開される。**報告**。

**直し方の案**: `stop()` で Task の変数を全部 nil に戻し、覚えている状態を捨てる。完了した側の後始末(`self.runTask = nil` など)が**新しい世代を
壊さない**よう、世代番号で守る(`CollectionCoverExtractor.runGeneration` と同じ形)。F1 の `guard isStarted` がここの大半も塞ぐ。

### L1. 表紙の抽出中にライブラリを OFF にすると、その本の表紙が `.failed` のまま残る

- `setLibraryFeatureEnabled(false)` → `cancelAll()`(`Services/CollectionCoverExtractor.swift:221, 334-345`)が `currentTask` を取り消す。
  走っている `extract(itemID:)` は `CoverImageResolver.coverImage` を待っていて(`:399`)、その中の `try? await BookLoader.load`
  (`Services/CoverImageResolver.swift:186`)は、`BookLoader.load` が取り消しを中へ伝えて `try Task.checkCancellation()` で投げる
  (`Services/BookLoader.swift:44-55`)ので nil を返す。`extract` は await の後に取り消しも設定も見ず、本は実在するので「本が見えなくなった」の
  早期 return にも当たらず、`setCoverStatus(.failed, …)` まで進む(`:405-417`)。**確認**。
- `setLibraryFeatureEnabled` のコメントは「やめた本は `.pending` のまま残り、ON へ戻ったときの `refill()` が拾う」だが、実際は `.failed`。
  `.failed` は表紙の指定が変わるまで試し直されない(`:104-110` のコメント)ので、灰色の表紙のままになる。**報告**(試し直しの条件)。
- 取り消しが読み込みの成功の後に届いた場合は、OFF なのに JPEG を書いて `.ready` にする(害は無いが OFF の間の仕事)。**報告**。

**直し方の案**: `extract` の await の直後に `guard !Task.isCancelled, isLibraryFeatureEnabled else { return }`(`.pending` のまま置く)。
テストは、抽出を待たせる読み込み役を差し込んで「途中で OFF → `.pending` のまま → ON で作られる」を見る。

## 3. 指摘 ―― 判断が要るもの

### D1. OFF の間も `CollectionItem` を全件引く経路がある

`CollectionStore.allItems()` は設定を見ない。`allRegisteredBookIDs()`(`ViewModels/CollectionStore.swift:380`)と
`anyBookmarkData(forBookID:)`(`:391`)が OFF でも全件を引く。**確認**。呼び出し元(**報告**):
- `KnownBooks.collect`(`ViewModels/KnownBooks.swift:31`)―― 「メタデータの編集」ウインドウを開くだけで走る
  (`ViewModels/MetadataEditorViewModel.swift:324`)。「コレクション表紙の読み込み」でも(`ViewModels/ShelfCoverImportViewModel.swift:108`)。
- URL を解く `??` の連鎖の最後の手段 ―― `ViewModels/BookExportViewModel.swift:582`、`MetadataEditorViewModel.swift:101`、
  `ViewModels/LibraryCleanupViewModel.swift:150, :253`。

見立て: ライブラリのためだけの仕事ではなく(コレクションにしか無い本も編集・書き出しの対象で、権限の最後の手段でもある)、**「止めないもの」の側**。
ただし `AppStores.applyLibraryFeature` のコメント・docs/14 の表・CLAUDE.md の「must not fetch `CollectionItem`s while it is off」のどれにも
載っていない。意図どおりなら 3 箇所へ追記、そうでなければ設定を見る。

### D2. OFF の間に動かした本の、コレクションの行の `bookID` が付け替わらない(**報告**、確度は中)

- OFF の間に Finder で同じボリュームの中を移した本を開くと、レイアウト・ブックマーク・メタデータ・お気に入りの行は付け替わるが、
  コレクションの行は付け替えない(`ViewModels/AppState.swift:1061-1068`)。`:1066` のコメントは「ON へ戻したときの存在確認がブックマークで追う」
  だが、`finishExistenceRefresh` は場所の辞書を埋めるだけで `bookID` は直さない。ON の状態でもう一度開けば `reconcileBookIDIfMoved` が直す。
  それまでは `item.bookID` で引くもの(表紙の指定・タイトル・メタデータ)が外れる。
- 同じ原因で、OFF の間に表紙の指定が変わった本の控え(`booksChangedWhileDisabledKey`。中身はパス。
  `CollectionCoverExtractor.swift:239-253`)も、その後に本が動くと付け替わらず、ON へ戻したときの作り直しから漏れる。
  `BookRecordRelocator` も `reconcileBookIDIfMoved` もこの一覧を触らない。

直すなら: 本を開いたときの `reconcileBookIDIfMoved` は OFF でも走らせる(全件フェッチを伴うので、D1 と同じ「止めないもの」の判断になる)か、
コメントを実際の挙動へ直す。控えのほうは `BookRecordRelocator` の付け替えに加える。

### D3. 文言の残り(軽微)

- 読み取り専用のヘルプの "create and add to collections"(`Views/FileBrowserSettingsView.swift:22`)。ライブラリ OFF の間は無い機能。**確認**。
- ファイルブラウザ版のメタデータのシートの表紙の枠のアクセシビリティのラベル "Collection Cover"(`Views/Welcome/BookMetadataSheet.swift:490`)。**報告**。
- 「メタデータの編集」ウインドウの "Collection Cover" 列と、その右クリックの "Change Collection Cover" / 切り出し位置の "Use Library Setting"
  (`Views/MetadataEditorWindow.swift:309`、`Views/Export/ExportWindowContent.swift:639, :750`)。表紙の指定を OFF でも変えられるのは docs/14 のとおり
  (ファイルブラウザのアイコンに使う)だが、切り出し位置はコレクションの表示にしか効かない。このウインドウは docs/14 の表に載っていない。**報告**。

## 4. 軽微 ―― 文書へ足せば済むもの

- `ContentView.welcomeTitle`(`Views/ContentView.swift:196-209`)は、OFF の間もタイトルを評価するたびにライブラリとコレクションの行を引く
  (`allLibraries()` / `allCollections()`。`CollectionItem` ではない)。`.browser` / `.classic` では結果を使わない。`mode == .shelf` のときだけ引けば揃う。**確認**。
- 起動時の「見つからない本」の確認(`ContentView.swift:937-946`)は起動につき 1 回。OFF で起動して ON にしても次の起動まで出ない。**報告**。
- 進行中の存在確認は OFF にしても完走する(`CollectionStore.swift:1198` の繰り返しが取り消しを見ない。1 パスぶん)。**報告**。
- ON → OFF の後も `cachedItems` / `locationByItemID` / `fileDatesByItemID` はメモリに残る(docs が「載らない」と約束しているのは OFF で起動した場合だけ)。**報告**。
- ファイルブラウザ OFF でも、ウインドウごとの `FileBrowserState` は作られ、購読(アクティブ化・キーウインドウ・ボリューム・`FileSystemChangeCenter`・カット)は
  残る。そのたびの仕事はカットの検証とペーストボードの `changeCount` の比較だけ(`ViewModels/FileBrowserState.swift:389-395, 988-1008`)。
  ON → OFF で隠れたウインドウは、最後のフォルダの一覧を閉じるまで持つ。表示中のフォルダ自体が動いたときだけ 1 回列挙する(本を読んでいる間と同じ)。**報告**。
- サムネイルのディスクキャッシュの起動時 1 回の刈り込みは設定に関わらず走る(`FileBrowserThumbnailDiskCache.swift:150-169`)。**報告**。
- コピー・移動の最中に OFF にすると、操作は続くのに進捗バーと中止ボタンがペインごと消える(`FileBrowserOperations` は `FileBrowserState` の持ち物)。
  ウインドウに出した確認(`FileBrowserSheetPresenter`)・一括リネームのシートは残り、OFF の後に押しても実行される(入り口が見るのは読み取り専用だけ)。
  書き出し中のシート(`bookSheet`)を片付けるのは `releaseResources` だけ。名前の編集中に OFF にしたとき確定扱いになるかは**実機**。**報告**。
- テストホストでは `welcomeLibrary` の 2 つの設定が ON に固定される(`ContentView.swift:357, 363`)一方、メニューバー・
  `RevealInFileBrowserAction.isFeatureEnabled`(`ContentView.swift:509`)・`AppState.showInFileBrowser`(`FileBrowserReveal.swift:97`)は実際の設定を読む。
  テストが自前の `AppPreferences` を使う限り害は無い。**報告**。
- `FileBrowserLibraryActions.createCollection` は入口で設定を見たあと分類を待つので、そのあいだに OFF にすると名前を訊くシートの行列に積まれる
  (`FileBrowserLibraryActions.swift:40-46`、`WelcomeView.swift:147-148`)。環境設定を操作しないと踏めない。**報告**。

## 5. 抜けが無かった範囲

**確認**したもの:
- モードの表 ―― `WelcomeLibraryState.constrained`(`ViewModels/WelcomeLibraryState.swift:85-92`)が 4 通りを網羅し、`mode` の `didSet` が必ず通すので、
  `mode = .browser` と書く場所(`FileBrowserReveal.swift:106`、`ContentView.swift:803` など)はどれも押し戻される。押し込まれたモードは保存しない。
  init が保存先の設定を直に読むので、最初の 1 コマも正しい。
- 実行中の切り替え ―― `ContentView.swift:356-364` が 2 つの設定を写し、ライブラリ OFF で `endEditing()`(出しかけのシート・`menuRequest`・編集モード)。
- `.browse` の要求 ―― 作るのは `BookWindowOpener.openFolder` だけで、呼ぶのは「ファイルブラウザで開く」(入口で断る)とファイルブラウザ自身
  (ペインが無ければ届かない)。受ける側(`ContentView.swift:799-804`)も表に押し戻される。
- 割り当てられる `ViewerAction` に、ライブラリ・ファイルブラウザへ触るものは無い(`returnToWelcome` だけ)。
- 環境設定の「見つからない本の削除を尋ねる」はライブラリ OFF で無効(`GeneralSettingsView.swift:122`)。

**報告**で「塞がっている」とされたもの(1 件ずつの読み直しはしていない):
- 「ファイルブラウザで開く」の 9 箇所(`SidePanelView.swift:774/1108/1473/1762`、`PageContextMenuItems.swift:54`、`SidePanelLibraryTreeSection.swift:216`、
  `CollectionDetailView.swift:612`、`ViewerView.swift:2400`、`QooViewerApp.swift:818`)と入口の拒否。「Finder で開く」のほかの箇所には対の項目が無い。
- ファイル・編集・表示・移動・ホームの各メニュー(`QooViewerApp.swift:727, 818, 949-951, 1128, 1225, 1247`、`HomeMenuCommands.swift:75-101, 176-179, 409-420`)。
  本棚の選択が相手の項目は `HomeMenuState.isShelfShown` が偽なので対象が nil になる。
- `FileBrowserNavigationGestureMonitor`・名前の編集のイベント監視・ツリーの監視・アイコンのサムネイルの依頼は、ペインの onAppear / onDisappear で着脱。
- サイドパネルのライブラリのツリー(`SidePanelView.swift:391-413`)、ファイルブラウザの右クリック(`FileBrowserActions.swift:668, 748`)と入口
  (`FileBrowserLibraryActions.swift:40, 82`)、`BookMetadataSheet.swift:109`、ホームへのドロップ(編集モードが前提)。
- 裏の仕事の入口 ―― `CollectionStore.scheduleExistenceRefresh`(`:1176`)、`CollectionCoverExtractor` の `prepareIfNeeded` / `enqueue` / `refill` /
  `handleLayoutChange`、`CollectionAutoFolderScanner.scheduleScan`(`:152, :332`。監視は入口の先で遅れて作る)、`HomeMenuDirectoryStore`、
  `AppStores.sweepLibraryOrphansIfNeeded`、`AppState.open` の 2 つの呼び出し、`FileBrowserThumbnailProvider.resolveSource`(`:300`)。
- OFF → ON の再開は 1 回ずつ(購読の `removeDuplicates()` と各 setter の同値の確認)。掃除は下ごしらえの移行の後。
- `AutoRenameService.start` を呼ぶのは `AppStores` の 2 箇所だけで、どちらも設定を見る。動画サムネイルの先回りは自分で購読していて、3 通りの遷移とも正しい。
- `FavoriteLocationStore` / `FileCutClipboard` / `AutoRenameStore` / `AutoRenameActivityLog` の init は保存先を読むだけ。`ReplaceBackupRecovery` と
  `FileSystemChangeCenter` は意図して残してある(文書どおり)。
- `WindowContentRequest` にライブラリ・コレクションを開く case は無い。Dock のメニュー・サービス・URL スキームは無い。状態の復元は全 `WindowGroup` で無効。

## 6. 引き継ぎ

1. **F1 → L1 → F2 を直す。** どれも「止められる側」の中で閉じる修正で、互いに依存しない。テストは UI 無しで書ける ――
   `AutoRenameService` は使い捨てのフォルダ + 注入した `fileOps` で(既存の自動リネームのテストの形)、`stop()` の直後に
   `refreshAvailability()` / `handle` を呼んで何も起きないこと、予約の直後に `stop()` → `start()` して走査が動くこと。
   `CollectionCoverExtractor` は L1 のとおり。
2. 直す前に、**報告**の項目は該当のコードを読み直す(行番号は `839891b` のもの)。
3. **実機**で確かめるもの ―― 「ウインドウ」メニューの「自動リネームの設定」(F1)、名前の編集中・シートを出したままの OFF(§4)。
   使い捨てのボリュームに合成名の項目を置いて行う(CLAUDE.md「個人情報の流出防止」)。
4. D1〜D3 は方針を決めてから。D1 を「止めないもの」にするなら、`AppStores.applyLibraryFeature` のコメント・docs/14 の表・CLAUDE.md の 3 箇所へ足す。
5. 直したら docs/14・docs/15 の「止まる仕事・止めない仕事」と、この文書の該当の節に「修正済み」を書き足す(§1〜§5 は調査時点の記録として残す。
   [fs-ui-consistency-audit.md](fs-ui-consistency-audit.md) と同じ形)。

## 7. 修正の記録(2026-09-21)

§2〜§4 の指摘を直した。**報告**だった項目は、直す前に該当のコードを読み直して確かめてある。テストは `AutoRenameServiceTests`(3 件追加)と
`LibraryFeatureToggleTests`(3 件追加)。**実機ではまだ確かめていない**(下の「残り」)。

| 指摘 | 直し方 |
|---|---|
| **F1** 入り口 | 環境設定「ファイルブラウザ」の「自動リネームの設定…」は OFF の間は淡色。`Window` シーンを `autoRenameSettingsScene` に切り出して `.commandsRemoved()`。設定ウインドウは OFF になったら自分で閉じる(`onChange(of: fileBrowserFeatureEnabled, initial: true)` → `dismissWindow`。シートごと)。フッターの説明に「ファイルブラウザを無効にしている間は動かない」を足した。`AppStores.applyFileBrowserFeature` のコメントと docs/15 の「画面がファイルブラウザにしか無い」も事実に合わせた |
| **F1** サービス | `refreshAvailability` / `refreshAvailabilitySoon` / `updateWatcher` / `handle` / `scheduleRun` / `startRunIfNeeded` / `scheduleRecheck` / `readOnlyDidChange` の入口に `guard isStarted`。設定ウインドウの「アクセスを許可」・移動の提案の「更新」・確認の `confirm` は、止まっている間は保存先を書き換えるだけで何も起こさない(`confirm` は `store.confirm` だけで、走査へ進むのは `store.$rules` の購読 ―― `stop()` が外している)。「元の名前に戻す」(`restore`)は塞いでいない: 入り口のウインドウが閉じるので届かず、届いても利用者が押した 1 件だけ |
| **F2** | `stop()` が Task の変数を全部 nil に戻し、待ち行列・観測・`missingSince`・`activeTargetKeys`・公開している値を捨てる。`stop()` のたびに進む `generation` を Task が控え、await から戻るたびに `isCurrent(generation)` を確かめる(可用性のパスの各 await の後・`runPendingWork` の繰り返し・`process` の項目ごと・各予約の Task)。古い世代の後始末は新しい世代の変数に触らない |
| **L1** | `extract(itemID:)` の読み込みの直後に `guard !Task.isCancelled, runGeneration == generation, isLibraryFeatureEnabled`(`.pending` のまま戻る)。`inFlightItemIDs` の後始末も世代で守る。テストは、読み込みの直前に呼ぶ口(`willLoadCoverImageForTesting`)から OFF にして、取り消された状態で本物の読み込みへ入らせる(確認を外すと `.failed` になって落ちることを確かめた)。`waitUntilIdle()` は取り消したループの終わりまで待つ(`lastCancelledTask`) |
| **D1** | 方針: **「止めないもの」の側**。`AppStores.applyLibraryFeature` のコメント・docs/14 の「止めないもの」・CLAUDE.md へ足した。止めるのは「ライブラリのためだけの仕事」で、「`CollectionItem` に触るもの全部」ではない |
| **D2** 行の `bookID` | 方針: 本を開いたときの `CollectionStore.reconcileBookIDIfMoved` / `backfillFileNodeIdentifier` を **OFF でも走らせる**(`AppState.open` の `tracksCollections` を撤去)。5 つのストアを必ず揃えて付け替える。全件フェッチを伴うが、D1 と同じ「保存データを正しく保つ仕事」 |
| **D2** 控え | `CollectionCoverExtractor.relocateBooksChangedWhileDisabled` を足し、`BookRecordRelocator.apply` が呼ぶ(アプリ自身が移した本)。Finder で移した本は、開いたときの `LayoutStore.reconcileBookIDIfMoved` が新しいパスで `.layoutDataDidChange` を出すので、`rememberChangeWhileDisabled` が新しいほうも覚える(上の行の修正でコレクションの行も新しいパスになるので、ON へ戻したときの作り直しに届く) |
| **D3** | 読み取り専用のヘルプは、ライブラリ OFF の間「コレクションの作成と登録」を外した文にする。「コレクション表紙」の名前(メタデータのシートのラベル・「メタデータの編集」ウインドウの列と右クリック・切り出し位置)は**変えない** ―― 理由は docs/14「止めないもの」の末尾 |
| §4 `welcomeTitle` | `mode == .shelf` のときだけライブラリとコレクションの行を引く |
| §4 進行中の存在確認 | OFF にしたら取り消し、繰り返しが取り消しを見て抜け、途中までの結果は公開しない(`abandonExistenceRefresh`。すぐ ON へ戻されていたら最初からやり直す) |
| §4 `createCollection` | 分類の await の後で設定を確かめ直す |

**直さず、文書へ書いたもの**(§4 の残り): 起動時の「見つからない本」の確認が起動につき 1 回であること、ON → OFF の後も引いてあった行がメモリに残ること
(docs/14)。コピー・移動の最中の OFF、OFF でも残る `FileBrowserState` の購読、サムネイルのディスクキャッシュの起動時の刈り込み(docs/15)。
テストホストで `welcomeLibrary` の 2 つの設定が ON に固定されることは、テストが自前の `AppPreferences` を使う限り害が無いのでそのまま。

**(下の 2 件は同じ日にどちらも処置した ―― この節の末尾「残りの処置」)**

**調べている途中で見つけた、この監査の外の件**: フォルダの本のページの鍵(`PageRef.sortKey`)は**絶対パス**で、`LayoutStore.applyBookRelocation` /
`reconcileBookIDIfMoved` は `bookID` だけを付け替えて鍵(`PageLayoutOverride.pageKey`・`shelfCoverPageKey`・`coverPageKey`)は書き換えない。
フォルダの本を移す・名前を変えると、ページ単位の指定と「本の中のページ」での表紙の指定が外れるはず(書庫・PDF・EPUB の鍵は本の中で閉じているので
無関係)。ON/OFF とは関係なく前からある挙動で、ここでは直していない。

**実機で確かめたもの**(2026-09-21、コミット `2dad5a7` の Debug ビルド。メニューと環境設定をアクセシビリティ経由で操作し、スイッチは HID レベルの
クリックで切り替えた。読んだのはメニューの項目名・ウインドウの有無・ボタンの enabled で、画面は撮っていない):
- 「ウインドウ」メニューに「自動リネームの設定」が並ばない(ON でも OFF でも。ほかの `Window` シーンは並んでいる)。
- ON の間、「ホーム」メニューの項目と環境設定「ファイルブラウザ」のボタンから設定ウインドウが開く。
- 設定ウインドウを開いたままファイルブラウザを OFF にすると、その場で閉じる。「ホーム」メニューから「ファイルブラウザ」と「自動リネームの設定…」が消え、
  環境設定のボタンは淡色(enabled = false)、フッターは新しい文になる。
- ON へ戻すと「ホーム」メニューの項目とボタンが戻る。閉じたウインドウが勝手に開き直すことはない。
- **`.commandsRemoved()` の副作用と、その修正**: 最初の修正では、開いている間も、このウインドウが「ウインドウ」メニューの下端の開いている
  ウインドウの一覧に載らなかった(シーンの項目がその一覧の行を兼ねていた)。`AutoRenameSettingsWindow` が自分の載っている `NSWindow` の
  `isExcludedFromWindowsMenu` を false に戻すようにして直した。実機で確かめた: 開いている間だけ一覧の末尾に 1 行載り、選ぶと手前へ出て、
  閉じると消える(OFF の間の入り口にはならない)。

**実機で確かめたもの・2 回目**(同じ日。Debug 側で許可済みのボリュームの直下に合成名のフォルダを作り、アプリの終了中に、よく使う項目 1 件と
そのフォルダだけを対象にした規則 1 件を Debug の設定へ書き足した ―― ファイル選択ダイアログは使っていない。終わってから設定を差分ゼロまで戻し、フォルダを消した):
- **OFF の間は名前を変えず、ON へ戻すと変える。** ON の間に置いた項目は約 2 秒で名前が変わる(基準)。OFF にしてから対象の直下とサブフォルダへ
  項目を置き、10 秒待っても変わらない。ON へ戻すと 1〜2 秒で両方変わる(`start` の全走査)。
- **シートを出したままの OFF で、ウインドウが閉じなかった ―― 直した。** 実行ログのシートを出したまま OFF にすると、最初の修正ではウインドウもシートも
  残った。シートが付いている間の `dismissWindow` は何も起こさない。`.sheet` の `onDismiss` から呼び直しても、その時点ではまだ付いていて閉じなかった
  (これも実機)。いまは先にシートを下ろし、`NSWindow.attachedSheet` が nil になるのを待ってから閉じる(`AutoRenameSettingsWindow.closeIfFileBrowserIsOff`。
  長くて 5 秒。待っているあいだに ON へ戻されたら閉じない)。シートあり・なしの両方で閉じることを確かめた。ON へ戻せばまた開ける。
- ついでに分かったこと: シートが付いたウインドウがあると、アプリの終了(AppleScript の `quit`)は「キャンセルされました」で断られる(AppKit の普通の挙動)。
  「ホーム」メニューの「自動リネームの設定…」は、環境設定ウインドウが手前のときは淡色(本のウインドウの値を読む項目なので。前からの挙動)。

**実機で確かめたもの・3 回目**(同じ日。「実名が写るのでペインは撮れない」としていたが、ユーザー指摘のとおり**使い捨てボリュームの中身を表示して
行えば済む**話だった ―― Debug 側には起動ディスク直下(`/`)の許可があるので `hdiutil` のボリュームもダイアログ無しで読め、よく使う項目を検証の間だけ
合成フォルダ 1 件に差し替えれば、ペインに実在の名前は並ばない。撮るのはウインドウの内側だけ、帯より下):
- **右クリックの「自動リネーム」**: ON の間、フォルダの右クリック ▸ 自動リネーム ▸(規則の一覧・「このフォルダの規則を作成…」・)「自動リネームの設定…」から
  設定ウインドウが開く。OFF の間はペインごと無いので、この入り口も無い。
- **名前の編集中の OFF**: 編集欄に打ちかけのまま環境設定を開き(編集は続いている)、OFF にすると、**編集は捨てられて名前は変わらない**。ON へ戻すと
  ペインは編集中でない状態で戻る。直すものは無い。
- **シートを出したままの OFF で、押すと実行された ―― 直した。** 一括リネームのシートを出したまま OFF にすると、シートはウインドウの持ち物なので残り、
  「名前を変更」を押すと名前が変わった(§4 の報告のとおり)。シートを出したまま**読み取り専用へ切り替えた**場合も同じ穴(こちらは前からある)。
  `FileBrowserOperations.isReadOnly` が「ファイルブラウザ機能が OFF」も断る理由に数えるようにし、操作を始める前の確認・シートは `asking` を通して、
  **出している間に断る状態へ切り替わっていたら「キャンセル」扱い**にした(一括リネーム・保存先の選択・すぐに消える削除・ロックされた項目・戻せない移動)。
  直した後の実機: 同じ手順で押すとシートが閉じるだけで、名前は変わらない。テストは `FileBrowserOperationsTests`(機能 OFF・読み取り専用の 2 通り)。
  - 最初は「コマンドを実行に移す直前」に 1 箇所で見たが、既存の決まり「読み取り専用は走っている操作を止めず、次の操作から効く」(切り替えの前に受け付けて
    並んでいた操作は最後までやる)を壊した(そのテストが落ちた)。見るのは「確認を出す前は断っていなかったのに、答えが返ったときには断っていた」場合だけ。
  - コピー・移動の**途中**の衝突の確認(`resolveConflict`)は通さない ―― 半分だけ済んだ状態で止めない。進捗バーがペインごと消える件もそのまま。

**残りの処置**(同じ日):
- **フォルダの本のページの鍵**(上の「この監査の外の件」): テストで再現してから直した。`PageKeyRelocation` が、`bookID` を付け替える 2 つの経路
  (`reconcileBookIDIfMoved`・`applyBookRelocation`)で `PageLayoutOverride.pageKey`・`coverPageKey`・`shelfCoverPageKey`・`Bookmark.pageKey`・
  `BookReadingState.lastPageKey` の頭も付け替える。それ以前に移した本の行は、開いたときに候補が 1 つに決まる場合だけ直す。経緯と決まりは
  [06](../06-persistence.md#移動リネームへの追従)。テストは `PageKeyRelocationTests`。
- **操作の最中の OFF で進捗の帯が消える**(§4): ペインが出ていない間は `WelcomeView` の下端へ帯を引き継ぐ([15](../15-file-browser.md)
  「ファイルブラウザ機能の ON/OFF」)。実機で、ボリュームをまたぐ約 12 GB のコピーの最中に OFF → 帯が残る → 帯の中止で作りかけの項目が片付く、を確かめた。
  - この検証で 1 枚、**OFF にした後の本棚の下端(表紙の絵の切れ端。名前は無い)が写った**。範囲を帯の高さより広く取ったため。すぐ削除し、以後は帯の
    高さだけを切り出した。モードが切り替わる検証では、切り替わった後に何が出るかまで考えて範囲を決めること。
- これで §2〜§4 と、途中で見つけた件に、未処置のものは無い。「直さない」と決めて理由を書いたものは: `restore`(元の名前に戻す)を止まっている間も
  塞がないこと、「コレクション表紙」の名前を OFF の間も変えないこと(D3)、コピー・移動の途中の衝突の確認は OFF でも答えさせること、
  ON → OFF の後も引いてあった行をメモリに残すこと、サムネイルのディスクキャッシュの起動時の刈り込み、テストホストの設定の固定。


## 8. 2 回目の監査と修正(2026-09-21、v1.64 以降の変更全体)

v1.64(`4b912b1`)から `43ffad0` までの差分を、リソースリーク・クラッシュ・ハング・ファイルの破損と消失・メモリとディスクの過大な消費に絞って
読み直した(停止と再開の並行性・保存データとファイル操作・UI とライフサイクルの 3 つに分けて、指摘は実コードで確かめ直した)。致命的なものは無く、
次の 5 件を直した。どれも実機ではまだ確かめていない(テストで再現してから直した)。

- **M1 フォルダの本を移すと、ページの並べ替え(`pageOrderOverrideJSON`)だけが付け替わらない** ―― §7「残りの処置」のページの鍵の付け替えの漏れ。
  鍵が合わないと表示は黙って正準順へ戻り、付いてきたページ単位の見開きの指定が別の並びに当たって崩れた(`pinPageOrderIfNeeded` が自動で固定した本も)。
  `LayoutStore.relocatePageKeys` と `repairStalePageKeys` が並べ替えも書き換える。テストは `PageKeyRelocationTests` の 3 件に並べ替えを足した。
- **L1 OFF の間に表紙を変えた本の控えを、作り直しが終わる前に消していた** ―― 作り直しの途中でもう一度 OFF にする・アプリを終えると、残りの本は
  古い表紙のまま二度と拾われなかった。`.failed` の本は指定を直しても灰色のままだった。控えは本ごとに抽出が終わってから外し、`.failed` は `.pending` へ
  戻す([14](../14-library-collections.md)「ライブラリ機能の ON/OFF」)。テストは `LibraryFeatureToggleTests.redoInterruptedByTurningOffKeepsTheRest`。
- **L2 確認で止めたペーストで、カットの記憶だけが消える** ―― 記憶を下ろすのを、移動を実際に始める時点へ移した([15](../15-file-browser.md)
  「コピー/カット」)。テストは `FileBrowserOperationsTests.cutSurvivesAPasteStoppedAtTheConfirmation`。
- **L3 初めて ON にした時点の掃除が、書いたばかりの表紙の元画像を隔離しうる** ―― 掃除が起動時以外にも走るようになったため。書いてから 10 分以内の
  ファイルは隔離しない(`CollectionCoverSourceStore.recentFileGrace`)。テストは `CollectionCoverSourceStoreTests.freshlyWrittenFilesAreLeftAlone`。
- **L4 自動リネームの読み取り専用の穴 2 つ**(v1.64 以前からのもの) ―― 走査が各項目の前に設定の値そのものも見る。「元の名前に戻す」は読み取り専用の
  間は淡色で、戻す側でも断る。テストは `AutoRenameServiceTests.restoringIsRefusedInReadOnlyMode`。

**直していないもの**: 2 本指フリックが一覧の上で `.ended` まで届くかは実機でまだ確かめていない(届かなくても移動しないだけ。届かなければ一覧の側で
`wantsScrollEventsForSwipeTracking(on:)` を使う)。「常にこのアプリケーションで開く」がフォルダにも出ること・開いている本を除かないことは、xattr を
書くだけで本を壊さないので残した。
