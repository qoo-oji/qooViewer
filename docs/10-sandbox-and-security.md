# 10. サンドボックスとファイルアクセス

## 前提

App Sandbox + Hardened Runtime、`ENABLE_USER_SELECTED_FILES = readwrite`。アプリ本体にネットワークの
entitlement は無く、本体は通信しません。通信するのは自動アップデート(Sparkle)の Downloader.xpc だけで、
取りに行くのは GitHub の appcast と更新の書庫だけです(→ [自動アップデート](#自動アップデートsparkle2026-10-10))。
entitlement はビルド設定から生成され、Release だけ `Configurations/qooViewer.entitlements`(Sparkle の XPC
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
| `FavoriteBook.bookmarkData` | お気に入りから開く(無効化中) |
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
- `SecurityScopedHandoff`: 履歴・お気に入り・ブックマーク一覧から**別のウインドウ/タブ**へ
  URL を渡すとき、受け取った側の `AppState.open(url:)` が走るのは次以降のランループなので、
  渡す直前に開き、10 秒以内に受け取り側が引き取る(引き取ったら渡し側が閉じる)。
- 存在確認だけの一時的な open/close(`fileExists(bookmark:)`)は、その場で対にする。

### 解決は重い ―― 表示のためにメインスレッドで解決しない

`URL(resolvingBookmarkData:)` は、対象が未接続の外付け/ネットワークボリュームを指していると
ボリュームの探索を試みて**秒単位でブロック**します。次の設計はすべてこの一点から来ています。

- 履歴の一覧はキャッシュしたパスだけで描き、解決は開くときだけ。再検証はアプリのアクティブ化と
  ボリュームのマウント/アンマウントで非同期に(`RecentFilesStore`)。
- お気に入りの実在確認はキャッシュ(`existenceByFavoriteID`)を読むだけ。未確認は「存在する」扱い
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
操作(コレクション・お気に入り・ブックマーク一覧から開く、Finder に表示…)だけ `.userOpen` で従来どおり繋ぎに行く。
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
  (`check-release-app.sh` が「無いこと」を確かめる)。代償は Sparkle の文書のとおり、リリースノートが古い WebView で描かれる・
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
