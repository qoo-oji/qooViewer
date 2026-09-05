# 09. UI ―― 画面・入力・見た目

## 画面の構成

```
ContentView(ウインドウ/タブの中身)
 ├─ HStack: [SidePanelView(常時表示)] + (ViewerView | WelcomeView) [+ SidePanelView(右配置)]
 ├─ ZStack overlay: SidePanelView(「隠す」設定のときのホバー表示)
 ├─ BookLoadingOverlay(読み込み中)
 ├─ ファイルのドロップ先(ウインドウ全体に1つ)
 └─ リネーム・削除のダイアログ(サイドパネル由来。ホバー自動非表示を止める必要があるためここ)

ViewerView(本1冊)
 ├─ mainZStack
 │   ├─ VStack: [ツールバー(常時表示)] + pageArea + [プログレスバー(常時表示)]
 │   ├─ ツールバー/プログレスバー(自動隠しのときは画像の上に浮かべる)
 │   ├─ ThumbnailGridView(ページ一覧。外側クリックで閉じる)
 │   ├─ PageInfoPanelView(「情報を見る」)
 │   ├─ LoupeOverlayView(拡大鏡。pageArea の imagesRow に overlay)
 │   └─ トースト、拡大率表示
 ├─ pageArea: 見開きの左右スロット(SpreadPageSlot)、クリックゾーン、ScrollView(スクロールする表示モード)
 ├─ NSEvent ローカルモニタ: スクロール/スワイプ/キー/右クリック/ページ一覧の外側クリック
 └─ シート・アラート: お気に入りフォルダ選択、伝播範囲、自動レイアウト確認、境界の毎回確認、書き出し
```

`ViewerView.swift` は約 4800 行あります。`body` は型チェックが時間内に終わらない不具合を避ける
ために、`windowContent` / `applyFileDropTarget` / `applyPreferenceChangeHandlers` /
`handleOnAppear` / `handleOnDisappear` などへ切り出してあります。1つ `onChange` を足しただけで
「reasonable time」の限界を超えた経緯があるので、モディファイアを足すときは切り出し先へ。

`ContentView` が `isPrivateWindow` を自分で持たず `appState` から読むのは、`struct` の init が
ビューの作り直しのたびに走り、環境設定を切り替えた瞬間に `AppState` 側と食い違うためです。

## 入力

### キー(KeyBindingStore / RemappableKey / ViewerAction)

- 1つの操作に複数のキー、1つのキーに1つの操作。基本(画面内に収める)と、スクロールできる
  3モード(横幅に合わせる/同(単ページ)/拡大縮小しない)の上書き(cooViewer の
  `KeyArrayMode2/3` と同じ2段構え)。
- 既定値は cooViewer のノーマルモードに合わせつつ、qooViewer の設計(画面位置基準の
  `spatialLeft/Right` と、読み方向に依らない `moveNext/Previous` を分ける)を優先。矢印は空間、
  z/space と x/shift+space は物語的な次/前。option+矢印は端へ(`spatialEndRight/Left`。
  読み方向を切り替えても向きが崩れない)。数字キーは割合ジャンプ。
- **キー入力は `.onKeyPress` ではなく NSEvent のローカルモニタで取る。** 環境によっては矢印
  キーが SwiftUI に届かずビープだけ鳴った報告があったため。`RemappableKey.from(nsEvent:)` は
  仮想キーコードで判定し、矢印キーに OS が付ける `.numericPad` / `.function` フラグの影響を
  受けないよう shift/option/control/command だけを個別に見る。
- command 付き、control+矢印などの OS 標準と衝突する組み合わせは語彙に入れない。
  表示モードの直接選択(⌘1〜⌘4)はメニューの `.keyboardShortcut`(メニューの並び順どおり)。
- `closeWindow` / `closeTab` / `quitApplication` はマウス専用(⌘W/⌘Q と重なる)。
  `showFavoritesList` は入り口を失ったのでキー設定の一覧に出さない(列挙からは消さない)。

### マウス(MouseTrigger)

- 語彙: クリック = ボタン(左/中)× 位置(左半分/右半分/全体)× 修飾キー(shift/option)、
  ドラッグ = ボタン × 4方向 × 修飾キー、ホイール = 上/下 × 修飾キー(shift 不可: macOS が
  shift+ホイールで軸を入れ替えるため)。右ボタンと control+クリックはコンテキストメニュー固定。
- 解決は「位置指定 > 全体」「モード別 > 基本」(`resolvedClickAction`)。割り当てが1つも無ければ
  当たり判定を無効にして下の ScrollView へ通す(`hasAnyPointerAction`)。
- ドラッグジェスチャーは 30pt 以上・1秒以内・優勢な軸(cooViewer と同じ)。位置(Zone)を
  持たないのは、qooViewer には空間基準の操作が別にあるため。
- クリックでのページ送りは、ウェルカム画面のダブルクリックの2回目を読み捨てるため、本を開いてから
  `NSEvent.doubleClickInterval` の間は無効(`isClickZoneArmed`)。
- ホイールは1ノッチが複数イベントに分かれるマウスがあるため 40ms のクールダウン。

### トラックパッド

- 「フリックでページ送り」(既定 ON): 2本指の縦スクロールは無視し、左右のフリックで送る。
  3本指/4本指のスワイプは `.swipe` イベント。
- 「2本指スクロールを反転」: 画像が動く向きだけを反転(ホイールやフリックに割り当てた操作の
  向きは変えない。そちらはキー・マウス設定で入れ替えられ、二重になるため)。
- ピンチ拡大(`pinchZoomFactor`): 1.0 以上、上限は環境設定。永続化しない(一時的な操作)。
  ページ・表示モード・見開き・読み方向が変わったら解除。

### 表示モード(ScalingMode)と スクロール送り

- `fitToScreen` / `fitWidth` / `fitWidthSplit` / `noScale`。**`fitWidthSplit` の画面名は
  「横幅に合わせる(単ページ)」**。cooViewer 由来の「見開き分割」は「画像を2つに切る」と
  誤解された(実際に起きた)ため採用していない。分割する意味の無い内容では `fitWidth` と同じ表示。
- `scrollAndMoveNext`: 1画面分下へ → 下端なら横へ回り込んで最上部へ → 余地が無ければ次のページ
  (cooViewer の action 27)。画面内に収めるモードでは縮退して単なる次ページになるので、
  1つの割り当てで cooViewer のモード別の操作感を再現できる。
- ホイールの扱いはモード別の `WheelScrollBehavior`(スクロールのみ/端まで来たら横へ/横にも余地が
  無ければページ送り/常にページ送り)。修飾キー付きのホイールは常に割り当てた操作。
- スクロール位置と可動範囲は SwiftUI の `ScrollGeometry` では正しく取れなかった(インセットと
  スクロールバー幅のずれで下端に着いても「まだ動ける」と判定し続けた)ため、`ScrollViewAccessor`
  で裏の `NSScrollView` を掴んで読み書きする。前のページへ戻ったときは読み終わり側の隅から
  (`pendingPageEntryAtEnd`)。

## 帯とパネルの自動表示

- ツールバー/プログレスバー/サイドパネルは「隠す」設定でウインドウ端の帯にカーソルが入ると
  現れる。表示までの遅延は3面で別々(既定 0)。帯から出たら待ちをキャンセル。
- カーソルがウインドウの外へ出たら即座に隠す。マウス移動のローカル/グローバルモニタに加え、
  **メニューバーの上へ抜けた場合はどちらにも届かない**ため `WindowMouseExitAccessor`
  (`NSTrackingArea` の `mouseExited`)で補う。誤検知があるので受けた側で実際の位置を確認する。
- メニューを開いている間・サイドパネル由来のダイアログが出ている間は隠さない。
- ツールバーの下端の位置は `WindowYPositionAccessor` で AppKit に直接聞く(逆算するとタイトル
  バーの実装でずれ、ボタンの下半分で反応しなくなった)。
- 常時表示のときは HStack/VStack に組み込み(画像を押しのける)、隠すときは ZStack に浮かべる
  (出入りのたびに画像サイズが変わってちらつかないため)。

## サイドパネル(SidePanelView)

5つのモード(`SidePanelMode`): ブラウザ(上段フォルダ/下段本の中身)・ブックマーク(上段お気に入り
ツリー/下段ブックマーク)・履歴・ページ・リソース。幅 220〜480pt、左右どちらにも置ける。
AppState を参照しない作り(参照するとページ送りのたびに本体が再評価される。`PanelPartContextMenu`
のように薄いラッパーで受ける)。

- **フォルダブラウザ**(`SidePanelBrowserState`): 本の切替をまたいで生きる。**画像ファイルを行に
  出さない**(目的は本を探すこと)。そのため画像だけのフォルダは行き止まりに見えるので、
  「このフォルダの画像を開く」導線を出す(`currentDirectoryHasImages`)。本を開くと親フォルダへ
  アンカーし本自身をハイライト(画像群の本は**もう1階層上**)。フォルダ行のクリックで本を開いた
  直後は再アンカーを1回見送る。並べ替え(名前/サイズ/種類/作成日/変更日、昇降)はパネル上部の
  メニュー。`DirectoryBrowser` は `Task.detached` で列挙する。
- **本の中身ブラウザ**(`BookContentsBrowserState`): 本ごとに作り直す。フォルダ/書庫/画像群のみ
  (PDF/EPUB は非対応)。深さが増える方向にしか動かない階層スタックで、ページ送りに追従して
  該当階層まで**ルートから辿り直す**(`revealCurrentPage`。単に push すると「1階層上」が
  通り過ぎた別の書庫へ戻る)。並びは本のページ順そのもの(フォルダを上にまとめない)。
  `NestedArchiveResolver` は専用インスタンスで `openTransient`。
- **履歴/お気に入り/ブックマーク**の行は右クリックでリネーム・削除・「新規◯◯で開く」。
  右クリック中の行は `SidePanelContextMenuHighlight`(ホバー中の行 × `NSMenu.didBeginTracking`)で
  枠を出す(`.contextMenu` は開閉を教えてくれず、`menuItems` の中で `@State` を変えられないため)。
- **リソース**モードは [05](05-page-display-and-memory.md#リソースモニタと異常検出)。

## プログレスバー(ProgressBarView)

以前ホバー中にメインスレッドが止まる(レインボーカーソル)不具合があったため:
カーソルの x 座標そのものを `@State` に持たない(ホバー中のページ番号とスロット位置だけ)、
サムネイル読み込みはデバウンス後に同時数を絞って、フィルムストリップに明示的な frame。
枚数(3〜15)・文字・強調色・太さ・暗くするかは環境設定(既定は従来と同じ見た目)。
カーソル位置のページ番号は設定に関わらず常に出す。

## ページ一覧(ThumbnailGridView)

シートではなく `mainZStack` の1レイヤー。パネルの外側(ビューア画面のどこでも)をクリックすると
閉じる(`ThumbnailGridBackdropView` + NSEvent モニタで判定)。セルの大きさ・間隔・余白は環境設定、
セル枠の縦横比は最初に読めたページの実寸に合わせる。`LazyCellImageBudget` で画面外セルの画像を
定期的に手放す。ホイール1ノッチの行数はモニタで自前処理(物理ホイールのみ)。
イベントモニタの**持ち主は ViewerView**(ウインドウごと閉じるとパネルの `onDisappear` が呼ばれない)。

## パネルの面と文字の輪郭

すりガラスで描く面は `PanelSurface` の6つ(ページ一覧・ツールバー・プログレスバー・
サイドパネル・ウェルカム画面・その他の浮かぶ表示)。それぞれ `PanelSurfaceStyle` =
すりガラスの濃さ + 重ねる色 × 濃さ + 文字の影(輪郭)の段階。`Material` の種類を選ばせないのは、
サイドパネルだけ `NSVisualEffectView`(SwiftUI の `.regularMaterial` はキーウインドウで境界に
青い線が出る不具合があった)で描いており、両者に共通する意味を持つのが「濃さ+重ね色」の2層
だけだから。既定値は従来の描画と完全一致。

**面の重ね色を文字と同じ色にすると文字が消える**(黒 100% + ライト外観)。面の下はページ画像で
色が読めないため文字色の自動反転は採らず、**反対色の輪郭を文字の形のまま太らせて後ろに敷く**
(`PanelContentShadow`。ぼかすと「白くにじんだ幽霊」になる。方向は上下左右の4つだけ ―― 8方向
だと `.shadow` の連鎖で太さが2〜3倍になる。刻みは 0.25pt = Retina の半ピクセル)。

**面に UI を足したときの約束(CLAUDE.md より)**:

| 足したもの | 対応 |
|---|---|
| 素の文字・アイコン | `.panelOutlinedContent()`(文字とアイコンだけのコンテナに付けてもよい) |
| 自前の不透明な背景を持つ部品(検索欄・塗りのバッジ・選択中のモードボタン)、画像・サムネイル | 何もしない(輪郭が付くと不自然) |
| 輪郭が滲むネイティブ部品(スライダー) | `.panelControlWell()` |
| アクセントカラーで状態を示すもの | `.panelOutlinedAccent(in:)` |
| コンテキストメニュー・シート・アラート・ポップオーバーの中身 | 何もしない(macOS が不透明に描く) |

忘れても輪郭が出ないだけで、他の部品には漏れない。確認は「ライト外観+黒 100%」
「ダーク外観+白 100%」で塗った面に対して行う。アイコンボタンは `PanelIconButtonLabel` が
1箇所で輪郭を付けている。グラフ(`ResourceGraphView`)は Canvas の中で同じことを再現している。

「ウインドウの背後を透かす」(既定 OFF)は、常時表示の帯とウェルカム画面に `.behindWindow` の
すりガラスを敷くスイッチ。常時表示の帯は背後に何も描かれていないので、SwiftUI の `Material`
では灰色の板になる。

## 補助ウインドウ

### 一覧ウインドウの共通の形

メタデータの編集・書き出し3種・ブックマーク/レイアウトの編集・お気に入りの整理・
保存データの削除・履歴の削除は同じ形です。新設するときは全部やってください。

1. 操作(検索・絞り込み・並べ替え・追加)はタイトルバーのツールバーへ。中身に見出しや説明文を置かない。
2. 一覧はツールバーの下へスクロールして潜る(`ScrollEdgeEffect.hardTopScrollEdgeEffect()`、macOS 26 のみ効く)。
3. 件数・選択数は下部中央の `ListWindowStatusBar`(`.safeAreaInset(edge: .bottom)`)。
4. 列幅は開いた時点の内容を実測して決め(`ExportColumnWidthEstimator` / `SidebarWidthEstimator` /
   `MetadataButtonWidthEstimator`)、上限を設ける。以後はユーザーのドラッグを優先し勝手に変えない
   (`TableColumnCustomization`)。
5. 形式バッジ(`FormatBadgeView`)は名前の横。同名の cbz/epub を区別するため。
6. インジケータのアイコンは常に同じ幅のスロットに描き、非表示は `opacity`(`Group` の中の
   `EmptyView` は幅を持たず列がずれる)。
7. チェックは絞り込みをまたいで積み上がる。「すべて選択」は表示中の行だけ。
8. 検索欄は `releasesFocusOnOutsideClick()`(欄の外のクリック・Return・Esc でフォーカスを外す)。
9. ViewModel は `@EnvironmentObject` が揃ってから作るため、親は素の `@State` で持ち、
   観測は `@ObservedObject` を持つ子ビューに任せる(親が観測しないと再描画されない)。
10. 単一インスタンスの `Window` なので、変更通知を購読して一覧を読み直す。

### ウェルカム画面

本棚は無い。「最近開いたファイル」「最近のお気に入り」を各 10 件(存在確認済みのものだけ、
ブックマークは解決しない)。シークレットウインドウでは両方とも出さない。列幅は見出しと
バッジの実測。

### 環境設定(SettingsView)

- 画面の一覧は **`SettingsPane` が単一の情報源**(サイドバー・中身・タイトル・グループを
  `switch self` で網羅。`default:` を書かない)。8タブで `TabView` が限界になり、システム設定と
  同じ2ペインへ移した。前回の画面を `@AppStorage` で覚える。
- 行の作法(`SettingsControls.swift` 冒頭が正典): ラベルは項目名だけで意味が通る短い語句、
  補足は ⓘ のホバーの吹き出し(`help:`)へ、選択肢に説明を付けない(説明が要るなら選択肢名が悪い)。
  幅が足りなければ `ViewThatFits` で縦積み。ポップアップは自前の背景と境界線で「ドロップダウン
  だと分かる」ようにする。
- 「外観」と「レイアウト」は2階層(面ごと/形式ごとの子ページ)。子ページは次回に持ち越さない。
  タイトルバーの「戻る」は全画面共通で `SettingsNavigator` が状態を持つ。右クリックの「調整…」は
  `SettingsNavigator.appearanceTarget` に行き先を置いてから `openSettings`。
- `Settings` シーンのウインドウはリサイズ不可で作られ、SwiftUI から変えられないため
  `SettingsWindowResizabilityAccessor` が `.resizable` を足す(内部識別子でウインドウを探さない)。
- 「初期設定に戻す」の範囲は画面に見えている項目だけ、データが消える設定は除く
  (→ [06](06-persistence.md#apppreferences))。
- 説明文の日本語は文ごとに改行(→ [02](02-project-and-build.md#ローカライズ))。

## その他の小さな約束

- カーソルの push/pop は `hoverCursor(_:)` で対にする(ビューが消えると pop されず矢印が戻らなかった)。
- 「情報を見る」はサブメニューではなくオーバーレイパネル(値の先頭を揃えたい。`.popover` は
  ウインドウの外へはみ出した)。
- 境界での「毎回確認」は自前のシート(`.confirmationDialog` はボタン3つまで)。
- お気に入り一覧のツールバー版は `NSMenu` を直接組み立てる(`FavoritesNSMenuBridge`。SwiftUI の
  `Menu` はコードから開けない)。メニューバー版は SwiftUI の `Menu` のネスト。
- 外観(ライト/ダーク)は `NSApp.appearance`(`.preferredColorScheme` は AppKit のダイアログや
  Dock メニューに届かない)。「コントラストを上げる」に追従する。
- トースト(`showToast`)、拡大率表示、「情報を見る」は面 `overlays` に属する。
