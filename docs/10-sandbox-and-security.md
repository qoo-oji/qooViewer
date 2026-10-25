# 10. サンドボックスとファイルアクセス

## 前提

App Sandbox + Hardened Runtime、`ENABLE_USER_SELECTED_FILES = readwrite`。アプリ本体にネットワークの
entitlement は無く、本体は通信しません。通信するのは自動アップデート(Sparkle)の Downloader.xpc(取りに行くのは GitHub の
appcast と更新の書庫だけ。→ [自動アップデート](#自動アップデートsparkle2026-10-10))と、アプリに入れた XPC サービス
`StackNestConnector.xpc`(この Mac の StackNest の本の API への決まった形の要求だけ。→ [StackNest の本と通信](#stacknest-の本と通信))
だけです。entitlement はビルド設定から生成され、Release だけ `Configurations/qooViewer.entitlements`(Sparkle の XPC
サービスと話す mach の名前 2 つ)が加わります(→ [02](02-project-and-build.md))。

サンドボックス下で触れるのは、

1. ユーザーがパネル・ドラッグ&ドロップ・Finder の「開く」で**直接選んだ**ファイル/フォルダ
   (そのプロセスの間だけ)、
2. それを**セキュリティスコープ付きブックマーク**(`URL.bookmarkData(options: .withSecurityScope)`)
   として保存し、次回以降に解決して `startAccessingSecurityScopedResource()` したもの、
3. 環境設定「フォルダのアクセス権」で許可したフォルダの配下すべて(`FolderAccessStore` が起動中
   ずっと開いたまま維持する)、
4. 自分のコンテナ(`~/Library/Containers/com.qooProject.qooViewer/`。Debug ビルドは
   `com.qooProject.qooViewer.debug/` で、中身は共有しない → [02](02-project-and-build.md))の中

だけです。**書庫ファイルを1つ開いただけでは、同じフォルダの他のファイルは見えません。**
「次の本へ/前の本へ」「同じフォルダのファイルを開く」「サイドパネルのフォルダブラウザ」は、
フォルダのアクセス権が無いと空になります。その場合は `AppState.ensureAccess` /
`SidePanelBrowserState.requestFolderAccess` がその場で許可を求めるパネルを出します。

## セキュリティスコープ付きブックマークを持つ場所

| 場所 | 何のため |
|---|---|
| `RecentFilesStore` | 履歴(ファイルメニュー・サイドパネル)から開く |
| `CollectionItem.bookmarkData` | コレクションから開く・カバーを抽出する |
| `Bookmark.bookmarkData` | 編集ウインドウから今開いていない本を開いてジャンプ |
| `BookLayoutSettings.bookmarkData` | 編集ウインドウでレイアウトだけある本のサムネイル |
| `BookLayoutSettings.externalCoverBookmarkData` | 本に含まれないカバー画像 |
| `BookMetadata.bookmarkData` | 書き出しウインドウがメタデータだけの本を解決する |
| `LastActiveBookStore` | 起動時に前回の本を開く |
| `FolderAccessStore` | 許可したフォルダ |
| `LastUsedFolderMemory` | フォルダ選択パネルの前回位置、書き出しの固定の保存先 |

コレクションの**自動登録フォルダ**(`BookCollection.autoFolderPath`)は意図的にブックマークを持たず
パスだけです。フォルダを列挙する権限は `FolderAccessStore` に一本化してあり、走査と FSEvents の監視は
`isPathCovered` に「いま列挙してよいか」を訊いて、覆われていなければ黙って見送ります(設定の面が
「アクセスを許可」を出す)。別のブックマークを持たせると、同じフォルダの権限を2箇所が別々に開閉する
―― 過去に漏れを出したのと同じ形になります(→ [14](14-library-collections.md#自動登録フォルダ))。

FSEvents は App Sandbox で追加の entitlement 無しに動き、読み取り権限の無いパスのイベントも届きます
(届いても列挙できなければ何もできないので、許可済みのフォルダだけを渡す)。ネットワークボリューム
(SMB/AFP)では飛びません。

`bookID` はパス文字列でしかなく、それだけでは(許可済みフォルダの配下でない限り)開けません。
ブックマークを持たない古い行は、本を開けた(=アクセス権がある)タイミングで補完します(`backfill*`)。
複数のストアが同じ本のブックマークを持ちうるので、`BookURLResolver.Candidates` は全部を集めて
解決できたものを使います。

## 約束事

### start と stop は必ず釣り合わせる

`startAccessingSecurityScopedResource()` は参照カウント式で、**開いたのと同じ URL オブジェクト**へ
`stop` を呼ばなければなりません。過去に `_ = url.startAccessingSecurityScopedResource()` と
開きっぱなしにしてカーネルリソースを漏らしていた箇所が複数あり、次の形に直してあります。

- `AppState.securityScopedBookURLs`: 今開いている本のぶん。次の本を開くときと閉じるときに stop。
- `FolderAccessStore.accessedURLsByPath`: `reload()` のたびに差分だけ開閉。追加した直後の
  フォルダも同じ経路で開く(呼び出し側で開かない)。
  起動時とボリュームの取り付け・取り外しでは `reloadInBackground`(2026-09-27、表示の切り替えの監査の 11): 開いているものは
  そのまま使い、ローカルのブックマークはその場で解決し、**ネットワークボリュームの上のものだけ**を 1 件ずつ `FileIO` で解決して、
  済んだものから開いて一覧へ足す(`accessGained` を送る ―― 自動登録フォルダの走査とスマートライブラリの集め直しがやり直す)。
  以前は起動時にすべてをメインで解決し、応答しない共有の許可が 1 つあると最初のウインドウが出る前に約 30 秒止まった。
  解決が済むまでそのフォルダは「許可なし」(先に「ある」と答えると、スコープを開く前の `fileExists` の失敗を「消えた」と
  読む判定が保存データを消しうる)。待ちたい所は `waitForPendingResolutions`(期限で包む)。ローカルを同期のままにしたのは、
  起動直後の仕事(スマートライブラリの集め直し・ファイルブラウザの最初の一覧)が、解決の前に読んで空の結果を出さないため。
- `BookLayoutEditorViewModel.securityScopedURL` / `BookExportViewModel.securityScopedURLs`:
  ウインドウが生きている間はサムネイルのために開いたままにし、`deinit` で閉じる。
  同じ本を何度読み込んでも開くのは1回だけ(Set)。
- `SecurityScopedHandoff`: 履歴・コレクション・ブックマーク一覧から**別のウインドウ/タブ**へ
  URL を渡すとき、受け取った側の `AppState.open(url:)` が走るのは次以降のランループなので、
  渡す直前に開き、10 秒以内に受け取り側が引き取る(引き取ったら渡し側が閉じる)。
- 存在確認だけの一時的な open/close(`fileExists(bookmark:)`)は、その場で対にする。

### 解決は重い ―― 表示のためにメインスレッドで解決しない

`URL(resolvingBookmarkData:)` は、対象が未接続の外付け/ネットワークボリュームを指していると
ボリュームの探索を試みて**秒単位でブロック**します。次の設計はすべてこの一点から来ています。

- 履歴の一覧はキャッシュしたパスだけで描き、解決は開くときだけ。再検証はアプリのアクティブ化と
  ボリュームのマウント/アンマウントで非同期に(`RecentFilesStore`)。
- コレクションの本の実在確認はキャッシュ(`existenceByItemID`)を読むだけ。未確認は「存在する」扱い
  (起動直後に全部が消えたように見えないため)。確認はメインアクターの外。
- 書き出しウインドウの対象一覧の実在確認は `BookURLResolver` でメインアクターの外。
- 「保存データの削除」の実在判定は3値(exists / missing / **unknown**)。アクセス権が無くて確認
  できない本を「消えた」と表示して削除を促さない。判定済みの本は再判定しない。
- 履歴の削除ウインドウには「実在するか」の列を**意図的に置かない**。
- メインアクターの外へ渡すのは `Sendable` な値(UUID・Data)に写し取ってから。

### 裏の解決は繋がっていないボリュームへ繋ぎに行かない(2026-09-24)

既定のオプション(`.withSecurityScope` だけ)で解決すると、指す先のボリュームが繋がっていなければ**繋ぎに行く**。
NAS の電源が落ちていると約 30 秒後に macOS の「サーバ“…”への接続で問題が起きました」が出る(どのアプリのせいかは
書かれない。利用者の報告)。統合ログで、qooViewer が外付けの取り外しの知らせを受けてブックマークを十数件解決した直後に
ScopedBookmarkAgent が `smb://…` のマウントを求め、30 秒後に NetAuthAgent が起動したのを確かめた。取り出した
ディスクイメージも既定の解決で**勝手に付け直される**(実測)。

解決はすべて `BookmarkResolution` を通す。裏で自動に行う解決(在りかの確かめ・移動の検出・カバーの抽出・書き出し・
取り込み・起動時の復元・パネルの最初の場所)は `.background` = `.withoutMounting` + `.withoutUI`、利用者が本を**開く**
操作(コレクション・ブックマーク一覧から開く、Finder に表示…)だけ `.userOpen` で従来どおり繋ぎに行く。
引数の既定は `.background`(新しい呼び出しが既定のままでも、ダイアログを出す側には倒れない)。

繋がっていないボリュームの上の本は、`.withoutMounting` で**約 10ms で `NSFileNoSuchFileError`(4)** ―― 実体が無いときと
同じコードで失敗する(実測 2026-09-24)。したがって「無い」と言い切る所は、ボリュームが付いているかを**マウントの一覧で**
別に確かめる(`BookLocationResolver.isVolumeAvailable`、`BookExistenceProbe` の `isOnAnUnmountedVolume`。後者は以前、
許可済みの共有の上の本を NAS が落ちている間「実体の無い本」に数えていた)。

### 存在確認の判定順(LibraryCleanupViewModel.evaluate)

1. いずれかのストアのブックマークから URL を解決できるなら、開いて `fileExists`(最も確実)。
2. 解決できなくても許可済みフォルダの配下なら、素のパスの `fileExists` を信用する。
3. どちらでもなければ、`fileExists` が成功すれば存在する。失敗は「無い」のか「見えない」のか
   区別できないので `.unknown`。

### ブックマークの解決は削除されていても成功しうる

解決に加えて `fileExists` まで確認しないと、削除済みのファイルが履歴に残り続けます
(`RecentFilesStore.resolveForOpening` の修正)。

### 解決の失敗の理由は、オプションを変えて解き直さないと分からない

**エラーコードはブックマークの種類ではなく解決時のオプションで決まります**(アプリ本体の中=
サンドボックス下で実測 2026-09-10):

```
                        .withSecurityScope      オプション無し
実体を消したブックマーク   259 (フォーマット違い)   4 (ファイルが存在しません)
壊れた・切れたデータ       259                    259
生きているファイル         成功                    成功
```

`.withSecurityScope` を付けた解決は、**実体が消えただけでも壊れたデータと同じ 259 で失敗する**
ため、それだけでは「無くなった」と「ブックマークが使えなくなった」を区別できません。
オプション無しで解き直すと 4 と 259 に分かれます(権限は付きませんが、失敗の理由を知るだけなら
それで足ります)。この2段構えが `BookLocationResolver` の土台です
(→ [14](14-library-collections.md#実体の確認--見つからないには理由がある))。

リネームと**ゴミ箱への移動は解決に成功します**(`bookmarkDataIsStale` が立つだけで、
`fileExists` も true)。ゴミ箱を空にして初めて失敗します。

### ボリュームが付いているかは、解決結果から判断しない

未接続のボリュームを指すパスに触ると、ディスクイメージでは**自動で再マウントされました**
(実測)。「解決できたか」はボリュームの有無の証拠になりません。記録してある `volumeUUID` を
`FileManager.mountedVolumeURLs` の一覧と照合します(→ [06](06-persistence.md#移動リネームへの追従))。

## 記録の線引き

何を記録するか/しないかは [06](06-persistence.md#シークレットウインドウとその場限りの本) に
まとめてあります。**フォルダのアクセス権だけは、シークレットウインドウでもその場限りの本でも
保存します**(本の記録ではなく権限そのもの)。「すべてのデータを削除」でも残します。

## Finder で表示

`FinderReveal` / `PageFileAccess`。フォルダの本のページは実物を選択、書庫や PDF の中のページは
入れ物のファイルを選択(代わりに「画像を書き出す」の導線を出す)。入れ子書庫のページは
一時ファイルではなく本を指す。サイドパネルのフォルダブラウザは `NSWorkspace.shared.open`。

隣の「ファイルブラウザで表示」(`AppState.revealInFileBrowser`)は同じものを qooViewer のファイルブラウザで見せる。
Finder と違って**読めるのは `FolderAccessStore` に許可のあるフォルダだけ**で、本を 1 冊開いた許可では隣が読めないので、
許可が無ければファイルブラウザの側に「アクセスを許可…」が出る(→ [15](15-file-browser.md#ファイルブラウザで表示filebrowserrevealswift))。

## ファイルブラウザ(改善要望7)

ホームのファイルブラウザは、利用者が入ってもいない場所に自分から触る部品(ツリーの三角・アイコン表示の絵・動画の絵の先回り)を
持つので、このアプリの中でいちばん TCC(デスクトップ・書類・ダウンロード・`~/Library` の他のアプリのデータ)とネットワークに近い。
約束の一覧は [15「サンドボックスと TCC の約束」](15-file-browser.md#サンドボックスと-tcc-の約束)。要点:

- 読むのは `FolderAccessStore` の許可の下だけ。読めなければ「アクセスを許可…」から許可を足す(ここで足した許可も、よく使う項目の「＋」で
  足した許可も、「フォルダのアクセス権」の一覧に並ぶ)。**よく使う項目はパスだけ**を持ち、ブックマークを持たない(自動登録フォルダと同じ理由)。
- 実際のホームフォルダは `getpwuid` で引く(`homeDirectoryForCurrentUser` はコンテナを返す)。
- **自分から中を読む部品は、保護下の場所をパスの文字列だけで、ネットワークをマウント表で除外する**(触ることがダイアログや 30 秒のブロックの
  引き金になるので、確かめるために触ることもしない)。
- iCloud などに追い出されたファイル(`SF_DATALESS`)の絵は作らず、読み取りはスレッド単位で実体化を切る(`setiopolicy_np`。サンドボックスの中でも掛けられる)。
- **ペーストボードから読んだ URL には、その項目自身への読み書きの許可が付く**(親フォルダには付かない。2026-09-14 実測)。許可の無い場所の
  項目も貼れるが、移動すると元へ戻せないので、移動の前に元のフォルダを `access(W_OK)`(サンドボックスの判定も返す)で見て尋ねる。
- Finder へのドラッグの移動は Finder が行い、サンドボックスに掛からない。
- 「置き換える」の途中で落ちたときの復旧(`ReplaceBackupRecovery`)は起動時に走り、戻すフォルダの許可が要る。許可の無い場所の記録は戻さずに残す。
- 許可の有無を実測するときは、Debug の app に Xcode が足す一時的な例外と、開発中に付けた `/` の許可を先に外す
  (→ [12](12-verification-and-debugging.md#ファイルブラウザ))。

## ゴミ箱と使い捨てボリューム(改善要望7 段階 2、2026-09-13 実測)

- **サンドボックスでも `NSWorkspace.recycle` は実際のホームフォルダの `~/.Trash`(外付けなら `.Trashes/<uid>/`)へ送り、
  戻せる**(qooLibrary と今回の実測)。`FileOperationEnvironment.live` はこれを使う。
- **ゴミ箱があるかは問い合わせだけで決めない**(`TrashAvailability`)。作ったばかりの APFS / exFAT / FAT32 では
  `url(for: .trashDirectory, create: false)` が 3328 で失敗するのに、recycle は `.Trashes` を作って普通に入れる。
  問い合わせが通る**か**マウント表でローカルなら「ある」。ネットワーク越し(SMB)で `.Trashes` が無ければ「無い」
  ―― そこで recycle すると OS の確認を経て完全削除され、ゴミ箱の中の URL が返らない(qooLibrary 実測)。
- **テストホスト(サンドボックスの中)からは `hdiutil` を起動できない**(`deny(1) mach-lookup com.apple.system.hdiejectd.xpc`)。
  外で付けたボリュームへの読み書きはできるので、テスト用のボリュームはスキームの前後処理で付ける
  (→ [02](02-project-and-build.md) の「テストターゲット」)。

## 一時ファイルとキャッシュ

コンテナの `tmp/` と `Caches/` の中だけを使います。一時ファイルは起動ごとのディレクトリで、
起動時に他の pid のものを掃除します(OS は自動では掃除しない。11 日前のものが残っていた)。
キャッシュは容量逼迫時に OS が消してよく、Time Machine の対象にならない場所です
(再生成できるものしか置かない)。

## 自動アップデート(Sparkle、2026-10-10)

Sparkle 2(`sparkle-project/Sparkle`、**正確な版**で固定。→ [11](11-forked-dependencies.md#sparkle2026-10-10))で
配布版を更新します。コードは `Services/AppUpdater.swift`、設定は `qooViewer/Info.plist` のコメント、配る前の確かめは
`scripts/release/check-release-app.sh`、appcast を作る手順は [02「リリース」](02-project-and-build.md#リリース)。

### 信頼の根は EdDSA の鍵 1 本

このアプリは Developer ID で署名・公証していない(Apple Development 証明書)ので、Sparkle の「Apple のコード署名が
同じチームなら鍵を差し替えてよい」という逃げ道も使えません。**更新を受け入れるかどうかは、作者の Mac のキーチェーンにある
Ed25519 の秘密鍵で署名されているかだけで決まります。**

| 何を確かめるか | 設定 | 意味 |
|---|---|---|
| 書庫の署名を**展開する前に** | `SUVerifyUpdateBeforeExtraction = YES` | 改ざんされた書庫を展開の処理に通さない(2.9 系で展開時のシンボリックリンクの脆弱性が続いた) |
| appcast(版・リリースノート)の署名 | `SURequireSignedFeed = YES` | 配信元を乗っ取られても、偽の版番号やリリースノート(偽のリンク)を見せられない |
| 署名の合わない appcast を受け入れない | `SUSignedFeedFailureExpirationInterval = 0` | 既定の 20 日では、署名の合わない状態が続くと期限切れで受け入れる(鍵の差し替え用)。差し替えはしない前提なので閉じる |
| 配信元 | `SUFeedURL` を HTTPS に固定 + デリゲートが Info.plist の値を返す + 起動時に defaults の `SUFeedURL` を消す | Sparkle は defaults の `SUFeedURL` を Info.plist より優先する(古い API の名残)ので、`defaults write` で向け先を変えられないようにする |
| 公開鍵 | `SUPublicEDKey`(Info.plist にだけある。Sparkle は defaults からは読まない) | |

アプリは起動の前に `UpdaterConfiguration.validate` でこれらを確かめ、1 つでも崩れていれば Sparkle を起動しません
(更新が止まるほうが、確かめを緩めたまま更新を受け入れるより安全)。同じ約束を `UpdaterConfigurationTests`(出荷する Info.plist)と
`check-release-app.sh`(配る .app。CI の Release ジョブと `make-appcast.sh` が呼ぶ)が見ます。

**鍵をなくすと、以後のアップデートを配れません**(差し替える逃げ道が無いため)。`generate_keys -x` で書き出した控えを
リポジトリの外の安全な場所(パスワード管理ソフトなど)に置きます。**鍵が漏れると、誰でも「正しい」更新を作れます** ―― 漏れたら
新しい鍵を入れた版を手で配り直すしかありません(今の利用者のアプリは古い鍵の署名しか受け付けない)。リポジトリには入れない
(`.gitignore` と `make-appcast.sh` がリポジトリの中の鍵ファイルを拒む)。

### アプリ本体は通信しない

- サンドボックスの中のアプリはインストーラを自分で起動できないので、Sparkle.framework の中の `Installer.xpc` に頼みます
  (`SUEnableInstallerLauncherService` と、Release の entitlements の mach-lookup の例外 `<バンドルID>-spks` / `-spki`)。
- 取りに行くのは `Downloader.xpc`(`SUEnableDownloaderService`)。そのため本体に `com.apple.security.network.client` を足していません
  (`check-release-app.sh` が「無いこと」を確かめる。StackNest の本の通信も本体ではなく `StackNestConnector.xpc` がする)。
  代償は Sparkle の文書のとおり、リリースノートが古い WebView で描かれる・
  版ごとに出し分けられないこと。リリースノートは appcast に埋め込み(`--embed-release-notes`、markdown)、JavaScript は切ってあります。
- 送るものは Sparkle の既定の要求だけ(アプリ名と版・Sparkle の版)。`SUEnableSystemProfiling = NO` で Mac の情報は送りません。
  本や保存データに関わるものは何も送りません。

### Debug・テスト・自分でビルドした人

- **Debug ではアップデーターを起動しません**(ビルド設定 `QOO_UPDATER_ENABLED = NO` → Info.plist `QOOUpdaterEnabled`)。バンドル ID も
  保存データも別のアプリなので、配布版の更新で置き換わってはいけない。Debug には mach-lookup の例外も付けません。テストの中でも
  起動しません(`RuntimeEnvironment.isRunningTests`)。
- 公開鍵の入っていないビルドは起動しません(環境設定の欄とメニューの「アップデートを確認…」は淡色)。
- clone して Release で組んだ人のアプリも、公開鍵と配信元は配布版と同じなので、新しい版が出ると配布版に置き換わります
  (書庫の署名が正しければ、署名の主体が違っても Sparkle は受け入れる)。望まなければ環境設定で自動確認を切ります。

### 版番号

Sparkle は `CFBundleVersion` で新旧を比べます。以前は `CURRENT_PROJECT_VERSION = 1` 固定で、どの版も同じに見えたため、
`CURRENT_PROJECT_VERSION = $(MARKETING_VERSION)` にしました(`1.82` < `1.83` < … < `2.00` は Sparkle の比べ方で正しく並ぶ。
小数点以下を 2 桁で書き続けること ―― `1.9` と `1.10` は 1.9 < 1.10 と読まれる)。

### 利用者の設定

環境設定「一般」▸「アップデート」(既定: 自動で確認 ON、自動でダウンロードしてインストール OFF)。値は `AppPreferences`
(`qooViewer.pref.*` なので保存データの書き出しにも入る)が持ち、`AppUpdater` が Sparkle へ流します。Sparkle の更新の
ウインドウにある「今後は自動的に…」で変えた値は環境設定へ書き戻します。Sparkle が 2 回目の起動で出す「自動的に確認しますか」は、
環境設定が決めるので出しません(`updaterShouldPromptForPermissionToCheck` が false)。

自動確認 OFF のまま起動し、途中で環境設定から ON にした回も「自動でダウンロードしてインストール」は効きます(2026-10-10 に実機で確認。
ソースを読んで「効かない」と誤って判断し `SUAllowsAutomaticUpdates = YES` を足したが、修正前のビルドで効くことを確かめて戻した)。
Sparkle の値の変化(KVO)は、届いたスレッドがメインならその場で、ほかならメインへ回して受けます(`AppUpdater.onMain`。以前は
`MainActor.assumeIsolated` だけで、メイン以外で届けば落ちた。Sparkle 自身はメインでしか書き換えず、別のプロセスの `defaults write` も
メインに届くことを実測)。

### 利用者から見た動き(Sparkle 2.10.0 の標準の画面。ソースで確かめ、下の実機の確認で見た)

- **いつ確かめるか**: 起動の直後(初回の起動を含む ―― Sparkle が「2 回目の起動まで待つ」のは自動確認の許可を尋ねる画面のことで、
  それは出さない設定なので、前回の確認日時が無ければすぐ確かめる)と、その後は約 1 日ごと(`SUScheduledCheckInterval` の既定)。
  手動の「アップデートを確認…」はいつでも。自動の確認の失敗(通信できない、appcast が 404)は何も出さない。
- **いつ出すか**(Dock に出る普通のアプリの場合。`SPUStandardUserDriver`): 起動の直後か、Mac をしばらく触っていなければすぐ前面に。
  qooViewer を使っている最中は割り込まず、ほかのアプリへ移って戻ってきたときに。手動の確認ならすぐ。
- **更新のウインドウ**: 見出し・今の版と新しい版・リリースノート(appcast に埋め込んだ markdown を NSTextView で書式付きで表示。見出しと入れ子の
  箇条書きも崩れない)・「このバージョンはスキップ」「あとで通知」「アップデートをインストール」・「今後はアップデートのダウンロードとインストールを
  自動で行う」(環境設定の 2 つ目と連動)。スキップした版は自動の確認では出さないが、手動の確認では出す。
- **インストール**: ダウンロード → 署名の確かめ →「インストールできます」の画面(ボタンは「インストールして再起動」だけ)。押せば終了して新しい版で
  起動し直す。押さずに qooViewer を終了すれば、終了時に入れ替わって起動し直さない。実行中の作業があれば、終了の前にいつもの確認が出る。
- **自動でインストール ON**: 何も出さずにダウンロードし、次の終了時に何も聞かずに入れ替える(起動し直さない)。長く終了しなければ(既定 1 週間)
  ウインドウで促す。
- 文言は Sparkle の訳(日本語あり)。ただし appcast の署名が合わないときの「The update feed is improperly signed…」は 2.10.0 では英語のまま。

### 実機での確認(2026-10-10)

本物と同じ作り(`xcodebuild archive`)の 1.82 と 1.83 を、バンドル ID だけ `com.qooProject.qooViewer.sparkletest` に変え、使い捨ての鍵と
`http://127.0.0.1` の配信元(試験用のビルドだけ HTTPS の約束を緩めた)で試した。手順は [12](12-verification-and-debugging.md#自動アップデートの実機の確かめ方)。

| 試したこと | 結果 |
|---|---|
| appcast は正しく、zip だけを中身の違うものに差し替え | 「アップデートエラー! アップデートの署名が不適切で認証できませんでした」。ログは「EdDSA signature does not match」→ Developer ID の代わりの確かめも不可 →「signature validation **before unarchiving** failed」。ディスクの .app は 1.82 のまま |
| appcast の版番号だけを書き換え(署名し直さない) | 「The update feed is improperly signed and could not be validated」。何も入れない |
| 正しい appcast と zip で「インストールして再起動」 | 古いプロセスが終わり、同じ場所の .app が 1.83 になって起動し直した。署名は有効、`com.apple.quarantine` は付かない(公証していなくても Gatekeeper に止められずに起動した) |
| 「インストールできます」でボタンを押さずに終了 | 終了時に 1.83 へ入れ替わり、起動し直さない |
| 環境設定「アップデートを自動的にダウンロードしてインストール」ON(コンテナの defaults)で起動 | `AppUpdater` が Sparkle の `SUAutomaticallyUpdate` を 1 にし、起動直後に何も出さずに appcast と zip を取得、終了時に何も聞かずに 1.83 へ入れ替わった |

## ネットワークのサーバとボリュームの接続(2026-10-25)

ファイルブラウザのツリーの「ネットワーク」(docs/15「ツリーのネットワークとアンマウント」)。LAN で Bonjour(`_smb._tcp`)に名乗り出ている
サーバを並べ、クリックで macOS にマウントしてもらう。**Finder は通さない**(利用者の指定)。

### 実測で分かったこと(2026-10-25、検証用の小さなアプリで)
- **探す**: App Sandbox だけのプロセスでは `NWBrowser` も `DNSServiceBrowse` も起動直後に `-65563 ServiceNotRunning`(mDNSResponder への
  接続が断られる。ダイアログも出ない)。`com.apple.security.network.client` があれば通り、macOS 15 以降は**ローカルネットワークの許可**の
  確認が出る。許可の返事の前は**失敗もせず結果が 1 件も来ない**(`NWBrowser` は ready のまま黙る)―― 「NAS がいない」と区別できない。
- **マウント**: `NetFSMountURLAsync` は `network.client` 無しのプロセスからは `EPERM`。あれば通り、マウント先は `/Volumes` の下に限られる
  (NetAuthSysAgent のログ「Process … is sandboxed and no path was supplied; allowing NetFS to mount under /Volumes」)。マウントは
  `quarantine` 付き。共有を指定しない URL では、macOS が共有の選択のダイアログを出す(NetFS.h)。
- **認証**: アプリ自身から頼むとキーチェーンに保存済みの資格情報がそのまま使われたが、**XPC サービスから頼むと NetAuthAgent が
  パスワード欄のダイアログを毎回出し**、入れたパスワードの保存も失敗した(NetAuthSysAgent の資格情報の段階 4 = キーチェーンが通らず
  段階 5 = UI へ進む。保存は「Failed to create keychain item … -25308 ユーザの操作は許可されていません」)。原因は **XPC サービスが既定で
  自分だけの監査セッションに置かれること**: サービスの Info.plist の `XPCService` に `JoinExistingSession = true`(Apple の説明では
  キーチェーンなどセッション単位のものを使うサービスに要る)を入れると、NetAuthSysAgent は利用者のセッション(Finder から頼んだときと
  同じ番号)に加わり、段階 4 で通ってパスワードを聞かずにマウントした(同日、実機で確認)。
- **断られたとき**(2026-10-25、qooViewer 自身で): 断られていると、探し始めた直後に `NWBrowser` が `.waiting(.dns(-65570
  PolicyDenied))` になる(返事を待っている間は何も来ないので区別できる)。システム設定 ▸ プライバシーとセキュリティ ▸ ローカルネットワークの
  一覧には **「qooViewer」**(`CFBundleName`。Debug 版も同じ名前。XPC サービスの名前ではない)で載り、オフにしても消えないので、そこで
  オンに戻せる。ただし**走っている探索は、オンに戻しても自分では立ち直らず**(十数秒待っても断られたまま)、探し直せばすぐ見つかる。
  使っている途中でオフにされても、走っている探索には何も届かない(一覧は古いまま)。システム設定の「ローカルネットワーク」の画面を直接
  開く URL は無い(6 通り試し、どれも「プライバシーとセキュリティ」の最初の画面まで)。作業用フォルダに置いた検証用の小さなアプリは、
  許可しても断っても一覧に載らなかった(qooViewer で確かめた理由)。
- **読む**: マウントした直後の中身は App Sandbox の中から `EPERM`(ほかのボリュームと同じく、フォルダの許可が要る)。
- **アンマウント**: `FileManager.unmountVolume` は App Sandbox だけのプロセスから、権限もダイアログも無しに通る(SMB の共有を 0.17 秒)。

### 形
- 探すのとマウントを頼むのは XPC サービス `NetworkVolumeConnector.xpc`(App Sandbox + `network.client` だけ。ファイルへのアクセス無し。
  呼び出し元のセッションで動く ―― `JoinExistingSession`。上の「認証」)。
  `scripts/release/check-release-app.sh` が entitlement とバンドル ID を確かめる)。頼めるのは**いま見つかっているサーバ**だけで、URL は
  `smb://<名前>._smb._tcp.local` の形に限る(`NetworkVolumeConnectorPolicy`。アプリとサービスが同じ判定をする)。この Mac 自身
  (ループバックで見えるもの)は外す。サービスは SMB を話さない ―― マウント・認証・共有の選択は macOS の NetAuthSysAgent / NetAuthAgent。
- アプリの側は `NetworkServerDirectory`(アプリで 1 つ、`AppStores.networkServers`)。探すのは環境設定「ツリーに「ネットワーク」を表示」
  (既定 OFF)が ON で、ツリーが画面にある間だけ。テストの中で走る
  実物のアプリでは道を繋がない(`AppStores.Dependencies.networkVolumeConnector` が nil)。
- 断られていたら、サービスが一覧と一緒に `isLocalNetworkDenied` を知らせ、ツリーは「ローカルネットワークへのアクセスが許可されていません」の
  行を出す(クリックで戻し方を案内し、「システム設定を開く」)。探している間は、qooViewer が前面に戻るたびに探し直す
  (`NetworkServerDirectory.refreshOnActivation`。3 秒に 1 回まで)ので、システム設定でオンにして戻ればそのまま並び、オフにして戻れば
  案内の行に替わる(断られているときだけ探し直していた版では、オフにしても古い一覧のままだった)。許可されたかどうかは「探し始めてから
  2 秒、断られなかった」で決める(サーバが 1 台も無いと結果の知らせが来ない)。
- アンマウントはアプリ本体(`VolumeUnmounting`)。先にネットワーク上の書庫の読み込み層が猶予の間だけ持つ記述子を手放させ
  (`StagedFileRegistry.releaseHolds`)、`.withoutUI` で外す(失敗の知らせはアプリが出す)。
- ローカルネットワークの許可の確認の文は、アプリ本体の Info.plist の `NSLocalNetworkUsageDescription`(日本語は `InfoPlist.xcstrings`)。

## StackNest の本と通信

StackNest(画像の本のライブラリ管理アプリ)は、外部ビューアに本そのものではなく**参照ファイル**(`.stacknestbook`。この Mac の
StackNest の本の API の基点 `http://127.0.0.1:<ポート>/api/v1/…` と、その本だけを読める鍵)を渡します。qooViewer はページを
1 枚ずつその API から取り、読み進めたページを書き戻します。参照ファイルの読み取り・要求の組み立て・鍵の扱い・書き戻しは、StackNest の
開発者が公開している Swift パッケージ StackNestViewerKit(→ [11](11-forked-dependencies.md))が行います。リモートの本も StackNest が
127.0.0.1 で中継するので、つなぐ先はこの Mac だけです。参照ファイルは StackNest の `~/Library/Application Support/StackNest/ViewerHandoff/…/<題名>.stacknestbook`
にあり、StackNest が渡すたびに同じパスへ新しい鍵で書き直し、期限(30 日)が切れると消します。

### 通信は XPC サービスがする(2026-10-18 のレビュー)

最初の案(PR #1)はアプリ本体に `com.apple.security.network.client` を付けていました。本体は信頼できない書庫(rar・7z の C の
コードを含む)を読むので、そこを突かれたときに外へ送り出せないことが、本体に通信の権限を持たせない理由です。宛先を
127.0.0.1 に絞るのは部品のコードの決まりでしかなく、OS は本体のどの通信も止めません。そこで:

- **`StackNestConnector.xpc`**(アプリの `Contents/XPCServices`)だけが外への接続を持ちます。権限は App Sandbox と
  `network.client` だけで、ファイルへのアクセスも待ち受けも持たず、ATS は `NSAllowsLocalNetworking` だけ(`check-release-app.sh` が確かめる)。
- アプリの側では StackNestViewerKit をそのまま使い、そのセッションの URLSession(部品の `Configuration.makeURLSessionConfiguration`)に
  `StackNestConnectorURLProtocol` だけを差し込みます。要求は XPC でサービスへ渡り、アプリ本体はソケットを開きません。部品の決まり
  (宛先の制限・リダイレクトの拒否・本文の上限・時間切れ)はそのまま効きます。
- サービスは**決まった形の要求しか出しません**(`StackNestConnectorPolicy`。アプリも送る前に同じ判定をする):
  - `http` で、ホストは `127.0.0.1` か `::1` の字面だけ(名前・資格情報・断片は不可)
  - パスは `/api/v1/libraries/<書庫>/books/<番号>` か `/api/v1/relay/<ID>` の下の `manifest`・`pages/<番号>`・`cover`(GET。`?maxw=<幅>` だけ可)と
    `progress`(POST。JSON の本文 64 KiB まで)。パーセント符号化を含むパスは不可
  - ヘッダは鍵(`Authorization: Bearer …`)・名乗り・POST の本文の型だけ
  - 応答は 64 MiB まで、リダイレクトには付いて行かない(3xx はそのまま返す)。ephemeral のセッションで、キャッシュ・クッキー・
    資格情報の保管・プロキシを使わない

  これで、細工した参照ファイルを開いても、この Mac で待ち受けているほかのサービスへ別の形の要求が出ることはなく(部品は宛先の
  ホストしか見ず、パスは参照ファイルのままに使うため)、アプリのプロセスが乗っ取られても外の宛先へは出せません。
- XPC の返事は必ず 1 度(`StackNestConnectorClient`): サービスが落ちた・起動できないときは控えている要求を `.unavailable` で
  終わらせ、部品はつながらない失敗として扱います(次の要求は立ち直ったサービスへ)。

### ページの読み方(スレッドとメモリ)

- ページは部品の **async の口**で待ちます(`StackNestReferenceReader.pageData`)。最初の案は `ArchiveReading` の同期の口を
  `FileIO` のスレッドで待っていて、ページ一覧のセル・先読み・寸法の下調べが頼んだ数だけスレッドが塞がり(1 本最長 25 秒×最大 3 回)、
  StackNest が応答しないと数ウインドウでプロセスのスレッドの上限(512)に届いて、ほかの本・ファイルブラウザの読み書きまで止まりえました。
- 要求の同時数は接続先(StackNest の 127.0.0.1 のポート)ごとの門 **`StackNestRequestGate`** が絞ります(同じ StackNest の本どうしで共有。
  本ごとに持つと 2 冊で接続数を超え、サービスの URLSession の中で待つ): 合わせて 6(接続先 1 つの同時の接続数と同じ。サービスは門を通らない
  manifest と書き戻しの分の余りを足して 8)、そのうち
  先読み・サムネイル・寸法は 4 まで(残りは表示のために空けておく)。表示は空きがあればいくつでも使え(応答の止まった表示のページが
  あっても次の表示は通る)、空きが出たら待っている表示を先に通します。合計が接続数を超えないので、部品の待ちの時間切れ(並んでいる間も
  数える)で正常な StackNest でも失敗する、先読みの後ろに表示のページが並ぶ、ということが起きません。先読みに表示が追いついたら
  背景の列から表示の列へ移します(`promote`)。PageLoader は許可をデコードが終わるまで持つので、取り寄せたまま枠を待つバイト列も
  門の数で頭打ちです。
- **ページ送りの待ち**(2026-10-19、1 ページの往復に 300 ms かかる作り物の StackNest で測って直したもの。手元の StackNest は往復が
  数 ms で、直接開いた本とほぼ同じ速さ ―― 数字は [12「StackNest の本の実機の確かめ方」](12-verification-and-debugging.md#stacknest-の本の実機の確かめ方)):
  - 表示するページを頼む**前に**先読みを始め(`ViewerViewModel.loadCurrentSpread`)、見開きの相方も 1 枚目と同時に**表示として**頼みます
    (組まないと分かったら取り消す)。以前は相方を 1 枚目が届いてから頼み、往復 2 回ぶん待ちました(先読みの外へ飛ぶと 660 ms → 345 ms)。
  - 先読みに合流した表示の要求は、門に並ぶ前の合流でも表示の列で通ります(`decodedPixels` が門に並ぶときに `cancellableInFlightKeys` を
    見る。`promote` は並んだ後の合流しか移せず、表示するページが背景の列で 0.9 秒待っていました)。
  - 表示の要求も、待つ人(表示・先読み・セル)が全員取り消したら取り寄せごと取り消します(`awaitRemote`)。つまみを動かすように続けて飛ぶと、
    通り過ぎたページの取り寄せが門の枠を握ったまま最後まで走り、最後のページが出るまで 1.3 秒かかっていました(今は 0.37 秒)。
  - 取り消した読み込みには、表示も先読みも合流しません(`inFlightTasks` に残っていても読み直す。2026-10-24 のレビュー: 先読みが合流すると
    nil を受け取り、すぐ戻って来たページが表示されるまで取り寄せられなかった)。そのため同じ鍵の読み込みが一時的に 2 つありうるので、
    待つ人の札は読み込みごとに数え(`awaitRemote` の鍵に Task を足す)、門とデコードの待ちの格上げは新しい方(後ろ)を移します
    (`StackNestRequestGate.promote`・`promoteDecodeWaiter`)。表示の読み込みを新しく始めたら、残った先読みの印(`cancellableInFlightKeys`)を外します。
  - 続けて送ったときの通過コマは、手元に届いている絵だけを出し(相方が無いコマは出さない)、取り寄せは着地する先を頼みます
    (`loadTransitFrame`・`drainPageFlipQueue`)。以前は通過する全ページを 1 枚ずつ待ち、キーを 30 回押すと最後のキーから着地まで 12.6 秒
    (60 回で 33 秒)かかっていました(今は 0.5 秒)。
  - サムネイルの一覧(ページ一覧・サイドパネル)は背景の 4 本で取り寄せるので、往復 300 ms なら 1 秒に十数枚です(先読みと同じ枠)。
    ホバーした拡大プレビューだけは表示の列で頼みます(`gridThumbnail(asksAsDisplay:)`。環境設定「表示中のサムネイルの拡大画像を先読み」の
    先読みは背景の列のまま)。背景の列のままだと、先読みとサムネイルの後ろに並んでプレビューが出なかった。
  - 原寸大のウインドウは、表示用の絵が上限(4096 px)に届いたページだけを読み直すので、StackNest の本ではほとんど起きません
    (リモートのライブラリの本は、StackNest の取り次ぎが幅 1600 px に揃えて返す。手元のライブラリの本は往復が数 ms)。
  - StackNest は、リモートのライブラリの本を取り次ぐときに、ページを内蔵ビューアと共有するディスクのキャッシュに入れ、開いたページの近くを
    自分でも先読みします(StackNest の `ViewerRelayCache`)。キャッシュを使うのは幅を指定しない(または内蔵の 1600 px の)要求だけなので、
    **qooViewer は `?maxw=` を付けない** ―― サムネイルを小さく頼むと、毎回リモートへ取りに行く。
- 寸法の下調べで取ったバイト列のヘッダーは控え(`headerInfoCache`)、「情報を見る」の形式と名前は中身から決めます(ページの名前
  `000041.jpg` は仮のもの)。寸法の下調べは、同じページの絵をもう取り寄せていればそれを待って、届いた中身のヘッダーで答えます
  (先読みと同じページを別々に取りに行き、背景の枠を取り合っていた)。
- 部品のページのキャッシュ(直近 8 ページ・64 MiB)は、受け取ったページから同じ決まりで見積もってリソースモニタに出します
  (`StackNestSessions.Book.memoryUsageItems`。量は部品 0.2.0 の `cachedPageBytes` と、受け取りの途中の本文 `bufferedResponseBytes`。
  0.1.0 は量を外へ出さなかったので、受け取ったページから部品のキャッシュの決まりをなぞって見積もっていた)。ビューアの後始末(`releaseResources`)はセッションと書き戻しの役を
  手放し(最初の案は手放さず、旧世代のビューモデルが 64 MiB と URLSession を抱えた)、PageLoader は手放した後に reader を作り直しません。
- 開いたときの本全体の下調べはしません(横長の判定は表示したページの近傍だけ)。レイアウトの計算は、記録を残さない本なので
  そもそも走りません(下の「記録を残さない」)。

### 鍵・記録・ほかの機能との関係

- **鍵(token)**: メモリの中だけに置き、DB・UserDefaults・保存データの書き出し・ページ一覧のキャッシュ・ログに残しません(部品の
  `StackNestBookReference` は `Codable` でなく、文字列にすると `<redacted>`。アプリ側の `StackNestReferenceIdentity` も同じ)。
- **セッションは本ごとに 1 つ**(`StackNestSessions`): 同じ参照ファイルから作る reader(開くときの BookLoader・ビューア・同じ本を開いたほかのウインドウのビューア)と
  書き戻しの役は 1 つのセッション(ページのキャッシュと門)を使い回します。使い回すのは接続先と鍵と形式の版が同じとき
  (`StackNestReferenceIdentity`)。開く位置(`startPage`)・題名だけが違う書き直しでは使い回し、ビューアも作り直しません
  (`MangaBook.viewerIdentity`)。**本の開く位置・題名は、使い回したセッションの参照ではなく、BookLoader がいま読んだ参照ファイルから
  取ります**(2026-10-25。v1.85 のリリースの CI で、同じ鍵のまま開く位置だけを書き直す試験が、閉じたビューアのセッションが残っていると
  古い開始ページから開いた)。StackNest は渡すたびに新しい鍵を出すので(`ExternalViewerHandoff` の `openLocal` / `openRemote` が書く直前に
  `ViewerTokenStore.issue` ―― 本家 main `1b616bc` で確認)、本番では鍵が変わってセッションも作り直されます。
- **記録を残さない**(2026-10-18、利用者の決定「シークレットフォルダの本と同じ扱い」。`MangaBook.leavesNoRecord`): 参照ファイルは
  開くたびに同じパスへ新しい鍵で書き直され、中身が前回と同じ本かを qooViewer から確かめる手段がありません(本の置き場所も中身の
  指紋も届かない)。そのまま読書位置・ブックマーク・レイアウトを残すと、別の本や増減したページに古い記録が当たりえます。そのため
  どの窓でも、履歴・読書位置・ブックマーク・レイアウト・メタデータ・「前回の本」のどれも書きません(`ViewerViewModel.skipsPersistence`)。
  保存データの読み込みも、どのカテゴリでも参照ファイルの本を外し(`LibraryImportExportService.removingStackNestBooks`。StackNest へも
  問い合わせない)、外した冊数を結果に出します。表示している間は外観をシークレットの
  揃いにし、タイトルを「(StackNest) 題名」(シークレットウインドウでは「(シークレット) (StackNest) 題名」)にし、出たときに一度だけ
  知らせます(`ContentView.showsAsPrivate`・`NoRecordNotice`。シークレットウインドウでは知らせない)。ブックマークとレイアウトを
  StackNest の本で使えるようにするか(同じ本だと確かめる手がかり ―― manifest の `etag` など ―― を何にするか)は、別に決めます。今は
  記録を残さない本として淡色です。
- **開く位置**: いつも参照ファイルの `startPage` から開き、再開の確認は出しません(`ViewerViewModel.stackNestStartPageID`)。
  読み方向は manifest の向きで、切り替えはその場だけです。最初の案は qooViewer の読書位置を残し、履歴から開き直すと古い
  `startPage` で開いて巻き戻していました(その後の修正で更新日時を比べたが、記録を残さないことにしたので要らなくなった)。
- **本の置き場所が無い**(`MangaBook.hasBrowsableLocation`): 参照ファイルのフォルダは StackNest の受け渡し用の場所で、本の置き場所
  ではありません(並ぶのはほかの本の参照ファイル)。前の本・次の本、「同じフォルダのファイルを開く」、Finder・ファイルブラウザで
  表示(ページの右クリックも)、「このフォルダへのアクセスを許可」、ホームの「直前の本へ戻る」(開き直すのは StackNest から)は淡色で、
  キーや境界の動作で届いたら理由を知らせます(`AppState.noteNoBrowsableLocation`。スライドショーの末尾は黙る)。サイドパネルの
  フォルダブラウザは見た目はいつもどおりで、前の本のフォルダを残さず、一覧の場所に理由を出し、移動・並べ替え・絞り込みを淡色にし、
  読み込みも止めます(`SidePanelView.folderSection`。フォルダ名の欄は「StackNest」)。下段の本の中身ブラウザは、本のページを平坦な
  1 階層で並べます(書庫として開かない。`BookContentsBrowserState` の `.pages`)。
  「情報を見る」の場所は「StackNest」です。
- **続けて渡される本**(2026-10-19、利用者の決定「案 B」): StackNest は書庫の窓で選んだ本を 1 冊ずつ外部ビューアへ渡す(StackNest の
  `openInExternalViewerSyncing`。`NSWorkspace.open` を 1 冊に 1 回)。ほかの「開く」のように 1 秒の間に届いた回をまとめて「次の本へ」の
  並びにすると、2 冊目以降は開かれず、StackNest が 15 秒後に「qooViewer が本を読み込んでいません」と知らせていた(鍵が使われたかを
  確かめる。`viewerUseCheckDelay`)。参照ファイルはまとめず、届いたものをどれもすぐ開く: 続けて届いたうち最初の 1 冊は環境設定「Finder
  から開いたとき」に従い、2 冊目以降は直前の本のタブの右に新しいタブで開く(渡された順に並ぶ。`AppDelegate.openStackNestReferences`)。
- **止め方**: 期限切れ・認証失敗・本が無い・ライブラリのロック・宛先の制限は、StackNest から開き直すまで直らない。その後は、
  その本のページも manifest も StackNest へ問い合わせず(`StackNestSessions.Book.permanentFailure`)、表示できないページでは
  理由を 1 度だけ知らせます。書き戻しもその本については送りません(部品)。それ以外の失敗(StackNest が応答しない・リモートの
  ライブラリにつながらない・想定外の応答)は一時的なものとして要求を止めず、読めなかったページでは、そのページを次に受け取るまで
  覚えた理由を毎回知らせます(`Book.record(_:page:)`・`pageFailureToShow(page:)`。2026-10-19 の監査: 以前は「このページを表示できません」
  だけで理由が出なかった。ページごとに覚えるのは、見開きの相方や先読みのページが届いたことで、読めなかったページの理由を消さないため)。
  開くときに部品が返す `.cannotConnect` は「つながらない」(拒否、数 ms)と「応答しない」(部品の待ちの上限、実機で約 22 秒)を区別しないので、
  15 秒以上待ってからの失敗は「StackNest が応答しません」と言い換えます(`BookLoader.stackNestNotRespondingAfter`・`StackNestOpenError.notResponding`。
  2026-10-24 の実機確認で、応答しない作り物に「起動していないか、同期の設定がオフです」と出た。部品が時間切れを別のコードで返すようになれば要らない)。終了(⌘Q)のときは、送っていない位置を最長 2 秒だけ待って
  送ります(部品の `StackNestProgressRegistry.shared.flushAllBlocking`。送りはメインスレッドの外で走り、メインはそこで待つ)。最初の案は
  部品 0.1.0 の `flushAll` と `.terminateLater` を使っていて、終了がメインキューの仕事の中から頼まれる(スライドショーの末尾の「終了」・
  保存データの削除の後の終了・Debug の制御口の quit)と、メインキューが回らずに返事が来ないまま、アプリが終わらなくなりました(実測)。
  その後しばらくはアプリ側の送り切り(`StackNestQuitFlush`)で避け、部品へ PR を出して 0.2.0 に入ったものに替えました(2026-10-19)。
  ビューアの書き戻しの役は、作るときに登録簿を渡します(`ViewerViewModel(stackNestProgressRegistry:)`。アプリは `shared`、試験は
  `ViewerHarness` が自分の登録簿を渡し、プロセスで 1 つの登録簿に試験の役を残さない)。
- **書き戻し**: StackNest の本はどの窓でも記録を残しませんが、StackNest へ位置を返すのは保存データではないので続けます。シークレット
  ウインドウでは送りません(`ViewerViewModel.recordingRule` → `writesBackToStackNest`)。
- **ほかの機能の外**: コレクション(`CollectionStore.makePendingItem` が実ファイルの参照ファイルを断る)・本の書き出し・
  メタデータ(`MetadataGenerator` の母体)・サムネイルのディスクキャッシュ(鍵を掛けられるライブラリの絵を、施錠や期限と関係なく
  残さない)には入れません。起動時の掃除(`ExternalMoveSweeper`・`NonBookFolderSweeper`)は参照ファイルの本を見ません。
- **シークレットフォルダ**: 参照ファイルの場所からは StackNest の本の実際の置き場が分からないので、効きません(StackNest の本はもともと記録を残さない)。
- **名乗り**: `X-StackNest-Viewer: <バンドル ID>/<版>; format=<参照ファイルの版>; kit=<部品の版>`(部品の `StackNestViewerIdentification`)。
- **対応の宣言**: `Info.plist` の `StackNestViewerSupport.referenceFormatVersions`(今は `[1]`)。StackNest はこの鍵をファイルとして読みます。
  部品が読める版の中だけを宣言します(`StackNestViewerDeclarationTests`)。
- **文言**: 知らせの文言は部品の既定の英日の文言を、qooViewer の表示言語とアプリの名前で出します(`StackNestText`)。
- **テスト**: 実物の StackNest は使いません。部品の見立て `StackNestStubServer`(`URLProtocol`)を、作業フォルダの下の参照ファイルにだけ
  `StackNestSessions.useConfigurationForTesting` で使わせます(`StackNestTestBook`)。XPC の道は、形の判定(`StackNestConnectorPolicyTests`)と、
  見立ての運び手を差し込んだ `StackNestConnectorURLProtocol` の試験で確かめ、サービスそのものとの往復は `TEST_RUNNER_QOO_STACKNEST_CONNECTOR_PROBE_URL`
  を付けたときだけ走る試験で確かめます(手元で、この Mac の見立てのサーバへ)。
