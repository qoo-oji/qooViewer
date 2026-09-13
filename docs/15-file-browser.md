# 15. ファイルブラウザ ―― ウェルカム画面のもう1つのモード

改善要望7(2026-09-13〜)。ウェルカム画面の帯の左端のボタンで、本棚([14](14-library-collections.md))と
**Finder の代わりに使えるファイルブラウザ**を切り替えます。検討の経緯と決定事項は
[plans/file-browser-study.md](plans/file-browser-study.md)、段階ごとの計画と引き継ぎは
[plans/file-browser-plan.md](plans/file-browser-plan.md) にあります。この章は**いま入っているもの**の説明です。

| 段階 | 内容 | 状態 |
|---|---|---|
| 0 | 蔵書の名前を出さない仕組み(→ [02](02-project-and-build.md)) | 済 |
| 1 | 環境設定の整理・帯の 2 ボタンの撤去 | 済 |
| 2 | ファイル操作エンジン(UI なし) | 済 |
| 3 | 画面(読むだけ): モード切替・ツリー・リスト・アイコン・操作列・パスバー・開く・新規タブ/ウインドウ・環境設定 | **済(2026-09-13)** |
| 4 | 書く操作の UI | **4a 実装中**(コピー/カット/ペースト・ゴミ箱・新規フォルダ・名前の変更・取り消し・進捗の帯。D&D は未) |
| 5〜9 | 一括リネーム・圧縮展開・サムネイル・既存機能との接続・文書 | 未着手 |

## 構成

```
WelcomeView(PanelSurface.welcome)
 ├─ WelcomeTopBar: [ファイルブラウザ] | ライブラリのチップ … ＋      ← | は WelcomeSeparator
 ├─ WelcomeSeparator(横)
 └─ mode == .shelf   → WelcomeLibraryPane(本棚)
    mode == .browser → FileBrowserPane
        ├─ FileBrowserTreeView(NSOutlineView): ボリューム / ホーム / よく使う項目 ＋
        ├─ WelcomeSeparator(縦。幅のドラッグ)
        └─ 右: 操作列 [‹ › ↑] [フォルダ名] [大きさ(アイコン表示のみ)][リスト][アイコン][並べ替え][検索]
               FileBrowserListView(NSTableView) / FileBrowserIconView(LazyVGrid)
               FileBrowserPathBar(NSPathControl)
```

| 型 | 置き場所 | 寿命 |
|---|---|---|
| `WelcomeLibraryState.mode`(`WelcomeMode`) | ViewModels | ウインドウごと。`qooViewer.welcome.mode` に保存し、次のウインドウは前回のモードで始まる |
| `FileBrowserState` | ViewModels | ウインドウごと(`ContentView` の `@StateObject`)。現在のフォルダ・一覧・選択・戻る/進む・表示形式・並べ替え・`FileCommandStack` |
| `FavoriteLocationStore` | ViewModels | アプリ全体(`AppStores`)。よく使う項目(パスだけ) |
| `FileBrowserListing` / `FileBrowserEntry` / `FileBrowserLoadError` | Services/FileBrowser | 一覧の読み取り(nonisolated、`FileIO` の上で呼ぶ) |
| `FileBrowserActions` | Views/FileBrowser | ペインの `@State`。3 つの一覧が共有する「開く」などの口(相手は全部 weak) |
| `WindowContentRequest` | Models | 本のウインドウの提示値(`book` / `browse`) |

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
ホーム ⇧⌘H(⌥ でライブラリ)/ コンピュータ ⇧⌘C / アプリケーション ⇧⌘A / ユーティリティ ⇧⌘U ― フォルダへ移動… ⇧⌘G。

- 置かないもの(qooViewer に無い機能。ユーザー指示): 最近の項目・最近使ったフォルダ・AirDrop・ネットワーク・iCloud Drive・共有・
  サーバへ接続、「内包しているフォルダ」の ⌥ / ⌃ の代替。
- 標準の場所は**実際のホーム**の下(`FileBrowserStandardLocation`)。開く前に触って確かめない(TCC の引き金になる)。読めなければ
  右ペインの「アクセスを許可…」、書類・デスクトップは TCC の確認も出る。
- 「フォルダへ移動…」(`FileBrowserGoToFolderSheet`): `/` か `~` で始まるパスだけ。`~` は実際のホームに読み替える。
  フォルダが無ければシートを閉じずに知らせる。読む権限は確かめない。
- 項目の数が変わるのは本を開く・閉じる・本棚と切り替えるときだけ(メニューを開いている最中には起きない)。

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
たびにウインドウが実際のホームを読みに行っていた(共有の状態に触れる。TCC の確認の引き金にもなりうる)。→ [12](12-verification-and-debugging.md#テスト中に出る虹色のカーソル)

## 一覧の読み込み

- **`FileIO.perform` の上で `FileManager.enumerator(… [.skipsSubdirectoryDescendants, .skipsHiddenFiles, .skipsPackageDescendants])`**。
  `DirectoryBrowser.listingAsync`(`Task.detached`)は流用しない ―― 応答しない共有で協調プールが塞がる(→ [03](03-architecture.md#並行処理の規約))。
  列挙の入口の失敗はエラーハンドラで拾って投げ直し、空のときだけ実在と読み取り権限を確かめる(読めないフォルダを空と取り違えない)。
- **全ファイルを出す**(サイドパネルは本だけ)。**子フォルダの中を見ない**(三角も件数も出さない)。
  1 フォルダを開くたびに子の数だけ列挙が増えるうえ、`~/Library` の保護領域に降りた瞬間に TCC のダイアログが出るため。
  画像フォルダかどうかは右クリックの「開く」を選んだときに 1 回だけ `ShelfFolderResolver.role` で調べる。
- パッケージ(`.app` など)は 1 項目。「フォルダを上に」ではファイルの側に並ぶ(Finder と同じ)。
- 並べ替えの比較はサイドパネルと**同じ実装**(`FolderBrowserSort.sorted`、`FolderBrowserSortable`)。
  「フォルダを上に」だけは環境設定「ファイルブラウザ」の独立した設定(サイドパネルの「並び順」とは別)。
- 絞り込み(検索欄)は現フォルダの中だけ。照合はウェルカム画面の検索と同じ `LibrarySearchQuery`。
  変わったら見えなくなった項目を選択から外す。フォルダを移ったら空にする。
- **世代番号で古い結果を捨てる**(速く移動したとき)。選択は残っている項目のぶんだけ保つ。
- 失敗の分類: 読めない → `needsAccess`(中央に「アクセスを許可…」)、無い・ボリュームが外れた → **残っているいちばん近い祖先へ移る**
  (外れたボリュームならコンピュータへ)。
- 「コンピュータ」(`currentFolder == nil`)は `MountTable` から作る。`/` と `/Volumes/` 直下のうち `MNT_DONTBROWSE` でないものだけ
  (`-nobrowse` で付けたディスクイメージは出ない)。ネットワーク越しのボリュームには名前も問い合わせない。
- 表示中のフォルダは `FolderChangeWatcher`(FSEvents)で見張り、**見えている間だけ**。アプリのアクティブ化とボリュームの着脱でも読み直す。
- 種類(「種類」列)は拡張子ごとに 1 回 LaunchServices へ問い合わせる。**文字列は OS の言語**(アプリの表示言語には従わない。LaunchServices の説明文を他の言語で引く手段が無い)。

## 選択・スクロール先は「パス」で持つ

列挙はフォルダの URL を末尾 `/` 付きで返し、外から渡される URL には付いていないことが多いので、URL の `==` では
同じ項目が別物になる。`FileBrowserEntry.id` = `url.path` で持ち、フォルダは `FileBrowserState.folderURL(_:)` で揃える。

## 移動の規則

- ダブルクリック / Return(リストは ⌘↓ も)= フォルダなら**画像フォルダでも中へ移動**(要望)、本と画像は qooViewer で開く
  (`AppState.open(urls:)`。複数選択は `BookOpenRequest` の規則)、それ以外は既定のアプリ。記号リンクは実体を解いてから。
- 右クリックの「開く」だけが画像フォルダを本として開く。
- 上へ = 元いたフォルダを選んで見える位置へ。ボリュームのルートの上はコンピュータ。
- 戻る = **戻り先が直前のフォルダの親なら、そのフォルダを選ぶ**(上へと同じ見え方)。
- ツリーの行を選ぶと右ペインがそこへ移る。右ペインで移動したら、その行が見えていれば選ぶ(見えていなければ選択を外す)。
- パスバーの成分をクリックすると、そのフォルダ(先頭はコンピュータ)へ。

## 新しいタブ・ウインドウで開く(`WindowContentRequest`)

本のウインドウの提示値を `BookOpenRequest` から `WindowContentRequest`(`.book(BookOpenRequest)` / `.browse(folder:nonce:)`)に広げた。
`BookWindowOpener.openFolder(_:to:from:openWindow:)` が開き、受け取った `ContentView` は `welcomeLibrary.mode = .browser` +
`fileBrowser.prepare(showing:)`。

- **`browse` は開くたびに `nonce` を変える。** `openWindow(id:value:)` は等値の値のウインドウを前面に出すだけなので、
  同じフォルダを 2 枚で見られなくなる(本はそれを二重に開かない砦として使っている)。状態復元は無効なので値は残らない。
- 通常ウインドウは `"book"` ではなく `"normal"` で開く(`BookWindowGroup.id(forBrowsing:inheritingFrom:)`)。
  `"book"` は `.contentSize` で、ウェルカム画面から始まったウインドウで本を開いた瞬間にフレームが作り直される。
- 重複の判定はしない。セキュリティスコープは本と同じ 10 秒の受け渡し(`SecurityScopedHandoff`)。
- 右クリックの「新規タブ/ノーマル/シークレットで開く」は、画像フォルダなら本として、それ以外のフォルダはファイルブラウザとして開く。

## AppKit とすりガラス面

リストとツリーは AppKit(決定事項 Q3。SwiftUI の `Table` の退行を避け、type-select・列幅の保存・段階 4 のレスポンダチェーンを標準で得る)。
面は `PanelSurface.welcome` なので、SwiftUI の輪郭修飾子が届かない部品を自前で描く(`FileBrowserAppKitParts.swift`):

| 部品 | 扱い |
|---|---|
| 行の文字・グループの見出し | `FileBrowserOutlinedTextFieldCell`(反対色の文字を上下左右にずらして後ろへ。選択中は掛けない) |
| 選択の地 | `FileBrowserRowView`(アクセント色の角丸 + 反対色の縁)。ウインドウが後ろでも白い文字 |
| 開閉の三角 | `FileBrowserOutlineView` がボタンの絵を輪郭入りに焼き直す(**無いと、ダーク+白100%で三角が消えた**。実測) |
| 「＋」 | `FileBrowserOutlinedIconButton` |
| 列の見出し | `FileBrowserTableHeaderView` が不透明な地を敷く(**既定の見出しは半透明で、ダーク+白100%で文字ごと消えた**。実測) |
| アイコン | 種類のアイコン(色付きの絵)なので掛けない |
| 「アクセスを許可…」 | `.borderedProminent`(不透明なアクセント色)。`.panelControlWell()` ではライト+黒100%で文字が読めなかった(実測) |
| パスバー | `controlBackgroundColor` の帯(不透明) |

アイコン表示は SwiftUI(`WelcomeGridColumns` の固定幅の列・`welcomeGridPinch`・`MarqueeSelection` を `.replacing` で)。
名前は未選択なら `.panelOutlinedContent()`、選択中はアクセント地 + `.panelOutlinedAccent(in:)`、選択中のアイコンの薄い地は `.panelOutlinedFrame(in:)`。

**アイコンは種類だけで引く**(`FileBrowserIconProvider`)。`NSWorkspace.icon(forFile:)` は到達できない共有で 30 秒ブロックし、
フォルダのカスタムアイコンを読みにデスクトップ・書類へ触れると TCC のダイアログが出る。本と画像の絵は段階 7 のサムネイルで出す。

`NSPathControl.url` は設定しない(メインスレッドで各成分の `realpath` とアイコン取得が走る。FB22294400)。`NSPathControlItem` を自分で組む。

## クリックとキー(アイコン表示)

`FileBrowserState.click(_:modifier:)`(1 件 / ⌘ 反転 / ⇧ 起点からの範囲)と `moveSelection(_:columns:)`(`GridKeyboardNavigation`)。
単発のクリックは `simultaneousGesture` で即時に効かせる。余白のクリックは選択を外し、余白からのドラッグは帯で選ぶ(修飾キーなしなら置き換え)。
リスト表示は `NSTableView` の標準のまま(⌘/⇧ クリック・矢印・type-select)。

## 右クリック

`FileBrowserMenuCommand.groups(for:)` が種類(`FileBrowserMenuKind`: フォルダ / ファイル / 空きスペース / ツリー)ごとの並びを持ち、
3 つの一覧で共有する(要望の一覧どおり)。種類は右クリックした 1 件で決める。
対象は「選択に含まれていればその全部、外ならその 1 件」。できない項目は淡色(**項目の数は選択の状態で変えない**)。
段階 6(圧縮・展開)と段階 8(コレクション・このアプリケーションで開く・メタデータ・書き出し)の項目は淡色で置いてある。
空きスペースには「表示」「並べ替え」のサブメニューが付く。ツリーのよく使う項目の行だけ「よく使う項目から削除」が付く。

## 書く操作(段階4)

- **窓口は `FileBrowserOperations` 1 つ**(`FileBrowserState.operations`、ウインドウごと)。リスト・アイコン・ツリー・編集メニューが
  ここを呼び、中で `FileCommandStack` にコマンドを積む。**操作は 1 本ずつ直列**(次は前が終わるのを待つ)。
- 確認・衝突・問題の報告は `FileBrowserOperationPresenting` へ渡す(本番は `FileBrowserSheetPresenter` がウインドウのシートで。
  テストは偽物)。**問題は進捗の帯を片付けてから見せる。**
- コピー/カット: ペーストボードへ `NSURL` を書く。カットは `FileBrowserState.cutPaths`(標準化したパス)にも覚え、淡く描く。
  ペーストは**ペーストボードの集合がカットの集合とそのまま一致したときだけ移動**、⌥⌘V は常に移動。同じフォルダへのコピーは尋ねずに `name 2` の複製。
- 衝突の確認は「両方残す / スキップ / 中止」(+「すべてに適用」)。**「置き換える」はまだ出さない**(途中で落ちたときに退避を戻す記録が無い)。
- ゴミ箱: `TrashAvailability` で見て、無い場所が混ざれば「すぐに削除されます」の確認(既定のボタンはキャンセル)→ 完全削除(積まない)。
- 新規フォルダ: ファイルメニュー(⇧⌘N。Finder と同じ。「新規シークレットウインドウ」は ⌥⌘N へ移した)・右クリック。
  「名称未設定フォルダ」(ぶつかれば番号)で作り、表示中のフォルダなら選んで名前の編集を始める(`renameRequest`)。
- 名前の変更(リスト): 名前の欄は `FileBrowserNameField`。選ばれた 1 行をもう一度クリック、または右クリックの「名前を変更」で始まり、
  編集中は表示名ではなく実際の名前を出して拡張子の前までを選ぶ。Esc で取りやめ。**編集中は一覧の読み直しを待たせる**(消えるため)。
- キー: リストは `FileBrowserTableView` が `copy:`/`cut:`/`paste:` を受け(標準の編集メニューが効く)、⌘⌫ / ⌥⌘V / ⌘[ / ⌘] / ⌘↑ を
  `FileBrowserEditCommand` へ。アイコン表示はコピー・カット・ペーストを `.onCommand`、⌘↑ を矢印キーの `.onKeyPress`、
  ⌘⌫ / ⌥⌘V / ⌘[ / ⌘] を **表示中だけのキー監視 `FileBrowserKeyMonitor`** で受ける(`.onKeyPress` では届かなかった。実測)。
  監視はテキストを編集中は受けない(検索欄の ⌘⌫ は文字を消す)。
- 空のフォルダでも一覧は置き、「このフォルダは空です」はその上に重ねる(案内だけにすると ⌘V と空きスペースの右クリックが効かない)。
- AppKit の右クリックメニューは `autoenablesItems = false`(既定のままだと淡色の指定が無視される)。
- 取り消す/やり直す: 編集メニュー(`CommandGroup(replacing: .undoRedo)`)。題はフォーカス中のウインドウの
  `MenuCheckmarkState.fileBrowserUndoTitle`(ファイルブラウザが出ているときだけ)。テキストを編集中ならその欄の `undo:` へ流す。
- 進捗の帯(`FileBrowserProgressBar`): パスバーの上。400ms 以内に終わる操作では出さない。「N 件中 M 件目 — バイト — 残り約」+ 中止。
  残り時間はバイトが動き始めて 1 秒経ってから。地は不透明なので輪郭は掛けない。
- 操作のあと: 表示中のフォルダを読み直して運んだものを選ぶ(ネットワークでは FSEvents が飛ばない)。ツリーは
  `fileSystemChange` を受けて、**開いていて子を読み終えている行だけ**読み直す(同じパスの行は同じ Node を使い回し、孫の開閉を保つ)。

## 保存するもの

| 値 | キー | 備考 |
|---|---|---|
| モード | `qooViewer.welcome.mode` | |
| 表示形式・並べ替えの基準と向き・アイコンの大きさ・左の幅 | `qooViewer.fileBrowser.*` | 環境設定の画面に並ばないので `qooViewer.pref.*` にしない(「初期設定に戻す」の対象外) |
| 最後に表示したフォルダ | `qooViewer.fileBrowser.lastFolderPath` | **パスだけ**(空文字はコンピュータ)。読む権限は `FolderAccessStore` だけが持つ。**シークレットウインドウでは書かない** |
| よく使う項目 | `qooViewer.fileBrowser.favoriteLocations`(JSON) | パスだけ。「＋」は `NSOpenPanel` → `FolderAccessStore.add` → 登録。シークレットウインドウでは登録・削除させない |
| リストの列幅・並び | `NSTableView Columns v3 qooViewer.fileBrowser.list` など | `autosaveName` |
| 起動時のフォルダ・フォルダを上に | `qooViewer.pref.fileBrowser.*` | 環境設定「ファイルブラウザ」(`SettingsPane.fileBrowser`) |

環境設定「ファイルブラウザ」には**いま効く行だけ**を置いた(起動時のフォルダ・フォルダを上に)。計画にある残りの行
(外からのドロップ・圧縮の拡張子・「ファイルブラウザで開く」の行き先・動画のサムネイル・キャッシュ)は、それを使う段階で足す。

## リーク

`NSViewRepresentable` の delegate・メニュー・対象は `dismantleNSView` で切る。`FileBrowserActions` は相手を weak で持つ。
ウインドウを閉じるときは `FileBrowserState.releaseResources()`(FSEvents と購読)を `willClose` から呼ぶ。
2026-09-13 に新規ウインドウの開閉を 6 回繰り返し、`FileBrowserState` / `AppState` / `FileBrowserTableView` の生存数が増えないことを `heap` で確認した。

## テスト

| suite | 見るもの |
|---|---|
| `FileBrowserListingTests` | 全ファイル・隠しファイル・パッケージ、`notFound` / `needsAccess` の分類、コンピュータの行の選び方、絞り込み、退避先 |
| `FileBrowserStateTests` | 一覧と並べ替え(読み直さない)、保存、絞り込みと選択、上へ/戻る/進む、世代番号、消えたフォルダの退避、reveal、選択の維持、クリックと矢印、起動時のフォルダ、シークレットで書かない |
| `FileBrowserOperationsTests` | コピー/カット/⌥⌘V の移動とコピーの判定、同じフォルダの複製、衝突(スキップ・両方残す)、ゴミ箱と完全削除の確認、新規フォルダの名前と編集の依頼、名前の変更と取り消し、直列、ツリーへの通知、残り時間、名前の選択範囲 |
| `FileBrowserGoMenuTests` | 「フォルダへ移動…」のパスの解釈(`~`・相対パスを断る)、標準の場所が実際のホームの下 |
| `FileCommandSoundTests`(FileOperations) | 音源の実在と登録、音の割り当て、成功とやり直しだけで鳴ること |
| `FileBrowserModelTests` | `GridKeyboardNavigation`、`WindowContentRequest` の往復と `nonce`、`FavoriteLocationStore`、`WelcomeLibraryState.mode` |

画面そのものは実機で確認する(→ [12](12-verification-and-debugging.md#ファイルブラウザ))。

## 既知の制限(段階 3 時点)

- **ツリーは開いた時点の子を覚えたまま**。このアプリの操作による変更は開いている行へ反映するが、Finder など外での
  フォルダの追加・削除は、その行をたたんで開き直すまで反映されない(右ペインは即時)。
- ボリューム・フォルダのアイコンは種類の汎用アイコン(カスタムアイコン・ボリュームごとのアイコンは出ない)。
- パスバーの成分はパスの綴りのまま(Finder の「ユーザ」のような表示名にしない)。
- ドラッグ&ドロップ・アイコン表示の名前の変更・「置き換える」は段階 4 の残り。「このアプリケーションで開く」は段階 8。
