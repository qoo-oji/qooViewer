# 12. 検証とデバッグの方法

このアプリの単体テスト(`qooViewerTests`)は、UI を伴わない `nonisolated` のパイプライン ――
拡張子の判定・並び順、書庫の読み取りから `BookLoader` → `PageRef` まで、EPUB / PDF の構造解決 ――
を、小さな本のフィクスチャで通すものです(→ [02](02-project-and-build.md#テストターゲットqooviewertests))。
golden は `PageRef.sortKey` の列で、DB の pageKey がここに乗っています。画面まわりはテストで
押さえていません。そのぶん、次のような「実物を動かして測る」やり方を積み重ねてきました。
仕組みを変えるときは、同じやり方で前後を比べてください。

## 基本

- Xcode で `Cmd+R`。ビルドだけなら `xcodebuild -project qooViewer.xcodeproj -scheme qooViewer
  -configuration Debug build`、単体テストは同じ行の末尾を `-destination 'platform=macOS' test` に。
- SwiftLint / SwiftFormat の設定はありません。
- コミット前に `scripts/ci/check-all.sh` を走らせます(タグを打つ前は `scripts/ci/check-all.sh v1.42`
  のようにタグ名を渡すと、`MARKETING_VERSION` と CHANGELOG の見出しも照合します)。CI の `check.yml`
  が走らせるのと同じスクリプトです(→ [02](02-project-and-build.md#ci))。
- ビルドすると `Localizable.xcstrings` に差分が出ます。戻さずコミットします。
- 統合ログは `/usr/bin/log`(zsh の `log` ビルトインに注意)。`NSLog` した保存失敗
  (`lastSaveErrorMessage`)は Console.app で追えます。
- 「ハング」に見えるものは、Xcode から起動していると例外で止まっているだけのことがあります
  (`_crashOnException:`)。`sample` で確かめる。

## 再現を先に、仮説は後

報告時点の状態(どの本・どの設定・どの操作)を自分の記録から特定し、同じ条件で再現・一致を
確認してから修正を試します。発生しない条件での結果は判定に使いません。報告者の環境で再現しない
プラットフォーム起因の不具合は、堅牢な側の実装へ倒します(`RemappableKey.from(nsEvent:)` は
その例)。

## プラットフォーム API は実測より検索が先

AppKit / SwiftUI の挙動が不明なら、probe を書く前に既存の報告を検索します。「できない」と言う前に
選択肢を列挙して実測し、公式の手段が無いと分かったら非公式な回避策を自分の判断で試し始めず、
報告して止まります(`Settings` シーンのリサイズ、`.confirmationDialog` のボタン数、`ScrollGeometry`
の可動範囲は、この手順で結論が出たもの)。

## SwiftUI の最小再現ハーネス

AppKit のブートストラップ(`NSApplication` + `NSHostingView`)で SwiftUI のビューを直接実行する
小さなプログラムを、scratchpad に作って測ります。`LazyCellImageBudget` の設計(300 セルで
170 個生存、`onDisappear` で nil を書いても解放されない、`.id(epoch)` だけが効く)は、この
ハーネスでの実測から決まりました。

## SwiftUI の画面をテストホストの中で撮る

環境オブジェクトや実データが要る画面は、外から操作するより**テストの中で描かせて PNG にする**
ほうが速くて確実です。アプリ本体(TEST_HOST)の中で走るので、環境設定・ストア・表示言語を
その場で組み立てられます。

- **`NSHostingView` をウインドウに載せ、`cacheDisplay(in:to:)` で撮る。**
  `ImageRenderer` は手軽ですが、**`ScrollView` の中身が描かれません**(実測 2026-09-10。
  枠だけが出て一覧が空になり、実装の不具合と見分けがつかない)。AppKit に描かせれば実物と同じです。
- 表示言語と明暗は `.environment(\.locale, …)` / `.environment(\.colorScheme, …)` で振り、
  1回の実行で日本語・英語・ライト・ダークを撮ります。
- 出力はコンテナの `Caches` へ。確認が済んだら**撮影用のテストごと消します**(リポジトリに
  残すものではない)。

## 実物のアプリを外から操作する

- **Debug ビルドのコンテナは `com.qooProject.qooViewer.debug`**(普段使いのアプリとは保存データが別。
  → [02](02-project-and-build.md))。`defaults` のドメイン名もこちら。実データが要る確認は、
  普段使いのアプリで行うか、Debug 側に検証用のデータを作って行う。
- `open -a` でコンテナの `defaults` を書いてから起動し、シークレットモードで検証する。
  **ファイル選択ダイアログは自動操作しない**(サンドボックスの権限付与を伴うため)。
- System Events(アクセシビリティ)でメニューやボタンを叩き、`screencapture -R` で見た目を自分の
  目で確かめる。Dock からの再オープンは Dock タイルを AX でクリック、一瞬だけ出るウインドウは
  `CGWindowListCopyWindowInfo` で監視する。
- 検証を始める前にウインドウの位置・サイズと「隠す」系の設定のスナップショットを取り、
  終わったら元へ戻す。
- **Debug のコンテナにも実蔵書の名前が入っていることがある**(ストアを写した開発機では、コレクション名が
  棚にそのまま出る)。画面を撮る検証では、アプリを終えた状態で `default.store{,-shm,-wal}` とコンテナ内の
  `com.qooProject.qooViewer.debug/`(表紙の保管庫)を `cp -Rp` で控えてから同じ場所で改名して退避し、空の
  本棚で起動する。終わったら新しくできたものを消して改名を戻し、`cmp` で一致を確かめる。`defaults export`
  → `import` は消えたキーを消さないので、増えたキーは `delete` してから export を突き合わせる。
  本は `hdiutil` の使い捨てボリュームに合成名で置き、検証で残ったページ一覧キャッシュ
  (`Caches/.../BookPageLists/*.json`)も消す。2026-09-13 の段階 1 の検証がこの手順。
- GUI の挙動は、推測で2回外したらコンテナ内にログを仕込んで自分で読む。

## ファイルの同定の測り方

「このファイルは同じものか」に関わる API は、**思い込みが当たらない**ところが多いので測ります
(結論は [06](06-persistence.md#移動リネームへの追従) / [10](10-sandbox-and-security.md) と
`FileNodeIdentifier` / `BookLocationResolver` の型コメントが正典)。

- **ディスクイメージで測る。** `hdiutil create -size 10m -fs APFS -volname X -quiet X.dmg` →
  `hdiutil attach -nobrowse` → `stat -f "st_dev=%d st_ino=%i"` → `hdiutil detach`。
  **`-quiet` を付けた detach は失敗しても黙っている**ので、`mount | grep` で外れたことを
  必ず確かめること(付けっぱなしのまま「再マウントしても値が変わらない」という誤った結論を
  一度出した)。
- **`st_dev` はマウント順で変わる**(他のボリュームを先に挿すだけで変わる)。ボリュームの同定は
  `volumeUUIDString`。`volumeIdentifierKey` は `st_dev` と同じく変わる。
- **未接続のボリュームの代用にディスクイメージは使えない。** パスに触ると自動で再マウントされる。
- **ブックマークの解決エラーは、オプション無しで解き直さないと理由が分からない**
  (→ [10](10-sandbox-and-security.md#解決の失敗の理由はオプションを変えて解き直さないと分からない))。
  この手の測定は**サンドボックスの中**(テストホスト)で行うこと ―― 素の CLI で測った値は
  アプリでの挙動と一致しないことがある(実際、CLI では区別できたエラーが、アプリでは
  同じコードに潰れていた)。

## メモリの測り方

- 数字は `task_vm_info.phys_footprint`(`ProcessResourceSampler` と同じ)。`vmmap` で内訳。
- 分かっていること: CGImage の表示は元の約3倍、malloc の大ブロックは解放しても footprint が
  戻らない(mmap は戻る)、ImageIO のサムネイルは purgeable。
- リソースモニタ(サイドパネル)は、このアプリに組み込まれた計測器です。「説明のつかないメモリ」
  (footprint − 意図して確保しているキャッシュ)が増えていないか、異常の欄が空か、を見ます。

## 閉じたウインドウが解放されるかの測り方

2026-09-13 に「本のウインドウを閉じても中身が残る」を測ったときの手順と、踏んだ罠
(結論は [13](13-history-and-known-limitations.md#既知の制限))。

- **生存数は `heap <pid>` で数える。** Swift のクラスも名前で出る(`AppState`・`ViewerViewModel`・
  `PageLoader`・`..NSKVONotifying_SwiftUI.AppKitWindow`)。コードに手を入れずに測れる。アドレスは
  `heap -q --noContent --addresses=AppState <pid>`、持ち主の経路は `leaks --traceTree=<addr> <pid>`
  (保守的なスキャンなので Swift Metadata・Dispatch continuations を根にした誤検出が大量に混ざる。
  名前の付いたオブジェクトの近いほうだけを読む)。2回ぶんの `heap` を差分にして「1回ごとに1個ずつ
  増えるクラス」を拾うと、残っている一式の範囲が分かる。
- **ウインドウが本当に閉じたかは CGWindowList で見る**(`CGWindowListCopyWindowInfo([.optionAll], …)`)。
  AX のウインドウ一覧から消えても、`onscreen=false` で残っていることがある。
- **最後のウインドウを閉じるとアプリが終了する**ので、閉じる前に「新規ノーマルウインドウ」をもう1枚出す。
- **同じ本が既に開いていると `open -a <app> <本>` は既存のウインドウを前に出すだけ**で、新しく開かない。
  繰り返しの計測では、前の回の本のウインドウが本当に消えているかを毎回確かめる。
- **メニューの「ウインドウを閉じる」は `NSApp.keyWindow` に効く。** AX の `AXRaise` ではキーウインドウは
  変わらないので、狙ったウインドウを閉じるなら、そのウインドウの閉じるボタン
  (`first button of window "…" whose subrole is "AXCloseButton"`)を押す。
- **Debug ビルドの `NSLog` は unified log(`/usr/bin/log show`)に出てこなかった。** ライフサイクルの
  確認は、コンテナの `tmp/` のファイルへ追記する一時的な関数で行った(コミットしない)。
- 本を表示したウインドウと、本を開かないウインドウを**必ず並べて**測る。後者が解放されるなら、
  原因は本の表示側に絞れる。
- **閉じた直後に数えない。** 解放は次のイベント(マウスの移動など)まで遅れることがある。閉じたら
  `cliclick m:` でカーソルを動かして5秒待ってから数える。これを知らずに同じ条件で「残る/消える」が
  ぶれ、切り分けを一度やり直した。
- 実害の大きさは `footprint <pid>`(phys_footprint、MB)を開閉のたびに取って比べる。この件では
  1回あたり +118MB という数字で優先度が決まった。
- 部品を1つずつ外す切り分けは、**外しても残る**が続くときは「複数の部品が独立に掴んでいる」ことを
  疑い、`leaks --traceTree` の `__strong` 付きの近い持ち主(この件では `SwiftUIAppKitButton
  .configuration.action.context` と `AppKitDialogBridge.lastDialogValues`)を先に読む。

## ファイルブラウザ

2026-09-13 の段階 3 の実機検証の手順(→ [15](15-file-browser.md))。上の「実物のアプリを外から操作する」の手順
(Debug のストア・表紙・defaults を控えて退避し、空の本棚で起動)に次を足した。

- **ストアだけを退避して表紙の保管庫を残したまま起動しない**(2026-09-14)。起動時の掃除が、参照の無くなった表紙の元画像を
  保管庫の中の `.orphaned/` へ隔離する(docs/14。30 日は消えないが、戻すまで保管庫の中身が控えと食い違う)。退避するなら
  `Application Support/com.qooProject.qooViewer.debug/` ごと。やってしまったら、そのフォルダを控えから丸ごと戻して `diff -r` で確かめる。

- 使い捨てボリュームは **`-nobrowse` を付けずに**付ける(付けると「コンピュータ」とツリーに出ない ―― Finder と同じ規則)。
  中は合成名のフォルダ・画像フォルダ・zip で作った cbz・テキスト。起動時のフォルダは defaults で
  `qooViewer.welcome.mode = browser`、`qooViewer.pref.fileBrowser.startupLocation = lastFolder`、
  `qooViewer.fileBrowser.lastFolderPath = /Volumes/<ボリューム>` にして、**ホームや蔵書のボリュームへ移動しない**
  (画面に実在のフォルダ名が写る)。
- 読めないフォルダは `chmod 000` で作る(サンドボックスの `needsAccess` と同じ表示になる)。FSEvents の追従と
  「消えたフォルダの祖先への退避」は、表示中にシェルからファイルを足す/フォルダを消して確かめる。
- **画面がロックされていると、`screencapture` は真っ黒、System Events はウインドウ 0 枚を返す**(アプリは動いている)。
  `CGSessionCopyCurrentDictionary()` の `CGSSessionScreenIsLocked` を先に見る。
- すりガラス 2 条件は defaults で `qooViewer.pref.surface.welcome.{tintColor,tintOpacity,contentShadowLevel}` と
  `qooViewer.pref.appAppearance` を書いて起動し直す。AppKit の部品(三角・列の見出し・標準のボタン)が消えるのは
  ここでしか見つからなかった。
- リークは File ›「新規ノーマルウインドウ」→ ⌘W を繰り返し、`heap <pid>` で `FileBrowserState` / `AppState` /
  `FileBrowserTableView` の数が増えないことを見る(閉じた直後の 1 つぶんは SwiftUI が遅れて手放すので、回数を増やして比べる)。
- 終わったら `NSTableView … qooViewer.fileBrowser.list` など**検証で増えたキーを消してから** `defaults import`。
- ファイル選択ダイアログ(「アクセスを許可…」・よく使う項目の「＋」)とホームの初回の許可・TCC のダイアログは自動操作しない。
- 書く操作(段階 4、2026-09-13): 別ボリュームへのコピーと衝突は、使い捨ての APFS ボリュームを 2 本付けて行う。
  **SSD 上のイメージ間では 900MB のコピーが 1 秒未満で終わり、進捗の帯は途中を撮れない**(衝突の確認を待つ間だけ見える)。
  取り消しでゴミ箱へ行ったものは、そのボリュームの `.Trashes/<uid>` に入る(ボリュームを外せば消える)。
- AppKit の右クリックメニューの淡色は、縮小した画像では見分けられない。メニューを上下 2 つの範囲に分けて等倍で撮る。
- アイコン表示のキーは、項目を選んだあとの ⌘⌫・⌘[ と、**検索欄に文字を入れた状態の ⌘⌫(文字だけが消え、項目は残る)**を両方見る。
- ドラッグ&ドロップ(段階 4b): ドラッグは CGEvent(`leftMouseDown` → `leftMouseDragged` を 20ms 刻みで 30 回 → `leftMouseUp`)を
  `cghidEventTap` へ送る小さな Swift のプログラムで合成できる(qooViewer から他のアプリへのドラッグも Finder からのドラッグも同じ)。
  **修飾キーはマウスのイベントの flags に載せ、⌥ / ⌘ のキーの押し下げも送る**。キーを離すイベントがボタンを離すイベントより先に処理されると
  `NSEvent.modifierFlags` は修飾なしを返す(アプリは離した瞬間のイベントから読むので通るが、判定のログを読むときに混乱する)。
  受け口の判定はコンテナの `tmp/` へのログで見た(SwiftUI の `dropUpdated` が `performDrop` の後にも届くのはこれで分かった)。
  Finder のウインドウは AppleScript で使い捨てボリュームを表示させ、アプリのウインドウと重ならない位置に置く。
- **クリックとキーを送る前に、毎回 qooViewer が最前面かを確かめる**(`System Events` の `bundle identifier of first process whose frontmost is true`。
  違えば打たずに止める)。2026-09-14、起動直後に送ったクリックが前にいた別のアプリのウインドウへ入った。
  `cliclick t:` は日本語のキー配列では文字を打てない。`keystroke` はかな入力になるので、編集欄に焦点があるうちに英数キー(`key code 102`)を送ってから打つ。
- 「置き換える」の起動時の復旧(段階 4b、2026-09-14): Debug のコンテナの `Application Support/FileOperations/replace-backups.json` に
  `[{"backupPath": …, "targetPath": …}]` を手で書き、使い捨てボリュームに `.qooViewer-replace-<任意>/<名前>` を作って起動する。
  終わったら**記録のフォルダごと消す**(残すと、外したボリュームを次の起動で探して警告が出る)。ロックは `chflags uchg` で掛ける。
  使い捨てボリュームの `.Trashes` はシェルから読めない(Permission denied)ので、ゴミ箱の中の状態は ⌘Z の結果で確かめる。
  **ゴミ箱に触るプローブを一時フォルダで走らせない**(`NSWorkspace.recycle` は起動ボリュームなら本物の `~/.Trash` へ入れる)。
- **サンドボックスの許可の有無を測るときは、Debug に残っている許可を先に疑う**(2026-09-14、Finder からのペーストの実測)。
  ① テストで作られた Debug の app(DerivedData)には Xcode が `com.apple.security.temporary-exception.files.absolute-path.read-only` = `/` を
  足している(`codesign -d --entitlements -` で見える)。`-derivedDataPath` を scratchpad にした素の `build` なら付かない。
  ② Debug の defaults の `qooViewer.grantedFolderBookmarks` に `/` の許可が入っていることがある(開発中に付けたもの)。控えてから `defaults delete`
  して起動し、終わったら `defaults import` で戻す。どちらも、プロセスへの判定を `sandbox_check(pid, "file-read-data", SANDBOX_FILTER_PATH, path)` を
  呼ぶ小さな C のプログラムで確かめてから測る(一度、両方が効いたまま「拡張の無い URL でも読める」と測ってしまった)。
  対照は「一度もペーストボードに載せていない同じボリュームのファイル」が拒否されること。
- **環境設定ウインドウを撮るときは、先に defaults で画面を選ぶ**(2026-09-14、ツリーの自動展開の検証)。環境設定は前回の画面
  (`qooViewer.settings.selectedPane`)で開き、「フォルダのアクセス権」には許可したフォルダの実名が出る。アプリを終えた状態で
  `defaults write … qooViewer.settings.selectedPane fileBrowser` としてから起動して ⌘, で開く。キーは後始末の `defaults import` で戻る。
- **Finder の挙動を写すときは、実物の Finder を同じ手順で操作して測る**(2026-09-14、一括リネーム)。使い捨てボリュームに合成名のファイルを置き、
  AppleScript で Finder のウインドウに表示・選択し、System Events でメニュー(1 件選択だと項目名が「“名前”を名称変更」に変わる)とシートを操作して、
  結果はシェルの `ls` と中身で対応を取る。**始める前に `com.apple.finder` の関係するキーを控え、終わったら書き戻す**(Finder は入力を覚える)。
  AX で欄に `set value` した値は例の行へ反映されないことがあるが、押した結果には使われる。文言と書式は Finder の
  `Resources/<言語>.lproj/*.strings`・`LocalizableMerged.strings` を `plutil -p` で読める(日付の書式 `DATE_FORMATTER1` はここにあった)。
  APFS は大文字小文字を区別しないので、`aA.txt` と `Aa.txt` を続けて作ると 1 つになる(測り間違えた)。

- **選ばれている行を左クリックしてから右クリックしない**(2026-09-14、圧縮・展開の検証)。2 回目のクリックで名前の編集が始まり、右クリックのメニューが
  名前の欄の文字のメニュー(Google で検索・スペルと文法…)に変わる。選ばれていない行は右クリックだけで選ばれる。編集が始まってしまったら Esc を 2 回(メニュー・編集)。
- **書庫の日時は `stat` と `unzip -l` で突き合わせる**(2026-09-14)。同じライブラリで書いて読み戻すテストは一致してしまい、ZIPFoundation が MS-DOS 形式の
  日時を UTC として扱う(9 時間ずれる)ことは実物の Finder の zip を展開して初めて見つかった。
- **空の本棚で起動すると `Caches/<bundle id>/CollectionTiles/` が空になる**(2026-09-14、段階 7a の検証)。起動時の孤児の掃除が、ストアに無い
  コレクションのタイルを消す。表紙から作り直せるキャッシュなので戻さなくてよいが、控えと突き合わせるなら Caches も控えておく。
  ファイルブラウザの絵のキャッシュ(`FileBrowserThumbnails/`)は検証で作られるので、終わったら消す。
- 環境設定の右ペインを下まで送るには、AX で `scroll bar 1 of scroll area 1 of group 2 of splitter group 1 of group 1 of window "<画面名>"` の
  `value` を 1 にする。SwiftUI のボタンは AX の名前を持たないので、撮った画像から座標を出して `cliclick` で押す。
- **動画の絵(段階 7b、2026-09-14)は、実物のソースを CLI と一緒にコンパイルして先に測る**。`Services/FileBrowserThumbnails/` の
  `VideoThumbnailer.swift`・`RetaggedHEVCThumbnailLoader.swift`・`MediaContainerSniffer.swift`・`MatroskaDimensionReader.swift` と
  `Services/FileOperations/FileIO.swift` を、`FileOperationError` だけを作り物にした `@main` のファイルと `swiftc -swift-version 6
  -enable-upcoming-feature NonisolatedNonsendingByDefault -parse-as-library` でまとめると、QuickLook と再タグ付けの経路ごとの結果と時間が出る。
  合成の動画は `AVAssetWriter`(H.264 / HEVC、斜めの縞にすると縦横比の潰れと上下の反転が見える)。**`hev1` は HEVC の mp4 の `hvc1` の 4 バイトを
  書き換えるだけで再現する**。Matroska は ffmpeg が無くても、mp4 のサンプルを `AVAssetReaderTrackOutput(outputSettings: nil)` で読んで
  EBML(Info・Tracks(`V_MPEG4/ISO/AVC` + `avcC`)・Cluster の SimpleBlock)を手で組めば QLMedia が読む。qlmanage は応答しないことがあるので使わない。
  よく使う項目は defaults の `qooViewer.fileBrowser.favoriteLocations` に JSON(`[{"id","path"}]`)を `-data` で書けば、使い捨てボリュームのフォルダを
  「＋」のダイアログ無しで登録できる(読めるかは Debug に残っている許可しだい)。事前生成の進みは Caches の `FileBrowserThumbnails/` の枚数で見る。
- **場面で変わるメニュー項目(閉包を載せた NSMenuItem)は、実機で 1 回は押す**(2026-09-14、段階 8)。組み立てと淡色の判定はテストで見られるが、
  押したときに閉包へ届くかはメニューを通らないと分からない。今回は action の名前が NSObject の `perform(_:)` とぶつかり、全部が無反応だった。
  **押した結果が画面に出ない操作(コレクションへの登録など)は、ストアを `sqlite3 -readonly` で読んで確かめる**(`ZCOLLECTIONITEM` の `ZBOOKID`、`ZBOOKMETADATA`)。
  同じ仕組みの別の項目(「このアプリケーションで開く ▸ その他…」でパネルが出るか)と比べると、配線の問題か処理の問題かを 1 回で切り分けられる。
- **保存先を尋ねるパネル(NSOpenPanel)は、出たことだけ確かめて Esc で閉じる**。撮った画像にはパネルに実在のフォルダ名が写りうるので、見ずに消す。
- **ウインドウのタイトルは AX の `name of windows` で読める**(タブのうち前面のもの)。タブ全部の名前はタブバーを撮る。
- **Debug のコンテナに実ストアの写しがあるまま起動しない**(2026-09-14、段階 8.5)。ウェルカム画面の帯にライブラリの名前が出る。
  控えを取ったら `Application Support/` の `default.store*` と `com.qooProject.qooViewer.debug/` を退避してから起動する(上の「表紙の保管庫を残したまま起動しない」)。
- **環境設定の画面は、スイッチを押す前に撮って画面の名前を確かめる**(2026-09-14)。`defaults import` で `qooViewer.settings.selectedPane` が戻ると、
  次に開いたときは別の画面(「フォルダのアクセス権」)で開き、「ファイルブラウザ」の「読み取り専用」のスイッチの座標には、許可したフォルダの削除ボタンがある。
- **右クリックのメニューが開いたかは `CGWindowListCopyWindowInfo` で数える**(qooViewer のウインドウが 1 枚増える)。撮った画像に何も写らないとき、
  メニューが出ていないのか撮る時機がずれたのかをこれで切り分けられる。System Events の `focused of windows` はキーのウインドウでも false を返すので、
  キーかどうかの判定には使えない(一度これで「キーでない」と誤診した)。
- **クリックがどこに届いたかは、`NSEvent.addLocalMonitorForEvents` の中で `event.window?.contentView?.hitTest(event.locationInWindow)` をログに出す**
  (2026-09-14、段階 8.5)。アイコン表示の SwiftUI の右クリックでサブメニューを開いて閉じたあと、リストの右クリックが開かなくなった件は、これで
  「当たり先が表ではなく名前の欄になっていて、表の `rightMouseDown` / `menu(for:)` が呼ばれていない」と 1 回で分かった(docs/15「実機で見つけて直したもの」)。
  ログは `#if DEBUG` でコンテナの `Library/Logs/` へ書き、原因が分かったらコードもファイルも `Logs/` フォルダも消す。
- **利用者が Mac を使っている最中は、カーソルを動かす・画面を撮る検証をしない**(2026-09-14)。Debug を Xcode から動かしている最中に、
  検証用の再現アプリを開いてカーソルを動かし `screencapture -R` で撮ったところ、再現アプリのウインドウが利用者のウインドウの後ろに回っていて、
  **蔵書の実名が写った**(すぐ削除)。その前にも、座標の範囲がウインドウの外へはみ出して別のアプリの文字が写った。先に `pgrep` で qooViewer と
  Xcode の実行を確かめ、動いていればコードの読みとビルドまでにして、画面での確認は利用者に頼む。撮るなら範囲をウインドウの内側に限り、
  撮る直前にそのウインドウが最前面か(`CGWindowListCopyWindowInfo` の並び順)を確かめる。
- **SwiftUI の部品の振る舞いは、scratchpad の最小の再現アプリで一度に並べて測る**。`.contextMenu` の中の `Menu` に `.disabled` が効かない件は、
  無効にする書き方を 10 通り並べたメニューを 2 回撮って決着した(`NSApplication` + `NSWindow` + `NSHostingView` を自前で立てて `./probe`)。
- **名前の編集の検証は、名前の文字の上をクリックする**。行の左端(アイコン)をクリックしても編集は始まらないので、「始まらない」ことを確かめるときは
  必ず対照(始まるはずの条件で同じクリック)を先に取る(一度アイコンの上を押して「読み取り専用で始まらない」と誤って判定しかけた)。
- **Finder は、ドロップを受けたり Finder のウインドウでマウスを押されたりすると前面に出る**。続けて qooViewer へキーやクリックを送る前に `activate` し直す。
- **使い捨てボリュームが外れないときは `lsof +D` で持ち主を見る**。ほかのアプリのサムネイルの拡張(書庫を読みに来る)が書庫を開いたままで、
  `hdiutil detach` が「リソースが使用中」になった。`-force` で外した。

## テスト中に出る虹色のカーソル

テストはこのアプリの中で走るので、テストの間は Debug 版のウインドウが出る。`@MainActor` のテストがメインスレッドを
次々に使うため、**そのウインドウはテストが終わるまで応答しない(虹色のカーソル)**。統合ログの
`spindump … qooViewer [<pid>]: spin` の時刻がテストの実行と重なり、`sample` のメインスレッドが `Runner._runTestCase`
なら、アプリの不具合ではない(2026-09-13 にユーザーの報告から確認)。

- そのウインドウが自分から共有の状態に触れないよう、`RuntimeEnvironment.isRunningTests` の間は止めてある
  (ウェルカム画面は本棚で始める ―― 以前は Debug の設定がファイルブラウザだと実際のホームを読みに行っていた。音も鳴らさない)。
  アプリの起動時に何かを始める処理を足すときは、テスト中にも走ってよいかを決めること。
- テストの最中に `CGWindowListCopyWindowInfo` を回し続けたら、時間を測る `FileIOTests` が 1 件落ちた(負荷で 22 秒)。
  テスト中のウインドウを観察するときは、測るテストと並べない。

## テスト用の使い捨てボリューム

別ボリュームへの移動・exFAT の縮退経路・空き容量の検査は、起動ボリュームの一時フォルダでは確かめられない
(同一ボリュームの移動は rename、APFS のコピーはクローンで、バイトを運ぶ経路が通らない)。
`scripts/test/test-volumes.sh attach` が `/Volumes/qooViewerTest-{apfs,exfat,fat32,tiny}` を `-nobrowse` で付け、
`detach` が外してイメージを消す。スキーム qooViewer の Test の前後で自動で走るので、普段は意識しなくてよい。

- xcodebuild を途中で止める(kill)と Post-action が走らず残る。次の `attach` が最初に外すが、すぐ片付けるなら
  `scripts/test/test-volumes.sh detach`。
- テストを止めるときに `pkill -f` を使うなら、**Debug のテストホストだけに当たるパターンにする**
  (`qooViewer.app/Contents/MacOS/qooViewer` だけだと、`/Applications` の Release 版を開いていれば一緒に落とす)。
- 実機の検証(本を置いて開く)は従来どおり自分で作った使い捨てボリュームで行う(→「実物のアプリを外から操作する」)。
  テスト用の 4 本はテストが作業フォルダを作って消すので、手で物を置かない。

## 応答しないネットワークボリュームを作る

「到達できない共有でファイルに触るとスレッドが止まる」経路は、使い捨ての WebDAV で再現できる
(`scripts/dev/webdav-server.py`。標準の `mount_webdav` だけで、管理者権限も追加のソフトも要らない)。

```bash
python3 scripts/dev/webdav-server.py <公開するフォルダ> 18089 &
/sbin/mount_webdav -S http://127.0.0.1:18089/ <マウント先>   # サンドボックスのアプリに触らせるなら、そのコンテナの tmp/ の中
kill -STOP <サーバのpid>    # ここから、まだ取得していないパスへの stat が 40〜90 秒止まる(alarm でも中断できない)
kill -CONT <サーバのpid>    # 解放。終わったら umount <マウント先>
```

- **WebDAV は「無い」と分かった名前を覚える。** 一度サーバを再開して応答させたパスは、次に止めても
  すぐ返ってくる。比較するビルドごとに、まだ使っていない名前で打つこと(同じ名前で比べて「修正前も
  止まらない」という誤った結果を一度出した)。ボリュームの属性も数十秒は覚えているので、マウントの
  一覧の件は「止めてから40秒待って起動」で測った。
- 止まっているスレッドは `sample <pid> 2` の出力から `stat` / `getattrlist` を含むスタックを数え、
  キュー名(`com.apple.root.*.cooperative` = Swift Concurrency のプール、専用キューなら自分の名前)で
  どこが握っているかを見分ける。2026-09-13 の実測: 自動登録フォルダの欄に12文字打つと、修正前は
  プールの10本(このMacのコア数)すべてが止まり、修正後は専用キューの1本だけ。

## 描画経路の測り方

`NSHostingView` のレイヤーツリーを実測して、SwiftUI の補間設定が CALayer のどのフィルタに
対応するかを確かめました(`.medium` = `.low` = linear)。遅延デコードの直描きが最速でした。

## メニュー再構築の現行犯逮捕

macOS 26 でメニューが落ちる問題では、(1) `NSMenu` の変異(`setItemArray:`)をログに出す、
(2) 各 `@Published` の publish にプローブを仕込む、(3) 人工的な遅延を入れて「メニューを開いている
最中に publish が届く」状況を再現する、の3つで「App 直下の `@StateObject` の publish は全メニューを
作り直す」ことを突き止めました。`MenuBarMenuGate` と `AppStores`(publish しない箱)はその結果です。

## 7z のアクセス順を変えたとき

フォーク側の `sevenzip-bench`(`swift build -c release` → `.build/release/sevenzip-bench archive.7z
シナリオ`)と、`7zz` で作った scratchpad の複製で測ります。footprint は1プロセス1シナリオ。
qooViewer 側では**「ブロック先頭からのやり直し回数」**(`Archive.folderStreamRestartCount`)を
数えてください。前後交互のアクセスは禁物です(→ [11](11-forked-dependencies.md))。

## 書き出しの検証

- **往復そのものは `qooViewerTests` が見ています**(`CbzExportTests` / `EpubExportTests` /
  `PDFExportTests`。書き出す → 読み込み側で開き直す → 中身の番号で並びを追う。
  → [02](02-project-and-build.md#テストターゲットqooviewertests))。書式が仕様に合っているかは
  CI が EPUBCheck と ComicInfo v2.0 の XSD で見ます(`scripts/ci/validate-exports.sh`)。
  手元で同じことをするなら、テストを結果バンドル付きで走らせてからスクリプトへ渡します:

  ```sh
  xcodebuild -project qooViewer.xcodeproj -scheme qooViewer -configuration Debug \
    -destination 'platform=macOS' -resultBundlePath /tmp/Tests.xcresult test
  EPUBCHECK_JAR=~/epubcheck/epubcheck.jar scripts/ci/validate-exports.sh /tmp/Tests.xcresult
  ```

- 実物の Exporter(`EpubExporter` / `PDFExporter` / `CbzExporter` は nonisolated で UI に依存しない)
  を SwiftPM のコマンドラインツールへ取り込めば、CLI から動かして出力を検証できます。
- EPUB は Kindle Previewer 3 の CLI と、同梱の JRE + EPUBCheck で検査します(`dc:language` の
  `und` と `group-position` の非数値は、この検査で見つかった)。
- 生成物は `unzip -l`、`xmllint`、`qpdf --check` などで中身を確認します。

## 用語と形を揃える

UI の文言は用語表(→ [01](01-overview.md#用語表))、一覧ウインドウは共通の形
(→ [09](09-ui-and-windows.md#一覧ウインドウの共通の形))に照らして確認します。
すりガラスの面に文字を足したら「ライト外観+黒 100%」「ダーク外観+白 100%」で見ます。

## git の扱い

コミット・プッシュ・履歴の書き換えは、その変更について明示的に指示があるときだけ行います。
方法が複数あるときは選んでもらいます。
