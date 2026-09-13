# 改善要望7 実装計画 ―― ウェルカム画面のファイルブラウザモードと環境設定の整理(引き継ぎ資料)

立案日: 2026-09-13 / ブランチ: `feature/file-browser` / 検討メモ: [file-browser-study.md](file-browser-study.md)(決定事項は同 §11)

段階は §11 の決定を反映して 0 → 9 の順(Q12 の読み取り専用モードは段階 8.5)。段階 0・1・2・3 は済み(段階 3 の結果と引き継ぎは §3.8・§3.9)。段階 4 は 4a と 4b の D&D・アイコン表示の名前の変更と type-select・「置き換える」と退避の復旧記録・ロックされた項目の確認まで実装(§4 冒頭。**次の人への引き継ぎは §4.12**、その前のものは §4.11・§4.10・§4.9)。各段階は単独でビルド・テストが通り、
レビューできる大きさにする。段階 2 までは UI を持たない(テストで検証)。段階 3 で初めてウェルカム画面が変わる。
この計画に出てくる既存コードの行番号は立案時点(`ecda25f` + 段階 0)のもの。

**引き継ぐ人が最初に守ること**: [file-browser-study.md §1.3](file-browser-study.md) の運用の約束(蔵書の名前を
どこにも書かない・使い捨てボリュームで検証する)、`scripts/dev/install-git-hooks.sh` を一度実行して hook を有効にすること
(無いと `pre-commit` は動かず、リストが無いとコミットは**拒否される**設計 ―― `scripts/dev/build-private-terms.py` で
自分の蔵書から一覧を作る)。CLAUDE.md の「個人情報の流出防止」も参照。

---

## 決定事項(2026-09-13、ユーザー)

| # | 決定 |
|---|---|
| Q1 | 履歴に残ったルートフォルダ名 1 語は**そのまま**(作業ツリーだけ修正) |
| Q2 | 「最近開いた本を表示する」の設定行を**消す**(キーは残す) |
| Q3 | **リストとツリーは AppKit(`NSTableView` / `NSOutlineView`)、アイコン表示は SwiftUI(`LazyVGrid`)** |
| Q4 | ゴミ箱の無いボリュームでは「すぐに削除されます」と確認して完全削除(Undo 不可) |
| Q5 | 本のサムネイルは 2 段構え(コレクション表紙があればそれ、無ければ安い先頭画像) |
| Q6 | 本の表示中の「ファイルブラウザで開く」の行き先は**環境設定で選ぶ**: 新規タブ / 新規ノーマルウインドウ / 新規シークレットウインドウ |
| Q7 | 一括リネームのシートは AppKit(`NSPanel`)で組み、基準はこの機の macOS 26.6 の Finder |
| Q8 | シークレットウインドウでもファイル操作は許す。保存(よく使う項目・最後のフォルダ)だけしない |
| Q9 | 検索欄は現フォルダの絞り込みだけ(再帰検索は後回し) |
| Q10 | 進捗は右ペイン下(パスバーの上)の帯 + 中止ボタン |
| Q11 | mkv の検証用の QuickLook 拡張は QLMedia(**導入済み**) |
| Q12 | **読み取り専用モード**(2026-09-13 追加、ユーザー要望)。環境設定「ファイルブラウザ」に ON/OFF を置き、ノーマル/シークレット共通で効く。**既定は ON**。ON の間はファイルそのものを変える操作をできなくし、よく使う項目の登録・解除、閲覧・開く、コレクションの作成・登録などだけにする。利用者が明示的に OFF にしたときだけファイルマネージャーとして使える。**実装は最終段階**(§段階 9 の前に行う。下記) |

---

## 段階 0. 流出対策(済)

- `scripts/dev/build-private-terms.py`(一覧の生成。リポジトリの外へ)、`scripts/ci/check-private-terms.{sh,py}`(検査。`check-all.sh` に追加)、
  `scripts/git-hooks/{pre-commit,commit-msg,pre-push}` + `scripts/dev/install-git-hooks.sh`、`.gitignore`。
- 照合は「先頭 2 文字で引く索引 + 本文 1 パス」(語ごとに探す形は 2 万語で 2 分超 → 索引で 2 秒。実測)。
- 一覧の語は出力しない(`--reveal` のときだけ)。hook は一覧が無ければ拒否(fail-closed)。
- `ExportSharedViews.swift:209` の例示を `蔵書` に書き換えた。
- CLAUDE.md「個人情報の流出防止」、docs/02「CI」に運用を書いた。

---

## 段階 1. 環境設定の整理 + 帯のボタン 2 つの撤去

**実装済み・コミット済み(2026-09-13。全 986 テスト通過、実機検証済み)。計画から変えた点:**
- 「並び順を Finder に揃える」の表紙の作り直し(`handlePageOrderSettingChange`)は消さず、
  **OFF で使っていた人だけ起動時に一度**従来順 → 正準順の判定をする
  `CollectionCoverExtractor.refreshCoversForRetiredOrderSettingIfNeeded` に変えた(消すと、OFF だった人の
  表紙が従来順の先頭のまま残る)。`comparePageOrder` は `compareLegacyPageOrder` に、
  `usesFinderOrderOverride` は `usesLegacyOrder` に置き換え(古い番号を鍵へ直す経路が従来順を要るため)。
  `PageOrder.defaultsKey` は `retiredSettingKey` に改名して残した。
- `showRecentFilesOnWelcome` も**プロパティごと消した**(読む側が無くなるため。キーの値は残す。docs/06)。
- 帯の左端の「ファイルブラウザ」ボタンは**段階 3 へ回した**(`WelcomeMode` が無い段階で押しても何も起きないため)。

### 1.1 「並び順を Finder に揃える」

| ファイル | 変更 |
|---|---|
| `Services/PageOrder.swift` | `comparePageOrder(_:_:usesFinderOrder:)` を削除し、呼び出しは `compareCanonicalPageOrder` へ。`PageOrder.usesFinderOrder` と `defaultsKey` を削除。`differsByOrderSetting(keys:)` は**残す**(`LayoutStore.pinPageOrderIfNeeded` が「設定で並びが変わりうる本」の判定に使う ―― 過去に OFF で作ったレイアウトを守るため)。`pageOrderSettingDidChange` 通知を削除。冒頭の「並び順の全体設計」を「表示順の切替は無くなった(2026-09-13)。従来順(`.numeric`)は `pinPageOrderIfNeeded` の判定にだけ残る」に書き換える |
| `Services/EffectivePageOrder.swift` | `usesFinderOrder` の分岐を外す(常に正準順) |
| `ViewModels/AppPreferences.swift` | `usesFinderSortOrder` と `Keys.usesFinderSortOrder`、`keys(for: .general)` の行、`resetToDefaults` の行を削除。**UserDefaults のキーは消さない**(古い版を起動した人の設定を壊さない) |
| `ViewModels/ViewerViewModel.swift` / `BookLayoutEditorViewModel.swift` / `BookExportViewModel.swift` | `pageOrderSettingDidChange` の購読と並べ直しを削除 |
| `Services/CollectionCoverExtractor.swift` | `handlePageOrderSettingChange` とその購読を削除(docs/14「並び順の設定」の段落も) |
| `Services/CoverImageResolver.swift` | `usesFinderOrder` 引数を外す |
| `ViewModels/LayoutStore.swift` | `pinPageOrderIfNeeded` はそのまま(旧設定 OFF で焼いた `pageOrderOverride` がある本は今後も固定される) |
| `Views/GeneralSettingsView.swift` | 「ページ順」セクションを削除 |
| テスト | `PageOrderTests` / `EffectivePageOrderTests` / `CollectionCoverExtractorTests` / `AppPreferencesTests` / `AppPreferencesProbe` の該当ケースを削除・書き換え |
| docs | docs/07(並び順の 2 層)、docs/13(経緯の表に「表示順の切替を撤去」の行)、MANUAL の該当節、CHANGELOG `[Unreleased]` |

### 1.2 「ウェルカム画面でも表示する」

| ファイル | 変更 |
|---|---|
| `Views/ContentView.swift` | `isSidePanelSuppressedForWelcome` を `appState.currentBook == nil` に。`onChange(of: preferences.showSidePanelOnWelcome)` を削除。コメントを「本を開いていない間はサイドパネルを出さない(改善要望7: ファイルブラウザとフォルダブラウザを同時に見せない)」に |
| `App/QooViewerApp.swift:838` | 「サイドパネルを隠す」の無効化条件から `preferences.showSidePanelOnWelcome` を外す(`!hasBook` だけ) |
| `ViewModels/AppPreferences.swift` | `showSidePanelOnWelcome` とキーの参照を削除(キーは残す) |
| `Views/GeneralSettingsView.swift` | 行を削除 |
| テスト | `AppPreferencesTests:236` / `AppPreferencesProbe:69` |

### 1.3 帯の 2 つのボタンと「最近開いた本を表示する」

- `Views/Welcome/WelcomeTopBar.swift`: 「本を開く…」「履歴から開く」と `labelWidth` の実測、`isShowingRecentBooks`、`RecentBooksPopover` の呼び出しを削除。
  **`chipLabelWidth` は今の見積り(2 つの文字列)をそのまま残す**(チップの幅を変えないため。文字列は String Catalog に残す)。
  代わりに左端へ「ファイルブラウザ」ボタン(`SidePanelNavButton` の形、`systemImage: "folder"`。`.panelIconButtonLabel()` が輪郭を持つ)。
  押されている状態(`.browser`)はアクセント地 + `.panelOutlinedAccent(in:)`(`WelcomeEditToggle` と同じ描き方)。⌘O は File メニューに残る。
- `Views/Welcome/RecentBooksPopover.swift`: 削除(履歴はファイルメニューとサイドパネルに残る)。
- `AppPreferences.showRecentFilesOnWelcome`: 行(`GeneralSettingsView:99`)を削除、プロパティとキーは残す(docs/06 の一覧に「読まれていない」と書く)。
- docs/14「ウェルカム画面の構成」の帯の説明を更新。

### 1.4 テスト・確認

- 既存テスト全通過。`WelcomeLibraryStateTests` に影響なし。
- 実機: 設定を OFF にしていた Debug コンテナで起動しても落ちないこと。ウェルカム画面でサイドパネルが出ないこと。

**結果(2026-09-13、Debug ビルド、空の本棚 + 使い捨てボリュームの合成名の本。手順は docs/12「実物のアプリを外から操作する」)**
- 撤去した 3 つのキーを残したまま(`usesFinderSortOrder = NO`・`showSidePanelOnWelcome = YES`・
  `showRecentFilesOnWelcome = YES`)起動 → 落ちない。
- 帯はライブラリのチップと「＋」だけ。常時表示(`hideSidePanel = NO`)でもウェルカム画面にパネルは出ない。
  「表示」→「サイドパネルを隠す」はグレーアウト。
- 環境設定「一般」に「ページ順」セクション・「最近開いた本を表示する」・「ウェルカム画面でも表示する」が無い。
- `a.png` / `B.png` / `c.png` の本を開く → a → B → c(正準順。従来順なら B が先)。パネルが戻る。
  本を閉じるとパネルが消える。
- `hideSidePanel = YES` で左端にカーソルを置く → ウェルカム画面では出ない。本を開いた状態では同じ操作で出る(対照)。
- 後始末: ストア・表紙の保管庫・UserDefaults を控えから戻して一致を確認、ボリュームを外し、残ったページ一覧
  キャッシュ 1 件を削除。

---

## 段階 2. 操作エンジン(UI なし)

**実装済み・コミット済み(2026-09-13。全 1049 テスト・105 suite 通過。画面が無いので実機検証は無し)。** 実装は qooLibrary の同名の型を写し、
下の計画に合わせて変えた。計画から変えた点・実測で分かった点:

- **テストホストからは hdiutil を起動できない**(サンドボックス。`hdiutil create` が「装置が構成されていません」、
  カーネルのログに `deny(1) mach-lookup com.apple.system.hdiejectd.xpc`)。一方、**外で付けたボリュームへは
  テストから読み書きできる**(実測)。そこで `DisposableVolume` は自分でイメージを作らず、**スキームの Test の
  Pre-action / Post-action が `scripts/test/test-volumes.sh attach|detach` で 4 本付け外し**
  (`/Volumes/qooViewerTest-{apfs,exfat,fat32,tiny}`、`-nobrowse`)、テストはその上に UUID 付きの作業フォルダを作る。
  ボリュームが無ければ**テストを失敗させる**(飛ばさない)。CI の Debug ジョブは `test-without-building` の前後でも
  同じスクリプトを呼ぶ(`build.yml`)。
- **`TrashAvailability` は `url(for: .trashDirectory, create: false)` だけで決めない。** 作ったばかりのローカルの
  ボリューム(APFS / exFAT / FAT32)ではこの問い合わせが 3328 で失敗するが、`NSWorkspace.recycle` は `.Trashes` を
  作って普通にゴミ箱へ入れる(実測。`create: true` も exFAT/FAT32 では ENOTDIR で失敗)。問い合わせだけで決めると、
  買ったばかりの USB メモリで「すぐに削除されます」が出る。→ 問い合わせが通る **か、マウント表でローカル**ならある。
- **exFAT(fskit)でも `renamex_np(RENAME_EXCL)` が ENOTSUP を返す**(宛先なし。macOS 26.6 実測)。qooLibrary が
  SMB で見つけた縮退経路(lstat + rename)は、手元の USB メモリでも通る経路だった。テストで前提ごと固定した。
- 「置き換える」の退避は `.qooViewer-replace-<UUID>/<元の名前>`(隠しフォルダの中に元の名前のまま)。フォルダごと
  改名して退避すると、ゴミ箱に `.qooViewer-replace-…` の名前で入り何を置き換えたのか分からないため。
  **落ちたときに退避を戻す記録(qooLibrary の `ReplaceBackupJournal`)は段階 4 へ**(UI から `.replace` に届くのが段階 4)。
- 完全削除はロックされた項目のロックを外さず、失敗として返す(確認の UI が無いので消さない側)。段階 4 で確認を付けるなら足す。
- `FileNameValidation` の UTF-8 255 バイトの規則は**入口では見ない**(APFS では日本語 86 文字以上の名前も作れるため)。
  宛先が `smbfs` のときだけ事前検査で見る(`FileOperationPreflight.nameByteLimit`)。
- `untitledFolderName` の 2 つ目以降(`名称未設定フォルダ 2`)は**まだ実機の Finder と突き合わせていない**(段階 4 で新規フォルダの
  ボタンを置くときに確かめる)。
- 一括の移動・コピーは**最初の失敗で止まり**、`TransferOutcome` に動いた分の受領書・止まった項目・手つかずの項目を入れて返す
  (1 件も動かなければ投げる)。「以降すべてに適用」は 1 回の操作の中でエンジンが覚える(`ConflictDecision.applyToRemaining`)。
- **自分のフォルダへの移動は方針によらず何もしない**(「両方残す」で `name 2` に改名しない)。同じフォルダへのコピーは
  「両方残す」なら複製、それ以外は何もしない(「置き換える」で自分自身を退避すると運ぶ元ごと消える)。
- ゴミ箱に触る口は `FileOperationEnvironment`(`live` / テスト用の `pseudoTrash(at:)`)。テストは実ゴミ箱に触れない。
- コマンドの名前: `MoveFilesCommand` / `CopyFilesCommand` / `RenameFileCommand` / `TrashFilesCommand` /
  `DeleteFilesImmediatelyCommand`(積まない)/ `CreateFolderCommand` / `CompositeFileCommand`。移動・コピーの取り消しは、
  「置き換える」でゴミ箱へ送った元の項目も空いた場所へ戻す。
- `FileIO` の枯渇テストは**測定をすべてプールの外(Thread と semaphore)で行う**。async で書くと、塞いだ瞬間にテスト自身の
  継続も `.timeLimit` の見張りも動けず、テストホストごと止まった(最初の形)。期限のテストも「200ms で戻る」ではなく
  「本体より先に戻る」を見る(テスト全体を並行に走らせると、戻った継続が走り出すまで 9 秒待たされた)。
- `MountTable` に `areOnSameVolume` / `isOnAnUnmountedVolume` / `volumeIdentifier`。`BookLocationResolver` のマウント一覧の
  読み取りをここへ寄せた(`getmntinfo` → `getmntinfo_r_np`)。

### 2.7 引き継ぎ(段階 2 → 段階 3、2026-09-13)

**次に着手するのは段階 3(読むだけの画面)。** 段階 2 の変更で段階 3 の計画の前提が変わった点は無い。
始める前に知っておくこと:

- **置き場所**: エンジンは `Services/FileOperations/`(`FileIO` / `MountTable` / `FileCopyEngine` / `TrashAvailability` /
  `FileOperationPreflight` / `FileOperationTypes` / `FileOperationService`)、名前の規則は `Models/FileNameValidation.swift`、
  コマンドは `ViewModels/FileCommands/`(`FileCommand` / `FileCommandStack` / `FileCommands`)。どれもまだ画面から呼ばれていない。
- **一覧の読み込み(§3.1)は `FileIO.perform` の上で**。`DirectoryBrowser.listingAsync` は `Task.detached` なので流用しない
  (応答しない共有でプールごと止まる)。取り消しは `Cancellation.isRequestedInCurrentScope`、世代番号で古い結果を捨てるのは従来どおり。
- **`FileCommandStack` は `FileBrowserState` が 1 つ持つ**(ウインドウごと)。`run` は投げたら積まない・何も起きなければ積まない。
  `undo`/`redo` は `FileUndoOutcome` を返すだけで、見せるのは呼び出し側(段階 4 の帯とアラート)。`needsAttention` が true なら必ず見せる。
- **ゴミ箱の判定**は `TrashAvailability.hasTrash(forAll:)` を `FileIO` の上で。ローカルは「ある」、ネットワーク越しで `.Trashes` が
  無ければ「無い」(→ 確認のうえ `DeleteFilesImmediatelyCommand`)。
- **段階 4 へ持ち越したもの**: 「置き換える」の途中で落ちたときの退避の復旧記録(qooLibrary の `ReplaceBackupJournal`)、
  ロックされた項目の削除の確認、`untitledFolderName` の 2 つ目以降の番号を実機の Finder で確かめること、
  ゴミ箱の無い場所での「置き換える」(置き換えた元を完全削除するしかない)の確認。
- **テスト**: 使い捨てボリュームが要るテストは `DisposableVolume.make(.apfs / .exfat / .fat32 / .tiny, "label")`。スキームの Test から
  走らせれば自動で付く(外から走らせるなら `scripts/test/test-volumes.sh attach`)。ゴミ箱は `FileOperationEnvironment.pseudoTrash(at:)`。
  協調プールを塞ぐテストを書くときは、測定をプールの外(Thread と semaphore)で行う(async のまま塞ぐとテストホストごと止まる)。
  **テストを kill するときは Debug のテストホストだけを狙う**(docs/12「テスト用の使い捨てボリューム」)。
- **文言**: `xcodebuild` のビルドは `Localizable.xcstrings` へ新しい鍵を書き戻さない。段階 2 の 43 件は JSON へ手で足した
  (`json.dumps(indent=2, separators=(',', ' : '), ensure_ascii=False)` で Xcode の書式と一致する)。Xcode で開いてビルドすると
  並びが書き戻されることがあるが、その差分はそのままコミットしてよい。
- **CI**: `build.yml` / `check.yml` は main への push でしか自動では走らない(このブランチでは走らない)。`test-volumes.sh` を呼ぶ変更は
  **このブランチで手動実行(workflow_dispatch)して確認済み(2026-09-13)** ―― macos-26 のランナーでも 4 本のボリュームが付いて外れ、
  `FileOperationVolumeTests` の 7 件(exFAT の ENOTSUP・FAT32 の上限を含む)を含めて全テストが通った。Check(actionlint を含む)も成功。
  このブランチで CI に関わる変更をしたら、同じく `gh workflow run build.yml --ref feature/file-browser`(と `check.yml`)で確かめる。

### 2.1 `Services/FileOperations/FileIO.swift`(新規)

```swift
/// ブロッキングするファイル I/O を、協調スレッドプールとメインアクターの外で走らせる。
/// 投入ごとに新しい serial queue を作る(qooLibrary 実測: concurrent queue も global queue も
/// プール枯渇中は 0/4 しか始まらず、投入ごとの serial queue だけが 4/4 を 0ms で始めた。費用は 1 件約 1µs)。
nonisolated enum FileIO {
    static func perform<T: Sendable>(_ body: @Sendable () throws -> T) async throws -> T
    /// 期限付き。時間が来たら待つのをやめるだけで、I/O 自体は止まらない(macOS に中断できる I/O は無い)。
    /// タイマーは DispatchSource(Task.sleep も asyncAfter も枯渇中は発火しない ―― qooLibrary 実測)。
    static func withDeadline<T: Sendable>(_ limit: Duration, _ body: @Sendable () throws -> T) async throws -> T
}
/// 借りたスレッドの上では Task.isCancelled が常に false になるので、取り消しはこのフラグで伝える。
nonisolated final class Cancellation: Sendable { func request(); var isRequested: Bool }
```

`CollectionAutoFolderRow` の `FolderExistenceProbe` は**この段階では触らない**(動いているものを動かさない。後で寄せる)。

### 2.2 `Services/FileOperations/MountTable.swift`(新規)

`getmntinfo_r_np(MNT_NOWAIT)` の薄い包み。`entry(containing:)`(最長一致)、`isRemote(_:)`、`isLocal(_:)`、`volumeIdentifier(_:)`
(`volumeUUIDString` が nil の SMB では `f_mntfromname` のハッシュ)。既存の `BookLocationResolver` のマウント一覧の読み取り(2026-09-13 の修正)を
ここへ寄せる(同じ関数を 2 箇所に持たない)。

### 2.3 `Services/FileOperations/FileOperationService.swift`(新規、`actor`、状態を持たない)

```swift
actor FileOperationService {
    struct Options { var conflictPolicy: ConflictPolicy; var conflictResolver: (@MainActor (Conflict) async -> ConflictDecision)?;
                     var progress: ProgressSink?; var cancellation: Cancellation }
    func createDirectory(at url: URL) async throws -> URL                                  // 既存なら fileWriteFileExists
    func copy(_ items: [URL], to folder: URL, options: Options) async throws -> TransferOutcome
    func move(_ items: [URL], to folder: URL, options: Options) async throws -> TransferOutcome
    func rename(_ item: URL, to name: String) async throws -> RenameReceipt
    func trash(_ items: [URL], options: Options) async throws -> TrashOutcome              // NSWorkspace.recycle。120 秒の期限
    func deletePermanently(_ items: [URL], options: Options) async throws -> DeletionOutcome // ゴミ箱の無いボリューム用
    func restoreFromTrash(_ receipts: [TrashReceipt]) async throws -> RestoreOutcome
}
```

決めごと(検討メモ §4.2 の表がそのまま仕様):
- 移動: `renamex_np(RENAME_EXCL)` → `ENOTSUP` は `lstat` + `rename(2)` → `EXDEV` は `FileCopyEngine.copy` + 元削除(元が変わっていたら宛先を消して失敗。
  SMB の更新日時の揺れは中身 64KB × 3 点で判定)。
- コピー: `FileCopyEngine`(`copyfile(3)`、`COPYFILE_CLONE|ALL|EXCL|NOFOLLOW|RECURSIVE`、status callback で進捗と中止、エラー段階では `CONTINUE` を返さない)。
- 衝突: `ConflictPolicy { ask, replace, keepBoth, skip }`。`keepBoth` は `name 2.ext`(**既存の数字を解釈しない**。Finder どおり)。
  `replace` は同じフォルダの `.qooViewer-replace-<UUID>` へ退避 → コピー → 成功したら退避をゴミ箱へ、中断・失敗なら退避を戻す。
- 事前検査(1 バイトも書く前): `access(W_OK)`、宛先が元の中でない、名前 255 バイト、パス 1024 バイト、`volumeMaximumFileSize`、空き容量(同一ボリューム内の移動は検査しない)。
- 部分失敗は捨てない: `TransferOutcome { receipts: [TransferReceipt]; failures: [FailedItem] }`。
- ゴミ箱: `TrashAvailability.hasTrash(for: URL)`(`url(for: .trashDirectory, create: false)`、マウントポイントごとに 1 回、`FileIO` 経由)。無ければ
  呼び出し側が確認して `deletePermanently`(`EPERM`/`EBUSY` は 100ms 空けて 3 回まで再試行)。
- 進捗: `ProgressSink`(100ms の間引き、項目の最初のバイトは間引かない、最後は必ず通す)。

### 2.4 `Models/FileNameValidation.swift`(新規、純粋関数)

禁止は `/`、`.`、`..`、空、長さ(NFD 後の UTF-16 単位 255 と UTF-8 255 バイト)。`/` は Finder のように `:` へ置換せず理由を返す。
`nextAvailableName(_:in existing: Set<String>)`(`name 2.ext` …。比較は `precomposed + lowercased`)。
`untitledFolderName(existing:)`(`String(localized: "untitled folder")` → 「名称未設定フォルダ」。2 つ目以降の番号の付け方は**実機の Finder で確認してから**固定)。

### 2.5 コマンドと Undo(`ViewModels/FileCommands/`、新規)

```swift
@MainActor protocol FileCommand: AnyObject {
    var displayName: String { get }          // 「"X" の移動」。表示言語で組む(String(localized:language:))
    var isUndoable: Bool { get }
    func execute() async throws -> CommandResult      // .success / .partial(failures)
    func undo() async throws -> UndoResult            // .complete / .partial / .impossible(reason)
    func redo() async throws -> CommandResult         // 既定 = execute()
}
@MainActor final class FileCommandStack: ObservableObject {   // ウインドウごと(FileBrowserState が持つ)
    static let depth = 50
    @Published private(set) var canUndo, canRedo; var undoTitle, redoTitle: String
    func run(_ command: FileCommand) async -> CommandResult
    func undo() async -> UndoOutcome    // 部分取り消し・不能は redo へ積まない
    func redo() async -> CommandResult
}
```

コマンド: `MoveFilesCommand`(undo は `.keepBoth` で戻す。名前が変わったら `.partial`)、`CopyFilesCommand`(undo = 生成物をゴミ箱)、
`RenameCommand`、`TrashCommand`(undo = `restoreFromTrash`)、`CreateFolderCommand`(undo = 空のときだけゴミ箱。空判定は `FileIO`)、
`CompositeCommand`(D&D のコピー+移動混在、「〈名前〉に展開」。**中断のときだけ**実行済みの子を巻き戻す)、
`BulkRenameCommand`(段階 5)、`CompressCommand` / `ExtractCommand`(段階 6)。
「戻せなかった」は必ず見せる(`UndoOutcome.needsAttention` → 段階 4 のトースト/アラート)。

### 2.6 テスト(`qooViewerTests/FileOperations/`)

- **使い捨てボリューム**: `DisposableVolume`(`hdiutil create -size 64m -fs APFS -volname qooTest-<UUID>` → `attach -nobrowse`、deinit で `detach` + 削除)。
  exFAT 版も 1 つ(`renamex_np` の `ENOTSUP` 縮退経路・4GB 上限・2 秒精度)。テストホストはサンドボックスの中だが `/Volumes/<name>` の
  **新しいディスクイメージは起動ボリュームの許可が覆う**(qooLibrary 実測)ので、`FolderAccessStore` を使わずに読み書きできる。
  `swift test` 相当で残ったボリュームが無いか `ls /Volumes` を後始末で見る。
- ケース: 同一ボリューム移動がバイトを運ばない(inode 不変)/ 別ボリューム移動 / コピーが `EXCL` で上書きしない / クローン(`totalFileAllocatedSize` が増えない)/
  衝突 3 択 / `replace` の中断で両方残る / `keepBoth` の採番 / 大文字小文字だけの改名 / 事前検査の各失敗 / 部分失敗の受領書 / ゴミ箱 → 戻す(実ゴミ箱に触れる
  テストはホームの `~/.Trash` を汚すので **`TrashAvailability` と `restoreFromTrash` の経路だけを一時フォルダの疑似ゴミ箱で**)/ `FileIO` の枯渇テスト
  (プールをコア数ぶん塞いだ状態で `perform` が 1 秒以内に始まる)/ `Cancellation` / `FileCommandStack`(部分取り消しは redo へ積まない、深さ 50)。
- `MountTable`: `/`、`/Volumes/<disposable>` の判定、存在しないパスの最長一致が `/` へ後退しないこと。

---

## 段階 3. 画面(読むだけ)

**実装済み・実機検証済み(2026-09-13。全 1079 テスト・108 suite 通過)。** いま入っているものの説明は
[docs/15-file-browser.md](../15-file-browser.md)。下の §3.1〜3.7 は立案時の計画のまま残し、変えた点を §3.8、次の人への引き継ぎを §3.9 に書く。

### 3.1 状態: `ViewModels/FileBrowserState.swift`(新規、`ContentView` が `@StateObject`)

```swift
@MainActor final class FileBrowserState: ObservableObject {
    @Published private(set) var currentFolder: URL?          // nil = ボリューム一覧(「コンピュータ」)
    @Published private(set) var entries: [FileBrowserEntry]  // 全ファイル。並べ替え・絞り込み後
    @Published var selection: Set<URL>
    @Published var viewMode: FileBrowserViewMode             // .list / .icons(保存)
    @Published var sort: FolderBrowserSort                    // 既存の型。保存(AppPreferences.fileBrowserSort*)
    @Published var iconSize: CGFloat                         // 保存
    @Published var filterText: String                        // 保存しない。フォルダを移ったら空に
    @Published private(set) var loadError: FileBrowserLoadError?  // 権限 / 未接続 / 消えた
    let commandStack: FileCommandStack
    var canGoBack, canGoForward, canGoUp: Bool
    func navigate(to folder: URL); func goBack(); func goForward(); func goUp()
    func reveal(_ url: URL)                                   // 親へ移動して選択+スクロール
    func reload()                                             // 世代番号で古い結果を捨てる
    func releaseResources()                                   // FSEvents を止める(ウインドウを閉じるとき)
}
```

- 読み込みは `FileIO` の上で `enumerator(at:includingPropertiesForKeys:options:[.skipsSubdirectoryDescendants, .skipsHiddenFiles])`。
  キーは `isDirectoryKey, isPackageKey, isSymbolicLinkKey, localizedNameKey, totalFileSizeKey, fileSizeKey, creationDateKey, contentModificationDateKey, contentTypeKey`。
  **サブフォルダの中は見ない**(三角も件数も出さない)。`FileBrowserEntry` は表示・並べ替えに要る値を全部持つ(`DirectoryBrowser.Entry` と同じ考え方。
  `isBook`(書庫/PDF/EPUB/画像)、`isPackage`、`typeDescription` は拡張子キャッシュ)。
- 現在のフォルダは `FolderChangeWatcher`(既存)で見張る(`WatchRoot` なし)。アクティブ化でも読み直す。
- `goUp` の天井: ボリュームのルートなら「コンピュータ」へ。「コンピュータ」ではグレーアウト。
- 起動時のフォルダ: `AppPreferences.fileBrowserStartupLocation`(`.home` / `.favorite(id)` / `.last`)。`.home` は実ホーム(`getpwuid`)。
  権限が無ければ `loadError = .needsAccess` を出し、右ペインの中央に「アクセスを許可…」(既存の `SidePanelBrowserState.requestFolderAccess` と同じパネル)。
  `.last` は `LastUsedFolderMemory("qooViewer.fileBrowser.lastFolder")`。無ければ `.home`。**シークレットウインドウでは書かない**。
- モード: `WelcomeLibraryState.mode: WelcomeMode`(`.shelf` / `.browser`、UserDefaults `qooViewer.welcome.mode`)。

### 3.2 ツリー: `Views/FileBrowser/FileBrowserTreeView.swift`(`NSViewRepresentable` → `NSOutlineView`)

- 3 つのグループ(`NSOutlineView` の group row): ボリューム(`MountTable` から。`MNT_DONTBROWSE` を除く。着脱は `NSWorkspace.didMount/didUnmount/didRenameVolume`)、
  ホーム(実ホーム 1 行。子はホーム直下のフォルダ)、よく使う項目(`FavoriteLocationStore`。見出しの右に「＋」= `NSOpenPanel` → `FolderAccessStore.add` → 登録)。
- **起動時はボリュームもホームも閉じている**(要望)。展開状態は保存しない。
- 子の読み込みは行を開いたときだけ、`FileIO` 経由(`isExpandable` は「フォルダである」だけで決め、**サブフォルダの有無を調べない** ―― TCC と往復の両方の理由。
  開いたら空なら空と分かる)。パッケージは出さない。たたんだら子を捨てる。
- 右クリック(`FileBrowserTreeContextMenu`、`NSMenu`): 開く / 新規タブで開く / 新規ノーマルウインドウで開く / 新規シークレットウインドウで開く /
  このアプリケーションで開く / 新規フォルダ / ペースト / Finder で表示。よく使う項目のルート行だけ「よく使う項目から削除」。
  「開く」= 画像フォルダ(`ShelfFolderResolver.role == .book`)なら本として開く、それ以外は右ペインで表示。判定は**メニューを開いた瞬間に `FileIO` で 1 回**
  (`NSMenuDelegate.menuNeedsUpdate` は同期なので、判定が終わるまで項目を無効にして返し、終わったら有効にする)。
- スプリングローデッド: `NSOutlineView` の標準(ドラッグ静止で展開)。
- 見た目: 面はすりガラス(`PanelSurface.welcome`)なので `NSOutlineView` は `backgroundColor = .clear`、行の文字は `NSTextField` に
  `PanelContentShadow` と同じ 4 方向の影(`shadow` 属性)。選択は `NSTableRowView` を継承して `Color.accentColor` + 反対色の縁。
  **ダーク+白 100% / ライト+黒 100% で実測**してから完了。
- 閉包・delegate は `dismantleNSView` で切る。`NSTrackingArea` は使わない。

### 3.3 リスト: `Views/FileBrowser/FileBrowserListView.swift`(`NSViewRepresentable` → `NSTableView`)

- 列: 名前(アイコン + 名前。残り幅へ伸びる)/ 変更日 / サイズ / 種類 / 作成日。`autosaveName = "qooViewer.fileBrowser.list"` で列幅と並びを保存。
  ヘッダのクリックで並べ替え(`sort` と同期)。フォルダを上に(`sort.grouping`)は全基準で効く(既存の `FolderBrowserSort` どおり)。
- データは `entries` の差し替え(`reloadData`)。1 万件で `body` が走らないのが AppKit の利点。
- 単発クリック = 選択、⌘/⇧ は標準。**選択済みの 1 件をもう一度クリック → ダブルクリック間隔後にインラインリネーム**(`NSTableView` の標準。
  `NSTextField` の `isEditable`、フィールドエディタで拡張子を除いて選択)。ダブルクリック / Return = `open`(段階 3 では本と画像だけ。それ以外は `NSWorkspace.open`)。
  フォルダは**常に移動**(画像フォルダでも。要望)。
- 右クリック = 選択に含まれていればその全部、外ならその 1 件(`NSTableView.clickedRow` で標準どおり)。段階 3 では「開く」系・「Finder で表示」・
  「このアプリケーションで開く」だけ。残りは段階 4。
- 空きスペースの右クリック: 段階 4。
- 見た目: `backgroundColor = .clear`、`usesAlternatingRowBackgroundColors = false`、行の地は `Color.primary.opacity(0.04)` 相当の交互色を自前で(面の色に追従)。
  文字は影付き。ヘッダは `NSTableHeaderView` のまま(不透明)。

### 3.4 アイコン表示: `Views/FileBrowser/FileBrowserIconView.swift`(SwiftUI)

- `ScrollView` + `LazyVGrid`(`WelcomeGridColumns` の固定幅の列)。セルは `FileBrowserIconCell`(アイコン/サムネイル + 名前 2 行中略)。
- 選択: `MarqueeSelection`(既存。セルの外から引く帯、⌘ で外す)、クリックで選択、⌘/⇧ を自前(`CollectionDetailView` と同じ)。
- 大きさ: 右上のスライダー + ピンチ(`welcomeGridPinch` の形)。
- 右クリック: セルごとの `.contextMenu`(`contextTargets` の規則)。**非選択のセルの枠線は出ない**(`LazyVGrid` の既知の制限。qooLibrary と同じ)。
- キーボード: ↑↓←→ は自前(`Models/GridKeyboardNavigation.swift`、純粋関数 + テスト。列数はレイアウトと同じ式)。type-select は段階 4。
- 画面外セルの絵は `LazyCellImageBudget` で手放す。

### 3.5 操作列・パスバー・切替

(段階 1 から回した)`WelcomeTopBar` の左端に「ファイルブラウザ」ボタン(`SidePanelNavButton` の形、`systemImage: "folder"`)。
押されている状態(`.browser`)はアクセント地 + `.panelOutlinedAccent(in:)`(`WelcomeEditToggle` と同じ描き方)。

- `Views/FileBrowser/FileBrowserPane.swift`: 左右の幅ドラッグ(`SidePanelView.widthDragHitArea` と同じ作り。幅は保存)。上の操作列は
  `WelcomePaneHeaderLayout`(左: ‹ › ↑、中央: `WelcomeSearchField`、右: 表示切替(`Picker` の 2 アイコン `list.bullet` / `square.grid.2x2`)、
  `SidePanelSortMenu`(基準 + 向き)、スライダー(アイコン表示のときだけ有効))。
- `Views/FileBrowser/FileBrowserPathBar.swift`: `NSPathControl`(`.standard`)。**`url` は設定せず `pathItems` を自分で組む**(名前は `localizedName` を
  一覧の読み込み時に取ったものか `lastPathComponent`、アイコンは `NSWorkspace.icon(for: .folder)` / ボリュームは `icon(forFile:)` をローカルだけ同期)。
  クリックで `navigate`。ドロップは段階 4。地は `controlBackgroundColor` の帯(不透明なので輪郭不要)。
- `WelcomeTopBar` の「ファイルブラウザ」ボタン、`WelcomeView` の `mode` 分岐。「ウェルカム画面へ戻る」で `mode` と `currentFolder` はそのまま。
- 「本を開く」経路: `AppState.open(urls:)`(`BookOpenRequest` の正規化のまま)。新規タブ/ウインドウ: `BookOpenContextMenuItems` + `BookWindowOpener`。
  **フォルダを新規タブ/ウインドウで開く**ために `WindowContentRequest`(`case book(BookOpenRequest)` / `case browse(URL)`、`Codable, Hashable, Sendable`)を
  4 つの `WindowGroup` の提示値にする。`BookWindowOpener.open(_ request: WindowContentRequest, ...)`。`browse` は重複判定の対象外。
  受け取った `ContentView` は `mode = .browser` + `navigate(to:)`。権限は `SecurityScopedHandoff` で 10 秒受け渡す(フォルダも同じ経路でよい)。

### 3.6 環境設定「ファイルブラウザ」

- `SettingsPane.fileBrowser`(`.top` グループの 3 つ目。無彩色で「一般」より濃い灰。`systemImage: "folder.fill"`、`title: "File Browser"`)。
- `Views/FileBrowserSettingsView.swift`: 起動時に表示するフォルダ(`SettingsPicker`。「よく使う項目」はサブの `Picker` で 1 つ選ぶ。未登録なら無効)/
  フォルダを上に表示 / 外からドロップしたとき(ビューアで開く / コピー・移動)/ 「ここに圧縮」の拡張子(zip / cbz)/
  **本の表示中に「ファイルブラウザで開く」を選んだとき**(新規タブ / 新規ノーマルウインドウ / 新規シークレットウインドウ。`BookOpenDestination` の 3 値を
  `FileBrowserRevealDestination` として保存)/ 動画のサムネイルを作る / サムネイルのキャッシュの上限(段階 7 で有効化)。
- `AppPreferences` にキー `qooViewer.pref.fileBrowser.*` と `keys(for: .fileBrowser)`。

### 3.7 テスト・確認

- `FileBrowserStateTests`(一時フォルダ: 一覧・並べ替え・絞り込み・戻る/進む/上・世代番号・消えたフォルダの祖先への退避・`reveal`)。
- `GridKeyboardNavigationTests`。`WindowContentRequest` の `Codable` 往復。`FileBrowserSettings` のキーと `resetToDefaults`。
- 実機(使い捨てボリューム + 合成名): モード切替、ボリューム/ホーム/よく使う項目、ホームの初回許可が 1 回で済むこと、**デスクトップ/書類/ダウンロードへ
  入ったときだけ TCC が 1 回出ること**(`tccutil reset All com.qooProject.qooViewer.debug` で戻して再確認)、`~/Library` を開いてもダイアログが出ないこと、
  すりガラス 2 条件、ウインドウを閉じたあとの `AppState` 残留が増えていないこと(`heap`。docs/12)。

### 3.8 計画から変えた点・実測で分かった点(2026-09-13)

- **設定の保存先**: 並べ替えの基準と向き・表示形式・アイコンの大きさ・左の幅は `AppPreferences` ではなく
  `FileBrowserState` が `qooViewer.fileBrowser.*` へ(環境設定の画面に並ばない値。`WelcomeLibraryState` と同じ扱い)。
  「フォルダを上に」だけは環境設定の行なので `qooViewer.pref.fileBrowser.foldersFirst`(サイドパネルの「並び順」とは独立)。
- **最後に表示したフォルダはパスだけ**(`qooViewer.fileBrowser.lastFolderPath`)。`LastUsedFolderMemory` のブックマークは
  開かないスコープを抱えるだけで意味が無い(読む権限は `FolderAccessStore` に一本化)。
- **環境設定「ファイルブラウザ」はいま効く 2 行だけ**(起動時のフォルダ・フォルダを上に)。外からのドロップ・圧縮の拡張子・
  「ファイルブラウザで開く」の行き先・動画のサムネイル・キャッシュの行は、それを使う段階(4・6・8・7)で足す。
- **「このアプリケーションで開く」は段階 8 へ**(3 つの一覧で揃えて入れる。SwiftUI の `.contextMenu` の中で LaunchServices を
  引くと、行の本体評価のたびに走りうる)。
- **右クリックの「開く」の画像フォルダ判定はメニューを開くときではなく、選んだときに `FileIO` で**(`NSMenuDelegate` で項目を
  一時的に無効にする仕掛けが要らない。項目の数も状態で変わらない)。新規タブ/ウインドウも同じ判定で本かファイルブラウザかを決める。
- **アイコンは種類だけで引く**(`FileBrowserIconProvider`)。`icon(forFile:)` はネットワークでブロックし、デスクトップ・書類の
  カスタムアイコンを読みに行くと TCC のダイアログが出る。
- **`MarqueeSelection` の鍵を `AnyHashable` にした**(型の出し入れは型引数付きの `marqueeCell` / `marqueeSelectable`。帯の意味
  `.additive` / `.replacing`、余白のクリックを追加)。**クラスを `MarqueeSelection<ID>` にすると Release(-O)でコンパイラが `deinit` の
  最適化中に落ちた**(Swift 6.3.3。Debug では通る)ので、型引数はビュー側に置いた。座標空間の名前は `MarqueeCoordinateSpace.name`。
  **CI と同じ `-configuration Release QOO_CI_WARNINGS_AS_ERRORS=YES` のビルドをコミット前に通すこと。**
- **並べ替えの比較を共有にした**(`FolderBrowserSort.sorted` + `FolderBrowserSortable`)。`DirectoryBrowser.sortedEntries` はそこへ委譲。
- **`WindowContentRequest.browse` は `nonce` 付き**(`openWindow(id:value:)` が等値のウインドウを前面に出すだけになるため)。
  フォルダの通常ウインドウは `"book"` ではなく `"normal"`(`BookWindowGroup.id(forBrowsing:)`)。
- **ツリーのグループ(ボリューム/ホーム/よく使う項目)の見出しは開いた状態で始め、中の行を閉じておく**
  (「起動時はボリュームもホームも閉じている」をこう読んだ)。
- **実機で見つけて直したもの**(すりガラス 2 条件): ダーク+白 100% で**ツリーの開閉の三角が消えた** →
  `FileBrowserOutlineView` がボタンの絵を輪郭入りに焼き直す。同じ条件で**列の見出しが文字ごと消えた**(既定の見出しは半透明)→
  `FileBrowserTableHeaderView` が不透明な地を敷く。ライト+黒 100% で**「アクセスを許可…」の文字が地に溶けた**
  (`.panelControlWell()` の溝では足りない)→ `.borderedProminent`。
- **ユーザーが触ってからの調整(2026-09-13)**: 帯の切り替えを**「ファイルブラウザ」と文字で出す**横長のボタンにした
  (アイコンだけでは読めない。幅は文字に合わせる)。切り替えとライブラリの並びの間・帯の下・ツリーと右ペインの間の線を
  `WelcomeSeparator`(文字色 28% + 輪郭)にした(すりガラスの上で標準の `Divider` が薄い)。アイコンの大きさのスライダーは
  **アイコン表示のときだけ出し、リスト表示ボタンの左に置く**(ボタンの位置を表示形式で動かさない)。
- 実機で確認できたこと: モードの切り替えと保存、コンピュータ・ボリューム・ツリーの展開(子は開いたときだけ)、ツリーの行での移動と
  右ペインとの選択の同期、リスト/アイコンの切り替え、ダブルクリックで移動、上へで元のフォルダが選ばれる、パスバーの移動、
  検索の絞り込み、⇧クリックの範囲・矢印キー・帯での置き換え選択・余白のクリックで解除、右クリックの「開く」で画像フォルダが本として開く、
  「ウェルカム画面へ戻る」で同じフォルダに戻る、新規タブでフォルダが開く、FSEvents の即時反映(選択は残る)、表示中のフォルダを
  消すと祖先へ移る、読めないフォルダの案内、左の幅のドラッグと保存、空のフォルダの案内、すりガラス 2 条件、開閉 6 回で
  `FileBrowserState` / `AppState` が増えないこと(`heap`)。

### 3.9 引き継ぎ(段階 3 → 段階 4、2026-09-13)

**次に着手するのは段階 4(書く操作の UI)。** 始める前に知っておくこと:

- **ユーザーの状況(2026-09-13 時点)**: Debug ビルドで段階 3 を実際に触ってもらい、上の見た目の調整 3 点まで「いい感じ」。
  リネームがまだ無いことは説明済み(1 件ずつは段階 4、一括は段階 5)。
- **調整分の実機確認の範囲**: 帯のボタン・区切り線・スライダーの位置はユーザーが実機で見て了承した。**すりガラス 2 条件
  (ダーク+白100% / ライト+黒100%)ではまだ見ていない**(`WelcomeSeparator` は `.panelOutlinedContent()` を掛けてある)。
  段階 4 で帯やペインに触るときに合わせて見る。

- **まだ実機で確かめていないもの**(ファイル選択ダイアログが要るので自動操作していない。ユーザーに操作してもらう):
  「アクセスを許可…」で許可すると一覧が出ること、よく使う項目の「＋」→ 登録 → 起動時のフォルダに選べること、
  **ホームの初回の許可が 1 回で済むこと**、**デスクトップ/書類/ダウンロードへ入ったときだけ TCC が 1 回出ること**
  (`tccutil reset All com.qooProject.qooViewer.debug` で戻して再確認)、`~/Library` を開いてもダイアログが出ないこと、
  シークレットウインドウで「＋」「削除」が淡色になること、「Finder で表示」、新規ノーマル/シークレットウインドウでフォルダを開くこと。
  段階 4 の最初にまとめて頼むとよい。
- **置き場所**: 画面は `Views/FileBrowser/`(`FileBrowserPane` / `FileBrowserTreeView` / `FileBrowserListView` / `FileBrowserIconView` /
  `FileBrowserPathBar` / `FileBrowserActions` / `FileBrowserAppKitParts`)、状態は `ViewModels/FileBrowserState.swift`、
  一覧の読み取りは `Services/FileBrowser/FileBrowserListing.swift`、環境設定は `Views/FileBrowserSettingsView.swift`。
- **右クリックの項目は `FileBrowserMenuCommand` に足す**(3 つの一覧が共有。AppKit は `FileBrowserMenuBuilder`、SwiftUI は
  `FileBrowserContextMenuItems`)。**項目の数を状態で変えない**(淡色にする)。空きスペースの右クリックはまだ無い
  (リストは `clickedRow == -1` で空のメニュー、アイコンは余白に `.contextMenu` が無い)。
- **レスポンダチェーン**: リストは `FileBrowserTableView`(`NSTableView` のサブクラス。Return / ⌘↓ を `onReturn` へ)に
  `copy:` / `cut:` / `paste:` / `delete:` を足せば標準の編集メニューが効く。アイコン表示はまだ `NSView` で包んでいない
  (`.focusable()` + `.onKeyPress` で矢印と Return だけ)。計画どおり `FileBrowserKeyResponder` で包む。
- **コマンドの実行**: `state.commandStack`(`FileCommandStack`、ウインドウごと)。操作のあとは `state.reload()` を待たなくても
  FSEvents が読み直すが、ネットワークでは飛ばないので明示的に `reload()` する。選択して見せるなら `reveal(_:)` か `select` + `scrollRequest`。
- **ツリーは子をたたむまで読み直さない**(docs/15 の既知の制限)。段階 4 で新規フォルダ・移動を入れると目に付くので、
  操作の後に該当する親の行を読み直す口(`Coordinator.loadChildren(of:)` を開いている行に対して呼ぶ)を足すこと。
- **ユーザー要望(2026-09-13、段階 4 以降のどこかで入れる)**: 環境設定「ファイルブラウザ」に**「現在のフォルダまでツリーを自動で展開する」**
  設定を足す。ON なら右ペインで移動するたびに、ツリーの該当する根(ボリューム・ホーム・よく使う項目のうち、現在のフォルダを含む
  いちばん深いもの)から現在のフォルダまでの行を順に開き、その行を選んで見える位置へスクロールする。作るときの注意:
  子は開いたときに `FileIO` で読む非同期なので、1 段ずつ読み終わるのを待って次を開く(世代番号で途中の移動に負けないように)。
  展開の途中の階層も TCC の保護領域に触れうるので、**右ペインで既に読めているパスの祖先だけ**を開く。OFF(既定)は今のまま。
  既定値・`keys(for: .fileBrowser)`・`apply`・`AppPreferencesTests.paneSettings`・`mutateEverySetting` を揃えること。
  ツリーを読み直す口(下の項目)と一緒に作ると無駄が無い。
- **インラインリネーム**は未実装(`FileBrowserCellView` のラベルは編集不可。リストは `NSTextField.isEditable` とフィールドエディタで)。
- **リーク**: AppKit の部品を足したら `dismantleNSView` で delegate・メニュー・対象・閉包を切る。`FileBrowserActions` は相手を weak で。
  開閉を繰り返して `heap` で数える(docs/12「ファイルブラウザ」)。
- **すりガラス 2 条件**は実機で必ず見る。AppKit の既定の部品(三角・見出し・ベゼル)は SwiftUI の輪郭が届かず、ここでしか見つからなかった。
- **文言**: 段階 3 で 26 件を `Localizable.xcstrings` へ手で足した(書式は段階 2 の引き継ぎと同じ。空の辞書 `"" : {}` だけ
  Xcode は `{\n\n    }` と書くので、`json.dumps` の後で置き換えると差分が出ない)。

---

## 段階 4. 書く操作の UI

**4a を実装・実機検証・コミット済み(2026-09-13)。4b は D&D まで実装・コミット済み。**
下の計画のうち入ったもの・変えた点・残り:

- 入ったもの: `FileBrowserOperations`(`FileBrowserState.operations`。コピー/カット/ペースト/⌥⌘V/ゴミ箱/完全削除の確認/
  新規フォルダ/名前の変更/取り消し・やり直し。操作は 1 本ずつ直列)、`FileBrowserSheetPresenter`(確認・衝突・問題の報告を
  `AppState.hostWindow` のシートで)、`FileBrowserProgressBar`(パスバーの上。400ms の猶予のあとに出す)、右クリックの全項目
  (要望の一覧どおりフォルダ/ファイル/空きスペース/ツリーで並びを分け、段階 6・8 の項目は淡色で置いた)、リストの
  インラインリネーム(`FileBrowserNameField`。選ばれた 1 行の再クリック、Esc で取りやめ、編集中は読み直しを待たせる)、
  リストのレスポンダ(`copy:`/`cut:`/`paste:` + ⌘⌫/⌥⌘V/⌘[/⌘]/⌘↑)、アイコン表示の `.onCommand` とキー、カット済みの淡色、
  編集メニューの「取り消す/やり直す」(`MenuCheckmarkState.fileBrowserUndoTitle`。テキスト編集中はその欄へ流す)、
  ツリーの開いている行の読み直し(`FileBrowserState.fileSystemChange`。同じパスの Node を使い回して孫の開閉を保つ)。
- 変えた点: **衝突の確認は「両方残す / スキップ / 中止」だけ**(「置き換える」は `ReplaceBackupJournal` を入れてから)。
  **新規フォルダはファイルメニューの項目(Finder と同じ ⇧⌘N)**。それまで ⇧⌘N だった「新規シークレットウインドウ」は **⌥⌘N へ移した**
  (2026-09-13、ユーザー決定。MANUAL の 2 箇所と CHANGELOG は文書更新の指示が出たときに直す)。
  「置き換える」を復旧記録ができるまで出さないこともユーザー了承済み。
  失敗は帯の下の 1 行を出さずアラートだけ。ペーストはリストのフォルダ行を右クリックしても**表示中のフォルダへ**(Finder と同じ)。
- **実機検証(2026-09-13、Debug・空の本棚・使い捨て APFS ボリューム 2 本に合成名。手順は docs/12「ファイルブラウザ」)**:
  ファイルメニュー(⌥⌘N / ⇧⌘N)、⌘C → 空のフォルダで ⌘V(貼ったものが選ばれ、編集メニューが「「note1.txt」のコピーを取り消す」)、
  ⌘Z(ボリュームのゴミ箱へ)/ ⇧⌘Z、⇧⌘N → 名前の編集 → Return、選んだ行の再クリックで拡張子の前まで選択・Esc で取りやめ、
  ⌘⌫ と ⌘Z、右クリック 3 種の並びと淡色、別ボリュームへの 900MB のコピー、衝突のシート(「両方を残す」で `big 2.bin`)と
  その下の進捗の帯、アイコン表示のカット(淡色)→ ⌘V で移動・⌘⌫・⌘[ / ⌘]、検索欄での ⌘⌫ は文字だけ消えること、
  操作後にツリーの開いている行へ新しいフォルダが出ること、新規ウインドウの開閉 6 回で `AppState` / `FileBrowserState` /
  `FileBrowserOperations` が増えないこと(`heap`)。後始末でストア・表紙・defaults が控えと一致。
- **実機で見つけて直したもの**: ① 空のフォルダでは一覧の代わりに案内だけを出していたので、⌘V を受ける相手も空きスペースの
  右クリックも無く**空のフォルダへペーストできなかった** → 一覧の上に案内を重ねる。② **AppKit の右クリックメニューの淡色が
  効いていなかった**(`NSMenu.autoenablesItems` の既定が `isEnabled` を無視する。段階 3 から)→ `autoenablesItems = false`。
  ③ **アイコン表示で ⌘⌫ / ⌘[ / ⌘] が届かなかった**(`.onKeyPress(phases:)` も `.onKeyPress(keys:)` も)→ 表示中だけの
  キー監視(`FileBrowserKeyMonitor`。テキスト編集中は受けない、`dismantleNSView` で外す)。
- 実機で確かめられなかったもの: 進捗の帯の途中の数字と残り時間(SSD 上のイメージ間で 900MB が 1 秒未満で終わり、帯は衝突の
  確認を待つ間の「0 KB / 943.7 MB」だけ見えた)、すりガラス 2 条件での新しい部品(帯は不透明な地)、アイコン表示の
  インラインリネーム(未実装。アイコン表示で新規フォルダを作ると名前の編集が始まらない)。
- **4a の後の追加要望(2026-09-13、実装・実機検証済み。詳細は docs/15)**: ファイル操作の効果音(qooLibrary と同じ割り当て)、
  ファイルブラウザ表示中の「移動」メニューを Finder 準拠に(+「フォルダへ移動…」)、操作列の中央をフォルダ名にして検索をボタンから広がる形に。
  あわせて、テストホストのウインドウが実際のホームを読まないよう本棚で始めるようにした(ユーザー報告の「虹色のカーソル」の調査から)。
  音が実際に鳴るかはユーザーの耳での確認待ち。
- **4b の D&D を実装・実機検証・コミット済み(2026-09-13)。説明は docs/15「ドラッグ&ドロップ」**。計画から変えた点: 修飾キーは
  Finder の実際どおり **⌥ = 常にコピー、⌘ = 常に移動**(「⌥ で反転」ではない)。環境設定の行は「他のアプリからドロップしたとき」
  (既定「ビューアで開く」)。**スプリングローデッドは入れていない**。実機(Debug・空の本棚・使い捨て APFS 2 本に合成名、CGEvent で
  ドラッグを合成)で確かめたこと: リストの行→フォルダの行(同じボリュームで移動)、リスト→ツリーのボリューム(別ボリュームでコピー)、
  ⌥ でリストの空きへ(複製)、フォルダを操作列・自分の上へ落としても何も起きず本も開かない、パスバーの成分へ(枠が出て移動)、
  アイコン表示で 2 件選んでフォルダのセルへ(件数のバッジ・セルの強調・両方移動)→ ⌘Z で両方戻る、アイコン表示の余白へ ⌥(複製)、
  ツリーのフォルダの行→アイコン表示のフォルダ(移動しツリーからも消える)、Finder → 余白(既定で本として開く)、設定を「コピー・移動」にして
  Finder の別ボリューム → フォルダのセル(コピー)・同じボリューム → フォルダのセル(サンドボックス下でも移動でき、衝突のシートで「両方を残す」)。
  実機で見つけて直したもの: SwiftUI の受け口で**ドロップ後に強調が残った**(`performDrop` の後に `dropUpdated` が届く)、**⌥ を離すのと
  同時にボタンを離すとコピーが「何もしない」に化けた**(修飾キーをイベントから読むよう変更)。
  確かめていないもの: すりガラス 2 条件でのドロップの強調(ペインの枠・セルの地は `.panelOutlinedAccent`)、qooViewer から Finder への
  ドラッグ(コピー)、ウインドウをまたいだドラッグ、`heap` でのリーク、ネットワークボリューム。
- **D&D コミット後の確認(2026-09-13)**: すりガラス 2 条件(アイコン表示のフォルダの強調・右ペインの枠は見える。リスト全体の強調は
  AppKit 標準の細い枠で薄いが見える)、qooViewer → Finder(別・同じボリュームともコピー)、ウインドウをまたいだドラッグ、開閉とドラッグの
  繰り返しで `heap` の生存数が増えないこと。見つけて直したもの: **ツリーの行へのドロップが、静止して行が開いた直後だと黙って断られる**
  (ドラッグ中は行を開かない)、その直し方の途中で **`draggingEnded` の上書きがドラッグ元の終わりの通知を止める**こと、
  **取り消し・やり直しがツリーへ知らせていなかった**。ネットワークへの書き込みは、手元の WebDAV の検証用サーバーが読み取り専用のため確かめられず
  (移動は「項目が見つかりませんでした」で報告された)。あわせて、ユーザー指摘で**「フォルダへ移動」のシートの余白とボタンの幅**を直し、
  要望で**サブフォルダの無い行の三角を消した**(docs/15「ツリーの三角」)。
- **Finder へのドラッグを移動にも(2026-09-14、ユーザー指摘「Finder へは移動が期待では」)**: アプリの外へのマスクに move / generic を足し、
  Finder が同じボリュームで移動・別でコピー・⌥ でコピー・⌘ で別ボリュームへ移動すること(リストとアイコン表示)、
  ウインドウをまたいだ同じボリュームのドラッグが移動になることを実機で確かめた。Dock のゴミ箱(`.delete`)は合成したドラッグでは
  Finder からでも受け付けられず確かめられないので、許していない(ユーザーに実際の操作で試してもらう候補)。
- **アイコン表示の名前の変更と type-select(2026-09-14、実装・実機検証済み。説明は docs/15「クリックとキー」「書く操作」)**:
  実機(Debug・空の本棚・使い捨て APFS 1 本に合成名)で確かめたこと: 選んだ項目の名前の再クリックで編集が始まり拡張子の前まで選ばれる、
  Return で確定(選択が残る)・Esc で取りやめ・ほかのクリックで確定・リスト表示へ切り替えて確定、⇧⌘N の直後にフォルダ名全体が選ばれて始まる、
  右クリックの「名前を変更」、長い名前で欄が 3 行に伸びる、ダブルクリックでは編集が始まらず開く、欄の中の ⌘C は文字のコピー、⌘Z で名前が戻る、
  リスト表示で新規フォルダ → Esc → アイコン表示へ切り替えても編集が始まらない、すりガラス 2 条件で欄が見える、type-select(b → b → 1 秒後 ch)。
  実機で見つけて直したもの: **打った文字が type-select に、Return が「開く」に取られた**(`.onKeyPress` は編集中も先に取る)、
  **欄に焦点が置かれないことがあった**(ウインドウに入る前に `makeFirstResponder` していた)、**ダブルクリックの判定に `clickCount` が使えない**。
  合成したクリックを 1 秒未満の間隔で続けると、タップが 1 回拾われないことが 1 度あった(間隔を 1.5 秒にすると 12 回とも拾われ、再現できていない)。
- **「置き換える」+ 退避の復旧記録、ロックされた項目の確認(2026-09-14、実装・実機検証済み。説明は docs/15「書く操作」)**:
  `ReplaceBackupJournal`(qooLibrary から写した。記録は Application Support/FileOperations/replace-backups.json、テスト中はプロセスごとの
  一時フォルダ、テストのエンジンは `pseudoTrash` の隣の使い捨ての記録)と起動時の `ReplaceBackupRecovery`(テスト中は動かさない)。
  衝突の確認は「両方を残す(既定)/ 置き換える / スキップ / 中止」、ゴミ箱の無い宛先では「置き換えるとすぐに削除」と書き足す。
  ロックされた項目は `NSWorkspace.recycle` も `trashItem` も断る(実測。中にロックされた項目があるだけのフォルダは送れる)ので、
  確認(続ける / 中止)→ 外して送る → ゴミ箱の中で掛け直す。完全削除は中まで見て確認し、外して消す(消せなければ戻す)。
  実機(Debug・空の本棚・使い捨て APFS 1 本に合成名)で確かめたこと: 記録を 2 件(戻せるもの・元の場所が埋まっているもの)書いて起動すると、
  サンドボックスのまま 1 件目が戻り隠しフォルダも消え、2 件目は警告で記録に残る(アラート 2 枚を撮って確認)、⌘V の衝突のシートのボタン 4 つ
  (縦に同じ幅で並ぶ)、「置き換える」で新しい内容になり記録が残らないこと、⌘Z で古い内容に戻ること、ロックされた項目の ⌘⌫ で確認
  (既定は「中止」)→「続ける」でゴミ箱へ、⌘Z でロックされたまま戻ること(= ゴミ箱の中でも掛け直せていた)。
  確かめていないもの: ゴミ箱の無い共有での「置き換える」と完全削除の確認(手元に書ける SMB が無い)、ボリュームの `.Trashes` の中身
  (シェルからは読めない。⌘Z の結果で間接に確かめた)。
- **Finder からのペーストの実測、`untitledFolderName` の突き合わせ(2026-09-14、済。§4.12)**。
- 残り(4b): 実機確認(各操作・すりガラス 2 条件・`heap`)、段階 3 から持ち越した実機確認(§3.9)。

### 4.9 引き継ぎ(段階 4b の D&D 完了時点、2026-09-14)

**ブランチの状態**: `feature/file-browser` は `bebc71f` までプッシュ済みで作業ツリーはきれい。全 1432 テスト、CI と同じ
`-configuration Release QOO_CI_WARNINGS_AS_ERRORS=YES` のビルド、`scripts/ci/check-all.sh` が通る。CHANGELOG `[Unreleased]`・MANUAL・
README・docs/15 はここまでの内容に揃っている。`MARKETING_VERSION` は触っていない。

**ここまでに入ったもの(4b)**: ドラッグ&ドロップ一式(docs/15「ドラッグ&ドロップ」)、ツリーのサブフォルダの無い行の三角を消す
(docs/15「ツリーの三角」)、「フォルダへ移動」シートの余白とボタン幅、取り消し・やり直しをツリーへ知らせる修正。

**次に着手する候補(4b の残り。順番はユーザーに選んでもらう ―― 今回も「D&D から」をユーザーが選んだ)**:
1. ~~アイコン表示のインラインリネームと type-select~~(2026-09-14 済。§4 冒頭)
2. 「置き換える」+ 退避の復旧記録(qooLibrary の `ReplaceBackupJournal`)、ロックされた項目の削除の確認
3. Finder からのペーストをサンドボックスで実測、`untitledFolderName` の 2 つ目以降を実機の Finder と突き合わせ
4. ユーザー要望の「現在のフォルダまでツリーを自動で展開する」設定(§3.9 の要望。まだ入っていない)
5. 段階 8.5 の読み取り専用モードは**書く操作が出揃ってから**(決定事項 Q12)

**ユーザーに頼むこと(自動操作では確かめられない・していないもの)**:
- **Dock のゴミ箱へのドラッグ**: `.delete` をマスクに足すと対応できる見込みだが、CGEvent で合成したドラッグは Finder からでも
  ゴミ箱が受け付けず確かめられなかったので、許していない。実際のマウスで「Finder の項目をゴミ箱へ」が効く環境で、足した版を試してもらう。
- 段階 3 から持ち越しのファイル選択ダイアログ・TCC が絡む確認(§3.9)、効果音が実際に鳴るか(4a)。
- ネットワーク上の共有(SMB)への書き込み・D&D。手元の `scripts/dev/webdav-server.py` は**読み取り専用**(OPTIONS/PROPFIND/HEAD/GET だけ)で、
  移動は「項目が見つかりませんでした」の報告になった(報告の経路が働くことだけは確認)。

**気づいているが直していないもの**:
- リスト全体へのドロップの強調は AppKit 標準の細い枠で、すりガラス 2 条件では薄い(見えはする)。
- Finder など外での変更は、ツリーでは親をたたんで開き直すまで反映されない(三角の有無も同じ)。
- ウインドウをまたいだドラッグの取り消しは、落とした側のウインドウの履歴に積まれる(Finder は 1 つの履歴なので違う)。

**このブランチで分かった罠(コードのコメントと docs/15 にもある)**:
- `NSOutlineView` のスプリングローデッドは、開いた直後にその行を受け口から外す(動かさずに離すと黙って断られる)→ `shouldExpandItem` で止めた。
- `NSOutlineView` の `draggingEnded` / `concludeDragOperation` を上書きすると、そこへ落としたドラッグの**元**の
  `draggingSession(_:endedAt:operation:)` が呼ばれなくなる(`FileBrowserDragTracker` が残って外からのドラッグを取り違える)。
- SwiftUI の `DropDelegate` は `performDrop` の**後に** `dropUpdated` がもう 1 回来る(強調が付き直る)。
- `NSEvent.modifierFlags` はドロップの瞬間の修飾キーとずれうる(ボタンとキーをほぼ同時に離すと)→ マウスのイベントの flags を読む。
- SwiftUI の `.onDrop` が断ると、外側(ウインドウ全体の「本を開く」受け口)が拾う → 右ペインは全体を受け口で覆い、受け口として断る。
- 禁止語の検査(`check-private-terms`)は `/Volumes/<名前>/<名前>` の形を**合成名でも**拒否する。テストの置き場所は `X` で始まる名前
  (`/Volumes/XOther/…`)か `NoSuchVolume` などの許可された接頭辞にする。未追跡のファイルは `check-all.sh` では見られず、コミットの hook で初めて落ちる。

**実機検証の手順(このブランチで使ったもの。docs/12「ファイルブラウザ」に追記済み)**:
- 始める前に Debug のストア・表紙の保管庫・defaults を控えて退避し、`hdiutil` の合成名ボリュームを付け、defaults で
  `qooViewer.welcome.mode = browser`・起動時のフォルダ = 最後のフォルダ = そのボリュームにして起動する。終わったら増えたキーを消して
  `defaults import`、ストアと保管庫を戻して `cmp` / `diff -r`、ボリュームを外す。**アプリが開いたまま戻さない**(終了時に defaults を書く)。
  シートが出ていると `quit` はキャンセルされるので、先にシートを閉じる。
- ドラッグは CGEvent を送る小さな Swift のプログラムで合成する(docs/12)。ツリーの行の上で 1 秒以上止めると、以前は行が開いて
  結果が変わった(いまは開かない)。取り消しは ⌘Z を System Events で送る前に一覧の余白をクリックして焦点を戻す。
- 文字の入力は System Events の `keystroke` だと**日本語入力が有効なときにかなになる**。シートの欄は AX の `set value of text field` で入れる。
- ウインドウの大きさは AX で変えられなかった(アクセス拒否)。2 枚並べるときは「ウインドウ」→「移動とサイズ変更」→「左と右」。
- 画面を撮るときは実蔵書・ホームの中身を写さない(ホームを開いたときは三角の列だけを切り出して確かめた)。

- 右クリック(フォルダ / ファイル / 空きスペース)の全項目(要望の一覧どおり。1 件用の項目は複数選択中に淡色)。「開く」の 4 種と「コレクションを作成/登録」
  「メタデータを編集」「本を書き出す」は段階 8 で接続(それまでは無効で置く ―― **項目数を状態で変えない**)。
- キー: ⌘C / ⌘X / ⌘V / ⌥⌘V / ⌘A / ⌘⌫(ゴミ箱)/ ⇧⌘N(新規フォルダ)/ Return(開く)/ ⌘↑(上へ)/ ⌘[ と ⌘] (戻る/進む)/ Space は無し。
  `NSTableView`/`NSOutlineView` はレスポンダチェーンの `copy:`/`cut:`/`paste:`/`delete:`/`selectAll:` を実装 → **標準の編集メニューがそのまま効く**。
  アイコン表示は `FileBrowserIconView` を包む `NSView`(`FileBrowserKeyResponder`)が同じセレクタを受ける。type-select(1 秒でリセット、2 文字以上は先頭から)。
- ペーストボード: ⌘C = `writeObjects(urls as [NSURL])`、⌘X = 同じ + `FileBrowserState.cutPaths`(**`Set<String>`**。`standardizedFileURL.path`)+ 淡色表示、
  ⌘V = 一致すれば移動、違えばコピー。Finder からのペースト(sandbox で触れるか)は**段階 4 の最初に Debug で 1 回測る**。触れなければ「ペースト」を
  外部由来の URL では無効にする。
- D&D: アプリ内(同一ボリューム = 移動、別 = コピー、⌥ で反転。修飾キーは `draggingSourceOperationMask` / ドロップの瞬間の `NSEvent.modifierFlags`)、
  外へ(`NSPasteboardWriting` の `NSURL`。`.outsideApplication` は `.copy`)、外から(環境設定: ビューアで開く / コピー・移動)。
  ツリーの行・リストのフォルダ行・パスバーの項目・空きスペースへ落とせる。パッケージには落とさせない。混在は `CompositeCommand`。
- Undo/Redo: `CommandGroup(replacing: .undoRedo)` に自前の 2 項目(題は `FocusedValue` の `FileCommandStack` から。ファイルブラウザが無いときは無効)。
  テキスト欄がファーストレスポンダ(`NSApp.keyWindow?.firstResponder is NSText`)なら `NSApp.sendAction(Selector(("undo:")), ...)` へ流す。
  ⌘Z / ⇧⌘Z は `.keyboardShortcut`。
- インラインリネーム(リスト = `NSTableView` 標準、アイコン = `SelectAllTextField` をセルへ差し替え)→ `RenameCommand`。名前の検証は `FileNameValidation`。
- 新規フォルダ → `CreateFolderCommand` → 選択してリネーム開始。
- ゴミ箱: `TrashAvailability` を `FileIO` で見て、無ければ「この項目はすぐに削除されます。この操作は取り消せません。」の確認 → `deletePermanently`。
- 進捗の帯(`FileBrowserProgressBar`、パスバーの上): 「12 件中 3 件目 — 1.49 GB / 4.29 GB — 残り約 2 分」+ 中止。残り時間はバイトが動き始めてからの平均速度、
  計測 1 秒未満・総量不明なら出さない。**エラーを見せる前に帯を片付ける**。同時に走る操作は 1 本(次は待つ)。
- 「戻せなかった」「一部失敗」: `showToast` 相当の帯の下の 1 行 + 詳細はアラート(件数と理由。`UserPresentableError` の 3 要素: 何が/なぜ/次に何ができるか)。
- テスト: `FileBrowserPasteboardTests`(cut の判定は path で)、`DropOperationTests`(同一/別ボリューム/⌥ の表)、`FileCommandStackTests` の追加。
  実機: 各操作 1 回ずつ使い捨てボリュームで。SMB が手元に無い場合は「ゴミ箱の無いボリューム」の経路を `TrashAvailability` の注入で確認。

### 4.10 引き継ぎ(アイコン表示の名前の変更と type-select の完了時点、2026-09-14)

**ブランチの状態**: `feature/file-browser` にコミット・プッシュ済みで作業ツリーはきれい。全 1434 テスト、CI と同じ
`-configuration Release QOO_CI_WARNINGS_AS_ERRORS=YES` のビルド、`scripts/ci/check-all.sh` が通る。CHANGELOG `[Unreleased]`・MANUAL・
README・docs/15・docs/12 はここまでの内容に揃っている。`MARKETING_VERSION` は触っていない。

**ここまでに入ったもの**: §4.9 の一式に加えて、アイコン表示の名前の変更(`FileBrowserIconNameEditor`)と type-select
(`FileBrowserState.typeSelect`)、名前の編集の依頼を済んだら下ろす修正(`finishRenameRequest`。表示形式の切り替えで古い依頼を拾い直さない)。
実機で確かめた範囲は §4 冒頭の「アイコン表示の名前の変更と type-select」。

**次に着手する候補(順番はユーザーに選んでもらう ―― 今回は「アイコン表示のリネーム」が選ばれた)**:
1. 「置き換える」+ 退避の復旧記録(qooLibrary の `ReplaceBackupJournal`)、ロックされた項目の削除の確認
2. Finder からのペーストをサンドボックスで実測、`untitledFolderName` の 2 つ目以降を実機の Finder と突き合わせ
   (qooViewer は「名称未設定フォルダ 2」を作る。実機で見た)
3. ユーザー要望の「現在のフォルダまでツリーを自動で展開する」設定(§3.9 の要望。まだ入っていない)
4. 段階 5(一括リネーム)以降。段階 8.5 の読み取り専用モードは**書く操作が出揃ってから**(決定事項 Q12)

**ユーザーに頼むこと**: §4.9 のもの(Dock のゴミ箱へのドラッグ、ファイル選択ダイアログ・TCC、効果音、SMB への書き込み)は変わらず残っている。
加えて、アイコン表示の名前の再クリックを**実際のマウスで**何度か試してもらう(下の「気づいているが直していないもの」の 1 件目)。

**気づいているが直していないもの**(§4.9 の 3 件に加えて):
- 合成したクリックを 1 秒未満の間隔で続けたとき、アイコン表示のタップが 1 回拾われないことが 1 度あった。1.5 秒間隔では 12 回とも拾われ、
  再現できていない。人の操作で起きるかは未確認。
- 名前の部分かどうかは「アイコンの枠より下」で判定している(名前の文字の横の余白をクリックしても始まる。Finder は文字の上だけ)。
- 編集欄の外をクリックして確定したとき、クリックした場所が余白でも選択は外れない(確定した項目が選ばれたまま)。
- 日本語入力の変換中の Return は変換の確定に使われ、名前は確定しない(OS の通常の動作。2 回目の Return で確定)。

**このブランチで分かった罠(コードのコメントと docs/15 にもある)**(§4.9 のものに加えて):
- SwiftUI の `.onKeyPress` は、AppKit のファーストレスポンダが子の `NSTextField`(フィールドエディタ)になっていても、SwiftUI の焦点が
  祖先に残っていれば**先にキーを取る**。編集中は `.ignored` を返し、`@FocusState` も外す。
- `NSViewRepresentable.makeNSView` の直後の `DispatchQueue.main.async` では、まだウインドウに入っていないことがある
  → `viewDidMoveToWindow` で焦点を置く。
- ジェスチャーの閉包の中の `NSApp.currentEvent` はマウスのイベントではない(`clickCount` が 0)。
- 子の `NSView` でクリックを受けたいときは、祖先のジェスチャーを `including: .subviews` にする。

**実機検証の手順で足したこと(docs/12「ファイルブラウザ」に追記済み)**: クリック・キーを送る前に毎回 qooViewer が最前面かを
確かめる(起動直後に送ったクリックが別のアプリへ入った)。`cliclick t:` は日本語配列で打てない。`keystroke` の前に英数キー(`key code 102`)。
欄の中の ⌘C は**利用者のクリップボードを上書きする**ので、試すなら先に中身を控える。

### 4.11 引き継ぎ(「置き換える」と退避の復旧記録・ロックされた項目の確認の完了時点、2026-09-14)

**ブランチの状態**: `feature/file-browser` にコミット・プッシュ済みで作業ツリーはきれい。Debug の全テスト(1142 件)、CI と同じ
`-configuration Release QOO_CI_WARNINGS_AS_ERRORS=YES` のビルド、`scripts/ci/check-all.sh` が通る。CHANGELOG `[Unreleased]`・MANUAL・
README・CLAUDE.md・docs/15・docs/12 はここまでの内容に揃っている。`MARKETING_VERSION` は触っていない。

**ここまでに入ったもの**: §4 冒頭の「「置き換える」+ 退避の復旧記録、ロックされた項目の確認」。置き場所は
`Services/FileOperations/ReplaceBackupJournal.swift` / `ReplaceBackupRecovery.swift`、エンジンは `FileOperationService`
(`checkConflict` が記録してから退避、`carry` / `restoreReplacedItem` が片付けたら消す。`trash` / `deletePermanently` の `unlockingLocked`、
`isLocked` / `setLocked` / `lockedItems(atOrUnder:)` はリンクを辿らない lstat / lchflags)、確認は `FileBrowserOperationPresenting` の
`confirmLockedItems` と `resolveConflict(_:replacingDeletesImmediately:cancellation:)`。`TemporaryDirectory` は片付ける前にロックを外す。

**次に着手する候補(順番はユーザーに選んでもらう)**:
1. Finder からのペーストをサンドボックスで実測、`untitledFolderName` の 2 つ目以降を実機の Finder と突き合わせ
2. ユーザー要望の「現在のフォルダまでツリーを自動で展開する」設定(§3.9)
3. 段階 5(一括リネーム)以降。段階 8.5 の読み取り専用モードは書く操作が出揃ってから(Q12)

**ユーザーに頼むこと**: §4.9・§4.10 のものに加えて、書ける SMB 共有があれば「置き換える」(確認の文とすぐに消えること)と
ロックされた項目の完全削除。

**気づいているが直していないもの**(§4.9・§4.10 に加えて):
- ロックされた項目の**移動・名前の変更**は OS が EPERM で断るまま「権限がありません」になる(確認して外す経路は無い)。
- ゴミ箱の無い場所で、中にロックされた項目があるフォルダを**置き換える**と、退避の完全削除が途中で止まりうる(記録は残り、次の起動で
  「元の場所に同じ名前がある」と警告される)。置き換えの前にロックを見る確認は入れていない。
- ロックされた項目の確認は「続ける / 中止」の 2 択で、ロックされていない項目だけを送る選択肢は無い。
- 起動時の復旧は、退避のあるフォルダの許可(`FolderAccessStore`)が取り消されていると戻せない(警告し、記録を残す)。

**分かった罠**:
- `NSWorkspace.recycle` にロックされたファイルを渡すと、Finder のように尋ねず 513「ゴミ箱に入れるアクセス権がありません」で失敗する。
  中にロックされた項目があるフォルダは通る(移動は親のフォルダの rename なので)。
- 検証のプローブが本物のゴミ箱へ入れてしまうことがある(`NSWorkspace.recycle` を合成ファイルで試したらフォルダが `~/.Trash` へ入った。
  中身を確かめてロックを外して消した)。ゴミ箱に触るプローブは使い捨てボリュームの上で走らせる(そのボリュームの `.Trashes` に入る)。
- 使い捨てボリュームの `.Trashes` はシェルから読めない(Permission denied)。ゴミ箱の中の状態は ⌘Z の結果で見る。
- 起動時の復旧の実機確認は、Debug のコンテナの `Application Support/FileOperations/replace-backups.json` に記録を手で書き、
  使い捨てボリュームに `.qooViewer-replace-<任意>/<名前>` を作って起動すればよい(終わったら記録のフォルダごと消す ―― 残すと、外した
  ボリュームを次の起動で探して警告が出る)。

### 4.12 引き継ぎ(Finder からのペーストの実測・新規フォルダの番号の突き合わせの完了時点、2026-09-14)

**ブランチの状態**: `feature/file-browser` にコミット・プッシュ済みで作業ツリーはきれい。アプリの動作は変えておらず、コードの変更はコメントとテストだけ
(`FileBrowserOperations.paste` の型コメント、`FileNameValidation.untitledFolderName` の Note、`FileNameValidationTests.untitledFolderNameMatchesFinder`)。
`FileNameValidationTests`(9 件)と `scripts/ci/check-all.sh` が通る(全テストはこの変更では回していない ―― 直前の §4.11 の時点で全件通過)。
docs/15・docs/12・検討メモの表に実測結果を、MANUAL「ファイルの操作」と CHANGELOG `[Unreleased]` に「他のアプリでコピーした項目も貼れる/
許可の無い場所からの ⌥⌘V は取り消せない」を書いた。README の機能一覧は変わらないので触っていない。`MARKETING_VERSION` は触っていない。

**Finder からのペースト(実測)**: 素の `build` の Debug(テスト用の読み取り例外なし)で、Debug の defaults の許可を外して起動し、
`sandbox_check` で「使い捨てボリュームのファイルは拒否・宛先(コンテナの tmp)は許可」を確かめてから測った。宛先は表示中のフォルダ = コンテナの `tmp/` の中。
- Finder で ⌘C したファイル → ⌘V: コピーされる。貼った後はその項目だけ許可になり、同じボリュームの別のファイル・親フォルダは拒否のまま。
- 対照: 拡張を添えず `NSPasteboardItem.setString(_, forType: .fileURL)` だけで置いた URL(同じボリュームと `/private/tmp`)も貼れた → 許可を付けるのはペーストボードの側。
- Finder で ⌘C したファイル → ⌥⌘V: 移動できる(元が消える)。⌘Z は「「XPasteSrc」に書き込むアクセス権がありません」のシートで失敗し、項目は宛先に残り、履歴から消える。
- フォルダ(中身あり)の ⌘V・⌥⌘V: どちらも中身ごと運べる。
- 結論: 計画 §4 の「触れなければペーストを外部由来の URL では無効にする」は不要。

**新規フォルダの番号(実機の Finder、macOS 26.6、日本語)**: 空 → 3 回で「名称未設定フォルダ」「… 2」「… 3」、`2` を消して作ると `2`、`2` だけあると番号なし、
同じ名前の**ファイル**があると `2`、`… 2 2` があっても `2`、`… 1` があっても `2`。qooViewer の `nextAvailableName` と全部同じだったので、コードは変えずにテストへ固定した。

**次に着手する候補(順番はユーザーに選んでもらう)**:
1. ユーザー要望の「現在のフォルダまでツリーを自動で展開する」設定(§3.9)
2. 外から来た項目の ⌥⌘V を取り消せない件への対応(下の 1 件目。直すかどうかから決めてもらう)
3. 段階 5(一括リネーム)以降。段階 8.5 の読み取り専用モードは書く操作が出揃ってから(Q12)

**気づいているが直していないもの**(§4.9〜§4.11 に加えて):
- 外から来た項目(許可の無い場所)を ⌥⌘V で移動すると取り消せない。事前に分かる手がかりはある(`access(親, W_OK)` はサンドボックスの判定を返し、
  実測で許可の有無と一致した)ので、「取り消せません」と確認する・移動をコピーに落とす、などは作れる。
- 取り消しに失敗したコマンドは履歴から消える(やり直しにも残らない)。Finder と比べてはいない。

**分かった罠**: docs/12「ファイルブラウザ」の最後の項目(テスト用の app の読み取り例外と、Debug の defaults に残る `/` の許可)。
実測ではクリップボードの元の内容を控えてから Finder で ⌘C する。元の内容が**実在しないファイルの URL** だと、書き戻してもペーストボードに残らない。

---

## 段階 5. 一括リネーム

- `Models/BulkRename.swift`(純粋関数): `Mode { replaceText(find, replaceWith), addText(text, placement), format(style: index|counter|date, custom, placement, start) }`、
  `plan(names: [String], mode:) -> [Rename]`、`markingConflicts(_:existing:)`(新名どうし / 既存 / `FileNameValidation`。大小文字を畳む)、`requiresTwoPass`。
  カウンタは 5 桁ゼロ埋め、インデックスは素の数、日付は実行時刻(書式は**実機の Finder の出力を写す**)、追加は空白を入れない、置換は拡張子を含む名前全体。
- `BulkRenameCommand`: 2 パスは `<UUID>.qooViewer-rename-tmp` へ逃がす。第 1・第 2 パスどちらの失敗でも戻す(第 2 は `.keepBoth`)。**連番は表示順**。
- `Views/FileBrowser/BulkRenamePanel.swift`(AppKit、`NSPanel` + Auto Layout): Finder の nib と同じ部品・同じ文言(検討メモ §8 の表)。寸法は**この機の Finder の
  シートを `screencapture` して 1 ピクセル単位で合わせる**(合成名のファイルで Finder を開く)。前回の設定を `qooViewer.fileBrowser.bulkRename.*` に保存。
  例の行は先頭の項目で更新。衝突があれば「名称変更」を無効にし、赤字の理由。
- 入り口: 右クリック「名前を変更」で複数選択のときと、⌘R(Finder は Return が 1 件のリネーム、複数選択の Return が一括)。
- テスト: `BulkRenameTests`(Finder の既知の出力を固定: `File 1`〜、`00001`、置換で拡張子が変わる、衝突、2 パス)。

---

## 段階 6. 圧縮・展開

- `Services/FileOperations/ZipCompressor.swift`: ZIPFoundation。同じフォルダの `.qooViewer-compress-<UUID>.zip` に `.create` → `replaceItemAt`/`moveItem`。
  エントリ名は NFC(`nfcNormalizedForExport`)、画像・書庫・PDF・EPUB は `.none`、他は `.deflate`、`bufferSize` 1MiB、隠しファイルと `._*` は除外、
  出力名は 1 件ならその名前・複数ならカレントフォルダ名、拡張子は環境設定、衝突は `name 2.zip`。空き容量の事前検査。進捗は 1/30 秒に間引き、中止は `progress.cancel()`。
  `Archive` は detached task の中だけ。
- `Services/FileOperations/ArchiveExtractor.swift`: 既存の `makeArchiveReader` + `EntryNameDecoder`(zip)。書き込みは同じフォルダの `.qooViewer-extract-<UUID>/` へ
  全部出してから項目ごとに `renamex_np(RENAME_EXCL)`(衝突は `name 2`)、中止で一時フォルダごと削除。安全策: `EntryPathValidation`(絶対 / `..`(`/` と `\`)/ NUL・制御 /
  記号リンク / 特殊 / 実体解決後の脱出 / `__MACOSX` と `._*` / 大小文字衝突 → `name 2`)、宣言サイズの飽和加算、非圧縮 20GB・10 万件・圧縮比 1,000 倍、
  展開先の空き容量、**`FileHandle.write(contentsOf:)`**。7z は書庫順(フォークの `read(entry:chunkSize:)`)、rar は `extract(_:handler:)`。
  暗号化・分割は「対応していません」と伝える。
- メニュー: 「圧縮」サブメニュー(ここに圧縮 / 圧縮…)、「展開」サブメニュー(ここに展開 / 〈名前〉に展開 / 展開…)。対応形式以外は淡色。
- テスト: `ZipCompressorTests`(NFC・bit 11・`.none` 判定・衝突名・中止で残骸なし)、`ArchiveExtractorTests`(Zip Slip 各種を `ZipFixtureBuilder` で作る、
  飽和加算、`__MACOSX`、大小文字衝突、ディスクフルは `DisposableVolume` 4MB で **SIGABRT にならず失敗すること**、CP932 名の zip)。

---

## 段階 7. サムネイル

- `Services/FileBrowserThumbnails/ThumbnailCache.swift`(actor): Caches の `FileBrowserThumbnails/<volumeUUID>-<inode>-<mtime>-<size>.jpg`(JPEG 0.8、長辺 512)、
  上限は環境設定(既定 200MB、古い順に刈る、リソースモニタに出す、「キャッシュ」画面から削除)。メモリは `PagePixelCache` 型の LRU 96MB。同時生成 4、表示が背景より優先。
- `BookThumbnailer`: ① `CollectionStore` に登録済みで `CollectionCovers/<itemID>.jpg` があればそれ ② 安い先頭画像(zip = 中央ディレクトリから正準順の先頭画像 1 件、
  rar/7z = 書庫順の先頭画像、PDF = 1 ページ目、EPUB = spine 先頭、画像フォルダ = 正準順の先頭。`isAppleDoubleEntry` 除外)。**`BookLoader.load` は使わない**。
- `VideoThumbnailer`: `QLThumbnailGenerator`(`.thumbnail`、8 秒で `cancel`、成功時にタイムアウト側を起こす)+ `MediaContainerSniffer`(16 バイト、`contentType`)+
  `MatroskaDimensionReader`(8MB、要求サイズの補正)+ `RetaggedHEVCThumbnailLoader`(`hev1`)。環境設定で OFF にできる。
- `BackgroundThumbnailWarmer`: よく使う項目の配下の動画だけ、逐次 1 本、`.background`、2 秒デバウンス、同じ拡張子が 3 回失敗したらそのセッションは飛ばす(永続化しない)、
  ネットワークと dataless は対象外。
- 画像ファイルは `ImageDecoder` の縮小デコード。その他は `NSWorkspace.icon(forFile:)`(リモートは非同期)。
- テスト: `ThumbnailCacheTests`(鍵・上限・無効化)、`BookThumbnailerTests`(各形式のフィクスチャで先頭画像の番号を `PageColorReader` で確認)、
  `MatroskaDimensionReaderTests`(手組み EBML)、`MediaContainerSnifferTests`。実機: QLMedia で mkv、`hev1` の mp4、`.mp4` を名乗る mkv。

---

## 段階 8. 既存機能との接続

- 右クリックの「コレクションを作成 / 登録」: `WelcomeLibraryState.pendingCreations` / `addingBooks`(モードを `.shelf` に戻して名前入力シート)。
  判定 `ShelfFolderResolver.role` は一覧の読み込み時に `isBook` として確定。
- 「メタデータを編集」: `BookMetadataSheet` に URL 版の入り口(`init(sourceURL:)`。表紙の面は出さない)。
- 「本を書き出す」: `BookLoader.load` → `OpenBookExportSheet`(`BookLoadingOverlay` で進捗、`displayState` は既定)。
- 「このアプリケーションで開く」: `urlsForApplications(toOpen:)`(bundle id で畳む、既定を先頭、「その他…」= `/Applications` の `NSOpenPanel`)。
- **「ファイルブラウザで開く」を 11 箇所へ**(既存の「Finder で表示」の隣): `QooViewerApp:672`、`SidePanelView:555/761/1089/1444/1724`、`PageContextMenuItems:47`、
  `SidePanelLibraryTreeSection:210`、`ViewerView:2387`、`RecentBooksPopover`(段階 1 で削除)、`CollectionDetailView:526`。実体は `AppState.revealInFileBrowser(url)`:
  本を開いていなければこのウインドウで(`mode = .browser` + `reveal`)、開いていれば `AppPreferences.fileBrowserRevealDestination` に従って
  `BookWindowOpener.open(.browse(parent), to:)` + 受け取った側で `reveal(url)`。
- docs/09 の「一覧ウインドウの共通の形」には該当しない(補助ウインドウではない)が、右クリック項目の並びは `BookOpenContextMenuItems` と揃える。

---

## 段階 8.5. 読み取り専用モード(決定事項 Q12)

段階 4〜8 の書く操作が出揃ってから入れる(先に入れると、各段階の実機検証のたびに OFF にする手間が増えるため)。

- `AppPreferences.fileBrowserReadOnly`(キー `qooViewer.pref.fileBrowser.readOnly`、**既定 true**)と環境設定「ファイルブラウザ」の行。
  `keys(for: .fileBrowser)`・`resetToDefaults`・`AppPreferencesTests.paneSettings`・`mutateEverySetting` を揃える。
  既存の利用者も初回は ON で始まる(段階 4 の書く操作を使っていた人には CHANGELOG で知らせる)。
- ON の間に**できなくする**もの: コピー後のペースト・カット・⌥⌘V・ゴミ箱/完全削除・名前の変更(インライン含む)・新規フォルダ・
  一括リネーム・圧縮・展開・ファイルを動かす D&D(アプリ内・外から)・取り消し/やり直し(ファイル操作)。
  **できるまま**のもの: 閲覧・開く・新規タブ/ウインドウで開く・Finder で表示・このアプリケーションで開く・よく使う項目の登録/解除・
  コレクションの作成/登録・メタデータの編集・本の書き出し(qooViewer の保存データや書き出し先であって、表示中のファイルを変えない)・
  ⌘C(ペーストボードへ載せるだけ)・アプリ外への D&D(元を変えない)・外からのドロップの「ビューアで開く」。
- 窓口は `FileBrowserOperations` の 1 箇所で断る(メニュー・キー・D&D の経路ごとに判定を散らさない)。メニュー項目は**消さずに淡色**
  (項目の数を変えない)。ファイルメニューの「新規フォルダ」・編集メニューの取り消し/やり直しも淡色。インラインリネームは始めない。
- 途中で ON にしたとき、走っている操作は止めない(次の操作から効く)。取り消しの履歴は残すが、ON の間は使えない。
- テスト: ON で各書く操作が何もしない(ファイルが変わらない)こと、OFF で従来どおり、読むだけの操作は ON でも効くこと。

## 段階 9. 検証と文書

- 実機検証は**使い捨てボリューム**(`hdiutil`)+ 合成名。手順を docs/12 に「ファイルブラウザ」の節として書く(TCC の確認手順、`tccutil reset`、
  スクリーンショットは実蔵書を写さない)。
- リーク: ウインドウを開閉して `heap` で `FileBrowserState` / `NSOutlineView` / `NSTableView` の残留が増えないこと(`dismantleNSView`)。
- すりガラス 2 条件(ダーク+白 100% / ライト+黒 100%)で全部品。
- 文書: docs/15(新規「ファイルブラウザ」: 構成・操作エンジン・Undo・圧縮展開・サムネイル・sandbox/TCC の約束)、docs/03(ウインドウごとのものに `FileBrowserState`、
  提示値 `WindowContentRequest`)、docs/06(保存先の一覧に追加)、docs/09(ウェルカム画面の節)、docs/10(TCC の節)、docs/13(経緯)、docs/README の表、
  CLAUDE.md(アーキテクチャの段落)、MANUAL、CHANGELOG `[Unreleased]`、README の機能一覧。**MARKETING_VERSION は触らない**(指示があるまで)。

---

## 触るファイル(見積り)

新規: `Services/FileOperations/`(8)、`ViewModels/FileCommands/`(10)、`ViewModels/FileBrowserState.swift`、`ViewModels/FavoriteLocationStore.swift`、
`Views/FileBrowser/`(12)、`Views/FileBrowserSettingsView.swift`、`Models/{FileNameValidation,BulkRename,GridKeyboardNavigation,WindowContentRequest,FileBrowserPreferences}.swift`、
`Services/FileBrowserThumbnails/`(7)、テスト 15 ファイル、`qooViewerTests/Support/DisposableVolume.swift`。
変更: `QooViewerApp`(WindowGroup の提示値・メニュー)、`ContentView`、`AppState`、`BookWindowOpener`、`LaunchCoordinator`、`WelcomeTopBar`、`WelcomeView`、
`WelcomeLibraryState`、`SettingsPane`、`AppPreferences`、`GeneralSettingsView`、`PageOrder`/`EffectivePageOrder`/`CoverImageResolver`/`CollectionCoverExtractor`/
`LayoutStore`、`BookLocationResolver`(`MountTable` へ)、「Finder で表示」の 11 箇所、`Localizable.xcstrings`(ビルドで書き戻る差分はそのままコミット)。

合計の見積り: 約 10,000 行(テスト約 3,000 行を含む)。
