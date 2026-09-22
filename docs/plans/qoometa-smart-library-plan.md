# qooMeta への置き換えとスマートライブラリ(計画と引き継ぎ)

2026-09-21 開始。ブランチ `feature/qoometa-and-smart-library`。

## 1. 利用者の指示(2026-09-21)

1. ファイル名からメタデータを作る処理を、兄弟リポジトリ **qooMeta v0.1.0**(`qoo-oji/qooMeta`、SwiftPM)に置き換える。
   - 「メタデータの編集」ウインドウは、qooMeta のメインウインドウ 3 ページ目(確認・編集)を土台に作り直す。
   - 解析は 2 ページ目の「自動」相当(本ごとにルールセットを選ぶ)。**2 ページ目そのものは持たない**。代わりに
     ①ファイル名の型に合わなかった本を絞り込む手段、②右クリックから任意のルールセットで読み直す手段、
     ③解析の設定を開くボタン、を持つ。
   - qooViewer が持っていなかった欄(複数の著者・ジャンル・イベント・原作・情報・並べ替え用の巻数)は qooMeta のものを
     土台に持たせ、そこへ表紙画像(コレクションの表紙)の指定を統合する。
2. 決めたこと(同日の質問への回答)
   - **直したらすぐ登録**(DB へ書く)。取り消し(⌘Z)も DB に反映する。
   - 解析の設定・シリーズと巻数の抽出の設定は、qooMeta の 2 つの窓を**両方とも移植**する。従来の 3 枚の編集シート
     (ファイル名フォーマット・巻数・除外)は廃止。
   - 新しい欄は、保存データの JSON・ComicInfo/EPUB/PDF の書き出し・検索のすべてで使う。
3. スマートライブラリ(StackNest のスマートシェルフが土台)
   - ホームのトップバーで「ファイルブラウザ」とライブラリの間に「スマートライブラリ」ボタン。
   - 下は 2 ペイン。StackNest では画面の上にある絞り込み(フィルタ・ブラウザ列・スマートシェルフの一覧)を左ペインに集める。
   - 対象の本: **ライブラリに登録されている本** + **ファイルブラウザの「よく使う項目」のフォルダに含まれる本** +
     **スマートライブラリ自身に登録した対象フォルダに含まれる本**。

### qooMeta の取り込み方(利用者の指示 2026-09-21)

- qooMeta は**依存パッケージ**(SwiftPM、`https://github.com/qoo-oji/qooMeta`、`upToNextMajorVersion` from 0.1.0。
  Package.resolved がリリースのタグで固定する)。使う製品は `QooMetaKit`(中核)と `QooMetaRules`(同梱の既定値の JSON:
  `filename-formats.json`・`series-rules.json`)。
- **中核と同梱のプリセットの JSON は、qooMeta を更新すればそのまま入る**(Xcode の「Update to Latest Package Versions」か
  `xcodebuild -resolvePackageDependencies` の後で Package.resolved を確かめる)。qooViewer が持つのは利用者の**差分だけ**
  (`MetadataRulesStore` の rules-bundle)で、既定値は毎回 `BuiltInRules.bundled()` から読むので、コピーを持たない。
- 画面(移植したビュー)は qooViewer のコード。qooMeta のアプリ側が変わっても自動では入らない。

## 2. メタデータ(段階 A)

### 保存の形

- `BookMetadata`(@Model)に欄を足す: `additionalAuthorsRaw`(2 人目以降の著者を改行でつないだもの。`author` は先頭の
  著者のまま ―― 古い版・書き出しが先頭だけを読んでも崩れない)、`genre` `event` `source` `info`、`volumeSort: Double?`。
  すべて既定値つき(軽量マイグレーション)。`StoreSchemaGuard.generations` に 2 を足す。
- **登録済み = すべての欄が確定**。qooMeta へは確定した内容として渡す: シリーズがあれば
  `.series(name:volume:fields:)`(巻が空なら `volume: ""` =「巻は無い」)、無ければ `.notInSeries(fields:)`。
  従来の約束「登録したメタデータは、規則を変えても変わらない」を保つ。
- 編集ウインドウで直した本は、その時点で登録する(行に見えている値すべてを書く)。窓を開いているあいだは qooMeta の確定
  (`Confirmation`)で持ち、行が変わるたびに登録済みの本の DB を行に合わせる。「登録を外す」で確定を捨て、行を削除する。

### 規則の保存

- 規則の差分(`RuleChanges` の rules-bundle)とスタンプは `~/Library/Application Support/`(サンドボックスのコンテナ)の
  `qooMeta/settings.json`。qooMeta の `AppSettings` と同じ読み書き(読めないファイルは写しを残す)。
- 旧 `MetadataFormatStore` の UserDefaults(3 種の規則)は、既定から変えていたファイル名フォーマットだけを
  利用者のルールセット「qooViewer(以前の設定)」として一度だけ引き継ぐ。

### 画面

- 「メタデータの編集」ウインドウ = qooMeta の `WorkspaceView`(NSTableView の一覧 + 右の詳細 + 絞り込みの帯)を移植。
  状態の絞り込みに「型に合わなかった」「登録済み」、ツールバーに「解析の設定」「抽出の設定」、行の右クリックに
  「ファイル名を読み直すルールセット ▸」「登録を外す」、詳細に表紙(コレクションの表紙の指定)。
- 1 冊ぶんのシート(`BookMetadataSheet`)は新しい欄つきの形に。初期値は DB、無ければ qooMeta で 1 冊だけ読んだ提案。
- 題の解決(`BookTitleResolver`)と書き出しの題・著者の初期値(`TitleAuthorFilenameParser` を廃止)は `parseName`。

## 3. スマートライブラリ(段階 B)

- モード `WelcomeMode.smart`(ライブラリ機能が ON のときだけ)。
- 保存するもの: スマートシェルフ(名前・すべて/いずれか・条件の並び)と対象フォルダ。
- 左ペイン: スマートシェルフの一覧(「すべての本」+ 保存したもの)/ 対象フォルダ / ブラウザ(欄ごとのボタンと選択パネル)/
  絞り込み(形式・未読/既読・追加日・読んだ日)。登録の有無は絞り込みからも条件からも外した(2026-09-22)。2026-09-22 の作り直しは §4。
- 右: 表紙のグリッド(検索・並べ替え・大きさ)。本のメタデータは、登録済みなら DB、未登録なら qooMeta の提案。

## 4. 進み具合

### 2026-09-21(1 日目)

- 済: qooMeta を依存に追加(QooMetaKit・QooMetaRules)。`BookMetadata` に欄を足し、`StoreSchemaGuard` 世代 2。
  `MetadataRulesStore`(規則の差分・スタンプ・以前の規則の引き継ぎ)。メタデータの編集ウインドウを qooMeta の 3 ページ目から
  作り直し(直したらすぐ登録・⌘Z も DB へ・型に合わなかった本の絞り込み・右クリックの読み直しと登録の解除・解析/抽出の設定の窓・
  詳細にコレクションの表紙)。1 冊ぶんのシート・題の解決・書き出しの初期値を qooMeta へ。保存データの JSON(formatVersion 5、
  `metadataRules`)、ComicInfo/EPUB/PDF へ新しい欄(著者の並び・ジャンル・情報)。検索に新しい欄。qooMeta の訳を xcstrings へ合流。
- 済: スマートライブラリ一式(帯のボタン・ホームメニュー・2 ペイン・スマートシェルフの編集シート・対象フォルダ・絞り込み・
  ブラウザ列・並べ替え・大きさ)。
- 済: テスト(MetadataWorkspaceTests・MetadataRulesStoreTests・SmartLibraryTests・保存の開き直し・JSON の往復)。全体 1446 件が通る
  (ファイルブラウザの名前のクリックの時間のテストが 1 回だけ負荷で落ち、単独では通った)。
- 実機(Debug、使い捨てボリュームの架空の本): スマートライブラリの表示・条件のシート、メタデータの編集ウインドウが開いて
  全冊を読むことを確かめた(一覧は実名が写るので撮っていない)。

### 2026-09-21(利用者の確認を受けた作り直し)

- メタデータの編集ウインドウ: 右の詳細を無くし、操作は右クリックとツールバーへ。**ロック = 登録**(案 A。直した値は下書き
  `MetadataDraftStore`)。以前の版の欄で登録した本は、開いたときに「空の欄だけ埋める / ロックを外して解析し直す」を尋ねる
  (`BookMetadata.fieldsVersion`)。除外フォルダ設定。メタデータを再生成(選んだ本)。ファイル名の解析ルールは切り替えだけ。
  スタンプ・確定・保存データの削除・右クリックの解析の設定は外した。表紙は一覧の列に戻した。
- 使い捨てボリュームのテスト 17 件が、書き込みの権限で落ちるようになった(コードの変更とは無関係と見ている。Debug 版の
  リムーバブルボリュームの許可を確かめてもらう)。

### 2026-09-22(スマートライブラリの確認を受けた作り直し)

- 帯のファイルブラウザとスマートライブラリの間に区切り線。
- 対象の本は**スマートライブラリの対象フォルダの中の本だけ**(ライブラリ・よく使う項目の本は外した。ライブラリと
  ファイルブラウザは個別に OFF にできるので切り分ける)。対象の切り替えのスイッチも無くした。
- ブラウザ列を、左ペインの幅いっぱいのボタン(最初はジャンル・著者・シリーズ)+ 選択パネル(複数選択・ピン留め・検索)+
  ボタンの下の選んだ値のチップへ作り替えた。絞り込みはブラウザの下へ。形式は複数選べるドロップダウン。
- メタデータの編集ウインドウの対象: 開いた本・ライブラリの本 + スマートライブラリの対象フォルダの本
  (よく使う項目のフォルダの本は開くまで対象外)。

- 「読み終えた」の判定: `BookReadingState.isAtLastPage`(最後の画面に最後のページが写っていたか)を足した。StoreSchemaGuard の
  世代 2 の指紋を書き換え(リリース前なので行は足さない)、開き直しのテストを足した。

- 保存した条件の UI 名を「スマートコレクション」に。左ペインは 対象フォルダ / スマートコレクション / メタデータ / 絞り込み。

- シリーズでまとめる(束の表示・束を開く・戻る)。束の下はシリーズ名と著者。著者でもまとめられる(筆頭の著者)。
- main(1.66)を取り込んだ(a62e015)。外観の設定は `AppearanceSettings` へ: スマートライブラリの表紙の下の文字の大きさ・束の紙の色。
- 「最後のページまで表示した」の記録は、保存した位置がその画面のときだけ書く(「いつも最初から」で読書位置を先頭で
  上書きしていた。ViewerViewModelTests が捕まえた)。

- スマートライブラリを個別に ON/OFF(環境設定「一般」→「ホーム」。並びは ファイルブラウザ・スマートライブラリ・ライブラリ)。

- 読み込みの高速化: 前回の一覧を保存して先に出す・qooMeta の索引で変わった本だけ読む・ルールセットの選択を並列に。
  一覧は Application Support へ、表紙の鍵も持たせてネットワークの本の表紙を往復なしで出す。ネットワークの実機では未確認。

### 2026-09-22(実機検証)

- Debug(保存データは本番の写し)で、使い捨てボリュームの架空の本 9 冊を対象フォルダにして確かめた(撮るのはスマートライブラリの
  ペインの内側と環境設定だけ)。束ね方(著者・シリーズ)と束を開く・戻る、選択パネル・ピン留め(起動し直しても残る)、形式の複数選択、
  3 つの設定の 8 通り(帯とホームメニュー)、環境設定からのスマートライブラリの ON/OFF のその場の切り替え、外観の 3 項目、メタデータの
  編集ウインドウの「以前の版の欄」の確認(234 冊)と「空の欄だけ埋める」、ツールバー。
- 直したもの: ピン留めした値が「すべて」側で空白の行になる(識別子の重なり)、暗い外観で束の紙が見えない(既定の色)、帯のボタンが
  VoiceOver で「ボタン」としか読まれない(読み上げの名前)。
- 失敗: 8 通りの帯を撮った範囲が広すぎ、スマートライブラリ OFF の組でライブラリのチップ(実名)が 1 つ写った。画像はすぐ消した。
  帯を撮るときは、左端のモードのボタンだけに収まる幅にするか、先にライブラリ機能を OFF にする。
- 見ていないもの: メタデータの編集ウインドウの一覧(実名が並ぶ。対象フォルダの本が並ぶことはテストで確かめてある)、明るい外観、
  ネットワークの対象フォルダ。

### 2026-09-22(コード監査。まだ直していない)

利用者の指示で、このブランチの差分全体(main...HEAD、Swift 74 ファイル)を「リソースリーク・クラッシュ・ハング・ファイル破損・
ファイル消失・メモリとディスクの過大消費」の観点で監査した。核心部(SmartLibraryCatalog / Scanner / Store、MetadataRulesStore、
DraftStore、BookSavedDataEraser、BookMetadataStore、App 配線)と qooMeta の ProposalIndex は直接読み、ビュー群・規則画面・永続化/
書き出しは 4 つの観点に分けて並行で調べ、指摘はすべて該当箇所と qooMeta のソース(checkout `fc1ccbf`)で裏を取った。
**クラッシュ・ハング・ファイル破損に直結する欠陥は無し。** 下の番号順に直す(1〜4 が先)。

1. **【高・メモリ】スマートライブラリの表紙グリッドが訪れたセル分の CGImage を無制限に抱える。** `SmartBookThumbnail` が `@State` に
   `buffer?.makeImage()` を持ち(SmartLibraryPane.swift、`image = made`)、`LazyVGrid` に `LazyCellImageBudget` の `.id(epoch)` が無い。
   `makeImage()` は `PagePixelBuffer` の mmap 領域を CGDataProvider で共有するので、provider の 96 MB LRU が追い出しても本体は解放されない
   (`LazyCellImageBudget` の型コメントの実測)。既定の表紙は 512 段(1 枚 ≈ 0.7 MB)で、2,439 冊を端まで流すと ≈ 1.7 GB がペインを壊す
   まで残る。本棚が 2026-09-09 に直したのと同じ欠陥。直し方: `CollectionGridView` と同じく予算を持ち、`image = made` の所で
   `note(retaining:)`、グリッドに `.id(epoch)`。
2. **【中・設定消失】旧「ファイル名フォーマット」の引き継ぎが、失敗しても旧設定を消す**(`MetadataRulesStore.migrateLegacyFormatsIfNeeded`)。
   `defer` が旧 3 キーを無条件に消し、全書式を 1 つのルールセットとして `update` に渡して失敗しても NSLog だけ。qooMeta の型は旧
   `MetadataFormatCompiler` より厳しい(`@title`/`@series` 必須、欄の隣接不可)ので、旧一覧に 1 つでも通らない書式があると初回起動で
   全部失われる。テスト `legacyFormatsAreMigratedOnce` は正しい書式だけ。直し方: `FilenameFormat(text)` が通るものだけ引き継いで残りを
   知らせる、または errors が空でないときは旧キーを消さない。
3. **【中・保存データ】保存データ JSON の往復で `fieldsVersion` が 0 に落ちる。** 書き出しは `fieldsVersion` を書かず qooMeta の欄が空なら
   省き(`ExportedBookMetadataEntry`)、読み込みは `hasQooMetaFields ? 1 : 0`(`LibraryImportExportService`)。タイトル + 著者 1 人だけの
   版 1 の行が往復で版 0 になり、メタデータの編集ウインドウの「新しい欄が無い頃に登録された」ダイアログが全冊分出て、「ロックを外して
   解析し直す」を選ぶと登録値が捨てられる。直し方: `fieldsVersion` を JSON に(省略可能な Int で)出し入れし、無いときだけ今の推定。
4. **【中・下書き消失】メタデータの編集ウインドウを開くたびに、一覧に無い本の下書きを消す**(`MetadataEditorModel.open` →
   `MetadataDraftStore.keepOnly`)。一覧の `folderBookIDs()` はスマートライブラリ OFF・対象フォルダ未接続・対象から外した、のどれでも `[]`
   なので、対象フォルダの本を直して(ロックせず)閉じ、その状態で開くと下書きが回復不能に消える。型コメントの想定「Finder で動かした本」
   より条件がずっと広い。直し方: 消すのは「知らない本 かつ 実体が無いと確かめた本」に限るか、消さない。
5. 【中〜低・設定消失】保存済みの規則の差分が `RuleChanges(data:)` で読めない(外側の settings.json は正常)と `changes` が `.none` に
   なり、次の `update` が `.none` + 1 変更で組み立てた差分を保存して、`keepingUnreadable` で持ち続けるはずの差分が写しも無く消える
   (`keepCopy` は外側が壊れたときしか走らない)。起きるのは手で編集・将来の qooMeta で `kind`/`base` が変わる場合。
6. 【中〜低・値の消失】シリーズ無しで巻だけを持つ登録済みの行(旧 4 欄シート・ComicInfo/EPUB/PDF 取り込みで作れる)は、
   `BookMetadataValues.confirmation` が `.notInSeries(fields:)` を返し(巻の置き場が無い)、行の値は提案から作るので編集ウインドウで巻が
   見えない。ロックを外して掛け直す、または錨の効果で `push` が書き直すと `applyUpsert` の `trimmed` が `volumeSort` も nil にして永続化。
7. 【低】索引と控えの競合(同じ型が 2 か所): `SmartLibraryCatalog.rebuild` は `index.apply` が成功した後に世代の検査で抜けると索引だけ
   進んで `indexedInputs`/`proposalsByID` が古いままになり、その本の提案が規則変更まで古いまま出る(直し方: apply/load が成功したら
   索引の控えは世代に関わらず書き戻し、`books` の公開だけ止める)。`MetadataWorkspace.setRules` は `inputs[id]` を `apply` の前に書き
   換え、次の `setRules` の `reloading?.cancel()` が `apply` の途中で当たると索引だけ古いプリセットのまま。
8. 【低】`SmartLibraryPane.resolvedURL` がメインで `fileExists`(切断中のネットワークの本をクリックするとタイムアウトまで固まる)。
   全欄が空の本をロックすると `applyUpsert` が `.noChange` で何も登録しないのに鍵の表示だけ付く。drafts.json のデコード失敗は `try?` で
   空になり次の保存で上書き(規則ストアのような写しが無い)。`saveCache` は集め直しのたびに全冊の JSON を書く(有界)。`autoPreset` が
   `rules.presetCatalog` を本ごとに組み立て直す(安全だが無駄)。
9. ~~【未検証・要実測】メタデータの編集ウインドウのツールバー/alert/sheet の閉包が workspace を捕まえる~~ → **実測して、漏れていない**
   (2026-09-22)。HEAD の Debug(本番の写しのデータ)で「編集 ▸ メタデータの編集…」→ 確認に「あとで」→ 閉じるボタン、を 3 回、閉じたら
   カーソルを動かして 5 秒待ってから `heap` で数えた。`MetadataWorkspace`・`MetadataBookTable.Coordinator`・セル(170)・ウインドウの
   `ProposalIndex` は開くたびに 1 組でき、閉じるたびに 0 へ戻る(スマートライブラリの索引の 1 つは開く前からある)。閉じた後も残るのは
   `MetadataEditorModel`・`MetadataDraftStore`・`CoverOverrideController` とウインドウ(`AppKitWindow`/`AppKitWindowController`)の
   各 1 つで、回を重ねても増えない(`Window` のシーンが使い回す 1 組。`close()` で workspace を手放している)。phys_footprint は
   起動 155 MB → 開く 218 MB → 閉じる 189・196・197 MB。直す必要なし。

問題なしと確かめたもの: SmartLibraryCatalog の購読/Task の解除と世代の検査(ProposalIndex は `CancellationError` しか投げない)、
Scanner の上限と TCC/隠し/パッケージの回避、表紙の取得(取り消し・同時数・LIFO・`knownKey:`)、規則の正規表現(組み立て時の検査と 20 ms の
予算)と静的状態のスレッド安全性、settings.json の原子的な書き込みと写し、SwiftData(既定値付きの列・`StoreSchemaGuard`・開き直しのテスト・
ModelContext 1 つ・`upsertAll` の削除範囲)、書き出し(項目の追加のみ)、NSTableView の行/列対応と weak な delegate/target、環境オブジェクトの
注入、AppStores の OFF 経路。要求の外の付記: シークレットウインドウでもスマートライブラリの表紙が `savesToDisk` 既定 true でディスクに
書かれる(ファイルブラウザは `!state.isPrivate`)。

### 残り(次の人へ)

- **まず上の「コード監査」の 1〜4 を直す**(9 は実測して漏れていなかった)。直したら監査の節に「直した」と書く。
- スマートライブラリ: 表紙の大きさのピンチ、選択と複数冊の右クリック、左ペインの折りたたみは未実装。
- README / MANUAL / CHANGELOG([Unreleased]) / CLAUDE.md は 2026-09-22 に一式更新した(利用者の指示)。以後の変更も同じ組で直す。
