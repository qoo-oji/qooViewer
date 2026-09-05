# 10. サンドボックスとファイルアクセス

## 前提

App Sandbox + Hardened Runtime、`ENABLE_USER_SELECTED_FILES = readwrite`。ネットワークの
entitlement は無く、通信は一切しません。エンタイトルメントのファイルは無く、ビルド設定から
生成されます(→ [02](02-project-and-build.md))。

サンドボックス下で触れるのは、

1. ユーザーがパネル・ドラッグ&ドロップ・Finder の「開く」で**直接選んだ**ファイル/フォルダ
   (そのプロセスの間だけ)、
2. それを**セキュリティスコープ付きブックマーク**(`URL.bookmarkData(options: .withSecurityScope)`)
   として保存し、次回以降に解決して `startAccessingSecurityScopedResource()` したもの、
3. 環境設定「フォルダのアクセス権」で許可したフォルダの配下すべて(`FolderAccessStore` が起動中
   ずっと開いたまま維持する)、
4. 自分のコンテナ(`~/Library/Containers/com.qooProject.qooViewer/`)の中

だけです。**書庫ファイルを1つ開いただけでは、同じフォルダの他のファイルは見えません。**
「次の本へ/前の本へ」「同じフォルダのファイルを開く」「サイドパネルのフォルダブラウザ」は、
フォルダのアクセス権が無いと空になります。その場合は `AppState.ensureAccess` /
`SidePanelBrowserState.requestFolderAccess` がその場で許可を求めるパネルを出します。

## セキュリティスコープ付きブックマークを持つ場所

| 場所 | 何のため |
|---|---|
| `RecentFilesStore` | 履歴から開く |
| `FavoriteBook.bookmarkData` | お気に入りから開く |
| `Bookmark.bookmarkData` | 編集ウインドウから今開いていない本を開いてジャンプ |
| `BookLayoutSettings.bookmarkData` | 編集ウインドウでレイアウトだけある本のサムネイル |
| `BookLayoutSettings.externalCoverBookmarkData` | 本に含まれないカバー画像 |
| `BookMetadata.bookmarkData` | 書き出しウインドウがメタデータだけの本を解決する |
| `LastActiveBookStore` | 起動時に前回の本を開く |
| `FolderAccessStore` | 許可したフォルダ |
| `LastUsedFolderMemory` | フォルダ選択パネルの前回位置、書き出しの固定の保存先 |

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

### 存在確認の判定順(LibraryCleanupViewModel.evaluate)

1. いずれかのストアのブックマークから URL を解決できるなら、開いて `fileExists`(最も確実)。
2. 解決できなくても許可済みフォルダの配下なら、素のパスの `fileExists` を信用する。
3. どちらでもなければ、`fileExists` が成功すれば存在する。失敗は「無い」のか「見えない」のか
   区別できないので `.unknown`。

### ブックマークの解決は削除されていても成功しうる

解決に加えて `fileExists` まで確認しないと、削除済みのファイルが履歴に残り続けます
(`RecentFilesStore.resolveForOpening` の修正)。

## 記録の線引き

何を記録するか/しないかは [06](06-persistence.md#シークレットウインドウとその場限りの本) に
まとめてあります。**フォルダのアクセス権だけは、シークレットウインドウでもその場限りの本でも
保存します**(本の記録ではなく権限そのもの)。「すべてのデータを削除」でも残します。

## Finder で開く

`FinderReveal` / `PageFileAccess`。フォルダの本のページは実物を選択、書庫や PDF の中のページは
入れ物のファイルを選択(代わりに「画像を書き出す」の導線を出す)。入れ子書庫のページは
一時ファイルではなく本を指す。サイドパネルのフォルダブラウザは `NSWorkspace.shared.open`。

## 一時ファイルとキャッシュ

コンテナの `tmp/` と `Caches/` の中だけを使います。一時ファイルは起動ごとのディレクトリで、
起動時に他の pid のものを掃除します(OS は自動では掃除しない。11 日前のものが残っていた)。
キャッシュは容量逼迫時に OS が消してよく、Time Machine の対象にならない場所です
(再生成できるものしか置かない)。
