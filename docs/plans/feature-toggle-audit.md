# ライブラリ/ファイルブラウザの ON/OFF ―― 抜け漏れのコード監査(2026-09-21)

環境設定「一般」▸「ホーム」の 2 つの設定(`AppPreferences.libraryFeatureEnabled` / `fileBrowserFeatureEnabled`。
[14](../14-library-collections.md)「ライブラリ機能の ON/OFF」、[15](../15-file-browser.md)「ファイルブラウザ機能の ON/OFF」)について、
OFF の間に隠す・無効にする・止めるはずのものに抜けが無いかを調べた記録。**調べただけで、何も直していない**(対象のコミットは `839891b`)。
この文書は修正を引き継ぐためのもの。

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
