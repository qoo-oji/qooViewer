# 改善要望7 実装計画 ―― ウェルカム画面のファイルブラウザモードと環境設定の整理(引き継ぎ資料)

立案日: 2026-09-13 / ブランチ: `feature/file-browser` / 検討メモ: [file-browser-study.md](file-browser-study.md)(決定事項は同 §11)

段階は §11 の決定を反映して 0 → 9 の順(Q12 の読み取り専用モードは段階 8.5)。段階 0・1・2・3 は済み(段階 3 の結果と引き継ぎは §3.8・§3.9)。段階 5(一括リネーム)は済み(引き継ぎは §5.1)。段階 6(圧縮・展開)は実装・自動テスト済み(引き継ぎは §6.1。実機の確認が残り)。段階 7 は 7a(本・画像・画像フォルダの絵とキャッシュ)・7b(動画の絵とよく使う項目の配下の事前生成)まで実装・自動テスト・実機確認済み(引き継ぎは §7.2、7a のものは §7.1)。段階 8(既存機能との接続)は実装・自動テスト・実機確認済み(引き継ぎは §8.1、実機検証の結果は §8.2)。段階 8.5(読み取り専用モード)は実装・自動テスト・実機確認済み(引き継ぎは §8.5.3・§8.5.2・§8.5.1、そのあとのコード監査は §8.5.4)。段階 9(検証と文書)は文書化まで済み(**次の人への引き継ぎは §9.1**。実機の検証が残り)。段階 4 は 4a と 4b の D&D・アイコン表示の名前の変更と type-select・「置き換える」と退避の復旧記録・ロックされた項目の確認まで実装(§4 冒頭。**次の人への引き継ぎは §4.15**、その前のものは §4.14・§4.13・§4.12・§4.11・§4.10・§4.9)。各段階は単独でビルド・テストが通り、
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
- **ユーザー要望(2026-09-13、段階 4 以降のどこかで入れる。→ 2026-09-14 済、§4.13)**: 環境設定「ファイルブラウザ」に**「現在のフォルダまでツリーを自動で展開する」**
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
- **「現在のフォルダまでツリーを自動で展開する」設定(2026-09-14、実装・実機検証済み。§4.13、説明は docs/15「現在のフォルダまでツリーを開く」)**。
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
4. ~~ユーザー要望の「現在のフォルダまでツリーを自動で展開する」設定~~(2026-09-14 済。§4.13)
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

### 4.13 引き継ぎ(「現在のフォルダまでツリーを自動で展開する」の完了時点、2026-09-14)

**ブランチの状態**: `feature/file-browser` にコミット・プッシュ済みで作業ツリーはきれい。§3.9 のユーザー要望を実装した。
Debug の全テスト(1149 件)、CI と同じ `-configuration Release QOO_CI_WARNINGS_AS_ERRORS=YES` のビルド、`scripts/ci/check-all.sh` が通る。
CHANGELOG `[Unreleased]`(環境設定「ファイルブラウザ」の項目)・MANUAL(左のツリーの説明と環境設定の表)・README(機能一覧)・docs/15 はここまでの内容に揃っている。
CLAUDE.md は構成が変わらないので触っていない。`MARKETING_VERSION` は触っていない。

**入ったもの**: `AppPreferences.fileBrowserExpandsTreeToCurrentFolder`(`qooViewer.pref.fileBrowser.expandsTreeToCurrentFolder`、既定 false。
`keys(for: .fileBrowser)`・`apply`・`AppPreferencesTests.paneSettings`・`mutateEverySetting` を揃えた)、環境設定の「ツリー」の節、道筋の純粋関数
`Models/FileBrowserTreePath.swift` と `FileBrowserTreePathTests`(6 件)、`FileBrowserTreeView.Coordinator` の `reveal` / `expandedChildren` /
`startPendingRevealIfReady`(`Node.childrenTask` を待つ)、文言 3 件。

**実機で確かめたこと(Debug・空の本棚・使い捨て APFS 1 本に合成名、フォルダ 120 個+4 階層)**: 起動時のフォルダが 3 階層下のとき、ボリューム → 1 → 2 と開いて
3 が選ばれる(ボリュームの一覧の読み込みを待って始まる)、ツリーより行が多いときに選んだ行が見える位置へスクロールする、リストのダブルクリックで
1 段下へ移ると 3 が開いて 4 が選ばれる、パスバーでボリュームへ戻るとツリーが上へスクロールしてボリュームの行が選ばれる、環境設定の行の見た目。
後始末で defaults・ストア・表紙の保管庫が控えと一致。

**確かめていないもの**: 設定を途中で ON/OFF したとき、速い移動の途中でやめること(世代番号)、よく使う項目とホームの配下、TCC の保護下の場所
(デスクトップなど。右ペインが読めた後にしか開かないので新しいダイアログは出ない見込み)、ネットワークボリューム、すりガラス 2 条件(ツリーの既存の部品しか使っていない)。

**次に着手する候補(順番はユーザーに選んでもらう ―― 今回は「ツリーの自動展開」が選ばれた)**:
1. 外から来た項目の ⌥⌘V を取り消せない件への対応(§4.12。直すかどうかから決めてもらう)
2. 段階 5(一括リネーム)以降。段階 8.5 の読み取り専用モードは書く操作が出揃ってから(Q12)

**ユーザーに頼むこと**: §4.9〜§4.11 のもの(Dock のゴミ箱へのドラッグ、ファイル選択ダイアログ・TCC、効果音、SMB への書き込み、アイコン表示の名前の再クリック)に加えて、
ふだんの蔵書のフォルダでこの設定を ON にして使ってもらい、深い階層・よく使う項目の配下・デスクトップなどで開き方に違和感が無いか見てもらう
(自動の検証は合成名のボリュームだけで、実蔵書は画面に出さないため)。

**気づいているが直していないもの**(§4.9〜§4.12 に加えて):
- 道筋が隠しフォルダなどで切れたとき、開いた途中の行はそのまま残る(選択は外れる)。
- 自動で開いた行はたたまないので、あちこち移動するとツリーが長くなる(要望どおり。Finder のサイドバーには相当する機能が無く比べていない)。
- ツリーに出ている行へ移ったときも道筋をたどり直してスクロールする(開いている行は待たずに通るので、見た目は選択とスクロールだけ)。

**分かった罠 / 実機検証の手順で足したこと**:
- 環境設定ウインドウは前回の画面(`qooViewer.settings.selectedPane`)で開く。「フォルダのアクセス権」の画面には許可したフォルダの実名が出るので、
  **撮る前に defaults で見たい画面(`fileBrowser` など)を選んでから** ⌘, で開く(AX で左の一覧を選ぼうとすると要素が取れず手間取った)。
- 禁止語の検査は `/Users/<名前>/` の形も**合成名で**拒否する(ありふれた英単語のユーザー名でも落ちた)。テストのホームは `nobody` など許可された名前
  (`check-private-terms.py` の `PLACEHOLDER_USERS`)にする。
- `NSOutlineView.expandItem` は `outlineViewItemWillExpand` を同期で呼ぶので、開いた直後に `Node.childrenTask` を待てば子の読み込みを取りこぼさない。

### 4.14 引き継ぎ(取り消せない移動の確認の完了時点、2026-09-14)

**ブランチの状態**: `feature/file-browser` にコミット・プッシュ済みで作業ツリーはきれい。§4.12 の「外から来た項目の ⌥⌘V を取り消せない」件を、
ユーザーの選んだ方式(移動の前に確認)で直した。Debug の全テスト(1153 件)、CI と同じ `-configuration Release QOO_CI_WARNINGS_AS_ERRORS=YES` のビルド、
`scripts/ci/check-all.sh` が通る。CHANGELOG `[Unreleased]`(§4.12 の「取り消しても戻せません」を確認の説明に置き換え)・MANUAL(「ファイルの操作」と
ドラッグ&ドロップの外からのドロップ)・README(機能一覧)・docs/15(「書く操作」・段階の表・テストの表)はここまでの内容に揃っている。
CLAUDE.md は構成が変わらないので触っていない。`MARKETING_VERSION` は触っていない。

**入ったもの**: `FileBrowserOperations.transfer` が移動の前に `canPutBack`(元のフォルダへの `access(W_OK)`。読み取り専用のボリュームは尋ねない)で
戻せない項目を集め、あれば `FileBrowserOperationPresenting.confirmIrreversibleMove(of:totalCount:)` で「移動(既定)/ コピー / 中止」を尋ねる。
「移動」は `MoveFilesCommand(isUndoable: false)` で積まない(混ざった 1 回の操作ごと)、「コピー」は戻せない項目だけコピーに変える。
⌥⌘V・カットのペースト・D&D(外からのドロップの「コピー・移動」を含む)の全部が同じ経路を通る。テストは `FileBrowserOperationsTests` に 4 件
(`canPutBack` を差し替えて確かめる)、文言 4 件(日本語入り)。

**実機で確かめたこと(2026-09-14、scratchpad へ素の `build` をした Debug・空の本棚・許可を外した defaults・使い捨て APFS 1 本に合成名)**:
`sandbox_check` でボリュームのファイルと親が拒否・宛先(コンテナの `tmp/`)が許可であることを確かめ、Finder で ⌘C したファイルを ⌥⌘V。
シートに「「…」の移動は取り消せません。」と説明の文、ボタンが縦に同じ幅で「移動(既定)/ コピー / 中止」と出る。「中止」→ 何も変わらず編集メニューの
取り消しも無効のまま、「コピー」→ 元が残り「「…」のコピーを取り消す」になる、「移動」→ 元が消え、取り消しの題は前の操作のまま。
コピーの取り消しは起動ボリュームのゴミ箱(実物の `~/.Trash`)へ入るので試していない(テストで確かめてある)。後始末で defaults・ストア・表紙の保管庫が控えと一致。

**確かめていないもの**: 複数項目の文面(戻せる項目と混ざったとき)、外からのドロップでの確認、フォルダの ⌥⌘V。

**気づいているが直していないもの**:
- POSIX の権限で元のフォルダへ書けない(サンドボックスではない)場合も尋ね、「移動」を選ぶと移動そのものが「権限がありません」で失敗する。
- 積まない移動は、前の操作の受領書を古いままにする。前の操作が作った場所へ同じ名前で移動してくると(実機検証では前のコピーをシェルで消してから
  同じファイルを移動した)、⌘Z が前の操作のつもりで**移動してきた項目を**ゴミ箱へ送りうる。受領書をパスで持つ設計全体の話(外での変更と同じ)。
- 移動の途中で衝突の確認から「中止」したとき、`CompositeFileCommand` の巻き戻しは戻せない移動を戻そうとして黙って失敗する(項目は宛先に残る)。

**次に着手する候補(順番はユーザーに選んでもらう ―― 今回は「⌥⌘V の取り消し不可への対応」が選ばれ、方式は「移動前に確認」)**:
1. 段階 5(一括リネーム)
2. 段階 6(圧縮・展開)
3. 段階 8(既存機能との接続)。段階 7(サムネイル)も未着手。段階 8.5 の読み取り専用モードは書く操作が出揃ってから(Q12)

**ユーザーに頼むこと**: §4.9〜§4.13 のもの(Dock のゴミ箱へのドラッグ、ファイル選択ダイアログ・TCC、効果音、SMB への書き込み、アイコン表示の名前の再クリック、
ツリーの自動展開をふだんのフォルダで)。加えて、Finder から許可の無い場所の項目を**ドラッグして**「コピー・移動」設定で落としたときに確認が出るか
(自動の検証は ⌥⌘V だけ)。

**分かった罠 / 実機検証の手順で足したこと**:
- 起動ボリューム(コンテナの `tmp/`)へ貼ったものの取り消しは、実物の `~/.Trash` へ入る。コピーの取り消しを実機で試すなら宛先も使い捨てボリュームにする
  (ただしそのボリュームへの許可が要り、「許可の無い元」と両立させるにはボリュームを 2 本付けて片方だけ許可する)。
- クリップボードの控えは、全項目の全型のバイト列を plist に書く小さな Swift のプログラムで取って戻した(今回は元が空だった)。

### 4.15 引き継ぎ(ここまでに見つかっていた問題の修正の完了時点、2026-09-14)

**ブランチの状態**: `feature/file-browser` にコミット・プッシュ済みで作業ツリーはきれい。§4.9〜§4.14 の
「気づいているが直していないもの」のうち、ユーザーが選んだ 11 件を直した。Debug の全テスト(1173 件)、CI と同じ
`-configuration Release QOO_CI_WARNINGS_AS_ERRORS=YES` のビルド、`scripts/ci/check-all.sh` が通る。CHANGELOG `[Unreleased]`・MANUAL・README・
docs/15・docs/12 はここまでの内容に揃っている(下の「利用者に見える変化」を書いた)。CLAUDE.md は構成が変わらないので触っていない。`MARKETING_VERSION` は触っていない。

**直したもの**(説明は docs/15「書く操作」「ツリーの三角」「現在のフォルダまでツリーを開く」「クリックとキー」「ドラッグ&ドロップ」):
1. **⌘Z が同じ名前の別の項目を捨てうる**(§4.14): 受領書に `FileIdentity`(デバイス番号 + inode + 作成日時)を持たせ、移動・コピー・名前の変更・
   新規フォルダの取り消しは直前に一致を確かめる。
2. **中止したまとめた操作の巻き戻しが黙って失敗**(§4.14): 取り消せない子は戻そうとせず `CompositeRollbackError` で報告。あわせて、
   最後の項目の衝突で「中止」を選ぶと「スキップ」扱いになり巻き戻しが走らなかった件もエンジンで直した(`transfer` の最後)。
3. **ロック入りフォルダの置き換え**(§4.11): 退避の前にロックを見て確認し(`replacingIsBlockedByLock`)、許されたら外す。許しの無いまま消すことに
   なった退避は消し始めない。ゴミ箱の無い場所では退避をゴミ箱へ送ろうとしない(`environment.hasTrash` を見る)。
4. **取り消しに失敗すると履歴から消える**(§4.12): `FileUndoResult.impossible(reason:canRetry:)`。試し直せるものは履歴へ戻し、報告に一文を足す。
5. **外での変更がツリーに出ない**(§4.9): 開いている行を `FolderChangeWatcher(onChangedPaths:)` で見張る。共有はアクティブ化で読み直す。
6. **余白クリックで確定したとき選択が残る / 名前の横の余白で編集が始まる**(§4.10): 選び直しは選択が残っているときだけ。名前のクリックは
   `FileBrowserIconView.nameRect`(文字の矩形)。
7. **自動展開が途中で切れたとき開いた行が残る**(§4.13): その展開で開いた行をたたみ直す。
8. **リスト全体へのドロップの強調が薄い**(§4.9): 右ペインのアクセント色の枠を出す(アイコン表示の余白と同じ)。
9. **ロックされた項目の移動・名前の変更**(§4.11): 確認(`LockedItemAction.move` / `.rename`)→ 外して運び、運んだ先で掛け直す。
10. **ロック確認に「ロックされた項目をスキップ」**(§4.11): 一部だけがロックされているとき 3 つ目のボタン。`confirmLockedItems` は
    `(urls, totalCount:, action:) -> LockedItemsDecision` になった(プロトコルの形が変わっている)。
11. **POSIX の権限で書けない元でも「取り消せません」と尋ねる**(§4.14): `posixModeAllowsWrite` で POSIX が断る場合は尋ねない。

**利用者に見える変化**(CHANGELOG・MANUAL・README に書いたもの): ロックされた項目の移動・名前の変更・置き換えで確認が出て、続ければロックを保ったまま
行える/ロックの確認に「ロックされた項目をスキップ」/取り消せなかった操作は、原因を取り除けばもう一度取り消せる/操作のあとで同じ名前の別の項目に
置き換わっていたら、取り消しはそれに触らない/Finder などでのフォルダの作成・削除がツリーにすぐ出る/自動展開で行き着けなかったときは開いた行を
たたむ/アイコン表示の名前は文字の上をクリックしたときだけ編集が始まる・余白をクリックして確定すると選択が外れる/リストの空きへのドラッグで
右ペインに枠が出る。

**実機で確かめたこと(2026-09-14、scratchpad へ素の `build` をした Debug・使い捨て APFS 1 本に合成名)**: 隠しフォルダの下を起動時のフォルダに
すると、ボリュームの行がたたまれた状態に戻る/シェルでの `mkdir`・`rmdir`・別の行への `mv` が 2 秒以内にツリーへ出て、閉じた行に三角が付く/
ロックしたファイルのカット → 別のフォルダへ ⌘V で「「…」はロックされています。移動してもよろしいですか?」(中止 / 続ける)が出て、続けると
移動先でも `uchg`、⌘Z で元の場所へロックごと戻る/アイコン表示で名前を変えて余白をクリックすると選択が外れる(下の注意)、名前の横の余白の
再クリックでは編集が始まらない/⌥ で行をリストの空きへドラッグしている間だけ右ペインに枠が出て、落とすと消える、フォルダの行の上では出ない。
すりガラス 2 条件・`heap` は見ていない(枠は既存のペインの枠と同じ部品)。

**確かめていないもの**: ホームの配下と `/` の下での FSEvents のパス(`/System/Volumes/Data` の頭を外す手当ては推測)、共有のアクティブ化での読み直し、
別ボリュームへのロック入りフォルダの移動の実機(テストはある)、置き換えのロック確認と「ロックされた項目をスキップ」の見た目、
取り消しの「もう一度取り消せます」の文面、名前の変更のロック確認の見た目。

**気づいているが直していないもの**:
- アイコン表示で名前を変えて余白をクリックしたとき、**最初の 1 回だけ選択が外れなかった**。ログを仕込んで同じ手順を 6 回繰り返したが
  毎回外れ(確定 → 余白のクリック → 選択が空)、再現できていない。ログを入れる前の 1 回で何が起きたかは分からない。
- **リストで、選ばれていない行の名前の文字の上からドラッグを始めると、ドラッグにならず名前の編集が始まった**(⌥ 付きの合成したドラッグで 1 回。
  修飾なしの単発クリックでは始まらない)。今回の変更とは関係の無い経路(`FileBrowserTableView.validateProposedFirstResponder`)で、前からあった
  可能性が高い。実際のマウスで起きるかは未確認。
- 「すべてに適用」で「置き換える」を選んだあと、後の衝突の相手がロックされていると、尋ねずに「ロックされています」で止まる(最初の相手の
  確認で「続ける」を選んでいれば以降も外す)。
- §4.9〜§4.14 の残り(Dock のゴミ箱・ウインドウをまたいだドラッグの取り消し先・合成クリックの取りこぼし・名前の欄の Return と日本語入力・
  取り消しの受領書をパスで持つ設計の他の穴(外で名前を変えられた項目は「見つかりません」になる)・起動時の復旧と許可)は変わらない。

**次に着手する候補(順番はユーザーに選んでもらう)**:
1. 段階 5(一括リネーム)/ 段階 6(圧縮・展開)/ 段階 8(既存機能との接続)/ 段階 7(サムネイル)。段階 8.5 は書く操作が出揃ってから(Q12)

**ユーザーに頼むこと**: §4.9〜§4.14 のものに加えて、ふだんのホームの配下で Finder からフォルダを作ってツリーに出るか、
ロックした項目(Finder の「情報を見る」→「ロック」)の移動・名前の変更・置き換えの確認を実際のマウスで。

**分かった罠 / 実機検証の手順で足したこと**:
- **ストアだけを退避して表紙の保管庫を残したまま起動すると、表紙の元画像が `.orphaned/` へ隔離される**(今回踏んで、控えから戻して `diff -r` で一致を確認。docs/12 に追記)。
- **Debug のストアには本棚の中身が入っている**。空の本棚で起動する前にウインドウを撮らない(今回 1 枚撮ってしまい、すぐに消した。名前は会話にも書いていない)。
- 禁止語の検査は、起動ボリュームのデータ領域の頭(`FileBrowserTreeView.Coordinator.dataVolumePrefix`)の後ろに名前を続けた形も「ボリュームの下の名前」として止める。テストでは定数から組み立てる。
- Debug(`build-for-testing`)では通って、CI と同じ Release のビルドだけが Swift 6 の「並行して走るコードからの `var` の参照」で落ちた。コミット前に必ず Release を通す。

---

## 段階 5. 一括リネーム

**実装済み・実機検証済み(2026-09-14)。いま入っているものの説明は [docs/15「一括リネーム」](../15-file-browser.md)。** 下の箇条は立案時の計画のまま残す。
計画から変えた点(Finder の実測による。§5.1)と次の人への引き継ぎは §5.1。

### 5.1 引き継ぎ(一括リネームの完了時点、2026-09-14)

**ブランチの状態**: `feature/file-browser` にコミット・プッシュ済みで作業ツリーはきれい。関係する 4 suite(75 件)、
CI と同じ `-configuration Release QOO_CI_WARNINGS_AS_ERRORS=YES` のビルド、`scripts/ci/check-all.sh`、変更全体への禁止語の検査(一時の index で `--staged`)が通る。Debug の全テスト(1194 件)も通る ―― ただし 1 回目は
`FileIOTests` の「呼び出し元タスクの取り消しは、借りたスレッドの上で Cancellation として見える」が全体を並行に走らせた負荷の下で 1 件落ち
(17 秒かかった。FileIO は今回触っていない)、その suite だけなら 2 回とも、全体の 2 回目も通った。負荷で揺れるテストとして覚えておく。 CHANGELOG `[Unreleased]`(ファイルブラウザの項目)・MANUAL(「ファイルの操作」の表と「まとめて名前を変更」)・README(機能一覧。古くなっていた「ドラッグ&ドロップ・一括リネームは今後追加予定」も直した)・CLAUDE.md(アーキテクチャの段落)・docs/15・docs/12(Finder を測る手順)はここまでの内容に揃っている。`MARKETING_VERSION` は触っていない。

**Finder の実測(この機の macOS 26.6、日本語。使い捨てボリュームに合成名のファイルを置き、System Events で Finder のシートを操作)で計画から変えたもの**:
- 拡張子の規則(後ろから続く登録済みの拡張子全部)、置き換えの大文字小文字と拡張子の付け直し、カスタムフォーマットと区切りの空白、日付の書式
  (Finder の `LocalizableMerged.strings` の `DATE_FORMATTER1`)、開始番号の欄。詳細は `BulkRename` の型コメント。
- **衝突は無効にせず避ける**(番号を進める / `name 2`)。相手が元の名前全部なので **2 パス・一時名(`.qooViewer-rename-tmp`)は不要**になった。
- 使えない名前は Finder だとアラート+何もしない。qooViewer はシートの中で赤字+押せない(計画の赤字の考えはここに残した)。
- **⌘R は入れていない**(Finder の ⌘R は「オリジナルを表示」で、名称変更にキーは無い。qooViewer の Return は「開く」)。入り口は右クリックだけ。
- 文言: 部品の文言は Finder の文言表を写したが、見出しは「項目の名前を変更:」、ボタンは既存の「名前を変更」(用語表)。
- Finder の実測の後始末: `com.apple.finder` の `BulkRename*` を控えから書き戻し、一致を確認した。

**実機で確かめたこと(Debug・空の本棚・使い捨て APFS 1 本に合成名)**: 5 件を選んだ右クリックに「5 項目の名前を変更…」、シートの 3 方式の配置と高さ、
検索文字列 `a` で「先頭がドット」の赤字と押せないこと、フォーマット/カウンタで `ファイル 00001`(フォルダ)〜`ファイル 00005.zip.cbz` に変わり全部選ばれる、
編集メニューが「5 項目の名前の変更を取り消す」、⌘Z 1 回で全部戻る、前回の入力が次のシートに出る、Esc でキャンセル。後始末で defaults・ストア・表紙の保管庫が控えと一致。

**確かめていないもの**: すりガラス 2 条件(シートは macOS が不透明に描くので対象外のはず)、ライトの外観、英語表示での配置、進捗の帯(数千件の名前の変更)と中止、
ロックされた項目の確認の見た目、テキストを追加の実行、`heap` でのシートの残留、ネットワーク上の共有。

**気づいているが直していないもの**:
- 赤字の理由は長いと末尾が切れる(全文はツールチップ)。
- 2000 件を超える選択では、使えない名前の判定を押した後にだけ行う(シートは例の行だけ決める)。そのときは押すとアラートで知らせて何もしない。
- 例の行も押した結果も、フォルダの中身をシートを開く時点・押す時点で読むので、その間に外で名前が変わると例と結果が食い違うことがある(結果が正しい)。

**ユーザーに頼むこと**: §4.9〜§4.15 のもの(Dock のゴミ箱へのドラッグ、ファイル選択ダイアログ・TCC、効果音、SMB への書き込み、実際のマウスでの確認など)に加えて、
ふだんのフォルダで一括リネームを使ってもらい、Finder と同じ結果になるか(特に拡張子の残り方と番号の避け方)を見てもらう。

**次に着手する候補(順番はユーザーに選んでもらう)**: 段階 6(圧縮・展開)/ 段階 8(既存機能との接続)/ 段階 7(サムネイル)。段階 8.5 は書く操作が出揃ってから(Q12)。

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

**実装済み・自動テスト済み(2026-09-14)。いま入っているものの説明は [docs/15「圧縮・展開」](../15-file-browser.md)。** 下の箇条は立案時の計画のまま残す。
計画から変えた点と次の人への引き継ぎは §6.1。

### 6.1 引き継ぎ(圧縮・展開の実装の完了時点、2026-09-14)

**ブランチの状態**: `feature/file-browser` にコミット・プッシュ済みで作業ツリーはきれい(2026-09-14、ユーザー指示。実装 `81753ee`、実機検証で見つけた問題の修正と
この引き継ぎはその次のコミット)。Unrar.swift フォークも `2d2982e` を push し、`Package.resolved` をそこへ進めた。Debug の全テスト(1219 件)、CI と同じ
Release のビルド、`scripts/ci/check-all.sh` が通る。CHANGELOG `[Unreleased]`・MANUAL・README・CLAUDE.md・docs/11・docs/12・docs/15 はここまでの内容に揃っている。
`MARKETING_VERSION` は触っていない。

**入れたもの**: 右クリックの「圧縮 ▸ ここに圧縮 / 保存先を選んで圧縮…」「展開 ▸ ここに展開 / 「〈名前〉」に展開 / 展開先を選んで展開…」、
環境設定「ファイルブラウザ」の「圧縮したファイルの形式」(zip / cbz、キー `qooViewer.pref.fileBrowser.compressionFormat`)、
`ArchiveReading.entriesInArchiveOrder()` / `readEntry(at:_:)`(3 形式)、`ProgressTracker.init(sink:totalBytes:totalItems:)` と間引くエントリの区切り
(`startEntry` / `finishEntry`。「最初のバイトは間引かない」の例外を消費しない)、`FileBrowserOperationPresenting.chooseDestinationFolder`。

**計画から変えた点**:
- 「圧縮…」「展開…」は**どちらもフォルダ選択(NSOpenPanel)**にし、題を「保存先を選んで圧縮…」「展開先を選んで展開…」にした。NSSavePanel はそのファイル 1 つぶんの
  許可しか付かず、同じフォルダの一時ファイルから置く形が取れない(置き換えの確認も NSSavePanel と二重になる)。名前は「ここに…」と同じ規則で決まる。
- 「展開先を選んで展開…」は選んだフォルダの**直下に中身を並べる**(「ここに展開」を別の場所で)。書庫ごとのフォルダが要るなら、選んだ先で「〈名前〉に展開」を
  使ってもらう想定。**利用者の意図と違えば変える**(未確認)。
- 「〈名前〉に展開」は、**一時フォルダそのものを書庫の名前へ rename** する(計画は「フォルダを作る + 展開」の 2 コマンド)。1 回の rename で置け、取り消しは
  そのフォルダ 1 つをゴミ箱へ。同じ名前のフォルダが既にあれば**中へ混ぜずに `name 2`**(Finder のアーカイブユーティリティと同じ)。
- 展開先の既存の項目との衝突は尋ねない(`name 2`。計画どおり)。書庫の中の大文字小文字だけ違うフォルダは**まとめる**(計画は `name 2`)。
- 圧縮比の限度は、合計 100MB 以下では問わない(0 を詰めた小さなファイルで正当な書庫を断らないため。計画には無かった)。
- 使えないエントリを捨てたときは、展開は済ませたうえで「一部を処理できなかった」の報告に並べる(黙って捨てない。`__MACOSX` と `._*` だけは黙る)。
- 暗号化は rar だけ見分けて先に断る(zip・7z は reader が印を持たず「読めませんでした」)。分割 rar も先に断る。

**実測で分かったこと**:
- **ソリッドの rar の展開は 2 乗で遅かった**: 180MB・60 ファイル(3MB の乱数)で、非ソリッド 1.4 秒 / ソリッド 62 秒(Debug、テストホストの中)。
  unrar の公開 API(`Archive.extract(_:handler:)`)が 1 項目ごとに書庫を開き直して先頭から見出しを辿り、ソリッドでは読み飛ばす項目も伸長するため。
  ユーザーの指示でフォークに `Archive.forEachEntry(_:)`(1 回開いて見出しの順に読み通す)を足し(`2d2982e`)、`ArchiveReading.readEntriesInArchiveOrder`
  を rar だけ上書きした。**同じ書庫でソリッド 2.2 秒 / 非ソリッド 1.3 秒**。ページの表示は 1 枚ずつの `extract` のまま(変えていない)。
- 7z はフォークのストリーミング経路を書庫順に読むので線形(ソリッドでもやり直しは起きない)。
- ProgressTracker の「項目の最初のバイトは間引かない」を、展開のエントリの名前の報告が使い切っていた(小さな書庫では 100ms の間に全部終わり、
  バイトの報告が 1 回も出なかった)。エントリの区切りは例外を使わないようにした。
- Swift の `Set<String>` は正規化違い(NFD / NFC)を同じ値として扱うので、書庫の中の `é`(NFD)と `é`(NFC)は同じパスとして 2 つ目を捨てる
  (reader の索引も同じ鍵になり、どのみち同じ中身しか引けない)。

**実機で確かめたこと(2026-09-14、scratchpad へ素の `build` をした Debug・空の本棚・使い捨て APFS 1 本に合成名。後始末でストア・表紙の保管庫・defaults が控えと一致)**:
リストの右クリックの「圧縮 ▸ ここに圧縮 / 保存先を選んで圧縮…」(フォルダ・ファイル)、「展開 ▸ ここに展開 /「solid-book」に展開 / 展開先を選んで展開…」(書庫だけ)、
アイコン表示(SwiftUI の `Menu`)のサブメニューと「ここに展開」、英語表示の項目名(Compress / Extract / Extract Here / Extract to “ditto-book” / Extract To…)。
フォルダの圧縮で zip ができて選ばれる、環境設定を cbz にすると `.cbz`、ソリッドの cbr の「〈名前〉に展開」の中身が元と一致し日時も保たれる、編集メニューが
「「solid-book.cbr」の展開を取り消す」で ⌘Z で消える、7z の「ここに展開」の 6 枚が ⌘Z で全部消える、Finder(ditto)で作った cbz の `__MACOSX` が出ない、
`../` と絶対パスの入った zip は `ok/` だけができて報告のシートに 2 行並ぶ、パスワード付きの cbr は「パスワードで保護されています」、「展開先を選んで展開…」で
パネルがシートで出て Esc で何も起きない、900MB の乱数の圧縮で進捗の帯(「「Big」を圧縮しています…」「1 件中 1 件目 — 866.1 MB / 900 MB — 残り約 1 秒」)が出て
中止すると一時ファイルも zip も残らない(報告も出ない)、空きが足りないと書き始める前に断る、環境設定「圧縮」の行、新規ウインドウの開閉 6 回で
`FileBrowserState` / `AppState` / `FileBrowserOperations` が 2(表示中 1 + 遅れて手放す 1)のまま増えない。
**実機で見つけて直したもの**: zip の日時が 9 時間ずれていた(ZIPFoundation が MS-DOS 形式の日時を UTC として扱う。docs/15「圧縮・展開」。直した後の build で、
ditto の cbz を展開した日時が元と一致、作った zip の日時が元のファイルと一致することを確かめた)。圧縮の中の並びが列挙の順だった(名前順にした)。

**実機検証のあとで直したもの(ユーザー指示、2026-09-14)**:
- **空き容量が足りないときの文**が「1.5 GB 必要ですが、空きは 1.5 GB です」と足りているように読めた。比べていたのは書く量 + 余裕(`freeSpaceMargin`)なのに、
  見せていたのは書く量だけだった。`FileOperationError.insufficientFreeSpace(required:)` に**余裕を足した値**を入れるようにした(コピー・移動・圧縮・展開の 3 箇所。
  段階 2 からの文)。`FileOperationVolumeTests` で「必要量 > 空き」を確かめる。
- **報告の題のかぎ括弧が重なった**(「「「slip.zip」の展開」で処理できなかった項目があります。」)。操作の名前(`displayName`)は「「x」の展開」「3 項目のコピー」のように
  自分で括弧を持つので、それを入れる 7 つの題(完了できませんでした / 処理できなかった項目 / 中止したが戻せなかった / 一部しか取り消せ・やり直せなかった /
  取り消せ・やり直せなかった)は**囲まない**文にした(英語も `%@ couldn’t be completed.` のように名前で文を始める。キーごと変えた)。
  `FileBrowserOperationsTests.operationNameTitlesDoNotNestQuotes` で固定。この 2 件は実機では撮り直していない(文言と値の変更だけで、テストで確かめた)。

**確かめていないもの(実機)**: すりガラス 2 条件(追加した UI はメニュー・パネル・シート・環境設定で、どれも不透明に描かれるので対象外のはず)、ネットワーク上の共有への圧縮・展開、
Windows で作った CP932 の zip の実物(テストのフィクスチャでは確かめてある)、実際のマウスでの操作、7z・rar の大きな書庫の展開の進捗と中止。

**気づいているが直していないもの**:
- ~~本の書き出し(CbzExporter / EpubExporter)が書く zip の日時は、まだ UTC のまま~~ → 直した(§8.5.3)。
- rar・7z の記号リンクは見分けられず、リンク先のパスを中身にした小さなファイルとして展開される。
- 展開したファイルに実行権などの属性は写さない(漫画の用途では困らない想定)。
- 展開の一時フォルダは記録を持たないので、途中でアプリが落ちると `.qooViewer-extract-<UUID>/` が残る(隠しフォルダ。置き換えの退避と違って元の項目は入っていない)。
- 複数の書庫を展開するときの進捗の件数は全書庫のファイルの通し番号で、帯の題は「N 個の書庫を展開しています…」。

**ユーザーに頼むこと**: §4.9〜§5.1 のものに加えて、ふだんの書庫(特に Windows で作った zip・大きなソリッドの cbr/cb7)で「〈名前〉に展開」と「ここに圧縮」を使い、
中身・名前・日時が期待どおりか、実際のマウスで見てもらう。「展開先を選んで展開…」を直下に並べる形でよいか(書庫ごとのフォルダを作るほうがよければ変える)。

**実機検証の手順で足したこと**(docs/12「ファイルブラウザ」): 選ばれている行を左クリックしてから右クリックすると名前の編集が始まり、文字のメニューが出る。
使い捨てボリュームが外れないときは `lsof +D` で持ち主を見る(ほかのアプリのサムネイルの拡張が書庫を開いたままだった)。
「情報を見る」系の日時は `stat` / `unzip -l` と突き合わせる(同じライブラリでの往復のテストでは、ZIPFoundation の UTC の扱いが見つからなかった)。

**次に着手する候補(順番はユーザーに選んでもらう)**:
1. 段階 8(既存機能との接続)/ 段階 7(サムネイル)。段階 8.5 は書く操作が出揃ってから(Q12)。圧縮・展開も読み取り専用モードで淡色にする対象
2. 本の書き出しの zip の日時(上の「気づいているが直していないもの」)

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

**7a(本・画像・画像フォルダ)・7b(動画)は実装済み(2026-09-14)。いま入っているものの説明は [docs/15「サムネイル」](../15-file-browser.md)。** 下の箇条は立案時の計画のまま残す。
計画から変えた点と次の人への引き継ぎは §7.1(7a)・§7.2(7b)。

### 7.1 引き継ぎ(段階 7a の完了時点、2026-09-14)

**ブランチの状態**: `feature/file-browser` にコミット・プッシュ済みで作業ツリーはきれい(2026-09-14、ユーザー指示)。Debug の全テスト(1234 件)、CI と同じ
`-configuration Release QOO_CI_WARNINGS_AS_ERRORS=YES` のビルド、`scripts/ci/check-all.sh` が通る。CHANGELOG `[Unreleased]`(ファイルブラウザの項目と
環境設定「キャッシュ」の項目)・MANUAL(アイコン表示・環境設定「キャッシュ」・リソースモニタ・すべてのデータを削除)・README(機能一覧)・CLAUDE.md
(アーキテクチャの段落)・docs/15・docs/06・docs/03・docs/02・docs/12 はここまでの内容に揃っている。`MARKETING_VERSION` は触っていない。

**ユーザーが決めたこと(2026-09-14)**: 段階 7 は 7a → 7b に分ける / ディスクキャッシュは**既定 ON・上限 200MB** / キャッシュの行は
環境設定「**キャッシュ**」に置く(計画の「ファイルブラウザ」ではなく)/ 絵は**アイコン表示だけ**(リストの行のアイコンは種類のまま)。

**入れたもの**: `Services/FileBrowserThumbnails/`(`BookThumbnailer` / `FileBrowserThumbnailDiskCache` + `FileBrowserThumbnailKey` /
`FileBrowserThumbnailProvider`)、`Views/FileBrowser/FileBrowserIconImage.swift`、`ImageDecoder.decode(fileAt:maxPixelSize:)`、
`DirectoryProbe.protectedPrefix(containing:)` / `categoryProtectedPrefixes`、`AppPreferences.fileBrowserThumbnailCache{Enabled,LimitMB}`、
環境設定「キャッシュ」の節と使用量の行、リソースモニタの「ディスク」の行(`StorageUsage.fileBrowserThumbnailCacheBytes`)、
「すべてのデータを削除」での削除、`AppStores.fileBrowserThumbnails`(ウインドウの環境オブジェクト)。文言 8 件を xcstrings へ手で足した。

**計画から変えた点**:
- rar/7z も「書庫順の先頭」ではなく**正準順の先頭**(棚の表紙・本の 1 ページ目と揃える。検討メモ §6.1 の記述どおり。ソリッドの書庫でも
  名前順の先頭は書庫の先頭付近にあるのが普通)。
- フォルダは**直下の画像だけ**を見る(本を開く規則はサブフォルダも再帰で集めるが、セルごとの再帰の走査は重い)。章のサブフォルダにだけ画像を
  持つフォルダには絵を出さない。
- メモリの LRU は計画の「`PagePixelCache` 型」をそのまま使った(96MB)。セルの残留は `LazyCellImageBudget`(64MB)。
- 保護下の場所の扱いを足した: デスクトップ・書類・ダウンロードの中を見ているときだけ、同じ場所の中のフォルダは読む。
- 表紙が変わったときの読み直しは `CollectionStore.revision` の購読で(提供役の `revision` → セルの `.task(id:)`)。

**実機で確かめたこと(2026-09-14、scratchpad へ素の `build` をした Debug・空の本棚・使い捨て APFS 1 本に合成名の cbz / cb7 / cbr / PDF / png /
画像フォルダ / 章だけのフォルダ / 画像の無い cbz / txt)**: アイコン表示に各書庫の 1 ページ目・PDF の 1 ページ目・png(透明な地は白)が出る、
画像フォルダはフォルダのアイコンの上に `1.jpg`(`10.jpg` より前)が重なる、章だけのフォルダ・画像の無い cbz・txt は種類のアイコンのまま、
アイコンの大きさを最大(256)にしても粗くならない、ディスクキャッシュに 6 枚(長辺 512px)ができ、アプリを終えて起動し直すと**作り直さずに**
読む(ファイルの作成日時は同じで更新日時だけ進む)、環境設定「キャッシュ」に「ファイルブラウザのサムネイル」の節と使用量(49 kB)の行が出て
「削除」で 0 kB になりフォルダが消える。後始末でストア・表紙の保管庫・defaults が控えと一致。

**確かめていないもの**: すりガラス 2 条件(絵は輪郭を掛けない側で、影だけ足した)、`heap` での残留とメモリ(`footprint`)、項目の多いフォルダでの
スクロールとグリッドの作り直し(`LazyCellImageBudget` の 64MB に届く量)、名前の編集中に作り直しが待つこと、ネットワークの共有、
デスクトップ・書類の中(TCC)、コレクションに登録済みの本で表紙が使われること(テストも無い ―― `InMemoryLibrary` の上で書けるはず)、
OFF にしたときその場で消えること(テストはある)、リソースモニタの行の見た目、英語表示。

**気づいているが直していないもの**:
- 絵の地の色: 本・画像の絵は枠いっぱいに出るので、種類のアイコン(周りに余白を持つ)と並ぶと大きく見える(Finder も同じ)。
- 本の絵は PDF の cropBox で描き、埋め込み画像の解像度は見ない。表紙の上書き(ページ指定)は登録済みの本の表紙を使う経路でだけ効く。
- 作れなかった絵はこの起動の間だけ覚える。壊れた書庫の多いフォルダでは、起動のたびに 1 回ずつ読み直す。
- 並べ替えで順番を変えただけでは読み直さない(メモリの鍵は項目のパス・更新日時・サイズ)。

**実機検証の手順で分かったこと**(docs/12 に追記): **空の本棚で起動すると、Debug の `Caches/.../CollectionTiles` が空になる**(起動時の孤児の掃除。
カバーから作り直せるキャッシュなので戻していない)。環境設定の右ペインは AX で `scroll bar 1 of scroll area 1 of group 2 of splitter group 1 of group 1`
の `value` を 1 にすると下まで送れる。ボタンは AX の名前を持たないので座標でクリックした。

**次に着手する候補(順番はユーザーに選んでもらう)**:
1. 段階 7b(動画の絵: QuickLook・mkv・`hev1`、環境設定「ファイルブラウザ」の「動画のサムネイルを作る」、よく使う項目の配下の事前生成)
2. 段階 8(既存機能との接続)。段階 8.5 は書く操作が出揃ってから(Q12)
3. 本の書き出しの zip の日時(§6.1 の「気づいているが直していないもの」)

**ユーザーに頼むこと**: ふだんの蔵書のフォルダをアイコン表示で開き、絵の出る速さ・並ぶ絵が表紙として妥当か(特に入れ子の書庫・章フォルダの本)、
スクロールしたときの様子を実際のマウスで見てもらう。

### 7.2 引き継ぎ(段階 7b の完了時点、2026-09-14)

**ブランチの状態**: `feature/file-browser` にコミット・プッシュ済みで作業ツリーはきれい(2026-09-14、ユーザー指示)。Debug の全テスト(1250 件)、CI と同じ
`-configuration Release QOO_CI_WARNINGS_AS_ERRORS=YES` のビルド、`scripts/ci/check-all.sh` が通る。CHANGELOG `[Unreleased]`(ファイルブラウザの動画の絵と
事前生成・環境設定「ファイルブラウザ」の行)・MANUAL(アイコン表示・環境設定「ファイルブラウザ」の表・「ファイルブラウザのサムネイル」)・README(機能一覧)・
CLAUDE.md(アーキテクチャの段落)・docs/15・docs/12 はここまでの内容に揃っている。`MARKETING_VERSION` は触っていない。

**ユーザーが決めたこと(2026-09-14)**: 次に着手するのは 7b / 環境設定は「動画のサムネイルを作る」**1 行で**アイコン表示の絵と事前生成の両方を切り替える /
事前生成はよく使う項目の**サブフォルダも全部**辿る(保護下の場所・隠しフォルダ・ネットワーク越し・実体の無いファイルは除く)。

**入れたもの**: `Services/FileBrowserThumbnails/` に `VideoThumbnailer.swift`(`VideoThumbnailLoading`・`QuickLookVideoThumbnailLoader`・
`CompositeVideoThumbnailLoader`・`isVideoFile`・`isDataless`)、`RetaggedHEVCThumbnailLoader.swift`、`MediaContainerSniffer.swift`、
`MatroskaDimensionReader.swift`、`FileBrowserVideoThumbnailWarmer.swift`。`BookThumbnailer.Kind.video`、提供役の動画の経路・`includesVideo`・
`videoThumbnailJPEG`、`FileBrowserThumbnailDiskCache.contains`、`FileIO.perform(qos:)`、`AppPreferences.fileBrowserVideoThumbnailsEnabled`
(キー `qooViewer.pref.fileBrowser.videoThumbnailsEnabled`、既定 ON、「ファイルブラウザ」画面の「初期設定に戻す」の対象)と環境設定「ファイルブラウザ」の
「アイコン表示」の節、`AppStores.fileBrowserVideoThumbnailWarmer`。文言 3 件を xcstrings へ手で足し、キャッシュの説明 2 件を「本・画像・動画・フォルダ」に
直した(キーが変わった)。テストは `FileBrowserVideoThumbnailTests`(16 件)。

**計画から変えた点**:
- 名前は `VideoThumbnailer` / `BackgroundThumbnailWarmer` ではなく、口を `VideoThumbnailLoading`(qooLibrary と同じ)、先に作る役を
  `FileBrowserVideoThumbnailWarmer` にした。
- 事前生成の ON/OFF の行を足さない(ユーザーの判断)。ディスクキャッシュが OFF のときも動かない(作っても捨てるだけ)。
- 事前生成の「形式ごとに諦める」は**1 回の掃引の中だけ**(qooLibrary も同じ)。起動をまたいでは覚えない。
- 保護下の場所の扱いを足した(qooLibrary には無い): よく使う項目そのものが同じ保護下の場所の中にあるときだけ辿る。
- `MatroskaDimensionReader` の大きさの足し算を飽和させた(qooLibrary は `offset += Int(size)` で、細工した巨大な大きさで落ちうる)。ID は 4 バイトまで。
- `FileIO.perform` の非 throws 版に `qos` の既定値付き引数を**足さず**、`qos` 必須の版を別に置いた(既定値付きの引数が増えた版は throws の版より
  弱い候補に数えられ、既存の `try` 無しの呼び出しがすべてコンパイルエラーになった)。
- 動画は本の表紙(コレクション)を探さない。実体が手元に無い動画は作らず、「作れなかった」とも覚えない。

**利用者に見える変化**(CHANGELOG・MANUAL に書いたもの): ファイルブラウザのアイコン表示で、動画に中の 1 コマが出る(mp4・mov など。mkv などは
QuickLook の機能拡張があれば)/ ffmpeg で作った `hev1` の HEVC の mp4 にも絵が出る(Finder では出ない)/ 拡張子と中身が食い違う動画にも出る /
よく使う項目の中の動画は、起動している間に裏で作っておくので開いたときにすぐ出る / 環境設定 ▸ ファイルブラウザ ▸ 「動画のサムネイルを作る」で
まとめてオフにできる / 環境設定 ▸ キャッシュの「ファイルブラウザのサムネイル」に動画の絵も入る。

**実機で確かめたこと(2026-09-14、scratchpad へ素の `build` をした Debug・空の本棚・使い捨て APFS 1 本に合成の動画)**:
`AVAssetWriter` で作った H.264 の mp4(横長)・HEVC の mp4(縦長)・mov(正方形)、HEVC の `hvc1` を `hev1` に書き換えた mp4、`.mkv` を名乗る mp4、
自作の Matroska(H.264 を SimpleBlock に詰めたもの)と `.mp4` を名乗るその Matroska を並べ、**すべて縦横比どおりの絵が出た**(`hev1` は再タグ付けの経路、
mkv は QLMedia の経路 ―― 縦横比の補正が効いて 512×218)。起動から 3 秒で表示中の 5 本、2 秒の待ちの後で**よく使う項目の中の 2 本(サブフォルダの 1 本を含む、
隠しフォルダの 1 本は除く)がディスクキャッシュに入り**、起動し直してよく使う項目を開いても作り直さなかった(7 枚のまま)。環境設定の「動画のサムネイルを作る」を
OFF にするとその場で種類のアイコンに戻り、ON で絵に戻る(下の修正の後)。後始末でストア・表紙の保管庫・Caches・defaults が控えと一致。

**実機の検証で見つけて直したもの**: 「動画のサムネイルを作る」を OFF にしても、表示中のセルの絵が残った。`FileBrowserIconImage` の `.task(id:)` の鍵に
種類が入っておらず、`kind` が nil になっても読み直しが走らなかった(鍵に種類を足し、body も `kind` が nil なら絵を出さない)。

**確かめていないもの**: 事前生成が実物の QuickLook で「3 回失敗で諦める」こと(拡張の無い形式の実物で。テストは作り物)・途中で OFF にしたとき止まること
(テストはある)・ネットワークの共有・iCloud の追い出されたファイル・TCC の保護下の場所の中のよく使う項目・大量の動画(数千本)での掃引の時間とメモリ・
8 秒の期限に当たるファイル・すりガラス 2 条件(絵は 7a と同じ部品)・英語表示・Release(普段使いのアプリ)での QLMedia。

**気づいているが直していないもの**:
- 作れなかった動画(8 秒の期限を含む)は、本と同じくこの起動の間は覚える。一時的に重かっただけのファイルも、次の起動まで種類のアイコンのまま。
- 事前生成は起動時・よく使う項目の変化・設定の変化でしか回らない。起動している間によく使う項目の中へ増えた動画は、アイコン表示で見えるか次に回るまで作らない。
- 事前生成が作った絵はディスクキャッシュの上限(既定 200MB)に数えられ、動画が多いと本の絵を刈り込みで押し出しうる。
- `UTType` の判定は入っているアプリに左右される(mkv を扱うアプリが無い機では mkv は動画にならず、事前生成の対象にもならない)。

**次に着手する候補(順番はユーザーに選んでもらう)**:
1. 段階 8(既存機能との接続)。段階 8.5 は書く操作が出揃ってから(Q12)
2. 本の書き出しの zip の日時(§6.1 の「気づいているが直していないもの」)
3. §7.1・§7.2 の「確かめていないもの」の実機確認(ネットワークの共有・iCloud・大量の動画・すりガラス 2 条件・英語表示)

**ユーザーに頼むこと**: ふだんの動画のフォルダ(mkv を含む)をアイコン表示で開き、絵の出る速さと中身、よく使う項目に動画の多いフォルダを登録したときに
起動直後のアプリが重くならないかを、実際に見てもらう。

**分かった罠 / 実機検証の手順で足したこと**(docs/12 に追記):
- 動画の作り方は、**実物のソース(`VideoThumbnailer.swift` ほか 4 本 + `FileIO.swift`)を `swiftc` で小さな CLI と一緒にコンパイルすれば**、アプリを起動せずに
  QuickLook と再タグ付けの結果・時間を測れる(`-swift-version 6 -enable-upcoming-feature NonisolatedNonsendingByDefault -parse-as-library`、
  `FileOperationError` だけ作り物)。
- 合成の動画は `AVAssetWriter` で作れる。`hev1` は HEVC の mp4 の `hvc1` の 4 バイトを書き換えるだけで再現する。Matroska は H.264 のサンプルを素通しで読み、
  EBML を手で組んで SimpleBlock に詰めれば QLMedia が読める(ffmpeg が無くても作れる)。
- ファイルブラウザのツリーにはボリュームとホームの名前が写る(ボリューム名は書いてよい語。ホームの名前は撮った画像を外へ出さない)。

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

**実装済み・自動テスト済み(2026-09-14)。いま入っているものの説明は [docs/15「既存機能との接続」](../15-file-browser.md)。** 上の箇条は立案時の計画のまま残す。

### 8.1 引き継ぎ(段階 8 の実装の完了時点、2026-09-14)

**ブランチの状態**: `feature/file-browser` にコミット・プッシュ済みで作業ツリーはきれい(2026-09-14、ユーザー指示)。Debug の全テスト(1264 件)、CI と同じ
`-configuration Release QOO_CI_WARNINGS_AS_ERRORS=YES` のビルド、`scripts/ci/check-all.sh` が通る。CHANGELOG `[Unreleased]`(右クリックの 4 項目・「ファイルブラウザで開く」・
環境設定の行)・MANUAL(ファイルブラウザの「本棚・メタデータ・書き出し」、17 章「ファイルブラウザで開く」、環境設定「ファイルブラウザ」の表)・README(機能一覧)・
CLAUDE.md(アーキテクチャの段落)・docs/15・docs/03 はここまでの内容に揃っている。`MARKETING_VERSION` は触っていない。
MANUAL の「いまの制限」に残っていた「本の表紙は表示されません」(段階 7a で古くなっていた)も直した。

**ユーザーが決めたこと(2026-09-14)**: 次に着手するのは段階 8(§7.2 の候補から)。

**入れたもの**:
- 右クリック(リスト・アイコン・ツリー)の「コレクションを作成」「コレクションに登録 ▸」「このアプリケーションで開く ▸」「メタデータの編集…」「本の書き出し ▸」
  (`Views/FileBrowser/FileBrowserLibraryActions.swift`、`Services/FileBrowser/OpenWithApplications.swift`)。場面で変わるサブメニューは
  `FileBrowserMenuNode` の木にして AppKit・SwiftUI の両方で描く。
- 「ファイルブラウザで開く」を「Finder で開く」の隣 9 箇所(`ViewModels/FileBrowserReveal.swift`: `AppState.revealInFileBrowser`、環境値
  `\.revealInFileBrowser`)。`WindowContentRequest.browse(folder:selecting:nonce:)`、`BookWindowOpener.openFolder(_:selecting:…)`、
  `FileBrowserState.show(_:isDirectory:)` / `prepare(showing:selecting:)`、`AppState.welcomeLibrary`(weak)。
- 環境設定「ファイルブラウザ」の「ファイルブラウザで開く ▸ 本を表示しているとき」(`fileBrowserRevealDestination`、キー
  `qooViewer.pref.fileBrowser.revealDestination`、既定は新規タブ、「初期設定に戻す」の対象)。
- `BookMetadataSheet(sourceURL:)`(カバーの面を出さない版)、`BookExportViewModel.exportOpenBook` の `displayState` を省略可に、
  `WelcomeDropHandling.queueCreations` を内部公開(戻り値 Bool)、`FileBrowserState.bookSheet`。文言 11 件を xcstrings へ手で足した。
- テストは `FileBrowserIntegrationTests`(14 件)と `AppPreferencesTests` の画面の一覧・`AppPreferencesProbe`。

**計画から変えた点**:
- **本の書き出しは本を読まずにシートを出す**(計画は `BookLoader.load` + `BookLoadingOverlay`)。シートが使うのは id と場所だけで、書き出しは
  `BookLoader.load` で読み直すため、先に読むと大きな書庫を 2 回読む。本にならないファイルは書き出しの失敗として出る(書庫・PDF・EPUB に絞ってある)。
- 書き出しの「書き出したあとの動作」「保存データ・履歴の削除」はファイルブラウザからはしない(読んでいる本の続きを決める設定のため)。
- 「コレクションを作成」はモードを本棚へ戻さず、ファイルブラウザのまま名前のシートを出す(シートは `WelcomeView` が持つ)。ドロップと同じ振り分けなので、
  ばらの本の既定の名前は空、棚はフォルダ名。「コレクションに登録」は `addingBooks` パネルではなくサブメニューでコレクションを選ぶ。
- 画像フォルダかどうかは一覧の読み込みでは確定させず(§3.8 の方針のまま)、フォルダの項目は淡色にしないで選んだときに調べ、本でなければ伝える。
- 「ファイルブラウザで開く」は**フォルダならその中、ファイルなら入っているフォルダで選ぶ**(`FinderReveal` と同じ規則。計画は常に親で選ぶ)。
- サイドパネルのフォルダブラウザの見出しのアイコン(「Finder で開く」)には足していない(11 箇所のうち `SidePanelView:555`。右クリックにはある)。
  `RecentBooksPopover` は段階 1 で消えているので、実際に足したのは 9 箇所。
- 「このアプリケーションで開く」から qooViewer 自身を除いた(「開く」がそれにあたる)。

**テストで見つけて直したもの**: `coverExtractor?.enqueue(collectionStore.add(...))` と 1 行で書くと、抽出役が nil のときに引数ごと評価されず本が足されなかった
(アプリでは抽出役が必ず居るので表には出ないが、分けて書いた)。

**確かめていないもの(実機。まだ一度も起動していない)**: 右クリックの 5 項目の見た目(アイコン表示の SwiftUI の `Menu` にアプリのアイコンが出るか、サブメニューの入れ子)、
名前のシートがファイルブラウザの上に出ること、メタデータのシート(カバー無し)の大きさ、書き出しのシートと固定の保存先、「その他…」でサンドボックスから開けるか
(`kLSAppDoesNotClaimTypeErr`)、9 箇所の「ファイルブラウザで開く」(特にサイドパネルの奥とページ一覧で環境値が届くか、新規タブ/ウインドウで項目が選ばれるか、
シークレットウインドウからノーマルへ)、本棚のコレクションの中からこのウインドウで切り替わること、ウインドウを閉じたあとの残留(`heap`)、すりガラス 2 条件
(追加した UI はメニュー・シート・環境設定の行で、どれも不透明に描かれるので対象外のはず)、英語表示。

**気づいているが直していないもの**:
- アイコン表示のセルごとの `.contextMenu` は、本体評価のたびに「コレクションに登録」のサブメニュー(コレクションの数だけ)を組み立てる。一覧は覚えているが、
  `Menu` の中身のビューは毎回できる。コレクションが数百のときのスクロールの重さは測っていない。
- 「このアプリケーションで開く」の候補は拡張子ごとに覚え、qooViewer が前面に戻ったときに捨てる。前面のまま他のアプリが入れ替わっても古いまま。
- 「ファイルブラウザで開く」で見せたフォルダに読む許可が無いと、ファイルブラウザ側の「アクセスを許可…」が出るだけ(本を開いた許可からフォルダの許可へは広げない)。
- ~~「コレクションに登録」は足し終えても何も出さない(本棚ではないので目に見える変化が無い)。~~ → 右ペインの下に 2 秒の知らせを出すようにした(2026-09-14、ユーザー要望。docs/15「右クリック」)。

**次に着手する候補(順番はユーザーに選んでもらう)**:
1. 段階 8 の実機確認(上の「確かめていないもの」)
2. 段階 8.5(読み取り専用モード。書く操作は出揃った ―― コレクション・メタデータは保存データへの書き込みで、ファイルを変えないので「できるまま」の側)
3. 本の書き出しの zip の日時(§6.1)/ §7.1・§7.2 の実機確認

**ユーザーに頼むこと**: ふだんの蔵書で、ファイルブラウザからのコレクションの作成・登録、コレクションの外の本のメタデータの編集と書き出し、ビューア・サイドパネルからの
「ファイルブラウザで開く」を実際に使い、行き先(新規タブ)と選ばれ方が期待どおりか見てもらう。

### 8.2 引き継ぎ(段階 8 の実機検証とウインドウのタイトルの完了時点、2026-09-14)

**ブランチの状態**: `feature/file-browser` にコミット・プッシュ済みで作業ツリーはきれい(2026-09-14、ユーザー指示。§8.1 の `fb6a266` の次のコミット)。
Debug の全テスト(1267 件)、CI と同じ Release のビルド、`scripts/ci/check-all.sh` が通る。CHANGELOG `[Unreleased]` の「変更」(ウインドウのタイトル)・MANUAL 22 章・
CLAUDE.md(アーキテクチャの段落)・docs/15・docs/12 はここまでの内容に揃っている。`MARKETING_VERSION` は触っていない。

**ユーザーが決めたこと(2026-09-14)**: 本を開いていないウインドウ・タブのタイトルを、ファイルブラウザはいまのフォルダ、本棚はライブラリ/コレクションの名前にする
(「ライブラリ — コレクション」の両方を出す案は採らなかった)。

**実機で確かめたこと(scratchpad へ素の `build` をした Debug・空の本棚・使い捨て APFS 1 本に合成名。2 回に分けて行い、どちらも後始末でストア・表紙の保管庫・Caches・
defaults が控えと一致、ボリュームは外した)**:
- リストの右クリック: 5 項目が押せる。「このアプリケーションで開く ▸」はアプリのアイコン付きで、既定のアプリ・区切り線・名前順・「その他…」の順(既定は Release 版の
  qooViewer ―― bundle id が違うので除外の対象外。想定どおり)。「コレクションに登録 ▸」はコレクションが無いと「コレクションがありません」(淡色)。
- 棚のフォルダの「コレクションを作成」: ファイルブラウザの上に名前のシート(初期値はフォルダ名、自動登録フォルダも入る)→ 作成で 2 冊・表紙付きのコレクション。
- 「コレクションに登録 ▸ Sample Shelf」: **最初は何も起きなかった**(下の修正 1)。直した後はリスト(AppKit)・アイコン表示(SwiftUI)の両方で登録された(ストアを読んで確認)。
- 画像フォルダの「メタデータの編集…」: カバーの欄の無いシート(タイトルの初期値はフォルダ名)→ 登録で `ZBOOKMETADATA` にパスの行。
- 「本の書き出し ▸」: 3 形式。PDF を選ぶと保存先のパネルが出て、Esc で何も起きない。**書き出しそのものはしていない**(パネルを自動操作しない約束)。
- 棚のフォルダ・中間のフォルダの「メタデータの編集…」「コレクションを作成」で「本ではありません」(下の修正 2 の後、メタデータは 1 文・コレクションは 2 文)。
- 「ファイルブラウザで開く」: コレクションの中から → このウインドウが切り替わり本が選ばれる。ビューアの右クリック・サイドパネルのフォルダブラウザの行・ファイルメニュー
  → 新規タブ(本のタブのすぐ右)で本が選ばれる。環境設定を「新規シークレットウインドウ」にすると「(シークレット) qooViewer」のウインドウで選ばれる。
  シークレットウインドウの右クリックはコレクション 2 項目とメタデータが淡色、書き出しとこのアプリケーションで開くは押せる。環境設定の行の見た目。
- ウインドウのタイトル(修正 3 の後): 起動時「QooStage8」→ 中へ「Sample Shelf」→ 上へ「QooStage8」→「コンピュータ」、本棚「ライブラリ」、コレクションの中「Sample Shelf」、
  本のタブ「Loose Book.cbz」と「ファイルブラウザで開く」のタブ「QooStage8」が並ぶ。
- リーク: ファイルブラウザのタブ 3 枚を閉じたあと、シークレットウインドウを「ファイルブラウザで開く」で開いて閉じるのを 4 回繰り返したあと、どちらも `heap` で
  `AppState` / `FileBrowserState` / `FileBrowserOperations` が 2(本のウインドウ + 遅れて手放す 1)、`FileBrowserActions` が 1 で増えない。

**実機の検証で見つけて直したもの**:
1. **場面で変わるサブメニューの項目が、リスト・ツリー(AppKit)のメニューで押しても動かなかった**(コレクションに登録・このアプリケーションで開く・本の書き出しの全部)。
   閉包を載せる箱の action を `perform(_:)` と名付けていて、`#selector` が NSObject の `performSelector:` を指していた。`invokeAction(_:)` に改名。
   `FileBrowserIntegrationTests.appKitDynamicMenuItemsReachTheirActions` でメニューを組み、action が NSObject のメソッドでないことを確かめる(元の名前に戻すと失敗することを確認済み)。
2. 「本ではありません」の説明の 2 文目(本が並んだフォルダを選ぶと中の本が入る)がメタデータ・書き出しにも出ていた。コレクションの操作だけに出す(文言 1 件を追加)。
3. **ウインドウ・タブのタイトル**(ユーザー要望): `Models/WindowTitle.swift` と `ContentView.windowTitle`。ファイルブラウザの上の段の名前と同じ関数を使う。

**確かめていないもの**: 書き出しを最後まで(保存先を選ぶ必要がある)、「その他…」でアプリを選んで開くこと(サンドボックスの `kLSAppDoesNotClaimTypeErr`)、実際に他のアプリで開くこと、
ツリーの右クリックの 5 項目、ページのサムネイル・履歴・お気に入り・ライブラリのツリーからの「ファイルブラウザで開く」(同じ環境値の経路で、サイドパネルのフォルダブラウザで確認済み)、
すりガラス 2 条件(追加した UI はメニュー・シート・アラート・環境設定の行で、不透明に描かれる)、英語表示、名前を変えたライブラリ/コレクションでタイトルが追従すること。

**次に着手する候補(順番はユーザーに選んでもらう)**:
1. 段階 8.5(読み取り専用モード)
2. 本の書き出しの zip の日時(§6.1)
3. §8.2・§7.1・§7.2 の「確かめていないもの」の実機確認(書き出しを最後まで・「その他…」で開く・英語表示・すりガラス 2 条件など)

**分かった罠**(docs/12 に追記): 閉包を載せたメニュー項目はテストでは押されない / 結果が画面に出ない操作はストアを `sqlite3 -readonly` で読む /
保存先のパネルを撮った画像は見ずに消す / ウインドウのタイトルは AX の `name of windows` で読める。

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

**実装済み・自動テスト済み(2026-09-14)。いま入っているものの説明は [docs/15「読み取り専用モード」](../15-file-browser.md)。** 上の箇条は立案時の計画のまま残す。

### 8.5.1 引き継ぎ(段階 8.5 の実装の完了時点、2026-09-14)

**ブランチの状態**: `feature/file-browser` にコミット・プッシュ済みで作業ツリーはきれい(2026-09-14、ユーザー指示。§8.2 の `bb2ea14` の次のコミット)。
Debug の全テスト(1276 件)、CI と同じ `-configuration Release QOO_CI_WARNINGS_AS_ERRORS=YES` のビルド、`scripts/ci/check-all.sh` が通る。
CHANGELOG `[Unreleased]`(ファイルブラウザの項目の「最初は読み取り専用」と環境設定の行)・MANUAL(9 章「読み取り専用」、25 章の表)・README(機能一覧)・
CLAUDE.md(アーキテクチャの段落)・docs/15・docs/12 はここまでの内容に揃っている。ファイルブラウザ自体が未リリース(`[Unreleased]`)なので、
「段階 4 からの書く操作を使っていた人への知らせ」は要らなかった(ファイルブラウザの項目の中に書いた)。`MARKETING_VERSION` は触っていない。

**ユーザーが決めたこと(2026-09-14)**: 実機で見つけた問題を直してから、ドキュメントを更新してコミット・プッシュする。

**ユーザーが決めたこと(2026-09-14)**: 次に着手するのは段階 8.5(§8.2 の候補から)。

**入れたもの**:
- `AppPreferences.fileBrowserReadOnly`(既定 true)と環境設定「ファイルブラウザ」の先頭の節「ファイル操作 ▸ 読み取り専用」。
  `keys(for: .fileBrowser)`・`resetToDefaults`・`AppPreferencesTests` の画面の一覧・`AppPreferencesProbe` を揃えた。文言 3 件を xcstrings へ手で足した。
- `FileBrowserOperations.isReadOnly` と、書く操作 12 の入り口の `guard`(undo / redo / cut / paste / transfer / drop / moveToTrash / newFolder / rename /
  bulkRename / compress / extract)。
- `FileBrowserActions.allowsFileChanges` / `canChange` / `canCreateFolder`、`canPaste` と `canCompress` に読み取り専用を足した。右クリックの淡色と `canPerform`。
  `FileBrowserEditResponding` に `allowsFileChanges` を足した(リストの名前の欄・出し口のマスクが読む)。
- メニューバー: 「新規フォルダ」と取り消し/やり直しを `ContentView` の `MenuCheckmarkState` で淡色。
- D&D: `FileBrowserDropDecision.make(allowsFileChanges:)`、`fileBrowserDragSourceMask`(`FileBrowserTableView` / `FileBrowserOutlineView` の上書き、
  アイコン表示の取っ手)。
- テスト: `FileBrowserOperationsTests`(4 件)・`FileBrowserIntegrationTests`(1 件)・`FileDropPlanTests`(2 件)。既存の 2 つの Fixture は OFF にした。
  入り口の判定を常に false にすると新しいテストが落ちることを確認済み。

**計画から変えた点**:
- **アプリの外への D&D は、ON の間はコピーだけ**(計画は「元を変えない」として許すままだった)。出し口が移動を許すと、Finder へ落としたときに
  Finder が同じボリュームの項目を移動する(§4b のコメント、実機 2026-09-14)。
- 環境設定の行は先頭に置いた(既定 ON なので、ファイルを変えたい人が最初に探す場所)。
- 読み取り専用であることを画面(操作列・パスバー)には出していない。**出さないことにユーザーが決めた(2026-09-14、§8.5.3)。**

**(実機の確認前に書いた)確かめていないもの**: 環境設定の行の見た目と英語表示、切り替えたときに右クリック(リスト・アイコン・ツリー)と
メニューバーがすぐ淡色になるか、リストで選んだ行をクリックしても名前の編集が始まらないこと、アイコン表示の名前のクリック、⌘⌫・⌥⌘V・⌘X が何もしないこと、
Finder へのドラッグがコピーになること(`draggingSession(_:sourceOperationMaskFor:)` の上書きが NSTableView / NSOutlineView で本当に使われるか)、
外からのドロップ(環境設定が「コピー・移動」)が禁止のカーソルになり、ウインドウ全体の「本を開く」へ落ちないこと、ON のまま ⌘Z をテキスト欄で押したとき
(取り消しの項目が淡色なので、以前から積まれていないときと同じ)。

**実機で確かめたこと(2026-09-14、scratchpad へ素の `build` をした Debug・空の本棚・使い捨て APFS 1 本に合成名。後始末で Application Support・
Caches・defaults が控えと一致、ボリュームは外した)**:
- 環境設定の行(日本語・英語)と説明のポップオーバー。既定(キー無し)で ON。
- ON: リストの右クリックで名前を変更・カット・ペースト・ゴミ箱に入れる・圧縮・展開が淡色、コピー・コレクション・このアプリケーションで開く・メタデータ・
  書き出しは押せる。ツリーの右クリックは新規フォルダ・ペーストが淡色(ペーストボードにファイルがある状態で)。メニューバーの新規フォルダ・取り消す・
  やり直す・カット・ペーストが淡色、コピーは押せる。⌘C はペーストボードに載り、⌘X・⌘⌫・⌥⌘V・⌘V ではファイルが変わらない。
- 環境設定で切り替えると、開き直さずに右クリック・メニューバーが追従する(OFF で全部押せる → ON で淡色)。
- 名前の編集: ON では選んだ行の名前のクリック(2 回)でもアイコン表示の名前のクリックでも始まらない。**対照として OFF では同じクリックで始まる**ことを確認。
- Finder へのドラッグ: ON で同じボリュームの `Drop Target` へ落とすと**コピー**(元が残る)。対照の OFF では**移動**。
- Finder からのドロップ(環境設定「コピー・移動」): ON ではリストのフォルダの行・リストの空き・アイコン表示の空きのどれも強調されず何も運ばれず、
  本のウインドウも開かない。対照の OFF ではフォルダの行が強調されて移動された。

**実機で見つけて直したもの**(説明は docs/15「実機で見つけて直したもの(段階 8.5)」):
1. **アイコン表示(SwiftUI)の右クリックで、サブメニューを持つ「圧縮」「展開」の親項目が淡色にならなかった**(中の項目は淡色で押せない)。
   `.contextMenu` の中の `Menu` には `.disabled` が効かない(scratchpad の最小の再現アプリで 10 通りの書き方を並べて実測。検索では事例が見つからなかった)。
   淡色のサブメニューは押せない `Button` で描く(`FileBrowserDisabledSubmenu`)。場面で変わるサブメニュー(`FileBrowserMenuNode.submenu`)も同じ。
   実機でアイコン表示の「圧縮」「展開」が淡色になったことを確認。
2. **アイコン表示で右クリック → サブメニューを開く → Esc 2 回、のあと、リストの右クリックが開かず、選ばれていない行のクリックで名前の編集が始まった**
   (読み取り専用でも。確定しても入り口が断って名前は変わらなかった)。ログで測ると、ウインドウはキーのままで、リストの `hitTest` が
   `validateProposedFirstResponder` を尋ねずに名前の欄を返し、表の `mouseDown` / `rightMouseDown` / `menu(for:)` が呼ばれていなかった
   (通常は尋ねて表を返す)。最初は「ウインドウがキーでない」と見立てたが、System Events の `focused` がキーのウインドウでも false を返していただけだった。
   `FileBrowserTableView.hitTest` で同じ判定を確かめ直して表を返す、`FileBrowserOutlineView.hitTest` は行の文字の欄を当たり先にしない。
   実機で同じ手順のあと、リストの右クリックが開く・選ばれていない行のクリックは選択だけ・ツリーのフォルダの行の右クリックが開く・ツリーの行のクリックで移動・
   OFF で選んだ行の名前のクリックから編集が始まる・編集中の欄の中のクリックで編集が続く、を確認。AppKit のどの内部状態が判定を飛ばさせるのかは分かっていない。
3. 「ツリーのボリュームの行には右クリックのメニューが出ない」と書いたのは、2 の状態で試していたため(ボリュームの行も `url` を持ち、`Node.entry` は nil にならない)。
   ボリュームの行そのものでは直した後に実機で試していない。

**テスト**: `FileBrowserTreeAndIconHitTests` に `resolvedHit` の 2 件(判定を外すと落ちることを確認済み)。SwiftUI の右クリックの淡色はテストしていない
(`.contextMenu` の中身を外から読めない)。

**コミットの後にユーザーが見つけて直したもの(2026-09-14)**: よく使う項目の見出しの「＋」にカーソルを合わせると下向きの矢印が出て「＋」がずれた。
`.sourceList` のグループ行が出す開閉の印で、`shouldShowOutlineCellForItem` が見出しにも true を返していた。見出しには出さない(docs/15「ツリーの三角」)。
ユーザーが Xcode の実行で直ったことを確認。**テストは手元で流していない**(ユーザーが Debug を Xcode から動かしている最中で、テストのホストが
同じ bundle id で起動するため)。CI の Debug のジョブで流れる。

**確かめていないもの**: ボリュームの行の右クリック(上の 3)、すりガラス 2 条件(足した UI は環境設定の行・メニューの項目で、不透明に描かれる)、
シークレットウインドウでの読み取り専用、ON のまま ⌘Z をテキスト欄で押したとき(取り消しの項目が淡色なので、以前から積まれていないときと同じはず)。

**気づいているが直していないもの**:
- アイコン表示の淡色のサブメニューには矢印が出ない(リスト・ツリーの AppKit のメニューは淡色の矢印が出る)。SwiftUI で淡色の `Menu` を描く手段が無いため。
- ⌘C の検証で Debug からクリップボードへ書いた内容は戻せない(実機検証の副作用。検証の手順に書くほどではない)。

### 8.5.2 引き継ぎ(段階 8.5 の後の要望 4 件、2026-09-14)

**ブランチの状態**: `feature/file-browser` にコミット・プッシュ(ユーザー指示)。変更したファイルのテスト(`FileBrowserStateTests`・
`FileBrowserIntegrationTests`・`SidePanelBrowserStateTests`・`AppPreferencesTests`、70 件)と `scripts/ci/check-all.sh` が通る。全テストは手元で流していない(CI の Debug のジョブで流れる)。

**入れたもの**(説明は docs/15「一覧の読み込み」「リストの列」「右クリック」「保存するもの」):
1. 並べ替えの基準と向きをサイドパネルのフォルダブラウザと共通にした(`AppPreferences.folderBrowserSortKey` / `…Direction`)。「フォルダを上に」は別のまま
   (ユーザーには別のままにしたことを伝えてある。同期したいと言われたら `fileBrowserFoldersFirst` と `sidePanelSortOrder` の関係を決め直す)。
2. リストの見出しの右クリックで列の表示/非表示。**作成日は既定で隠す**(作業中にユーザーが決めた)。
3. 列のドラッグでの入れ替えは元から効いていた。名前の列を先頭に固定した。
4. フォルダ・ツリーの右クリックに「よく使う項目に登録」(登録済みなら淡色)。文言 1 件を xcstrings へ手で足した(ja「よく使う項目に登録」)。

**実機で確かめたこと**(Debug ビルド。AX で見出しの題・位置とメニューの項目を読むだけ、画面は見出しのメニューの部分だけを撮った。defaults は控えと一致させた):
作成日の列が既定で隠れる、「種類」の見出しのドラッグで列が入れ替わる、名前の列はドラッグしても動かず他の列も前へ入らない、見出しの右クリックのメニュー
(並び順・チェック・名前は淡色)、「作成日」を選ぶと列が出て保存も変わる、未登録のフォルダの行の右クリックに「よく使う項目に登録」が押せる状態で出る。

**確かめていないもの**: 「よく使う項目に登録」を実際に押したとき(テストのみ)、アイコン表示とツリーでの項目の見え方、サイドパネルとファイルブラウザを
並べて並べ替えを変えたときの追従(テストのみ)、見出しのメニューの英語表示、すりガラス 2 条件(AppKit 標準のメニューで不透明)。

**次に着手する候補(順番はユーザーに選んでもらう)**:
1. 本の書き出しの zip の日時(§6.1)
2. 段階 9(検証と文書)。§8.5.1・§8.2・§7.1・§7.2 の「確かめていないもの」を含む
3. 読み取り専用であることを画面(操作列など)に出すか(淡色だけで伝わるか、ユーザーに見てもらってから)

**ユーザーに頼むこと**: ふだんの使い方で、読み取り専用の ON/OFF を切り替えて、淡色の項目だけで「いま操作できない理由」が分かるかを見てもらう。

### 8.5.3 引き継ぎ(本の書き出しの zip の日時、2026-09-14)

**ユーザーが決めたこと(2026-09-14)**: §8.5.2 の候補から「本の書き出しの zip の日時」を先にやる。

**ブランチの状態**: `feature/file-browser` にコミット・プッシュ(2026-09-14、ユーザー指示)。CHANGELOG `[Unreleased]` の「修正」に 1 行、docs/08・docs/15 を更新。MANUAL・README・CLAUDE.md は書き出す日時に触れていないので変えていない。

**入れたもの**: `CbzExporter` / `EpubExporter` / `ShelfCoverArchive`(コレクション表紙の zip。同じ問題を持っていたので一緒に直した)の `addEntry` が
`modificationDate: ZipDOSTime.zipFoundationDate(forLocal: Date())` を渡す。書く日時は従来どおり「書き出した時刻」(元のページの日時は写さない)。
テストは 3 つの suite に 1 件ずつと `ExportedZipTimestamps`(`Support/ExportHarness.swift`)。**直す前のコードで 3 件とも落ちることを JST で確認済み**。
時差 0 の CI のランナーではずれが出ないので、直す前でも通ってしまう(タイムゾーンは共有状態なのでテストから変えない)。

**テスト**: `CbzExportTests`・`EpubExportTests`・`ShelfCoverArchiveTests`・`ShelfCoverImportTests`・`LibraryImportTests`(78 件)と `scripts/ci/check-all.sh`。全テストは手元で流していない。

**確かめていないもの**: 書き出した cbz / epub を Finder・`unzip -l` で見たときの日時(テストは同じ ZIPFoundation での往復と、直す前に落ちることだけ)。

**`9666a25` での全体の確認(2026-09-14)**: §8.5.1 の後の 3 コミットは全テストを手元で流しておらず、「CI の Debug のジョブで流れる」と書いたが
CI はこのブランチでは手動起動(`workflow_dispatch`)の 2026-09-13 の 1 回しか走っていなかった。手元(JST)で Debug の全テスト(1282 件・123 suite、失敗・スキップ無し。
使い捨てボリュームはスキームの後処理で外れた)、CI と同じ `-configuration Release QOO_CI_WARNINGS_AS_ERRORS=YES` のビルド、`scripts/ci/check-all.sh` が通った。

**次に着手する候補**: 段階 9(検証と文書。§8.5.1・§8.2・§7.1・§7.2 の「確かめていないもの」を含む)。

**ユーザーが決めたこと(2026-09-14)**: 読み取り専用であることを画面(操作列・パスバーなど)には**出さない**。淡色の項目だけで伝える(§8.5.2 の候補 3 と「ユーザーに頼むこと」はこれで閉じた)。

### 8.5.4 引き継ぎ(「コレクションに登録」の知らせと、ブランチ全体のコード監査、2026-09-14)

**ブランチの状態**: `feature/file-browser` にコミット・プッシュ(2026-09-14、ユーザー指示)。この節と一緒に、右クリックの「コレクションに登録」の
知らせ(`FileBrowserState.showToast` → `Views/OverlayToast.swift`。ビューアのお気に入り/ブックマークのトーストと同じ見た目に共通化、
`FileBrowserLibraryActions.addedToCollectionMessage` に文の出し分け、`FileBrowserIntegrationTests` に文の判定)を入れた。CHANGELOG には足していなかった
(2026-09-14 の 4・5 の修正のコミットで、「ドキュメントを更新」の指示により CHANGELOG・MANUAL の登録の行に足した)。docs/15「右クリック」と §8.1 の「確かめていないもの」は更新済み。

**コード監査(2026-09-14、ユーザー指示)**: ブランチで足した/変えたコード全体を、資源リーク・クラッシュ・ハング・ファイルの破損と消失・
メモリとディスクの過大な消費に絞って監査した。方法は、ファイル操作エンジンの精読 + 独立した 5 系統の読み合わせ(エンジンの二重監査・UI 層・
状態と監視の層・サムネイル層・既存サービスの差分)で、疑わしいものは**実測**で裏を取った。実測の道具は 2 つ:
`qooViewerTests/FileOperations/` に一時テスト(`Issue.record` で結果を出す)を置いて
`xcodebuild … -only-testing:qooViewerTests/<Suite> test` で回す(スキームの Pre-action が使い捨てボリュームを付ける。1 回 2〜3 分。**終わったら消す**)、
および `swift` で直接走らせる小さなスクリプト(`copyfile`・`removeItem`・`trashItem`・`recycle` の素の挙動)。監査で実測したプラットフォームの事実は
その場で確かめたものなので、直すときはもう一度同じ手で確かめる。

**見つかったもの(重い順。すべて 2026-09-14 に直した ―― 下の「1〜3 の修正」「4・5 の修正」「6 以降の修正」。10 の `heap` による確認だけが残っている)**:

1. **【最重要・実測で消失】別ボリュームへの移動で、元の削除が途中で失敗すると宛先の完全なコピーまで消す**
   (`FileOperationService.moveItem`、`removeAbsorbingTransientFailure(at: source)` の catch で `removePartialWrite(at: target)`)。
   `FileManager.removeItem` は木の削除が途中で失敗しても消した分を戻さない(実測)。実測(APFS の使い捨てボリューム): `01〜05.cbz`・`zz.cbz`・
   `uappnd` フラグ付き `log.txt` を含むフォルダを移動 → 元も宛先も `log.txt` だけになり **6 ファイルが消失**(ゴミ箱にも無い)。
   `MoveFilesCommand.undo`(逆向きの別ボリューム移動)も同じ経路。現実の引き金: SMB で他のクライアントやこのアプリ自身(開いている本)が
   掴んでいるファイル(EBUSY / ENOTEMPTY は再試行しない)、途中で現れた `.DS_Store`、`uappnd`・ACL の付いた子。
   **直し方**: 元の削除を始めた後は宛先を消さない。削除に失敗したら**コピーを残して**「コピーは済んだが元を消せなかった」と報告する
   (受領書は返す)。ついでに `lockedItems` が見るのを `UF_IMMUTABLE` だけでなく `UF_APPEND` にも広げるかは検討。
2. **【実測】フォルダのコピー/移動が途中で失敗すると、宛先に中途半端な木がその名前のまま残る**(`carry` の catch は退避の復元だけ、
   `restoreReplacedItem` は退避が無ければ `removePartialWrite` の前に return。中止のときだけ片付けている)。
   **同じ実測で分かった別の欠陥**: 中身のある 0555 のサブフォルダを含むフォルダのコピーが、同一ボリュームでも別ボリュームでも EACCES で失敗する。
   原因は `COPYFILE_CLONE | COPYFILE_RECURSIVE` の組み合わせ(`FileCopyEngine.copy`)で、CLONE 無しなら同じ木を写せる(`swift` スクリプトで実測)。
   読み取り専用メディアから戻したフォルダで普通に起きる。**直し方**: エラー時も宛先の書きかけを消す(1 の条件下では消さない)。
   CLONE で EACCES なら CLONE 無しで試し直す(要実測)。
3. **「置き換える」の退避の記録が、退避先のボリュームが外れた状態で起動すると捨てられる**(`ReplaceBackupJournal.recoverAll`:
   `itemExists(at: backup)` は lstat なので未マウントでも false → `alreadyClean` → 記録を消す)。繋ぎ直しても元の項目は
   `.qooViewer-replace-<UUID>/` に隠れたまま二度と知らされない。`restoreReplacedItem` は「次は繋がっているかもしれない」と記録を残すのに、
   起動時の復旧がそれを打ち消している(`ReplaceBackupJournalTests` の「退避が無ければ記録だけを捨てる」がこの挙動を固定)。
   **直し方**: 退避先の親フォルダが実在する(`MountTable.isOnAnUnmountedVolume` が偽)ときだけ忘れる。
4. **現在のフォルダの配下全体の FSEvents で一覧を読み直す**(`FileBrowserState` の `FolderChangeWatcher(onChange:)` はパスを見ずに `reload()`)。
   FSEvents は渡したパスの階層全体のイベントを返すので、ホーム(既定の起動フォルダ)や `/` を表示している間は `~/Library` 配下の書き込みで
   0.3 秒ごとに再列挙が走り続ける。`reload()` は前の列挙を取り消す(列挙は 256 件ごとに中断)ので、列挙に 0.3 秒以上かかるフォルダの配下で
   ダウンロード/バックアップ/コピーが続く間は**一覧が永遠に出ない**(livelock)。ツリー側は `onChangedPaths` で親を突き合わせているので同じ形にする。
   付随: ネットワーク上のフォルダも見張ろうとし、応答しない共有では `FSEventStreamCreate` が `Task.detached`(協調プール)で最大 30 秒塞ぐ
   (`MountTable.isRemote` なら `watch([])` でよい)。`lastEventID` を別のパスの組にも引き継ぐ(`kFSEventStreamCreateFlagFullHistory`)ため、
   移動のたびに新しいフォルダの履歴が再生される(パスの組が変わったら `SinceNow` へ戻す)。
5. **リスト表示で名前を編集中に一覧が変わると、別のファイルの名前を変える**(`FileBrowserListView.Coordinator.update`: 編集中は `reloadData()` を
   先送りするのに `entries` は差し替える。`controlTextDidEndEditing` が `table.row(for:)` = 古い行番号で新しい `entries` を引いて `rename`)。
   引き金は編集中の `reload()`(4 の配下全体の FSEvents、アプリの再アクティブ化、ボリュームの着脱、他ウインドウの操作)。
   `applySelection` / `scrollRowToVisible` も同じ添字ずれ。**直し方**: 編集中は `revision` / `entries` の取り込み自体を先送りし、`finishEditing` で
   取り込み → `reloadData` → 選択の反映をまとめて行う。

中程度:

6. サムネイルが iCloud 等の**追い出されたファイルをダウンロードさせる**: 動画だけ `VideoThumbnailer.isDataless` を見て、書庫・画像・PDF・EPUB・
   フォルダの経路(`BookThumbnailer.thumbnail`)には検査が無い。「ストレージを最適化」したデスクトップをアイコン表示で開くと 4 本並列で落ちてくる。
7. フォルダを表示しただけで zip の**伸長爆弾**を踏む: `BookThumbnailer.decodeEntry` は宣言サイズを見てから `data(at:)` で全部伸長し、後から
   `count` を見る。`dataPrefix(at:maxByteCount:)` で `maxEntryBytes + 1` を読めば上限が本当に効く(`PageLoader.rawData` も同じ形だが、
   あちらは本を開く操作が要る)。
8. 「置き換える」で退避のゴミ箱送り(`FileManager.trashItem`)が失敗すると、元の項目を確認なしに完全削除する(`carry`)。
   実測では新品の exFAT / FAT32 / APFS でも `trashItem` は `.Trashes/501/` を作って通り、ロックされた子を含むフォルダも送れる
   (項目自身が `uchg` なら -5000)ので発生確率は低いが、失敗したら退避と記録を残す側に倒すべき。
9. `controlTextDidEndEditing` が 2 度届くと**表示名への改名**を積む(要実測): `finishEditing` で欄を表示名に戻してから `makeFirstResponder(table)` を
   呼び、再入の防護が無い(`isCancellingEdit` は Esc だけ)。ローカライズされたシステムフォルダ・拡張子を隠したファイル・`.app` で実名と違う名前へ
   `rename` されうる。コンテナ内のログで 2 度目が来るかを確かめ、来なくてもフラグ 1 つで塞ぐ。
10. `.contextMenu` の中で `FileBrowserState` への Binding(`FileBrowserBackgroundMenuItems` の `$state.viewMode` など)、`FileBrowserActions` が
    `OpenWindowAction` を保持。CLAUDE.md の relay 規則の例外で、`entries`・取り消し履歴がウインドウより長生きしうる。`heap` で確認する。
11. メインアクター上の LaunchServices 問い合わせ(`OpenWithApplications`: 右クリックとアイコン表示のセルごと。拡張子の無いファイルはパスごと)。
    応答しない共有の項目でメインが待たされうる。`FileIO` の上で作って結果だけを覚える形にできる。
12. サムネイルの鍵の `tv_sec * 1_000_000_000`(`FileBrowserThumbnailKey.of`)が桁あふれでトラップ。APFS は mtime をクランプするので起きないが、
    SMB / NFS / 他社ドライバの壊れた日時では落ちる。`multipliedReportingOverflow` か、秒と ns を別々に文字列へ。

軽微(直すなら 1〜12 の後):
環境設定の MB 値の `Int(Double)` が NaN / 範囲外の plist で起動時にトラップ(`AppPreferences`、既存列も同形)。取り消し/やり直しのたびにツリーの
閉じた行の数だけ `FileIO` スレッドを同時に起こす(`reloadExpandedRows(in: nil)`)。`FileBrowserDragTracker` の残留だけで「アプリ内のドラッグ」を
判定する脆さ(AppKit 側は `draggingSource` で確かめられる)。zip の索引作成が展開専用の descriptor を毎回全項目ぶん作る(`ZipArchiveReader.indexEntries`)。
補正後パスが重複する 2 エントリで 1 つ目に 2 つ目の中身が入る(zip だけ last-wins)。`withLocksLifted` が同一ボリュームの移動でも木を全部歩き、
別ボリュームの移動は木を最大 6 回歩く。ハードリンクの兄弟への `rename` が成功扱いの no-op。PDF の box が非有限なら `Int(NaN)` でトラップ
(`BookThumbnailer.render`、`PageLoader` も同形)。`RetaggedHEVCThumbnailLoader` の期限待ちが呼び出し側の取り消しを見ない。先読み役がフォルダごとに
`MountTable.current()`。EPUB の絵で spine 全部の XHTML を読む。

**実測で否定した疑い**(直す必要なし): exFAT / FAT32 への xattr 付きフォルダの移動・コピーが AppleDouble(`._*`)の分で「変更された」と断られる
→ 両方成功した(カーネルが `._*` を隠す)。新品のボリュームで `FileManager.trashItem` が失敗する → 通った。`NSWorkspace.recycle` の対応表の鍵が
渡した URL と一致しない → 末尾 `/` の有無ごと一致した。

**監査で問題なしと確認した範囲**: 退避の記録 → 作成の順序と失敗時の巻き戻し、`RENAME_EXCL` / `COPYFILE_EXCL` / `O_EXCL | O_NOFOLLOW` による
上書き防止、記号リンクの不追従、ゴミ箱の無い場所の確認と完全削除の分離、`FileIdentity` による取り消しの取り違え防止、展開の Zip Slip 対策・限度・
一時フォルダ・中止の片付け、圧縮の一時名と縮み/伸び検出、一括リネームの衝突回避、`FileIO` / `Cancellation` / `withDeadline`、`MountTable`、
監視の寿命(`releaseResources` / `dismantleNSView` / weak 参照)、サムネイル提供役の並行制御、Matroska / EBML パーサの境界、QuickLook / 再タグ付けの
資源解放、ディスクキャッシュ、zip の日時補正の往復、`@Model` の変更が無いこと。

**1〜3 の修正(2026-09-14、ユーザー指示「致命的な不具合をまず修正」)**: コミット・プッシュ済み(`b5b24b1`)。
- 1: `moveItem` は元の削除に失敗しても宛先を消さず、`FileCopyEngine.Outcome.copiedButSourceRemains` を返す。`carry` は受領書を返し、
  `transfer` は `FileOperationError.sourceRemainsAfterMove` の文を失敗に積んで止まる(残りは unprocessed)。`withLocksLifted` はこのとき
  宛先と元の両方で掛け直す。取り消しは元に同じ名前が残っているので「両方残す」で `name 2` へ戻り、部分的な取り消しとして報告される(消失はしない)。
  `lockedItems` を `UF_APPEND` へ広げるのは見送った(広げなくても消失はしなくなった。確認の文言が「ロック」なので意味もずれる)。
- 2: `FileCopyEngine.copy` が失敗時に書きかけを消す(errno が EEXIST で、かつ callback が頂点より下へ進んでいないときだけ残す)。
  EACCES で、元の木に持ち主の書き込み権の無いフォルダがあれば、CLONE 無しで 1 回だけやり直す(1 回目に報告したバイト数は差し引く)。
  部分的な木の削除は 0555 のサブフォルダを含んでも通ることを `swift` スクリプトで再確認(失敗時点の木は中身が入る前なので書ける)。
- 3: `ReplaceBackupJournal.presence(of:mounts:)` で、lstat が ENOENT / ENOTDIR かつ `isOnAnUnmountedVolume` が偽のときだけ `.absent`。
  それ以外(外れたボリューム、EPERM / EACCES)は `.unreachable` で記録を残し、`ReplaceBackupRecovery` は知らせない。
- 回帰テスト: `FileOperationVolumeTests` に 3 件(`uappnd` の子を含むフォルダの別ボリューム移動 / 0555 のサブフォルダを含む木の同一・別ボリュームへの
  コピー / 読めないファイルを含むフォルダのコピーと移動で書きかけが残らない)、`ReplaceBackupJournalTests` に 1 件(外れたボリューム上の記録)。
  **修正前のコードで 3 件とも失敗し、修正後に通ることを確認した**。全体 1287 件成功、`check-all.sh` 成功。

**4・5 の修正(2026-09-14、ユーザー指示)**: コミット・プッシュ済み(この節と同じコミット)。
- 4: `FileBrowserState` の見張りを `FolderChangeWatcher(onChangedPaths:)` にし、`changedPaths(_:touchFolderSpelledAs:)` でフォルダ自身か直下の
  項目のときだけ読み直す(`/System/Volumes/Data` の頭は外し、`watchedFolderSpellings` で `/private` 付きの書き方も持つ。`pathOutsideDataVolume` は
  ツリーから `FileBrowserState` へ移した)。読み込み中に届いたら `needsReloadAfterLoad` を立て、同じ世代の読み込みが終わったら 1 回だけ読み直す
  (取り消さない = livelock しない)。ネットワーク上のフォルダは `watch([])`、ツリーの `watchedRoots` もネットワーク上の行を外す。
  `FolderChangeWatcher.stopStream` の `lastEventID` は `FSEventsGetCurrentEventId()`(プランの「SinceNow へ戻す」ではなく、止めた時点の ID ―― 残るパスの
  空白を埋めたまま、新しいパスの再生を止めてから始めるまでに限る)。**実機では確かめていない**(ホームを表示してダウンロードを続ける、など)。
- 5: `FileBrowserListView.Coordinator.update` は編集中なら一覧・カット・選択・スクロール・名前の依頼の取り込みをすべて待たせ(`needsReloadAfterEditing`)、
  `finishEditing` で `syncWithState` にまとめて取り込む。確定では欄の `editingName` と `entries[row]` の実名を突き合わせる。9(2 度目の
  `controlTextDidEndEditing`)も `isFinishingEdit` で塞いだ(2 度目が実際に来るかはログで確かめていない)。
- 回帰テスト: `FileBrowserListEditingTests`(**修正前のコードで b.txt の名前を変えて失敗し、修正後に通ることを確認**)、`FileBrowserStateTests` に 2 件
  (読み直す範囲、`/private` の書き方)。全体 1290 件成功、`check-all.sh` 成功。

**6 以降の修正(2026-09-14、ユーザー指示「監査指摘事項 6 以降を修正」)**: コミット・プッシュ済み(この節と同じコミット)。
- 6: `BookThumbnailer.make(of:kind:maxPixelSize:)` が `Outcome`(`.image` / `.unavailable` / `.notDownloaded`)を返す。項目そのもの・フォルダの中の先頭の
  画像が `SF_DATALESS` なら `.notDownloaded`(提供役は「作れなかった」と覚えない)。読み取り全体を `DatalessFiles.withoutDownloading`
  (`setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, OFF)`、終われば元へ)で包み、取りこぼしもダウンロードにしない。
  `VideoThumbnailer.isDataless` は `DatalessFiles.isDataless` へ寄せた。**本物の追い出されたファイルでは確かめていない**(テストで作れない)。
- 7: `BookThumbnailer.decodeEntry` は `boundedEntryData` で、宣言サイズに加えて `readEntry` のチャンクを数え、64MB を超えた時点で打ち切る
  (`dataPrefix` は rar が全体読みに落ちるので使わない)。ついでに EPUB の絵は `EpubStructureResolver.resolve(reader:maxPages: 1)` で先頭 1 ページで止める(軽微の列)。
- 8: `carry` は、ゴミ箱のある場所で退避をゴミ箱へ送れなければ消さずに退避と記録を残し、`FileOperationError.replacedItemKept` の文を失敗に積んで止まる
  (`Carried.sourceRemains` を `problem` に改めて両方を運ぶ)。完全削除へ落ちるのはゴミ箱の無い場所だけ。
- 10: 空きスペースの右クリックの「表示」「表示順序」の Binding を `FileBrowserState` を weak で捕まえる閉包で作る。`FileBrowserActions.openWindow`
  はペインの `onDisappear` で外す(`onAppear` の `connectActions` が付け直す)。**`heap` での確認はしていない**(実物のアプリでウインドウを開閉する必要がある)。
  `.contextMenu` の中の `FileBrowserContextMenuItems` が `FileBrowserActions` を強く持つのは残した(相手は全部 weak、残る値は `collectionMenuCache` だけ)。
- 11: `OpenWithApplications` は `urlsForApplications(toOpen: UTType)` で引く(ファイルに触らない)。種類は名前だけで決める(`contentType(for:isDirectory:isPackage:)`:
  中へ入れるフォルダは `.folder`、パッケージ・ファイルは拡張子の種類、拡張子の無いファイルは `.data`)。覚える鍵もパスごとをやめた。
  失うもの: 1 ファイルだけに付けた既定のアプリの「(既定)」表示と、拡張子の無いファイルの中身での見分け。
- 12: `FileBrowserThumbnailKey.of` の更新日時を `&*` / `&+` で作る。
- 軽微の列:
  - 環境設定の MB 値は読むときに `storedMegabytes`(数でない・非有限なら既定値、範囲外は端)で収め、バイトへの換算も `clampedMegabytes` を通す(NaN は `min`/`max` を素通りする)。
  - ツリーの閉じた行の調べ直しを 1 本の `FileIO` にまとめた(`reprobe(_ nodes:)`)。
  - AppKit の受け口は `info.draggingSource == nil`(他のアプリから)なら `FileBrowserDragTracker.end()`。SwiftUI の側は手当てできていない。
  - `ZipArchiveReader`: 同じ補正後パスは先のエントリを採る(rar / 7z と同じ)。`entriesInArchiveOrder` の descriptor は初めて頼まれたときに作る。
  - `withLocksLifted`: 同じボリュームなら項目自身のロックだけを見る(木を歩かない)。別ボリュームの「木を最大 6 回歩く」は手を付けていない。
  - 名前の変更: 同じ inode でも、名前の違いが大文字小文字・正規化だけでなければ「自分自身」とみなさない(ハードリンクの兄弟への no-op の成功を止めた)。
  - PDF の箱: `CGRect.hasUsablePDFPageSize`(有限・正・1 辺 1,000 万 pt 未満)を `BookThumbnailer.render` と `PageLoader` の 3 箇所で使う。
  - `FileIO.withDeadline` が呼び出し元の取り消しを `operation` の Task へ渡す(`TaskCancellationRelay`)。`RetaggedHEVCThumbnailLoader` はこれで取り消しを見る。
  - 先読み役(`FileBrowserVideoThumbnailWarmer`)のマウント表は場所ごとに 1 回。
- 回帰テスト: `FileBrowserThumbnailTests` に 4 件(伸長しながら数える上限 / 実体化の方針が掛かって戻る / PDF の箱 / EPUB の先頭 1 ページ)、
  `FileOperationServiceTests` に 2 件(置き換えでゴミ箱へ送れないときに残す / ハードリンクの兄弟への改名)、`ZipEntryNameTests` に 1 件(同じパスは先のもの、展開も)、
  `AppPreferencesTests` に 1 件(壊れた MB 値)、`FileIOTests` に 1 件(期限付きの待ちへの取り消し)、`FileBrowserIntegrationTests` の「このアプリケーションで開く」の鍵を
  種類で引く形に書き換え。**修正前のコードでの失敗は確かめていない**(新しい口を使うテストが多く、修正前ではビルドできない)。全体 1299 件成功、`check-all.sh` 成功。
  1 回目の全体実行で既存の `FileIOTests`「呼び出し元タスクの取り消しは、借りたスレッドの上で Cancellation として見える」が 1 度落ち、2 回目は通った
  (この修正で触っていない `perform` のテスト。並行実行で協調プールが混んだときの揺らぎと見ている)。

**引き継ぎ(2026-09-14 時点。監査の 1〜12 と軽微の列を直し終えたところ)**:
- ブランチの状態: 1〜3 が `b5b24b1`、4・5(と 9)が `4ae1615`、6 以降が次のコミット(「ドキュメントを更新」の指示とともにコミット・プッシュ)。
  CHANGELOG `[Unreleased]` の「追加」(ファイルブラウザの項)に 8(置き換えた元をゴミ箱に入れられなければ隠し項目として残す)と 6(ダウンロードされていない
  本・画像の絵を作らない)、「修正」に既存機能へ効くもの 3 件(壊れた PDF の箱で終了・壊れた MB 値で起動時に終了・zip の同じ名前の画像は前のもの)を足した。
  MANUAL はアイコン表示・置き換え・「このアプリケーションで開く」の段落を更新。README・CLAUDE.md は変える記述が無かった。
- 確かめていないもの: 10 の `heap`(ウインドウを開閉して `FileBrowserState` が残らないこと)、6 の本物の追い出されたファイル、11 の「このアプリケーションで開く」の
  候補が実機で以前と同じ顔ぶれか(特に拡張子の無いファイル・パッケージ)、軽微の列のドラッグの記録の手当て(他のアプリからのドラッグ)。
  前回から持ち越し: 4 の実機、9 の 2 度目の `controlTextDidEndEditing`、1 の取り消しの報告の見え方。
- 測り方で分かったこと(前回から): リストの Coordinator は `NSHostingView` に載せずにテストできる(表を自分で組み、画面に出さないウインドウに入れればフィールドエディタも
  動く。`makeNSView` は `autosaveName` で `UserDefaults.standard` に列の幅を書くので載せない ―― `FileBrowserListEditingTests`)。テストに
  `/Users/<名前>/` の合成パスを書くと `check-private-terms.sh` が止める(`/Users/nobody` だけが許される)。今回: `setiopolicy_np` のスレッド単位の
  実体化の方針はサンドボックスのテストホストの中でも掛けられる。
- 監査の列で残したもの: 別ボリュームの移動で木を最大 6 回歩く(`preflight` の総量・ロック・コピー・確認の各段)、SwiftUI の受け口でのドラッグの記録の古さ。

**次に着手する候補(順番はユーザーに選んでもらう)**:
1. 10 の `heap` の確認
2. 段階 9(検証と文書)。上の「確かめていないもの」を含む

**ユーザーに頼むこと**: ふだんのホームをファイルブラウザで表示したまま、しばらく他のアプリでダウンロードやコピーを続け、一覧が出続けること・
名前の編集が途中で消えないことを実際のマウスで見てもらう。「ストレージを最適化」で追い出されたファイルのあるフォルダ(デスクトップ・書類など)を
アイコン表示で開き、ダウンロードが始まらないこと(Finder の雲のアイコンが残ること)を見てもらう。

## 段階 9. 検証と文書

- 実機検証は**使い捨てボリューム**(`hdiutil`)+ 合成名。手順を docs/12 に「ファイルブラウザ」の節として書く(TCC の確認手順、`tccutil reset`、
  スクリーンショットは実蔵書を写さない)。
- リーク: ウインドウを開閉して `heap` で `FileBrowserState` / `NSOutlineView` / `NSTableView` の残留が増えないこと(`dismantleNSView`)。
- すりガラス 2 条件(ダーク+白 100% / ライト+黒 100%)で全部品。
- 文書: docs/15(新規「ファイルブラウザ」: 構成・操作エンジン・Undo・圧縮展開・サムネイル・sandbox/TCC の約束)、docs/03(ウインドウごとのものに `FileBrowserState`、
  提示値 `WindowContentRequest`)、docs/06(保存先の一覧に追加)、docs/09(ウェルカム画面の節)、docs/10(TCC の節)、docs/13(経緯)、docs/README の表、
  CLAUDE.md(アーキテクチャの段落)、MANUAL、CHANGELOG `[Unreleased]`、README の機能一覧。**MARKETING_VERSION は触らない**(指示があるまで)。

### 9.1 引き継ぎ(段階 9 の文書化の完了時点、2026-09-14)

**ユーザーの指示(2026-09-14)**: 「段階 9 のドキュメント化を進めて」。検証(実機)はこの回ではしていない。コミットはしていない。

**ブランチの状態**: 作業ツリーに文書だけの変更。コードは変えていない。

**書いたもの**(段階 4〜8.5 の各回で docs/15・CHANGELOG・MANUAL・README は都度そろえてあったので、足りなかったものを埋めた):
- docs/15: 段階の表を現状に、「構成」の表に `FileBrowserOperations`・絵の 2 役・`ReplaceBackupRecovery`、**「操作エンジン(段階 2)」**(層の図と決めごとの表)、
  **「サンドボックスと TCC の約束」**(部品を足すときに当てはめる表と、書く操作のサンドボックスの事実)、**「シークレットウインドウ」**、「保存するもの」に
  絵のキャッシュと置き換えの記録、「既知の制限」を段階 3 時点のものから各節の制限を集めた一覧へ。
- docs/03: アプリ全体で 1 つのものに `FileBrowserVideoThumbnailWarmer` と `ReplaceBackupJournal` / `ReplaceBackupRecovery`。
- docs/06: ファイルブラウザの表示の状態の行を現状に(並べ替えは共通の `pref`、隠した列・一括リネームの入力)、置き換えの記録の行、シークレットウインドウの節に
  ファイルブラウザ。
- docs/10: 「Finder で開く」に「ファイルブラウザで開く」、**「ファイルブラウザ」の節**(15 の約束の要点)。
- docs/12: 「ファイルブラウザ」の冒頭に「まず守ること」と **TCC の確認の手順**(`tccutil reset` は Debug の bundle id に限る)、リークの `heap` の対象と閉じる前に通す操作。
- docs/13: 経緯の表に 9 行(三角・読み取り専用・外へのドラッグ・見張りの範囲・別ボリュームの移動・置き換えの退避・起動時の復旧・「このアプリケーションで開く」・淡色のサブメニュー)、
  既知の制限と未着手の項を現状に。
- docs/01(主な機能)、docs/02(段階 4 以降の suite は docs/15 の表へ)、docs/README(15 の説明)、CLAUDE.md(自分から中を読む部品の TCC・ネットワークの約束を 1 文)。
- MANUAL: 「いまの制限」に 4 項目、§26 にファイルブラウザ、§28 に Q&A 2 件、「まとめて名前を変更」の前の空行(前の箇条書きに続いてしまっていた)。
- README: サンドボックスの節にファイルブラウザ。CHANGELOG は変えていない(利用者に見える変更が無い)。

**文書化で気づいたこと 2 件 → ユーザーの判断で直した(2026-09-14、この節の次のコミット。「ドキュメントを更新」の指示とともにコミット・プッシュ)**:
- **シークレットウインドウでは絵をディスクキャッシュへ書かない**(ユーザー「保存しないことが期待」)。`FileBrowserThumbnailProvider.thumbnail(…, savesToDisk:)`、
  セルは `!state.isPrivate`。同じ仕事を待つセルの OR で書く。読むのは許し、メモリの絵は共有する(こちらで決めた)。`AppState.isPrivateWindow` のコメントに足した。
  テスト `FileBrowserThumbnailTests.providerDoesNotWriteToDiskForPrivateWindows`。
- **「すべてのデータを削除」で「置き換える」の記録を消す**(ユーザー「消す」)。`QooViewerApp.performPendingStoreResetIfNeeded(replaceBackupJournalURL:)` で終了時・
  次の起動の最初に消す(予約の時点では消さない)。`StoreRecoveryTests.aFullResetKeepsOnlyTheGrantedFolders` に足した。MANUAL・CHANGELOG も更新。
- **テスト**: コミットの時点では Xcode から Debug を実行中で流せず(テストホストが同じ bundle id で起動する)、scratchpad の DerivedData で
  Debug の `build-for-testing` と CI と同じ Release のビルドが通ることだけ確かめた。Debug を止めてから手元で Debug の全テストを流し、
  **1300 件・124 suite が通った**(失敗・スキップ無し、2026-09-14。使い捨てボリュームはスキームの後処理で外れた)。なお `QOO_CI_WARNINGS_AS_ERRORS=YES` をコマンドラインで付けた
  `build-for-testing` は、変更前の HEAD でも `BulkRenameTests`(`isRegistered` のメインアクター)と `FileBrowserVideoThumbnailTests`(冗長な `#require`)で
  エラーになる(コマンドラインの設定がテストのターゲットにも届くため。docs/02 の「push する前に CI と同じ形で」の手順とは合っていない。未対応)。

**確かめていないもの(段階 9 の検証で見る。§8.5.4 までの「確かめていないもの」を集めた)**:
1. `heap`: ウインドウの開閉で `FileBrowserState` / `FileBrowserOperations` / `FileBrowserTableView` / `FileBrowserOutlineView` が残らない(監査 10 の修正後。
   アイコン表示の空きスペースの右クリックを通してから閉じる)。
2. すりガラス 2 条件(ダーク+白 100% / ライト+黒 100%)で全部品 ―― 段階 4b の枠・段階 8.5 の淡色・ボリュームの行の右クリック。
3. TCC の確認の出方(docs/12 の新しい手順。一度も通していない)。
4. 監査 6: 本物の追い出されたファイル(Finder の雲のアイコンが残ること)。利用者の手元でしか作れない。
5. 監査 4: ホームを表示したまま外で書き込みが続いても一覧が出続けること、ホームの配下と `/` の下での FSEvents のパスの頭。
6. 監査 11: 「このアプリケーションで開く」の候補が以前と同じ顔ぶれか(拡張子の無いファイル・パッケージ)。
7. 監査 9: 2 度目の `controlTextDidEndEditing` が実際に来るか。監査 1: 別ボリュームの移動の「両方を残しました」とその取り消しの見え方。
8. シークレットウインドウでの読み取り専用、ネットワーク上の共有への書き込み(書ける SMB が要る)、SwiftUI の受け口での他のアプリからのドラッグの記録。

**次に着手する候補(順番はユーザーに選んでもらう)**:
1. 上の「確かめていないもの」の実機検証(1〜3 は手元で、4 は利用者の手元で)

### 9.2 引き継ぎ(段階 9 の後の要望 8 件、2026-09-14)

**ユーザーの要望(2026-09-14)**: 環境設定の見た目と文言 4 件、アプリのアイコン、よく使う項目の並べ替え、アイコン表示の表紙、コレクションの本の
「このアプリケーションで開く」。コミットはしていない。CHANGELOG・MANUAL・README は変えていない(指示が無いため。下の「文書で残っているもの」)。

**入れたもの**:
- 環境設定「ファイルブラウザ」の「よく使う項目」のポップアップが右端に揃わなかった: macOS 26 の `.menuStyle(.button)` は枠を広げてもボタンが内容幅のまま
  枠の中央に置かれていた(検証アプリで実測)。`SettingsControls.PopUpWidth` の固定幅を右寄せに(全画面の `SettingsPickerRow(controlWidth:)` に効く)。
- 日本語の文言: 「圧縮ファイルの形式」「動画のサムネイルを生成」「現在のフォルダまでツリーを自動で展開」(キーは英語のまま、`ja` だけ)。コードのコメントと docs/15 も追従。
- アプリケーションのアイコン(リスト・アイコン表示): `FileBrowserApplicationIcon`、`BookThumbnailer.Kind.application`、`FileBrowserListApplicationIcons`(docs/15「アプリケーションのアイコン」)。
- よく使う項目のドラッグでの並べ替え: `FavoriteLocationStore.move(id:to:)`、`FileBrowserActions.moveFavoriteLocation`、ツリーの出し口・受け口(docs/15「ドラッグ&ドロップ」)。
- 表紙: ユーザーは「登録済みの本で表紙を使う」実装を把握していなかっただけ(不具合ではない)。そのうえで**ファイルブラウザのメタデータの編集シートにカバーの面を出す**
  (ユーザーの選択「全ての本で出す」)。登録済みならコレクションと同じ面、未登録なら切らない面。提供役はコレクション表紙の指定(画像・ページ)を未登録の本にも使う
  (docs/15「サムネイル」)。`FileBrowserBookSheet.Kind.metadata` は URL から `FileBrowserEntry` に変えた。
- コレクションの本の右クリックに「このアプリケーションで開く」: `CollectionDetailView.openWithMenu`、メニューの中身は `OpenWithApplications.menuNodes` に寄せてファイルブラウザと共有。

**テスト**: 足したもの ―― `FileBrowserModelTests.favoriteLocationsMove`、`FileBrowserThumbnailTests.applicationIcon` / `providerUsesShelfCoverOverrideForUnregisteredBooks`、
種類の判定に `.app`。Debug の全テスト **1303 件・124 suite が通った**(2026-09-14)。`scripts/ci/check-all.sh` も通った。

**実機検証(2026-09-14、Debug。ストア・表紙・defaults を控えて退避し、使い捨てボリュームの合成名の本で。終わって戻し、控えと一致を確認)**:
1. 環境設定: 「よく使う項目」のポップアップが右端に揃う(「表示モード別の操作」の固定幅のポップアップも)。3 つの文言も新しいもの。
2. アプリケーションのアイコン: リスト(全行)・アイコン表示(最小〜最大の大きさ。最大でもぼやけない)で、アプリ固有のアイコンが出る。
3. よく使う項目のドラッグ: 挿入線が行の間に出て並びが変わり、defaults に保存される。ボリュームの行・右の一覧へ落としても何も起きない(強調も出ない)。
   自分のすぐ下へ落としても変わらない。**見つけて直した**: 並べ替えると、表示中のフォルダ(よく使う項目の行)の選択が外れた ――
   `FileBrowserTreeView.Coordinator.update` がよく使う項目の行を作り直したあと選び直していなかった(追加・削除でも同じだった)。直した後に再確認。
4. メタデータの編集シート(ファイルブラウザから): 未登録の本は切らない面、ページ選び・Finder からの画像のドロップ(ドロップ中は枠)・既定に戻すが、
   シートとアイコン表示のセルの両方に即座に出る。登録済みの本はコレクションと同じ面(「切り取るときに残す位置」あり)で、ページ選びの後、
   抽出された表紙がシートとアイコン表示に出る。
5. コレクションの本の右クリック: 「このアプリケーションで開く」が「新規タブで開く」の下に出て、中身は既定・区切り・候補・「その他…」。

**確かめていないもの**:
- 他のアプリで実際に開くこと(候補の cooViewer・EdgeView などの履歴に合成の本が残るので開かなかった。また、テストでビルドされた Debug の app には
  Xcode が `/` を読める例外を足しているので、スコープを開けて渡すことの確認にはならない ―― docs/12「サンドボックスの許可の有無を測るとき」)。
- 複数選択中の「このアプリケーションで開く」の淡色。macOS 15 での見た目。
- 気づいたこと(未対応、既存の挙動): ファイルブラウザのメタデータの編集でページを選ぶと、ページ一覧のキャッシュ(`BookPageLists`)が書かれる
  (コレクションからのシートと同じ `CoverOverrideController.loadBookForCoverPicker`)。

**文書で残っているもの**: CHANGELOG(`[Unreleased]` に 4 件ほど)、MANUAL(§ファイルブラウザのアイコン・よく使う項目・右クリック、§25 の環境設定の表の 3 行の文言、
コレクションの右クリック)。「ドキュメントを更新」の指示があれば入れる。

### 9.3 引き継ぎ(画像フォルダのダブルクリックの設定、2026-09-14)

**ユーザーの要望(2026-09-14)**: 右ペインで画像フォルダをダブルクリック / リターンキーで開いたときの動作を、環境設定で「フォルダを開く」「ビューアで開く」から選べるようにする。

**入れたもの**: `FileBrowserImageFolderOpenAction`(既定 `.openFolder`、キー `qooViewer.pref.fileBrowser.imageFolderOpenAction`、「初期設定に戻す」の対象)と
環境設定「画像フォルダを開くとき ▸ ダブルクリック / リターンキー」。**右クリックの「開く」は常にその反対**(私の判断をユーザーに確認済み。どちらの設定でも
もう片方の開き方が右ペインに残る)。`FileBrowserActions.open` / `openFromMenu` は `openFolder(_:fromMenu:)` に寄せ、画像フォルダかを調べるのは本として開く側だけ。
ツリーと新規タブ/ウインドウで開くのは変えていない(docs/15「移動の規則」)。

**テスト**: `FileBrowserIntegrationTests` に 2 件(設定と開き方の対応、中へ移動する側が調べずに移ること・本でないフォルダは調べた後に移ること)。
本として開く側(`appState.open`)はテストでは通していない。`AppPreferencesTests` / `AppPreferencesProbe` に項目を足した。

**実機検証(2026-09-14、Debug。ストア・表紙・defaults を控えて退避し、使い捨てボリュームの合成名の画像フォルダ・棚フォルダで)**: 既定でダブルクリック・リターンキーは
中へ、右クリックの「開く」は本として。環境設定の行・ヘルプ・切り替えの保存。「ビューアで開く」でリストのダブルクリック・リターンキー・アイコン表示のダブルクリックは本として、
棚フォルダのダブルクリックと画像フォルダの右クリックの「開く」は中へ。9 件とも期待どおり。終わって戻し、控えと一致を確認。

### 9.4 引き継ぎ(ツリーのサブフォルダの並び、2026-09-14)

**ユーザーの要望(2026-09-14)**: ツリーの根(ボリューム・ホーム・よく使う項目)を除き、開いた行のサブフォルダの並びを右ペインの並べ替えに合わせる。環境設定で ON/OFF。

**入れたもの**: `AppPreferences.fileBrowserTreeFollowsListSort`(既定 false、キー `qooViewer.pref.fileBrowser.treeFollowsListSort`、「初期設定に戻す」の対象)と
環境設定「ツリー ▸ サブフォルダを右と同じ順に並べる」。`FileBrowserPane` が ON なら `state.sort`、OFF なら `FileBrowserTreeView.nameSort` を渡す。
ツリーは子の `FileBrowserEntry` を `Node.listing` に持ち、`FolderBrowserSort.sorted` で並べる。基準が変わったら読み直さずに並べ直す(docs/15「ツリーのサブフォルダの並び」)。

**テスト**: `AppPreferencesTests` / `AppPreferencesProbe` に項目を足した。ツリーの並べ直し(AppKit の Coordinator)の単体テストは無い。

**実機検証(2026-09-14、Debug。ストア・表紙・defaults・よく使う項目を控えて退避し、使い捨てボリュームの合成名で更新日の違うフォルダ 4 つ)**: OFF では右を変更日順にしても
ツリーは名前順。ON にした瞬間に右と同じ順(変更日の昇順)へ並び替わり、開いていた行と孫の並びも保たれる。変更日の降順・名前の降順も右と一致。
シェルで作ったフォルダは FSEvents の読み直しで正しい位置に入る。OFF に戻すと名前の昇順。ボリュームの並びは変わらない。環境設定の行とヘルプの表示も確認。
終わって戻し、控えと一致を確認。

### 9.5 引き継ぎ(ブランチ全体の 2 回目のコード監査、2026-09-14)

**ユーザーの指示(2026-09-14)**: 「もう一度、本ブランチで実装した内容についてコード監査」。重点は §8.5.4 と同じ(資源リーク・クラッシュ・ハング・ファイルの破損と消失・
メモリとディスクの過大な消費)。前回の修正そのものと、その後に入った §9.2〜9.4 も対象。続けて「まず引き継ぎ資料を記載、その後 1〜6 から修正」。

**方法**: 独立した 6 系統の読み合わせ(操作エンジン / 圧縮・展開と書庫の reader / 取り消し・D&D / 画面と状態 / サムネイル / 既存コードの差分)。
重いものはコードを端から辿って確かめ、プラットフォームの挙動は scratchpad の `swift` スクリプト・使い捨ての `hdiutil` イメージで実測した(後始末済み)。
下の「実測」は再現を確かめたもの、「コード」は経路を辿ったもの、「推定」は条件次第のもの。

**監査で実測したプラットフォームの事実**(直すときはもう一度同じ手で確かめる):
- `copyfile(COPYFILE_CLONE | COPYFILE_RECURSIVE)` は、**中身のあるロックされた(`uchg`)サブフォルダ**を含む木で EPERM で失敗する(CLONE 無しなら写る)。
  書きかけにはロックされた空のフォルダが写っていて、`removeItem` は EPERM で消せない。
- `copyfile(… COPYFILE_EXCL | COPYFILE_RECURSIVE)` は、宛先に**同名のフォルダがあると失敗せず、その中へ `宛先/名前/…` を書いて 0 を返す**(CLONE の有無によらない)。
  EEXIST になるのは宛先がファイルのときと、`宛先/名前` まで既にあるときだけ。型コメントの「EXCL で既存の宛先は失敗」はフォルダには当てはまらない。
- CLONE 無しの再帰コピーは、フォルダを写し終えた時点でそのフォルダの権限(0555 など)を掛け、ファイルの `uchg` も写す。途中で止めた書きかけは `removeItem` で消せない(EACCES / EPERM)。
- マウントしたボリュームのルートは `renamex_np` が EXDEV、`removeItem` は**中身を全部消してから** EBUSY で失敗する。
- ZIPFoundation 0.9.20 は `addEntry` の `defer { fflush }` と `deinit` の `fclose` の結果を捨てる。末尾(セントラルディレクトリ / EOCD)で ENOSPC になると
  `addEntry` は投げずに終わり、開き直すと `missingEndOfCentralDirectoryRecord`。
- `FileManager.enumerator(atPath:)` は読めない(0000)サブフォルダを黙って飛ばして正常に終わる。
- フォークの SevenZip.swift は BCJ2 などストリーミング非対応の coder の組で `SzArEx_Extract` へ落ち、ソリッドブロック全体を確保する
  (800MB のゼロ + 20KB の jpg を `-mf=BCJ2` で固めた 143KB の cb7 で RSS 845MB。LZMA2 なら 40MB)。
- 巨大な無圧縮 BMP(16000²)の `CGImageSourceCreateThumbnailAtIndex` は最大 2GB(PNG / TIFF / HEIC / PDF は間引いて読むので数十 MB)。
- APFS(大文字小文字を区別しない)は `ς`/`σ`・`ß`/`ss`・`ﬁ`/`fi` を同じ名前とみなすが、`FileNameValidation.foldedForComparison` は畳まない。
- `URL(fileURLWithPath:)`(`isDirectory:` 無し)は実在を stat して `hasDirectoryPath` を決める。

**見つかったもの(重い順)**:

A. 消失・終了・壊れたファイル
1. **【実測・終了】深い入れ子のパスを持つ書庫の展開でスタックが溢れる**(`ArchiveExtractionPlan.swift` の `Namer.directory(for:)` がパスの要素ごとに再帰。段数・全体長に上限なし、
   段ごとに畳んだキーを作り直すので 2 乗)。3000 段のエントリ 1 つの 12KB の zip で、FileIO のスレッド(512KB スタック)が SIGBUS。7z も名前長に上限なし。
   **直し方**: `components(of:)` で深さ・全体のバイト数に上限を設けて `.unsafePath` として捨て、`Namer` はループで組み立てる。
2. **【コード・消失】1 回の転送に同じ名前の項目があると、後の項目が先に運んだ項目を「置き換え」る**(`FileOperationService.checkConflict`)。別々のフォルダの `x.txt` 2 つ
   (大文字小文字を区別するボリュームの `a`/`A` も)を移動し、2 件目の確認で「置き換える」か、先の衝突で「すべてに適用」を選んでいると、1 件目はゴミ箱へ、
   ゴミ箱の無い宛先(SMB)では確認なしに完全削除。**直し方**: この転送で置いた項目(受領書の宛先)に当たったら置き換えずに「両方残す」にする。
3. **【実測】ロックされたサブフォルダを含むフォルダのコピーが必ず失敗し、消せない書きかけが残る**(`FileCopyEngine.copyOnce` の CLONE 無しのやり直しは EACCES のときだけ。
   片付けの `removePartialWrite` は `try?`)。「置き換える」なら `restoreReplacedItem` が宛先を空けられず、元の項目が隠しフォルダに残り起動のたびに警告。
   **直し方**: EPERM で木にロックがあれば CLONE 無しでやり直す。書きかけの片付けは自分が書いた木のロックと書き込み禁止を外してから消す。
4. **【実測】書きかけの片付けが、写し終えた 0555 のフォルダやロック付きファイルで失敗する**(中止・ENOSPC・読めないファイル・元の変化)。3 と同じ片付けで直す。
5. **【実測・欠けた zip】圧縮で読めないサブフォルダの中身を黙って抜かした zip を成功として作る**(`ZipCompressor` の `enumerator(atPath:)` と、`lstat` 失敗の `continue`)。
   **直し方**: `errorHandler` 付きの列挙で投げる。`lstat` の失敗は ENOENT(途中で消えた)だけ飛ばす。
6. **【実測・壊れた zip】ディスクが末尾で溢れると壊れた zip を成功として最終名に置く**(上の ZIPFoundation の事実)。**直し方**: `Archive` を閉じた後に一時ファイルを
   読み取りで開き直し、エントリ数を確かめてから rename。`CbzExporter` / `EpubExporter` / コレクション表紙の zip も同じ形(ブランチ以前から)。
7. 【コード】別ボリュームへの移動の「元が変わっていないか」が、大きさと inode が同じなら先頭・中央・末尾の 64KB × 3 窓だけ(`MoveVerification`)。領域を先に確保して
   書き続けるダウンロード・ディスクイメージで、窓の外の書き込みが失われる。元のフォルダを消している間に作られたファイルも消える。
   **直し方**: ローカルのボリュームでは更新日時(ns)も比べる。フォルダは列挙して写したものだけを下から消す。
8. 【挙動は実測・発生は競合】他人のフォルダを完全削除する経路 2 つ: (a) `checkConflict` とコピーの間に宛先に同名のフォルダが現れると、copyfile が中へ合流し、
   後の片付け(元の変化・失敗)でフォルダごと消す。(b) `restoreReplacedItem` が宛先にあるものを自分が作ったか確かめずに消す。
   **直し方**: フォルダは一時名へ写してから `RENAME_EXCL` で置く、片付けは作ったものの `FileIdentity` と一致するときだけ。
9. 【エンジンの挙動は実測・引き金は推定】ボリュームのルートの移動(Finder でボリュームを ⌘C → ⌥⌘V、⌘ ドロップ)。全部写してから元を空にする。`paste` だけが
   `isVolume` を外していない。**直し方**: 転送の入口でマウントポイントの移動を断る(エンジンでも)。

B. 取り消しと操作の流れ
10. 【コード】`CompositeFileCommand` で後の子が投げると(中止以外)、済んだ子を巻き戻さずに投げ、`FileCommandStack.run` は積まない → 済んだ移動が取り消せず報告にも出ない。
    **直し方**: 済んだ子に効果があれば `.partial` で返す。
11. 【コード】実行中に押した ⌘Z は列の後ろに並び、実行時の積み場所の一番上を戻す(走っている操作が終わった直後にそれを戻す)。**直し方**: 押した時点の一番上を控えて一致するときだけ、
    または操作中は取り消し/やり直しを淡色に。
12. 【コード】取り消し/やり直しは `run` を通らず進捗・中止が無い(別ボリュームの移動の取り消しは全量を写し直す)。ウインドウを閉じても操作は続き、`presenter` が nil で
    失敗の報告(`sourceRemainsAfterMove` / `replacedItemKept` を含む)が捨てられ、残りの衝突は黙ってスキップ。
13. 【コード】ゴミ箱の無い場所への操作の取り消しが `trashUnavailable` で `canRetry: true` のまま履歴に居座り、下の操作へ届かない。
14. 【推定・終了】取り消しの題・「移動」メニューの可否・モードを `MenuBarMenuGate` を通さずに `MenuCheckmarkState` へ渡している(`ContentView`)。メニューを開いている間に
    操作が終わると macOS 26 の `setItemArray:` のクラッシュ条件に当たりうる。**直し方**: AppState に保留付きの `@Published` で持つ(`isCurrentPageBookmarked` と同じ形)。
- 低: 途中で中止した操作のやり直しが中止済みの `Cancellation` を使い回して何もしない。ゴミ箱から戻すとき(`restoreFromTrash`・置き換えた元)に実体を見ない
  (空にした後に同名を捨てると別の項目が戻る)。新規フォルダの取り消しが読めないフォルダを空とみなす。取り消せない操作で redo が消えない。
  シートの途中でウインドウが閉じたときの continuation(未実測)。SwiftUI の受け口が他のアプリのドラッグ元の移動禁止を見ない。

C. ハング・TCC
15. 【コード】右クリックの「開く」・新規タブ/ウインドウで開く・メタデータの編集・コレクションの作成が `ShelfFolderResolver.role` → `DirectoryBrowser.listing` で
    **子フォルダの中を全部読む**(保護下の除外なし)。ホームや `~/Library` で TCC の確認が次々に出る。§9.3 の「ビューアで開く」ならダブルクリックだけで。
    **直し方**: 画像フォルダの判定は直下だけを見る版にする。
16. 【実測】メインの 2 乗: 一括リネームの名前決め(`BulkRename.avoiding`、5000 件 4.6 秒、シートでは 2000 件まで打鍵ごと)、ペースト後の選択の突き合わせ
    (`FileBrowserState` の `wanted.filter { allEntries.contains }`、1000×2 万で 3.4 秒)。FileIO の上だが中止の効かない 2 乗: 展開計画の大文字小文字の衝突
    (`nextAvailableName` の線形探索、4000 件 2.9 秒。件数の上限は計画を作った後)。
17. 【コード】ツリーの `loadChildren` は前の読み込みを取り消さずに重ねる(開いたダウンロードの中でダウンロードが続くと 0.3 秒ごとに FileIO が 1 本)、
    「現在のフォルダまで開く」が終わらない。`handleExternalChange` が FSEvents のパスごとに `URL(fileURLWithPath:)` でメイン上の stat。
18. 【推定】応答しない共有: 一覧の `reload()`(アクティブ化・着脱のたび)とツリーの共有の行の読み直しが、走っている読み込みを待たずに FileIO のスレッドを積む。
    サムネイルの同時 4 枠がアプリで 1 つで、ネットワークの項目に期限が無い(共有の 4 件で全ウインドウの絵が止まる)。
19. 【実測】`FolderChangeWatcher` の `watch([])` の後も `lastEventID` を持ち越すので、本を読んで数時間後にファイルブラウザへ戻るとその間の履歴がまとめて届く
    (ホームで 180 秒に 2,587 件)。**直し方**: 空の組で止めたら `SinceNow` に戻す。

D. メモリ・CPU・ディスク
20. 【実測】BCJ2 の 7z でブロック全体を確保(上の事実)。フォルダをアイコン表示で開くだけで、セルごと・同時 4 件。フォークに宣言サイズで断る口が要る。
21. 【コード】ソリッドの rar / 7z の絵は、先頭の画像より前を全部伸長する(64MB の上限は画像自身だけ、中止も見ない)。展開で捨てたエントリの伸長も上限・中止に数えない。
22. 【コード】動画の先読み役(`FileBrowserVideoThumbnailWarmer`)とアイコン表示が 200MB のディスクキャッシュを取り合う(`contains` がアクセス日時を触らず、先読み役は上限を知らない)。
    上限を超える量の動画があると起動ごとに作り直しと追い出しが続く。
23. 【推定】`DirectoryProbe.protectedPrefixes` の比較が Data ボリュームの頭(`/System/Volumes/Data`)を付けたホームの書き方を素通しする。`/` をよく使う項目に登録すると先読み役が保護下へ入り、全体を二重に辿る。
    先読み役はフォルダごとに `MountTable.current()`(走査の中の分が残っている)、SF_DATALESS のフォルダも辿る。
24. 【実測】巨大な無圧縮 BMP の絵で約 2GB。
- 低: キャッシュを OFF にした瞬間の書き込みが残る。表紙を指定した未登録の本の絵が `CoverImageResolver` 経由で追い出されたページを落とす。圧縮の一時ファイル
  (`.qooViewer-compress-<UUID>.zip`)がクラッシュ後に残る。リストのアプリのアイコンの同時読み込みに上限が無い。ボリュームの着脱・よく使う項目の並べ替えでツリーの開いた行が閉じる。
  id が `String` の正準等価で NFC / NFD の同名項目が 1 つになる(NFS など)。`ReplaceBackupJournal` がパスだけで持つ(改名後・同名の別ディスクで記録を捨てる)。
  `MountTable.areOnSameVolume` がパスの文字列で比べる(リンク越し)。QuickLook が取り消しに応えないと枠が塞がる(推定)。

**監査で問題なしと確認した範囲**: 前回の修正(`copiedButSourceRemains` と両側での掛け直し、書きかけの EEXIST / `reachedChild` の規則とやり直しのバイト数、`presence`、
`replacedItemKept`、同一ボリュームのロックの近道、ハードリンクの兄弟、`withDeadline` の取り消しの橋渡し、`DatalessFiles.withoutDownloading` の出口、`boundedEntryData`、
シークレットウインドウの `savesToDisk`)。FSEvents のコールバックの寿命、NSOutlineView の項目の解放(NSZombie で確認)、リストの編集中の取り込み、読み取り専用モードの抜け道
(全経路で入口が断る)、Zip Slip 対策、Matroska / EBML パーサ(乱数 300 万件)、`@Model` の変更が無いこと、全データ削除の順序、撤去した設定とページの鍵の対応、
`WindowContentRequest` の復元。

**1〜6 の修正(2026-09-14、ユーザー指示「1〜6 から修正」)**: 「ドキュメントを更新してコミット・プッシュ」の指示で、CHANGELOG `[Unreleased]`(ファイルブラウザの項)・MANUAL(ファイルの操作・圧縮・展開)・docs/15・docs/13 の経緯の表と一緒にコミット・プッシュ(この節と同じコミット)。README・CLAUDE.md は変える記述が無かった。Debug の全テスト 1311 件・124 suite が通り、`check-all.sh` も通った。
- 1: `ArchiveExtractionPlan.components(of:)` がパス全体で `PATH_MAX`(`maxPathBytes`)を超えるものを `.nameTooLong` で捨てる(= 段数の上限)。
  `Namer.directory(for:)` は親から順のループに(畳んだキーは 1 段ずつ伸ばす)。
- 2: `FileOperationService.transfer` がこの操作の受領書の `FileIdentity` を `checkConflict` へ渡し、衝突の相手がそれなら方針・答えによらず尋ねずに
  「両方残す」。`FileIdentity` を `Hashable` に。
- 3: `FileCopyEngine.copyOnce` のやり直しは errno で絞らず、「書きかけが消えた」かつ「木に CLONE を断るフォルダ(持ち主の書き込み権が無い / `uchg`)がある」とき
  (`containsDirectoryBlockingClone`)。実測: ロックされたフォルダは空でも CLONE で EPERM、CLONE 無しなら写る。ロックされたファイル・`uappnd` のフォルダは CLONE でも写る。
- 4: `removePartialWrite` は素の削除で残ったら `liftWriteProtection(under:)`(`uchg`/`uappnd` を lchflags で外し、フォルダに u+rwx、リンクは辿らない、
  自分のスタックで歩く)してから消し直す。呼ぶのは自分が書いた木だけ(`restoreReplacedItem` の宛先も含む ―― 競合で他人の項目がそこに来る 8(b) は未対応)。
- 5: `ZipCompressor.collect` は `contentsOfDirectory` + `lstat` で自分で歩き、読めないフォルダ・`lstat` の失敗(ENOENT 以外)を `posixFailure` で投げる。
- 6: `ZipCompressor.verifyWrittenArchive`: 一時ファイルを `fsync`(EINVAL / ENOTSUP は無視)し、読み取りで開き直してエントリ数が `sources.count` と合うかを見る。
  合わなければ一時ファイルを消し、空きが余裕を割っていれば ENOSPC、それ以外は EIO で、出すはずだった名前を添えて失敗。**CbzExporter / EpubExporter /
  コレクション表紙の zip は同じ形のまま(未対応)**。
- テスト: `ArchiveExtractionPlanTests.deepNestingIsBoundedAndIterative`、`FileOperationServiceTests.sameNamedItemsInOneTransferNeverReplaceEachOther` /
  `partialWriteCleanupLiftsCopiedProtection`、`FileOperationVolumeTests.copiesTreesWithLockedSubfolders`(同じボリューム + 別ボリュームへの置き換え)、
  `ZipCompressorTests.unreadableSubfolderFailsInsteadOfSkipping` / `verificationRejectsATruncatedArchive`(末尾を切った zip で検証を直接確かめる。
  本物のディスクフルでの末尾の欠けは tiny ボリュームでは作っていない)。**2・3・4 のテストは修正前のエンジン(`FileCopyEngine` / `FileOperationService` を HEAD に戻す)で
  失敗し、修正後に通ることを確認した**。1・5・6 は新しい口を使うので修正前ではビルドできない(監査の実測で再現済み)。

**7〜9 の修正(2026-09-15、ユーザー指示「監査で検出した残りの不具合を修正。切りの良いところで都度ドキュメントを更新し、コミット・プッシュしてよい」)**:
Debug の全テスト 1317 件・124 suite が通った。CHANGELOG・MANUAL・docs/13・docs/15 と一緒にコミット・プッシュ(この節と同じコミット)。
- 8(a)(b): `FileCopyEngine.copy` はファイルもフォルダも同じフォルダの `.qooViewer-copy-<12 桁>`(`stagingPrefix`)へ写し、写し終えたら置く前に
  `MoveVerification` で元の変化を見て、`RENAME_EXCL` で宛先の名前へ置く(`renameLiftingProtection`: 写った `uchg` / `uappnd` を外して置き、掛け直す)。
  失敗・中止・元の変化・宛先が埋まっていた(`alreadyExists`)ときは一時名だけを消す。これで `carry` の「置いた後の検証と `removePartialWrite(at: target)`」と
  `restoreReplacedItem` の宛先の削除を外した(宛先の名前にあるものは他人の項目)。`moveItem` の検証もエンジンへ。事前検査のパス長は一時名のぶんを足す
  (`checkPathFits(staged:)`)。クラッシュで一時名が残るのは既知の限界(圧縮の一時ファイルと同じ「低」の列)。
- 7: `MoveVerification.sourceWasModified(trustsModificationDate:)` ―― エンジンが `MountTable.current().isLocal(source)` を渡す。フォルダの元の削除は
  `FileOperationService.removeTransferredSource(_:copiedTo:)`(写した先を列挙して帰りがけに unlink / rmdir。最初の失敗で止め、`copiedButSourceRemains` に)。
- 9: `preflight` が移動のとき `MountTable.isMounted` の項目を `FileOperationError.volumeCannotBeMoved` で断る(文言は ja も xcstrings へ)。
- テスト: `FileOperationServiceTests.changeOutsideTheSampledWindowsIsDetected` / `folderAppearingAtTheDestinationDuringACopyIsNeverMergedOrRemoved` /
  `replaceNeverRemovesAnItemThatAppearedAtTheTarget` / `copiesItemsWhoseOwnFlagsBlockRename` / `removingATransferredSourceKeepsItemsThatWereNotCopied`、
  `MoveVerificationTests` にローカルの日時、`FileOperationVolumeTests.refusesToMoveAVolume`。競合はテストの進捗の callback の中で起こす
  (ProgressTracker は項目の最初のバイトを間引かず、copyfile のスレッドの上で同期に呼ぶ)。

**10〜14 の修正(2026-09-15、同じ指示)**: Debug の全テスト 1323 件が通った。CHANGELOG・MANUAL・docs/13・docs/15 と一緒にコミット・プッシュ(この節と同じコミット)。
- 10: `CompositeFileCommand.runChildren` ―― 中止以外で子が投げたら、`executed` に効果のある子があれば `.partial`(投げた子 + 残りを「処理されませんでした」)。
  `undo(in:)` は `executed` の効果のある子だけ。テスト `compositeDoesNotRollBackOnFailure` を書き換え、`compositeUndoRetryability` は実行してから取り消す形に。
- 11: `FileCommandStack.nextUndo` / `nextRedo` と `undo(in:expecting:)` / `redo(in:expecting:)`(`!==` で比べる。控えは強参照なのでアドレスの再利用で取り違えない)。
  `FileBrowserOperations.undo()` / `redo()` が押した時点で控える。
- 12: `FileCommand.undo(in:)` / `redo(in:)` + `FileCommandContext`(既定の実装は素の `undo()` / `redo()`)。`MoveFilesCommand` / `CopyFilesCommand` / 
  `CompressFilesCommand` / `ExtractArchivesCommand` / `BulkRenameFileCommand` / Composite が実装。`TransferUndo.undo` は `PutBack`(restored / missing / cancelled)。
  `FileBrowserOperations.runUndoOrRedo` が帯を出し、`transferOptions` から進捗と尋ねる口を作って渡す。ウインドウを閉じたら `detachFromWindow()`
  (`DetachedFileBrowserOperationPresenter`)。`transferOptions` の尋ねる口は相手がいなければ中止を立てる。
- 13: `TransferUndo.canRetryTrashing(after:)`。ついでに「低」の「新規フォルダの取り消しが読めないフォルダを空とみなす」を直した。
- 14: `AppState.fileBrowserMenu`(`FileBrowserMenuSnapshot`)+ `setFileBrowserMenu`(`MenuBarMenuGate` のキー `fileBrowserMenu`)。`ContentView.fileBrowserMenuSnapshot`
  を `.onChange(initial: true)` で渡す。実機でのメニューの見た目の確認はしていない(ユーザーが Xcode で動かしているので画面は触らない)。
- テスト: `FileCommandStackTests.undoAndRedoOnlyActOnTheExpectedCommand`、`FileCommandsTests.undoWhereThereIsNoTrashIsNotRetryable` /
  `moveUndoCanBeCancelledAndRedoUsesAFreshCancellation` / `createFolderUndoDoesNotTreatAnUnreadableFolderAsEmpty`、
  `FileBrowserOperationsTests.undoPressedDuringAnOperationDoesNotUndoThatOperation` / `detachedOperationsDeclineConfirmationsButStillReport`。
- 「低」の列のうち直したもの: 中止済みの `Cancellation` を使い回すやり直し(12)、読めないフォルダの新規フォルダの取り消し(13)。
- 全テストを並べて走らせたときに `FileIOTests.taskCancellationIsVisibleOnTheBorrowedThread` が 1 度落ちた(FileIO のスレッドが埋まり、中の 10 秒の期限が
  先に来た。単独では通る)。待ち合わせに FileIO のスレッドを借りないようにし、期限を 45 秒(Test の上限は 1 分)にした。

**15〜19 の修正(2026-09-15、同じ指示)**: Debug の全テスト 1328 件が通った。CHANGELOG・MANUAL・docs/13・docs/15 と一緒にコミット・プッシュ(この節と同じコミット)。
- 15: `ShelfFolderResolver.isSingleBookFolder(_:protectedPrefixes:)`(直下の名前 → 画像があれば 1 冊、本のファイルがあれば棚、無ければ子フォルダの
  直下に画像があるか。`DirectoryProbe.mayReadChild` で保護下の子を外す)。`FileBrowserActions.isImageFolder` と `FileBrowserLibraryActions.resolveBook`
  がこれを使う。`DirectoryBrowser.makeEntry` も `mayReadChild` で保護下の子の `directContents` を読まない(コレクションの作成・本棚へのドロップ・
  サイドパネルの一覧。ホームの一覧で「書類」などの `containsImageFile` は false になる ―― 本棚にホームを落としても「書類」を本と数えない)。
  D-23 の前半(`/System/Volumes/Data` の書き方の素通し)もここで `DirectoryProbe.comparablePath` に。
- 16: `BulkRename.avoiding` と展開の `Namer.availableName` が番号の続きを覚える(`nextNumbers`)。一括リネームは「自分の元の名前」の例外だけ先に
  確かめる(`numberSuffix`)。`FileNameValidation.numberedName` を切り出した。ペースト後の選択は `Set` で引く。
- 17: ツリーの `loadChildren` は `isLoadingChildren` / `needsReloadAfterLoad` で重ねない(世代はたたんだときだけ進む)。`handleExternalChange` は文字列で親を求める。
- 18: `FileBrowserState.reload` は同じフォルダを読んでいる最中(`inFlightFolderID`)なら `needsReloadAfterLoad` だけ立てる。その間の `apply` は選ぶ・見せる
  依頼を次の読み直しまで取っておく。絵は `Job.isRemote` で別の枠(`maxConcurrentRemoteJobs` = 2)。
- 19: `FolderChangeWatcher` は空の組・`tearDown` で `lastEventID` を `SinceNow` に戻す(テストのために `private(set)`)。
- テスト: `ShelfFolderResolverTests.singleBookFolderCheckMatchesTheRulesWithoutEnteringProtectedChildren`、`DirectoryProbeTests.mayReadChildOnlyInsideTheSameProtectedPlace`、
  `BulkRenameTests.manyCollisionsStayLinear`、`ArchiveExtractionPlanTests.manyCaseCollisionsStayLinear`、`FolderChangeWatcherTests.stoppingForgetsWhereItLeftOff`。
  ツリー・一覧の重ならない読み込みと絵の別枠は自動テストを足していない(応答しない共有を作れない)。実機の確認も未(ユーザーが Xcode で動かしているので画面は触らない)。

**20〜24 の修正(2026-09-15、同じ指示)**: Debug の全テスト 1332 件が通った。CHANGELOG・MANUAL・docs/11・docs/13・docs/15 と一緒にコミット・プッシュ(この節と同じコミット)。
- 20: **フォーク `qoo-oji/SevenZip.swift` の `streaming-extract` に `0b4c1b9`**(`Archive.maxWholeBlockBytes` と `LZMAError.blockTooLarge`、BCJ2 のフィクスチャで
  テスト、`docs/StreamingExtraction.md`)をコミットしてプッシュし、`Package.resolved` の revision を手で書き換えて `-resolvePackageDependencies`。
  アプリは `SevenZipArchiveReader.maxWholeBlockBytes` で素通しし、`BookThumbnailer.make` の書庫だけが `maxEntryBytes`(64MB)を付ける。
- 21: `BookThumbnailer.readsTooMuchBefore`(zip 以外。書庫の順で前のファイルの宣言サイズ > 256MB で作らない)。展開は `ArchiveExtractionPlan.skippedDeclaredBytes`
  (`__MACOSX`・捨てた・同じパスの 2 つ目)を `checkLimits` の合計と倍率に足す。読み飛ばしの中の中止は相変わらず届かない(7z は C の中、rar はライブラリの中)。
- 22: `FileBrowserThumbnailDiskCache.bytesAvailableForWarming`(上限の半分 − 使用量)を掃引の始めに 1 回、書いたぶんを引いて尽きたら止める(`SweepReport.stoppedForCacheBudget`)。
- 23: 後半。先読み役の `live` の `isRemote` は `RecentMountTable`(1 秒に 1 回)、`videoFiles` は `SF_DATALESS` のフォルダに入らない。前半(データ側の書き方)は C で済み。
- 24: `ImageDecoder.decode(… maxFullDecodePixelCount:)` と `subsamplingTypeIdentifiers`。`BookThumbnailer.maxFullDecodePixelCount` = 3200 万画素を画像・フォルダ・書庫の絵に。
- テスト: `FileBrowserThumbnailTests.entriesBeforeTheFirstImageAreBounded` / `hugeImagesThatCannotBeSubsampledAreSkipped`(BMP の見出しだけを組む)、
  `FileBrowserVideoThumbnailTests.warmerStaysWithinHalfOfTheCacheLimit`、`ArchiveExtractionPlanTests.skippedEntriesCountTowardLimits`。フォーク側は
  `StreamingTests.testWholeBlockLimitRefusesLargeFallbackBlocks`(`swift test` 35 件)。

**「低」の列の修正(2026-09-15、同じ指示)**: Debug の全テスト 1335 件が通った。CHANGELOG・MANUAL・docs/13・docs/15 と一緒にコミット・プッシュ(この節と同じコミット)。
- 直した: ゴミ箱から戻すときの実体の確認(`TrashReceipt.identity` / `TransferReceipt.replacedItemIdentity`)、取り消せない操作でやり直し先を捨てる、
  キャッシュを OFF にした瞬間の書き込み(書いた後で見て消す)、表紙を指定した未登録の本の追い出されたページ(`CoverImageResolver.coverImage(skipsNotDownloadedPages:)`)、
  リストのアプリのアイコンの同時読み込み(4 件)、ボリュームの着脱・よく使う項目の並べ替えでツリーの行が閉じる(Node を使い回す)、
  `areOnSameVolume` のリンク越し(`FileOperationService.isOnSameVolume` が親のリンクを解く。ドラッグの判定は画面の側なので文字列のまま)、
  QuickLook が取り消しに応えないと枠が塞がる(`QuickLookVideoThumbnailLoader` をタスクグループから「最初の 1 つで戻る箱」へ)、
  SwiftUI の受け口が他のアプリのドラッグ元の移動禁止を見ない(Finder が最前面のときだけ移動を許す ―― 公開 API で元のマスクを取る手段が無い)。
  前の区切りで済んだ: 中止済みの旗のやり直し、読めないフォルダの新規フォルダの取り消し。
- 残した(docs/15 の既知の制限へ): シートの途中でウインドウが閉じたときの continuation(未実測。画面を触れないので確かめていない)、
  一時名・一時ファイル・一時フォルダがクラッシュ後に残る(置き場所の記録が要る)、NFC / NFD の同名項目が 1 つになる(id の型を変える大きな変更)、
  `ReplaceBackupJournal` がパスだけで持つ。
- テスト: `FileOperationServiceTests.restoreChecksTheIdentityInTheTrash`、`FileCommandStackTests.irreversibleOperationsClearRedo`、
  `FileOperationVolumeTests.sameVolumeCheckResolvesLinks`。ツリーの行・アプリのアイコン・QuickLook・SwiftUI のドロップ・追い出されたページは自動テストを足していない。

**次にやること**: 2 回目の監査の列はここまで。実機での確認(§9.1 の手順に、この監査で変えた画面の挙動 ―― 取り消しの帯と中止、閉じたウインドウの報告、
「移動」メニュー、ツリーの行が閉じないこと、SwiftUI の受け口のコピー ―― を足して)はユーザーの操作が無いときに。

---

## 触るファイル(見積り)

新規: `Services/FileOperations/`(8)、`ViewModels/FileCommands/`(10)、`ViewModels/FileBrowserState.swift`、`ViewModels/FavoriteLocationStore.swift`、
`Views/FileBrowser/`(12)、`Views/FileBrowserSettingsView.swift`、`Models/{FileNameValidation,BulkRename,GridKeyboardNavigation,WindowContentRequest,FileBrowserPreferences}.swift`、
`Services/FileBrowserThumbnails/`(7)、テスト 15 ファイル、`qooViewerTests/Support/DisposableVolume.swift`。
変更: `QooViewerApp`(WindowGroup の提示値・メニュー)、`ContentView`、`AppState`、`BookWindowOpener`、`LaunchCoordinator`、`WelcomeTopBar`、`WelcomeView`、
`WelcomeLibraryState`、`SettingsPane`、`AppPreferences`、`GeneralSettingsView`、`PageOrder`/`EffectivePageOrder`/`CoverImageResolver`/`CollectionCoverExtractor`/
`LayoutStore`、`BookLocationResolver`(`MountTable` へ)、「Finder で表示」の 11 箇所、`Localizable.xcstrings`(ビルドで書き戻る差分はそのままコミット)。

合計の見積り: 約 10,000 行(テスト約 3,000 行を含む)。
