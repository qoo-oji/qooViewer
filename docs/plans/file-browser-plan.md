# 改善要望7 実装計画 ―― ウェルカム画面のファイルブラウザモードと環境設定の整理(引き継ぎ資料)

立案日: 2026-09-13 / ブランチ: `feature/file-browser` / 検討メモ: [file-browser-study.md](file-browser-study.md)(決定事項は同 §11)

段階は §11 の決定を反映して 0 → 9 の順。段階 0・1・2 は済み。各段階は単独でビルド・テストが通り、
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

---

## 段階 4. 書く操作の UI

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
