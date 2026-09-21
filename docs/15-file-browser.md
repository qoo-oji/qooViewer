# 15. ファイルブラウザ ―― ホームのもう1つのモード

改善要望7(2026-09-13〜)。ホームの帯の左端のボタンで、本棚([14](14-library-collections.md))と
**Finder の代わりに使えるファイルブラウザ**を切り替えます。検討の経緯と決定事項は
[plans/file-browser-study.md](plans/file-browser-study.md)、段階ごとの計画と引き継ぎは
[plans/file-browser-plan.md](plans/file-browser-plan.md) にあります。この章は**いま入っているもの**の説明です。

| 段階 | 内容 | 状態 |
|---|---|---|
| 0 | 蔵書の名前を出さない仕組み(→ [02](02-project-and-build.md)) | 済 |
| 1 | 環境設定の整理・帯の 2 ボタンの撤去 | 済 |
| 2 | ファイル操作エンジン(UI なし) | 済 |
| 3 | 画面(読むだけ): モード切替・ツリー・リスト・アイコン・操作列・パスバー・開く・新規タブ/ウインドウ・環境設定 | **済(2026-09-13)** |
| 4 | 書く操作の UI | **済(2026-09-14)**。4a: コピー/カット/ペースト・ゴミ箱・新規フォルダ・名前の変更・取り消し・進捗の帯。4b: D&D・アイコン表示の名前の変更と type-select・置き換えと退避の復旧・ロックされた項目の確認・ツリーの自動展開・取り消せない移動の確認・見つかった問題 11 件の修正(計画 §4.15) |
| 5 | 一括リネーム | **済(2026-09-14)** |
| 6 | 圧縮・展開 | **済(2026-09-14)**。実装・自動テスト・実機確認(計画 §6.1) |
| 7 | サムネイル | **済(2026-09-14)**。7a(本・画像・画像フォルダの絵とキャッシュ)・7b(動画・よく使う項目の配下の事前生成)。実装・自動テスト・実機確認(計画 §7.1・§7.2) |
| 8 | 既存機能との接続 | **済(2026-09-14)**。実装・自動テスト・実機確認(計画 §8.1・§8.2) |
| 8.5 | 読み取り専用モード | **済(2026-09-14)**。実装・自動テスト・実機確認、実機で見つけた問題 2 件の修正(計画 §8.5.1)。そのあとブランチ全体のコード監査と修正(計画 §8.5.4) |
| 9 | 検証と文書 | **文書は済(2026-09-14)**。実機の検証が残り(計画 §9.1 の一覧) |

## 構成

```
WelcomeView(PanelSurface.welcome)
 ├─ WelcomeTopBar: [ファイルブラウザ] | ライブラリのチップ … ＋      ← | は WelcomeSeparator
 ├─ WelcomeSeparator(横)
 └─ mode == .shelf   → WelcomeLibraryPane(本棚)
    mode == .browser → FileBrowserPane
        ├─ FileBrowserTreeView(NSOutlineView): ボリューム / ホームフォルダ / よく使う項目 ＋
        ├─ WelcomeSeparator(縦。幅のドラッグ)
        └─ 右: 操作列 [‹ › ↑] [フォルダ名] [大きさ(アイコン表示のみ)][リスト][アイコン][並べ替え][検索]
               FileBrowserListView(NSTableView) / FileBrowserIconView(NSCollectionView)
               FileBrowserPathBar(NSPathControl)
```

| 型 | 置き場所 | 寿命 |
|---|---|---|
| `WelcomeLibraryState.mode`(`WelcomeMode`) | ViewModels | ウインドウごと。`qooViewer.welcome.mode` に保存し、次のウインドウは前回のモードで始まる |
| `FileBrowserState` | ViewModels | ウインドウごと(`ContentView` の `@StateObject`)。現在のフォルダ・一覧・選択・戻る/進む・表示形式・並べ替え・`FileCommandStack` |
| `FavoriteLocationStore` | ViewModels | アプリ全体(`AppStores`)。よく使う項目(パスだけ) |
| `FileBrowserListing` / `FileBrowserEntry` / `FileBrowserLoadError` | Services/FileBrowser | 一覧の読み取り(nonisolated、`FileIO` の上で呼ぶ) |
| `FileBrowserActions` | Views/FileBrowser | ペインの `@State`。3 つの一覧が共有する「開く」などの口(相手は全部 weak。値の `OpenWindowAction` だけはペインが消えたら外す) |
| `WindowContentRequest` | Models | 本のウインドウの提示値(`book` / `browse`) |
| `FileBrowserOperations` | ViewModels | ウインドウごと(`FileBrowserState.operations`)。書く操作の窓口(→「書く操作」「操作エンジン」) |
| `FileBrowserThumbnailProvider` / `FileBrowserVideoThumbnailWarmer` | Services/FileBrowserThumbnails | アプリ全体(`AppStores`)。アイコン表示の絵と、よく使う項目の中の動画の絵の先回り(→「サムネイル」) |
| `AutoRenameStore` / `AutoRenameActivityLog` / `AutoRenameService` | ViewModels / Services/AutoRename | アプリ全体(`AppStores`)。自動リネームの規則・実行ログ・実行役(→「自動リネーム」) |
| `ReplaceBackupRecovery` | Services/FileOperations | 起動時に 1 回(`QooViewerApp`。テスト中は動かさない)。「置き換える」の途中で落ちたときの復旧 |

## 操作エンジン(段階 2)

画面を持たない層。qooLibrary の同名の型を写し、計画 §2 に合わせて変えた。書く操作はすべて上から順にこの経路を通る。

```
FileBrowserOperations(ウインドウごと。1 本ずつ直列・確認の受け渡し・読み取り専用の入り口)
 └─ FileCommandStack(ウインドウごと。深さ 50・完了の音)
     └─ FileCommand: MoveFiles / CopyFiles / RenameFile / BulkRenameFile / TrashFiles /
                     DeleteFilesImmediately / CreateFolder / CompressFiles / ExtractArchives / Composite
         └─ FileOperationService(状態を持たない actor。段取りだけ)
             ├─ FileIO.perform …… ブロッキングする I/O はすべてこの上(投入ごとの serial queue)
             ├─ FileCopyEngine …… copyfile(3) + COPYFILE_CLONE。進捗・中止・書きかけの片付け
             ├─ FileOperationPreflight / ProgressTracker / MoveVerification …… 総量・空き容量・パス長・運ぶ間に元が変わったか
             ├─ MountTable / TrashAvailability / FileOperationEnvironment …… マウント表・ゴミ箱の有無・本物のゴミ箱か pseudoTrash か
             ├─ ReplaceBackupJournal …… 「置き換える」の退避の記録
             └─ ZipCompressor / ArchiveExtractor / ArchiveExtractionPlan …… 圧縮・展開(段階 6)
```

| 決めごと | 中身と理由 |
|---|---|
| ブロッキングは `FileIO` の上 | `Task.detached` は協調プールの上で、応答しない共有(SMB 30 秒・NFS hard は無限)がプールごと止める。決まった本数のキューを使い回すとデッドロックする(qooLibrary)。借りたスレッドでは `Task.isCancelled` が常に false なので、取り消しは `Cancellation.isRequestedInCurrentScope` で読む。`withDeadline` は**待つのをやめるだけ**(I/O は止まらない) |
| actor は状態を持たない | I/O の間 actor を手放しても正しさが崩れず、1 件のハングが他の操作を巻き添えにしない。同時に走る操作の交錯は、`RENAME_EXCL` / `COPYFILE_EXCL` / `O_EXCL \| O_NOFOLLOW` が「取りこぼした衝突で書き潰す」ことを防ぐ(最悪 EEXIST)。exFAT は `RENAME_EXCL` に ENOTSUP を返すので、上書きしない別の手順へ落ちる。`static` メンバは「ブロッキング側」、素のメソッドは「段取り側」と読める |
| 「どこか」はマウント表で答える | `resourceValues` / `statfs(path)` は相手のファイルシステムへ問い合わせる。`MountTable`(`getmntinfo_r_np(MNT_NOWAIT)`)はカーネルの控えを写すだけ。ボリュームの同定は `volumeIdentifier`(`st_dev` はマウント順で変わる) |
| 結果は受領書 + 失敗 | 一括の移動・コピーは投げ切らず、動いた分の受領書(`TransferReceipt`)と失敗(`FailedItem`)を 1 つの結果(`TransferOutcome`)で返す。1 件も動かなかったときだけ投げる。衝突の「すべてに適用」は 1 回の操作の中でエンジンが覚える(`ConflictDecision`) |
| 取り消しは自前のスタック | `NSUndoManager` を使わない ―― 取り消しが非同期で、部分的にしか戻らないことがあり、「戻らなかった」を必ず見せ、進捗と中止も要る。投げた操作は積まない、部分的に済んだ操作は積む(動いた分を戻せるように)、部分的な取り消しは redo に積まない。取り消しの直前に `FileIdentity`(デバイス + inode + 作成日時)を突き合わせる(→「書く操作」) |
| 進捗は 100ms に間引く | 項目の切り替わり・完了・項目の最初のバイトは間引かない。1 バイトも書かないと分かっている操作(同じボリュームの移動)とクローンで済むコピーでは総量を数えない |
| ゴミ箱 | `NSWorkspace.recycle`(サンドボックスでも実際のホームフォルダの `~/.Trash`)。完了が来ない環境があるので 120 秒で待つのをやめる。ゴミ箱の有無は `TrashAvailability`(→ [10](10-sandbox-and-security.md#ゴミ箱と使い捨てボリューム改善要望7-段階-22026-09-13-実測)) |
| テスト | `FileOperationEnvironment.pseudoTrash(at:)` で本物のゴミ箱に触れない。置き換えの記録もテストごとの使い捨て。別ボリュームの経路は使い捨てボリュームの上(→ [02](02-project-and-build.md#テストターゲットqooviewertests)) |

## 帯と操作列の見た目(2026-09-13、ユーザー指示)

- 帯の切り替えは**「ファイルブラウザ」と文字で出す**ボタン(先頭に小さなフォルダのアイコン)。ライブラリのチップと同じ形・地で、
  **幅は文字に合わせる**(チップの固定幅にしない)。アイコンだけのボタンは、何に切り替わるのか読めなかった。
- 切り替えボタンとライブラリの並びの間、帯の下、ツリーと右ペインの間は **`WelcomeSeparator`**(文字色 28% の 1pt の線 +
  `.panelOutlinedContent()`)。標準の `Divider`(`separatorColor`)はすりガラスの上で薄く、境目が読み取りにくかった。
  帯の下の線は本棚のときも同じ。右ペインの中(操作列の下・パスバーの上)は標準の `Divider` のまま。
- アイコンの大きさのスライダーは**アイコン表示のときだけ出し、列の左端(リスト表示ボタンの左)に置く**。列は右端に揃えてあるので、
  出し入れしても表示切替・並べ替えのボタンが動かない。検索欄は `WelcomePaneHeaderLayout` が行の中央に置くので動かない。

## 操作列の中央と検索(2026-09-13、ユーザー要望)

- 行の中央は**いまのフォルダの名前**(パスの綴りのまま。`/` だけは起動ディスクの名前、コンピュータは「コンピュータ」)。
  すりガラス面に直に置く文字なので `.panelOutlinedContent()`。body でファイルシステムに問い合わせない(`displayName(atPath:)` は使わない)。
- 検索は右端の虫眼鏡のボタン。押すと幅 200 の欄に広がって焦点が入る。**欄が空のまま焦点が外れたら**(他をクリック・
  ✕ で消してから外す・フォルダを移って空になった)ボタンへ戻る。Esc は文字を消してボタンへ戻す。文字が入っている間は欄のまま。
  Esc は `WelcomeSearchField(onEscape:)` で**欄そのものに**付ける(外側の `.onExitCommand` には欄が Esc を受けて届かなかった。実測)。

## 「移動」メニュー(2026-09-13、ユーザー要望)

ファイルブラウザが出ている間(`MenuCheckmarkState.fileBrowserNavigation` が nil でない間)、「移動」メニューの中身が
`FileBrowserGoMenuItems` に入れ替わる。**この機の Finder の「移動」メニューを AX で読んだ並びとキー**:
戻る ⌘[ / 進む ⌘] / 上の階層 ⌘↑ / 起動ディスクを選択 ⇧⌘↑ ― 書類 ⇧⌘O / デスクトップ ⇧⌘D / ダウンロード ⌥⌘L /
ホームフォルダ ⇧⌘H(⌥ でライブラリ)/ コンピュータ ⇧⌘C / アプリケーション ⇧⌘A / ユーティリティ ⇧⌘U ― フォルダへ移動… ⇧⌘G。

- 置かないもの(qooViewer に無い機能。ユーザー指示): 最近の項目・最近使ったフォルダ・AirDrop・ネットワーク・iCloud Drive・共有・
  サーバへ接続、「内包しているフォルダ」の ⌥ / ⌃ の代替。
- 標準の場所は**実際のホームフォルダ**の下(`FileBrowserStandardLocation`)。開く前に触って確かめない(TCC の引き金になる)。読めなければ
  右ペインの「アクセスを許可…」、書類・デスクトップは TCC の確認も出る。
- 「フォルダへ移動…」(`FileBrowserGoToFolderSheet`): `/` か `~` で始まるパスだけ。`~` は実際のホームフォルダに読み替える。
  フォルダが無ければシートを閉じずに知らせる。読む権限は確かめない。
- 項目の数が変わるのは本を開く・閉じる・本棚と切り替えるときだけ(メニューを開いている最中には起きない)。
- ほかのメニューのファイルブラウザの項目(2026-09-15): ファイルメニューに開く ⌘↓・このアプリケーションで開く・名前を変更・ゴミ箱に入れる ⌘⌫・
  圧縮・展開・よく使う項目に登録、編集メニューにここに項目を移動 ⌥⌘V・検索 ⌘F、表示メニューに表示形式・並べ替え・拡大/縮小・表示する列、
  「ホーム」メニューにコレクションを作成・コレクションに登録。可否は右クリックと同じ判定。割り振りとキーの振り分けは
  [09](09-ui-and-windows.md#メニューバーのホーム画面の項目)。

## フリックとサイドボタンでの戻る / 進む(2026-09-21、ユーザー要望)

トラックパッドの左右フリックとマウスのサイドボタンで、履歴の前後のフォルダへ移る。判定は `FileBrowserNavigationGesture` /
`FileBrowserSwipeTracker`(画面に依らない。テストあり)、イベントを受けるのは `FileBrowserNavigationGestureMonitor`
(`FileBrowserPane` に `.fileBrowserNavigationGestures` で 1 つ)。操作は一覧のキー(⌘[ / ⌘])と同じ口
(`FileBrowserEditResponding.perform`)へ渡すので、戻り先が無ければ何も起きない。

- **向きはブラウザ(Safari・Chromium)と同じ: 中身が右へ動く向き = 戻る。**
  - 2 本指: 「ページ間をスワイプ」が 2 本指のとき、その操作は `.swipe` ではなく `.scrollWheel` の並びで届く(ビューアの調査。
    [09](09-ui-and-windows.md))。指が触れてから離れるまでの `scrollingDeltaX` / `Y` を積算し、**離れたときに 1 回だけ**判定する
    (正 → 戻る、負 → 進む)。`scrollingDeltaX` には「ナチュラルなスクロール」が織り込まれているので反転しない。
  - 3 本指 / 4 本指: `.swipe` の `deltaX` が正 → 戻る、負 → 進む(Chromium の `swipeWithEvent:` と同じ)。
  - マウス: ボタン 3 → 戻る、ボタン 4 → 進む(ドライバ無しのマウスが送る番号)。押し下げを同じウインドウで見たボタンを離したとき。
    ドライバがボタンを ⌘[ / ⌘] などのキーへ割り当てている場合は、そちらのキーとして届く。
- しきい値は横 20pt 以上かつ横 > 縦 × 2。ビューアのページ送り(横 10pt、横 > 縦)より厳しいのは、誤って移動すると一覧ごと変わるため。
- **横にスクロールできる一覧の上では、端にいるときだけ。** リスト表示は列が収まらないと横にスクロールする。フリックを始めた時点で
  ポインタの下の `NSScrollView` がその向きにまだスクロールできるなら移動しない(AppKit のスワイプ追跡と同じ約束)。
- システム設定の「ページ間をスワイプ」がオフでも 2 本指は効く(ビューアのフリックと同じ扱い)。ビューアの環境設定
  「トラックパッドのフリックでページを送る」(`treatTrackpadFlickAsWheel`)とは連動しない。設定項目は無い。
- 受け取る範囲は**そのウインドウ全体**(ツリーや操作列の上でも。Finder と同じ)。ペインが出ている間だけモニタを付けるので、
  本を開いている間・本棚の間は働かない。シートが出ている間(`attachedSheet`)も働かない。
- イベントは消費しない(一覧のスクロールや `FileBrowserNameClickRename` の押し下げの監視をそのまま働かせる)。例外は、移動を起こした
  フリックの**慣性のぶん**だけ ―― 通すと、移った先の一覧が勢いで横へ流れる。
- 実機で確かめたこと(2026-09-21): マウスのサイドボタンでの戻る / 進む(ユーザー確認)。フリックの向きとしきい値は実機の報告待ち
  (合成イベントでは送れない。判定の規則はテストで固定してある)。

## ファイルブラウザ機能の ON/OFF(2026-09-21、ユーザー要望)

環境設定「一般」▸「ホーム」の **「ファイルブラウザを有効にする」**(`AppPreferences.fileBrowserFeatureEnabled`、既定 ON)。
「ライブラリを有効にする」([14](14-library-collections.md#ライブラリ機能の-onoff2026-09-21ユーザー要望))と対の設定で、作りも同じ
(実行時に切り替わる・保存したものは消さない・起動時の値は init へ、実行中の切り替えは `AppStores` が購読して伝える)。

### ホームの形は 2 つの設定の組で決まる(`WelcomeLibraryState.constrained`)

| ライブラリ | ファイルブラウザ | ホーム | `mode` |
|---|---|---|---|
| ON | ON | 帯(切り替え + ライブラリ)と、本棚かファイルブラウザ | 選んだほう(保存する) |
| ON | OFF | **ファイルブラウザを足す前の形(v1.50〜v1.56)**: 帯の左端は切り替えのボタンの代わりに**「本を開く…」「履歴から開く」**(`WelcomeTopBar.openButtons` / `RecentBooksPopover`)、区切り、ライブラリ、「＋」。中身は本棚 | `.shelf` に固定 |
| OFF | ON | ファイルブラウザだけ(帯なし) | `.browser` に固定 |
| OFF | OFF | **本棚を足す前のウェルカム画面**(`ClassicWelcomeView`: 「開く…」・ドロップの案内・最近開いた本 10 件。2026-09-09 までの `WelcomeView` を git から戻したもの) | `.classic` |

- `.classic` は選べるモードではない。`mode == .shelf` / `.browser` を見ている場所(メニューの値・ウインドウのタイトル・`ContentView.isFileBrowserShown`)が、
  どちらも出ていないときに自然に偽になるよう独立した値にした。押し込まれたモードは保存しないので、両方 ON へ戻すと前に見ていたほうへ戻る。
- 帯の 2 つのボタンは 2026-09-13 のコミット `00e1e89`(v1.60 に入った)で、左端をファイルブラウザへの切り替えに譲るために撤去したもの。
  最初はこれを戻し忘れていた ―― 「ファイルブラウザを入れた直前のコミット」だけを見て、同じ日の準備のコミットを見落とした(ユーザー指摘
  2026-09-21)。当時のままの実装を git から戻してある: ラベルに同じ幅を与える(ボタンではなく)、`.panelControlWell()` の溝 +
  ラベルの `.panelOutlinedContent()`、シークレットウインドウでは「履歴から開く」が淡色、ポップオーバーは履歴の全件で行の右クリックは
  サイドパネルの「履歴」と同じ。違いは、出すかどうかの設定(`showRecentFilesOnWelcome`)が無いので常に出すことと、⌘O を付けないこと。
- `ClassicWelcomeView` の当時との違い: 「最近開いた本」の列を出すかの設定は 2026-09-13 に撤去済みなので常に出す(シークレットウインドウでは出さない)。
  「開く…」のボタンに ⌘O を付けない(ファイルメニューが持つ)。背景とすりガラス面は `WelcomeView` が敷く。列幅の計算
  (`WelcomeQuickOpenWidth`)とそのテストも一緒に戻した。

### OFF の間に消える項目

- ホームの帯の「ファイルブラウザ」ボタン、「ホーム」メニューの「ファイルブラウザ」・「コレクションを作成」「コレクションに登録 ▸」
  (ファイルブラウザの選択が相手)・「自動リネームの設定…」。**両方 OFF なら「ホーム」メニューごと出さない**(条件付きの `CommandMenu`)。
- ファイルメニューの「新規フォルダ」と選んだ項目の群(`FileBrowserFileMenuItems`)・「ファイルブラウザで開く」、編集メニューの「ここに項目を移動」、
  表示メニューの表示形式と列(`HomeViewMenuItems`。両方 OFF なら中身なし)。「検索」は本棚にも効くので、両方 OFF のときだけ消える。
  「移動」メニューはファイルブラウザが出ている間しか入れ替わらないので、何もしなくても本のほうのまま。
- **「ファイルブラウザで開く」の 9 箇所**(ビューア・ページ一覧・サイドパネルの 4 つ・ライブラリのツリー・コレクションの中): 環境値
  `RevealInFileBrowserAction.isFeatureEnabled` を見て項目ごと出さない。入り口(`AppState.showInFileBrowser`)でも断る。
- 環境設定の「ファイルブラウザ」のタブはそのまま(設定は残っているので、OFF の間も変えられる)。**「自動リネームの設定…」のボタンだけは淡色**
  (自動リネームは止まっている。ここは項目を消せるメニューではなく設定の並びなので、消さずに押せなくする)。
- **「自動リネームの設定」ウインドウ**: 「ウインドウ」メニューに自動で並ぶ項目を `.commandsRemoved()` で落とし(`Window` シーンは宣言するだけで
  並ぶ。`SceneBuilder` は条件分岐できないので ON の間も並べない ―― 入り口は「ホーム」メニュー・右クリック・環境設定にある)、OFF にした時点で
  開いていたウインドウは自分で閉じる(`AutoRenameSettingsWindow` の `onChange(of: fileBrowserFeatureEnabled, initial: true)` →
  `closeIfFileBrowserIsOff`)。**シートが付いている間の `dismissWindow` は何も起こさない**(`.sheet` の `onDismiss` から呼んでもまだ早い。どちらも
  2026-09-21 の実機)ので、先にシートを下ろし、`NSWindow.attachedSheet` が nil になるのを待ってから閉じる。`.commandsRemoved()` は開いている間のメニュー下端のウインドウの一覧からも外してしまうので、ウインドウの側で
  `isExcludedFromWindowsMenu = false` に戻す(載るのは開いている間だけ。2026-09-21 の実機)。最初の版はこの 3 つが抜けていて、OFF の間もウインドウへ届き、そこの「アクセスを許可」や移動の提案の「更新」から
  自動リネームが動き出した(2026-09-21 の監査の F1)。
- 淡色ではなく消すのは、ライブラリと同じ理由 ―― 機能そのものが無く、設定は環境設定ウインドウでしか変わらない(メニューを開いている最中に項目の数は変わらない)。

### OFF の間に止まる仕事・止めない仕事(`AppStores.applyFileBrowserFeature`)

| 止まる | どこで |
|---|---|
| **自動リネーム**(よく使う項目の下の FSEvents の監視・走査・名前の変更) | `AutoRenameService.stop()` / OFF で起動したら `start()` しない。規則を作る・止める入り口は OFF の間どれも消える・押せなくなる(上の節)ので、画面が無い間に裏で名前を変え続けない。ON へ戻すと `start()` が全部を走査し直す |
| よく使う項目の中の動画のサムネイルの先回り | `FileBrowserVideoThumbnailWarmer.connect` が設定を購読している |
| ウインドウごとの一覧の読み込み・FSEvents・サムネイル作り | ペインが画面に出ないので始まらない(`FileBrowserState.activate` はペインの onAppear、`FileBrowserThumbnailProvider` は頼まれたぶんだけ) |

**止めないもの**: 置き換えの退避の復旧(`ReplaceBackupRecovery`。前回の操作が途中で落ちていたら利用者のファイルを元へ戻す)、アプリ自身が
ファイルを動かした知らせとよく使う項目の付け替え(サイドパネルのフォルダブラウザも使う)。よく使う項目・規則・ログ・サムネイルのディスクキャッシュは消さない。

**`AutoRenameService.stop()` は「実行中に止めて、また動かせる」こと**(2026-09-21 の監査の F1・F2)。この設定ができるまで `stop()` はテストと
終了時にしか呼ばれず、次の 3 つが抜けていた:
- **止まっている間に外から呼ばれる口が `isStarted` を見ていなかった。** `refreshAvailability()` は設定ウインドウからも直に呼ばれ、パスの末尾が
  監視を張り直して走査を予約した。いまは `refreshAvailability` / `refreshAvailabilitySoon` / `updateWatcher` / `handle` / `scheduleRun` /
  `startRunIfNeeded` / `scheduleRecheck` / `readOnlyDidChange` の入口がどれも `isStarted` を見る。
- **取り消した Task の変数を nil に戻していなかった。** 取り消された Task は自分の後始末(`self.runScheduled = nil`)を通らずに抜けるので、
  走査の予約から 0.3 秒のあいだに OFF にすると、`scheduleRun` の `guard runScheduled == nil` が弾き続け、ON へ戻してもアプリを終えるまで走査しなかった。
- **走っている最中の Task が止まらなかった。** `FileIO.perform` や名前の変更の await から戻ってきた側が、下ろした監視を張り直し、見直しを予約し直した。
  `stop()` のたびに進む世代番号(`generation`)を Task が作られたときに控え、await から戻るたびに `isCurrent(generation)` で確かめて、古ければ何も
  触らずに抜ける(`CollectionCoverExtractor.runGeneration` と同じ形)。取り消しを見るだけでは足りない ―― 古い Task の後始末が、`stop()` → `start()` の
  後に作られた新しい Task の変数を消してしまう。進行中の名前の変更 1 件は止められない(その 1 件の実行ログは書く)。

`stop()` は覚えている状態も捨てる(待ち行列・書き終わりの観測・`missingSince` ―― 残すと、再開の最初のパスで「1 秒置いて確かめ直す」を飛ばして対象を
OFF にしうる)。公開している値(`availability`・`targetsAwaitingConfirmation`・`moveSuggestions`・`isPausedForReadOnly`)も空にする。規則と実行ログには触らない。

**OFF にした瞬間に進行中だったもの**(監査の §4): コピー・移動の最中に OFF にすると、操作は最後まで続く(`FileBrowserOperations` は
`FileBrowserState` の持ち物で、ペインが消えても生きている)。**進捗の帯と中止ボタンは、ペインが出ていない間はホームの下端へ引き継ぐ**
(`WelcomeView` が `mode != .browser` の間だけ `FileBrowserProgressBar` を置く。動いていなければ何も描かない)。最初の版は帯がペインごと消え、進み具合も
中止の手段も無くなった ―― 設定を OFF にしたときだけでなく、操作の最中に本棚へ切り替えたときも同じだった。実機(2026-09-21): ボリュームをまたぐ
コピーの最中に OFF にすると本棚の下に帯が出続け、帯の中止で作りかけの項目が片付く。名前の編集中に OFF にすると、
編集は捨てられて名前は変わらない(実機)。**ウインドウに出した確認・一括リネームのシートは残るが、押しても実行しない**: `FileBrowserOperations.isReadOnly` は
「ファイルブラウザ機能が OFF」も断る理由に数え、操作を始める前の確認・シートは `asking` を通して、出している間に断る状態(機能 OFF・読み取り専用)へ
切り替わっていたら「キャンセル」扱いにする(最初の版は OFF の後に押すと実行された。実機で確認して直した)。切り替えの**前に**受け付けて並んでいた操作と、
コピー・移動の途中の衝突の確認は、これまでどおり最後までやる(半分だけ済んだ状態で止めない)。ウインドウごとの `FileBrowserState` とその購読
(アクティブ化・キーウインドウ・ボリューム・`FileSystemChangeCenter`・カット)は OFF でも残るが、そのたびの仕事はカットの検証とペーストボードの
`changeCount` の比較だけ。サムネイルのディスクキャッシュの起動時 1 回の刈り込みは設定に関わらず走る(キャッシュは消さない約束なので、上限も守る)。

**抜け漏れの監査(2026-09-21、修正済み)**: 調べた範囲・指摘・直した内容は [plans/feature-toggle-audit.md](plans/feature-toggle-audit.md)(§7 が修正の記録)。

## 効果音(2026-09-13、ユーザー要望。qooLibrary と同じ)

`SystemSoundPlayer`(Services/FileOperations)が macOS 同梱のシステムサウンドを鳴らす。**鳴らすのは `FileCommandStack` の 1 箇所**
(`FileCommand.completionSound`)。

| 操作 | 音 |
|---|---|
| コピー・移動(ペースト) | `system/Volume Mount.aif` |
| ゴミ箱に入れる | `dock/drag to trash.aif`(`finder/move to trash.aif` は Finder が使っていない) |
| 完全削除 | `finder/empty trash.aif` |
| 名前の変更・新規フォルダ | 鳴らさない |

完全に済んだときとやり直しで鳴らし、**取り消し・部分的な成功・中止では鳴らさない**。まとめた操作は最初に音を持つ子の 1 回だけ。
システム設定「ユーザインターフェイスのサウンドエフェクトを再生」に従い、アプリに設定は持たない。テストホストの中では鳴らさない。

## テストホスト

テストは実物のアプリの中で走り、ウインドウも出る。`ContentView` は `WelcomeLibraryState(restoresMode: !RuntimeEnvironment.isRunningTests)`
で、**テスト中は保存したモードを読まずに本棚で始める**(保存値は書き換えない)。以前は Debug の設定がファイルブラウザだと、テストの
たびにウインドウが実際のホームフォルダを読みに行っていた(共有の状態に触れる。TCC の確認の引き金にもなりうる)。→ [12](12-verification-and-debugging.md#テスト中に出る虹色のカーソル)

## 一覧の読み込み

- **`FileIO.perform` の上で `FileManager.enumerator(… [.skipsSubdirectoryDescendants, .skipsHiddenFiles, .skipsPackageDescendants])`**。
  `DirectoryBrowser.listingAsync`(`Task.detached`)は流用しない ―― 応答しない共有で協調プールが塞がる(→ [03](03-architecture.md#並行処理の規約))。
  列挙の入口の失敗はエラーハンドラで拾って投げ直し、空のときだけ実在と読み取り権限を確かめる(読めないフォルダを空と取り違えない)。
- **全ファイルを出す**(サイドパネルは本だけ)。**子フォルダの中を見ない**(三角も件数も出さない)。
  1 フォルダを開くたびに子の数だけ列挙が増えるうえ、`~/Library` の保護領域に降りた瞬間に TCC のダイアログが出るため。
  画像フォルダかどうかは、本として開く側の操作(下の「移動の規則」)を選んだときに 1 回だけ `ShelfFolderResolver.role` で調べる。
- パッケージ(`.app` など)は 1 項目。「フォルダを上に」ではファイルの側に並ぶ(Finder と同じ)。
- 並べ替えの比較はサイドパネルと**同じ実装**(`FolderBrowserSort.sorted`、`FolderBrowserSortable`)。
  「フォルダを上に」だけは環境設定「ファイルブラウザ」の独立した設定(サイドパネルの「並び順」とは別)。
- **並べ替えの基準と向きはサイドパネルのフォルダブラウザと同じ 1 つの設定**(`AppPreferences.folderBrowserSortKey` / `folderBrowserSortDirection`。
  2026-09-14、ユーザー要望)。`FileBrowserState.sortKey` / `sortDirection` はそれを読み書きする計算プロパティで、`observePreferences` が
  変更を購読して並べ直す(サイドパネル・他のウインドウで変えたとき)。`resort` は並びが変わらなければ一覧を差し替えない(自分で書いた変更を
  購読からもう一度受けるため)。以前の `qooViewer.fileBrowser.sortKey` / `sortDirection` は読まない(サイドパネルの値にそろう)。
- 左のツリーのサブフォルダも、設定でこの並びに合わせられる(下の「ツリーのサブフォルダの並び」)。
  「本の移動をブラウザの並び順に合わせる」が ON なら、ファイルブラウザで変えた並べ替えも前後の本の順に効く。
- 絞り込み(検索欄)は現フォルダの中だけ。照合はホームの検索と同じ `LibrarySearchQuery`。
  変わったら見えなくなった項目を選択から外す。フォルダを移ったら空にする。
- **世代番号で古い結果を捨てる**(速く移動したとき)。選択は残っている項目のぶんだけ保つ。
- 失敗の分類: 読めない → `needsAccess`(中央に「アクセスを許可…」)、無い・ボリュームが外れた → **残っているいちばん近い祖先へ移る**
  (外れたボリュームならコンピュータへ)。
- 「コンピュータ」(`currentFolder == nil`)は `MountTable` から作る。`/` と `/Volumes/` 直下のうち `MNT_DONTBROWSE` でないものだけ
  (`-nobrowse` で付けたディスクイメージは出ない)。ネットワーク越しのボリュームには名前も問い合わせない。
- 表示中のフォルダは `FolderChangeWatcher`(FSEvents)で見張り、**見えている間だけ**。アプリのアクティブ化とボリュームの着脱でも読み直す。
  読み直すのは**フォルダ自身か直下の項目が変わったときだけ**(`FileBrowserState.changedPaths(_:touchFolderSpelledAs:)`。FSEvents はリンクを
  解いたパスで知らせるので `/private/var` の書き方も持つ)。FSEvents は階層全体のイベントを返すので、以前はホームフォルダを表示している間
  `~/Library` の下の書き込みで 0.3 秒ごとに読み直し、前の列挙を取り消すため、列挙の遅いフォルダの配下で書き込みが続くと一覧が出なかった
  (2026-09-14 の監査)。読み込み中に届いた変更は取り消さずに、読み終えてから 1 回だけ読み直す。ネットワーク上のフォルダは見張らない
  (FSEvents が飛ばず、応答しない共有では生成が 30 秒塞ぐ。ツリーも同じ)。見張る場所を入れ替えるときの `sinceWhen` は、止めた時点の
  システム全体のイベント ID(以前は古いストリームが最後に受けた ID で、`FullHistory` のため移った先の古い履歴が再生された)。
- 種類(「種類」列)は拡張子ごとに 1 回 LaunchServices へ問い合わせる。**文字列は OS の言語**(アプリの表示言語には従わない。LaunchServices の説明文を他の言語で引く手段が無い)。

## アプリ自身の変更の知らせ(`FileSystemChange`、2026-09-19)

監査([plans/fs-ui-consistency-audit.md](plans/fs-ui-consistency-audit.md))で見つけた食い違いの大半は、**アプリ自身がアクティブなまま
ファイルを動かすようになったのに、それをアプリのほかの部分へ知らせる口が無い**ことから出ていた(棚・履歴・サイドパネルの契機は
「アクティブ化」だけ、別のウインドウの一覧は FSEvents 頼みでネットワーク上では届かない、祖先の名前の変更は FSEvents でも分からない)。

- **出す場所は `FileOperationService` の入り口 1 か所**(`changeObserver`)。実行・取り消し・やり直し・自動リネームは必ずここを通るので、
  経路ごとに出し忘れない。中身は「移った・名前が変わった項目の新旧のパス(起きた順)」「無くなった項目」「できた項目」。アプリの
  `FileOperationService.shared` だけが `FileSystemChangeCenter.shared` へ繋ぎ、テストの作るインスタンスは繋がない。
- **`FileSystemChangeCenter`** は続けて届いた知らせを起きた順のまま 1 つにまとめ(80ms。一括リネームは 1 件ごとに届く)、メインアクターで配る。
  操作を終えた `FileBrowserOperations` は `flush()` で待たずに配らせる。テストの中では状態ごとに別の箱(並んで走るテストの操作で読み直されない)。
- 受ける側:
  - すべての `FileBrowserState`(`handleFileSystemChange`): 戻る/進む・選択・表示中のフォルダを新しいパスへ付け替え、**表示中のフォルダ自身か
    祖先の名前が変わった・移ったなら、退避せずに付いていく**。中身が変わっていたら読み直し、ツリーにも知らせる(ネットワーク上ではこれが唯一の知らせ)。
    自分の操作が走っている間は読み直さない(済んだ時点で `didChangeFileSystem` が読み直す)。
  - `SidePanelBrowserState`(→ [09](09-ui-and-windows.md))、`FavoriteLocationStore.relocate`(よく使う項目のパス)、`FileCutClipboard.forget`。
  - `AppStores.handleFileSystemChange`: 保存データの付け替え(→ [06](06-persistence.md#移動リネームへの追従))が済んでから、棚・履歴・お気に入りの実体確認。
- アプリの**外**での変更は今までどおり FSEvents とアクティブ化。右ペインの見張りは 2026-09-19 に 3 つ直した: 直下のフォルダの中で項目が
  増減したら読み直す(そのフォルダの変更日と変更日順の並びが古いままだった。書き換えだけでは読み直さない)、イベントがあふれた知らせは
  表示中のフォルダの上でも下でも読み直す、初めて張るストリームは一覧を読み始める前のイベント ID から(`FolderChangeWatcher.watch(_:startingAt:)`)。

## 選択・スクロール先は「パス」で持つ

列挙はフォルダの URL を末尾 `/` 付きで返し、外から渡される URL には付いていないことが多いので、URL の `==` では
同じ項目が別物になる。`FileBrowserEntry.id` = `url.path` で持ち、フォルダは `FileBrowserState.folderURL(_:)` で揃える。

## 移動の規則

- ダブルクリック / Return(リストは ⌘↓ も)= フォルダなら中へ移動、本と画像は qooViewer で開く
  (`AppState.open(urls:)`。複数選択は `BookOpenRequest` の規則)、それ以外は既定のアプリ。記号リンクは実体を解いてから。
  右クリック・メニューバーの「開く」も同じ(→「淡色の条件は『押して何かが起きるか』」)。
- 画像フォルダ(`ShelfFolderResolver.role` が `.book`)だけは、環境設定「ファイルブラウザ」の「画像フォルダを開くとき ▸ ダブルクリック / リターンキー」
  (`fileBrowserImageFolderOpenAction`、**既定「フォルダを開く」** = 段階 3 からの決まりのまま。2026-09-14、ユーザー要望)で
  「ビューアで開く」を選ぶと本として開く。**右クリックの「開く」は常にその反対**(`FileBrowserImageFolderOpenAction.opensAsBook(fromMenu:)`)
  ―― どちらの設定でも、もう片方の開き方が右ペインから届く所に残る。
  - 中へ移動する側は中を調べずにすぐ移動する(既定のダブルクリックに待ちを足さない)。本として開く側は `FileIO` で調べ、本でなければ中へ移動する。
    調べている間に別のフォルダへ移っていたら、後から引き戻さない。
  - 左のツリーには効かない(行を選ぶ = そのフォルダへ移る)。新規タブ/ウインドウで開くのも設定に関わらず下の規則のまま。
- 上へ = 元いたフォルダを選んで見える位置へ。ボリュームのルートの上はコンピュータ。
- 戻る = **戻り先が直前のフォルダの親なら、そのフォルダを選ぶ**(上へと同じ見え方)。
- ツリーの行を選ぶと右ペインがそこへ移る。右ペインで移動したら、その行が見えていれば選ぶ(見えていなければ選択を外す)。
- パスバーの成分をクリックすると、そのフォルダ(先頭はコンピュータ)へ。

## 新しいタブ・ウインドウで開く(`WindowContentRequest`)

本のウインドウの提示値を `BookOpenRequest` から `WindowContentRequest`(`.book(BookOpenRequest)` / `.browse(folder:selecting:nonce:)`)に広げた。
`BookWindowOpener.openFolder(_:selecting:to:from:openWindow:)` が開き、受け取った `ContentView` は `welcomeLibrary.mode = .browser` +
`fileBrowser.prepare(showing:selecting:)`。`selecting` は「ファイルブラウザで開く」でファイルを示すときだけ入る(段階 8)。

- **`browse` は開くたびに `nonce` を変える。** `openWindow(id:value:)` は等値の値のウインドウを前面に出すだけなので、
  同じフォルダを 2 枚で見られなくなる(本はそれを二重に開かない砦として使っている)。状態復元は無効なので値は残らない。
- 通常ウインドウは `"book"` ではなく `"normal"` で開く(`BookWindowGroup.id(forBrowsing:inheritingFrom:)`)。
  `"book"` は `.contentSize` で、ホームから始まったウインドウで本を開いた瞬間にフレームが作り直される。
- 重複の判定はしない。セキュリティスコープは本と同じ 10 秒の受け渡し(`SecurityScopedHandoff`)。
- 右クリックの「新規タブ/ノーマル/シークレットで開く」は、画像フォルダなら本として、それ以外のフォルダはファイルブラウザとして開く。

## AppKit とすりガラス面

リストとツリーは AppKit(決定事項 Q3。SwiftUI の `Table` の退行を避け、type-select・列幅の保存・段階 4 のレスポンダチェーンを標準で得る)。
面は `PanelSurface.welcome` なので、SwiftUI の輪郭修飾子が届かない部品を自前で描く(`FileBrowserAppKitParts.swift`):

| 部品 | 扱い |
|---|---|
| 行の文字・グループの見出し | `FileBrowserOutlinedTextFieldCell`(反対色の文字を上下左右にずらして後ろへ。選択中は掛けない) |
| 選択の地 | `FileBrowserRowView`(角丸 + 反対色の縁)。**強調中(キーウインドウで一覧が操作先)はアクセント色に白い文字、それ以外は灰色の地にふつうの文字**(macOS 標準。`SelectionEmphasis`、下の「選択の強調」) |
| ドロップ先の行 | `FileBrowserRowView.drawDraggingDestinationFeedback`(アクセント色の薄い地 + 反対色の縁。アイコン表示のセルと同じ。AppKit 標準の強調は縁が無く面の色に溶ける) |
| 開閉の三角 | `FileBrowserOutlineView` がボタンの絵を輪郭入りに焼き直す(**無いと、ダーク+白100%で三角が消えた**。実測) |
| 「＋」 | `FileBrowserOutlinedIconButton` |
| 列の見出し | `FileBrowserTableHeaderView` が不透明な地を敷く(**既定の見出しは半透明で、ダーク+白100%で文字ごと消えた**。実測) |
| アイコン | 種類のアイコン(色付きの絵)・本の絵なので掛けない |
| 「アクセスを許可…」 | `.borderedProminent`(不透明なアクセント色)。`.panelControlWell()` ではライト+黒100%で文字が読めなかった(実測) |
| パスバー | `controlBackgroundColor` の帯(不透明) |

アイコン表示は `NSCollectionView`(2026-09-15 に SwiftUI の `LazyVGrid` から置き換えた。下の「アイコン表示を AppKit にした理由」)。セルの
`FileBrowserIconCellView` が同じ輪郭を描く: 名前は未選択なら `FileBrowserOutlinedTextFieldCell`、選択中はアクセント地(強調中でなければ灰色の地)+ 反対色の縁、選択中の
アイコンの薄い地とドロップの受け口のアクセント地は反対色の縁で囲む(SwiftUI の `.panelOutlinedFrame(in:)` / `.panelOutlinedAccent(in:)` 相当)。

### 選択の強調(2026-09-19)

選択・「いまここ」の強調は **macOS 標準に合わせ、ウインドウが前(キー)で、その一覧が操作先のときだけアクセント色、それ以外は灰色**
(`Views/SelectionEmphasis.swift`)。それまでは面の色に選択が溶けるのを嫌って常にアクセント色にしていたが、左のツリーだけは `.sourceList`
形式で AppKit が後ろのウインドウで文字を淡くするので、**左ペインの文字だけが灰色になり、右ペインと選択の色はそのまま**という食い違いが出た
(ユーザー報告)。標準の側へ揃え、灰色の選択にもアクセント色のときと同じ反対色の縁を掛けて、面の色に溶ける件を防ぐ。

- リスト・ツリーの行: `NSTableRowView.isEmphasized`(AppKit が「キーウインドウかつ表がファーストレスポンダ」で立てる)。文字の白/ふつうは
  `interiorBackgroundStyle` の既定に任せる。**ツリーとリストの両方が選択を持つので、操作先でない側は灰色になり、キー入力の行き先が見える。**
- アイコン表示: `NSCollectionView` には同じ仕組みが無いので、`FileBrowserCollectionView.isSelectionEmphasized` をウインドウのキーの出入りと
  ファーストレスポンダの出入りで計り直す(名前の編集中も操作先に数える)。
- SwiftUI(ホームの上の帯のチップ・ファイルブラウザの切り替え・編集トグル・表示切替・タイルとカバーの選択の枠と印、サイドパネルの
  モード切り替え・現在の行): `@Environment(\.appearsActive)`。グリッドのように大きな `body` では読まず、枠・重ねだけの小さなビュー
  (`SelectionEmphasisBorder` / `SelectionEmphasisHighlight` / `SelectionEmphasisReader` / `.selectionEmphasisForeground`)が自分で読む。
- **変えないもの**: ドロップの受け口(ドラッグを受けるウインドウは後ろにあるのがふつうで、Finder も後ろのウインドウでアクセント色の強調を出す)、
  状態の色(残っているページ・登録済みのメタデータ・開いている本の印など ―― 選択ではない)、ページ一覧の現在のページの枠(色を環境設定で選べる)。
- カットしたフォルダはツリーの行も淡くする(リスト・アイコン表示と揃える)。

**アイコンは種類だけで引く**(`FileBrowserIconProvider`)。`NSWorkspace.icon(forFile:)` は到達できない共有で 30 秒ブロックし、
フォルダのカスタムアイコンを読みにデスクトップ・書類へ触れると TCC のダイアログが出る。本と画像の絵はアイコン表示だけに出す(→「サムネイル」)。

`NSPathControl.url` は設定しない(メインスレッドで各成分の `realpath` とアイコン取得が走る。FB22294400)。`NSPathControlItem` を自分で組む。

## ツリーの三角(2026-09-13、ユーザー要望)

子を読むとき(行を開いたとき)に、それぞれの子に**直下のサブフォルダがあるか**を `DirectoryProbe.hasSubdirectory` で 1 回だけ調べ、
無い行には三角を出さない(qooLibrary の同名の関数を写したもの)。段階 3 では TCC と往復を理由に調べていなかったが、次のように避けられる。

- `readdir` を最初のサブフォルダで打ち切る。数える規則は一覧と揃える(`.` で始まる名前・`UF_HIDDEN`・パッケージ・記号リンクは数えない)。
- **TCC の保護下の場所はパスの文字列だけで除外**(`protectedPrefixes`。`~/Library` の他アプリのデータ・File Provider の置き場に、
  **デスクトップ・書類・ダウンロードを足した** ―― ホームフォルダの読み取りを許可した状態でホームフォルダを開くと、入ってもいない 3 つの中を読んで
  ダイアログが出るため)。**ネットワーク越しの場所はマウント表で除外**(子の数だけ往復しない)。
- 調べていない・調べられない行(ボリューム・ホームフォルダ・よく使う項目の根、除外した場所、読めない場所)は `nil` で、三角を出す
  (誤って消すと行き止まり、誤って出しても開いたら空、の非対称)。
- 自分の操作のあと(`fileSystemChange`)は、開いている行を読み直し、閉じている行の三角を調べ直す。**取り消し・やり直しは
  どのフォルダが変わったか分からない**ので `isUnknownScope` で全体を見直す(以前は何も知らせず、取り消しで戻ったフォルダがツリーに
  出てこなかった)。閉じている行の調べ直しは**まとめて 1 本の `FileIO` で順に**行う(1 行ずつ投げると、取り消しのたびに閉じた行の数だけ
  スレッドが同時に立った。2026-09-14 の監査)。
- **Finder など外での変更**(2026-09-14): 開いている行のうちいちばん上のものを FSEvents で見張り(`FolderChangeWatcher(onChangedPaths:)`。
  ファイル単位のイベントのパスを受け取る版)、**変わった項目の親の行とその項目の行だけ**を上と同じ手当てで読み直す。見張る顔ぶれは
  開閉・ボリュームの着脱・よく使う項目の変更・子の読み直しのたびに次のランループでまとめて入れ替える。`/` を見張ると FSEvents が
  `/System/Volumes/Data` を頭に付けて知らせることがあるので外して揃える。FSEvents はネットワークの共有では当てにならないので、
  アプリがアクティブになったときに**共有の上の開いている行だけ**を読み直す。使い捨てボリュームで、シェルからのフォルダの作成・削除・
  別の行への移動が 2 秒以内に出ること、閉じた行に三角が付くことを実機で確認(ホームフォルダの配下と共有では未確認)。
- **グループの見出し(ボリューム・ホームフォルダ・よく使う項目)には開閉の印を出さない**(`shouldShowOutlineCellForItem`、2026-09-14、ユーザー報告)。
  `.sourceList` のグループ行はカーソルを乗せると右端に開閉の印(下向きの矢印)を出してセルを縮めるので、よく使う項目の「＋」に合わせると
  矢印が出て「＋」が左へずれた。グループは常に開いておく(`expandItem(group)`)ので、たたむ手段は無くした。ユーザーの手元で直ったことを確認。

## 現在のフォルダまでツリーを開く(2026-09-14、ユーザー要望)

環境設定「ファイルブラウザ」の「現在のフォルダまでツリーを自動で展開」(`fileBrowserExpandsTreeToCurrentFolder`、**既定 OFF**)。
ON なら右ペインで移動するたびに、現在のフォルダを含む根(ボリューム・ホームフォルダ・よく使う項目)のうち**いちばん深いもの**から親までの行を
1 段ずつ開き、現在のフォルダの行を選んで `scrollRowToVisible` する。道筋は `FileBrowserTreePath`(純粋関数。深さが同じ根は先に並ぶほう、
道筋の 1 段は完全一致を優先して無ければ大小文字を無視)、行を開いて待つのは `FileBrowserTreeView.Coordinator.reveal`。

- **右ペインがそのフォルダを読み終えてから始める**(`isLoading` が下りて `loadError` が無いとき)。読めなかったら開かない。道筋の階層は
  どれも現在のフォルダの祖先なので、右ペインが読めた以上ここで TCC の確認を新しく出さない。
- 子の読み込みは非同期なので、`Node.childrenTask` を待ってから次の段を開く。**途中で別のフォルダへ移った・ツリーの行をクリックした・
  設定を OFF にしたら**世代番号(`revealGeneration`)で残りをやめる。起動直後はボリュームの一覧を読み終えるまで待つ。
- ツリーの行をクリックして移ったときは何もしない。開いていたほかの行はたたまない。三角を消した行(`hasSubfolders == false`)が道筋に
  あれば、三角を戻して開く(右ペインが配下を読めた以上、サブフォルダはある)。
- 隠しフォルダ・パッケージ・記号リンクの先など、ツリーに出ない階層で道筋が切れたら、**その展開で開いた行をたたみ直す**(前から開いていた行は
  そのまま)。選択は外れたまま。以前は途中まで開いたまま残り、現在のフォルダが見えないのに途中の行だけが開いていた(2026-09-14 に変更)。

## ツリーのサブフォルダの並び(2026-09-14、ユーザー要望)

環境設定「ファイルブラウザ」の「サブフォルダを右と同じ順に並べる」(`fileBrowserTreeFollowsListSort`、**既定 OFF** = 従来どおり名前の昇順)。
ON なら、ツリーで開いた行の子を右ペインと同じ `FileBrowserState.sort`(基準・向き)で並べる。

- **根(ボリューム・ホームフォルダ・よく使う項目)の並びは変えない**。ボリュームは起動ボリュームが先頭、よく使う項目はユーザーが並べ替えた順のまま。
- 比較は右ペインと同じ `FolderBrowserSort.sorted` を使うので、右ペインに並ぶフォルダ同士の前後とツリーの並びは必ず一致する。子はフォルダだけなので
  「フォルダを上に」は効かない。フォルダはサイズを持たず種類も同じなので、サイズ・種類で並べたときは名前で決まる(向きは効く)。
- 並べ替えに要る値は子を読むときの `FileBrowserEntry` を `Node.listing` に持たせる。基準・向き・設定が変わったら**読み直さずに**読み込み済みの子を
  並べ直し、並びが変わった行だけ `reloadItem(_:reloadChildren:)` する。同じ `Node` を使い回すので、開いている孫の行は閉じない。
- 並べるのは読み込みの結果を受け取った時点の並び(読んでいる間に基準が変わっても古い順では入らない)。`FileBrowserTreePath` はパスで子を探すので、
  「現在のフォルダまで開く」は並びに関係なく動く。
- **変更日で並べているときは、中身が変わったフォルダの親の行も読み直す**(2026-09-17、ユーザー報告。`reloadExpandedRows`)。中身が変わった
  フォルダは自分の変更日も変わり、親の行の子の並びが変わる。以前は変わったフォルダとその中身の行しか読み直さなかったので、右ペインのフォルダ
  から親の違うサブフォルダ(兄弟など)へファイルをドロップしても、運び先の親の行が並び替わらず、たたんで開き直すまで古い順のままだった
  (操作の `affected` は運び先と運び元のフォルダだけで、FSEvents も運んだファイルのパスしか知らせない)。親は開いている行だけ読み直す
  (閉じた行の三角の有無は変わらない)。作成日は変わらず、フォルダはサイズを持たないので、ほかの基準では足さない。
  実機検証(Debug、使い捨てボリュームの合成名): 修正前のビルドで再現(8 秒待っても並ばない)、修正後はドロップから 1 秒以内に並び替わり、
  シェルでの移動(FSEvents)でも並び替わることを確認。

## アイコン表示を AppKit にした理由(2026-09-15、ユーザー判断)

アイコン表示だけが SwiftUI(`LazyVGrid`)で、リスト・ツリー(AppKit)と同じ機能を別の仕組みで作り直していたので挙動がずれた。ドロップでは
`DropInfo` にドラッグ元が許す操作が無く、他のアプリからの移動を「Finder が最前面のときだけ」と推し量っていた。右クリックは SwiftUI の
`.contextMenu` と AppKit の `NSMenu` の 2 系統で、淡色のサブメニューを押せないボタンで描く回避策が SwiftUI 側だけにあった。選択・帯で選ぶ・
矢印キー・名前の編集・ドラッグの開始が自前で、`LazyVGrid` が画面外のセルの絵を手放さないので帳簿(`LazyCellImageBudget`)で数えて作り直していた。

`NSCollectionView` にしてリストと同じ口に揃えた:

| 役目 | アイコン表示 | リストと共有するもの |
|---|---|---|
| 選択・⌘ / ⇧ クリック・余白からの帯 | `NSCollectionView` の標準(⇧ クリックは範囲ではなく追加。Finder のアイコン表示と同じ) | ―(リストは `NSTableView` の標準) |
| 矢印キー | `FileBrowserState.moveSelection`(`GridKeyboardNavigation`)。起点はクリックで選んだ項目(`setSelectionAnchor`) | ―(標準の矢印キーは独自のレイアウトで右矢印が真下へ移り、下矢印で動かなかった。実機 2026-09-15) |
| type-select | `FileBrowserCollectionView.keyDown` → `FileBrowserState.typeSelect`(`NSCollectionView` には無い) | ― |
| Return / ⌘↓ で開く、⌘⌫ / ⌥⌘V / ⌘[ / ⌘] / ⌘↑、コピー・カット・ペースト | `FileBrowserCollectionView.keyDown` / `copy:` など | `FileBrowserEditCommand.forKey`、`FileBrowserEditResponding` |
| 右クリック | `menu(for:)` で押したセルを控え、`menuNeedsUpdate` で組む | `FileBrowserMenuBuilder`(対象の規則も同じ) |
| 出し口 | `pasteboardWriterForItemAt`、読み取り専用ならコピーだけ | `FileBrowserActions.pasteboardWriter`、`fileBrowserDragSourceMask` |
| 受け口 | `draggingEntered` などを自前で(フォルダのセルならそのフォルダ、ほかは表示中のフォルダ。全体のときはペインの枠) | `FileBrowserActions.dropDecision(for:into:)`(ドラッグ元のマスクを見る) |
| 名前の編集 | セルの名前の欄をそのまま編集できる形に切り替える | `FileBrowserNameField`(実名に差し替えて拡張子の前を選ぶ) |
| 当たり先 | **セル**(`FileBrowserIconCellView.hitTest`)が中の部品を当たり先にしない(編集中の欄だけ通す)。一覧の `hitTest` は上書きしない | `FileBrowserTableView.hitTest` と同じ考え |

- 標準の受け口(`validateDrop` / `acceptDrop`)は使わない。「セルの間へ差し込む」表示を前提にしていて、表示中のフォルダ全体を受け口にする形が無い。
  `draggingEnded` / `concludeDragOperation` は上書きしない(ドラッグ元の終わりの通知が止まる。ツリーの件)。ドラッグ中の端のスクロールも自分で行う。
- 並べ方は `FileBrowserIconLayout`(`NSCollectionViewLayout` の子。同じ大きさのセルを間隔を固定して左上から詰める。本棚の `WelcomeGridColumns` と同じ見え方)。
  中身が少なくても見えている範囲いっぱいまで一覧にする(余白のどこからでも帯・右クリック・ドロップが一覧に届く)。
- 名前は 2 行まで、長い名前は中ほどを「…」で詰める(`FileBrowserIconView.twoLineName`。Finder と同じく両端を残す)。名前は**セルの `draw` で描く**
  (編集欄は編集のときだけ出す)。本文・後ろに敷く反対色の輪郭・2 行に詰める計算がすべて同じ `NSString` の描画と属性なので食い違わない。
  詰める計算は、残す文字の 1 行の幅の合計が 2 行ぶんを明らかに超える長さを測らずに飛ばす(字の幅は 1 字ずつ覚える。3 回目の監査。
  以前は 1 文字ずつ全部を `boundingRect` で測り、ピンチのたびに見えているセルの数だけメインを止めた。結果は変わらないことを 400 通りで確かめた)。
- 名前の編集中は一覧を取り込まないので、**余白へのドロップ・背景のメニューは最後に取り込んだフォルダ(`displayedFolder`)を使い**、編集中に
  表示するフォルダが変わったら打った名前で確定してから取り込む(リストも同じ。3 回目の監査)。セルの絵の依頼は、画面から外れたとき・ビューを
  捨てるときにも取り消す(`prepareForReuse` を通らずに捨てられるアイテムの Task が残っていた)。画面の外に用意されたアイテムは `deinit` で取り消し、
  `didEndDisplaying` は既に別の位置で使い回されたアイテムの依頼を取り消さない(4 回目の監査)。ペーストした項目を選ぶ依頼は、同じフォルダの
  reveal でも捨てる(後の読み直しで利用者の選択を上書きしない)。
- 名前のクリックからの編集は、`mouseDown` で「押す前にその 1 件だけが選ばれていた」「名前の文字の上」「修飾キーなし」「ドラッグが始まらなかった」を
  見て、ダブルクリックの間隔だけ待ってから始める(その間の次のクリック・キー・ドラッグで取りやめ)。
- 絵はセル(`FileBrowserIconItem`)が頼み、使い回されるときに取り消して捨てる。ピンチは `magnify(with:)`。
- ドラッグ中、`NSCollectionView` は運んでいるセルを隠すので、始まった直後に戻す(Finder・リストと同じく元の場所に残す)。
- **実機の検証で見つけて直したもの**(2026-09-15。使い捨てボリュームの合成名の項目で、クリック・⌘ / ⇧ クリック・余白のクリックと帯・矢印キー・
  type-select・右クリック(セル / 余白)・名前のクリックからの変更と Return / Esc / ⌘Z・ダブルクリックでの移動と ⌘[・一覧の中のドラッグ・
  Finder との往復のドラッグ・大きさの変更・読み取り専用モード・ウインドウの開閉 3 回 × 2 巡の `heap`・ダーク + 白 100% の面を確認):
  1. **一覧の `hitTest` で一覧自身を返すと、セルをクリックしても選択されない。** `NSCollectionView` は当たり先のビューからセルを見分ける
     (`indexPathForItem(at:)` が nil を返した)。部品を当たり先にしない処理はセルの側へ移した。
  2. **流し込み(`NSCollectionViewFlowLayout`)の結果の x だけを書き換えると、見えている位置と当たり判定が食い違う**(当たり判定は書き換える前の
     位置で引かれた)。位置を最初から決める独自のレイアウトにした。
  3. **独自のレイアウトでは標準の矢印キーが崩れる**(右矢印で真下へ、下矢印で動かない)。矢印キーは `FileBrowserState.moveSelection`
     (`GridKeyboardNavigation`。一度消したが戻した)で自分で動かし、クリックで選んだ項目を起点にする(`setSelectionAnchor`)。
  4. 名前を `NSTextField` に描かせると、測った 2 行と欄の折り返しが食い違って 3 行目が欠け、輪郭と本文の折り返しもずれて白 100% の面で文字が潰れた →
     セルの `draw` で描く。中略は二分探索だと単語の折り返しのせいで短く詰めすぎたので、長い方から 1 文字ずつ試す(結果は名前と幅ごとに覚える)。
  5. ドラッグ中に元のセルが消えた → 戻す(上)。
  ⇧ クリックは範囲ではなく追加(`NSCollectionView` の標準。Finder のアイコン表示と同じ。SwiftUI 版は範囲だった)。
- ペイン全体の SwiftUI の受け口(`FileBrowserDropDelegate`)は、一覧の外(操作列・トースト)を覆うためだけに残した(覆わないと、断ったドロップを
  ウインドウ全体の「本を開く」受け口が拾う)。

## リストの列(2026-09-14、ユーザー要望)

- **見出しの右クリックで列を出す・隠す**(Finder と同じ)。見出し(`NSTableHeaderView.menu`)に行とは別の `NSMenu` を付け、
  `menuNeedsUpdate` で行のメニューと見分ける。列は今の並び順に、表示中はチェック付き。**名前の列は淡色で隠せない**。
  隠している列は `FileBrowserState.hiddenListColumns`(`Column.rawValue` の集合)。**保存が無いときは作成日だけを隠す**
  (`defaultHiddenListColumns`、ユーザーの判断)。空の配列も保存するので「全部出した」を「保存なし」と取り違えない。
  `autosaveName` も Hidden を保存するが、表示は状態の側に合わせる(`applyHiddenColumns`)。
- **見出しのドラッグで列を入れ替える**のは `allowsColumnReordering` の標準のまま(段階 3 から効いていた。実機で確認)。
  **名前の列は先頭から動かさず、ほかの列も名前の前へは入れない**(`tableView(_:shouldReorderColumn:toColumn:)`。Finder と同じ)。
  以前の保存で名前の列が先頭でなければ、作るときに先頭へ戻す。
- 見出しの右クリックのメニューには、AX で見ると題の無い淡色の項目が 1 つ末尾に付く(画面には出ない。システムが足すもの)。

- type-select(段階 4b、2026-09-14): `FileBrowserState.typeSelect(_:now:)`。文字のキーで表示名の先頭が一致する項目を 1 件選んでスクロールする。
  1 秒空くと打ち直し、**1 文字(同じ文字の連打を含む)は選択の次から一巡、2 文字以上は先頭から**。大小文字・濁点・全角半角は区別しない。
  ⌘ / ⌃ / ⌥ 付きと制御文字・機能キー(U+F700〜)は受けない。
- **編集欄を出している間は、一覧の `.onKeyPress` をすべて素通しにする。** SwiftUI の焦点が一覧に残っていると、AppKit のファーストレスポンダが
  編集欄でも `.onKeyPress` が先にキーを取り、打った文字が type-select に、Return が「開く」になった(実機)。編集を始めるときに一覧の焦点も外す。

## 右クリック

`FileBrowserMenuCommand.groups(for:)` が種類(`FileBrowserMenuKind`: フォルダ / ファイル / 空きスペース / ツリー)ごとの並びを持ち、
3 つの一覧で共有する(要望の一覧どおり)。種類は右クリックした 1 件で決める。
対象は「選択に含まれていればその全部、外ならその 1 件」。できない項目は淡色(**項目の数は選択の状態で変えない**)。
コレクション・このアプリケーションで開く・メタデータ・書き出しの項目は段階 8 でつないだ(→「既存機能との接続」)。
「圧縮」「展開」はサブメニュー(→「圧縮・展開」)。サブメニューの親も子と同じ条件で淡色にする(項目の数は変えない)。
空きスペースには「表示」「並べ替え」のサブメニューが付く。ツリーのよく使う項目の行だけ「よく使う項目から削除」が付く。
よく使う項目の並びは、ツリーでその行をドラッグして入れ替える(→「ドラッグ&ドロップ」)。
フォルダ(一覧)とツリーの行には「よく使う項目に登録」(`addToFavoriteLocations`、2026-09-14、ユーザー要望)。選んだものが全部フォルダで、
まだ登録していないものがあるときだけ押せる(全部登録済みなら淡色。シークレットウインドウでも淡色。読み取り専用モードでは押せる)。
**登録するのはパスだけで、アクセス権は足さない**(一覧に見えている時点で読めている。読めなくなれば行は残って「アクセスを許可…」に落ちる)。
登録済みかは `FavoriteLocationStore.contains`(`add` と同じ規則でパスをそろえる)。

### ⌥ で入れ替わる項目(2026-09-21、ユーザー要望。Finder と同じ)

右クリックメニューを開いたまま ⌥ を押している間、「コピー」が「パス名をコピー」に、「このアプリケーションで開く ▸」が
「常にこのアプリケーションで開く ▸」に入れ替わる(`FileBrowserMenuCommand.optionAlternate`)。

- 組み方は AppKit の「代わりの項目」: 元の項目の**すぐ後ろ**に `isAlternate = true`・`keyEquivalentModifierMask = [.option]` の項目を
  `FileBrowserMenuBuilder` が足す(キーはどちらも無し)。押す・離すでその場で入れ替わり、**見えている項目の数は変わらない**。
  `groups(for:)` には載せない。3 つの一覧(リスト・アイコン・ツリー)は同じ組み手なので同じに効く。コレクションの中の右クリックは
  SwiftUI の `.contextMenu` で、代わりの項目を作れないので付けていない。
- **パス名をコピー**(`FileBrowserOperations.copyPathnames`): パスを文字列で載せる(複数なら 1 行に 1 つ、フォルダの末尾の `/` は無し)。
  ファイルに触らないので読み取り専用でもボリュームでも使える。ファイルの参照は載せないのでペーストは淡色になり、カットの覚えも捨てる。
  一覧のキーは Finder と同じ ⌥⌘C(`FileBrowserEditCommand.copyPathname`)。メニューバーには置いていない。
- **常にこのアプリケーションで開く**(`FileBrowserActions.alwaysOpen`): Finder と同じく**そのファイルだけ**の既定のアプリにして、
  そのアプリで開く。`NSWorkspace.setDefaultApplication(at:toOpenFileAt:)` がファイルに拡張属性 `com.apple.LaunchServices.OpenWith` を
  書く ―― **サンドボックスの中から通る**(テストホストで実測 2026-09-21: 書いた後 `urlForApplication(toOpen:)` がそのアプリを返し、
  拡張属性が付いた)。ファイルを変えるので**読み取り専用モードでは淡色**(`canAlwaysOpenWith`)。書けなかった項目は開かずに知らせる。
  候補は種類で引くまま(`OpenWithApplications`)なので、設定した結果は「(既定)」の印には出ない(→「既知の制限」)。
  ファイルの「開く」(本と画像以外)は `NSWorkspace.open` なので、設定したアプリで開く。
- 実機で確かめたこと(2026-09-21、ユーザー確認): メニューを開いたまま ⌥ を押す・離すと、2 つの項目がその場で入れ替わる。

### 淡色の条件は「押して何かが起きるか」(2026-09-19 の総点検)

淡色の判定は、押したときに呼ぶ操作の場合分け・断る条件と**同じもの**を読む。右クリック・メニューバー(`FileBrowserMenuSelection`)・
一覧のキー(`canPerform`)の 3 つの入り口で同じ判定を使う。総点検で直した食い違い:

- 「開く」 = `FileBrowserActions.canOpen`(`open(_:)` と同じ場合分け)。1 件なら何でも(フォルダ・リンクは中へ、本と画像は qooViewer、
  それ以外は既定のアプリ ―― 段階 4a の「ファイルは本と画像だけ」は、Return では開けたのでユーザー判断でやめた)。複数ならフォルダ・リンクを
  含まないときだけ(以前はフォルダ 2 つで押せて何も起きなかった)。Return・ダブルクリックでも何も起きない組み合わせなら鳴らす。
- 名前の変更・カット・ゴミ箱 = `canChange`。**ビューアで開いている本(とそれを含むフォルダ)は淡色**、名前の編集も始めない
  (`FileBrowserOperations.refusesBecauseOpenInViewer` が断るので、以前は名前を打ち終えてから断られた)。圧縮・展開・コピーは元を変えないので押せる。
  メニューバーの値の覚え書きは開いている本のパスも鍵に入れるが、ほかのウインドウで本を開いてもこのウインドウの本体が評価されるまで古いことがある
  (押せば断ってダイアログで知らせる)。ドラッグでの移動と取り消しは従来どおり落とした・押した時点で断る。
- ペースト・新規フォルダ・ここに項目を移動 = `canWriteInto`。**表示中のフォルダが読めていない(`loadError`)間は淡色**。
- メニューバーの「ここに項目を移動」(⌥⌘V)は、ペーストボードの写し `FileBrowserState.pasteboardHasFiles` で淡色を決める。変化は購読できないので、
  アプリ・ウインドウが前に来たときと、このアプリがファイルを書いたときに `changeCount` で確かめ直す。写しが古くて押せたときは鳴らす。
- 「自動リネーム」のサブメニューの親は、フォルダ 1 つ・保存できるウインドウなら開ける(`canShowAutoRenameMenu`)。よく使う項目の外・ネットワーク上の
  フォルダでは「入れる」側(未チェックの規則・このフォルダの規則を作成)だけ淡色にし、チェックを外す・設定を開くは残す。
- 「移動」メニューの ⌘↑・⇧⌘↑ は、テキストの欄を編集中なら欄へ返す(`HomeMenuKeyRouting.shouldPerformNavigation`。欄の中では「先頭へ」)。
- 編集メニューの「取り消す」「やり直す」は、テキストの欄を編集中なら淡色にしない(`TextEditingMenuState`。以前は読み取り専用モード・本の表示中・
  補助ウインドウで欄の ⌘Z が効かなかった)。

## 既存機能との接続(段階 8、2026-09-14)

### 右クリックの 5 項目(`FileBrowserLibraryActions.swift`)

| 項目 | 押せる条件 | 選んだとき |
|---|---|---|
| コレクションを作成 | 書庫・PDF・EPUB のファイルかフォルダだけ(画像ファイル・ボリュームが混ざると淡色)。シークレットウインドウでは淡色 | ホーム(編集モード)へのドロップと同じ振り分け(`CollectionDropClassifier` → `WelcomeDropHandling.queueCreations`): ばらの本はまとめて 1 つ、棚はフォルダ名で 1 つずつ、名前を訊くシートを積む。**ライブラリが複数あるときはサブメニューで作る先のライブラリを選ぶ**(2026-09-21、ユーザー要望 ―― ファイルブラウザの間は本棚のライブラリの選択が見えず、選び直せなかった。`PendingCollectionCreation.libraryID` に載せ、シートがそのライブラリで重複の確認と作成をする。名前を訊いている間に消されていれば選んでいるライブラリへ)。ライブラリが 1 つならサブメニューにせず、そのライブラリへ(「コレクションに登録」と同じ省き方)。名前は本棚の帯と同じ `displayName`(既定のライブラリは表示言語の訳 ―― 「コレクションに登録」も 2026-09-21 までは生の `name` を出していた)。メニューバーの「ホーム」▸「コレクションを作成」も同じ形。シートは `WelcomeView` が持つのでファイルブラウザのまま出る。`fromDrop` なので「本を追加」パネルは出ない |
| コレクションに登録 ▸ | 同上 | サブメニューにライブラリ(1 つなら省く)→ コレクション(本棚の並び順)。棚は中の本へ展開して足す(`booksToAdd`)。同じ本は `CollectionStore.add` が弾く。足し終えたら右ペインの下に 2 秒の知らせ(`FileBrowserState.showToast` → `OverlayToast`。1 冊なら名前・複数なら冊数・入っていた本があればその旨。本棚ではないので画面に変化が無いため、2026-09-14 ユーザー要望) |
| このアプリケーションで開く ▸ | ボリューム以外 | `OpenWithApplications`: `urlsForApplications(toOpen:)`(**種類 `UTType` で引く**。ファイルに触らない)の候補を bundle id で畳み、既定のアプリを先頭(「(既定)」)、残りは名前順、qooViewer 自身は除く。末尾に「その他…」(`/Applications` の `NSOpenPanel`)。失敗は `showProblem` で報告 |
| メタデータの編集… | 1 件・上と同じ種類。シークレットウインドウでは淡色 | `BookMetadataSheet(fileBrowserEntry:)`(コレクションの外の本も開ける版。DB の行はパスで引く)。カバーの面も出す(2026-09-14、ユーザー要望): コレクションに入っている本はその行とライブラリで、コレクションから開いたときと同じ面。入っていない本は**切らずに**出し、絵はアイコン表示と同じ提供役から引く(指定した表紙がそのままアイコン表示に出る)。「切り取るときに残す位置」は枠の比が決まらないので出さない |
| 本の書き出し ▸ EPUB/PDF/CBZ | 1 件・上と同じ種類。書き出しのシートを出している間は淡色 | ビューアの右クリックと同じ `OpenBookExportSheet`。保存先の決め方も同じ(環境設定で固定なら尋ねない)。**本は読まずに渡す**(`MangaBook` の `pages` は空。書き出しは `BookLoader.load` で読み直すので、先に読むと大きな書庫を 2 回読む)。画面の状態(読み方向・見開き)は無いので `displayState: nil` = 書き出しウインドウと同じく DB > 既定値。「書き出したあとの動作」「保存データ・履歴の削除」はしない(読んでいる本の続きを決める設定なので)。シークレットウインドウではカバーを選ばせない |

- **フォルダは淡色にせず、選んだときに調べる**(一覧の読み込みで子フォルダの中を見ない方針。右クリックの「開く」と同じ)。
  メタデータ・書き出しは `ShelfFolderResolver` が画像フォルダ(`.book`)と答えたときだけ進み、そうでなければ「「…」は本ではありません。」を出す。
  コレクションも、本が 1 冊も無ければ同じ報告。
- 中身が場面で変わるサブメニュー(このアプリケーションで開く・コレクションに登録・本の書き出し)は `FileBrowserMenuNode` の木にして、
  AppKit(`FileBrowserMenuBuilder`)と SwiftUI(`FileBrowserMenuNodeItems`)が同じものを描く。閉包は `FileBrowserActions` を weak で持つ。
  AppKit の項目は閉包を `MenuNodeBox`(target。項目の `representedObject` で生かす)に入れる。**その action を `perform(_:)` と名付けない** ――
  NSObject の `performSelector:` と名前がぶつかって `#selector` がそちらを指し、押しても何も起きなかった(実機で発見。テストはメニューを通らず通っていた。
  いまは `FileBrowserIntegrationTests` がメニューを組んで action が NSObject のメソッドでないことを確かめる)。
- **`FileBrowserMenuNode.item` の画像(このアプリケーションで開くのアプリアイコン)は表示を指定してある**(2026-09-18)。macOS 27 SDK で
  リンクすると、AppKit・SwiftUI どちらのメニューでも項目の画像は既定で隠れ、普通の画像(アプリアイコン)まで消えていた(実機で確認)。
  Finder は 27 でもアイコンを出すので、AppKit は `NSMenuItem.showsImageOnMacOS27()`(`preferredImageVisibility = .visible`。
  26 SDK には無い API なので `#if compiler(>=6.4)` で包む)、SwiftUI は `.labelStyle(.titleAndIcon)` で揃えた。SF Symbols の項目は OS の既定に任せる。
- **「情報を見る」(2026-09-18、ユーザー要望)** は「Finder で開く」の下。ファイル・フォルダ・ツリーの行で、1 件以上選んでいれば押せる
  (読み取り専用モード・シークレットウインドウでも押せる)。情報ウインドウは Finder の一部で公開 API が無いので、Finder が公開している
  サービス **`Finder/Show Info`** に URL を載せたペーストボードを渡す(`FileBrowserActions.showInfo`、`NSPerformService`)。Apple Events では
  ないので Finder を操作する許可のダイアログもエンタイトルメントの例外も要らず、**サンドボックスの中から、読む権限の無いファイルでも開く**
  (ファイルを読むのは Finder。同じエンタイトルメントの検証アプリと実物の Debug ビルドで実測)。複数選べば Finder の ⌘I と同じく 1 件ずつ開く。
- 「「…」は本ではありません。」の説明は、コレクションの操作だけ「本が並んだフォルダを選ぶと、その中の本が入ります。」を添える(メタデータ・書き出しに出すと、棚のフォルダでも編集できるように読める)。
- **アイコン表示の `.contextMenu` はセルの本体評価のたびに組み立てられる**ので、アプリの候補は種類の決まる単位(拡張子とフォルダ/パッケージ/ファイルの別)
  ごとに覚え(qooViewer が前面に戻ったら捨てる)、コレクションの一覧は `CollectionStore.revision` と並び順が変わるまで覚える。
- **アプリの候補はファイルの URL ではなく種類で引く**(2026-09-14 の監査): これはメインアクターの上で走り、URL を渡すと LaunchServices が項目を調べに行くので、
  応答しない共有の上ではメインが待たされえた。種類は名前だけで決める(中へ入れるフォルダは `.folder`、パッケージとファイルは拡張子の種類、拡張子の無い
  ファイルは `.data`)。失うのは、1 つのファイルだけに付けた既定のアプリが「(既定)」に出ないことと、拡張子の無いファイルを中身で見分けないこと。
- 非同期の操作(作成・登録・メタデータ)は Task を返す(テストの待ち合わせ口)。

### 「ファイルブラウザで開く」(`FileBrowserReveal.swift`)

既存の「Finder で開く」の隣 9 箇所に置いた: ファイルメニュー、ビューアの右クリック、サイドパネル(フォルダブラウザの行・本の中身ブラウザの行・
お気に入り・履歴・ライブラリのツリー)、ページのサムネイル(`PageContextMenuItems` = サイドパネルのページモード・本の中身・ページ一覧)、
本棚のコレクションの中。実体は `AppState.revealInFileBrowser(_:isDirectory:)`。

- **何を見せるか**は `FinderReveal` と同じ: フォルダはその中、ファイルは入っているフォルダでその項目を選ぶ(`FileBrowserState.show`)。
  フォルダかどうかは、分かっていれば渡してもらい(履歴のスコープの付かない URL・一覧を読み済みの行)、分からなければ `FileIO` で調べる。
  見つからなければ警告音だけ(Finder で開くと同じ)。
- **どこに出すか**(決定事項 Q6): 本を開いていないウインドウ(本棚のコレクションの中)は、そのウインドウをファイルブラウザに切り替える
  (編集モードは畳む)。本を開いているウインドウは、環境設定「ファイルブラウザ」の「本を表示しているとき」
  (`fileBrowserRevealDestination`: 新規タブ(既定)/ 新規ノーマルウインドウ / 新規シークレットウインドウ)へ `BookWindowOpener.openFolder` で開く。
- ビューの右クリックからは環境値 `\.revealInFileBrowser`(`RevealInFileBrowserAction`、ContentView が入れる)で呼ぶ。**AppState を weak で持つ** ――
  メニュー項目の閉包は AppKit 側に渡ってウインドウより長生きしうる(ViewerActionRelay の件)。ビューアの右クリックは従来どおり relay 経由。
  `OpenWindowAction` は呼ぶたびに引数で渡し、AppState には持たせない(SwiftUI の中身を抱えうる値を `@StateObject` が持つと循環になりうる)。
- 読めるのは `FolderAccessStore` に許可のあるフォルダだけ。本を 1 冊開いた許可では隣は読めないので、許可が無ければファイルブラウザ側に「アクセスを許可…」が出る。
- サイドパネルのフォルダブラウザの見出しのボタン(「Finder で開く」のアイコン)には足していない(細い見出しにアイコンを増やさない。右クリックにはある)。

## ウインドウ・タブのタイトル(2026-09-14、ユーザー要望)

本を開いていないウインドウは一律「qooViewer」だったので、「ファイルブラウザで開く」で新規タブを重ねるとどれがどれか分からなかった。
いま画面の上の段に出ている名前をタイトルにする(`Models/WindowTitle.swift`、`ContentView.windowTitle`):

| 表示 | タイトル |
|---|---|
| 本 | 本の名前(従来どおり) |
| ファイルブラウザ | いまのフォルダの名前。コンピュータなら「コンピュータ」、起動ディスクの `/` はボリューム名(上の段の名前と同じ関数 `WindowTitle.folderName`) |
| 本棚(コレクションの一覧) | ライブラリの名前 |
| コレクションの中 | コレクションの名前(別のウインドウで消されていればライブラリの名前) |

シークレットウインドウの「(シークレット)」は従来どおり頭に付く。名前はパスの綴りのまま(ファイルシステムに問い合わせない)。

## 書く操作(段階4)

- **窓口は `FileBrowserOperations` 1 つ**(`FileBrowserState.operations`、ウインドウごと)。リスト・アイコン・ツリー・編集メニューが
  ここを呼び、中で `FileCommandStack` にコマンドを積む。**操作は 1 本ずつ直列**(次は前が終わるのを待つ)。
- 確認・衝突・問題の報告は `FileBrowserOperationPresenting` へ渡す(本番は `FileBrowserSheetPresenter` がウインドウのシートで。
  テストは偽物)。**問題は進捗の帯を片付けてから見せる。**
- コピー/カット: ペーストボードへ `NSURL` を書く。カットは**アプリで 1 つの** `FileCutClipboard`(標準化したパス + 書いた直後の
  `changeCount`)に覚え、各ウインドウの `FileBrowserState.cutPaths` はその写しで淡く描く(2026-09-19。以前はウインドウごとで、A でカットして
  B でペーストするとコピーになり、A は淡色のまま残った)。ペーストボードがほかで書き換えられたら、アクティブ化・ペーストの前に記憶ごと下ろす。
  ペーストは**ペーストボードの集合がカットの集合とそのまま一致したときだけ移動**、⌥⌘V は常に移動。同じフォルダへのコピーは尋ねずに `name 2` の複製。
  カットの記憶を下ろすのは**移動を実際に始めるとき**(確認をすべて通った後。`FileCutClipboard.clear(ifHolding:)` ―― 待つ間に別の項目をカットし直して
  いたら、その記憶は残す)。2026-09-21 まではペーストの入口で下ろしていたので、確認で止めた・確認の最中に読み取り専用やファイルブラウザ OFF へ
  切り替えて捨てられた・開いている本で断られた、どの場合も覚えだけが消え、もう一度 ⌘V するとコピーになった(同日の監査の L2)。
- **Finder など他のアプリでコピーした項目**(2026-09-14、許可を 1 つも持たない Debug で実測): 許可の無い場所の項目でも ⌘V・⌥⌘V で貼れる。
  ペーストボードから読んだ URL には**その項目自身**(フォルダなら中身ごと)への読み書きの許可が付き、親フォルダには付かない。
  拡張を添えずに `public.file-url` のバイト列だけを置いた URL でも同じだったので、付けているのはペーストボードの側。
  そのため**外から来た項目の ⌥⌘V は取り消せない**(元のフォルダへ書けず「「…」に書き込むアクセス権がありません」と報告され、項目は宛先に残る)。
  ペーストを外部由来の URL で無効にする案(計画 §4)は要らなくなった。
- **取り消せない移動は先に尋ねる**(2026-09-14、ユーザー決定): 移動(⌥⌘V・カットのペースト・D&D)の前に、各項目の元のフォルダへ
  `access(W_OK)` で書けるかを見る(サンドボックスの判定も返し、実測で許可の有無と一致した。`FileBrowserOperations.canPutBack`)。
  書けない項目があれば「〜の移動は取り消せません」と「移動(既定)/ コピー / 中止」で尋ねる。「移動」は取り消しに積まない
  (`MoveFilesCommand(isUndoable: false)`。混ざった 1 回の操作ごと積まない ―― ⌘Z は前の操作を戻す)、「コピー」は**戻せない項目だけ**をコピーに
  変え、戻せる項目は移動のまま 1 回で取り消せる。読み取り専用のボリュームと、**POSIX の権限で書けない元のフォルダは尋ねない**
  (どちらも移動そのものが断られる。`posixModeAllowsWrite` がモードビットで見て、POSIX では書けるのに `access` が断る = サンドボックスのときだけ尋ねる)。
  中止した混ざった操作の巻き戻しは、積まない移動を戻そうとせず、宛先に残ったことを問題として見せる(`CompositeRollbackError`)。
- **取り消しは、実行したときの実体にだけ触る**(2026-09-14): 受領書はパスで持つので、操作のあとで同じパスへ別の項目が来ると(積まない移動・
  Finder での置き換え)、⌘Z がそれを自分のものと取り違えてゴミ箱へ送りえた。移動・コピー・名前の変更・新規フォルダは、置いた直後の
  `FileIdentity`(デバイス番号 + inode + 作成日時)を受領書に持ち、取り消しの直前に一致を確かめる。違えば触らず「置き換わっていた」と伝える。
  移動の取り消しは元のフォルダごとにまとめて運ぶので、**エンジンが運ぶ直前にも 1 件ずつ確かめる**(`FileOperationOptions.expectedIdentities` →
  `itemReplacedSinceOperation`。4 回目の監査 ―― 始める前の 1 回だけでは、長い取り消しの間に置き換わった項目を運んだ)。
- **取り消せなかった操作の行き先**: 何も戻らず、原因を取り除けば戻せるもの(権限・元の名前が埋まっている・ゴミ箱の中に残っている)は
  `FileUndoResult.impossible(canRetry: true)` で**履歴に残し**、「もう一度取り消せます」と書き添える。相手が無い・別の項目に変わったなど
  試し直しても戻らないものは外す(残すと、その下の古い操作まで ⌘Z が届かない)。まとめた操作は、どの子も戻らずどれも試し直せるときだけ残す。
  最後の項目の衝突で「中止」を選んだときも中止として返す(以前は「スキップ」と同じになり、まとめた操作が済んだ子を巻き戻さなかった)。
  既定を「移動」にしたのは、利用者が移動を選んだうえ、何も失わない(Finder でなら戻せる)から。
- **取り消し・やり直しの流れ**(2 回目の監査 10〜14、2026-09-14):
  - まとめた操作(`CompositeFileCommand`)は、中止以外の失敗で子が投げたとき、**済んだ子に効果があれば投げずに `.partial` で返す**
    (投げた子・手を付けなかった子を失敗の列に並べる)。以前は投げたので積まれず、済んだ移動を ⌘Z で戻せず報告にも出なかった。
    取り消すのは実行して効果のあった子だけ(`executed`)。最初の子が投げたなら今までどおり投げる。
  - ⌘Z / ⇧⌘Z は**押した時点の一番上**(`FileCommandStack.nextUndo` / `nextRedo`)を控え、列の順番が来たときに一番上がそれでなければ
    何もしない(`undo(in:expecting:)`)。以前は走っている操作の後ろに並んだ ⌘Z が、その操作が終わった直後にその操作を戻した。
  - 取り消し・やり直しも `run` と同じ帯(「〜を取り消しています…」)と中止ボタンを出す。`FileCommand.undo(in:)` / `redo(in:)` が
    `FileCommandContext`(進捗・中止の旗・やり直しの衝突を尋ねる口)を受け取る。移動の取り消しは受領書の境目で中止を見て、何も戻って
    いなければ試し直せる扱いで履歴に残す。**やり直しは実行時の中止の旗を使い回さない**(以前は中止した操作のやり直しが立ったままの旗で
    何もせずに終わった。圧縮・展開・一括リネームも同じ)。中止で何も変わらなかったときは失敗を見せない。
  - ウインドウを閉じる(`FileBrowserState.releaseResources`)と、`presenter` を nil にせず `DetachedFileBrowserOperationPresenter` に
    差し替える: 確認は断る側(中止・キャンセル)、衝突は残りを止め、問題の報告だけ元の相手へ渡す(本番のシートの相手は、出す
    ウインドウが無ければアプリのモーダルで出す)。以前は閉じた後に終わった操作の報告(「元の項目を削除できなかった」「隠し項目として
    残した」を含む)が捨てられ、残りの衝突は黙ってスキップされた。
  - ゴミ箱へ送る取り消し(コピー・圧縮・展開・新規フォルダ)が `trashUnavailable` で失敗したら、試し直せる扱いにしない
    (`TransferUndo.canRetryTrashing`)。何度試しても送れないのに履歴の一番上に居座り、下の操作へ ⌘Z が届かなかった。完全削除の代わりにはしない。
    新規フォルダの取り消しは、読めないフォルダを空とみなさない。
  - 取り消しの題・新規フォルダ・「移動」メニューの中身(ファイルブラウザ用 ↔ 通常で項目の数が変わる)は、`ContentView` が
    `FileBrowserMenuSnapshot` にまとめて `AppState.setFileBrowserMenu` へ渡し、**`MenuBarMenuGate` で保留してから** `MenuCheckmarkState` へ出す
    (以前は直に詰めていたので、メニューを開いている間に操作が終わる・モードが変わると、macOS 26 のメニューの再構築のクラッシュ条件に当たりえた)。
- 衝突の確認は「両方を残す(既定のボタン)/ 置き換える / スキップ / 中止」(+「すべてに適用」)。Finder の既定は「置き換える」だが、
  Return 1 回で既存の項目がゴミ箱へ行かないよう「両方を残す」を既定のままにした。宛先にゴミ箱が無ければ「置き換えると元の項目はすぐに
  削除されます」と書き足し、「置き換える」を破壊的なボタンにする。
- **置き換え**(段階 4b、2026-09-14): 既存の項目を同じフォルダの `.qooViewer-replace-<UUID>/<元の名前>` へ退避してから書き、書き終えたら
  退避をゴミ箱へ(直後の ⌘Z で元の項目も戻る)、失敗・中止なら元へ戻す。**退避を作る前に `ReplaceBackupJournal` へ記録し**
  (Application Support/FileOperations/replace-backups.json。空になればファイルごと消す)、片付けたら消す。途中でアプリが落ちると記録が残り、
  次の起動で `ReplaceBackupRecovery` が戻して知らせる(元の場所に何かあれば上書きせず、隠し項目のまま残っていると警告し、記録も残して
  次の起動でもう一度試す)。走査ではなく記録にしたのは、退避の場所が利用者の選んだ書き込み先で、起動時に探すにはボリュームの走査が要るため
  (qooLibrary の NV-92)。サンドボックスでは、戻すフォルダの許可(`FolderAccessStore`)が起動時に開いている必要がある。
  置き換えられる項目がロックされていれば(ゴミ箱の無い場所では中の項目も)、**退避を作る前に**「“名前”はロックされています。置き換えてもよろしいですか?」と
  尋ね、続けるならロックを外して退避し、ゴミ箱の中で掛け直す。中止ならその操作を止める。確認を経ずに(「すべてに適用」の後など)ロックに当たったら、
  触る前に「ロックされています」で断る。ゴミ箱へ送れず消すことになった退避の中にロックされた項目があり許しが無ければ、消し始めずに記録ごと残す
  (途中まで消えた木を残さない。以前はここで止まり、次の起動で警告が出た)。
  **ゴミ箱のある場所で退避をゴミ箱へ送れなかったら、消さずに残す**(2026-09-14 の監査。以前は確認なしに完全削除へ落ちていた): 退避と記録を残し、
  「置き換えましたが、元の項目をゴミ箱に入れられませんでした。隠し項目「…」として残っています」の失敗として止める(`FileOperationError.replacedItemKept`)。
  次の起動の復旧も、元の場所が埋まっているので隠し項目が残っていると知らせる。完全削除するのはゴミ箱の無い場所(確認で「すぐに削除されます」と伝えた場合)だけ。
- **途中で失敗したとき**(2026-09-14 の監査で直した): 別ボリュームへの移動は「写す → 元を確かめる → 元を消す」で、**元を消し始めたあとは写しを消さない**。
  `FileManager.removeItem` は木の削除が途中で失敗しても消した分を戻さないので、以前の「元を消せなければ写しを片付ける」は元と写しの両方から
  兄弟を消した(`uappnd` の子を含むフォルダで 6 ファイル消失を実測)。写しを残して受領書を返し、「コピーしましたが元の項目を削除できなかったため、
  両方を残しました」の失敗として止める(`FileCopyEngine.Outcome.copiedButSourceRemains`)。写す段階の失敗では、`FileCopyEngine.copy` が
  **自分が作った書きかけの木を消してから**投げる(頂点の名前が EEXIST で断られたときだけは他人の項目なので触らない)。中身のある 0555 の
  サブフォルダを含む木は `COPYFILE_CLONE | COPYFILE_RECURSIVE` が EACCES で必ず失敗する(同じボリュームでも別のボリュームでも。CLONE 無しなら
  権限ごと写る)ので、その形の木に限って CLONE 無しでやり直す。**ロックされたフォルダ(空でも)を含む木も同じく EPERM で必ず失敗する**ので
  やり直しの対象(2 回目の監査、2026-09-14。ロックされたファイル・`uappnd` のフォルダは CLONE でも写る)。やり直すのは書きかけが本当に消えたときだけ
  (残っていると copyfile は既存のフォルダの中へ合流して書く)。書きかけの片付け(`removePartialWrite`)は、写ったロック・追記のみのフラグ・
  持ち主の権限の無いフォルダを外してから消し直す(以前は素の `removeItem` が EACCES / EPERM で途中までしか消せず、宛先の名前のまま残り、
  「置き換える」では宛先を空けられず元の項目が隠しフォルダに残った)。保護を外すのは自分が書いた木だけ。
- **一時名へ写してから置く**(2 回目の監査 8、2026-09-14): `COPYFILE_EXCL | COPYFILE_RECURSIVE` は宛先に同名の**フォルダ**があると失敗せずその中へ
  合流して書く(実測)ので、衝突の確認と写し始めの間に誰かが同じ名前のフォルダを作ると、写しが混ざり、後の片付け(元の変化・失敗)が
  他人のフォルダごと消した。`FileCopyEngine.copy` はファイルもフォルダも同じフォルダの `.qooViewer-copy-<12 桁>` へ写し、写し終えたら**置く前に**
  元の変化を確かめ(`MoveVerification`)、`RENAME_EXCL` で宛先の名前へ置く(写ったロック・追記のみのフラグは rename を EPERM で断るので外して置き、
  置いた先で掛け直す)。**宛先の名前に現れるのは完成した自分の写しか他人の項目だけ**なので、失敗・中止の片付けは一時名だけを消し、
  「置き換える」を戻す `restoreReplacedItem` も宛先の名前にあるものを消さない(埋まっていれば退避と記録を残して `replaceBackupOrphaned`)。
  埋まっていたら一時名を消して「同じ名前の項目があります」で止める。パス長の事前検査は一時名のぶん(先頭の要素が一時名より短いとき)を足す。
  アプリが写している最中に落ちると一時名が隠し項目として残る(既知の限界。圧縮の一時ファイルと同じ)。同じボリュームの移動は rename なので一時名を使わない。
- **元が運ぶ間に変わったか**(2 回目の監査 7): 大きさ・実体が同じなら先頭・中央・末尾の 64KB × 3 窓の抜き取りで決めていたので、領域を先に確保して
  書き続けるもの(ダウンロード・ディスクイメージ)の窓の外の書き込みを見逃し、移動では元を消して失っていた。**元がローカルのボリュームなら更新日時(ns)の
  違いも変化に数える**(日時を書き込み直後に差し替えるのは SMB のサーバなので、ネットワークの元だけ抜き取りに任せる)。
  別ボリュームへの移動で**元のフォルダを消すときは、写した先にもある項目だけを下から 1 つずつ消す**(`removeTransferredSource`。unlink / rmdir、
  リンクは辿らない)。写し終えてから消し終えるまでに元へ作られた項目は、その親の rmdir が ENOTEMPTY で断るので元に残り、「元の項目を削除できなかった」
  として伝わる(以前は `removeItem` が木ごと消し、どこにも残らなかった)。
  **名前は `readdir` で取り(`FileManager.contentsOfDirectory` は APFS の上でも `._*` を返さない)、フォルダは空と確かめてから rmdir する**
  (3 回目の監査。以前は `._` が消す対象に入らず、孤立した `._` だけのフォルダへ rmdir を呼んだ。exFAT の使い捨てボリュームでその rmdir が
  戻らずシステムごと固まった。再起動後に qooViewer を介さない素の操作で再現を確かめた ―― 孤立した `._` だけのフォルダへの rmdir が UN のまま戻らない)。**写した後に変わった元のファイル・リンクは消さない**(置く前の検証の後の保存・
  ダウンロードの完了を消していた。`SourceChangeCheck`)。確かめ方はボリュームで分ける: APFS・HFS+ などのローカルは**写し始める前の時刻より後に ctime が
  変わったもの**(更新日時を保つ上書きも ctime は今になる。同じ木のハードリンクの兄弟は、片方を消すと残りの ctime が変わるので残る側に倒れる)、
  **FAT・exFAT は大きさと更新日時を写しと比べる**(2 秒までのずれは許す ―― FAT32 の粒度)、ネットワークは見ない。FAT・exFAT の ctime は更新日時そのもの
  (4 回目の監査で実測: `touch -t` で更新日時を過去・未来へ動かすと ctime も同じだけ動く。msdosfs のソースも `va_change_time = va_modify_time`)なので、
  時刻と比べると未来の日時のファイル(カメラの時計のずれ、ローカル時刻で書く FAT32)で移動が 1 件目で止まり、過去の日時を保つ上書きは見逃して新しい中身ごと消していた。
- **移動の取り消しは元のフォルダごとにまとめて 1 回で運ぶ**(`TransferUndo.undo`。2026-09-15 の実機検証)。1 件ずつ移動を呼んでいたときは、4000 件の
  別ボリュームの移動(24 秒)の取り消しに 89 秒掛かり、帯は「全 1 件の何バイト」を 1 件ごとに出し直した。エンジンは最初の失敗で止まるので、失敗した項目を外して
  残りを続けて運び、まとめた呼び出しが 1 件も動かずに投げたら**そのまとまりを半分ずつに割って**確かめる(4 回目の監査。先頭 1 件を試してから残り全体で
  呼び直していたときは、空き容量の不足のようにまとまり全体で決まる断りで、1 件ごとに残り全部の事前検査をやり直して項目数の 2 乗になった。64 件のテストで
  呼び出しに渡した件数の合計 2108 → 256)。戻す先の組は辞書で引く(多くのフォルダから集めた移動で、組の線形探索がメインで項目数 × 組の数になっていた)。元のフォルダが複数あるときは、帯には全体の件数だけを出す。途中で止めた取り消しは、残りの件数で名乗る(`MoveFilesCommand.remainingToUndo`)。
- **帯への進捗は `ProgressRelay` で最新の 1 件だけを 50ms 空けて渡す**(2026-09-15 の実機検証)。報告ごとに `Task { @MainActor }` を作っていたときは、小さなファイルが
  多い移動でメインが追いつかず、バーが件数 20% のとき 7% まで遅れた(Task どうしの順番も保証されない)。中継は最初に届けた帯の操作に結び付き
  (`ProgressRelay.activityID`)、終わった操作の遅れた報告を次の操作の帯へ入れない(4 回目の監査)。
- **3 回目の監査で直した取り消し**: 移動の取り消しを中止で途中で止めると、戻した受領書を外して履歴へ戻す(`FileUndoResult.stopped` →
  `FileUndoOutcome.cancelled`。続きを ⌘Z で戻せる)。戻し終えた直後に立った中止を「戻せなかった」と数えない。やり直しは効果があったときだけ
  取り消しの履歴へ積み、何も起きずに中止したらやり直しの履歴へ戻す。中止ボタンを押していても `.failed` は見せる。メニューから押した取り消しは、
  メニューに出ていた名前と一番上の操作が違えば何もしない(メニューを開いている間は表示の更新が保留される)。並んでいる操作はウインドウを閉じても
  終わるまで操作と状態を持つ。
- **2 回目の監査の「低」で直したもの**: ゴミ箱から戻すときは送った直後の実体(`TrashReceipt.identity`・`TransferReceipt.replacedItemIdentity`)と
  一致するときだけ戻す(ゴミ箱を空にした後で同じ名前を捨てると別の項目が戻った)。取り消せない操作でも効果があればやり直し先を捨てる。
  同じボリュームかはリンクを解いてから決める(`FileOperationService.isOnSameVolume`。別のボリュームを指すリンクの下で空き容量とロックの確認を飛ばした)。
  SwiftUI の受け口は、他のアプリからのドラッグは Finder のときだけ移動を許す(`DropInfo` に元の操作のマスクが無い。最前面のアプリで見分ける)。
  2026-09-15 にアイコン表示を AppKit にしたので、この判定が効くのは一覧の外(操作列など)へ落としたときだけ。
- **ボリュームそのものは移動しない**(2 回目の監査 9): Finder でボリュームを ⌘C して ⌥⌘V、⌘ を押してドロップすると、全部写してから元を空にしていた
  (マウントポイントの `removeItem` は中身を全部消してから EBUSY)。画面の側はボリュームの行を外しているが、ペーストボードや他のアプリからのドロップは
  外せないので、移動の事前検査でマウント表(`MountTable.isMounted`)に載っている項目を「ボリュームなので移動できません」で断る。コピーは今までどおりできる。
- **1 回の転送の中の同じ名前**(2 回目の監査、2026-09-14): 衝突の相手が**この操作で置いたばかりの項目**(受領書の `FileIdentity`)なら、方針や
  確認の答え(「すべてに適用」の置き換えを含む)によらず、尋ねずに「両方残す」で `name 2` に置く。以前は別々のフォルダの同じ名前の項目を
  1 回で運ぶと 2 件目が 1 件目を置き換え、ゴミ箱の無い宛先では移動してきた唯一の実体を消していた。実体で比べるので、名前の畳み方には左右されない。
  同じボリュームの移動のロックの確認は項目自身だけを見る(中を歩かない。邪魔をするのは rename(2) が断る項目自身のロックだけ)。
  名前の変更で宛先が「自分自身」(同じ inode)とみなすのは、名前の違いが大文字小文字と正規化だけのとき(`namesDifferOnlyInCaseOrNormalization`)。
  同じフォルダのハードリンクの兄弟への変更は rename(2) が何もせずに成功を返すので、以前は「変えた」と報告して取り消しも積んでいた。
  置き換えの記録の復旧は、退避が「確かに無い」(載っているボリュームが繋がっていて ENOENT)ときだけ記録を捨て、ボリュームが外れている・読めない
  ときは黙って記録を残す(`ReplaceBackupJournal.Outcome.unreachable`。以前は外付けを繋がずに起動しただけで記録が消え、隠れた元の項目が二度と
  知らされなかった)。
- **ロックされた項目**(Finder の「ロック」= `uchg`): `NSWorkspace.recycle` も `trashItem` も項目自身がロックされていると「アクセス権が
  ありません」で断る(中にロックされた項目があるだけのフォルダは送れる。2026-09-14 実測)。そこでゴミ箱へ送る前に、ロックされた項目があれば
  「“名前”はロックされています。ゴミ箱に入れてもよろしいですか?」(続ける / 中止。既定は中止)と尋ね、続けるならロックを外して送り、
  **ゴミ箱の中でロックを掛け直す**(戻すと元の場所でもロックされている)。ゴミ箱の無い場所の完全削除は中の項目まで見て尋ね、
  外してから消し、消せなければ外したロックを戻す。一部だけがロックされているときは「ロックされた項目をスキップ」も出す(残りだけを送る)。
  コピーの取り消しは自分が作ったものなので尋ねずに外して送る(ロックはコピーにも写る)。
  **移動と名前の変更**も同じ確認を出す(2026-09-14。以前は OS の EPERM が「権限がありません」と出るだけだった)。移動で邪魔をするのは、同じボリュームなら
  項目自身のロック(rename)、別のボリュームなら中の項目のロックも(コピーしてから元を消すため。`movingIsBlockedByLock`)。続けるなら邪魔をするロックだけを
  外して運び、**運んだ先の同じ場所で掛け直す**(失敗・中止なら元の場所で)。自分が運んだもの・名前を変えたものの取り消しは尋ねずに外して戻す。
  Finder の動作は検索しても情報が割れていて、突き合わせていない。
- ゴミ箱: `TrashAvailability` で見て、無い場所が混ざれば「すぐに削除されます」の確認(既定のボタンはキャンセル)→ 完全削除(積まない)。
- 新規フォルダ: ファイルメニュー(⇧⌘N。Finder と同じ。「新規シークレットウインドウ」は ⌥⌘N へ移した)・右クリック。
  「名称未設定フォルダ」(ぶつかれば 2 から数えて最初に空いた番号。この機の Finder と 6 通りで突き合わせて同じ、2026-09-14)で作り、表示中のフォルダなら選んで名前の編集を始める(`renameRequest`)。
- 名前の変更(リスト): 名前の欄は `FileBrowserNameField`。**選ばれた 1 行の名前の文字をもう一度クリックしてダブルクリックの間隔だけ待つ**
  (アイコン表示と同じ仕組み。下の「名前の編集を始める・続ける決まり」)、または右クリックの「名前を変更」で始まり、
  編集中は表示名ではなく実際の名前を出して拡張子の前までを選ぶ。Esc で取りやめ。**編集中は一覧の読み直しを待たせる**(消えるため)。
  待たせるのは描き直しだけでなく**一覧・選択・スクロールの取り込みごと**(2026-09-14 の監査。以前は `entries` だけ差し替えていたので、
  編集中に一覧が変わると確定が古い行番号で新しい一覧を引き、別のファイルの名前を変えた。`FileBrowserListEditingTests`)。後始末の最中に
  届く 2 度目の「編集が終わった」は無視する。
- 名前の変更(アイコン): セルの名前の `FileBrowserNameField` を、不透明な地の折り返す欄に切り替えて編集する(打つと下へ伸びる。輪郭なし)。
  始まり方は 3 つ ―― **選ばれた 1 件の名前の文字の上をもう一度クリックしてダブルクリックの間隔だけ待つ**(範囲は `FileBrowserIconView.nameRect`。
  以前は「アイコンより下」全部で、名前の横の余白でも始まった)、新規フォルダの直後、右クリックの「名前を変更」。Return で確定、Esc で取りやめ、
  ほかをクリックして焦点が外れても・表示形式を切り替えても・編集中のセルが画面から外れて使い回されても確定。**編集中は一覧の取り込みを待たせる**(リストと同じ)。
  名前の変更が済んだあとに変えた項目を選び直すのは、**その項目がまだ選ばれているときだけ**(余白をクリックして確定したら選択は外れたまま)。
- 名前の編集の依頼(`renameRequest`)は、一覧が編集を始めたら `finishRenameRequest` で下ろし、フォルダを移ったら捨てる。
  残しておくと、表示形式を切り替えて作り直された一覧が古い依頼を拾い直して、頼んでいない編集を始める。**読み終えた一覧に相手が無ければ捨て、
  絞り込みで隠れているなら絞り込みを解く**(`settleRenameRequest`。2026-09-19 ―― 絞り込み中に新規フォルダを作ると依頼が残り、後で絞り込みを
  解いた時点で編集が始まった)。ペースト・展開などで置いた項目が絞り込みで 1 つも見えないときも絞り込みを解く(reveal と同じ)。
- **ビューアで開いている本は、名前の変更・移動・ゴミ箱を断る**(`refusesBecauseOpenInViewer`。2026-09-19、ユーザー決定。自動リネームが
  開いている本を避けるのと同じ)。当たるのは、開いている本そのもの・その祖先(フォルダごと)・その中身(フォルダの本の中の画像)。
  コピー・圧縮・展開は断らない。取り消し・やり直しは確かめない(受領書を一律に覗く口が無い)。開いている本の一覧は全ウインドウ・全タブの
  `MangaBook.pathsInUse`(ペインが `openBookPaths` に繋ぐ)。
- **名前の編集を始める・続ける決まり**(2026-09-19、`FileBrowserNameEditing.swift`。リスト・アイコン共通。ツリーは名前を編集しない)。
  報告: リストで選ばれているファイルをフォルダへドラッグして移動したら、**移動したファイルの名前の編集が始まり**、編集中は一覧を取り込まないので
  もう無いファイルが編集を終えるまで残った。調べた結果と直し方:
  - リストの再クリックでの編集は `NSTableView` の標準に任せていた。編集を始めるのは AppKit の内側の遅延実行(`-[NSTableRowData _delayMakeFirstResponder:]`、
    実機のスタックで確認)で、アプリの状態を見ない。押し直しがダブルクリック扱いになるとこの予約は取り消されず、操作の途中で編集が始まった
    (使い捨てボリュームに合成イベントで再現。報告の操作そのものは 9 通り試して再現できていない)。→ **名前の欄はふだん編集できない欄**にし
    (`editingName` を入れるのは `beginEditingName` だけ。AppKit の予約が走っても焦点を受けない)、クリックの判定は `FileBrowserTableView.mouseDown`、
    待つのは `FileBrowserNameClickRename`。予約は**アプリのどこかでの押し下げ・キー**(イベントモニタ)・ドラッグの開始・編集の開始で取りやめ、
    待ち終わってもボタンが押されたまま・ウインドウがキーでない・その 1 件だけを選んでいないなら始めない。以前のアイコン表示は一覧の中の押し下げだけを
    数えていたので、ツリーで押した操作を見落としえた。`FileBrowserTableView.hitTest` は編集中でない名前の欄を当たり先にしない(判定を単純にした)。
  - 始める直前に `canBegin`: 書ける状態・画面が状態に追いついている(`displayedFolder` と今の一覧)・**ディスクにある**(`lstat`)。依頼
    (右クリック・新規フォルダ)もクリックも同じ関門を通る。
  - 編集中に届いた一覧から編集中の項目が消えたら(同じフォルダのまま。ドラッグでの移動・Finder・自動リネーム・他のウインドウ)、`editedItemVanished` で
    **編集を取りやめて取り込む**(打った名前は捨てる ―― 元が無いので変えられない)。表示するフォルダが変わったときは今までどおり打った名前で確定する。
  - 実機で確かめたこと(Debug・使い捨てボリュームに合成名): リスト・アイコンとも再クリックで編集が始まる、名前の右の余白では始まらない、クリック直後に
    押し直してドラッグすると移動だけで編集は始まらない、ダブルクリック扱いの押し直しでも始まらない、編集中にシェルから移すと編集が消えて一覧から外れる。
- キー: リストは `FileBrowserTableView` が `copy:`/`cut:`/`paste:` を受け(標準の編集メニューが効く)、⌘⌫ / ⌥⌘V / ⌘[ / ⌘] / ⌘↑ を
  `FileBrowserEditCommand` へ。アイコン表示の `FileBrowserCollectionView` も同じ形で受ける(2026-09-15 まではコピー・カット・ペーストを `.onCommand`、
  ⌘⌫ / ⌥⌘V / ⌘[ / ⌘] を表示中だけのキー監視で受けていた ―― SwiftUI の `.onKeyPress` では届かなかったため)。
  2026-09-15 から ⌘⌫ / ⌥⌘V / ⌘↓ はメニューバーの項目のキーでもあり、一覧の `keyDown` より先にメニューが受ける
  (`HomeMenuKeyRouting` が一覧に焦点があるときだけ選択へ効かせ、テキストの欄を編集中なら欄へ返す)。キーの ⌘↓ はダブルクリックと同じ
  `open`、メニューの項目を選んだときは右クリックと同じ `openFromMenu`(4 回目の監査。メニューが先に受けるようになって、⌘↓ が画像フォルダで
  ダブルクリックと反対の開き方になっていた)。
- 空のフォルダでも一覧は置き、「このフォルダは空です」はその上に重ねる(案内だけにすると ⌘V と空きスペースの右クリックが効かない)。
- AppKit の右クリックメニューは `autoenablesItems = false`(既定のままだと淡色の指定が無視される)。
- 報告の題に操作の名前(`displayName`。「「x」の移動」「3 項目のコピー」)を入れるときは、題の側でかぎ括弧を付けない(名前が自分で括弧を持つので重なる。2026-09-14)。
  空き容量が足りないときに見せる「必要な量」は、比べた値と同じ「書く量 + 余裕」。
- 取り消す/やり直す: 編集メニュー(`CommandGroup(replacing: .undoRedo)`)。題はフォーカス中のウインドウの
  `MenuCheckmarkState.fileBrowserUndoTitle`(ファイルブラウザが出ているときだけ)。テキストを編集中ならその欄の `undo:` へ流す。
- 進捗の帯(`FileBrowserProgressBar`): パスバーの上。400ms 以内に終わる操作では出さない。「N 件中 M 件目 — バイト — 残り約」+ 中止。
  残り時間はバイトが動き始めて 1 秒経ってから。地は不透明なので輪郭は掛けない。
- 操作のあと: 表示中のフォルダを読み直して運んだものを選ぶ(ネットワークでは FSEvents が飛ばない)。ツリーは
  `fileSystemChange` を受けて、**開いていて子を読み終えている行だけ**読み直す(同じパスの行は同じ Node を使い回し、孫の開閉を保つ)。

## 読み取り専用モード(段階 8.5、2026-09-14。決定事項 Q12)

環境設定「ファイルブラウザ」の先頭の「読み取り専用」(`AppPreferences.fileBrowserReadOnly`、キー `qooViewer.pref.fileBrowser.readOnly`、
**既定 ON**、「初期設定に戻す」の対象)。ノーマル/シークレットの両方に効く。ON の間はファイルそのものを変える操作をできなくし、
利用者が OFF にしたときだけファイルマネージャーとして使える。

- **断るのは `FileBrowserOperations` の入り口 1 か所**(`isReadOnly`。環境設定が届いていなければ断る側)。ペースト・⌥⌘V・カット・移動/コピー・
  ドロップ・ゴミ箱/完全削除・新規フォルダ・名前の変更・一括リネーム・圧縮・展開・取り消し/やり直しが、呼ばれた時点で何もしない
  (確認のシートも出さない)。**走っている操作・順番を待っている操作は止めない**(次の操作から効く)。取り消しの履歴は消さない。
- 画面の側は**淡色にするだけ**(項目の数を変えない): `FileBrowserActions.allowsFileChanges` / `canChange` / `canPaste` / `canCreateFolder` を
  右クリック(リスト・アイコン・ツリー)と `canPerform`(キー・編集メニューのコピー/カット/ペースト)が読む。ファイルメニューの「新規フォルダ」と
  編集メニューの取り消し/やり直しは `MenuCheckmarkState` の値で淡色(`ContentView`)。
- **できるまま**: 閲覧・開く・新規タブ/ウインドウで開く・Finder で表示・このアプリケーションで開く・よく使う項目の登録/解除・
  コレクションの作成/登録・メタデータの編集・本の書き出し(保存データや書き出し先であって、表示中のファイルを変えない)・⌘C・パス名をコピー・
  外からのドロップの「ビューアで開く」。
- 名前の編集: リスト・アイコン表示とも `FileBrowserNameEditing.canBegin` で断る(2026-09-19 まではリストが
  `FileBrowserTableView.validateProposedFirstResponder` で名前の欄に焦点を渡さなかった)。アイコン表示は `isReadOnly` を値で受け取る ―― `state` と `actions` の参照が変わらないので、
  値で受け取らないと環境設定を切り替えても本体が評価し直されず、右クリックの淡色が古いまま残る。
- ドロップ: `FileBrowserDropDecision.make(allowsFileChanges:)` が運ぶ判定を `.refuse` にする(受け口としては断る ―― 型コメントの
  「ウインドウ全体のドロップ先との関係」)。他のアプリからの「ビューアで開く」はそのまま。
- **出し口はコピーだけを許す**(`fileBrowserDragSourceMask`。計画は「アプリ外への D&D は元を変えない」としてそのままだったが、移動を許すと
  Finder へ落としたときに Finder が元を動かす)。リスト・ツリーは `draggingSession(_:sourceOperationMaskFor:)` を上書きしてドラッグのたびに引く
  (`setDraggingSourceOperationMask` は作ったときの 1 回で、あとから切り替えた設定が効かない)。アイコン表示は始めるときに決める。

### 実機で見つけて直したもの(段階 8.5、2026-09-14)

- **SwiftUI の `.contextMenu` の中の `Menu` には `.disabled` が効かない**(macOS 26.6、最小の再現アプリで実測。`Menu` / `Group` / `Section` への
  `.disabled`、`\.isEnabled`、`menuStyle`、`primaryAction` のどれでも親項目は押せる見た目のまま、中の項目だけ淡色)。アイコン表示の右クリックで
  「圧縮」「展開」が押せるように見えた。淡色のサブメニューは押せない `Button` で描く(`FileBrowserDisabledSubmenu`。矢印は出ないが項目の数は同じ)。
  AppKit のメニュー(リスト・ツリー)は `autoenablesItems = false` + `isEnabled` で正しく淡色になる。
- **名前の欄が当たり先になる状態**: アイコン表示の右クリックでサブメニューを開いて Esc で閉じたあと、リストの `hitTest` が
  `validateProposedFirstResponder` を尋ねずに名前の欄を返すようになった(ログで実測。ウインドウはキーのまま)。右クリックが表に届かずメニューが開かない、
  選ばれていない行のクリックで(読み取り専用でも)名前の編集が始まる、ツリーの右クリックが開かない、が起きた。タイトルバーをクリックすると戻る。
  AppKit の内側の状態は見えないので、`FileBrowserTableView.hitTest` が確かめ直して表を返し(2026-09-19 からは「編集中でない名前の欄は当たり先にしない」)、`FileBrowserOutlineView.hitTest` は行の文字の欄を
  当たり先にしない(判定は `resolvedHit` に切り出してテストする)。名前の変更そのものは、この状態でも `FileBrowserOperations` の入り口が断っていた。

## 一括リネーム(段階 5、2026-09-14)

複数を選んで右クリックすると「名前を変更」が「N 項目の名前を変更…」になり、Finder の「名称変更…」と同じシートが出る。
コードは `Models/BulkRename.swift`(名前の決め方。純粋関数)、`BulkRenameFileCommand`(FileCommands.swift)、
`FileBrowserOperations.bulkRename`、`Views/FileBrowser/BulkRenamePanel.swift`(AppKit のシート)。

**規則は計画(検討メモ §8)の推測ではなく、この機の macOS 26.6 の Finder で実際に名前を変えた結果に合わせた**(使い捨てボリュームに合成名のファイル。
詳細と例は `BulkRename` の型コメント、期待値は `BulkRenameTests`)。推測と違っていた点:

- **拡張子は後ろから続く「登録済みの拡張子」全部**(`c.zip.cbz` → `ファイル 1.zip.cbz`、`p.q.txt` → `….txt`、`1.2.3` → 拡張子なし)。
  登録済み = `UTType(filenameExtension:)` が動的な型でない。フォルダも同じ。
- **テキストを置き換える**は大文字小文字を区別せず全部を置き換え、最後の拡張子が登録済みでなくなったら元の最後の拡張子を付け直す(`c.txt` の txt→qq は `c.qq.txt`)。
- **フォーマット**: カスタムフォーマットが空でなければ間に何も挟まない(「ファイル 1」「1ファイル 」)。空なら元の名前と空白 1 つ。日付の書式は
  Finder の文言表の `DATE_FORMATTER1`(日本語 `yyyy-MM-dd h.mm.ss a`、英語 `… 'at' …`)。
- **衝突は止めずに避ける**(計画の「名称変更を無効にして赤字」ではなかった)。相手はフォルダの元の名前全部(この操作で空く名前も含む)と、先に決めた名前。
  インデックス・カウンタは番号を進め、ほかは `name 2.ext`。新しい名前は元の名前と重ならないので、**計画にあった一時名の 2 パスは要らない**。
- 番号は表示順(`state.entries` の並び。フォルダを上にしていればフォルダから)。例の行は表示順の先頭。

Finder と変えたところ: 使えない名前(先頭のドット・`/`・空)ができる入力では、Finder は押した後にアラートを出して何もしないが、ここでは
例の行に赤字で理由を出して「名前を変更」を押せなくする(押した時点の中身で決め直してもう一度見る)。見出しは「Finder項目の」を付けず、
ボタンは qooViewer のほかの場所と同じ「名前を変更」。ポップアップの幅は Finder の寸法を下限にした(macOS 26 の標準のポップアップは余白が広く、
Finder と同じ 143pt では「テキストを置き換える」が切れた)。シートの高さは実機で 102 / 133 / 162pt(Finder 103 / 132 / 161pt)。

実行は 1 件ずつ `RENAME_EXCL` で、失敗した項目があっても残りを続ける(済んだ分は取り消せ、失敗は報告に並ぶ)。**全体で 1 回の取り消し**。
名前の前後の空白を落とさない(`FileNameValidation.validatedExactly`、`rename(…, keepsNameExactly: true)`)。ロックされた項目は
「続ける / ロックされた項目をスキップ / 中止」で尋ねる。ファイルメニューの項目とキーは付けていない(Finder も名称変更にショートカットは無い)。

## 自動リネーム(2026-09-15、ユーザー要望)

よく使う項目(またはその配下)のフォルダの中の項目の名前を、アプリの起動中に規則で自動で変える。検討の経緯・決定事項・実測は
[plans/auto-rename-study.md](plans/auto-rename-study.md)。コードは `Models/AutoRename.swift`(規則と名前の決め方・書き終わりの判定。純粋関数)、
`ViewModels/AutoRenameStore.swift`(規則・除外・実行ログ)、`Services/AutoRename/`(対象の状態・走査・実行役)、`Views/AutoRename/`(設定ウインドウとシート)、
`Views/FileBrowser/FileBrowserAutoRenameActions.swift`(右クリック)。

- **1 つの規則 = 名前の変え方 1 つ + 対象フォルダの列**。規則は一覧の上から順にかけ、一覧のチェックボックスで ON/OFF する。上限は規則 20・規則ごとの対象 20。
- 変え方: テキストを置き換える(ファイル名 / 拡張子)、テキストを追加(名前の前 / 後)。**ファイル名の置き換えは拡張子に掛けない**(一括リネームと違う。
  拡張子の中に検索文字列が現れる規則が拡張子を壊し続けるため)。拡張子の置き換えは最後の拡張子が丸ごと一致したときだけ(`zip` → `cbz`)で、フォルダには掛けない。
  テキストの追加は、既に付いていれば付けない。大文字小文字の区別は規則ごと(既定は区別しない)。**フォルダの名前も変えるかは規則ごとで既定 OFF**
  (コピー中のフォルダの名前を変えると Finder のコピーそのものが失敗する。検討メモ §9.2)。
- **変えない場面**: 読み取り専用モードの間 / 対象が使えない(よく使う項目の外・ボリュームの未接続や別のディスク・ネットワーク・権限なし・見つからない)/
  今ある項目に掛けることをまだ確認していない対象(中身を変えた・ON にした・足した対象。変わる項目が無ければ黙って確認済みにする)/
  書き込みが終わっていない(Finder のコピー中の印 `brok`/`MACS`、ファイルは 2 回の観測、フォルダは配下全部の 2 回の観測)/ ビューアで開いている本とそれを含むフォルダ /
  もう一度かけると変わる・使えない名前になる(実行ログに 1 回だけ残す)/ 実行ログから元に戻した項目(`AutoRenameStore.excludedPaths`)。
- 衝突は一括リネームと同じ `name 2` で避け、避けた名前にもう一度規則をかけて変わらないことを確かめる。
- 契機: 起動時の走査、規則の変更(変わった対象だけ)、FSEvents(`FolderChangeWatcher(onEvents:)`。フォルダが作られた・移ってきたら配下を読む ―― 同じボリュームの中の移動は
  中身のイベントが来ない。`MustScanSubDirs` なら配下を全部読む)、ボリュームのマウント、よく使う項目・フォルダの許可・読み取り専用モードの変更、見送った項目の見直し。
  自分が変えた名前のイベントは 5 秒読み飛ばす。**テストの中で走る実物のアプリでは動かさない**(`AppStores` が `start()` を呼ばない)。
- **見つからない対象**: ボリュームの UUID が登録時と一致しているのにフォルダが無いときだけ、1 秒置いて確かめ直してから**その対象だけを OFF**(`disabledMissing`)にする。
  戻ってきても自動では ON に戻さない。保存しておいた**セキュリティスコープの無い**ブックマークを解いて移動先を提案し(ゴミ箱の中・よく使う項目の外などは淡色)、
  「更新」するとパスを書き直して元の ON/OFF に戻す(確認はし直す)。よく使う項目から外された対象は OFF にせず止め、戻されたら再開する。
- 名前の変更は `FileOperationService.rename`(`RENAME_EXCL`・名前を正確に保つ・ロックされた項目は断る)。ウインドウの ⌘Z には積まず、実行ログの「元の名前に戻す」で戻す
  (名前を変えた直後の `FileIdentity` と一致するときだけ)。**読み取り専用の間は「元の名前に戻す」も淡色で、戻す側でも断る**(戻している途中で切り替えたら
  残りは戻さずにそう伝える)。名前を変える走査も、各項目の前に読み取り専用の設定そのものを見る ―― 停止の印(`isPausedForReadOnly`)は切り替えの
  1 ランループ後に追いつくので、その間に 1 件だけ変わりえた(2026-09-21 の監査の L4)。
- 画面: 「自動リネームの設定」ウインドウ(左に規則、右に中身と対象フォルダ。帯で読み取り専用の停止・確認待ち・移動の提案、ツールバーに実行ログ)。
  入口は右クリックの「自動リネーム」(フォルダとツリー。規則ごとのチェックで対象に入れる・外す、このフォルダの規則を作成、設定を開く。よく使う項目の外・ネットワーク・
  シークレットウインドウでは淡色)、環境設定「ファイルブラウザ」のボタン、「ホーム」メニュー。
  「フォルダを追加…」のパネルは、よく使う項目の「＋」と同じく**直前に足した対象のときに閉じたパネルの `directoryURL` から始める**(規則の最後の対象がそれである間。
  覚えるのはアプリを終了するまで。設定ウインドウは閉じてもビューの状態が残るので、開き直しても消えない ―― 2026-09-17 の実機)。それ以外は最後の対象の親、対象が無ければ最初のよく使う項目(2026-09-17、ユーザー指摘。以前は最後の対象そのものから始め、中に入った状態で開いていた)。
- 実機で確かめたこと(2026-09-16、Debug・使い捨てボリュームに合成名): 右クリックとホームメニューから開く・確認シートを通した名前の変更・`cp` で置いた項目の変更・
  **Finder の 3GB のコピーの間は名前を変えず、終わってから変える**・**Finder のフォルダごとのコピーは中身を変えてからフォルダを変え、Finder のコピーは失敗しない**・
  別のディスクに差し替えたときの「ボリュームが接続されていません」・対象を移したときの OFF と移動の提案と更新・実行ログからの復元と、別の項目になっていたときの断り・
  読み取り専用モードの帯・環境設定のボタン。実機で見つけて直したもの: ステータスバーが左の一覧の「+ −」に重なる、検索・置換の欄に枠も例も無くどこに打つか分からない、
  **帯が 2 本出るとウインドウの中身がはみ出して左の一覧まで見えなくなる**(帯の文の高さの固定をやめ、フォームの上に差し込む形にした)。
- 既知の制限: 実行ログから戻した項目の除外はパスで持つので、対象フォルダを移動の提案で更新すると外れ、確認の一覧にまた出る。戻した行は日時が変わるが並びは元の位置のまま。

## 圧縮・展開(段階 6、2026-09-14)

右クリックの「圧縮」「展開」のサブメニュー。コードは `Services/FileOperations/{ZipCompressor, ArchiveExtractor, ArchiveExtractionPlan,
FileOperationService+Archives}.swift`、コマンドは `CompressFilesCommand` / `ExtractArchivesCommand`(FileCommands.swift)、窓口は
`FileBrowserOperations.compress` / `extract`。

| 項目 | すること |
|---|---|
| 圧縮 ▸ ここに圧縮 | 選んだ項目(同じフォルダのもの)を同じフォルダの zip 1 つに。名前は 1 件ならその名前(ファイルは拡張子ごと `a.jpg.zip`。Finder と同じ)、複数ならフォルダの名前。拡張子は環境設定「圧縮ファイルの形式」(zip / cbz) |
| 圧縮 ▸ 保存先を選んで圧縮… | 同じものをフォルダ選択(NSOpenPanel)で選んだフォルダへ |
| 展開 ▸ ここに展開 | 書庫の中身を書庫と同じフォルダの直下に並べる |
| 展開 ▸ 「〈名前〉」に展開 | 書庫の名前(拡張子を 1 つ外す)のフォルダを作ってその中へ。複数なら「それぞれの名前のフォルダに展開」 |
| 展開 ▸ 展開先を選んで展開… | 選んだフォルダの直下に並べる |

- **圧縮**(`ZipCompressor`): ZIPFoundation。フォルダはフォルダごと入れる(`Book/001.jpg`)。先頭がドットの名前(`.DS_Store`・`._*`)と `Icon\r` は入れない
  (選んだ項目そのものは入れる)。エントリ名は NFC。画像・書庫・PDF・EPUB・動画は無圧縮、ほかは deflate。同じフォルダの
  `.qooViewer-compress-<UUID>.zip` に書いてから `renamex_np(RENAME_EXCL)` で置く(塞がっていれば `name 2.zip`)。書く前に、書けるか・空き容量
  (入れるファイルの合計)を見る。読んでいる間に元が縮んだ・書き換わったら「コピー中に変更された」で止める(ZIPFoundation は短いチャンクに気づかず壊れた zip を作る)。
  中は自分で歩き、**どの深さでも読めないフォルダ・`lstat` できない項目は失敗にする**(途中で消えた項目だけ飛ばす。2 回目の監査、2026-09-14。
  `FileManager.enumerator(atPath:)` は読めないサブフォルダを黙って飛ばすので、中身の欠けた zip が成功として出来ていた)。
  **置く前に一時ファイルを `fsync` し、読み取りで開き直してエントリの数を確かめる**(同。ZIPFoundation は `fflush` / `fclose` の結果を捨てるので、
  末尾のセントラルディレクトリ / EOCD でディスクが溢れても成功になり、壊れた zip が最終名で置かれていた)。
- **展開**(`ArchiveExtractor`): 読むのは既存の `ArchiveReading`(本として開くときと名前が食い違わない)。書庫の中の順番で読む(7z のソリッドを
  やり直さない)ために、`entriesInArchiveOrder()` と `readEntry(at:_:)` を足した。全部を先に開いて一覧・限度・合計の空き容量を確かめてから、
  書庫ごとに同じフォルダの `.qooViewer-extract-<UUID>/`(0700)へ書き、書き終えたら置く。中止・失敗なら一時フォルダごと消す。
  ファイルは `open(O_CREAT | O_EXCL | O_NOFOLLOW)` + `FileHandle.write(contentsOf:)`(投げる版。ディスクフルで落ちない ―― テストあり)。
  読むのは `readEntriesInArchiveOrder`(書庫を 1 回だけ読み通す)。rar はフォークの `forEachEntry`(→ [11](11-forked-dependencies.md))で、
  1 件ずつの `extract` だとソリッドの rar が 2 乗で遅かった(180MB・60 ファイルで 62 秒 → 2.2 秒。非ソリッドは 1.3 秒)。
  書庫の更新日時をファイル・フォルダに写す。実行権などの属性は写さない。
- **zip の日時は現地時刻**(`ZipDOSTime`、2026-09-14 の実機検証で発見): MS-DOS 形式の日時はタイムゾーンを持たない現地時刻で、Finder も Info-ZIP も
  現地時刻で書くが、ZIPFoundation 0.9.20 は読み書きとも UTC として扱う。そのままだと展開したファイルが 9 時間未来になり、作った zip は他のツールで
  9 時間前に見えた。読むとき(展開・「情報を見る」)も書くとき(圧縮)もずらす。本の書き出し(CbzExporter / EpubExporter)とコレクション表紙の zip(ShelfCoverArchive)も、書き出す時刻をずらして渡す(2026-09-14、→ [08](08-export-and-import.md))。
- 圧縮の中の並びは、要素ごとの名前順(列挙はディスク上の順なので、毎回同じにする)。
- **捨てるエントリ**(`ArchiveExtractionPlan`。純粋関数): 絶対パス(`/`・`\`・`C:`)、要素に `..`(`/` と `\` の両方で区切って見る)、NUL・制御文字、
  255 バイトを超える要素・PATH_MAX を超えるパス(= 入れ子の段数の上限。2 回目の監査で、3000 段のエントリ 1 つの zip が名前決めの再帰で
  スタックを溢れさせアプリごと落ちた。名前決めもループにした)、記号リンク(見分けられるのは zip だけ)。これらは報告に「書庫: パス: 理由」で並ぶ(展開そのものは済む)。
  `__MACOSX/` と `._*` は黙って外す。暗号化された rar は「パスワードで保護されています」、分割された rar は「分割されています」で断る
  (zip・7z の暗号化は見分けられず、「読めませんでした」になる)。
- **書庫の中の名前の衝突**: ファイルどうし・ファイルとフォルダは後のほうを `name 2`、大文字小文字だけ違うフォルダはまとめる、まったく同じパス
  (Swift の文字列として等しい = 正規化違いも含む)の 2 つ目は捨てる。reader も同じパスでは先のエントリを読む(zip だけ後のもので上書きしていて、
  1 つ目の名前に 2 つ目の中身が書かれていた。2026-09-14 の監査)。**展開先の既存の項目との衝突は尋ねずに `name 2`**(Finder と同じ)。
- **限度**(伸長爆弾よけ、`ArchiveExtractionLimits`): ファイル 10 万個・合計 20GB・圧縮比 1,000 倍(合計 100MB 以下なら問わない)。
  始める前に索引の宣言で、書いている最中に実際に書いた量で見る。宣言サイズの合計は飽和加算。
- **取り消し**: 作った zip / 置いた項目(「〈名前〉に展開」は作ったフォルダ 1 つ)をゴミ箱へ。`FileIdentity` が変わっていたら触らない。
  複数の書庫は全体で 1 回の取り消し。1 冊が開けなくても残りは続け、失敗は報告に並ぶ。
- **「保存先を選んで…」を NSSavePanel にしなかった理由**: 保存パネルで選んだ場所にはそのファイル 1 つぶんの許可しか付かず、同じフォルダの
  一時ファイルに書いてから置く形が取れない。フォルダを選べば中へ書く許可が付く。
- **既知の制限**: rar・7z の記号リンクは
  中身の短いファイルとして展開される。進捗の件数はファイルの数(書庫が複数でも通しで数える)。

## サムネイル(段階 7a・7b、2026-09-14)

アイコン表示のセルに、本・画像・画像を直接持つフォルダ・動画の**中の絵**を出す(リストとツリーは種類のアイコンのまま。ユーザーの判断。
アプリケーションのアイコンだけはリストにも出す ―― 下の「アプリケーションのアイコン」)。
コードは `Services/FileBrowserThumbnails/{BookThumbnailer, FileBrowserThumbnailDiskCache, FileBrowserThumbnailProvider}.swift` と
`Views/FileBrowser/FileBrowserIconView.swift` の `FileBrowserIconItem` / `FileBrowserIconCellView`。動画(7b)は同じフォルダの `VideoThumbnailer` / `RetaggedHEVCThumbnailLoader` /
`MediaContainerSniffer` / `MatroskaDimensionReader` / `FileBrowserVideoThumbnailWarmer`(下の「動画」)。

- **どこから持ってくるか**(決定事項 Q5): コレクションに登録済みで表紙ができている本は**その表紙**(`CollectionCoverStore` の JPEG。本は読まない)。
  次に、**コレクション表紙を指定してある本**(メタデータの編集で。登録していない本でも指定できる。2026-09-14、ユーザー要望 ―― 同じ本の表紙の絵が
  アプリの中に 2 種類あるのを避ける): 画像の指定は保管庫(`CollectionCoverSourceStore`)の画像をそのまま(本は読まない。ディスクキャッシュにも
  入れない)、本の中のページの指定は `CoverImageResolver` でそのページを作り、鍵に `variant = "shelfPage:<ページのキー>"` を足してディスクキャッシュへ
  (本を丸ごと読むので重いが、指定した本だけ。**登録済みの本では作らない** ―― 抽出役がすぐ同じ絵を作るので、それまでは先頭の絵で待つ)。
  どれも無ければディスクキャッシュ、それも無ければ作ってキャッシュへ。表紙の有無は `CollectionStore.items(forBookID: entry.id)`(bookID = パス)、
  指定は `LayoutStore` の `shelfCover*` の列で引き、`CollectionStore.revision` が進んだとき・絵にしたことのある本の指定が `.layoutDataDidChange` で
  変わったとき(`shelfSignatures` と比べる)に提供役の `revision` を進めてセルに頼み直させる(メモリにあれば即座に返る)。
- **作り方**(`BookThumbnailer`。本を丸ごと開かない ―― `BookLoader.load` はアイコン表示には重すぎる):

  | 種類 | 読むもの |
  |---|---|
  | 画像 | そのファイルを ImageIO で縮小(`ImageDecoder.decode(fileAt:)`。画素数の上限は本と同じ。**間引いて読めない形式**(`subsamplingTypeIdentifiers` = JPEG・PNG・TIFF・HEIC・HEIF 以外。無圧縮の BMP など)は 3200 万画素まで ―― 16000² の BMP の縮小は約 2GB を確保した。2 回目の監査 24) |
  | zip / cbz / rar / cbr / 7z / cb7 | 索引(`listFilePaths`)から `isExcludedArchiveEntry` を外した画像のうち**正準順の先頭** 1 件。64MB まで(宣言サイズと、`readEntry` で伸長しながら数えた量の両方)。rar / 7z は**書庫の順でその前にあるファイルの宣言サイズの合計が 256MB を超えたら作らない**(ソリッドでは前を全部伸長する。`readsTooMuchBefore`。非ソリッドかは見分けない)。7z は**ストリーミングできないブロック(BCJ2 など)を丸ごと伸長してよい上限を 64MB に**する(フォークの `Archive.maxWholeBlockBytes`。800MB のブロックを持つ 143KB の cb7 で 845MB を確保した。2 回目の監査 20・21) |
  | EPUB | `EpubStructureResolver` の spine の先頭(`maxPages: 1` で残りの XHTML を読まない) |
  | PDF | 1 ページ目を白地に描く(/Rotate を反映) |
  | フォルダ | **直下の**画像のうち正準順の先頭(`readdir`。`.` で始まる名前・`UF_HIDDEN`・記号リンクは数えない) |

  並べ方と除外が本を開くときと同じなので、並べ替えていない本なら 1 ページ目と同じ絵になる(`FileBrowserThumbnailTests` が台帳の全書庫で
  確かめる)。**違いうるのは**、書庫の中の書庫・PDF・EPUB が先頭に来る本(入れ子は開かない。直下に画像が無ければ絵を出さない)と、
  サブフォルダの中の画像が先に並ぶ・サブフォルダにだけ画像を持つフォルダの本。パッケージ・記号リンク・ボリュームは作らない。
- **フォルダの中を読まない場所**: ネットワーク越しのボリューム(セルの数だけ往復する)と TCC の保護下の場所(`DirectoryProbe.protectedPrefixes`。
  ホームフォルダを開いただけで「デスクトップ」の中を読むと確認が出る)。ただしデスクトップ・書類・ダウンロードの**中を見ている**ときの、同じ場所の中の
  フォルダは読む(許可は場所ごとに済んでいる。`categoryProtectedPrefixes`)。`~/Library` の他のアプリのデータは中を見ていても読まない。
  ファイル(本・画像)はいま読めているフォルダの直下なので、場所を問わず作る。
- **実体が手元に無いファイルは作らない**(2026-09-14 の監査。以前は動画だけが見ていた): 項目そのもの・フォルダの中の先頭の画像が `SF_DATALESS` なら
  作らず、「作れなかった」とも覚えない(`BookThumbnailer.Outcome.notDownloaded`)。さらに読み取り全体を
  `DatalessFiles.withoutDownloading`(`setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, …_OFF)`、終われば元の方針へ戻す)で包むので、
  確かめた後に追い出された・EPUB の中から辿った、などの取りこぼしも読み取りの失敗になるだけでダウンロードは起きない。
  **本物の追い出されたファイルでは確かめていない**(テストで作れない。方針がサンドボックスの中で掛かり、戻ることだけをテストで見ている)。
- **PDF の箱**は `CGRect.hasUsablePDFPageSize`(有限・正・1 辺 1,000 万 pt 未満)を通ったものだけ使う(巨大な箱で `Int(_:)` がトラップした。本の表示の `PageLoader` も同じ)。
- **見せ方**: 本・画像は枠(アイコンの大きさの正方形)に収め、薄い影を付ける(白いページが明るい面に溶けないように。絵なので輪郭は掛けない)。
  フォルダは**フォルダのアイコンの上に絵を小さく重ねる**(絵だけだと画像ファイルと見分けがつかない)。絵ができるまでは種類のアイコン。
  持っている絵は新しい絵が届くまで手放さない(大きさを変えて点滅しない)。
- **ディスクキャッシュ**(`FileBrowserThumbnailDiskCache`): `Caches/<bundle id>/FileBrowserThumbnails/`、長辺 512px の JPEG(品質 0.8、
  透明な地は白で塗る)。鍵は **ボリューム(`MountTable.volumeIdentifier`)+ inode + 更新日時(ns)+ サイズ + 作り方の世代**の SHA-256
  (名前を変えた・移した項目は作り直さない。差し替えた・inode が使い回された項目に古い絵を出さない)。**既定 ON、上限 200MB**
  (ページサムネイルと既定が逆なのはユーザーの判断。代わりに環境設定「キャッシュ」に ON/OFF・上限・使用量・削除を並べ、リソースモニタの
  「ディスク」にも出す)。刈り込みと OFF での削除は `ThumbnailDiskCache` と同じ規則・同じ関数。「すべてのデータを削除」でも消える。
- **メモリ**(`FileBrowserThumbnailProvider`、アプリで 1 つ): 復号した絵は `PagePixelCache`(96MB)に**大きさの段ごと**(長辺 128 / 256 / 512px。
  表示の大きさの 2 倍を超えるいちばん小さい段)。アイコンの大きさは 48〜450pt(上限はコレクションの中のカバーの最大 300×450pt と同じ見た目。
  2026-09-16)で、256pt を超えると 512px を引き伸ばす ―― カバーの側も最大付近では 768px を引き伸ばしているので、アイコンのためだけに大きい段は足さない(ユーザーの判断)。セルは使い捨ての CGImage を持ち、`LazyCellImageBudget`(64MB)で数えてグリッドを作り直す
  (**名前を編集している間は作り直さない** ―― 欄が作り直されると焦点が外れて確定してしまう。終わってから作り直す)。
- **並べ方**: 作る仕事は同時 4 件、待っている仕事は**後から頼まれたものから**(スクロールで画面に入ったセルが先)。同じ絵は 1 件にまとめ、
  頼んだセルが全部いなくなった仕事は始まる前なら捨てる。読み取りは `FileIO` の上(応答しない共有で協調プールを塞がない)。
  作れなかった絵(画像の無い書庫・壊れたファイル)はこの起動の間は覚えて作り直さない(鍵に更新日時とサイズを含むので、中身が変われば試し直す)。

### アプリケーションのアイコン(2026-09-14、ユーザー要望)

アプリケーションフォルダを開いてもアプリがすべて同じ汎用のアイコンで、見分けがつかなかった。`.app`(パッケージで記号リンクでないもの。名前だけで決める。
`BookThumbnailer.Kind.application`)は、そのアプリのアイコンを `NSWorkspace.icon(forFile:)` で取り、**FileIO の上で**決まった画素数へ描き写してから
(`FileBrowserApplicationIcon.render`。`NSImage` は描くときに遅れて中を読むので、画素にしてから持ち帰る)出す。

- アイコン表示: 提供役の段(128 / 256 / 512px)で作り、メモリの LRU に入れる。ディスクキャッシュには入れない(LaunchServices が覚えていて速く、
  アプリを入れ替えたときに古い絵を残さない)。ページ用の影は付けない。
- リスト表示: 行の 16pt(32px)を `FileBrowserListApplicationIcons` が覚え、まず種類のアイコンを出して、読み終わったら見えている行だけ差し替える。
- 読む場所: バンドルの中を読むので、フォルダの絵と同じくネットワーク越しと TCC の保護下の場所では読まない(`FileBrowserThumbnailProvider.kind(for:...)`)。
  ツリーはフォルダだけなので関係しない。

### 動画(段階 7b、2026-09-14)

qooLibrary の実装(`VideoThumbnailLoading` ほか)を写した。実測の経緯はそちらと検討メモ §6.2。

- **対象**: 名前の型が `UTType.movie` に準拠するファイル(`VideoThumbnailer.isVideoFile`)。**入っているアプリに左右される**(mkv は
  mkv を扱うアプリがあるときだけ動画になる ―― 無ければどのみち絵は作れない)。環境設定「ファイルブラウザ」の**「動画のサムネイルを生成」**
  (`fileBrowserVideoThumbnailsEnabled`、既定 ON)で、アイコン表示の絵と下の先に作る役の**両方**を切り替える(1 行にまとめたのはユーザーの判断)。
  提供役がこの値を `includesVideo` として写して配る ―― アイコン表示に `AppPreferences` を観測させると、どの設定が変わってもグリッド全体の
  body が作り直されるため。
- **作り方**(`CompositeVideoThumbnailLoader`、上から順に、できたところで止まる):
  1. `QuickLookVideoThumbnailLoader`: `QLThumbnailGenerator`(`.thumbnail`、長辺 512)。**8 秒で `cancel(request)`**(呼ばないと完了が来ず
     グループから抜けられない)、先にできたら眠っているタイムアウト側を起こす(起こさないと成功 1 本ごとに枠を 8 秒ふさぐ)。
     先頭 16 バイトで実体を見て(`MediaContainerSniffer`)、**拡張子と食い違うときだけ** `Request.contentType` にシステムの具体的な型を渡す
     (`.mp4` を名乗る mkv、`.mkv` を名乗る mp4。`UTType(filenameExtension:)` は未知の拡張子にも `dyn.` の型を返すので `.movie` 準拠で弾く)。
     実体が Matroska なら `MatroskaDimensionReader`(先頭 8MB の EBML)で縦横比を読み、要求の大きさを合わせる(QLMedia は要求の大きさへ
     引き伸ばす)。
  2. `RetaggedHEVCThumbnailLoader`: **`hev1` の HEVC**(AVFoundation が入口で断り、QuickLook も Finder も作れない。ffmpeg の libx265 の
     既定)。素通しの `AVAssetReaderTrackOutput` でキーフレームを取り出し、format description の subtype だけ `hvc1` にして
     `VTDecompressionSession` で復号する。対象外のファイルはトラックの情報を読むだけで nil。これも 8 秒の期限(`FileIO.withDeadline`)。
- **mkv**: OS の標準では作れず、**動く QuickLook 拡張があれば出る**(qooLibrary の比較で採用できたのは QLMedia。QLVideo 3.x は拡張点が無く、
  QLCodec-mkv は同時に頼むと絵が入れ替わり上下も逆)。拡張が無ければ種類のアイコンのまま。
- **提供役での扱い**: 本と同じディスクキャッシュ・同じ鍵・同じ同時 4 件。コレクションの表紙は探さない。**実体が手元に無いファイル**
  (`SF_DATALESS`。iCloud などに追い出されたもの)は作らない ―― QuickLook が読むと頼まれていないダウンロードが始まる。こちらは
  「作れなかった」とは覚えない。作れなかった動画(拡張が無い・壊れている・8 秒を超えた)は本と同じくこの起動の間は覚える。
- **よく使う項目の中を先に作る**(`FileBrowserVideoThumbnailWarmer`、アプリで 1 つ): よく使う項目の中(**サブフォルダも全部**。ユーザーの判断)
  の動画を、起動している間に裏で 1 本ずつ作ってディスクキャッシュへ入れる。起動時・よく使う項目が変わったとき・「動画のサムネイルを生成」
  かディスクキャッシュを ON にしたときに、2 秒待ってから回る(どちらかが OFF なら止まり、回らない)。`.background` の Task、借りるスレッドは
  `.utility`(`FileIO.perform(qos:)`)、アイコン表示の 4 件とは別に最大 1 本。作り済みは JPEG を読まずに飛ばす(`diskCache.contains`)。
  **同じ拡張子が 1 度も成功しないまま 3 回失敗したら、その掃引ではその拡張子を諦める**(覚えない ―― 次の起動でまた試すので、拡張を入れたら出る)。
  辿らないところ: ネットワーク越し(よく使う項目そのもの・途中のマウント)、TCC の保護下の場所(**よく使う項目そのものが同じ保護下の場所の
  中にあるときだけ辿る** ―― ホームフォルダを登録していても「デスクトップ」の中は読まない)、隠しファイル・隠しフォルダ(`~/Library` を含む)・
  パッケージの中・記号リンクの先、実体が手元に無いファイル・フォルダ(失敗とも数えない。フォルダは中を列挙すると一覧を落としてくる)。入れ子のよく使う項目でも 1 本は 1 回。
  ディスクキャッシュを OFF にした瞬間に書いていた絵は、書いた後で OFF を見て消す。リストのアプリのアイコンは同時に 4 件まで読む。
  QuickLook の動画の絵は、期限(8 秒)が来たら QuickLook の完了を待たずに戻る(取り消しに応えないと枠が塞がったままになった)。
  ツリーのボリュームとよく使う項目の行は、着脱・並べ替えのたびに作り直さず同じ Node を使い回す(開いていた行が閉じた)。
  **1 回の掃引で書くのはディスクキャッシュの上限の半分から使用量を引いた残りまで**(`bytesAvailableForWarming`。2 回目の監査 22。以前は上限を知らずに
  書き続け、上限を超える量の動画があると刈り込みと作り直しを起動のたびに繰り返した)。マウント表は 1 秒に 1 回だけ写し直す(`RecentMountTable`)。
  **テストの中の実物のアプリでは繋がない**(`AppStores` が `RuntimeEnvironment.isRunningTests` で外す)。回っている間に増えた動画は、
  次に回るまで(またはアイコン表示に出るまで)作らない。

## ドラッグ&ドロップ(段階4b)

コードは `Views/FileBrowser/FileBrowserDragAndDrop.swift`(判定・受け口・アイコン表示の出し口)と `Models/FileDropPlan.swift`(純粋な判定)。

- **移動かコピーか**(`FileDropPlan`): Finder と同じ。同じボリューム(`MountTable.areOnSameVolume`)なら移動、別ならコピー、
  **⌥ は常にコピー・⌘ は常に移動**(計画は「⌥ で反転」だったが Finder の実際に合わせた)。自分自身・自分の中へは断る、
  自分のフォルダへの移動は外す(全部そうなら断る)、⌥ で同じフォルダへ落とせば複製。移動とコピーが混ざった 1 回のドロップは
  `CompositeFileCommand` で **1 回の取り消し**。
- **何をするか**(`FileBrowserDropDecision`): アプリの中からのドラッグ(`FileBrowserDragTracker` が出し口の始まりから終わりまで覚える)は
  常に移動・コピー。**他のアプリからは環境設定「他のアプリからドロップしたとき」**(`fileBrowserExternalDropAction`、既定「ビューアで開く」
  = ウインドウのほかの場所へ落としたときと同じく本を開く /「コピー・移動」)。コンピュータ(行き先なし)へは運ばない。
- **修飾キーはドロップの瞬間のマウスのイベントから読む**(`FileDropPlan.Modifiers.current`)。`NSEvent.modifierFlags` はいまのキーの状態で、
  ボタンと ⌥ をほぼ同時に離すと、離した瞬間のイベントの処理中にもう ⌥ なしを返した(同じフォルダへの複製が「何もしない」に化けた。実機)。
- **よく使う項目の並べ替え**(2026-09-14、ユーザー要望): ツリーのよく使う項目の行は、並べ替えのためだけに掴める。ペーストボードには項目の id だけを
  アプリの独自の型(`fileBrowserFavoriteLocationPasteboardType`)で書き、**ファイルの URL は書かない**(書くとフォルダの行・リスト・Finder へ落としたときに
  登録したフォルダそのものが運ばれる)。出し口のマスクはアプリの中なら `.move`、外は無し(読み取り専用モードとは無関係)。落とせるのはよく使う項目の行の間だけで、
  行の上へ落とそうとしたら上半分なら前・下半分なら後ろへ直す。並べ替えは `FavoriteLocationStore.move(id:to:)`(動かす前の並びでの挿入位置)。
  並びは保存されるので、シークレットウインドウでは掴めない。項目が 1 つなら掴まない。
- 出し口: リストの行・ツリーの**ふつうのフォルダの行だけ**(ボリューム・ホームフォルダ・よく使う項目の根はファイルとしては動かさない)・アイコン表示のセル。
  ペーストボードは実際のファイルの `NSURL`。**アプリの外へも移動を許す**(copy / move / generic)。Finder へ落とすと Finder 自身が
  Finder の規則で移動・コピーする(同じボリュームは移動、別はコピー、⌥ でコピー、⌘ で移動を実機で確認 2026-09-14。移動は Finder が
  行うのでサンドボックスに掛からず、取り消しは Finder 側)。当初はコピーだけにしていたが、Finder のウインドウ同士と挙動が違うのは
  期待に反する(ユーザー指摘)。こちらは元を消さないので、移動を受けても自分で元を消さない相手ではコピーで済む。
  Dock のゴミ箱(`.delete`)は許していない(合成したドラッグでは Finder からでもゴミ箱が受け付けず、確かめられなかった)。
  ウインドウをまたいだドラッグはアプリの中として扱い、同じボリュームなら移動(実機で確認)。取り消しは落とした側のウインドウの履歴に積まれる。アイコン表示の出し口は `NSCollectionView` の標準
  (2026-09-15 まで SwiftUI だったときは、`.onDrag` が 1 件しか運べないので自前でドラッグセッションを始めていた)。
- 受け口: リストはフォルダの行の上ならそのフォルダ、それ以外は表全体(表示中のフォルダ)。表全体のときは、アイコン表示の余白と同じ
  **右ペインのアクセント色の枠**を出す(`FileBrowserTableView.isWholeTableDropTarget` → ペイン。AppKit 標準の表全体の強調は細い線で、
  すりガラス 2 条件では薄かった。2026-09-14、実機でフォルダの行の上では出ないこと・落とした後に消えることを確認)。ツリーはどの行の上でも(行の間はその親の行)。
  パスバーは成分ごと(`FileBrowserPathControl`。`NSPathCell` で成分の矩形を引き、アクセント色の枠で囲む。「コンピュータ」は断る)。
  アイコン表示はフォルダのセルならそのフォルダ、それ以外(ファイルのセル・余白)は表示中のフォルダで、全体のときはリストと同じペインの枠
  (`FileBrowserCollectionView` の受け口。2026-09-15)。**一覧の外(操作列など)は `FileBrowserPane` の受け口**が表示中のフォルダへ。
- **右ペインを全部受け口で覆い、断るときも受け口として断る**: SwiftUI の内側の受け口が断ると、ウインドウ全体の「本を開く」受け口
  (`ContentView.applyFileDropTarget`)が拾う(フォルダを自分の上に落とすと本として開く、になる)。
- SwiftUI の受け口は **`performDrop` の直後にもう 1 回 `dropUpdated` が届き**、消した強調が付き直って残った(ログで確認)。
  落とした後 0.5 秒は強調を付け直さない。
- **ツリーはドラッグ中に行を開かない**(`shouldExpandItem`)。`NSOutlineView` の標準では静止した行が開くが、開いた直後はその行が
  受け口から外れ、マウスを動かさずに離したドロップが黙って断られた(静止 1.2〜1.7 秒で 5 回とも失敗。子の入れ方を `insertItems` に変えても同じ)。
  「ドラッグを受けているか」は `FileBrowserOutlineView` が `draggingEntered` / `draggingExited` と受け取りで持つ。**`draggingEnded` /
  `concludeDragOperation` を上書きしてはいけない** ―― 上書きすると、そこへ落としたときにドラッグ元のリストの
  `draggingSession(_:endedAt:operation:)` が呼ばれず、`FileBrowserDragTracker` が残って次の他のアプリからのドラッグを
  アプリの中のものと取り違える。念のため AppKit の受け口(リスト・ツリー・パスバー)は、ドラッグ元が見えない(= 他のアプリからの)ドラッグなら
  残っている記録を捨てる(`dropDecision(for:into:)`。SwiftUI の `DropInfo` には元が無いので、そちらはこの受け口を一度通るまで古いまま)。
- 他のアプリからのドロップの中身は SwiftUI では `NSItemProvider` から読む(サンドボックスの読み取りの許可が付く経路)。カーソルの判定だけは
  ドラッグのペーストボード(`NSPasteboard(name: .drag)`)から読む。

## サンドボックスと TCC の約束

ファイルブラウザは Finder の代わりなので、利用者が**入ってもいない場所**に自分から触る部品(三角・絵・先回り)を抱えている。
触ると、(1) デスクトップ・書類・`~/Library` の他のアプリのデータなどで **TCC の確認ダイアログが出る**、(2) 応答しない共有でメインや
協調プールが**塞がる**、(3) iCloud などに追い出されたファイルの**ダウンロードが始まる**。約束は「**確認のダイアログは、利用者がその場所に
入ったときに 1 回だけ出る**」(段階 3)。部品を足すときは次の表のどの行に当たるかを決めること。

| 約束 | どこで守っているか |
|---|---|
| 読めるのは `FolderAccessStore` の許可の下だけ。読めなければ `needsAccess` で中央に「アクセスを許可…」(`NSOpenPanel` → `FolderAccessStore.add` → 読み直し) | `FileBrowserListing` / `FileBrowserActions.requestAccessToCurrentFolder`。よく使う項目の「＋」も同じ経路で許可を足す。右クリックの「よく使う項目に登録」は足さない |
| ホームフォルダは実際のホームフォルダ(`getpwuid`)。`homeDirectoryForCurrentUser` はサンドボックスではコンテナを返す | `FileBrowserListing.realHomeDirectory` |
| **開く前に触って確かめない**(触ること自体が確認の引き金) | 「移動」メニューの標準の場所・「フォルダへ移動…」(`FileBrowserStandardLocation` / `FileBrowserGoToFolderSheet`) |
| 一覧は子フォルダの中を見ない。パッケージの中へは降りない(写真ライブラリの確認も出ない) | `FileBrowserListing`(→「一覧の読み込み」) |
| 自分から中を読む部品は、TCC の保護下の場所を**パスの文字列だけで**除外し、ネットワーク越しの場所を**マウント表で**除外する | 三角 `DirectoryProbe.protectedPrefixes`、絵 `FileBrowserThumbnailProvider`(同じ保護下の場所の中を見ているときだけ `categoryProtectedPrefixes` を読む)、動画の先回り `FileBrowserVideoThumbnailWarmer`(よく使う項目そのものがその中にあるときだけ辿る) |
| 画像フォルダかどうか(右クリックの「開く」・新しいタブで開く・メタデータの編集・ダブルクリックで開く)は、直下と子フォルダの直下の名前だけを見て、保護下の子フォルダは同じ保護下の場所の中から見ているときだけ読む。`DirectoryBrowser` の一覧(コレクションの作成・本棚へのドロップ・サイドパネル)も同じ規則で子フォルダの中を読む。比べるパスは `/System/Volumes/Data` の頭を外して揃える(2 回目の監査 15・23。以前は `ShelfFolderResolver.role` がホームで「書類」などの中まで読んだ) | `ShelfFolderResolver.isSingleBookFolder` / `DirectoryProbe.mayReadChild` |
| アイコンは種類だけで引く。`NSWorkspace.icon(forFile:)` と `NSPathControl.url` を使わない | `FileBrowserIconProvider` / `FileBrowserPathBar`(→「AppKit とすりガラス面」) |
| 追い出されたファイル(`SF_DATALESS`)は絵を作らず、読み取りはスレッド単位で実体化を切る | `DatalessFiles.withoutDownloading`(→「サムネイル」) |
| 「このアプリケーションで開く」の候補はファイルに触らず種類(`UTType`)で引く | `OpenWithApplications` |
| FSEvents は許可なしで届くが、ネットワーク上の場所は見張らない | `FileBrowserState` / `FileBrowserTreeView`(→「一覧の読み込み」「ツリーの三角」) |
| 塞がる読み込みを積まない: 一覧は同じフォルダを読んでいる最中の読み直しを重ねず読み終えてから 1 回、ツリーの行も同じ、FSEvents のパスは URL を作らず文字列で親を求める(stat しない)、ネットワークの項目の絵は別の枠(2 件)、見張るものが無くなったら FSEvents の続きの位置を忘れる(2 回目の監査 17〜19) | `FileBrowserState.reload`(`inFlightFolderID`)/ `FileBrowserTreeView.loadChildren`(`isLoadingChildren`)/ `FileBrowserThumbnailProvider.maxConcurrentRemoteJobs` / `FolderChangeWatcher.forgetLastEventID` |

書く操作に関わるサンドボックスの事実(どれも 2026-09-14 に実測。詳細は「書く操作」「ドラッグ&ドロップ」):

- **ペーストボードから読んだ URL には、その項目自身への読み書きの許可が付く**(親フォルダには付かない)。そのため許可の無い場所の項目も
  貼れるが、移動すると元のフォルダへ書けず取り消せない。移動の前に元のフォルダを `access(W_OK)` で見て、書けなければ尋ねる。
- **Finder へのドラッグの移動は Finder が行う**(サンドボックスに掛からない。取り消しは Finder 側)。読み取り専用の間は出し口をコピーだけにする。
- **「置き換える」の起動時の復旧は、戻すフォルダの許可が開いてから走る**(`AppStores` の生成で `FolderAccessStore` が開いた後に
  `ReplaceBackupRecovery.runAtLaunch()`)。許可の無い場所の記録は戻せず、記録を残して次の起動でもう一度試す。
- 使い捨てボリュームとゴミ箱、テストホストから `hdiutil` を起動できない件は [10](10-sandbox-and-security.md#ゴミ箱と使い捨てボリューム改善要望7-段階-22026-09-13-実測)。

実機で確かめる手順(`tccutil reset` で初めての状態へ戻す、ダイアログは自動操作しない)は [12](12-verification-and-debugging.md#ファイルブラウザ)。

## シークレットウインドウ

決定事項 Q8: **ファイル操作は許し、保存だけしない**。シークレットウインドウで書かないもの: よく使う項目の登録・削除(「＋」「よく使う項目に登録」は淡色)、
最後に表示したフォルダ、一括リネームの前回の入力(そのウインドウの間は覚える)、コレクションの作成・登録、メタデータの編集、書き出しのカバーの選択。
表示の状態(表示形式・アイコンの大きさ・左の幅・隠したリストの列)は書く(痕跡にならない見た目の設定なので)。

**ファイルブラウザの絵はディスクキャッシュへ書かない**(2026-09-14、ユーザー判断。本のページのサムネイルを書かないのと揃える)。
アイコン表示のセルが `savesToDisk: !state.isPrivate` で頼み、提供役は同じ仕事を待つセルのどれか 1 つでも通常ウインドウなら書く
(`Job.savesToDisk`)。**読むのは許す**(何も残らない)。メモリの絵はアプリで共有するので、シークレットウインドウで作った絵を通常ウインドウが
メモリから受け取ったときも書かない(次の起動で作り直すだけ)。以前は提供役がウインドウを知らず、シークレットウインドウでも書いていた
(段階 9 の文書化で気づいた)。よく使う項目の中の動画の先回り(`FileBrowserVideoThumbnailWarmer`)はウインドウに関係なく書く
(シークレットウインドウではよく使う項目を足せない)。

## 保存するもの

| 値 | キー | 備考 |
|---|---|---|
| モード | `qooViewer.welcome.mode` | |
| 表示形式・アイコンの大きさ・左の幅・隠したリストの列 | `qooViewer.fileBrowser.*` | 環境設定の画面に並ばないので `qooViewer.pref.*` にしない(「初期設定に戻す」の対象外) |
| 最後に表示したフォルダ | `qooViewer.fileBrowser.lastFolderPath` | **パスだけ**(空文字はコンピュータ)。読む権限は `FolderAccessStore` だけが持つ。**シークレットウインドウでは書かない** |
| 一括リネームの前回の入力 | `qooViewer.fileBrowser.bulkRename`(JSON) | 方式ごとの欄を別々に覚える(Finder の `BulkRename*` と同じ)。**シークレットウインドウでは書かない**(そのウインドウの間は覚える) |
| よく使う項目 | `qooViewer.fileBrowser.favoriteLocations`(JSON) | パスだけ。「＋」は `NSOpenPanel` → `FolderAccessStore.add` → 登録。「＋」のパネルは一覧のいまのフォルダから始めるが、**直前の「＋」で足したフォルダにいる間は、そのとき閉じたパネルの `directoryURL` から始める**(`FileBrowserState.lastAddedFavoriteLocation`、2026-09-15、ユーザー要望。足すと一覧がその中へ移動し、次のパネルが中に入った状態で開いていた)。覚えるのはウインドウの間だけ。「足したフォルダの親」から始める案もあり、要望次第で戻す可能性がある(`addFavoriteLocation` のコメント)。右クリックの「よく使う項目に登録」は権限を足さない。シークレットウインドウでは登録・削除させない |
| 並べ替えの基準と向き | `qooViewer.pref.folderBrowserSortKey` / `…Direction` | サイドパネルのフォルダブラウザと共通(`AppPreferences`) |
| リストの列幅・並び | `NSTableView Columns v3 qooViewer.fileBrowser.list` など | `autosaveName` |
| 読み取り専用・起動時のフォルダ・フォルダを上に・現在のフォルダまでツリーを展開・ツリーのサブフォルダを右と同じ順に並べる・動画のサムネイルを生成・他のアプリからドロップしたとき・圧縮ファイルの形式・「ファイルブラウザで開く」の行き先・画像フォルダを開くとき | `qooViewer.pref.fileBrowser.*` | 環境設定「ファイルブラウザ」(`SettingsPane.fileBrowser`) |
| 絵のディスクキャッシュの ON/OFF・上限 | `qooViewer.pref.fileBrowserThumbnailCacheEnabled` / `…LimitMB` | 環境設定「キャッシュ」(ページサムネイルの設定と並べる。ユーザーの判断 2026-09-14) |
| 絵のディスクキャッシュ | `Caches/<bundle id>/FileBrowserThumbnails/` | 「サムネイル」。「すべてのデータを削除」で消える |
| 自動リネームの規則・除外・実行ログ | `qooViewer.fileBrowser.autoRename.rules` / `.excludedPaths` / `.activityLog`(JSON / 配列) | 「自動リネーム」。「すべてのデータを削除」で消え(ドメインごと)、「初期設定に戻す」の対象ではない。保存データの書き出しには含めない。実行ログは 500 件まで |
| 「置き換える」の退避の記録 | コンテナの `Application Support/FileOperations/replace-backups.json` | `ReplaceBackupJournal`。空になればファイルごと消す。**「すべてのデータを削除」で消える**(2026-09-14、ユーザー判断。それまでは対象から漏れていた)。消すのは終了時(と次の起動の最初)で、
予約した時点では消さない(終了までに走る置き換えが記録を要る)。途中で落ちて隠しフォルダに残っていた元の項目は、記録が消えると戻されず知らされもしない。テスト中はプロセスごとの一時フォルダ |

環境設定「ファイルブラウザ」には**いま効く行だけ**を置いた(読み取り専用・起動時のフォルダ・「ファイルブラウザで開く」の行き先・画像フォルダを開くとき・フォルダを上に・現在のフォルダまでツリーを展開・ツリーのサブフォルダを右と同じ順に並べる・動画のサムネイルを生成・他のアプリからドロップしたとき・圧縮ファイルの形式)。
絵のキャッシュの行は環境設定「キャッシュ」に置いた。

## リーク

`NSViewRepresentable` の delegate・メニュー・対象は `dismantleNSView` で切る。`FileBrowserActions` は相手を weak で持つ(`OpenWindowAction` は値なので
ペインの `onDisappear` で外す)。アイコン表示の空きスペースの右クリックの「表示」「表示順序」は `FileBrowserState` を weak で捕まえる Binding で作る
(`$state.viewMode` を渡すと `.contextMenu` を通じて閉じたウインドウの状態を残しえた。2026-09-14 の監査。`heap` ではまだ確かめていない)。
ウインドウを閉じるときは `FileBrowserState.releaseResources()`(FSEvents と購読)を `willClose` から呼ぶ。
2026-09-13 に新規ウインドウの開閉を 6 回繰り返し、`FileBrowserState` / `AppState` / `FileBrowserTableView` の生存数が増えないことを `heap` で確認した。

## テスト

| suite | 見るもの |
|---|---|
| `FileBrowserListingTests` | 全ファイル・隠しファイル・パッケージ、`notFound` / `needsAccess` の分類、コンピュータの行の選び方、絞り込み、退避先 |
| `FileBrowserListEditingTests` | リスト表示の名前の編集中に一覧が変わっても、編集していた項目の名前を変えること(表は自分で組み、Coordinator を本物で動かす) |
| `FileSystemChangeTests` | 知らせの中身(起きた順の付け替え・読み直しの要るフォルダ)、箱のまとめ方、エンジンが種類ごとに知らせること、別のウインドウの操作で読み直すこと、祖先の名前の変更に付いていくこと、カットの記憶がアプリで 1 つであること・ペーストボードが替わったら下ろすこと |
| `FileBrowserOpenBookGuardTests` | 開いている本(そのもの・祖先・中身)の名前の変更・移動・ゴミ箱を断り、コピーは通すこと |
| `BookRecordRelocatorTests`(FileBrowser の外) | アプリ自身が動かした本の保存データの付け替え(フォルダごと・キャプション・取り消し・先客のあるパス・**別ボリューム**) |
| `FileBrowserNameEditingTests` | 名前の編集を始めてよい条件、クリックの予約の取りやめ、リストの名前の欄がふだん編集できないこと、リスト・アイコン表示とも無い項目では始めず、編集中に項目が消えたら名前を変えずに取りやめること |
| `FileBrowserStateTests` | 外での変更で読み直す範囲(フォルダ自身と直下だけ、`/private` の書き方)、一覧と並べ替え(読み直さない)、保存、絞り込みと選択、上へ/戻る/進む、世代番号、消えたフォルダの退避、reveal、選択の維持、クリックと矢印、起動時のフォルダ、シークレットで書かない、type-select、名前の編集の依頼を下ろす・捨てる |
| `DirectoryProbeTests` | 三角の判定(ファイルだけ/フォルダあり、隠し・`UF_HIDDEN`・パッケージ・記号リンクを数えず一覧と一致、保護下と読めない場所は nil、既定の保護下の一覧) |
| `BulkRenameTests` | 一括リネームの名前の決め方を Finder の実測結果で固定(登録済みの拡張子・3 方式・日付の書式・番号を進める衝突・`name 2`・大文字小文字と正規化・使えない名前・押せる条件・例の行・開始番号の欄) |
| `ArchiveExtractionPlanTests` / `ArchiveExtractorTests` / `ZipCompressorTests`(FileOperations) | 捨てるパスの各種(`..` を `/` と `\` で、絶対パス、ドライブ名、制御文字、長い名前)・深い入れ子(PATH_MAX とスタック)・`__MACOSX` と記号リンク・書庫の中の名前の衝突・飽和加算・限度、Zip Slip の書庫を展開して外に何も書かないこと、zip(CP932 を含む)・7z・rar のフィクスチャを展開して reader の中身と一致すること、展開先での `name 2`、暗号化された rar、始める前の限度、中止で何も残らないこと、開けない書庫を越えて続けること、圧縮の中身(フォルダごと・隠しファイルを入れない・無圧縮と deflate)と展開しての往復、読めないサブフォルダで失敗すること、末尾の欠けた zip を置かないこと、NFC と bit 11、出力の名前と `name 2.zip`、圧縮の中止。ディスクフルは `FileOperationVolumeTests`(tiny ボリューム) |
| `FileDropPlanTests` | ドロップの移動/コピーの規則(ボリューム・⌥・⌘・元が移動を許さない)、自分の中へ・自分のフォルダへの移動を断る、他のアプリからのドロップと環境設定、カーソルの操作、読み取り専用モードで運ばないことと出し口のコピーだけのマスク |
| `FileBrowserOperationsTests` | ドロップの移動とコピーの混在が 1 回で戻る、⌥ で同じフォルダへの複製、コピー/カット/⌥⌘V の移動とコピーの判定、確認で止めたペーストのあともカットの記憶が残ること、同じフォルダの複製、衝突(スキップ・両方残す・置き換えと取り消し、ゴミ箱の無い場所で伝えること、ロックされた項目を含むフォルダの置き換え)、取り消せない移動の確認(尋ねない条件・中止・積まない移動・戻せない項目だけのコピー・中止した混ざった操作の報告)、同じ名前の別の項目に ⌘Z が触らないこと、ゴミ箱と完全削除の確認、ロックされた項目の確認とスキップ・移動・名前の変更、新規フォルダの名前と編集の依頼、名前の変更と取り消し・選択が外れていたら選び直さない、一括リネーム(表示順・1 回の取り消し・入力の保存とシークレット・キャンセル・使えない名前・ロック)、圧縮・展開(環境設定の拡張子・選択・取り消し、書庫でない項目を外す、保存先の選択とキャンセル、捨てたエントリの報告、メニューの判定)、直列、ツリーへの通知、残り時間、名前の選択範囲、読み取り専用モード(既定 ON・書く操作が全部何もせず尋ねもしない・取り消しの履歴を残す・走っている操作は止めない) |
| `FileCommandStackTests` / `FileCommandsTests`(FileOperations) | 積み方(深さ・部分的な取り消し・試し直せる取り消し・積まない操作)、まとめた操作の巻き戻しと取り消せない子の報告、各コマンドの取り消し(置き換わっていたら触らない・元の名前が埋まっていたら試し直せる)、一括リネームの失敗を越えて続けることと中止 |
| `LibraryFeatureToggleTests` / `WelcomeQuickOpenWidthTests` | ホームの形が 2 つの設定の組で決まること(`constrained` の表・切り替えの順・押し込まれたモードを保存しない・次のウインドウの最初の形・タイトル)。本棚を足す前のウェルカム画面の列幅の計算。「ファイルブラウザで開く」を入り口で断ることは `FileBrowserIntegrationTests` |
| `FileBrowserGoMenuTests` | 「フォルダへ移動…」のパスの解釈(`~`・相対パスを断る)、標準の場所が実際のホームフォルダの下 |
| `FileBrowserNavigationGestureTests` | サイドボタンの番号と `.swipe` の向き、2 本指のフリックが離したときに 1 回だけ返ること、縦スクロール・斜め・触れただけを数えない、横にスクロールできる一覧では端だけ、`.began` の無い並び・慣性・取り消し |
| `ReplaceBackupJournalTests`(FileOperations) | 起動時の復旧(戻す・上書きしない・再試行・片付いていた・壊れた記録)、置き換えの最中は記録があり成功・中止で消えること、ロックされた宛先を置き換えないこと、知らせる内容 |
| `FileCommandSoundTests`(FileOperations) | 音源の実在と登録、音の割り当て、成功とやり直しだけで鳴ること |
| `FileBrowserTreePathTests` | ツリーを現在のフォルダまで開く道筋(いちばん深い根、`/` の直下、根そのもの、名前の途中までの一致を祖先にしない、同じ深さの根、1 段の探し方)。同じファイルの `FileBrowserTreeAndIconHitTests` は FSEvents のパスの頭の揃え方とアイコン表示の名前のクリックの範囲、リスト・ツリーの当たり先の確かめ直し(`resolvedHit`) |
| `FileBrowserThumbnailTests` | 絵の種類の判定(パッケージ・記号リンク・保護下の場所・ネットワーク越しのフォルダ)、台帳の全書庫で選ぶエントリが 1 ページ目と一致、zip の除外と正準順、画像の無い・壊れた書庫、フォルダの直下だけ・隠しファイル、EPUB の spine の先頭と PDF の 1 ページ目、画像の縮小、透明な地の白、鍵(名前を変えても同じ・中身が変われば別)、ディスクキャッシュの往復と OFF で消えること、提供役のメモリ・ディスクの当たり・シークレットウインドウの頼みはディスクへ書かず読むだけ・作れなかった絵を覚える・同時の要求をまとめる・取り消し、段 |
| `FileBrowserVideoThumbnailTests` | 動画(段階 7b): コンテナの見分け方(qooLibrary の実機の先頭バイト列)・宣言し直す型と `dyn.` の型を弾くこと、Matroska の寸法と壊れた・巨大な大きさの細工で落ちないこと、作り方の並び(QuickLook → 再タグ付け)、動画の種類と環境設定、提供役(作ってディスクへ・別の提供役はディスクから・作れなければ覚える・環境設定を写す)、先に作る役(サブフォルダまで・作り済みを飛ばす・3 回失敗した拡張子を諦める/1 度でも成功したら諦めない・ネットワーク越しと途中のマウント・実体の無いファイル・隠しフォルダ・保護下の場所・入れ子の重複・OFF・止めたら残りへ進まない)。QuickLook と VideoToolbox の実物は使わない(入っている拡張と実物の動画しだい) |
| `FileBrowserIntegrationTests` | ⌥ で入れ替わる項目(元の項目のすぐ後ろ・並びの定義に載せない)、パス名をコピー、常にこのアプリケーションで開く(書けた項目だけ開く・知らせる・読み取り専用)。段階 8: ウインドウのタイトルの決め方、画像フォルダをダブルクリック / 右クリックの「開く」で開くときの設定との対応、AppKit のメニューに組んだ項目の action が NSObject のメソッドを指さないこと、「本ではありません」の説明の出し分け、「ファイルブラウザで開く」の出す場所と見せるもの、新しいウインドウへ選ぶ項目を渡す往復、出ていないときの予約と出たときの選択、本を開いていないウインドウのモード切替、右クリック 5 項目の淡色(シークレット・画像ファイル・複数選択)、サブメニューの中身、コレクションの作成(振り分けと本が無いときの報告)・登録(棚の展開と重複)、シークレットで書かないこと、メタデータの画像フォルダの判定、「このアプリケーションで開く」の候補の並べ方と覚え方の鍵、読み取り専用モードで淡色になる右クリックの項目とキーの操作 |
| `AutoRenameTests` | 自動リネームの名前の決め方(置き換えの大文字小文字・拡張子に掛けない・拡張子の丸ごとの置き換え・テキストの追加と既に付いているとき・順番・変え続ける規則・衝突と避けた名前・使えない名前)、対象の範囲、確認の印、JSON の往復、書き終わりの判定と Finder のコピー中の印 |
| `AutoRenameServiceTests` | 実行役を一時フォルダと本物の FSEvents で: 確認済みの対象の今ある項目、確認待ちと黙って確認済みにする場合、新しい項目と移ってきたフォルダの中身、フォルダの規則とサブフォルダの範囲、衝突、変え続ける規則を 1 回だけ記録、実行ログからの復元と除外、読み取り専用の間は復元しないこと、読み取り専用モード、よく使う項目の外、開いている本、Finder のコピー中、見つからない対象を OFF にして移動を提案・更新、ゴミ箱、別のボリューム、権限なし、保存 |
| `FileBrowserAutoRenameMenuTests` | 右クリックの「自動リネーム」の淡色、規則ごとのチェックで対象に入れる・外す、このフォルダの規則を作成、足せないフォルダ |
| `FileBrowserModelTests` | `GridKeyboardNavigation`、`WindowContentRequest` の往復と `nonce`、`FavoriteLocationStore`、`WelcomeLibraryState.mode` |

画面そのものは実機で確認する(→ [12](12-verification-and-debugging.md#ファイルブラウザ))。

## 既知の制限

2026-09-14(段階 9 の文書化)時点。各節に散っていたものを集めた。実機で確かめていないものは計画 §9.1。

表示と操作:
- ボリューム・フォルダのアイコンは種類の汎用アイコン(カスタムアイコン・ボリュームごとのアイコンは出ない)。アプリケーション以外のパッケージも汎用アイコン。パスバーの成分はパスの綴りのまま
  (Finder の「ユーザ」のような表示名にしない)。「種類」列は OS の言語。
- 検索は現フォルダの絞り込みだけ(再帰検索は無い。決定事項 Q9)。
- スプリングローデッドフォルダ(ドラッグで静止して開く)は無い(ツリーの行もドラッグ中は開かない)。Dock のゴミ箱へのドラッグは受け付けない。
- ~~アイコン表示の淡色のサブメニューには矢印が出ない~~(2026-09-15、アイコン表示を AppKit のメニューにした)。コレクションの中の右クリックは SwiftUI のままなので残る。
- ネットワーク上の共有では FSEvents が飛ばないので、**アプリの外での**変更はアプリがアクティブになるまで一覧・ツリーに出ない
  (アプリ自身の変更は `FileSystemChange` で届く)。
- 表示中のフォルダの祖先を**アプリの外で**名前変更・移動されても、アクティブ化まで気づかない(FSEvents に `WatchRoot` を付けていない)。
- 「同じフォルダのファイルを開く」の一覧は本を開いた時点のもの。右クリックから出したメタデータ・書き出しのシートは出した時点のパスを持つ。
- 無くなったよく使う項目の行には印が出ない(押すと祖先へ退避する)。履歴は別ボリュームへ移した本を追わない(ブックマークが追えない)。
- ~~ツリーは開いた時点の子を覚えたまま~~(2026-09-14、FSEvents で見張るようにした。「ツリーの三角」)。

書く操作:
- 取り消しの受領書はパスで持つ。外で名前を変えられた・移された項目の取り消しは「見つかりません」になる(別の項目に触らないことだけは `FileIdentity` で守る)。
- 許可の無い場所から来た項目(他のアプリでコピーしたもの)の移動は取り消せない(確認で「移動」を選んだ場合)。
- 別ボリュームへの移動は、事前の総量・ロック・コピー・確認の各段で木を最大 6 回歩く(2026-09-14 の監査で残した)。
- SwiftUI の受け口(右ペインの一覧の外 ―― 操作列など)では、他のアプリからのドラッグを「アプリの中のドラッグ」と取り違えうる古い記録を捨てられない
  (`DropInfo` にドラッグ元が無い。AppKit の受け口を一度通れば捨てる)。アイコン表示は 2026-09-15 から AppKit の受け口。
- 「すべてに適用」で「置き換える」を選んだあとの衝突の相手がロックされていると、尋ねずに「ロックされています」で止まる。
- 展開: rar・7z の記号リンクは中身の短いファイルになる、実行権などの属性は写さない、zip・7z の暗号化は見分けられず「読めませんでした」、
  途中でアプリが落ちると `.qooViewer-extract-<UUID>/` が残る(記録を持たない。元の項目は入っていない)。圧縮の `.qooViewer-compress-<UUID>.zip`、
  コピー・別ボリュームへの移動の `.qooViewer-copy-<12 桁>` も同じ(2 回目の監査の「低」で残した。片付けるには置き場所の記録が要る)。
- 展開・一覧の絵で、ソリッドの書庫の読み飛ばしの最中は中止が届かない(7z は C の中、rar はライブラリの中)。量は宣言サイズの限度で抑える。
- ウインドウを閉じたときにシートで答えを待っていた確認(衝突・ロック)の続きがどうなるかは実測していない(2 回目の監査の「低」)。
- 一覧の id はパスの `String` なので、正規化(NFC / NFD)だけが違う同じ名前の 2 項目(NFS など、正規化を区別するファイルシステム)は 1 つに見える。
- 「置き換える」の退避の記録はパスだけで持つ。退避を置いたフォルダの名前を変える・同じ名前の別のディスクを繋ぐと、記録を捨てるか戻せない。
- 取り消し・やり直しの進捗の帯は、移動の取り消しでは 1 件ずつ数え直す(受領書ごとに運ぶため)。

絵とアプリの候補:
- 書庫の中の書庫にしかページが無い本、サブフォルダにだけ画像を持つフォルダの本は絵が出ない(本を丸ごと開かないため)。
- mkv などの動画は、それを読める QuickLook 拡張があるときだけ絵が出る。
- 表紙に指定したページが追い出されている(iCloud)未登録の本の絵は、この起動の間は「作れなかった」と覚える(落としてきた後は次の起動で出る)。
- rar / 7z は、書庫の順で先頭の画像の前に 256MB を超えるファイルがあると絵が出ない(非ソリッドでも)。無圧縮の BMP などは 3200 万画素まで。
- 「このアプリケーションで開く」は種類で引くので、1 つのファイルだけに付けた既定のアプリは「(既定)」に出ず、拡張子の無いファイルは中身で見分けない。
