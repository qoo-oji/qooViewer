# 09. UI ―― 画面・入力・見た目

## 画面の構成

```
ContentView(ウインドウ/タブの中身)
 ├─ HStack: [SidePanelView(常時表示)] + (ViewerView | WelcomeView(Views/Welcome/)) [+ SidePanelView(右配置)]
 ├─ ZStack overlay: SidePanelView(「隠す」設定のときのホバー表示)
 ├─ BookLoadingOverlay(読み込み中)
 ├─ ファイルのドロップ先(ウインドウ全体に1つ)
 └─ リネーム・削除のダイアログ(サイドパネル由来。ホバー自動非表示を止める必要があるためここ)

ViewerView(本1冊)
 ├─ mainZStack
 │   ├─ VStack: [ツールバー(常時表示。左端は「ホームへ戻る」)] + pageArea + [プログレスバー(常時表示)]
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
  お気に入りが無効化されている間(`FavoritesFeature.isEnabled == false`)は
  `toggleFavorite` / `showFavoritesOrganizer` も同様に出さない(既定の割り当ては残す)。
- `returnToWelcome`(本だけ閉じてホームへ。ウインドウ/タブは残る ―― 閉じるのは
  `closeTab`)は**キー・マウスとも既定の割り当てを持たない**。主な入り口はツールバー左端と
  サイドパネルのモード切替の左にあるボタンで、キー/マウスへ割り当てたい人だけが自分で割り当てる。
  実体は `ViewerView.returnToWelcome()`(`flushPendingSave` → `AppState.closeBook()`)で、
  最終ページの動作(`PageBoundaryBehavior`)・書き出し後の動作(`BookExportCompletionBehavior`)
  とも共通。`ViewerViewModel.onPageBoundaryRequest` からは `performViewerAction` 越しに呼ぶ
- **ビューアのボタン・右クリックメニューの閉包は `ViewerView` を直接捕まえない**(2026-09-13)。
  `Button { perform(.x) }` は `self`(ViewerView の写し → appState・viewModel → PageLoader)を丸ごと
  捕まえ、SwiftUI はその閉包を AppKit のボタン(`SwiftUIAppKitButton`)・NSMenuItem・確認ダイアログへ
  渡す。それらはウインドウを閉じた後も解放されないので、本のウインドウを閉じるたびに約118MB残っていた
  (→ [13](13-history-and-known-limitations.md#既知の制限))。**`relay.send { $0.perform(.x) }` と書く**
  (`ViewerActionRelay`。中身は onAppear で入れ、onDisappear とウインドウを閉じるときに空にする)。
  `NSViewRepresentable` に閉包を渡すなら `dismantleNSView` で切る、`NSTrackingArea(owner: self)` は
  ウインドウから外れたら外す、Binding の閉包は `AppState` を weak で捕まえる、も同じ理由。
  **新しくボタン・メニュー項目・Toggle を足すときもこの形にすること**(直接書いても動くので、
  漏れは実測でしか分からない ―― 測り方は [12](12-verification-and-debugging.md#閉じたウインドウが解放されるかの測り方))。
- **ウインドウを閉じる2つの経路は、どちらも `AppState.closeBook()` を先に通す**(2026-09-13)。
  Cmd+W とタブの×は `windowShouldClose`(タブ1枚)、赤い閉じるボタンと「ウインドウを閉じる」は
  `BookClosingWindowDelegate.forceCloseWindow`(タブすべて。`close()` を直に呼ぶので `windowShouldClose` を
  通らない)。**Cmd+W(File ▸ 閉じる = `performClose:`)は、閉じるボタンの差し替え先へ来る**: `performClose` は
  「閉じるボタンを押したのと同じ」なので、差し替えた action が sender = 閉じるボタンで呼ばれる(AppKit 単体で
  実測、2026-09-26)。それまで Cmd+W でもタブがすべて閉じ、確認が出ていた。今は差し替え先の
  `closeButtonClicked` が `NSApp.currentEvent` を見て、このウインドウの閉じるボタン上の左クリックなら
  `forceCloseWindow`、それ以外(キー入力・メニューのクリック・イベント無し)なら `closeTab()`(macOS 標準どおり
  タブ1枚、確認なし)に分ける。「ウインドウを閉じる」メニューには ⇧⌘W(Safari と同じ)。本を一度も開いていないウインドウには
  `BookClosingWindowDelegate` が付かないので、そのメニューは同じ確認(`confirmCloseIfMultipleTabs`、static)の後で
  タブグループの全ウインドウへ `performClose` を送る(以前は `performClose` 1回 = タブ1枚だった)。後者が `closeBook()` を呼んでいなかった間、本のセキュリティスコープ付きアクセスの解放は
  `AppState.deinit` 任せで、その deinit は SwiftUI の `focusedValues` に掴まれて来ない
  (→ [13](13-history-and-known-limitations.md#既知の制限))ため、赤いボタンで閉じるたびに
  アクセスが開いたままになっていた。
  ―― 直接呼ぶとクロージャが `ViewerView` のコピーを捕まえて循環参照が戻るため。

### マウス(MouseTrigger)

- 語彙: クリック = ボタン(左/中)× 位置(左半分/右半分/全体)× 修飾キー(shift/option)、
  ドラッグ = ボタン × 4方向 × 修飾キー、ホイール = 上/下 × 修飾キー(shift 不可: macOS が
  shift+ホイールで軸を入れ替えるため)。右ボタンと control+クリックはコンテキストメニュー固定。
- 解決は「位置指定 > 全体」「モード別 > 基本」(`resolvedClickAction`)。割り当てが1つも無ければ
  当たり判定を無効にして下の ScrollView へ通す(`hasAnyPointerAction`)。
- ドラッグジェスチャーは 30pt 以上・1秒以内・優勢な軸(cooViewer と同じ)。位置(Zone)を
  持たないのは、qooViewer には空間基準の操作が別にあるため。
- クリックでのページ送りは、ホームのダブルクリックの2回目を読み捨てるため、本を開いてから
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

### 「隠す」3つは最初のフレームから効かせる

「ツールバーを隠す」「プログレスバーを隠す」「サイドパネルを隠す」はウインドウごとの状態
(`AppState`)ですが、値そのものは `AppPreferences` に持たせて次のウインドウ・次回起動へ引き継ぎます。
この写しを `ContentView` の `onAppear` だけで行っていたころは、**隠してあるはずのパーツが最初の
1フレームにだけ現れて、直後に閉じる様子が見えていました**(ユーザー報告 2026-09-09)。とくに
サイドパネルは幅を持ち 0.15 秒のアニメーションが掛かるので、起動直後に「サイドパネルが隠れる様子」
としてはっきり見えます。`AppState` を作る時点(`ContentView.init`)で
`AppPreferences.hiddenChromeDefaults` を渡し、最初のフレームから正しい姿で描きます。
`onAppear` の写しはそのまま残してあります ―― 他のウインドウでこの設定が変わった後に開いた
タブにも効かせるためで、値が同じなら何も起きません。

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
モード切替の並びの左端には「ホームへ戻る」ボタンと区切り線がある。モードの選択肢では
ないので、高さはモードボタンと同じ 30pt、**幅は等分に加えず 30pt 固定**で、押しても選択状態には
ならない。本を開いていなければ無効(`onReturnToWelcome == nil`)。
お気に入りが無効化されている間(`FavoritesFeature.isEnabled == false`)、ブックマークモードは
上段と分割ハンドルを出さず、ブックマーク一覧が全高を使う1列構成になる(履歴・ページと同じ形)。
分割比率は保存されたままなので、復活させれば以前の比率が戻る。
AppState を参照しない作り(参照するとページ送りのたびに本体が再評価される。`PanelPartContextMenu`
のように薄いラッパーで受ける)。

- **フォルダブラウザ**(`SidePanelBrowserState`): 本の切替をまたいで生きる。**画像ファイルを行に
  出さない**(目的は本を探すこと)。そのため画像だけのフォルダは行き止まりに見えるので、
  「このフォルダの画像を開く」導線を出す(`currentDirectoryHasImages`)。本を開くと親フォルダへ
  アンカーし本自身をハイライト(画像群の本は**もう1階層上**)。フォルダ行のクリックで本を開いた
  直後は再アンカーを1回見送る。並べ替え(名前/サイズ/種類/作成日/変更日、昇降)はパネル上部の
  メニュー。`DirectoryBrowser` は `Task.detached` で列挙する。**読み直す契機**(2026-09-19): 移動・本の切り替わりのほかに、
  アプリ自身がファイルを動かした知らせ(`FileSystemChange`。表示中のフォルダに関わるときだけ。フォルダの名前が変わったら付いていく)、
  アプリのアクティブ化、ボリュームの着脱。以前はどれも無く、表示中のフォルダに本を足しても一覧が変わらなかった。表示中のフォルダが
  消えていたら残っているいちばん近い祖先へ移る(以前は読み込みの失敗を全部「アクセスを許可…」にしていた)。FSEvents では見張らない。
  **画面に出ている間だけ読む**(2026-09-25 の監査。`SidePanelBrowserState.setVisible`、条件は `ContentView.isSidePanelBrowserModeOnScreen`
  ―― 機能が ON・パネルが抑止されていない・ブラウザモード・パネルが常時表示か引き出し中)。出ていない間は上の契機で印だけ付け、
  出たときに 1 回読む(フォルダが変わっていたら前の行は捨てる)。以前はパネルを隠していても・別のモードでも、アクティブ化・
  着脱・本を開くたびに全ウインドウで一覧を読み直した(直下のフォルダごとに中を覗くので、共有では秒単位)。
- **本の中身ブラウザ**(`BookContentsBrowserState`): 本ごとに作り直す。本そのものがフォルダ/
  書庫/画像群のときだけ(本そのものが PDF/EPUB のときは出さない)。フォルダ/書庫の**中に**
  ある PDF/EPUB は行として並び、踏み込むとそのファイルのページ一覧になる
  (`BookEntryLevel.documentPages`。→ [04](04-book-loading.md#フォルダ書庫の中の-pdf-と-epub))。
  深さが増える方向にしか動かない階層スタックで、ページ送りに追従して
  該当階層まで**ルートから辿り直す**(`revealCurrentPage`。単に push すると「1階層上」が
  通り過ぎた別の書庫へ戻る)。並びは本のページ順そのもの(フォルダを上にまとめない)。
  `NestedArchiveResolver` は専用インスタンスで `openTransient`。
  ブラウザモードの下段が出ている間だけ作り・追従する(`ContentView.isBookContentsPaneOnScreen`、2026-09-25)。出たときに今の本・
  今のページへ追いつき、同じ本なら作り直さない。以前は本を開くたびに作り(書庫をもう 1 度開いて一覧を取り、開いたまま持つ)、
  ページ送りのたびに追従した。ウインドウの `willClose` で閉じる。ページ番号の引き当ては `pageOrder` の索引から
  (`pageIndex(ofMatchKey:in:)`。以前はクリックのたびに全ページを線形に探した)。
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
サイドパネル・ホーム・その他の浮かぶ表示)。それぞれ `PanelSurfaceStyle` =
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
| 薄い地しか持たない区画(絵がまだ無いカバーのセル) | `.panelOutlinedFrame(in:)` |
| コンテキストメニュー・シート・アラート・ポップオーバーの中身 | 何もしない(macOS が不透明に描く) |

`panelOutlinedFrame(in:)` は `panelOutlinedAccent(in:)` と描くもの(反対色の `strokeBorder`)が
同じで、要る理由が違う ―― あちらは「状態が伝わらない」、こちらは「区画そのものが在ることが
伝わらない」。**「自前の背景を持つから何もしない」と判断する前に、その背景が本当に不透明か
確かめること** ―― `Color.secondary.opacity(0.15)` のような薄い地は地になっておらず、面を文字色で
塗ると中身ごと消える(コレクションのカバーの形式バッジで実測 2026-09-10。[14](14-library-collections.md))。

忘れても輪郭が出ないだけで、他の部品には漏れない。確認は「ライト外観+黒 100%」
「ダーク外観+白 100%」で塗った面に対して行う。アイコンボタンは `PanelIconButtonLabel` が
1箇所で輪郭を付けている。グラフ(`ResourceGraphView`)は Canvas の中で同じことを再現している。

「ウインドウの背後を透かす」(既定 OFF)は、常時表示の帯とホームに `.behindWindow` の
すりガラスを敷くスイッチ。常時表示の帯は背後に何も描かれていないので、SwiftUI の `Material`
では灰色の板になる。

## 補助ウインドウ

### 一覧ウインドウの共通の形

メタデータの編集・書き出し3種・ブックマーク/レイアウトの編集・お気に入りの整理(現在は
開く入り口が無い)・保存データの削除・履歴の削除は同じ形です。新設するときは全部やってください。

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

「自動リネームの設定」(`AutoRenameSettingsWindow`、2026-09-15)は一覧ウインドウではなく 2 ペインの設定画面(`NavigationSplitView`)。
ステータスバーは右ペインにだけ付け(ウインドウ全体に付けると左の一覧の「+ −」の帯を隠した)、帯は右ペインの上に `safeAreaInset` で
差し込む(`VStack` で積み、文の高さを `fixedSize` で固定していたら、帯が 2 本出たときにウインドウの中身全体がはみ出した)。どちらも実機で見つけた。
→ [15](15-file-browser.md#自動リネーム2026-09-15ユーザー要望)

### ホーム

2026-09-09 に本棚(ライブラリ/コレクション)へ作り直した。構成・編集モードの規則・ドロップの振り分け・
自動登録フォルダは [14](14-library-collections.md) にまとめてある。ここに残す約束事だけ:

- 面は `PanelSurface.welcome`。帯の標準ボタンにも `.panelControlWell()` + ラベルの
  `.panelOutlinedContent()` が要る(背後のすりガラスに合わせて描かれるベゼルは文字色の重ね色で消える)。
- 帯の左端にあった「本を開く…」「履歴から開く」(`RecentBooksPopover`)は 2026-09-13 に撤去した
  (改善要望7。ファイルブラウザへの切り替えを置くため)。本を開くのはファイルメニューの ⌘O、履歴は
  ファイルメニューとサイドパネルの「履歴」モードに残る。チップの幅は 2 つのラベルの見積もりのまま
  (`WelcomeTopBar.chipLabelWidth`)。環境設定「一般」の「最近開いた本を表示する」は行ごと消した。
- 帯の左端は**本棚 ⇄ ファイルブラウザ**の切り替え(2026-09-13、改善要望7 段階 3。「ファイルブラウザ」と文字で出し、
  ライブラリの並びとは区切り線で分ける)。帯の下などの区切りは標準の `Divider` ではなく `WelcomeSeparator`
  (すりガラスの上で境目が読める濃さ + 輪郭)。ファイルブラウザの間は
  どのチップも選ばれていない見た目にし、チップを押すと本棚へ戻る。ファイルブラウザの構成と、AppKit の一覧で
  すりガラス面の輪郭をどう描いているかは [15](15-file-browser.md)。
- 本を開いていない間はサイドパネルを出さない(`ContentView.isSidePanelSuppressedForWelcome`)。
  以前は「ウェルカム画面でも表示する」で選べたが、ファイルブラウザと同時に見せないため設定ごと撤去した。
  「View」→「Hide Side Panel」も本を開いていない間はグレーアウト。例外は**ライブラリとファイルブラウザを両方 OFF にしている間**
  (`WelcomeMode.classic`)で、v1.42 までと同じく本を開いていなくても出し、ホームの「View」メニューにも「Hide Side Panel」を置く
  (2026-09-22、ユーザー要望。ファイルブラウザと二重にならず、その画面には本を探す口が「開く…」と最近開いた本しか無い)。
  モードが切り替わってホバー表示のパネルが浮いたまま残らないよう、`onChange(of: welcomeLibrary.mode)` で下ろす。
- 旧 `WelcomeView.swift`(`WelcomeQuickOpen*` の列幅計算)は削除した。

### メニューバーのホーム画面の項目

2026-09-15、ユーザーと決めた割り振り(それまでホーム画面の操作はメニューバーに 1 つも無く、ファイルブラウザも
新規フォルダ・取り消し・カット/コピー/ペースト・「移動」メニューだけだった)。コードは `App/HomeMenuCommands.swift`。

**割り振りの考え方: 動詞は標準のメニュー、ホーム画面そのものの操作は新しいメニュー。**
⌘C / ⌘⌫ のようなファイル操作は、どのアプリでも「ファイル」「編集」にあるので動かさない(Finder の割り振りが手本)。
ライブラリ・コレクションは漫画ビューアの本筋から外れるので、「ファイル」に混ぜずに 1 つのメニューへ隔離する。

| メニュー | 項目 | 備考 |
|---|---|---|
| **ホーム**(新設。表示・移動の右) | ファイルブラウザ ✓ / ライブラリ ▸ / 新しいライブラリ… / ライブラリの名前を変更… / ライブラリを削除… / 新しいコレクション… / 本を追加… / コレクションの名前を変更… / コレクションを削除… / 別のライブラリへ移動 ▸ / コレクションから削除 / コレクションを作成 / コレクションに登録 ▸ / 編集モード ✓ / ライブラリの設定… / コレクションの設定… / 自動リネームの設定…(2026-09-15。シークレットウインドウでは淡色) | ショートカットは付けない |
| ファイル | 開く(⌘↓)/ このアプリケーションで開く ▸ / 名前を変更 / ゴミ箱に入れる(⌘⌫)/ 圧縮 ▸ / 展開 ▸ / よく使う項目に登録 | ファイルブラウザの選択が相手 |
| ファイル(既存) | Finder で開く・ファイルブラウザで開く・EPUB/PDF/CBZ として書き出す… | 本を開いていなければホーム画面の選択に効く(書き出しはファイルブラウザで 1 冊選んだときだけ) |
| 編集 | ここに項目を移動(⌥⌘V)/ 検索(⌘F)/ メタデータの編集…(既存) | メタデータはいつもウインドウ。ホーム画面で 1 冊選んでいれば、その本を選んで見せる(2026-09-23。[07](07-page-order-layout-bookmarks.md)「書誌メタデータ」) |
| 表示 | リスト ✓ / アイコン ✓ / 並べ替え ▸ / 拡大(⌘+)/ 縮小(⌘−)/ 表示する列 ▸ | **ホーム画面の間だけ**、本を読むときの中身と入れ替わる |

- **名前**: 「コレクション」は中身(ライブラリ・切り替え)と合わず、「本棚」は UI で使っていない語なので、画面の名前「ホーム」にした。
  「移動」メニューの「ホームフォルダ」とは用語表で分けてある。
- **ショートカット**: 「ホーム」メニューには付けない(頻度が低い・⇧⌘ の空きが少ない・後から足すのは互換性を壊さない。
  利用者はシステム設定のアプリのショートカットで自分で足せる)。ほかのメニューには既にキーで動くもの・標準のキーがあるものだけ出す。
  キーはファイルブラウザ(⌘↓・⌘⌫・⌥⌘V)またはホーム画面(⌘F)が出ている間だけ付ける(`homeMenuShortcut`)。
  付けっぱなしにすると、本を読んでいる間のキーやテキストの欄のキーを淡色の項目が奪う。
- **⌘⌫・⌘↓ はメニューが一覧より先に受ける**(ビューが `performKeyEquivalent` で引き受けないキーは `keyDown` より先にメニューへ届く)。
  `HomeMenuKeyRouting` が振り分ける: 一覧(リスト・アイコン)に焦点があれば選択へ、テキストの欄を編集中なら欄の標準の動作
  (行頭まで削除・末尾へ)へ返し、それ以外(左のツリーなど)のキーは何もしない。メニューをクリックしたときは焦点に関係なく選択へ効く。
  「開く」はキー(⌘↓)ならダブルクリックと同じ、クリックなら右クリックの「開く」と同じ開き方(`NSApp.currentEvent` で見分ける)。
- **閉包は値だけを捕まえる**: `set` とボタンは `[weak appState]`、Toggle の Binding の `get` も `[home]`(素のまま `home` を読むと、AppState を
  強く持つ構造体ごと捕まえる。4 回目の監査)。
- **何を相手にするか**(`HomeMenuState`。テストは `HomeMenuTests`): コレクションの中にいればそのコレクション、一覧なら選んだもの
  (名前の変更・本の追加は 1 つだけ)。コレクションから削除・Finder で開く・メタデータはコレクションの中で選んだ本。
  **編集モードに入っていなくてもメニューからは使える**(確認は右クリックと同じものを出す)。本を読んでいるウインドウでは全部淡色、
  シークレットウインドウでは書き込む項目が淡色。
- **Toggle の `set` は渡された値を使わない**: 押された項目が指す状態を、いまの値に対して作る(`isEditing.toggle()`、並べ替えは
  押した基準をそのまま入れる)。メニューの値は保留されうるので、`isOn` を信じると 1 回目が効かないことがある(AX で続けて押して実測)。
- **項目の数は変えない**(`MenuBarMenuGate`)。表示メニューの入れ替えは本を開く・閉じるときだけ(「移動」メニューと同じ理由で安全)。
  本棚とファイルブラウザで表示メニューの並びは同じにし、意味の無い項目は淡色。
- **値の渡し方**: ウインドウごとの値は `ContentView` が `HomeMenuState` / `FileBrowserMenuSelection` を組み、`AppState.setHomeMenu` /
  `setFileBrowserMenu` がメニューを開いている間は保留してから `MenuCheckmarkState` へ出す。ファイルブラウザの可否は右クリックと同じ
  `FileBrowserMenuCommand.isEnabled` を引く(口は `AppState.fileBrowserActions`。持ち主はペイン)。
  **ファイルブラウザの可否は入力が変わるまで作り直さない**(`FileBrowserMenuSelectionMemo`。4 回目の監査)。`ContentView` の本体は
  `FileBrowserState` の publish のたび(ピンチ・ツリーの幅のドラッグの 1 イベントごと)に評価され、判定は選んだ項目を何度も歩くので、
  10 万件を選んだままだと 1 イベントごとに数十万回の URL 操作になった。鍵は判定が読むもの全部(選択と一覧の番号・表示中のフォルダ・
  読み取り専用・シークレット・シート・よく使う項目)で、**判定に新しい入力を足したら鍵にも足す**。`FileBrowserState.selectedEntries` も
  選択と一覧の番号で覚える。
- **ライブラリとコレクションの名前**は `HomeMenuDirectoryStore`(アプリで 1 つ)の値の写しから。`CollectionStore` を
  `allObjectWillChangePublishers` へ入れると表紙の抽出のたびにメニューが作り直されるので、名前・並び・所属が変わったときだけ知らせる。
  並びは名前の昇順(本棚の並び順はウインドウごとに違うので、メニューは誰にとっても同じにする)。`CollectionStore.revision` は表紙の抽出
  1 枚ごとにも進むので、**並べ替える前に名前・所属・「常に先頭/末尾」だけを集めて前回と比べ**、同じなら何もしない(4 回目の監査。
  以前は表紙 1 枚ごとに全ライブラリを `localizedStandardCompare` で並べ替えていた)。
- **シート・確認・ポップオーバーは画面が持ったまま**: メニューは `WelcomeLibraryState.menuRequest` に依頼を置き、出している画面
  (`WelcomeTopBar` / `CollectionGridView` / `CollectionDetailView`。設定のポップオーバーは親が `LibraryPaneControls` へ Binding で渡す)が
  拾って右クリックと同じ経路で開く。受け持たない依頼は取り上げない(`takeMenuRequest(where:)`)。本を開いたら捨てる(`endEditing`)。
  シートの要らない操作(本の追加・別のライブラリへ移動・編集モード・切り替え)はメニューが直接行う。
- **件数の実測(2026-09-15、使い捨ての SwiftUI アプリにダミーデータ)**: SwiftUI はサブメニューの中身を開くまで作らない。
  名前が変わったときの作り直しは件数に関係なく約 3 ms、名前と無関係な値(ページ送りのチェックマーク相当)が変わってもサブメニューの
  ボタンは作り直されない。開くときだけ件数に比例し、3 つのサブメニューを全部開いた合計で 1000 件: 名前の変更直後 約 140 ms・2 回目以降
  約 20 ms、3000 件: 約 400 ms / 約 40 ms。画面への描画は含まない。数千件を並べる使い方は想定しない(ユーザー判断)。
  サブメニューの中身は入力が変わらない限り前のものが使い回されるので、選択で中身が変わるサブメニューには選択の番号(`FileBrowserState.selectionRevision`。アプリ全体で通しなので、
  別のウインドウの選択と同じ値にならない)を `.id` に渡してある(以前は選んだ id の配列で、本体の評価のたびに作って比べていた)。

### 環境設定(SettingsView)

- 画面の一覧は **`SettingsPane` が単一の情報源**(サイドバー・中身・タイトル・グループを
  `switch self` で網羅。`default:` を書かない)。8タブで `TabView` が限界になり、システム設定と
  同じ2ペインへ移した。前回の画面を `@AppStorage` で覚える。
- 行の作法(`SettingsControls.swift` 冒頭が正典): ラベルは項目名だけで意味が通る短い語句、
  補足は ⓘ のホバーの吹き出し(`help:`)へ、選択肢に説明を付けない(説明が要るなら選択肢名が悪い)。
  幅が足りなければ `ViewThatFits` で縦積み。ポップアップは自前の背景と境界線で「ドロップダウン
  だと分かる」ようにする(macOS 26 以降はシステムのベゼルが付くのでそちらに任せる)。
- **スライダーの目盛りは値の刻みと別に決める**(`TickMarkSlider`、2026-09-23、ユーザー報告)。
  SwiftUI の `Slider` は `step:` の数だけ目盛りを描くため、刻みの細かい設定では目盛りが潰れて
  1本の直線に見える(カラーパレットの RGB は 0〜255 を1刻みで動かすので256本あった)。
  目盛りに合わせて刻みを粗くするのは本末転倒 ―― 色は1だけずらしたいことがある。
  AppKit の `NSSlider` は本数を刻みと別に持てるが、**両端を含む等分**にしか置けないので、
  幅が丸くない範囲では間隔が半端な数になる(0〜255 なら15刻み、0.5〜30秒なら1.475秒刻み。
  「数字として半端で目盛りらしくない」と再度の指摘を受けた)。そこで `TickMarkSliderView` が
  `numberOfTickMarks` を使わず**目盛りだけ自前で描く**。
  - 間隔は **1・2・5 の10の冪倍**(2.5系は入れない)のうち、**刻みの整数倍**で本数が21本以下に
    なる最小のもの。刻みが丸い数と噛み合わないとき(32MB刻みなど)だけ刻みの2の冪倍へ落とす。
  - 目盛りは範囲の端ではなく**その倍数の値の上**に置く(0〜255 なら 0,20,…240、0.5〜30秒なら
    2,4,…30、0.5〜5行なら 0.5,1,…5)。端に目盛りが来なくてよい ―― 両端の数値は
    `SettingsSlider` が左右に文字で出している。物差しと同じ考え方。
  - 位置と見た目は純正の目盛りを実測して合わせてある(つまみの中心の可動域を等分した位置、
    直径2ptの丸、バー下端から3pt下、`tertiaryLabelColor`、つまみの下に潜る分は描かない)。
    純正13本と自前13本を同じ条件で描かせ、画素の位置と色で突き合わせて確かめた
    (→ [12](12-verification-and-debugging.md))。
  - `SettingsSlider` の `sliderStep` は**ドラッグで止まれる刻み**だけの話になった(目盛りの本数は
    もう決めない)。細かすぎてドラッグで狙えない設定にだけ渡し、細かい調整はステッパーへ任せる。
- **ポップアップは macOS 27 SDK で組むこと**(2026-09-16、利用者からの報告)。macOS 27.0 で
  「設定のプルダウンが、選び直しても**先頭の選択肢**を表示したまま変わらない」という不具合が出た
  (設定そのものは変わっていて、背景色なら実際の背景は変わる。`SettingsPicker` の行だけで、
  ラベルの `Text` が1つしかない `SettingsPickerRow`(「選択…」)は正常 ―― 報告者が実測)。
  原因はアプリではなく OS 側で、macOS 27 のリリースノートに
  "Bordered `Menu` and `Picker` buttons now support better label customization and no longer use
  `NSPopUpButton` in their implementation." とある。**macOS 26 SDK で組んだアプリが macOS 27 で
  走るときの旧経路**だけが壊れており、Xcode 27(macOS 27 SDK)で組み直すと直る(報告者が実測)。
  手元の macOS は 26 で、26 では 26 SDK でも 27 SDK でも再現しない(最小の再現アプリと実アプリの
  両方で確認)。
  - **なぜ先頭の選択肢が出るのか**。この部品のラベルは、当時、いちばん長い選択肢の幅を確保するために
    **全選択肢の非表示 `Text` を `ZStack` で重ねて**おり、その先頭は先頭の選択肢の `Text` だった。
    旧経路はラベルのビューをそのまま描かず、先頭の `Text` を題として抜き出すため、常にそれが出る
    (SwiftUI がメニューの `Text` を題・副題へ写す既知の平坦化規則と同じ形。`.hidden()` は抜き出しでは
    失われる)。ラベルの `Text` が1つだけの `SettingsPickerRow` が正常なのはこれで説明が付く。
    Apple がリリースノートで "better label customization" と書いているのも、旧経路のラベルが
    文字列の抜き出し止まりだったことの傍証。この症状自体の公開された報告は無く、Apple の既知問題にも
    載っていない(調べた範囲では未報告の回帰)。
  - **直し方は2つ入れてある**。①配布するビルドを Xcode 27(macOS 27 SDK)で作る(→ [02](02-project-and-build.md#ビルド))。
    ②`SettingsPicker` のラベルを **`Text` 1つだけ**にし、幅の確保は `Menu` の**外**(背景に置いた
    見えない測定用のビュー)へ移した。②は組む SDK に依らないので、この手の「ラベルから文字列を
    抜き出す」経路に今後振り回されない。**新しいポップアップを足すときも、ラベルに `Text` を
    2つ以上置かないこと。**
  - ついでに分かったこと: **幅の確保は macOS 26 では元々効いていない**(2026-09-16 実測)。`Menu` は
    ラベルに付けた幅指定を無視して中身の幅で描く ―― 最小の再現アプリで、いちばん長い選択肢が 133pt
    なのにボタンは 80pt(`.button`)/ 39pt(`.borderlessButton`)。実アプリの「背景色」も選択に応じて
    60〜120pt で動き、その値は上の変更の前後で同じだった。幅を本当に揃えたくなったら、ラベルではなく
    `SettingsPopUp`(`PopUpWidth`)に固定幅を渡す話になる。
  - **macOS 27 SDK + macOS 27 では逆に幅の確保が効き、短い選択肢が左へ寄った**(2026-09-18、利用者からの報告)。
    新しい経路はラベルのビューをそのまま描くので、ボタンがいちばん長い選択肢の幅になり、短い名前はその枠の
    左端に置かれてシェブロンとの間が大きく空く。システム設定のポップアップは選択中の名前の幅で伸び縮みして
    右端で揃うため、**幅の確保は macOS 15(自前で枠を描く経路)だけに限り**、26 以降は内容幅に任せた
    (`SettingsPicker.reservesWidestTitleWidth`)。26 では元々効いていなかったので、26 の見た目は変わらない。
  → [02](02-project-and-build.md#ci)(CI の macOS 27 ジョブ)
- 先頭グループ(見出しなし)は「一般」「外観」「ファイルブラウザ」の 3 つ(2026-09-13 に 3 つ目を追加。無彩色の
  濃い灰)。「ファイルブラウザ」には、その段階で効く行だけを置く(→ [15](15-file-browser.md#保存するもの))。
- 「外観」と「レイアウト」は2階層(面ごと/形式ごとの子ページ)。子ページは次回に持ち越さない。
  面の子ページには「背景」の下に**その面だけの設定**が続く(ページ一覧パネルのサムネイル、プログレス
  バーのサムネイル、ホームの「ライブラリ」「コレクション」)。1つのパネルの見た目に効く設定は
  必ず同じページに揃える。
  タイトルバーの「戻る」は全画面共通で `SettingsNavigator` が状態を持つ。右クリックの「調整…」は
  `SettingsNavigator.appearanceTarget` に行き先を置いてから `openSettings`。
- `Settings` シーンのウインドウはリサイズ不可で作られ、SwiftUI から変えられないため
  `SettingsWindowResizabilityAccessor` が `.resizable` を足す(内部識別子でウインドウを探さない)。
- 「初期設定に戻す」の範囲は画面に見えている項目だけ、データが消える設定は除く
  (→ [06](06-persistence.md#apppreferences))。
- 説明文の日本語は文ごとに改行(→ [02](02-project-and-build.md#ローカライズ))。

## その他の小さな約束

- カーソルの push/pop は `hoverCursor(_:)` で対にする(ビューが消えると pop されず矢印が戻らなかった)。
- **`Image` に渡す `CGImage` は body のたびに作り直さない。** `CGImage.cropping(to:)` は画素を
  コピーしない代わりに毎回**別のオブジェクト**を返すので、body の中で切ると SwiftUI からは中身が
  すり替わったように見え、描き直しになる。ウインドウ全体に `.animation(_:value:)` が掛かっている
  場面(サイドパネルのホバー表示)では、その差し替えがアニメーションの対象になって**画面中の画像が
  一斉にクロスフェードする** ―― 「ウインドウ全体が軽く明滅する」というユーザー報告 2026-09-10 の
  正体だった。切り分けた結果は控えて同じオブジェクトを返す
  (`CollectionTile.SliceCache` → [14](14-library-collections.md))。
- 「情報を見る」はサブメニューではなくオーバーレイパネル(値の先頭を揃えたい。`.popover` は
  ウインドウの外へはみ出した)。
- 境界での「毎回確認」は自前のシート(`.confirmationDialog` はボタン3つまで)。
- お気に入り一覧のツールバー版は `NSMenu` を直接組み立てる(`FavoritesNSMenuBridge`。SwiftUI の
  `Menu` はコードから開けない)。メニューバー版は SwiftUI の `Menu` のネスト。
- 外観(ライト/ダーク)は `NSApp.appearance`(`.preferredColorScheme` は AppKit のダイアログや
  Dock メニューに届かない)。「コントラストを上げる」に追従する。
- **ノーマルウインドウとシークレットウインドウで別の外観**(2026-09-22、ユーザー要望)。外観タブの設定は**全部**
  `AppearanceSettings`(`AppPreferences` から切り出した)にあり、ノーマル用(`preferences.appearance`、従来のキー)と
  シークレット用(`preferences.privateAppearance`、キーの末尾に `.privateWindow`)の 2 揃いが同時に生きている。
  「シークレットウインドウに固有の外観を適用」(`privateWindowsUseOwnAppearance`、既定 OFF、どの「初期設定に戻す」でも戻さない)が
  OFF ならシークレットもノーマルの揃い。初めて ON にしたときだけシークレットの揃いをノーマルの写しから始め、OFF にしても消さない。
  - 読む側は `@EnvironmentObject var appearance: AppearanceSettings` だけを見る。どのシーンにもノーマルの揃いを渡し
    (`QooViewerApp` の `.environmentObject(preferences.appearance)`)、本のウインドウだけ `ContentView.body` がそのウインドウの揃い
    (`preferences.appearance(forPrivateWindow:)`)で上書きする。環境設定・補助ウインドウ・メニューバーはノーマルのまま(ユーザーの決定)。
  - シークレットの揃いのライト/ダークは、そのウインドウに `.preferredColorScheme` で掛ける(`WindowAppearance`)。
    `NSWindow.appearance` を AppKit で入れても、SwiftUI が更新のたびに(`AppKitWindowController.hostingView(_:willUpdate:)`)nil へ
    書き戻す(KVO で実測)。揃いが「システムに従う」でアプリ全体が決め打ちのときは、`AppleInterfaceStyle` と分散通知
    `AppleInterfaceThemeChangedNotification` でシステムの外観を引く(`SystemAppearanceObserver`)。ColorScheme では高コントラスト版を
    指定できないので、その揃いを明示指定にしたシークレットウインドウは「コントラストを上げる」に追従しない。原寸表示のウインドウは
    元のウインドウの `appearance` を継ぐ。
  - 環境設定「外観」は、スイッチが ON の間だけ「編集する外観」(`SettingsNavigator.editingAppearanceProfile`、外観の画面を離れると
    ノーマルへ戻る)で編集する揃いを選び、子ページも含めて全部がその揃いを編集する。「初期設定に戻す」は編集中の揃いだけを戻す
    (`AppearanceSettings.resetToDefaults()`。`AppPreferences.keys(for: .appearance)` は空)。
- **シークレットウインドウの目印**(環境設定「外観」→「ウインドウ」、`AppPreferences.privateWindowTitlePrefix`。2026-09-22、ユーザー要望)は
  シークレットウインドウのタイトルの先頭の文字。nil = 既定の「(シークレット)」(表示言語に従う。カタログの `"(Private) %@"`)、
  空 = 何も付けない(タイトルバーの色で見分けられるようになったため)、それ以外はそのまま(絵文字も可。欄の右のボタンは
  欄へ焦点を移してから文字ビューアを開く)。外観の揃いではなくアプリ全体で1つで、「初期設定に戻す」では戻さず行の矢印で既定へ戻す。
  矢印は出し入れせず透明にして場所を取っておく ―― 出し入れで行の幅が変わると `SettingRow` の `ViewThatFits` が段組みを切り替えて
  欄を作り直し、1文字目で焦点が外れた(実機で確認)。
- **タイトルバーの色**(環境設定「外観」→「アプリ全体」、`AppearanceSettings.titleBarColor`。nil = 標準。2026-09-22)は本のウインドウ
  (ContentView)だけに効く。塗り方は `WindowTitleBarColor`: タイトルバーを透明にして `NSWindow.backgroundColor` を見せる。
  透明にするのは SwiftUI の `.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)` ―― AppKit で `titlebarAppearsTransparent`
  を立てても、SwiftUI が更新のたびに(`BarAppearanceBridge.updateWindowToolbar`)false へ書き戻す(KVO で呼び出し元まで実測)。
  地の色は内容が塗っていない場所(すりガラス無しのホーム)にも透けるので、色を指定している間は内容の最下層に
  `windowBackgroundColor` を敷く。`.fullSizeContentView` を外してある(ツールバーを隠したときの不具合対策。ContentView の WindowAccessor のコメント)ので、SwiftUI の中身で
  タイトルバーの下を塗る方法は採れない。タブバーの帯も同じ色になる。文字の色は外観モードに従い、公開 API では変えられない。
- トースト(`showToast`)、拡大率表示、「情報を見る」は面 `overlays` に属する。
