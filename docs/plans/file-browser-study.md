# 改善要望7 検討メモ ―― ウェルカム画面のファイルブラウザモードと環境設定の整理

検討日: 2026-09-13 / ブランチ: `feature/file-browser` / 元の要望: `Memo/qooViewer改善要望 7.md`

このメモは「作る前の検討」。実現可否の判定・設計案・決めてほしいことを 1 枚にまとめる。
コードで先に触ったのは**段階0(流出対策)だけ**(§1)。それ以外はまだ触っていない。

参考にした一次資料: 同じ作者の qooLibrary(サンドボックス下の Finder 代替。フェーズ1完了)の
ソースと仕様書、および Web の一次情報(Apple のドキュメント/フォーラム)。qooLibrary から引く
事実は**あちらで実測されたもの**に限り、「実測」と明記する。

---

## 0. 要点

| 要望 | 結論 | 規模感 |
|---|---|---|
| 流出防止の多層防御を先に | **済**(§1)。禁止語リストはリポジトリの外、検査は `check-all.sh` + git hook(fail-closed) + CI の一般形。既存の流出 1 件を発見(→ §1.4、要判断) | 小(実装済み) |
| 環境設定の整理 2 件 | 可。「並び順を Finder に揃える」は 73 箇所・15 ファイル、「ウェルカム画面でも表示する」は 7 箇所。**保存済みのレイアウトは壊れない**(§2) | 小〜中 |
| ファイルブラウザモード | **可**。ただし「Finder と同様」を丸ごと実装する規模で、qooViewer の中で最大の機能になる(見積り 1 万行前後、テスト込み)。sandbox 下で成立しないものは無いが、**成立の仕方が Finder と違うもの**が 4 つある(§3.2) | 特大 |
| 一括リネームの Finder 模倣 | 文言・部品構成は Finder 本体の nib と `ja.lproj` から確認済み(§8)。**ビットパーフェクトは「同じ OS 版の Finder と並べて実測で合わせる」までは可能**、OS 版が変われば追従が要る | 中 |
| 動画の QuickLook サムネイル(mkv) | 可。ただし **mkv は OS 標準では出ない**。動作する QuickLook サムネイル拡張が入っていれば出る(qooLibrary 実測で採用できたのは App Store の QLMedia)。この機には現状その拡張が**無い**(`pluginkit` で確認) | 中 |

段階分け(§10)の順序は、**先に約束事と土台(操作エンジン・Undo)を UI 無しでテストしてから画面を載せる**。
qooLibrary のフェーズ1と同じ順で、あちらで実測済みの落とし穴をそのまま回避できる。

---

## 1. 流出対策(段階0。実装済み・未コミット)

### 1.1 なぜ「名前との一致」で見るのか

要望の実例「プロトタイプ」のとおり、**語の意味では判定できない**。qooLibrary の同じ検査
(`Scripts/check-private-data-leak.swift`)も、当初「カタカナ 4 文字以上・漢字 3 文字以上」の
抽出器で見ていて、**サークル名 1 件(カタカナ 2 文字+ひらがな+漢字 1 文字)が素通りした**(実測)。
以後は「抽出はコーパス側だけ、リポジトリ側は全文をそのまま走査」に変えている。ここでも同じ形にする:
**実在する名前の一覧**を蔵書から作り、リポジトリの全文と突き合わせる。

### 1.2 4 層

| 層 | 実体 | 何を止めるか |
|---|---|---|
| ① 禁止語リスト(**リポジトリの外**) | `scripts/dev/build-private-terms.py` → `~/Library/Application Support/qooViewer-dev/private-terms.txt`(5,100 語) | 蔵書のフォルダ名・ファイル名(拡張子あり/なし)、ホームのユーザー名、リポジトリの上位フォルダ名。ボリューム名・数字だけの名前・`qooViewer` は除く |
| ② 検査 `scripts/ci/check-private-terms.sh`(`check-all.sh` に追加) | ①との一致(NFC + 大小畳み。ASCII 語は単語境界、和文は**文字種の境界**で「語の一部」を除く ―― qooLibrary の実測に倣う) + リストが無くても動く一般形(`/Users/<名前>/…`、`/Volumes/<ボリューム>/<フォルダ>…`。説明用の `nobody`/`X`/`<名前>` は許可) + リストのファイルが追跡されていないこと | 追跡ファイルの中身とファイル名、**全コミットメッセージ、ブランチ・タグの名前** |
| ③ git hook(`scripts/git-hooks/`、`scripts/dev/install-git-hooks.sh` で `core.hooksPath`) | `pre-commit`(ステージ済みの中身)/ `commit-msg` / `pre-push`(push される範囲のメッセージ + 全体) | **リストが無ければコミットを拒否**(fail-closed)。「検査できなかった」を「問題なし」と読み替えない ―― qooLibrary の漏洩事故 4 回はすべて「検査の適用範囲が脅威の範囲より狭い」ことが原因だった |
| ④ `.gitignore` | `private-terms*.txt` / `*.local` | 万一リポジトリ内に置かれても追跡されない |

**検査の出力に語そのものを出さない**(既定)。検査の出力もまた漏洩経路(ターミナルの記録・AI との会話へ
写った語はそこからコピーされうる。qooLibrary では「除去の説明の中へ秘密を写す」事故が 3 度あった)。
手元で見直すときだけ `--reveal`。一般語として見逃す語は `private-terms-allow.txt`(同じくリポジトリの外)に
書く ―― **実在の固有名は絶対に足さない**(足した瞬間に検査が黙って無意味になる)。

確認したこと: 合成語で「拒否される」、リストが無いと「拒否される」、架空の `/Users/…` を含むメッセージが
「拒否される」、`check-all.sh` が全項目通る。**実名を使った試験はしない**(それ自体が漏洩になり、object として残る)。

### 1.3 運用の約束(CLAUDE.md へ書く)

- 蔵書のフォルダ名・ファイル名は、コード・コメント・docs・テスト・コミットメッセージ・スクリーンショット・
  **AI との会話**のどこにも書かない。書くのは「集計と形」だけ(「2,535 ファイル・深さ 2」はよい、名前は駄目)。
- 実機検証は使い捨てボリューム(`hdiutil` のディスクイメージ。ボリューム名は許されている)に**合成名**の本を置いて行う。
  実蔵書を表示したウインドウのスクリーンショットは撮らない。
- 検査を足したら「この検査は何を見ていないか」を書く。いま見ていないもの: 3 文字未満の固有名、
  ユーザー名の別綴り(ローマ字の語順違いなど)、バイナリファイルの中身、会話そのもの。

### 1.4 見つかった既存の流出(要判断 → §11 Q1)

②を現在のツリーと全履歴に掛けたところ、`qooViewer/Views/Export/ExportSharedViews.swift:209` のコメントに
**蔵書のルートフォルダ名**が書かれていた(保存先の表示名を説明する例示の中)。作業ツリーでは置き場所名を
`蔵書` に書き換えた。**過去のコミットには残ったまま**。qooLibrary の実測では、`git filter-repo` +
force push をしても **GitHub は到達不能オブジェクトをハッシュ直指定で配信し続けた**(4 ブランチの旧先端が
その後も API から取得できた)ので、消すならサポートへの依頼かリポジトリの作り直しが要る。
入っているのはルートのフォルダ名 1 語だけ(コミット `8adb1d9`、2026-08-30 以降。作品名・ファイル名は 0 件)で、
**ユーザーの判断(2026-09-13)は「そのまま」(作業ツリーだけ修正)**。

---

## 2. 環境設定の整理

### 2.1 「並び順を Finder に揃える」の撤去

- 設計上の位置: `PageOrder.swift` の「正準順(保存物)と表示順(適用点は `EffectivePageOrder` 1 か所)」の
  2 層のうち、**表示順の切替だけが消える**。正準順は Finder と同じ照合(`localizedStandardCompare`)で、
  既定は 2026-09-06 から ON なので、**既定のまま使っていた人には何も変わらない**。
- OFF にしていた人: 従来順(`.numeric`)で見ていたページ順が正準順に変わる。ただし**レイアウトを持つ本は
  `LayoutStore.pinPageOrderIfNeeded` で当時の並びに固定済み**なので、見開きの組み合わせは壊れない。
  固定されていない本は並びが変わるが、それは設定を ON にしたときと同じ挙動。
- 触るもの(73 箇所・15 ファイル): `AppPreferences.usesFinderSortOrder` とキー、`PageOrder.usesFinderOrder`
  (常に true として残すか、`comparePageOrder(usesFinderOrder:)` の引数ごと消すか → **消す**。
  `differsByOrderSetting` はピン留めの判定に残す)、`pageOrderSettingDidChange` 通知とその購読
  (`ViewerViewModel` / `BookLayoutEditorViewModel` / `BookExportViewModel` / `CollectionCoverExtractor.handlePageOrderSettingChange`)、
  `GeneralSettingsView` の行、`keys(for: .general)`、テスト 5 ファイル。
- UserDefaults のキー `qooViewer.pref.usesFinderSortOrder` は**読まなくなるだけ**(消さない。古い版を起動した
  人の設定を壊さない)。docs/07・13・MANUAL・CHANGELOG の記述も更新。

### 2.2 「ウェルカム画面でも表示する」の撤去

- `ContentView.isSidePanelSuppressedForWelcome` を「本を開いていない」だけの判定にする。常時表示でも
  隠す設定でも、本を開いていない間はサイドパネルを出さない(要望: ファイルブラウザとフォルダブラウザの同時表示を排除)。
- 触るもの: `AppPreferences.showSidePanelOnWelcome`(キーは残す)、`ContentView` 6 箇所、`QooViewerApp:838`
  (表示メニューの「サイドパネルを隠す」の無効化条件)、`GeneralSettingsView`、テスト 2 ファイル。
- 副作用: ウェルカム画面でサイドパネルの「履歴」「ブックマーク」「リソース」モードも見えなくなる。
  履歴はファイルメニュー、ライブラリのツリーはウェルカム画面そのもの、リソースは本を開いてから、で代替できる。

### 2.3 併せて消すもの(提案 → §11 Q2)

「本を開く…」「履歴から開く」のボタンを消すと、環境設定「一般」の「最近開いた本を表示する」
(`showRecentFilesOnWelcome`)は**このボタンの出し分けにしか使われていない**ので効かない設定になる。
行ごと消す(キーは残す)ことを提案する。

---

## 3. ファイルブラウザモード ―― 全体設計

### 3.1 画面

```
WelcomeView(PanelSurface.welcome)
 ├─ WelcomeTopBar(44pt): [ファイルブラウザ] | ライブラリのチップ | ＋      ← 「本を開く…」「履歴から開く」は消える
 ├─ Divider
 └─ (mode == .shelf)  WelcomeLibraryPane                               ← 従来どおり
    (mode == .browser) FileBrowserPane                                  ← 新規
        ├─ HSplitView 相当(自前の幅ドラッグ。SidePanelView の widthDragHitArea と同じ作り)
        │   ├─ FileBrowserTreePane(左): [ボリューム][ホーム][よく使う項目 ＋]
        │   └─ 右:
        │       ├─ 操作列: [‹ › ↑] … 検索欄(中央) … [表示切替][並べ替え][スライダー]   ← WelcomePaneHeaderLayout を流用
        │       ├─ FileBrowserListView(Table) / FileBrowserIconView(LazyVGrid)
        │       └─ FileBrowserPathBar(NSPathControl)
        └─ 進捗の帯(圧縮・展開・コピー中だけ、パスバーの上に出る。中止ボタン付き)
```

- **「ファイルブラウザ」はチップの左に置く同じ形のボタン**(帯の見た目は変えない。要望)。押すたびに
  `.shelf` ⇄ `.browser` を切り替える。選択中のライブラリのチップを押せば棚へ戻る。
- モードは `WelcomeLibraryState.mode`(ウインドウごと。UserDefaults `qooViewer.welcome.mode` に保存。
  次に開くウインドウは前回のモードで始まる ―― Finder を使う人はいつもファイルブラウザ)。
- 「ウェルカム画面へ戻る」で帰ってきたときは、離れたときのモードとフォルダに戻る(棚の `openedCollectionID` と同じ扱い)。
- すりガラス面の約束(CLAUDE.md)はこの面全体に掛かる。`Table` と `NSPathControl` は自前の不透明な地を持つ
  (`Table` の行は `.alternatingRowBackgrounds`、パスバーは `.controlBackgroundColor` の帯を敷く)ので輪郭は不要、
  ツリーの行・操作列のアイコン・空のときの案内は `.panelOutlinedContent()`、選択枠は `.panelOutlinedAccent(in:)`。
  ダーク+白 100% / ライト+黒 100% で実測してから完了にする。

### 3.2 sandbox 下で Finder と違う成立の仕方をするもの(要望と照らして先に言っておくこと)

| 要望 | Finder | このアプリ(sandbox) | 根拠 |
|---|---|---|---|
| ホームを表示 | 常に見える | **初回に一度、ホームを「アクセスを許可」で選んでもらう**(`FolderAccessStore` に入る)。以後は起動のたびに自動 | 実ホーム(`~`)は entitlement でも開かず、user-selected の許可が要る(qooLibrary 実測表) |
| デスクトップ・書類・ダウンロードへ入る | 見える | 入った瞬間に **macOS の TCC ダイアログ**が 1 回出る(許可すれば以後は出ない。署名の同一性が同じ限り) | TCC は sandbox とは別レイヤ。「`/` を許可しても TCC は通さない」(qooLibrary 実測)。qooViewer は Debug も Team で署名しているので、ad-hoc で毎ビルド失効する qooLibrary の問題は起きにくい |
| ゴミ箱に入れる | どこでも | **起動ボリューム(と `.Trashes` を持つ外付け)だけ**。SMB 共有にはゴミ箱が無く、そこでは「すぐに削除されます」の確認 → 完全削除(Undo 不可) | qooLibrary 実測: SMB 3 系統すべてでゴミ箱なし。`NSWorkspace.recycle` は OS の確認を出して完全削除し、返す URL は 0 件 |
| カット → Finder でペースト | Finder 同士だけ | **アプリ内でだけ移動**。Finder へ貼るとコピー | Finder のカット判定はプライベート API(qooLibrary の割り切り) |

「ホームを表示」の初回の許可は、起動時フォルダが「ホーム」のときにファイルブラウザを最初に開いた瞬間に
`NSOpenPanel`(`directoryURL = 実ホーム`、「アクセスを許可」)で求める。**実ホームのパスは
`getpwuid(getuid())->pw_dir`** で取る(`FileManager.homeDirectoryForCurrentUser` は sandbox ではコンテナを返す。qooLibrary 実測)。

### 3.3 TCC のダイアログを「勝手に」出さないための約束

qooLibrary で「フォルダを開くだけで TCC のダイアログが次々に出る」(ユーザー報告)の真因は 2 つ、どちらも対策を写す:

1. **`~/Library` 配下の保護領域(`Containers` / `CloudStorage` / `Mail` / `Safari` / `Group Containers` /
   `Application Support` …7 種)へ、三角マークの判定や件数の集計が降りていた。** → 判定に使う
   「サブフォルダがあるか」の `readdir` を**パス文字列だけで**保護領域と分かるものには行わない
   (`DirectoryProbe.isPrivacyProtected` の写し。`NSFileProviderManager` で判定するのは駄目 ―― それ自体が同じ TCC を要求する)。
   このアプリの `DirectoryBrowser.directContents(of:)` はフォルダ 1 件につき 1 回列挙している(「直下に画像があるか」の判定)ので、
   **ファイルブラウザの一覧ではこの判定を保護領域とパッケージに対して省く**。
2. **再ビルドごとに署名の同一性(CDHash)が変わり、TCC の記録が捨てられる。** → qooViewer は `Local.xcconfig` の
   Team で署名しているので該当しないが、**CI 用の署名上書き(`CODE_SIGNING_ALLOWED=NO`)を手元のビルドで使わない**
   (既に CLAUDE.md の約束)。

加えて: パッケージ(`.app`、`.photoslibrary` 等)は **1 項目として扱い中へ降りない**(Finder と同じ。写真ライブラリの
中を覗くと出る TCC も止まる)。ダイアログが出たら**消さずにユーザーに見せる**(`killall UserNotificationCenter` は
「拒否」として記録される ―― qooLibrary 実測)。

### 3.4 状態の置き場所

| もの | 置き場所 | 寿命 |
|---|---|---|
| モード・現在のフォルダ・戻る/進む・選択・表示形式・並べ替え・アイコンの大きさ | `FileBrowserState`(新規。`ContentView` が `@StateObject`。`SidePanelBrowserState` と同じ形) | ウインドウごと |
| 起動時のフォルダ(ホーム/よく使う項目のどれか/最後のフォルダ)、フォルダを上に、外からのドロップの意味、圧縮の拡張子、動画サムネイル ON/OFF、サムネイルのキャッシュ上限 | `AppPreferences`(`qooViewer.pref.fileBrowser.*`)+ 環境設定「ファイルブラウザ」 | アプリ |
| 最後に表示したフォルダ | `LastUsedFolderMemory`(セキュリティスコープ付きブックマーク + 表示用パス)。**シークレットウインドウでは書かない** | アプリ |
| よく使う項目 | `FavoriteLocationStore`(新規、UserDefaults)。**持つのはパスだけ**。列挙の権限は `FolderAccessStore` に一本化(コレクションの自動登録フォルダと同じ判断 ―― 同じフォルダの権限を 2 箇所が別々に開閉しない) | アプリ |
| Undo の履歴 | `FileCommandStack`(新規。ウインドウごと ―― Finder と同じ。アプリ全体で 1 本にすると別ウインドウの操作を取り消せてしまう) | ウインドウごと |
| サムネイル | `~/Library/Caches/<bundle id>/FileBrowserThumbnails/<volumeUUID>-<inode>-<mtime>-<size>.jpg` | キャッシュ(上限あり) |

「よく使う項目」の「＋」は `NSOpenPanel` → `FolderAccessStore.add` → パスを登録。**フォルダを登録すれば
その配下の権限も付いてくる**ので、蔵書のルートを 1 つ登録すればブラウザの主な用途は足りる。

### 3.5 新しいウインドウ/タブへ「フォルダを開いた状態」を渡す

いまの 4 つの `WindowGroup` は値として `BookOpenRequest`(本)しか受け取れない。フォルダを新規タブ/ウインドウの
ファイルブラウザで開くために、提示値を `WindowContentRequest`(`case book(BookOpenRequest)` / `case browse(folder: URL)`)へ
広げる。`BookWindowOpener.open` はそのまま(`BookOpenDestination` の 4 つの行き先・`SecurityScopedHandoff` の
10 秒の受け渡し・重複判定を流用)。`browse` は重複判定の対象外(同じフォルダを 2 枚で見てよい)。

### 3.6 既存機能との接続

| 要望の項目 | 使うもの |
|---|---|
| 開く(書庫/PDF/EPUB/画像/画像フォルダ) | `AppState.open(urls:)`(`BookOpenRequest` の正規化をそのまま通す)。**画像フォルダのダブルクリックは移動**(要望)なので、判定は `DirectoryBrowser.Entry.containsImageFile` ではなく「フォルダなら移動」で一律。「開く」(右クリック)だけが画像フォルダを本として開く |
| 新規タブ/ノーマル/シークレット | `BookOpenContextMenuItems` + `BookWindowOpener`(§3.5 の拡張) |
| コレクションを作成 / 登録 | `WelcomeLibraryState.pendingCreations` / `addingBooks` と `CollectionStore.makePendingItems`。「画像フォルダ以外はグレーアウト」は `ShelfFolderResolver.role` の `.book` で判定(**一覧の読み込み時に確定**。`.contextMenu` の中でディスクを触らない) |
| メタデータを編集 | `BookMetadataSheet` は `CollectionItem` の id を要求する。**URL から開ける版**を足す(`itemID: nil`、表紙の面は出さない)。「メタデータの編集」ウインドウと同じ `MetadataEditorViewModel.initialDraft` |
| 本を書き出す(EPUB/PDF/CBZ) | `OpenBookExportSheet` は `MangaBook` を要求する。**`BookLoader.load` で読み込んでから**同じシートを出す(`BookLoadingOverlay` で進捗)。シークレットウインドウではカバー選択を出さない、は従来どおり |
| このアプリケーションで開く | `NSWorkspace.shared.urlsForApplications(toOpen:)`(macOS 12+)で候補、`open(_:withApplicationAt:configuration:)` で起動。既定アプリは `urlForApplication(toOpen:)` を先頭に |
| Finder で表示 | `FinderReveal.reveal` |
| ファイルブラウザで開く(既存の 11 箇所) | `AppState` に `revealInFileBrowser(url)` を足し、`WelcomeLibraryState.mode = .browser` + `FileBrowserState.reveal(url)`(親フォルダへ移動して選択)。**本を開いている間は新規タブで**(§11 Q6) |

---

## 4. ファイル操作エンジン(UI 無し。段階2)

### 4.1 型

```
Services/FileOperations/
  FileOperationService.swift   actor。状態を持たない(I/O のあいだ actor を解放する)
  FileIO.swift                 ブロッキング I/O を専用のスレッドで走らせる(下記)
  FileCopyEngine.swift         copyfile(3)(COPYFILE_CLONE|ALL|EXCL|NOFOLLOW|RECURSIVE)+ status callback
  FileOperationTypes.swift     ConflictPolicy / TransferReceipt / TrashReceipt / PartialTransferFailure
  TrashAvailability.swift      そのボリュームにゴミ箱があるか(url(for: .trashDirectory, create: false))
  MountTable.swift             getmntinfo_r_np(MNT_NOWAIT)。ボリューム判定はこれだけ(ファイルシステムに触らない)
  FileNameValidation.swift     禁止は `/` `.` `..` と長さだけ(qooLibrary 実測: どの形式もそれ以外は受け付ける)
ViewModels/FileCommands/
  FileCommand.swift            protocol(execute/undo/redo、displayName、isUndoable)
  FileCommandStack.swift       深さ 50。部分取り消しは redo へ積まない
  MoveFilesCommand / CopyFilesCommand / RenameCommand / TrashCommand / CreateFolderCommand / BulkRenameCommand / CompressCommand / ExtractCommand
```

**qooViewer に既にあるもので代用できるか**: `DirectoryBrowser` は一覧を読むだけで書き込みが無い。
`TemporaryFileStore` は一時ファイルの置き場として流用。`FileNodeIdentifier`(volumeUUID + inode)は
サムネイルの鍵と「大文字小文字だけの改名」の同一性判定に流用。

### 4.2 OS API と、qooLibrary の実測から写す決めごと

| 操作 | API | 写す決めごと(実測の根拠は qooLibrary) |
|---|---|---|
| 移動(同一ボリューム) | `renamex_np(RENAME_EXCL)` → `ENOTSUP` なら `lstat` + `rename(2)` | **SMB では宛先が無いときだけ `ENOTSUP`**(宛先ありは `EEXIST`)。衝突の場合しか測っていないと「動く」と誤認する |
| 移動(別ボリューム) | `copyfile` + 元削除 | 運搬中に元が変わったら宛先を消して失敗。ただし **SMB は書き込み直後の更新日時が数百 ms 後に変わる**(fsync しても)ので、更新日時だけの差は中身(64KB × 先頭/中央/末尾)で決める |
| コピー | `copyfile(3)` | **`FileManager.copyItem` は APFS でクローンする(1GB が 3ms)**ので `COPYFILE_CLONE` 必須。`COPYFILE_EXCL` は man page の「implies」を信じず自分で付ける(付けないと既存を黙って上書きした)。status callback でエラー段階に `COPYFILE_CONTINUE` を返さない |
| ゴミ箱 | `NSWorkspace.shared.recycle` | `FileManager.trashItem` ではなく recycle(Finder の「戻す」と互換)。返る対応表の URL を `TrashReceipt` に持ち、Undo は `moveItem(trashURL → 元)`。**sandbox でも実ホームの `~/.Trash` が返り、戻せる**(実測)。UI 文脈の無いプロセスでは完了ハンドラが永久に来ないので 120 秒の期限 |
| 新規フォルダ | `createDirectory` の前に存在確認 | `withIntermediateDirectories: true` は既存でもエラーにならない |
| 名前変更 | `moveItem` | 大文字小文字だけの改名は `fileExists` が true になるので inode で同一判定 |
| 完全削除(ゴミ箱の無いボリューム) | `removeItem` | SMB では中身のあるフォルダの削除が **5 回に 1 回 `EPERM`** で失敗し、100ms 後には必ず通る → `EPERM`/`EBUSY` は 3 回まで再試行 |
| 衝突 | 3 択(置き換える/両方残す/スキップ)+「以降すべて」 | 「両方残す」は Finder 流の `name 2.ext`。`.replace` は消さず同じフォルダへ退避してからコピーし、成功したら退避を**ゴミ箱へ**(直後の ⌘Z で元が戻る)。空き判定は `attributesOfItem`(`fileExists` はリンクを辿る) |
| 事前検査 | `access(W_OK)`、`PATH_MAX`、名前長、`volumeMaximumFileSize`、空き容量 | 書き込み可否は `volumeIsReadOnly` でもモードビットでも駄目で `access(2)` だけが正しい。宛先が元の中(コピーは `copyfile` が 332 階層まで自己増殖した)。**同一ボリューム内の移動は走査も空き検査もしない** |
| 進捗 | 100ms の間引き。**項目の最初のバイトは間引かない** | 速いディスクでは 1 項目が窓に収まって「最中」の報告が一度も出ない |

### 4.3 スレッド ―― `FileIO`(ここが土台)

qooViewer は「メインアクターの外で走らせる」を `Task.detached` で行ってきた(協調スレッドプール)。
ファイル操作ではそれが足りない ―― qooLibrary 実測: **コア数ぶんの同期ブロッキング I/O を `Task` で走らせると、
ごく普通の `Task` が 5 秒間一度も動かなかった**。SMB は無応答時 30 秒、NFS(hard)は無限にブロックする。

| 実行先 | 枯渇中に 4 件のブロッキング I/O を始められるか(qooLibrary 実測) |
|---|---|
| private concurrent queue | 0/4(10 秒待っても始まらない) |
| `DispatchQueue.global()` | 0/4 |
| **投入ごとに新しい serial queue** | **4/4 が 0ms で開始**(費用は 1 件約 1µs) |

→ `FileIO.perform { }` = 投入ごとの serial queue で走らせ、`await` で受ける。**期限付きの版(`withDeadline`)のタイマーは
`DispatchSource`**(`Task.sleep` も `asyncAfter` も枯渇中は発火しなかった)。取り消しは `Task.isCancelled` ではなく
自前の `Cancellation` フラグ(借りたスレッドには Task の文脈が無い)。

このアプリでは既に `CollectionAutoFolderRow` の `FolderExistenceProbe`(「スレッドプールの外の直列キューで 1 本ずつ」、
監査で指摘 2026-09-13)が同じ理由で同じ形をしている。`FileIO` はそれをアプリ全体の道具にしたもの。
**`DirectoryBrowser.listingAsync` などの既存の `Task.detached` は、この機能では `FileIO` へ寄せる**(一覧の読み込みも
ネットワーク上ならブロックする)。既存の呼び出し元は触らない。

### 4.4 Undo / Redo

- **自前のコマンドスタック**(`NSUndoManager` は使わない。qooLibrary と同じ)。理由: 取り消しが非同期・部分成功がある・
  「戻せなかった」を必ず見せる・進捗と中止が要る ―― `registerUndo` のクロージャ 1 本では表せない。
- 編集メニューの「取り消す/やり直す」は今 `CommandGroup(replacing: .undoRedo) { }` で空。**ファイルブラウザが
  フォーカスされているときだけ**動的な題(「"X" の移動を取り消す」)で出す。テキスト欄(検索欄・リネーム中)が
  ファーストレスポンダなら標準の `undo:` へ流す(qooLibrary の `TextEditingKeyRouting` と同じ形)。
  題の文字列は `String(localized:language:)` で表示言語に従う(`.commands` は `@Environment(\.locale)` が届かない ―― qooLibrary 実測)。
- 取り消せるもの: 移動・コピー(生成物をゴミ箱へ)・名前変更・一括リネーム・ゴミ箱(戻す)・新規フォルダ(空のときだけ)・
  圧縮(生成物をゴミ箱へ)・展開(作った項目をゴミ箱へ。「ここに展開」は他と混在するのでフォルダ丸ごとは消さない)。
  取り消せないもの: ゴミ箱の無いボリュームでの削除。
- 移動の取り消しは `.keepBoth` で戻す(壊さない)。名前が変わって戻ったら「部分的に戻した」として見せる。

---

## 5. 圧縮・展開(段階6)

### 5.1 圧縮(zip のみ)

- **ZIPFoundation で書く**(libarchive は同梱しない。qooViewer の依存を増やさない)。`Archive(url:accessMode:.create)` +
  `addEntry(with:relativeTo:compressionMethod:progress:)`。エントリ名は **NFC に正規化**してから渡す
  (`nfcNormalizedForExport` が既にある。APFS は NFD で返す)。ZIPFoundation は汎用フラグ bit 11(UTF-8)を常に立てる(2026-09-03 実測)。
- 圧縮方式はエントリごと: 画像・書庫・PDF・EPUB は `.none`(既に圧縮済み。速くて同じ大きさ)、それ以外は `.deflate`。
- `.DS_Store` / `._*` / 隠しファイルは入れない(`skipsHiddenFiles`)。
- 出力名: 1 件なら `<その名前>.zip`、複数なら `<カレントフォルダ名>.zip`(要望)。拡張子は環境設定で zip/cbz。
  衝突は `name 2.zip`(Finder と同じ「両方残す」)。
- **同じフォルダの一時名(`.qooViewer-compress-<UUID>.zip`)へ書いて `replaceItemAt`**(qooViewer の書き出しと同じ。
  中止・失敗で出来損ないを残さない)。qooLibrary はコンテナのステージングから運ぶ形だが、あちらで
  「別ボリュームなら実コピーになり数秒かかる」と実測されている。
- 進捗: `Progress`(ZIPFoundation がチャンクごとに報告)を 1/30 秒で間引いて UI へ。中止は `withTaskCancellationHandler` の
  `onCancel` で `progress.cancel()` → `ArchiveError.cancelledOperation`。**`Archive` は `Sendable` ではない**ので detached task の中で作り、
  外へ出さない(`PageLoader` の reader と同じ)。`bufferSize` は 16KiB の既定ではなく 1〜4MiB。
- 空き容量の事前検査(非圧縮の総バイト数。qooLibrary は「無かったせいで libarchive の "Write error" 1 語しか出なかった」)。

### 5.2 展開(zip/cbz/rar/cbr/7z/cb7/epub)

- 読むのは既存の `ArchiveReading`(zip = ZIPFoundation、rar = Unrar.swift フォーク、7z = SevenZip.swift フォーク。
  EPUB は zip)。**書庫の文字コードは `EntryNameDecoder`**(書庫全体で 1 回、Foundation)をそのまま使う(既に zip の
  読み込みで CP932 を補正している。既知の制限: EUC-JP は当たらず、CP949 は倒れる ―― docs/13)。
- **書き込みは一時フォルダ(展開先と同じフォルダの `.qooViewer-extract-<UUID>/`)へ全部出してから、
  項目ごとに `renamex_np(RENAME_EXCL)` で最終位置へ**(衝突は「両方残す」)。中止したら一時フォルダごと消す
  (qooLibrary: 「ユーザーが止めたのに 20MB の中途半端なフォルダが残り、成功として扱われていた」)。
- 安全策(qooLibrary の `EntryPathValidation` + `SecureExtractor` を写す):
  絶対パス・`..`(区切りは `/` と `\` の両方)・NUL/制御文字・記号リンク・特殊ファイル・**実体解決後に展開先の外へ出るもの**を捨てる、
  `__MACOSX/` と `._*` を捨てる(qooViewer の `isAppleDoubleEntry`。**qooLibrary には無かった穴**)、
  大文字小文字だけ違う名前は `name 2` に改名、宣言サイズの合計は**飽和加算**(攻撃者が書ける値で `+` がトラップした)、
  非圧縮合計 20GB・エントリ 10 万・圧縮比 1,000 倍で中断、展開先の空き容量、
  **`FileHandle.write(contentsOf:)`(throwing 版)** ―― 非 throwing の `write(_:)` はディスクフルで ObjC 例外 → SIGABRT(実測)。
- 7z はソリッドなので**書庫順に読む**(フォークのストリーミング経路。後方読みをしない ―― `sevenzip-access-pattern-rules` の約束)。
  rar は `Archive.extract(entry, handler:)` のストリーミング。分割 rar・暗号化書庫は非対応(既存の制限)。
- 展開先の名前: 「ここに展開」= カレント直下、「〈書庫名〉に展開」= 同名フォルダを作って(無ければ)その中、「展開…」= `NSOpenPanel`。
  フォルダ作成 + 展開は 1 つの Undo 単位。
- 進捗: エントリ境界 + 大きな 1 エントリの途中でもバイト単位。

---

## 6. サムネイル(段階7)

### 6.1 本(zip/cbz/rar/cbr/7z/cb7/PDF/EPUB/画像フォルダ)の先頭画像

2 段構え(§11 Q5):
1. その本がコレクションに登録済みで `CollectionCovers/<itemID>.jpg` があれば**それを使う**(棚と同じ絵。読み込み 0)。
2. 無ければ**安い経路**で先頭画像を 1 枚だけ取る: zip/cbz は中央ディレクトリから画像エントリを名前順に選び 1 件だけ読む
   (qooLibrary 実測: 200 頁 60MB の zip で一覧 1.1ms + 1 件 0.5ms)、rar/7z は書庫順の先頭の画像エントリ
   (ソリッドでも先頭は安い)、PDF は 1 ページ目を `CGPDFDocument` で、EPUB は spine の先頭、画像フォルダは名前順の先頭。
   **`BookLoader.load` は使わない**(本を丸ごと開く。棚の表紙抽出と同じ費用でグリッドには重すぎる)。
   `isAppleDoubleEntry` と `isImageFile` で候補を絞る。正準順(`compareCanonicalPageOrder`)で先頭を決めるので、
   レイアウトで並び替えていない本なら棚の表紙と一致する。

### 6.2 動画(QuickLook)

- `QLThumbnailGenerator.shared.generateBestRepresentation(for:)`、`representationTypes: .thumbnail`(`.icon` は
  ファイルによらず同じ汎用アイコンを返す ―― qooLibrary 実測で MD5 一致)。**8 秒で `cancel(request)`**(呼ばないと
  完了ハンドラが来ずスコープが抜けられない)。成功したら眠っているタイムアウト側を起こす(片方欠けると
  成功 1 件ごとにスロットを 8 秒占有した)。
- **mkv**: OS 標準では出ない(`qlmanage -t` が 2 分以上応答しなかった)。動作する QuickLook サムネイル拡張が
  入っていれば出る。qooLibrary の実測: QLVideo は `.thumbnail` に非対応(拡張点を持たない)、QLCodec-mkv は同時要求で
  結果が入れ替わり上下反転、**QLMedia(App Store)で決着**(2026-08 時点)。その後 QLVideo 3.x は Media Extensions 方式へ移り、
  AVFoundation/QuickLook 側に mkv を足す形になった(§12)。**この機にはいま mkv 用の拡張が無い**(`pluginkit`)。
  写す 3 点: `MediaContainerSniffer`(先頭 16 バイトで実体を判定し、`.mp4` を名乗る Matroska には `Request.contentType`
  で mkv の型を渡す。`UTType(filenameExtension:)` は未知でも `dyn.` の型を返すので `conforms(to: .movie)` で弾く)、
  `MatroskaDimensionReader`(QLMedia は正方形にスクイーズするので、EBML の `PixelWidth/Height` を先頭 8MB から読んで
  要求サイズを補正)、`hev1` HEVC の再タグ付け(`AVAssetReader` パススルー → `hvc1` として `VTDecompressionSession`)。
- 背景生成は**よく使う項目の配下の動画だけ**(要望)。逐次 1 本・`.background`・2 秒のデバウンス、
  同じ拡張子が一度も成功せず 3 回失敗したらそのセッションでは飛ばす(**永続化しない** ―― 拡張を入れたら次回から出る)。
  ネットワークボリュームと dataless(iCloud 未ダウンロード)は対象外。

### 6.3 キャッシュ

鍵は **`<volumeUUID>-<inode>-<mtime>-<size>`**(inode だけだと外部で差し替えたファイルに古い絵が出続け、
inode 再利用で無関係な絵が出る ―― qooLibrary はこれで QLCodec-mkv の誤った絵が残った)。
場所は Caches(作り直せる)、上限は環境設定(既定 200MB。`ThumbnailDiskCache` と同じ扱いでリソースモニタに出す)。
メモリは `PagePixelCache` と同型の LRU。同時生成 4(表示が背景より優先)。**画面外のセルは `LazyCellImageBudget` で手放す**(既存)。

---

## 7. ブラウザ UI(段階3・4)

### 7.1 SwiftUI で組む(qooLibrary と同じ結論)。使い回すもの

| 部位 | 実装 | qooViewer にある部品 |
|---|---|---|
| ツリー(左) | `List(selection:)` + `Section` × 3 + `DisclosureGroup` の再帰 View。`.tag` は **`DisclosureGroup` 自身**に付ける(label に付けると最初の ↓ で先頭へ飛んだきり動かない ―― qooLibrary 実測)。たたんだら子を忘れる | `SidePanelLibraryTreeSection`(平らにした配列 + `LazyVStack`。階層が可変なのでこちらは再帰で) |
| 一覧(リスト) | `Table` + `TableColumnCustomization`(列幅のドラッグ変更) | 一覧ウインドウ 6 つと同じ形(`list-window-shared-shape`)。名前列は残り幅へ伸ばす(`onGeometryChange` で実測) |
| 一覧(アイコン) | `LazyVGrid` + 固定幅の列 + ピンチ | `WelcomeGridColumns` / `welcomeGridPinch` / **`MarqueeSelection`**(帯で選ぶ。qooLibrary には無い) / `LazyCellImageBudget` / `SelectionCheckmarkBadge` |
| 操作列 | 左・中央・右の割り付け | `WelcomePaneHeaderLayout` / `WelcomeSearchField` / `SidePanelNavButton` / `SidePanelSortMenu` の形 |
| パスバー | `NSPathControl`(`.standard`、`NSViewRepresentable`)。**`url` は設定せず `NSPathControlItem` を自分で組み立てる**(`url` を設定するとメインスレッドで各成分の `realpath`・アイコン取得が同期に走り、遅い共有で固まる ―― §12)。クリックで移動、項目へのドロップは移動/コピー | 新規 |
| 右クリック | `Table` は `.contextMenu(forSelectionType:)`(右クリックした行が選択外ならその 1 行だけ・枠線は標準)、グリッドはセルごとの `.contextMenu` | `CollectionDetailView.contextTargets`(Finder と同じ規則が既にある) |
| インラインリネーム | `TextField` + フィールドエディタで拡張子を除いて選択(`NSApp.keyWindow?.firstResponder as? NSText`、1 サイクル後) | `SelectAllTextField` / `FocusReleasingField` |
| キーボード | ↑↓←→ は `Table`/`List` 任せ、未選択時の先頭/末尾だけ足す。グリッドは自前(列数はレイアウトと同じ式)。type-select 1 秒 | `ListKeyboardNavigation` 相当を `Models/` に純粋関数で置いてテスト |
| 戻る/進む | `FileBrowserState` の 2 本のスタック。**戻り先が直前のフォルダの親なら、そのフォルダをハイライト**(`goUp` と同じ) | `SidePanelBrowserState` と同じ |

**ドラッグ&ドロップの API 版差(§11 Q3)**: SwiftUI の `List`/`Table` で**複数選択をまとめて掴めない**既知バグ
(FB10128110)があり、macOS 26 の `draggable(containerItemID:)` + `dragContainer` + `dragContainerSelection` で解決する
(qooLibrary はこれを使っている)。qooViewer の deployment target は macOS 15。選択肢は
(a) 26 では新 API、15 では 1 件ずつ(`.onDrag`)に落とす、(b) 一覧を `NSTableView`/`NSCollectionView`(`NSViewRepresentable`)で組む、
(c) target を 26 に上げる。

### 7.2 クリックの意味(Finder と揃える)

- 単発クリック = 選択(`.simultaneousGesture(TapGesture(count:1))` で即時。`onTapGesture` の 1 と 2 を並べると単発が
  ダブルクリック間隔だけ遅れる ―― qooLibrary 実測)。⌘ でトグル、⇧ で範囲。
- **選択済みの 1 件をもう一度クリック → 400ms 後にインラインリネーム**(その間にダブルクリックが来たら取りやめ)。
- ダブルクリック / Return = フォルダなら移動(画像フォルダでも)、本・画像なら qooViewer で開く、それ以外は `NSWorkspace.open`。
- 右クリック = 選択に含まれていればその全部、外ならその 1 件だけ(選択は変えない)。複数選択中は 1 件用の項目を淡色に。

### 7.3 一覧の読み込み

- `FileIO` の上で `enumerator(at:includingPropertiesForKeys:options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles])`
  (APFS/SMB で最速級 ―― §12。先読みしたキー**だけ**を後で読む。
  先読みしていないキーを読むと項目ごとの往復になる ―― qooLibrary 実測)。全ファイルを出す(サイドパネルと違う)。
  **サブフォルダの中は見ない**(三角も件数も出さない。TCC と往復の両方の理由)。
- 世代番号で古い結果を捨てる(速く移ると前のフォルダの中身が新しいフォルダに出うる)。適用時に消えた項目を選択から外す。
- 表示中フォルダの変更追従: `FolderChangeWatcher`(FSEvents。既存)で「何か変わった」だけ受けて読み直す。
  ネットワークでは飛ばないので、アクティブ化でも読み直す。自分の操作の結果は読み直しで反映(自己変更の識別は要らない ―― 読み直すだけ)。
- 種類(`localizedTypeDescription`)は拡張子単位のキャッシュ(既存の `typeDescription(for:isDirectory:cache:)`)。
- アイコンは `NSWorkspace.icon(forFile:)`。**到達できない共有上のパスでは 30 秒ブロックして「返る」**(qooLibrary 実測)ので、
  ローカルは同期・リモート(`MountTable.isRemote`)だけ非同期。

### 7.4 環境設定「ファイルブラウザ」(新しい `SettingsPane.fileBrowser`。「本」グループの前、「外観」の次)

| 行 | 種類 | 既定 |
|---|---|---|
| 起動時に表示するフォルダ | ホーム / よく使う項目(ポップアップ。未登録なら選べない) / 最後に表示したフォルダ(無ければホーム) | ホーム |
| フォルダを上に表示 | トグル | ON |
| 外からドロップしたとき | ビューアで開く / コピー・移動(Finder と同じ: 同一ボリュームは移動、別は コピー、⌥ で反転) | ビューアで開く |
| 「ここに圧縮」の拡張子 | zip / cbz | zip |
| 動画のサムネイルを作る | トグル(OFF なら QuickLook を呼ばない) | ON |
| サムネイルのキャッシュの上限 | スライダー + 使用量 + 削除 | 200MB |

---

## 8. 一括リネーム(Finder の模倣。段階5)

Finder 本体(macOS 26.6.2)の `BulkRenameWindow.nib` と `ja.lproj/BulkRenameWindow.strings` から確認できたこと:

- 部品: `NSPopUpButton` × 3(方式・名前のフォーマット・場所)、`NSTextField`(検索文字列/置換文字列/このテキスト/カスタムフォーマット/開始番号)、
  `NSNumberFormatter`、例の行、`NSBox`、ボタン 2 つ。
- 日本語の文言: 「Finder項目の名称変更:」「検索文字列:」「置換文字列:」「このテキスト」「名前の前/名前の後」「名前のフォーマット:」
  「名前とインデックス」「名前とカウンタ」「名前と日付」「カスタムフォーマット:」「開始番号:」「例: ^0」「名称変更」「キャンセル」。
  英語は `Base.lproj` の nib 内("Name and Index" / "Name and Counter" / "Name and Date" / "Custom Format:" / "Start numbers at:" /
  "before name" / "after name" / "Example: ^0" / "Rename")。方式のポップアップ(「テキストを置き換える/テキストを追加/フォーマット」)は
  nib ではなくコードから入るらしく、文言テーブルからは**見つけられなかった**(実機の Finder で確認する)。
- 方式のポップアップは Apple のマニュアルの表記で「テキストを置き換える / テキストを追加 / フォーマット」(英: Replace Text / Add Text / Format)。
  カスタムフォーマットの既定値は `File `(末尾に空白。日本語は `ファイル `)。
- 動作(Web と Finder の defaults から): **インデックス** = 1, 2, 3…、**カウンタ** = 5 桁ゼロ埋め(`00001`。桁数は選べない)、
  **日付** = リネームした時点の現在日時(ファイルの日付ではない。書式はロケール依存 ―― 実機で確認)、「テキストを追加」は空白を入れない、
  「フォーマット」と「追加」は拡張子を保ち、「置換」は拡張子を含む名前全体が対象(`.jpeg`→`.jpg` もできる)、全体が 1 回の ⌘Z で戻る。
  Finder は設定を `com.apple.finder` の `BulkRename*` キーに保存する(前回の方式・文字列・開始番号を次回も出す)→ こちらも `qooViewer.fileBrowser.bulkRename.*` に保存。

**qooViewer 側の実装**: モデルは純粋関数(`Models/BulkRename.swift`。既存の `BulkBookmarkRenaming` と同じ置き方)で
衝突検出(新名どうし・既存項目・`FileNameValidation`。大小文字を畳む)と 2 パス判定(新名が別の項目の旧名とぶつかる)、
実行は `BulkRenameCommand`(2 パスは `<UUID>.qooViewer-rename-tmp` へ逃がす。第 1・第 2 パスどちらの失敗でも戻す)。
**連番は表示順**(選択は `Set` なので並べ直す ―― qooLibrary が実機で踏んだ)。
シートは **AppKit(`NSPanel` + Auto Layout)** で組む(§11 Q7)。SwiftUI の `Form` では Finder と同じ寸法・間隔を出せない。

---

## 9. カット/コピー/ペースト・ドラッグ&ドロップ

- ⌘C: `NSPasteboard.general.writeObjects(urls as [NSURL])`。⌘X: 同じ書き込み + アプリ内の `cutPaths`(`standardizedFileURL.path` の集合。
  読み戻した URL は末尾スラッシュ等で `==` が外れる ―― qooLibrary 実測)。⌘V: ペーストボードの URL 集合が `cutPaths` と一致すれば移動、
  違えばコピー。⌥⌘V「ここに項目を移動」。カット済みは淡色で描く(qooLibrary には無いが Finder にはある)。
- Finder からのペースト(sandbox 下でペーストボードの URL に触れるか)は Web 調査の結果を待つ(§12)。
- アプリ内 D&D: 同一ボリュームは移動、別ボリューム(Finder からを含む)はコピー、⌥ で反転。修飾キーは**ドロップの瞬間**に `NSEvent.modifierFlags` で読む
  (判定を非同期にすると離されている)。同一ボリューム判定は `volumeUUIDString` を直接見ない(SMB では nil で「別ボリューム」になり移動がコピーに化けた)。
  コピーと移動が混在する 1 ジェスチャは 1 つの Undo 単位。
- アプリ外へ: 実 URL を `Transferable` でそのまま(`NSFilePromiseProvider` は使わない)。パッケージにはドロップさせない。
- スプリングローデッドフォルダ(ドラッグ静止で開く)は**最初は入れない**(qooLibrary も未実装)。

---

## 10. 段階(実装の順序と見積り)

| 段階 | 内容 | 見積り |
|---|---|---|
| 0 | 流出対策(**済**)。CLAUDE.md / docs/02 に運用を書く | ― |
| 1 | 環境設定の整理 2 件 + 「最近開いた本を表示」の行 + ボタン 2 つの撤去。テスト修正 | 300 行 |
| 2 | `FileIO` / `MountTable` / `FileOperationService` / `FileCopyEngine` / 衝突 / ゴミ箱 / コマンドとスタック。**使い捨てボリューム上のテスト**(APFS・exFAT のイメージ、`hdiutil`) | 2,500 行 + テスト 1,500 |
| 3 | 画面(読むだけ): モード切替・ツリー・リスト・アイコン・操作列・パスバー・検索(現フォルダの絞り込み)・戻る/進む/上・開く・新規タブ/ウインドウ・環境設定「ファイルブラウザ」・起動時フォルダ・よく使う項目 | 2,500 行 |
| 4 | 書く操作の UI: 右クリック 3 種・キー・カット/コピー/ペースト・D&D・インラインリネーム・新規フォルダ・ゴミ箱・Undo/Redo メニュー・進捗の帯 | 1,500 行 |
| 5 | 一括リネーム(モデル + `NSPanel`) | 900 行 + テスト 400 |
| 6 | 圧縮・展開(+ 安全策のテスト: Zip Slip・飽和加算・ディスクフル) | 1,000 行 + テスト 600 |
| 7 | サムネイル(本・動画・キャッシュ・背景生成) | 1,200 行 + テスト 300 |
| 8 | コレクション/メタデータ/書き出し/このアプリケーションで開く/Finder で表示/**ファイルブラウザで開く** 11 箇所 | 700 行 |
| 9 | 実機検証(使い捨てボリューム・合成名。TCC の 1 回だけの確認・すりガラス 2 条件・リーク測定)、docs/CHANGELOG/MANUAL | ― |

段階 2 までは UI 無しでテストが書ける。段階 3 以降は各段階の終わりに実機で確認する。

---

## 11. 決めてほしいこと → 決定(2026-09-13)

決定の一覧は [file-browser-plan.md](file-browser-plan.md) 冒頭の表。Q2〜Q5・Q7〜Q10 は推奨どおり、Q6 は「環境設定で
新規タブ / 新規ノーマルウインドウ / 新規シークレットウインドウを選ぶ」、Q11 は QLMedia(導入済み)。

- **Q1. 履歴に残った蔵書フォルダ名(§1.4)**: A. そのまま / B. 履歴書き換え + force push + GitHub サポートへ依頼 / C. リポジトリの作り直し。
  → **決定: A**(2026-09-13。ルートの名前 1 語だけで妥協できる、というユーザーの判断)。
- **Q2. 「最近開いた本を表示する」の行(§2.3)**: 消してよいか(キーは残す)。
- **Q3. 一覧の実装(§7.1・§12.1)**: (a) SwiftUI `Table` + `List`(qooLibrary の道。macOS 26 の新 API で複数ドラッグ、15 では 1 件ずつ) /
  (b) **リストとツリーは AppKit(`NSTableView` / `NSOutlineView`)、グリッドは SwiftUI** / (c) deployment target を 26 に上げて (a)。
  **推奨は (b)**(§12.1 の理由。Finder と同じ挙動を標準で得られ、`Table` の退行を避けられる)。
- **Q4. ゴミ箱の無いボリューム(SMB 等)での「ゴミ箱に入れる」**: Finder と同じく「すぐに削除されます」と確認して完全削除(Undo 不可)か、断るか。**推奨は確認して削除**。
- **Q5. 本のサムネイル(§6.1)**: 2 段構え(コレクション表紙があればそれ、無ければ安い先頭画像)でよいか。棚と絵が違いうるのは「表紙を指定した本」だけ。
- **Q6. 「ファイルブラウザで開く」を本を開いている間に選んだとき**: (a) 本を閉じてこのウインドウで開く / (b) 新規タブで開く。**推奨は (b)**(「Finder で表示」も今の画面を壊さない)。
- **Q7. 一括リネームのシート**: AppKit(`NSPanel`)で Finder と同じ寸法まで合わせる。ビットパーフェクトの基準は**この機の macOS 26.6 の Finder**でよいか(OS の版で変わりうる)。
- **Q8. シークレットウインドウでのファイルブラウザ**: 閲覧と本を開くことはできる。ファイル操作(書き込み)は**許す**が、よく使う項目の登録・最後のフォルダの記憶・Undo の履歴(メモリ上)以外の保存は**しない**、でよいか。
- **Q9. 検索欄の意味**: 現フォルダの絞り込み(即時)だけにする(再帰検索は後回し)でよいか。
- **Q10. 進捗の出し方**: 右ペイン下(パスバーの上)の帯に「N 件中 M 件 — 1.2GB / 4.3GB — 残り約 2 分」と中止ボタン。Finder のような別ウインドウにはしない、でよいか。
- **Q11. mkv の拡張**: 実機検証のためにどちらかを入れてよいか ―― QLMedia(App Store、qooLibrary で実測済み)/ QLVideo 3.x(無料、Media Extensions 方式、
  3.10+ は macOS 26 要。`QLThumbnailGenerator` から出るかは未実測)。入れなければ mkv は既定のアイコンになる。

---

## 12. Web 調査の結果(一次資料で確かめたもの。設計へ反映済み)

出典の等級: [Apple] = developer.apple.com のドキュメント/DTS の回答、[OS] = この Mac(26.6.2)から直接読んだもの、
[実測] = qooLibrary、[推定] = 一次資料に無い私の結論(実装前に 1 回測る)。

| 項目 | 分かったこと |
|---|---|
| ゴミ箱の書き込み先 | `application.sb` に `~/.Trash` と `<volume>/.Trashes` への read/write が**無条件で許可**されている [OS]。要るのは元のファイル側の権限だけ(user-selected で足りる) |
| ゴミ箱の無いボリューム | `trashItem` は `NSFeatureUnsupportedError`(3328)を投げる。IINA はこれを見て「このボリュームにはゴミ箱がありません。完全に削除しますか」と尋ねる [Community]。`NSWorkspace.recycle` は OS の確認ダイアログを出す [実測] |
| Finder の「元に戻す」 | 複数件を続けて捨てると**先頭の 1 件しか「元に戻す」が出ない**(DTS: `.DS_Store` の競合、10 年以上前からの不具合 r.23153124。回避策なし)[Apple]。このアプリの Undo は自前の `TrashReceipt` で戻すので影響しないが、Finder 側の「元に戻す」は 1 件目しか効かないことを docs に書く |
| ゴミ箱からの Undo | 戻すには**元の親フォルダの権限**がその時点で要る [推定。Cog は親のブックマークを保存している]。このブラウザは許可済みフォルダの中しか見せないので通常は持っている |
| Undo のメニュー | 標準の「取り消す/やり直す」は**ウインドウの `UndoManager`(レスポンダチェーン)**でしか有効にならない [Apple forum]。自前のスタックを使うなら、メニュー項目も自前(§4.4 の形)。テキスト欄のときは標準へ流す |
| Finder へのドラッグ(URL) | ペーストボードへ `public.file-url` を書く時点で**プロセスがサンドボックス拡張を添える**(触れない URL では `CreateSandboxExtensionData failed` が出る)[Apple forum ×3]。user-selected のファイルなら Finder へ渡せる。SwiftUI の `FileRepresentation` だけでは Finder が受け取らず、`ProxyRepresentation { $0.url }` が要る [Community]。Finder が「移動」してくれるかは未文書 → `.outsideApplication` は `.copy` にし、移動はアプリ内だけ |
| Finder からのドロップ | `onDrop` は「クロージャを抜ける前にしか中身に触れない」[Apple]。`draggingEntered` で URL を読むと落とせなくなることがある(UTI だけ見る)[Community]。SwiftUI の `DropInfo` に修飾キーは無い(DTS: 未対応)→ ドロップの瞬間に `NSEvent.modifierFlags` |
| Finder が ⌘C したファイルのペースト | ペーストボードの `public.file-url` にも書き手の拡張が付く**はず** [推定、同じ仕組み]。**Debug ビルドで 1 回測る**(`readObjects` → `attributesOfItem`)。Finder 自身にファイルの「カット」は無く(⌥⌘V「ここに項目を移動」)、アプリ内の「次のペーストは移動」で表す |
| このアプリケーションで開く | `urlsForApplications(toOpen: URL)`(macOS 12+、適合順)。サンドボックスからは**型を宣言していないアプリでは `kLSAppDoesNotClaimTypeErr`** になる(FB9878055)→ 候補は LaunchServices が返したものに限る。同じアプリの複製は bundle id で畳む |
| `NSPathControl` | `url` を設定すると**メインスレッドで**各成分の `realpath`・リソース値・アイコン取得が同期に走り、遅い共有で固まる(FB22294400)[Apple forum]。→ `NSPathControlItem` を自分で組み立て、名前は `lastPathComponent`、アイコンは種類ごとのキャッシュ |
| 一覧の読み込み | `enumerator(at:includingPropertiesForKeys:options: [.skipsSubdirectoryDescendants])` が APFS でも SMB でも最速級(Tempelmann の計測)。`contentsOfDirectory` は APFS で 3 倍遅い |
| 並べ替え | `localizedStandardCompare` = Finder。「フォルダを上に」は Finder では**名前順のときだけ**効く(`_FXSortFoldersFirst`)。このアプリは既存の `FolderBrowserSort` どおり全基準で上にする(サイドパネルと揃える) |
| 新規フォルダの名前 | 英語 `untitled folder`、日本語 `名称未設定フォルダ`。2 つ目以降の番号の付き方は資料が割れる(`1` 始まりの古い記述と `2` 始まり)→ **実機の Finder で確認**してから固定 |
| 「両方残す」/複製の名前 | コピー先の衝突は `name 2.ext`、`name 3.ext`。⌘D は `name copy.ext` / `name のコピー.ext`(空白の有無は要確認)。**Finder は元の名前の末尾の数字を解釈しない**(`Revision 2` → `Revision 2 2`)ので、こちらもそれに倣う(qooLibrary の「既存の連番を剥がす」より単純で Finder どおり) |
| ZIPFoundation 0.9.20 | `Archive(url:accessMode:.create)` は**既存ファイルがあると投げる**(一時名へ書く)。bit 11 は常に立て、`0x7075` は書かない。NFC 正規化は**しない**(こちらで `precomposedStringWithCanonicalMapping`)。`Progress` はチャンクごとに進み、`isCancelled` で `cancelledOperation` を投げて `rollback`(書庫は壊れないがファイルは残る → 自分で消す)。`Archive` は `Sendable` ではない(detached task の中で作って外へ出さない)。既定チャンク 16KiB は小さい(`bufferSize` 1〜4MiB)。`.none`/`.deflate` の 2 方式のみ、レベル指定なし。ZIP64 は自動 |
| `ditto` の NFC | 2026-09-03 の実測「ditto は NFC へ正規化する」を裏付ける資料は無く、HFS+ 時代の資料は NFD と言う(APFS では書いたままのバイトが返るだけ、という説明が整合する)。**どちらにせよ自分で NFC にする**方針は変わらない |
| Windows 側の読み方 | 7-Zip 21.06+ はホスト OS が Unix なら UTF-8、そうでなければ OEM コードページ(日本語 Windows は CP932)。Bandizip は統計的推定で短い名前は外す。→ NFC + bit 11 でよい |
| 文字コード検出 | The Unarchiver は**書庫全体で 1 つ**の検出器(qooViewer の `EntryNameDecoder` と同じ設計)。CP932 の 2 バイト目は ASCII 域を含む、半角カナは 1 バイト、UTF-8 の 3 バイトは CP932 の 2 文字に見える(「縺ゅ＞」)→ 「全部 strict UTF-8 で読めるなら UTF-8、でなければ検出」の順は正しい |
| 展開の安全策 | libarchive の `SECURE_NODOTDOT` / `NOABSOLUTEPATHS` / `SYMLINKS` は**ライブラリの既定では全部 OFF**(bsdtar が明示的に付けている)。7-Zip も 2025 年に記号リンクの脱出を 2 件直した(CVE-2025-11001/11002/55188)。`NAME_MAX` 255 バイト・`PATH_MAX` 1024 バイト [OS SDK]。APFS は既定で大小文字を区別せず正規化非依存 → 衝突は `precomposed + lowercased` の集合で見る |
| 進捗の UI | `ProgressView(_ progress: Progress)`(macOS 11+)は `localizedDescription` を出す。HIG: 確定的にできるならする、90%→5 分は欺瞞的、中止できるようにする。KVO は作業スレッドで秒間数千回来るので**こちらで 1/30 秒に間引いて MainActor へ**。`withTaskCancellationHandler` の `onCancel` で `progress.cancel()` |
| `QLThumbnailGenerator` | Sequoia で `.qlgenerator` は**完全に廃止**、appex(Thumbnail Extension)だけ。新しい拡張は再起動しないと効かないことがある。**QLVideo 3.x は QuickLook 拡張ではなく Media Extensions(macOS 15/26)で AVFoundation 側に mkv を足す**方式へ移った(3.10+ は 26 が要る)→ これでも `QLThumbnailGenerator` から mkv が出る(要実測)。qooLibrary が実測した QLMedia(App Store)と、この QLVideo 3.x が候補 |
| TCC | Tahoe の保護対象: デスクトップ・書類・ダウンロード・iCloud Drive・他社クラウド・**リムーバブル**・ネットワーク・Time Machine。ad-hoc 署名は DR が版に固定され再実行で再プロンプト(TN3127)。**`contentsOfDirectory(~)` 自体は保護対象ではない**(中へ触ると出る)。拒否は `NSFileReadNoPermissionError`(257)+ `EPERM`(空一覧ではなくエラー)。リセットは `tccutil reset All com.qooProject.qooViewer.debug` |
| ボリューム | `/Volumes` の一覧自体は sandbox で許可(`file-read* (literal "/Volumes")`)[OS]。`mountedVolumeURLs(includingResourceValuesForKeys:)` は**要求したキーによっては I/O でブロック**(Apple 明記)→ 既存の `getmntinfo(MNT_NOWAIT)` 経路(2026-09-13 の修正)を使う。着脱は `NSWorkspace.didMount/didUnmount/didRenameVolume` |
| SwiftUI `Table` | macOS 15.5 でスクロールが退行し 26 でも残る(「NSTableView を直接使え」)、1000 行で選択に 3.5 秒の事例、インラインリネームは「待ってから編集」が仕様、ドラッグ出しは 15.1 で壊れ後に修正、矩形選択は無い。公開されている Swift 製ファイルマネージャは CodeEdit / explorer が `NSOutlineView`/`NSTableView` を `NSViewRepresentable` で使う |

### 12.1 §7.1 の見直し ―― 一覧とツリーは AppKit、グリッドは SwiftUI(→ §11 Q3)

上の `Table` の事実から、**リスト表示は `NSTableView`、ツリーは `NSOutlineView`**(どちらも `NSViewRepresentable`)を推す。
得られるもの: インラインリネーム(フィールドエディタが標準)、type-select、スプリングローデッド(`NSSpringLoadingDestination`)、
ドラッグの修飾キー(`draggingSourceOperationMask`)、レスポンダチェーンの `copy:`/`cut:`/`paste:`/`delete:`/`selectAll:`
(**標準の編集メニューがそのまま効く**。§4.4 の Undo だけ自前)、1 万行でも安定。
失うもの: `Table` の `columnCustomization`(`NSTableView` は `autosaveName` で同じことができる)、SwiftUI の輪郭修飾子
(セルの `NSTextField` は `PanelContentShadow` と同じ影を `shadow` で描く)。**閉包は `dismantleNSView` で切る・
`NSTrackingArea(owner:)` は外す**(CLAUDE.md のリーク規則)。アイコン表示は `LazyVGrid` のまま
(`MarqueeSelection` / `WelcomeGridColumns` / ピンチ / `LazyCellImageBudget` をそのまま使える。ここは `Table` の退行と無関係)。
