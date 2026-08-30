import SwiftUI
import AppKit
import SwiftData
import CoreGraphics
import Combine
import UniformTypeIdentifiers

struct ViewerView: View {
    @StateObject private var viewModel: ViewerViewModel
    @ObservedObject private var preferences: AppPreferences
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var keyBindingStore: KeyBindingStore
    /// お気に入りに追加/削除トグルボタン(ツールバー・コンテキストメニュー・「Favorites List」
    /// サブメニュー)のために、appState.favoritesStore(weak var)ではなくこちらを直接使う。
    /// weak varはAppState自身の@Publishedではないため、favoritesStoreの変更(reload())が
    /// あってもAppState.objectWillChangeは発火せず、appState.favoritesStore経由で読んだ値は
    /// 画面に反映されない。EnvironmentObjectとして直接持てば、reload()のたびにこのビュー自身が
    /// 再描画されるため、トグルボタンの見た目・文言を確実に最新の状態に保てる。
    @EnvironmentObject private var favoritesStore: FavoritesStore
    /// 「ブックマークの編集」ウインドウ・「お気に入りの整理」ウインドウの「現在の本を追加」から
    /// 「今読んでいる本」を特定するために、このウインドウがキーウインドウになったことを
    /// 通知する(setUpWindowObservers参照)。
    @EnvironmentObject private var launchCoordinator: LaunchCoordinator
    /// 右クリックの「本の書き出し」(exportOpenBook参照)が使う3つのストア。
    /// initで受け取っているlayoutStore/metadataStoreと同じインスタンスだが、あちらは
    /// ViewerViewModelを組み立てるためだけに素通ししていて、このビュー自身は保持していない。
    @EnvironmentObject private var bookmarkStore: BookmarkStore
    @EnvironmentObject private var layoutStore: LayoutStore
    @EnvironmentObject private var metadataStore: BookMetadataStore
    /// 書き出し後の後始末で、書き出した本を履歴から取り除くために使う
    /// (環境設定「レイアウト」の「履歴: 削除」)。
    @EnvironmentObject private var recentFilesStore: RecentFilesStore
    /// 同じく後始末で、書き出した本の読書位置以外の保存データを消すために使う。
    /// 読書位置(BookReadingState)だけはViewerViewModelが行(readingState)を握っているため、
    /// ここからは触らずviewModel.discardReadingState()に任せる。
    @Environment(\.modelContext) private var modelContext
    @FocusState private var isFocused: Bool
    /// このViewerViewインスタンス自身を表す使い捨てのトークン。同じウインドウ内で本を
    /// 切り替えたとき(.id(book.id)により、このView自体が古い本のものから新しい本のものへ
    /// 作り直される)に、appState.performViewerAction等の後始末(onDisappear)が、
    /// 既に新しい本のonAppearが登録した内容を誤って上書き消去してしまわないようにするための
    /// 仕組み。詳細はAppState.activeViewerTokenのコメント参照。
    @State private var viewerToken = UUID()
    @State private var scrollMonitor: Any?
    /// 画面クリックでのページ送り(pageArea内の左右クリックゾーン)を有効にしてよいかどうか。
    /// ウェルカム画面の「最近開いたファイル」「最近お気に入りに追加したファイル」はシングル
    /// クリックで即座に本を開く仕様のため、普段の癖でダブルクリックしてしまうと、1回目の
    /// クリックで本が開いてこのViewerViewに切り替わった直後、2回目のクリックがちょうど
    /// (画面中央付近に配置されがちな)クリックゾーンへ入力されてしまい、開いた直後の本が
    /// 意図せず1ページ送られてしまう不具合があった。これを防ぐため、本を開いてから
    /// clickZoneArmDelay が経過するまではクリックゾーンへのヒットテスト自体を無効にし、
    /// 直前の画面でのクリックの「残り」を確実に読み捨てる(pageArea参照)。
    @State private var isClickZoneArmed = false
    /// スクロール送りが参照する、裏のNSScrollViewの入れ物(ScrollViewAccessor参照)。
    /// bodyからは読まないため、更新しても再描画は起きない。
    @State private var scrollGeometryBox = ScrollGeometryBox()
    /// ピンチ拡大に合わせてスクロール位置を合わせ直すための予約(PendingZoomAnchor参照)。
    @State private var pendingZoomAnchor: PendingZoomAnchor?
    /// ピンチ操作中に一時的に表示する拡大率(%)。nilなら非表示。
    @State private var zoomIndicatorPercent: Int?
    @State private var zoomIndicatorHideTask: Task<Void, Never>?
    /// 次にページを表示し始めるとき、読み終わり側の隅から始めるかどうか。
    /// scrollAndMovePreviousで前のページへ戻ったときだけtrueになる
    /// (cooViewerのsetStartFromEnd:YES相当)。
    @State private var pendingPageEntryAtEnd = false
    /// 今表示しているページについて、上のpendingPageEntryAtEndを解決した結果。
    /// 画像が届いたあとの2回目の位置合わせ(applyPageEntryScrollのコメント参照)でも
    /// 同じ隅を使うために保持する。
    @State private var pageEntryAtEnd = false
    /// 画像が実際に差し替わったあとの位置合わせを、既に済ませたページ番号。
    /// 同じページのまま画像だけが変わった場合(見開きの相方が後から読み込まれた等)に、
    /// 読者のスクロール位置を勝手に戻してしまわないための番人。
    @State private var lastPageEntryScrollIndex: Int?
    /// 上の無効化を解除するタイマー。onDisappearで確実にキャンセルするために保持する。
    @State private var clickZoneArmTask: Task<Void, Never>?
    /// 上記の無効化期間の長さ。ダブルクリックの2回目のクリックを確実に読み捨てられるよう、
    /// システムのダブルクリック判定間隔(NSEvent.doubleClickInterval、環境設定で変更可能)を
    /// そのまま使う。読者が本を開いてすぐにクリックでページ送りしたくなるほど短い時間ではないため、
    /// 通常の読書体験への影響は無い。
    private var clickZoneArmDelay: TimeInterval { NSEvent.doubleClickInterval }
    /// 直前にスクロールホイールでページ送りを実行した時刻。一部のマウス/ドライバが
    /// 1ノッチの回転を複数の細かいscrollWheelイベントに分けて送ってくることがあり、
    /// それによって1ノッチのつもりが2回ページ送りされてしまう現象を防ぐために使う
    /// (handleScroll参照)。
    @State private var lastWheelActionAt: Date?
    private let wheelActionCooldown: TimeInterval = 0.04
    /// 直前にトラックパッドのスワイプ(3本指/4本指設定の場合)でページ送りを実行した時刻
    /// (handleSwipe参照)。
    @State private var lastSwipeActionAt: Date?
    /// handleSwipe(3本指/4本指設定の場合の.swipeイベント)用の連続発火防止の間隔。
    /// 2本指設定の場合(handleTrackpadScrollGesture)はジェスチャー全体を1回だけ判定する
    /// 作りになっており、この定数は使わない(詳細はhandleSwipeのコメント参照)。
    private let swipeActionCooldown: TimeInterval = 0.3
    /// 現在進行中の2本指トラックパッド操作(.scrollWheelイベントのphaseで区切られる
    /// 一連のジェスチャー)における、縦横それぞれの動きの累計値
    /// (handleTrackpadScrollGesture参照)。
    @State private var trackpadGestureDeltaX: CGFloat = 0
    @State private var trackpadGestureDeltaY: CGFloat = 0
    @State private var isCursorHidden = false
    @State private var cursorHideTask: Task<Void, Never>?
    /// メニューバーのメニュー(このアプリのもの)が現在開いているかどうか。開いている間は
    /// カーソルが動かなくても自動的には隠さない(NSMenu.didBeginTracking/didEndTracking参照)。
    @State private var isMenuTracking = false
    @State private var showThumbnailGrid = false
    /// ページ一覧(サムネイルグリッド)パネル自身の、スクリーン座標系での現在のフレーム
    /// (PanelScreenFrameAccessor参照)。クリックがパネルの内側か外側かの判定に使う
    /// (installThumbnailGridDismissMonitorIfNeeded参照)。
    @State private var thumbnailPanelScreenFrame: CGRect = .zero
    /// ページ一覧パネルの上で始まったマウス操作の押し始めを覚えておく入れ物
    /// (dismissThumbnailGridIfGestureAssigned参照)。
    @State private var thumbnailGridGesturePressBox = ThumbnailGridGesturePressBox()
    /// ページ一覧パネルを閉じるクリックを拾うNSEventローカルモニタ
    /// (installThumbnailGridDismissMonitorIfNeeded参照)。
    @State private var thumbnailGridDismissMonitor: Any?
    /// ページ一覧パネルの上でのホイールスクロール量とピンチ(サムネイルの大きさ)を自前で
    /// 扱うNSEventローカルモニタ(ThumbnailGridView.makeGridEventMonitorが作る)。
    ///
    /// **取り付けるのはパネル側だが、預かるのはこちら。** ページ一覧を出したまま
    /// ウインドウごと閉じられると、パネルの`.onDisappear`は呼ばれないことがあり
    /// (このリポジトリで確認済みの挙動)、パネル側だけで持つとモニタが残ってしまう。
    /// ここに置けば、上のthumbnailGridDismissMonitorと同じく`handleOnDisappear`からも
    /// 確実に外せる。
    @State private var thumbnailGridEventMonitor: Any?
    /// 「お気に入りに追加」シート(登録先フォルダを選ぶ。FavoriteFolderPickerView)の表示状態。
    @State private var showFavoriteFolderPicker = false
    /// 右クリックの「本の書き出し」で進行中の書き出し(OpenBookExportSheetの表示状態を兼ねる)。
    /// nilなら何も出ていない。
    @State private var openBookExport: OpenBookExportRequest?
    /// 環境設定「レイアウト」の「書き出したあとの動作」が「毎回確認」のときに、書き出しを
    /// 終えた直後に出すシートの表示状態(「最後のページで」の毎回確認とまったく同じ作りで、
    /// 選択肢の正典もBookExportCompletionBehavior 1つに揃えてある)。
    @State private var isShowingExportCompletionPrompt = false
    /// 「お気に入り一覧」を表示中のネイティブNSMenuブリッジ(FavoritesNSMenuBridge)。
    /// ツールバーのボタンのクリック・ショートカット(showFavoritesList)のどちらからも
    /// showFavoritesListMenu()を呼び出す形に統一している。popUp自体は同期呼び出しで
    /// 閉じるまでブロックされるため、厳密には@Stateに保持しなくても呼び出し元のローカル変数の
    /// 生存期間だけで足りるはずだが、念のためこのビューの寿命に紐づけて保持している。
    @State private var favoritesMenuBridge: FavoritesNSMenuBridge?
    /// 「新しいウインドウで開く」「新しいタブで開く」(openFavorite(_:to:) → BookWindowOpener)
    /// で、指定したURLを持つ新しいウインドウをSwiftUIに作らせるための仕組み。
    @Environment(\.openWindow) private var openWindow
    /// このビューを表示しているウインドウ本体。フルスクリーンの入退場通知の登録・解除や、
    /// マウス位置と画面端との距離判定に使う。
    ///
    /// 予防: 以前は`@State private var hostWindow: NSWindow?`と、NSWindowを強参照で持って
    /// いた。SwiftUIがこのView自身の状態をいつ解放するかは保証されていない(このファイル・
    /// ContentView.swiftの各所に、その前提で書いたコードが原因の不具合の記録がある)ため、
    /// 強参照のままだと閉じたウインドウとそのビュー階層ごと掴み続けてしまう危険がある。
    /// AppState.hostWindowが最初からweakなのと同じ理由で、weakな箱に入れて保持する。
    @State private var hostWindowBox = WeakWindowBox()
    private var hostWindow: NSWindow? { hostWindowBox.window }
    /// 現在フルスクリーン表示中かどうか。
    @State private var isFullScreen = false
    /// 自動隠し中のツールバーを、マウスが画面端に近いために一時的に表示しているかどうか。
    /// フルスクリーン中、またはウインドウ表示でもhideToolbarがONのときに使われる
    /// (自動隠しが有効でないときは常にtrue相当として扱う。bodyの表示条件参照)。
    @State private var isToolbarAutoRevealed = true
    /// プログレスバー側の同じもの。以前はツールバーと1つの@Stateを共有していたが、
    /// 「端に近づけてから表示されるまでの時間」を部分ごとに設定できるようにした
    /// (ユーザー要望)ため、別々に持つ必要が出た。**表示のきっかけは今も共通**
    /// (上端・下端どちらの帯に入っても両方が対象。updateAutoHiddenChromeVisibility参照)で、
    /// 違うのは「何秒待ってから表示するか」だけ。
    @State private var isProgressBarAutoRevealed = true
    /// 上の2つを「表示までの時間」(環境設定)ぶん待ってから表示するための、待機中のタスク。
    /// 待っている間にカーソルが帯から出たらキャンセルする(scheduleToolbarReveal参照)。
    /// 遅延が0(既定)のときは使わず、その場で表示する。
    @State private var toolbarRevealTask: Task<Void, Never>?
    @State private var progressBarRevealTask: Task<Void, Never>?
    /// 自動隠し中のツールバーの「下端」の位置(NSEvent.locationInWindowと同じ、ウインドウ座標系での
    /// Y座標)。updateAutoHiddenChromeVisibilityでのマウス位置判定に使う。
    /// 以前は「window.contentView.frame.heightからツールバーの高さを引く」形で上端の位置を
    /// 逆算していたが、タイトルバーの実装の都合でこのcontentHeightが実際のツールバーの表示位置と
    /// 微妙にズレることがあり、ツールバーの上のほう(ボタンの上端付近)にカーソルがあるうちは
    /// 表示されるのに、少し下(ボタンの下半分など)に動かすと反応領域から外れて隠れてしまう
    /// 不具合があった。WindowYPositionAccessor(下記)を使ってAppKit自身に「このビュー(=実際に
    /// 表示されているツールバーの下端)はウインドウ座標系のどこにあるか」を直接教えてもらう形に
    /// することで、タイトルバー・タブバーの実装詳細によらず正確な位置を得られるようにしている。
    @State private var toolbarBottomYInWindow: CGFloat = 0
    /// プログレスバー(ProgressBarView)の実際の描画済みの高さ。自動隠し中に
    /// マウスを下端へ近づけたときの「反応する領域」の判定(updateAutoHiddenChromeVisibility)に、
    /// 固定値ではなくこの実測値を使う。
    @State private var progressBarHeight: CGFloat = 60
    /// NSWindow.didEnterFullScreenNotification / didExitFullScreenNotification /
    /// didResignKeyNotification のオブザーバートークン。onDisappearで確実に解除するために保持する。
    @State private var windowObservers: [NSObjectProtocol] = []
    /// Fileメニューの「閉じる」(Cmd+W)を「本を閉じる」動作に変更するためのウインドウデリゲート。
    /// NSWindow.delegateは弱参照のため、ここで強参照を保持しておかないと解放されてしまう。
    @State private var bookClosingDelegate: BookClosingWindowDelegate?
    /// お気に入り・ブックマークの追加/削除トグルボタンを操作したときに、画面中央下部へ
    /// 一時的に表示するフィードバック文言(例:「“Xxx”をお気に入りに追加しました」)。
    /// nilのときは非表示。showToast(_:)参照。
    @State private var toastMessage: String?
    /// toastMessageを一定時間後に自動的に消すためのタスク。表示中に別の操作でトーストが
    /// 出し直された場合、古いタイマーが先に発火して消してしまわないようキャンセルしてから
    /// 新しいタスクを積み直す。
    @State private var toastDismissTask: Task<Void, Never>?
    /// レイアウト操作(3.2節)で状態を選んだ後、伝播範囲(3.3節)を確認するダイアログ用の
    /// 保留中の操作。nilなら非表示。「レイアウト情報を削除する」は伝播範囲ダイアログを
    /// 挟まない(3.3節)ため、この仕組みは使わず直接viewModel.clearPageLayoutを呼ぶ。
    @State private var pendingLayoutStateChange: PendingLayoutStateChange?

    /// pendingLayoutStateChangeの中身。ページ番号と、これから設定しようとしている状態の組。
    private struct PendingLayoutStateChange: Identifiable {
        let id = UUID()
        let pageIndex: Int
        let state: PageLayoutState
    }

    /// 「現在の表示を基準に自動でレイアウトする」(3.1節)は、本全体を上書きする操作のため、
    /// 実行前に必ず確認ダイアログを挟む(設計コンセプト3.1節)。ツールバー・コンテキストメニュー・
    /// メニューバーの3経路すべてがこのフラグを立てるだけにし、実際の実行(viewModel呼び出し)は
    /// ここ1箇所(.alertのボタン)にまとめている。
    @State private var isShowingAutoLayoutConfirmation = false

    /// 見開き表示中、ツールバー/お気に入りメニュー/キーボードショートカットからブックマークを
    /// 追加しようとした際、環境設定(preferences.spreadBookmarkTargetBehavior == .askEachTime)に
    /// より左右どちらのページを対象にするか尋ねる確認ダイアログの表示状態。コンテキストメニュー
    /// (右クリック)からの追加はクリック位置で一意に決まるため、この仕組みは使わない
    /// (toggleCurrentPageBookmark/contextMenuContent参照)。
    @State private var isShowingBookmarkSideDialog = false

    /// コンテキストメニュー「情報を見る」(ユーザー要望)の、ビューアウインドウ内オーバーレイ
    /// パネル(mainZStack内、ThumbnailGridBackdropView + PageInfoPanelView)の表示状態。
    /// 対象ページはisLastContextClickOnLeftHalfから毎回infoContextPageIndexで再計算するため、
    /// ここでは表示中かどうかだけを持てば十分(PageInfoPanelView参照)。
    @State private var isShowingPageInfoPanel = false

    /// 画像のエクスポート機能(要望)。エクスポート中に画像の読み込み・結合・書き込みのいずれかで
    /// 失敗した場合のエラーメッセージ。nilなら非表示(applyLayoutAlerts参照)。
    @State private var imageExportErrorMessage: String?
    /// 「このページをエクスポート」の保存パネルを、いま出そうとしている最中かどうか。
    /// 同じパネルが入れ子で開くのを防ぐためだけの目印(exportImage(_:)参照)。
    @State private var isExportingSinglePage = false

    /// pageArea(見開き/単ページの画像表示領域)の、ウインドウ座標系(NSEvent.locationInWindowと
    /// 同じ基準)でのフレーム。PageAreaFrameAccessorが自動的に最新の値を報告してくる
    /// (詳細はPageAreaFrameAccessor/PageAreaFrameReportingViewのコメント参照)。
    /// コンテキストメニューを右クリックした位置が、見開きの左側・右側どちらのページの上か
    /// (設計コンセプト8.4節)を判定するために使う。
    @State private var pageAreaFrameInWindow: CGRect = .zero
    /// 直近のコンテキストメニュー起動クリック(右クリック、またはControl+左クリック)が、
    /// pageAreaの左半分・右半分のどちらで起きたか。見開き表示中でない(パートナーページが
    /// 無い)場合は参照されない。既定でtrueにしているのは、見開き表示前(まだ一度も
    /// 右クリックしていない)の状態でも常に何らかの値を持たせておくため実用上の影響は無い
    /// (partnerPageIndexがnilのときはこの値を使わないLayoutサブメニューの分岐になるため)。
    @State private var isLastContextClickOnLeftHalf = true
    /// コンテキストメニュー起動クリックの検知(rightMouseDown/Control+leftMouseDown)用の
    /// ローカルイベントモニタ。scrollMonitorとは別に持つ理由は無いが、責務ごとに変数を
    /// 分けたほうが見通しが良いため独立させている。onDisappearで確実に解除する。
    @State private var contextClickMonitor: Any?

    /// - Parameter skipsPersistence: この本についてDBへ一切書かないかどうか
    ///   (シークレットウインドウ、またはその場限りの本。詳細はViewerViewModel.skipsPersistence参照)。
    ///   呼び出し側(ContentView)が`isPrivateWindow || book.isTransient`をORして渡す。
    ///   ViewerViewModelの生成時に確定させる必要があるため、EnvironmentObjectのappStateではなく
    ///   initの引数で受け取る(initの時点ではEnvironmentObjectはまだ読めない)。
    /// - Parameter initialPageID: 開いた直後に表示したいページ(ViewerViewModel.init参照)。
    ///   StateObjectの生成時にしか渡せないため、skipsPersistenceと同じくinitで受け取る。
    /// - Parameter initialEdge: 開いた直後に着地させたい端(ViewerViewModel.init参照)。
    ///   initialPageIDと同じ理由でinitで受け取る。
    init(
        book: MangaBook, modelContext: ModelContext, preferences: AppPreferences,
        layoutStore: LayoutStore, metadataStore: BookMetadataStore, skipsPersistence: Bool = false,
        initialPageID: String? = nil, initialEdge: InitialPageEdge? = nil
    ) {
        _viewModel = StateObject(
            wrappedValue: ViewerViewModel(
                book: book, modelContext: modelContext, preferences: preferences,
                layoutStore: layoutStore, metadataStore: metadataStore,
                skipsPersistence: skipsPersistence, initialPageID: initialPageID,
                initialEdge: initialEdge
            )
        )
        _preferences = ObservedObject(wrappedValue: preferences)
    }

    /// .onAppear{}の中身をprivateメソッドへ切り出したもの(bodyのコメント参照。型チェックが
    /// 長くかかりすぎる不具合対策)。処理内容自体は以前と同じ(橋渡し処理の登録・
    /// 各種ローカルモニタの起動)。
    private func handleOnAppear() {
        isFocused = true
        // クリックでのページ送りは、ウェルカム画面からのダブルクリックの2回目のクリックを
        // 読み捨てるため、一定時間経ってから有効にする(詳細はisClickZoneArmedのコメント参照)。
        isClickZoneArmed = false
        clickZoneArmTask?.cancel()
        clickZoneArmTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(clickZoneArmDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            isClickZoneArmed = true
        }
        // 以下でappStateへ書き込むより前に、まず自分自身のトークンを登録する
        // (AppState.activeViewerTokenのコメント参照。同じウインドウ内で本を切り替えた際、
        // 古いViewerViewのonDisappearが今から行う登録を誤って後始末してしまわないため)。
        appState.activeViewerToken = viewerToken
        // バグ修正: 以前は`{ forward in ... }`とだけ書いていた。ViewerViewはstructのため、
        // クロージャの中でappState/viewModelに触れると「このViewer View自身のコピー」が丸ごと
        // キャプチャされる。そのコピーは@StateObjectのviewModel(同じViewerViewModelを強参照
        // する箱)を含むため、
        //   ViewerViewModel → onPageBoundaryRequest → ViewerViewのコピー → ViewerViewModel
        // という循環参照になり、しかもこの代入はどこでもnilに戻していなかったため、
        // ViewerViewModelが永久に解放されなくなっていた。巻き添えでPageLoader(actor。
        // 画像キャッシュ・開いたままの書庫ハンドル)、ViewerViewModelのdeinitで解除するはずの
        // 通知購読(bookmarksDidChange/layoutDataDidChange)、weak selfで止まる前提の
        // warmUpWideImageCacheForEntireBookまで、本を1冊開くごとに積み上がっていた。
        //
        // キャプチャリストで必要な2つだけを、どちらもweakで捕まえることで循環を断つ
        // (合わせてhandleOnDisappearでnilへ戻す。二重の対策)。appStateもweakにしているのは、
        // appState側の橋渡しクロージャがこのViewerViewのコピー(=viewModel)をキャプチャして
        // いるため、こちらがappStateを強参照すると
        //   ViewerViewModel → このクロージャ → AppState → 橋渡し → ViewerViewのコピー → ViewerViewModel
        // という遠回りの循環が、両者の後始末が済むまでの間だけとはいえ成立してしまうため。
        // どちらも既に解放されているなら、そもそも次の本を開く先が無いので何もしなくてよい。
        viewModel.onPageBoundaryRequest = { [weak appState = self.appState, weak viewModel = self.viewModel] request in
            guard let appState, let viewModel else { return }
            switch request {
            case .openSiblingBook(let forward, let landsOnEdge):
                if forward {
                    appState.openSibling(after: viewModel.book.sourceURL, landsOnFirstPage: landsOnEdge)
                } else {
                    appState.openSibling(before: viewModel.book.sourceURL, landsOnLastPage: landsOnEdge)
                }
            case .closeBook:
                // 「本を閉じる」はViewerAction.closeTabと同じ経路(タブが1枚ならウインドウごと)。
                // 実体はperform(_:)にあり、ホストウインドウ(@State)を実行時に読む必要があるため、
                // ここで直接呼ばずappStateに登録済みの橋渡しを経由する ―― このクロージャが
                // ViewerView自身を強くキャプチャしてしまうのを避けるため(上のコメント参照)。
                appState.performViewerAction?(.closeTab)
            case .returnToWelcome:
                // 本だけ閉じて、同じウインドウにウェルカム画面を出す。読書位置の保留分は
                // ViewerViewが消えるときのonDisappearでも確定するが、こちらが先に走る保証は
                // 無いのでここでも確定させておく(flushPendingSaveは二度呼んでも害が無い)。
                viewModel.flushPendingSave()
                appState.closeBook()
            }
        }
        appState.performViewerAction = { action in
            perform(action)
        }
        // メニューバーの「ブックマーク」メニュー下部に、現在の本のブックマーク一覧を
        // 表示するための橋渡し(詳細はAppState.swiftのコメント参照)。
        appState.jumpToBookmark = { bookmark in
            viewModel.jump(to: bookmark)
        }
        // サイドパネルのリソースモニタへ、この本のキャッシュの状態を渡す橋渡し
        // (AppState.fetchResourceSnapshotのコメント参照)。onPageBoundaryRequestと同じ理由で
        // weakにする(ViewerViewのコピーごとviewModelを強くキャプチャしない)。
        appState.fetchResourceSnapshot = { [weak viewModel = self.viewModel] in
            await viewModel?.resourceSnapshot()
        }
        // 「ブックマーク・レイアウトの編集」ウインドウ(4節)の右ペインで、ブックマークの
        // 無いページのサムネイルをダブルクリックした場合の橋渡し(AppState.swiftの
        // jumpToPageIndexのコメント参照)。
        appState.jumpToPageIndex = { pageIndex in
            viewModel.jump(toPageIndex: pageIndex)
        }
        // 「ブックマークの編集」ウインドウ(独立ウインドウ)の「Add This Page」ボタンから、
        // 現在のページを追加するための橋渡し(jumpToBookmarkと同じ理由。削除・リネームは
        // BookmarkStoreが直接SwiftDataを操作するため、ここでは扱わない。
        // AppState.swiftのコメント参照)。
        appState.addBookmarkAction = {
            viewModel.addBookmark()
        }
        // ページ一覧パネル・サイドパネルのサムネイル右クリックから、そのページ1枚を対象に
        // ブックマークを追加/削除するための橋渡し(AppState.toggleBookmarkAtIndex参照)。
        appState.toggleBookmarkAtIndex = { index in
            toggleBookmark(atIndex: index)
        }
        // サイドパネル(ブックマークモード)の「お気に入りに追加」ボタン・お気に入りツリーの
        // 橋渡し(AppState.addFavoriteAction/openFavoriteActionのコメント参照)。登録先フォルダの
        // 選択シート・「お気に入りを開くとき」の判定はどちらもこのViewerViewが持っているため、
        // サイドパネル側からはこのクロージャ経由で呼んでもらう。
        appState.addFavoriteAction = {
            showFavoriteFolderPicker = true
        }
        appState.openFavoriteAction = { favorite in
            openFavoriteAccordingToPreference(favorite)
        }
        // カーソルがウインドウの外へ出たときに、自動表示中のツールバー/プログレスバーを
        // 即座に隠すための橋渡し(AppState.hideAutoRevealedChromeのコメント参照)。
        // 拡大鏡ON時の強制非表示(下の.onChange(of: viewModel.isLoupeActive))と同じ処理内容。
        // 表示待ちのタスクの取り消しも含めて、後始末はhideAutoRevealedChromeNow()に集約して
        // ある(カーソルがウインドウの外へ出たあとに待ち時間が明けて表示されてしまう、という
        // 取り違えを防ぐため)。
        appState.hideAutoRevealedChrome = {
            hideAutoRevealedChromeNow()
        }
        // サイドパネル(ページモード)のサムネイル取得の橋渡し
        // (AppState.loadPageThumbnailのコメント参照)。ページ一覧グリッド
        // (ThumbnailGridView)と同じ、進捗バー用の軽量サムネイルキャッシュを共有する。
        // ホバー時の拡大プレビュー用の画像(pageImageLoader)も同時に登録する
        // (AppState.loadPageImageのコメント参照)。
        appState.updateLoadPageThumbnail({ index in
            await viewModel.loadThumbnail(at: index)
        }, pageImageLoader: { index in
            await viewModel.loadPreviewImage(at: index)
        })
        appState.updateCurrentBookmarks(viewModel.bookmarks)
        appState.updateCurrentPageIndex(viewModel.currentIndex)
        appState.updateCurrentBookPages(viewModel.book.pages)
        appState.updateCurrentVisiblePageSortKeys(currentVisiblePageSortKeys)
        // メニューバーの「表示モード切替」サブメニューから、特定のモードへ直接切り替える
        // ための橋渡し。
        appState.setScalingMode = { mode in
            viewModel.setScalingMode(mode)
        }
        // メニューバー「Edit」のレイアウトのグループ(8.2節)からの操作の橋渡し。詳細は
        // AppState.swiftのperformLayoutStateChange/performLayoutClear/performAutoLayoutのコメント参照。
        appState.performLayoutStateChange = { target, state in
            let pageIndex = target == .partner ? (partnerPageIndex ?? viewModel.currentIndex) : viewModel.currentIndex
            pendingLayoutStateChange = PendingLayoutStateChange(pageIndex: pageIndex, state: state)
        }
        appState.performLayoutClear = { target in
            let pageIndex = target == .partner ? (partnerPageIndex ?? viewModel.currentIndex) : viewModel.currentIndex
            viewModel.clearPageLayout(atIndex: pageIndex)
            syncMenuCheckmarkState()
        }
        appState.performAutoLayout = {
            isShowingAutoLayoutConfirmation = true
        }
        // 「同じフォルダの画像をすべて開く」の着地ページ指定は一度きり。ViewerViewModelの生成時に
        // 受け取り済みなので、ここで捨てて次に同じ本を開き直したときに再適用されないようにする
        // (AppState.pendingInitialPage参照)。
        appState.clearPendingInitialPage()

        // DBへ書かない本(シークレットウインドウ、またはその場限りの本)では、書き込みを伴う
        // 橋渡し(ブックマーク/お気に入りの追加・レイアウト変更)は登録しない。メニュー側は
        // MenuCheckmarkStateのisPrivateWindow/isTransientBookで
        // グレーアウトしているが、「ブックマーク・レイアウトの編集」ウインドウのように
        // activeBookAppState経由でこれらを呼ぶ経路もあるため、クロージャ自体を空けておく。
        if viewModel.skipsPersistence {
            appState.addBookmarkAction = nil
            appState.toggleBookmarkAtIndex = nil
            appState.addFavoriteAction = nil
            appState.performLayoutStateChange = nil
            appState.performLayoutClear = nil
            appState.performAutoLayout = nil
        }
        // 画像のエクスポート機能(要望)。メニューバーの「画像のエクスポート」サブメニューからの
        // 橋渡し(ImageExportKindのコメント参照)。
        appState.performImageExport = { kind in
            switch kind {
            case .currentPage:
                exportImage(.singlePage(index: viewModel.currentIndex))
            case .leftPage:
                exportImage(.singlePage(index: spreadLeftPageIndex))
            case .rightPage:
                exportImage(.singlePage(index: spreadRightPageIndex))
            case .mergedSpread:
                exportImage(.mergedSpread(leftIndex: spreadLeftPageIndex, rightIndex: spreadRightPageIndex))
            }
        }
        // サイドパネル・ページ一覧の右クリックからの「画像をエクスポート」(ユーザー要望)。
        // 対象がページ番号で一意に決まる経路(AppState.exportPageImageのコメント参照)。
        appState.exportPageImage = { index in
            exportImage(.singlePage(index: index))
        }
        // メニューバーの「スライドショー」「見開き」「右から左へ」「表示モード切替」の
        // 左に表示するチェックマーク、およびEPUBによるグレーアウト状態の、現在値の初期反映。
        syncMenuCheckmarkState()
        scrollMonitor = makeScrollMonitor()
        contextClickMonitor = makeContextClickMonitor()
    }

    /// スクロール/スワイプ/マウス移動/キー入力を監視するローカルモニタを作る
    /// (handleOnAppearのコメント参照。以前はonAppear内に直接書いていた)。
    private func makeScrollMonitor() -> Any? {
        NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .swipe, .magnify, .smartMagnify, .mouseMoved, .keyDown]
        ) { event in
            // NSEvent.addLocalMonitorForEventsは「このアプリのどのウインドウ宛てのイベントか」に
            // 関わらず、アプリ全体のイベントを受け取ってしまう。複数のウインドウ(タブ)を
            // 開けるようになったため、ここでイベント自身の宛先ウインドウ(event.window)が
            // 自分自身のウインドウ(hostWindow)と一致するときだけ処理するようにする。
            // これがないと、スクロール操作が他のqooViewerウインドウはもちろん、
            // 環境設定ウインドウやファイル選択パネルにまで影響してしまう
            // (キー入力も同様。ブックマーク名の変更などシート内のテキストフィールドは
            // 別のNSWindowとして表示されるため、event.windowがhostWindowと一致せず、
            // ここでの処理には影響しない)。
            guard let hostWindow, event.window === hostWindow else { return event }
            // マウス移動(.mouseMoved)は、カーソル自動非表示の解除・ツールバー/プログレスバーの
            // 自動表示のトリガーとして、サムネイル一覧表示中かどうかに関わらず常に処理する必要が
            // ある。下のshowThumbnailGridガードより後ろにあると、サムネイル一覧を開いている間
            // マウスを動かしてもregisterMouseActivity()が呼ばれず、カーソル自動非表示のタイマーが
            // 解除されない(ユーザー報告: サムネイル一覧上でカーソルが見えなくなる)。
            if event.type == .mouseMoved {
                registerMouseActivity()
                updateAutoHiddenChromeVisibility(forMouseLocationInWindow: event.locationInWindow)
                return event
            }
            // サムネイル一覧(ThumbnailGridView)を表示している間は、スクロール/スワイプによる
            // ページ送りやキーボードショートカットが背後の本へ影響しないようにする(以前は
            // 独立したシートとして表示していたため、シート自身が別ウインドウ扱いとなり
            // event.window（上のガード）が一致せず自動的に素通りしていた。同一ウインドウ内の
            // 重ね表示に変更したことに伴い、ここで明示的に無視する必要がある)。
            // サイドパネル(フォルダブラウザ + 本の中身ブラウザ、ContentView.swift側で管理)
            // 表示中も、サムネイル一覧と同じ理由で背後の本のページ送りへ影響しないようにする。
            // 例外: サムネイル一覧の表示中でも、「ページ一覧を表示/非表示」に割り当てられた
            // キーだけは通す。この操作はトグルなので、開いたときと同じキーでもう一度押したら
            // 閉じられる必要がある(ユーザー報告: tキーで開いたページ一覧がtキーで閉じられず、
            // パネルの外側をクリックするしかなかった)。
            // マウス側は、パネルを閉じるクリックを拾う専用のモニタ
            // (installThumbnailGridDismissMonitorIfNeeded)が閉じる役目を果たしている。
            if showThumbnailGrid, !appState.isSidePanelFloatingOverlay,
               event.type == .keyDown, !(hostWindow.firstResponder is NSTextView),
               let key = RemappableKey.from(nsEvent: event),
               keyBindingStore.resolvedAction(for: key, in: viewModel.scalingMode)
                   == .showThumbnailGrid
            {
                perform(.showThumbnailGrid)
                return nil
            }
            guard !showThumbnailGrid, !appState.isSidePanelFloatingOverlay else { return event }
            switch event.type {
            case .scrollWheel:
                // トラックパッド(またはMagic Mouseなど)由来のスクロールイベントには
                // phase/momentumPhase(.began/.changed/.ended/momentum中など)が付与される。
                // 通常の物理マウスホイールのノッチ操作では、これらは常に空(.phase == [])。
                //
                // 【調査で判明した重要な事実】「システム設定」>「トラックパッド」の
                // 「ページ間をスワイプ」が2本指設定の場合、その操作は専用のイベント種別
                // (NSEvent.swipe)としては届かず、通常の.scrollWheelイベントの並びとして
                // 届く(ログで確認済み。横方向にスワイプしていても、deltaXが大きい
                // .scrollWheelイベントが連続するだけで、.swipeイベントは一切発生しない)。
                // そのため、1個ずつの.scrollWheelイベントのdeltaYだけを見てページ送りする
                // 従来のhandleScrollのロジックのままでは、意図的な横方向スワイプの最中に
                // 生じるわずかな縦方向のぶれ(deltaY)にまで反応してしまい、1回のつもりの
                // スワイプで複数回・意図しないページ送りが発生する原因になっていた
                // (これが一連の不具合報告の実際の原因だった)。
                //
                // 「スワイプでページ送り」がONのときは、トラックパッド由来の
                // .scrollWheelイベントをhandleScrollには渡さず、代わりに
                // handleTrackpadScrollGestureへ渡す。そちらでは指が触れてから離れるまでの
                // 一連のイベント(1回のジェスチャー全体)をまとめて扱い、ジェスチャー全体で
                // 見て横方向優位だった場合にだけ、ジェスチャーの終わりに1回だけページ送りを
                // 行う。縦方向優位だった場合(2本指の縦スクロール)は何もしない
                // (完全に無視する)。物理マウスホイールでのページ送りはこれまでどおり
                // 影響を受けない。
                let isTrackpadOriginated = !event.phase.isEmpty || !event.momentumPhase.isEmpty
                // 環境設定「2本指スクロールを反転」(AppPreferences.invertTwoFingerScrolling)は、
                // phaseを伴うスクロール ― トラックパッドやMagic Mouseの、指でなぞる操作 ―
                // だけを対象にする。物理マウスホイールのノッチ(phaseが空)は対象外。
                let isInverted = preferences.invertTwoFingerScrolling && isTrackpadOriginated
                // ホイールの割り当てを引くための修飾キー。shiftを受け付けないのは、macOSが
                // ホイール由来のスクロールイベントについてshift押下時にdeltaXとdeltaYを
                // 入れ替えるため、向きの判定が信用できないから(MouseTrigger参照)。
                // nil(=control/command/shiftのいずれか)の場合、handleScrollは何もしない。
                let wheelModifiers = MouseTrigger.Modifiers.from(
                    event.modifierFlags, allowsShift: false
                )
                // ピンチ拡大中は、2本指の横方向の動きは「拡大した画像を横へ動かしたい」で
                // あってページ送りではない。ここを通すと、拡大して読んでいる最中に画像を
                // 横へずらしただけでページが送られ(そのうえ拡大も解除され)てしまう。
                // 3本指/4本指の.swipe(下のcase)は、スクロールと取り違えようのない
                // 明示的なページ送り操作なので、拡大中でもそのまま働かせる。
                if preferences.treatTrackpadFlickAsWheel && isTrackpadOriginated
                    && viewModel.pinchZoomFactor == 1 {
                    handleTrackpadScrollGesture(
                        phase: event.phase,
                        deltaX: event.scrollingDeltaX,
                        deltaY: event.scrollingDeltaY
                    )
                    // このぶんの素のスクロールは、通常はイベントをそのまま通して
                    // ScrollViewに任せる。反転が有効なときだけ肩代わりする
                    // (performInvertedScrollのコメント参照)。
                    if isInverted,
                       performInvertedScroll(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY) {
                        return nil
                    }
                    break
                }
                if isInverted, isPageAreaScrollable {
                    // 端でのページ送り判定(handleScroll)を先に済ませてから動かす。
                    // 判定は「このイベントを処理する**前**の位置」で行う必要があるため
                    // (handleScrollInScrollableModeのコメント参照)、順番を入れ替えられない。
                    if !handleScroll(
                        deltaY: event.scrollingDeltaY, isInverted: true, modifiers: wheelModifiers
                    ) {
                        performInvertedScroll(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
                    }
                    return nil
                }
                handleScroll(deltaY: event.scrollingDeltaY, modifiers: wheelModifiers)
            case .magnify:
                handleMagnify(event)
                // 標準の処理(SwiftUIのScrollViewは既定でmagnificationを受け付けないが、
                // 将来にわたって二重に処理されないことを保証するため)へは渡さない。
                return nil
            case .smartMagnify:
                handleSmartMagnify(event)
                return nil
            case .swipe:
                // 「ページ間をスワイプ」が3本指/4本指設定の場合は、こちらの専用イベントで
                // 届く(2本指設定の場合の扱いは上のhandleTrackpadScrollGesture参照)。
                handleSwipe(deltaX: event.deltaX)
            case .keyDown:
                // サイドパネルの絞り込み検索欄など、このウインドウ内のテキストフィールドを
                // 編集している間は、キー入力をページ送り等のショートカットとして横取りしない
                // (横取りすると「a」と打っただけでブックマークが追加される、といった挙動に
                // なってしまう)。AppKitではテキストフィールドの編集中、実際のファースト
                // レスポンダはフィールド自身ではなくウインドウ共有の「フィールドエディタ」
                // (NSTextView)になるため、それを見て判定する。ブックマーク名の変更シートなどが
                // 別ウインドウとして開く場合は、上のevent.window === hostWindowのガードで
                // 既に除外されている(ここで拾うのは同じウインドウ内の入力欄)。
                if hostWindow.firstResponder is NSTextView { return event }
                // ESCキー(keyCode 53)は、RemappableKey/keyBindingStoreによる
                // カスタマイズ可能なキー割り当ての対象には含めず、常に固定の「閉じる」操作
                // という慣習に合わせて別枠で扱う。拡大鏡(ルーペ)表示中に押すと、
                // ページ送りなど他の操作には一切影響させずに拡大鏡だけを閉じる。
                // 拡大鏡が出ていなければ、ピンチ拡大の解除に使う。どちらにも当てはまらない
                // ときはイベントを消費せずそのまま通し、フルスクリーンの解除など
                // macOS標準のESCの働きを妨げない。
                if event.keyCode == 53 {
                    if viewModel.isLoupeActive {
                        viewModel.toggleLoupe()
                        return nil
                    }
                    if viewModel.pinchZoomFactor > 1 {
                        resetPinchZoom()
                        return nil
                    }
                }
                // キー入力の検知は、以前はSwiftUIの.onKeyPressで行っていたが、
                // 環境によっては矢印キーがそちらまで届かない(ビープ音が鳴るだけで
                // 何も起きない)不具合があったため、動作が確実なこちらのNSEventベースの
                // 経路に統合した(詳細はRemappableKey.from(nsEvent:)のコメント参照)。
                if let key = RemappableKey.from(nsEvent: event),
                   let action = keyBindingStore.resolvedAction(
                       for: key, in: viewModel.scalingMode
                   ) {
                    perform(action)
                    // イベントをここで消費し、これ以上(標準のフォーカス移動や
                    // ビープ音などへ)伝播させない。
                    return nil
                }
            default:
                // .mouseMovedは上で早期リターン済みのため、マッチしている残りの型
                // (.scrollWheel/.swipe/.magnify/.smartMagnify/.keyDown)はすべて明示的な
                // caseで処理されており、ここには実質到達しない。
                break
            }
            return event
        }
    }

    /// コンテキストメニュー(右クリック、またはControl+左クリック)を起動したクリックの
    /// 位置を検知する専用のローカルモニタ(設計コンセプト8.4節。handleOnAppearのコメント参照)。
    ///
    /// SwiftUIの.contextMenu(menuItems:)は、そのメニューを表示させたクリックの位置を
    /// クロージャへ渡してくれない。pageAreaは見開き中でも左右のページ画像をまとめて
    /// 1枚のHStackとして描画している(pageArea参照)ため、左右のページを別々の
    /// SwiftUIビューに分けてそれぞれへ.contextMenuを付ける、という手も使えない。
    /// そのため、素のNSEventでクリック自体を(消費せず、通過させたまま)監視し、
    /// pageAreaFrameInWindow(PageAreaFrameAccessorが報告する、pageAreaの
    /// ウインドウ座標系でのフレーム)と突き合わせて、クリックがその左半分・右半分の
    /// どちらで起きたかを覚えておく。実際にメニューが開かれる少し前(mouseDown時点)に
    /// 判定しておき、contextMenuContentが呼ばれる時点ではこの保存済みの値を参照するだけ、
    /// という構成にしている。
    private func makeContextClickMonitor() -> Any? {
        NSEvent.addLocalMonitorForEvents(
            matching: [.rightMouseDown, .leftMouseDown]
        ) { (event: NSEvent) -> NSEvent? in
            guard let hostWindow, event.window === hostWindow else { return event }
            guard !showThumbnailGrid, !appState.isSidePanelFloatingOverlay else { return event }
            let isRightMouseDown: Bool = event.type == .rightMouseDown
            let isControlClick: Bool = event.type == .leftMouseDown && event.modifierFlags.contains(.control)
            let isContextMenuClick: Bool = isRightMouseDown || isControlClick
            guard isContextMenuClick, pageAreaFrameInWindow.width > 0 else { return event }
            let localX: CGFloat = event.locationInWindow.x - pageAreaFrameInWindow.minX
            let halfWidth: CGFloat = pageAreaFrameInWindow.width / 2
            isLastContextClickOnLeftHalf = localX < halfWidth
            return event
        }
    }

    /// ページ一覧(サムネイルグリッド)パネルを閉じるクリックを拾うNSEventローカルモニタを
    /// 取り付ける。showThumbnailGridがtrueになるたびに呼ばれる。
    ///
    /// ■ 閉じる条件を「画像表示領域のクリック」だけに絞ってある(方針転換。戻さないこと)
    /// 以前は逆で、「パネルの外側でありさえすれば、タイトルバー・メニューバー・他の
    /// qooViewerウインドウ・**他のアプリ**を含めどこをクリックしても閉じる」実装だった
    /// (そのために、ここのローカルモニタに加えてグローバルモニタと、メニューの追跡開始を
    /// 見る監視〈setUpWindowObservers〉まで置いていた)。これは当時のユーザー要望どおり
    /// だったが、実際に使うと「閉じたくない場面」で必ず閉じてしまうという指摘を受けた:
    ///   ・サイドパネルでフォルダやページを選ぼうとしてクリックした
    ///   ・環境設定ウインドウでサムネイルの大きさを調整しようとした
    ///   ・別のアプリへ切り替えて戻ってきた
    /// そこで、閉じる操作を次の3つだけに限定する(ユーザー要望):
    ///   1. サムネイルのクリック(そのページへジャンプして閉じる。ThumbnailGridViewのButton)
    ///   2. パネル内の余白のクリック(何もせず閉じる。ThumbnailGridViewの.onTapGesture)
    ///   3. **画像表示領域**のクリック(このモニタが担当)
    /// ツールバー・プログレスバー・タイトルバー・メニューバー・サイドパネル・他ウインドウ・
    /// 他アプリは、どれも閉じる条件にならない(ホバーで画像表示エリアの上に浮かせている
    /// サイドパネルも含む。下のsidePanelScreenFrameの除外を参照)。
    ///
    /// ■ このモニタが担当するのは3番だけ
    /// 1・2はパネル自身のSwiftUIのジェスチャーで完結している。3を透明な背景レイヤー
    /// (ThumbnailGridBackdropView)側で判定しないのは、あのレイヤーがツールバー/
    /// プログレスバーも含むビューア全体を覆っており、SwiftUIのタップジェスチャーだけでは
    /// 「画像表示領域の上かどうか」を区別できないため。スクリーン座標同士の比較にすれば、
    /// ウインドウ座標系の向きの違いを気にせず一箇所で書ける。
    ///
    /// 中ボタン(.otherMouseDown)も対象にしている。中ボタンに「ページ一覧を表示/非表示」を
    /// 割り当てた場合、それで開いたパネルを同じ操作で閉じられるようにするため。
    /// ボタンを離す側(.leftMouseUp/.otherMouseUp)を見ているのは、パネルの**上での**
    /// ドラッグジェスチャーを拾うため(dismissThumbnailGridIfGestureAssigned参照)。
    private func installThumbnailGridDismissMonitorIfNeeded() {
        guard thumbnailGridDismissMonitor == nil else { return }
        thumbnailGridDismissMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .otherMouseUp]
        ) { event in
            switch event.type {
            case .leftMouseUp, .otherMouseUp:
                dismissThumbnailGridIfGestureAssigned(event)
            default:
                // 自分のウインドウ宛て以外(他のqooViewerウインドウ、環境設定ウインドウ、
                // ファイル選択パネルなど)は一切見ない。
                guard let hostWindow, event.window === hostWindow else { return event }
                let location = NSEvent.mouseLocation
                guard !thumbnailPanelScreenFrame.contains(location) else {
                    // パネルの上での押下は、ドラッグジェスチャーの起点として覚えておく。
                    thumbnailGridGesturePressBox.press = MouseTrigger.Button.allCases
                        .first { $0.eventButtonNumber == event.buttonNumber }
                        .map { (location, event.timestamp, $0) }
                    return event
                }
                thumbnailGridGesturePressBox.press = nil
                guard pageAreaScreenFrame.contains(location) else { return event }
                // ホバーで浮かせたサイドパネルは、画像表示エリアの**上に重なって**描かれる
                // (ContentView.windowContent参照)。座標だけで判定すると、そのパネルの行を
                // クリックしただけでページ一覧が閉じてしまう ―― この関数のコメントで
                // 「閉じてほしくない」と明記した場面そのものになる。浮いている間だけ、
                // パネルの矩形を除外する(常時表示のときはそもそも画像表示エリアの外にある)。
                if appState.isSidePanelFloatingOverlay,
                   appState.sidePanelScreenFrame.contains(location) {
                    return event
                }
                showThumbnailGrid = false
            }
            // イベント自体は消費しない。閉じるかどうかと、そのクリックが本来届くべき先へ
            // 届くかどうかは別の話であるため(タイトルバーのボタン操作などを妨げない)。
            return event
        }
    }

    /// 画像表示エリア(pageArea)の、スクリーン座標系での現在のフレーム。
    /// まだ実測できていない場合は空の矩形を返す(`contains`が常にfalseになり、
    /// 「閉じない」側へ倒れる)。
    private var pageAreaScreenFrame: CGRect {
        guard let hostWindow, pageAreaFrameInWindow.width > 0, pageAreaFrameInWindow.height > 0
        else { return .zero }
        return hostWindow.convertToScreen(pageAreaFrameInWindow)
    }

    /// ページ一覧パネルの**上で**行われたドラッグジェスチャーが「ページ一覧を表示/非表示」に
    /// 割り当てられていれば、パネルを閉じる。
    ///
    /// パネルはビューアのほぼ全面を覆うため、「パネルの外側を押したら閉じる」経路だけでは、
    /// ジェスチャーで開いた人が同じジェスチャーで閉じられる余地がほとんど残らない
    /// (ユーザー要望: 設定したマウスジェスチャーで閉じられるようにしたい)。パネルの上を
    /// なぞる操作は他に意味を持たないため、ここで拾う。
    ///
    /// 割り当てられている操作がページ一覧でなければ何もしない ― 別の操作(ページ送りなど)を
    /// 割り当てたジェスチャーが、パネルを閉じるだけの操作に化けてしまわないようにするため。
    /// 30ポイントに満たない動き(=クリック)も対象外で、サムネイルを選ぶ操作は妨げない。
    private func dismissThumbnailGridIfGestureAssigned(_ event: NSEvent) {
        guard let press = thumbnailGridGesturePressBox.press else { return }
        thumbnailGridGesturePressBox.press = nil
        guard press.button.eventButtonNumber == event.buttonNumber else { return }
        let location = NSEvent.mouseLocation
        guard let direction = MouseTrigger.DragDirection.from(
            dx: location.x - press.location.x,
            dy: location.y - press.location.y,
            duration: event.timestamp - press.timestamp
        ) else { return }
        guard let modifiers = MouseTrigger.Modifiers.from(event.modifierFlags, allowsShift: true)
        else { return }
        let action = keyBindingStore.resolvedDragAction(
            button: press.button, direction: direction, modifiers: modifiers,
            in: viewModel.scalingMode
        )
        guard action == .showThumbnailGrid else { return }
        showThumbnailGrid = false
    }

    /// installThumbnailGridDismissMonitorIfNeededで取り付けたモニタを外す。
    /// showThumbnailGridがfalseになるたびに呼ばれる(handleOnDisappearからも、ウインドウごと
    /// 閉じられた場合の保険として呼ぶ)。
    private func removeThumbnailGridDismissMonitor() {
        if let thumbnailGridDismissMonitor {
            NSEvent.removeMonitor(thumbnailGridDismissMonitor)
        }
        thumbnailGridDismissMonitor = nil
    }

    /// ページ一覧パネルが取り付けたホイール/ピンチのモニタを外す
    /// (thumbnailGridEventMonitorのコメント参照)。パネル自身の`.onDisappear`からも
    /// 同じ処理が走るが、先に外したほうがnilを入れるので二重解除にはならない。
    private func removeThumbnailGridEventMonitor() {
        if let thumbnailGridEventMonitor {
            NSEvent.removeMonitor(thumbnailGridEventMonitor)
        }
        thumbnailGridEventMonitor = nil
    }

    /// .onDisappear{}の中身をprivateメソッドへ切り出したもの(handleOnAppearのコメント参照)。
    /// 処理内容自体は以前と同じ(各種モニタ・タスクの後始末、appStateへの後始末)。
    private func handleOnDisappear() {
        clickZoneArmTask?.cancel()
        clickZoneArmTask = nil
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
        scrollMonitor = nil
        if let contextClickMonitor {
            NSEvent.removeMonitor(contextClickMonitor)
        }
        contextClickMonitor = nil
        removeThumbnailGridDismissMonitor()
        removeThumbnailGridEventMonitor()
        clearAppStateBridgesIfStillOwner()
        // 自分の@StateObjectであるviewModelへ登録した橋渡しも、ここで確実に外す
        // (handleOnAppearのonPageBoundaryRequestのコメント参照。appState側と違い、この
        // viewModelはこのViewerView専用なのでトークンによる持ち主判定は不要)。
        viewModel.onPageBoundaryRequest = nil
        viewModel.stopSlideshow()
        viewModel.flushPendingSave()
        // このViewerViewはもう画面に無いので、本1冊ぶんのメモリキャッシュと走っている
        // 読み込みを明示的に手放す(ViewerViewModel.releaseResourcesのコメント参照)。
        // clearAppStateBridgesIfStillOwnerと違いトークンで持ち主を判定しないのは、
        // このviewModelがこのViewerView専用だからで、上のonPageBoundaryRequest等と同じ理由。
        viewModel.releaseResources()
        cursorHideTask?.cancel()
        cursorHideTask = nil
        toastDismissTask?.cancel()
        toastDismissTask = nil
        zoomIndicatorHideTask?.cancel()
        zoomIndicatorHideTask = nil
        cancelPendingChromeReveal()
        if isCursorHidden {
            NSCursor.unhide()
            isCursorHidden = false
        }
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers = []
    }

    /// handleOnAppearでappStateへ登録した橋渡し(メニューバー・サイドパネル・編集ウインドウ
    /// からこのビューアを操作するためのクロージャ群)と、そこへ push しておいた表示状態を
    /// まとめて元に戻す。
    ///
    /// 「まだ自分自身が最後にappStateへ登録したViewerViewである場合にだけ行う」という条件は
    /// 以前からのもの。同じウインドウ内で本を切り替えた際、既に新しいViewerViewのonAppearが
    /// 自分のトークンで上書きしていれば、ここでの後始末は行わない(誤って新しい本の正しい登録を
    /// 消してしまわないため。AppState.activeViewerTokenのコメント参照)。
    ///
    /// これらのクロージャはいずれもViewerView(struct)のコピーを丸ごとキャプチャしており、
    /// そのコピーは@EnvironmentObjectのappState自身を強参照しているため、AppStateから見ると
    /// 循環参照になっている(handleOnAppearのonPageBoundaryRequestのコメント参照)。つまり
    /// 「この後始末が確実に走ること」がAppStateの解放条件そのものになっている。そのため
    /// onDisappearだけに頼らず、ウインドウが閉じるタイミング(setUpWindowObservers内の
    /// willCloseNotification)からも呼ぶ。SwiftUIの.onDisappearは、実際にNSWindowが破棄される
    /// タイミングより後になることがある(同ファイルのsetUpWindowObservers末尾のコメント参照)。
    private func clearAppStateBridgesIfStillOwner() {
        guard appState.activeViewerToken == viewerToken else { return }
        appState.performViewerAction = nil
        appState.jumpToBookmark = nil
        appState.fetchResourceSnapshot = nil
        appState.jumpToPageIndex = nil
        appState.addBookmarkAction = nil
        appState.toggleBookmarkAtIndex = nil
        appState.addFavoriteAction = nil
        appState.openFavoriteAction = nil
        appState.hideAutoRevealedChrome = nil
        appState.updateLoadPageThumbnail(nil)
        appState.updateCurrentBookmarks([])
        appState.updateCurrentPageIndex(0)
        appState.updateCurrentBookPages([])
        appState.updateCurrentVisiblePageSortKeys([])
        appState.setScalingMode = nil
        appState.performLayoutStateChange = nil
        appState.performLayoutClear = nil
        appState.performAutoLayout = nil
        appState.performImageExport = nil
        appState.exportPageImage = nil
        // ツールバー/プログレスバーの自動表示は、このViewerViewが持っていた状態そのもの。
        // 本を閉じた(ウェルカム画面へ戻った)後もtrueのまま残ると、ContentView側から見て
        // 「まだ自動表示中のものがある」という誤情報になり、ウインドウ外検知用のグローバル
        // モニタが外れなくなる(ContentView.updateOutsideWindowMonitor参照)。
        appState.isChromeAutoRevealed = false
        appState.resetMenuCheckmarkState()
    }

    // MARK: - 画像のエクスポート(要望)

    /// 画像のエクスポートで実際に対象となるページの組み合わせ。呼び出し側(メニューバー経由の
    /// appState.performImageExport、コンテキストメニューのExport Imageサブメニュー)が、
    /// それぞれの手段でのページ番号の解決(見開き左右の判定、クリック位置の判定)を済ませたうえで
    /// この列挙を組み立てる。leftIndex/rightIndexは常に画面上の左右(読み方向を反映済み)を表す。
    private enum ImageExportRequest {
        case singlePage(index: Int)
        case mergedSpread(leftIndex: Int, rightIndex: Int)
    }

    /// 画像のエクスポート本体。NSSavePanelで保存先を選んでもらってから、実際の画像の読み込み・
    /// (結合が必要な場合は)合成・書き込みを非同期に行う
    /// (LibraryExportWindow.exportButtonTappedと同じ「パネル表示 → Task」の順序)。
    /// パネルをキャンセルした場合は何もしない。
    ///
    /// 見開きの結合はパネルより前がすべて同期的だが、1ページの書き出しだけはパネルを出す前に
    /// 拡張子の解決(await)を1回挟む(下のコメント参照)。
    private func exportImage(_ request: ImageExportRequest) {
        switch request {
        case .singlePage(let index):
            guard viewModel.book.pages.indices.contains(index) else { return }
            // 保存パネルを二重に開かない。すぐ下の理由でパネルが出るまでに`await`を1回挟むため、
            // その隙にもう一度この操作を起動できてしまい、runModal()が入れ子になりうる
            // (パネルが出た後はアプリモーダルなので操作できず、隙はこの`await`の間だけ)。
            // ここから`isExportingSinglePage`の代入までに中断点が無いので、この判定で塞げる。
            guard !isExportingSinglePage else { return }
            isExportingSinglePage = true
            let page = viewModel.book.pages[index]
            // 保存パネルを出す**前に**拡張子を確定させる。PDFのページは中の画像の形式を
            // 読むまでjpg/pngが決まらず、決め打ちにすると中身と名前が食い違う
            // (ViewerViewModel.exportableImageFileExtension(at:)のコメント参照)。
            // 画像データ本体はまだ読まないので、パネルが出るまでの待ちはごく短い。
            Task {
                defer { isExportingSinglePage = false }
                do {
                    guard let ext = try await viewModel.exportableImageFileExtension(at: index) else { return }
                    guard let url = presentImageExportSavePanel(
                        defaultFileName: ImageExporter.defaultFileName(for: page, fileExtension: ext),
                        contentType: ImageExporter.contentType(forExtension: ext)
                    ) else { return }
                    // PDFの本でも書き出せるよう、生データではなく
                    // ViewerViewModel.exportableImage(at:)を使う(そちらのコメント参照)。
                    guard let exportable = try await viewModel.exportableImage(at: index) else {
                        imageExportErrorMessage = String(localized: "Couldn't read the image to export.")
                        return
                    }
                    try ImageExporter.writeSinglePage(data: exportable.data, to: url)
                } catch {
                    imageExportErrorMessage = error.localizedDescription
                }
            }
        case .mergedSpread(let leftIndex, let rightIndex):
            guard viewModel.book.pages.indices.contains(leftIndex),
                  viewModel.book.pages.indices.contains(rightIndex), leftIndex != rightIndex
            else { return }
            // 「前・後」(ファイル名の決定・形式が異なる場合の優先側)は画面上の左右ではなく、
            // 常に読み順(ページ番号が若い方)を基準にする(ImageExporterのコメント参照)。
            let leadingIndex = min(leftIndex, rightIndex)
            let trailingIndex = max(leftIndex, rightIndex)
            let leadingPage = viewModel.book.pages[leadingIndex]
            let trailingPage = viewModel.book.pages[trailingIndex]
            let ext = ImageExporter.mergedFileExtension(leadingPage: leadingPage, trailingPage: trailingPage)
            guard let url = presentImageExportSavePanel(
                defaultFileName: ImageExporter.defaultMergedFileName(leadingPage: leadingPage, trailingPage: trailingPage),
                contentType: ImageExporter.contentType(forExtension: ext)
            ) else { return }
            Task {
                guard let leftImage = await viewModel.fullResolutionImage(at: leftIndex),
                      let rightImage = await viewModel.fullResolutionImage(at: rightIndex)
                else {
                    imageExportErrorMessage = String(localized: "Couldn't read the image to export.")
                    return
                }
                do {
                    let data = try ImageExporter.combine(leftImage: leftImage, rightImage: rightImage, outputExtension: ext)
                    try ImageExporter.writeCombinedImage(data: data, to: url)
                } catch {
                    imageExportErrorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - 本の書き出し(右クリックの「本の書き出し」。ユーザー要望)

    /// 右クリックから始めた1冊ぶんの書き出し。シートの表示状態と、その書き出しに使う
    /// ViewModelを一緒に持つ。
    ///
    /// ViewModelを`@State`で1つ持ち回すのではなく、書き出しのたびに作って捨てる形にしてある。
    /// 3つの形式は別々のサブクラス(EpubExportViewModel等)なので、形式を選んだ時点でしか
    /// 決められないため。作るのは軽い ―― 書き出しウインドウの対象一覧は組み立てない
    /// (BookExportViewModel.initのloadsEligibleRows参照)。
    private struct OpenBookExportRequest: Identifiable {
        let id = UUID()
        let format: BookExportFormat
        let viewModel: BookExportViewModel
        /// 環境設定「レイアウト」で固定の保存先が決めてあればそのフォルダ。
        /// nilなら、シートが保存先の選択から始める。
        let fixedDestination: URL?
    }

    /// 右クリック →「本の書き出し」→ 形式を選んだときに呼ばれる。
    private func startOpenBookExport(format: BookExportFormat) {
        guard openBookExport == nil else { return }
        // 固定の保存先が設定されていても、そのブックマークがもう解決できない(フォルダが
        // 消された・外付けが外れている)ことはある。その場合はnilのまま渡して、シートに
        // 保存先を尋ねさせる ―― 黙って何もしないより、その場で選び直せるほうがよい。
        let fixedDestination = preferences.bookExportDestinationMode(for: format) == .fixedFolder
            ? format.fixedFolder.lastFolder()
            : nil
        openBookExport = OpenBookExportRequest(
            format: format,
            viewModel: format.makeExportViewModel(
                bookmarkStore: bookmarkStore, layoutStore: layoutStore, metadataStore: metadataStore,
                preferences: preferences, loadsEligibleRows: false
            ),
            fixedDestination: fixedDestination
        )
    }

    /// 1冊の書き出しが成功したあとの後始末(環境設定「レイアウト」)。
    /// 保存データ・履歴を設定に従って片付けてから、「書き出したあとの動作」へ進む。
    private func finishOpenBookExport(format: BookExportFormat) {
        cleanUpExportedBook(format: format)

        let behavior = preferences.bookExportCompletionBehavior
        if behavior == .ask {
            isShowingExportCompletionPrompt = true
        } else {
            performExportCompletionBehavior(behavior)
        }
    }

    /// 書き出した本についてアプリが保存しているものを、設定に従って片付ける。
    ///
    /// DBへ書かない本(シークレットウインドウ・その場限りの本)では、そもそも消すものが無い
    /// ので何もしない。お気に入りは消さない ―― レイアウトや読書位置と違って、ユーザーが
    /// 明示的に手で登録したものだから(ユーザーの指示)。
    private func cleanUpExportedBook(format: BookExportFormat) {
        guard !viewModel.skipsPersistence else { return }
        let book = viewModel.book

        if preferences.bookExportDataCleanup(for: format) == .delete {
            bookmarkStore.deleteAllBookmarks(forBookID: book.id)
            layoutStore.discardLayoutData(forBookID: book.id)
            metadataStore.delete(forBookID: book.id)
            // 読書位置(BookReadingState)の行はViewerViewModelが握っているため、ここで
            // modelContextから直接消してはいけない(消した行へページ送りのたびに書き込もうと
            // してしまう)。ViewerViewModel.discardReadingState()参照。
            viewModel.discardReadingState()
        }

        if preferences.bookExportHistoryCleanup(for: format) == .delete {
            // 履歴の項目はブックマークとパスで照合する(RecentFilesStore.remove(_:)参照)。
            // 同じ実体を指す項目が複数入っていることがあるので、一致するものをまとめて渡す。
            let path = book.sourceURL.standardizedFileURL.path
            let matches = recentFilesStore.entries.filter {
                URL(fileURLWithPath: $0.path).standardizedFileURL.path == path
            }
            recentFilesStore.remove(matches)
        }
    }

    /// 「書き出したあとの動作」の実行。
    ///
    /// 移動系の3つ(次の本・本を閉じる・ウェルカム画面へ戻る)は、環境設定「閲覧中の動作」の
    /// 「最後のページで」がまったく同じことをしている。**同じ動作を2通りに実装しない**ため、
    /// ViewerViewModelがそちら向けに用意している依頼の口(onPageBoundaryRequest経由で
    /// ViewerViewが受け取る処理)をそのまま使う(PageBoundaryRequest参照)。
    private func performExportCompletionBehavior(_ behavior: BookExportCompletionBehavior) {
        switch behavior {
        case .none, .ask:
            // .askがここへ来ることは無い(finishOpenBookExportがシートへ回す)が、シートで
            // 何も選ばずに閉じられた場合と同じく「何もしない」で受ける。
            break
        case .nextBookFirstPage:
            appState.openSibling(after: viewModel.book.sourceURL, landsOnFirstPage: true)
        case .nextBook:
            appState.openSibling(after: viewModel.book.sourceURL)
        case .closeBook:
            // 「本を閉じる」はViewerAction.closeTabと同じ経路(タブが1枚ならウインドウごと)。
            perform(.closeTab)
        case .returnToWelcome:
            // 本だけ閉じて、同じウインドウにウェルカム画面を出す。読書位置の保留分は
            // onDisappearでも確定するが、先に走る保証が無いのでここでも確定させておく
            // (ViewerViewModel.onPageBoundaryRequestの.returnToWelcomeと同じ)。
            viewModel.flushPendingSave()
            appState.closeBook()
        }
    }

    /// 保存先のフォルダとファイル名を指定するためのウインドウ(要望)。LibraryExportWindow.
    /// exportButtonTappedと同じ、同期的なNSSavePanel.runModal()。
    private func presentImageExportSavePanel(defaultFileName: String, contentType: UTType) -> URL? {
        let locale = preferences.effectiveLocale
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = defaultFileName
        panel.message = String(localized: "Choose where to save the exported image.", locale: locale)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    /// pending.pageIndexを基準に、伝播範囲選択ダイアログ(applyLayoutAlerts参照)へ渡す選択肢を
    /// 絞り込む。先頭ページには「このページより前のページ全体」を、末尾ページには「このページ
    /// より後のページ全体」を出さない(BookmarkListView.availableScopes(forPageKey:)と同じ考え方)。
    private func availableScopes(forPageIndex pageIndex: Int) -> [LayoutPropagationScope] {
        let maxIndex = viewModel.book.pages.count - 1
        return LayoutPropagationScope.allCases.filter { scope in
            switch scope {
            case .thisPageOnly, .wholeBook: return true
            case .beforeThisPage: return pageIndex > 0
            case .afterThisPage: return pageIndex < maxIndex
            }
        }
    }

    // 以前はbody全体が「巨大なZStack + そこへ10個以上のモディファイア(.onAppear/.onDisappear/
    // 6個の.onChange/2個の.sheet/3個の.alert/1個の.confirmationDialog)を連鎖させた1つの式」
    // という構成だった。.onAppear/.onDisappearの中身をprivateメソッドへ切り出しても、次は
    // 別の箇所(.onDisappear、さらにその次の箇所)で同種のエラーが再発した(ユーザー報告)ため、
    // 場当たり的にクロージャ単位で切り出すのではなく、body自体を複数の独立した式に分割する
    // 方針に変更する。
    //
    // ZStack本体をmainZStackという別のcomputed varへ切り出し、モディファイアの連鎖も
    // 「ライフサイクル/onChange」「シート」「アラート・ダイアログ」の3グループに分け、
    // それぞれをジェネリックなprivateメソッド(applyLifecycleHandlers/applySheets/
    // applyLayoutAlerts)としてbodyの外に出す。body自身は、各段階の結果をlet(型は
    // コンパイラに推論させるが、1段階ごとに確定させるので式全体をまとめて推論するより
    // 大幅に軽い)へ順番に代入していくだけの、浅く単純な式になる。
    var body: some View {
        let withLifecycle = applyLifecycleHandlers(to: mainZStack)
        let withSheets = applySheets(to: withLifecycle)
        return applyLayoutAlerts(to: withSheets)
    }

    /// ツールバーが自動隠しの対象かどうか。フルスクリーン表示中は、表示メニューの
    /// 「ツールバーを隠す」の設定に関わらず常に自動隠しになる。ウインドウ表示のときは、
    /// その設定がONのときだけ自動隠しになる(OFFなら常に表示)。
    private var toolbarAutoHides: Bool { isFullScreen || appState.hideToolbar }
    /// プログレスバー側の同じもの(toolbarAutoHides参照)。
    private var progressBarAutoHides: Bool { isFullScreen || appState.hideProgressBar }

    /// bodyから切り出したZStack本体(handleOnAppearのコメント参照)。
    private var mainZStack: some View {
        // 自動隠しかどうかの判定(toolbarAutoHides/progressBarAutoHides)は、マウス位置に
        // よる自動表示の側(updateAutoHiddenChromeVisibilityなど)と条件を1箇所で共有するため、
        // このビューの計算プロパティにしてある。
        // 自動隠し中のツールバー・プログレスバーを、マウスが画面端に近づいたことで
        // 一時的に表示している状態かどうか。
        let showToolbarOverlay = toolbarAutoHides && isToolbarAutoRevealed
        let showProgressBarOverlay = progressBarAutoHides && isProgressBarAutoRevealed

        // 自動隠しでない(常に表示する)ときは、以前と同じくVStackの一部として組み込み、
        // 画像表示エリアはその分だけ縮んだ残りの領域を使う。
        // 一方、自動隠し中にマウスを近づけて一時的に表示するときは、画像表示エリアの
        // サイズを一切変えたくない(表示するたびに画像が拡大縮小されるのを避けるため)ので、
        // ZStackで画像の上に半透明のパネルとして重ねて表示する形にしている。
        return ZStack {
            VStack(spacing: 0) {
                if !toolbarAutoHides {
                    // 常時表示の帯の背後(ウインドウ内)には何も描かれていないので、SwiftUIの
                    // Materialではぼかす対象が無い。環境設定「外観」の「ウインドウの背後を
                    // 透かす」がONのときだけ、ウインドウの背後(デスクトップ/他のウインドウ)を
                    // 透かす.behindWindowのすりガラスを敷く(ユーザー要望: のっぺりして
                    // 見えるので背後が少しだけ透けて見えるように。既定はOFFで従来どおり
                    // 色の層だけ。panelSurfaceBackground(_:behindWindowMaterial:in:)の
                    // コメント参照)。.titlebarはすぐ上のタイトルバーと同系の控えめな
                    // マテリアルで、タイトルバーから帯まで質感が途切れずつながって見える。
                    toolbar
                        .panelSurfaceBackground(
                            preferences.toolbarSurfaceStyle,
                            behindWindowMaterial: preferences.toolbarDockedGlass ? .titlebar : nil,
                            in: Rectangle()
                        )
                        // 帯を右クリックしたら「ツールバーを隠す」(ユーザー要望)。背景を敷いた
                        // 後に付けることで、ボタンの無い余白も含めた帯全体が対象になる。
                        .panelPartContextMenu(for: .toolbar)
                    Divider()
                }
                pageArea
                    .contextMenu {
                        contextMenuContent
                    }
                if !progressBarAutoHides {
                    // ツールバー側と同じ(すぐ上のコメント参照)。
                    ProgressBarView(viewModel: viewModel)
                        .measuringHeight(into: $progressBarHeight)
                        .panelSurfaceBackground(
                            preferences.progressBarSurfaceStyle,
                            behindWindowMaterial: preferences.progressBarDockedGlass ? .titlebar : nil,
                            in: Rectangle()
                        )
                        // ツールバーと同じ(すぐ上のコメント参照)。こちらは「プログレスバーを隠す」。
                        .panelPartContextMenu(for: .progressBar)
                }
            }

            if toolbarAutoHides {
                VStack(spacing: 0) {
                    toolbar
                        // 背景の濃さと重ね色は環境設定「外観」に従う(ユーザー要望)。
                        // 既定値では従来の .background(.ultraThinMaterial) と同じ描画になる。
                        .panelSurfaceBackground(
                            preferences.toolbarSurfaceStyle, material: .ultraThinMaterial, in: Rectangle()
                        )
                        // 常時表示のときと同じ(すぐ上の分岐のコメント参照)。
                        .panelPartContextMenu(for: .toolbar)
                        // ツールバー(実際に表示されている帯)の下端が、ウインドウ座標系の
                        // どのY座標にあるかを実測する。この位置より上にマウスがあれば
                        // (=ツールバーの表示領域全体のどこであれ)表示を維持する
                        // (updateAutoHiddenChromeVisibility参照)。
                        .overlay(alignment: .bottom) {
                            WindowYPositionAccessor { y in
                                toolbarBottomYInWindow = y
                            }
                            .frame(height: 0)
                        }
                    Spacer(minLength: 0)
                }
                .opacity(showToolbarOverlay ? 1 : 0)
                .allowsHitTesting(showToolbarOverlay)
                .animation(.easeInOut(duration: 0.15), value: showToolbarOverlay)
            }

            if progressBarAutoHides {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    ProgressBarView(viewModel: viewModel)
                        .measuringHeight(into: $progressBarHeight)
                        // ツールバー側と同じ(すぐ上のコメント参照)。
                        .panelSurfaceBackground(
                            preferences.progressBarSurfaceStyle, material: .ultraThinMaterial, in: Rectangle()
                        )
                        // 常時表示のときと同じ(すぐ上の分岐のコメント参照)。
                        .panelPartContextMenu(for: .progressBar)
                }
                .opacity(showProgressBarOverlay ? 1 : 0)
                .allowsHitTesting(showProgressBarOverlay)
                .animation(.easeInOut(duration: 0.15), value: showProgressBarOverlay)
            }

            // お気に入り・ブックマークの追加/削除トグルを操作したときのフィードバック表示
            // (ユーザー要望)。ツールバー・プログレスバーの自動隠し状態に関わらず、常に画面
            // 中央下部に一時的に浮かせる(操作の結果がツールバー/コンテキストメニュー/
            // メニューバー/キーボードショートカットのどこから行われても同じ見た目で分かるように、
            // toggleCurrentPageBookmark()/toggleCurrentBookFavorite()/
            // FavoriteFolderPickerViewのonAddedからshowToast(_:)を呼ぶだけでよい形にしている)。
            if let toastMessage {
                VStack {
                    Spacer()
                    Text(toastMessage)
                        .font(.callout)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .panelOutlinedContent()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .panelSurfaceBackground(
                            preferences.overlaySurfaceStyle, material: .ultraThinMaterial, in: Capsule()
                        )
                        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                        .padding(.bottom, 48)
                }
                .allowsHitTesting(false)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .zIndex(1)
            }

            // ピンチ拡大中の拡大率表示(ユーザー要望)。トーストと同じく画面に浮かせるが、
            // トーストが画面下部を使うのに対しこちらは上部に出す(拡大操作の直後に
            // ブックマーク追加のトーストが重なっても互いに隠れないようにするため)。
            if let zoomIndicatorPercent {
                VStack {
                    Text(verbatim: "\(zoomIndicatorPercent)%")
                        .font(.callout)
                        .monospacedDigit()
                        .panelOutlinedContent()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .panelSurfaceBackground(
                            preferences.overlaySurfaceStyle, material: .ultraThinMaterial, in: Capsule()
                        )
                        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                        .padding(.top, 56)
                    Spacer()
                }
                .allowsHitTesting(false)
                .transition(.opacity)
                .zIndex(1)
            }

            // ページ一覧(サムネイルグリッド)。以前は独立したシート(.sheet)として表示していたが、
            // ユーザー要望により「閉じる」ボタンと並び替え機能を廃止し、代わりにこのパネルの
            // 外側(ビューア画面)をクリックすると閉じるようにした。パネル自体は以前のシートと
            // 同じく5列表示に必要な幅だけに留め(ThumbnailGridView.panelWidth参照)、
            // ビューア画面いっぱいには広げない(ユーザー要望)。そのため、ツールバー・
            // プログレスバー・pageAreaを含むビューア画面全体を覆う透明な背景レイヤー
            // (ThumbnailGridBackdropView)をこのZStackの最前面(トースト表示より上、zIndex参照)へ
            // 重ね、その上にパネル本体を中央揃えで置く2段構成にしている。表示中はスクロール/
            // スワイプ/キーボードショートカットが背後の本へ影響しないよう、makeScrollMonitor/
            // makeContextClickMonitor側でもshowThumbnailGridを見て無視している。
            if showThumbnailGrid {
                ZStack {
                    ThumbnailGridBackdropView()
                    // クリックがパネルの内側か外側かを判定するために、パネル自身の現在の
                    // スクリーン座標系でのフレームを常に把握しておく必要があり、パネル本体の
                    // .backgroundに重ねたPanelScreenFrameAccessorから報告を受け取る
                    // (thumbnailPanelScreenFrame/installThumbnailGridDismissMonitorIfNeeded参照)。
                    // 以前はここでThumbnailGridView全体の.backgroundとして取っていたが、
                    // パネルの大きさが環境設定の余白から決まる構成(ThumbnailGridView.body参照)に
                    // なり、このビューの外形は画像表示領域いっぱいになったため、パネル本体側へ移した。
                    ThumbnailGridView(
                        viewModel: viewModel,
                        isPresented: $showThumbnailGrid,
                        onExportPage: { exportImage(.singlePage(index: $0)) },
                        // 右クリックの「このページをブックマークに追加/削除」(ユーザー要望)。
                        // ビューアの右クリックと同じ、クリックした1ページだけを対象にするトグル。
                        onToggleBookmark: { toggleBookmark(atIndex: $0) },
                        onPanelScreenFrameChange: { thumbnailPanelScreenFrame = $0 },
                        eventMonitor: $thumbnailGridEventMonitor
                    )
                }
                .transition(.opacity)
                .zIndex(2)
            }

            // 「情報を見る」(contextMenuContent参照)。以前はNSMenuのサブメニューだったが、
            // 値の先頭を揃えて表示したいという要望(Finderの「情報を見る」のように)を受けて
            // 一度ポップオーバー(.popover)に変更したところ、ウインドウの外にはみ出す吹き出し
            // として表示されるのは意図と違うという指摘を受けた。そのため、すぐ上のページ一覧
            // (ThumbnailGridView)と同じ構成 — ウインドウ内を覆う透明な背景層
            // (ThumbnailGridBackdropView、外側クリックで閉じる。isPresentedのBindingを
            // 受け取るだけの汎用的な実装のためそのまま再利用している)の上にパネル本体を
            // 中央揃えで重ねる形 — に変更し、ビューアウインドウの内側にオーバーレイ表示される
            // ようにした。
            if isShowingPageInfoPanel {
                ZStack {
                    ThumbnailGridBackdropView(isPresented: $isShowingPageInfoPanel)
                    Group {
                        if let info = viewModel.pageImageInfo(atIndex: infoContextPageIndex) {
                            PageInfoPanelView(viewModel: viewModel, pageIndex: infoContextPageIndex, info: info)
                        } else {
                            // 通常はここに来ない(ViewerViewModel.pageImageInfoCacheのコメント
                            // 参照。表示中ページの情報はloadCurrentSpreadの時点で取得を開始して
                            // いる)が、念のためのフォールバック。SwiftUIの通常のView更新経路の
                            // ため、取得が完了すれば自動的にPageInfoPanelViewへ切り替わる。
                            Text("Loading…")
                                .panelOutlinedContent()
                                .padding(16)
                        }
                    }
                    .panelSurfaceBackground(
                        preferences.overlaySurfaceStyle,
                        material: .regularMaterial,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .shadow(color: .black.opacity(0.25), radius: 16, y: 4)
                }
                .transition(.opacity)
                .zIndex(2)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toastMessage)
        // 拡大率そのものが変わるたびにアニメーションさせると、ピンチ操作中ずっと数字が
        // ふわふわして読みにくいため、出す/消すの切り替わりだけをアニメーションさせる。
        .animation(.easeInOut(duration: 0.15), value: zoomIndicatorPercent == nil)
        .animation(.easeInOut(duration: 0.15), value: showThumbnailGrid)
        .animation(.easeInOut(duration: 0.15), value: isShowingPageInfoPanel)
        .background(preferences.effectiveBackgroundColor)
        .background(WindowAccessor { window in
            guard hostWindow !== window else { return }
            hostWindowBox.window = window
            setUpWindowObservers(for: window)
        })
        .focusable()
        .focused($isFocused)
    }

    /// bodyのモディファイア連鎖のうち、ライフサイクル(onAppear/onDisappear)と
    /// onChangeをまとめたグループ(mainZStackのコメント参照。型チェックが長くかかりすぎる
    /// 不具合対策で、body全体を複数の独立した式に分割するうちの1段階)。
    ///
    /// 以前はこのクロージャの中に橋渡し処理・2つのNSEventローカルモニタ(スクロール/
    /// スワイプ/キー入力の監視、コンテキストメニュー起動クリックの位置監視)の実装を
    /// すべて直接書いていたが、body全体が1つの巨大な式としてSwiftUIの型推論に
    /// 掛かるため、Xcodeが「The compiler is unable to type-check this expression in
    /// reasonable time」を出すようになった(ユーザー報告)。個々のクロージャ内の式を
    /// 型注釈で分割しても改善しなかったため、この処理全体をprivateメソッド
    /// (handleOnAppear/makeScrollMonitor/makeContextClickMonitor)へ切り出し、
    /// ここからは`handleOnAppear()`という1つの関数呼び出しだけが見えるようにした。
    @ViewBuilder
    private func applyLifecycleHandlers<Content: View>(to content: Content) -> some View {
        content
            .onAppear {
                handleOnAppear()
            }
            // handleOnAppear/makeScrollMonitor/makeContextClickMonitorと同じ理由
            // (型チェックが長くかかりすぎる不具合対策)で、こちらもprivateメソッドへ
            // 切り出している。
            .onDisappear {
                handleOnDisappear()
            }
        // キー入力の検知はonAppear内のNSEventローカルモニタ(.keyDownケース)に統合したため、
        // 以前ここにあった.onKeyPressは削除した(矢印キーがそちらまで届かない不具合があり、
        // 二重に処理してしまうのを避けるため)。
        // ブックマークの追加/削除/名前変更のたびに、メニューバーの「ブックマーク」メニュー
        // 下部の一覧を最新の内容に更新する。
        .onChange(of: viewModel.bookmarks) { _, newValue in
            appState.updateCurrentBookmarks(newValue)
        }
        // サイドパネル下段(本の中身ブラウザ)が、ダブルクリックされた画像から「本の何ページ目か」
        // を特定するために参照するAppState.currentBookPagesを最新に保つ。並び替え・除外
        // (reloadLayoutData)でbook.pagesが差し替わるたびに追従させる必要がある
        // (AppState.currentBookPagesのコメント参照。MangaBookの==はidのみを見るため、
        // viewModel.bookを監視してもpagesの変化そのものは検知できず、pages自体を見る必要がある)。
        .onChange(of: viewModel.book.pages) { _, newValue in
            appState.updateCurrentBookPages(newValue)
        }
        // 表示・非表示の切り替わりに合わせて、パネルを閉じるクリックを拾う専用のNSEventモニタ
        // (thumbnailGridDismissMonitor)を付け外しする。
        .onChange(of: showThumbnailGrid) { _, newValue in
            if newValue {
                installThumbnailGridDismissMonitorIfNeeded()
            } else {
                removeThumbnailGridDismissMonitor()
            }
        }
        // スライドショー実行中/ルーペ表示中/表示モード/読み方向/拡大縮小モードが変わるたびに、
        // メニューバーの該当項目のチェックマークを最新の状態に更新する。
        .onChange(of: viewModel.isSlideshowActive) { _, _ in syncMenuCheckmarkState() }
        .onChange(of: viewModel.isLoupeActive) { _, isActive in
            syncMenuCheckmarkState()
            // 拡大鏡ON時に、既に自動表示されているツールバー/プログレスバー/サイドパネルが
            // あれば直ちに隠す(ユーザー要望: マウスが端に近づいたことによる自動表示が
            // 拡大鏡での閲覧を妨げないようにするため。特にサイドパネル)。次のマウス移動を
            // 待たずにここで即時反映する(updateAutoHiddenChromeVisibility/
            // ContentView.installSidePanelHoverMonitorIfNeededのガードは、あくまで
            // 「今後の自動表示を抑止する」だけで、既に表示中のものは閉じないため)。
            if isActive {
                hideAutoRevealedChromeNow()
                appState.isSidePanelRevealed = false
            }
        }
        .onChange(of: viewModel.displayMode) { _, _ in syncMenuCheckmarkState() }
        .onChange(of: viewModel.readingDirection) { _, _ in syncMenuCheckmarkState() }
        .onChange(of: viewModel.scalingMode) { _, _ in syncMenuCheckmarkState() }
        .onChange(of: viewModel.isContrastCorrectionEnabled) { _, _ in syncMenuCheckmarkState() }
        // isPageShiftLocked(「1ページだけ送る」のグレーアウト判定)はcurrentIndexにも依存する
        // ため、ページ送り自体でもメニューバーの状態を更新し直す必要がある。「現在のページが
        // ブックマーク済みかどうか」の判定にも使うため、appState.currentPageIndexも合わせて更新する。
        .onChange(of: viewModel.currentIndex) { _, newValue in
            appState.updateCurrentPageIndex(newValue)
            appState.updateCurrentVisiblePageSortKeys(currentVisiblePageSortKeys)
            syncMenuCheckmarkState()
            // 新しいページは必ず読み始め側の隅から表示する(beginPageEntryScroll参照)。
            beginPageEntryScroll()
        }
        // hasPartnerPageDisplayed(Layoutメニューの「見開き表示中は左右2ページ分の項目に分ける」
        // 判定)はcurrentImages.count(実際に表示中の枚数)にも依存するが、以前はcurrentIndexの
        // 変化でしかsyncMenuCheckmarkState()を呼んでいなかった。履歴から本を再開した直後は、
        // currentIndexが(前回終了時の値のまま)最初から確定している一方、その位置の実際の
        // 見開きペア画像(currentImages)は本を開くシーケンスの中で非同期に後から読み込まれるため、
        // currentIndex自体は変化せずcurrentImagesだけが1→2枚に変わることがある。この場合
        // 上のonChange(of: viewModel.currentIndex)が発火せず、Layoutメニューが「単一ページ」の
        // ままになってしまっていた(ユーザー報告: 起動して履歴から本を開いた直後、実際には
        // 見開き表示なのにLayoutメニューが単一ページ用の項目のままになる)。
        .onChange(of: viewModel.currentImages.count) { _, _ in
            appState.updateCurrentVisiblePageSortKeys(currentVisiblePageSortKeys)
            syncMenuCheckmarkState()
        }
        // 表示モードを切り替えた直後も、そのモードでの読み始め位置に合わせ直す
        // (「画面内に収める」へ切り替えた場合はscrollToPageCornerが何もしない)。
        .onChange(of: viewModel.scalingMode) { _, _ in
            scrollToPageCorner(atEnd: false)
        }
        // 本を開いたまま環境設定でピンチ拡大の上限が引き下げられたら、今の拡大率もそこまで下げる。
        .onChange(of: preferences.maxPinchZoomPercent) { _, _ in
            viewModel.clampPinchZoomToCurrentLimit()
        }
    }

    /// bodyのモディファイア連鎖のうち、シート表示をまとめたグループ
    /// (mainZStack/applyLifecycleHandlersのコメント参照)。
    @ViewBuilder
    private func applySheets<Content: View>(to content: Content) -> some View {
        content
            // 「ブックマークの編集」は、以前はここに.sheetとして表示していたが、
            // 「お気に入りの整理」ウインドウと見た目・操作感を揃えるため、独立ウインドウ
            // (Window("Edit Bookmarks", id: "editBookmarks"))へ変更した。表示自体は
            // showBookmarkEditor()がopenWindowで行う(BookmarkEditorWindow.swift参照)。
            // お気に入りへの登録(要望2)。登録先フォルダの選択・新規フォルダ作成・重複確認は
            // FavoriteFolderPickerView側で完結する。
            // 環境設定「閲覧中の動作」の「最初のページで」「最後のページで」が「毎回確認」の
            // ときに、境界に達したその場で残りの選択肢を選ばせるシート
            // (ViewerViewModel.pendingBoundaryPrompt / PageBoundaryChoiceSheet参照)。
            // シートを閉じるだけ(Esc・シート外のクリック)は「何もしない」と同じ結果になる。
            .sheet(item: $viewModel.pendingBoundaryPrompt) { direction in
                switch direction {
                case .backward:
                    PageBoundaryChoiceSheet<FirstPageBehavior>(titleKey: "This is the first page.") {
                        viewModel.performFirstPageBehavior($0)
                    }
                case .forward:
                    PageBoundaryChoiceSheet<LastPageBehavior>(titleKey: "This is the last page.") {
                        viewModel.performLastPageBehavior($0)
                    }
                }
            }
            // 右クリックの「本の書き出し」(OpenBookExportSheet参照)。
            .sheet(item: $openBookExport) { request in
                OpenBookExportSheet(
                    viewModel: request.viewModel,
                    format: request.format,
                    book: viewModel.book,
                    // 読み方向・見開きは、この本のDBの行に上書きが無いと環境設定の既定値に
                    // なってしまうので、画面で見えているとおりの値を渡す
                    // (BookExportViewModel.OpenBookDisplayStateのコメント参照)。
                    displayState: .init(
                        readingDirection: viewModel.readingDirection,
                        displayMode: viewModel.displayMode
                    ),
                    fixedDestination: request.fixedDestination,
                    // シークレットウインドウ・その場限りの本ではカバーを選ばせない
                    // (指定がDBに残ってしまうため。OpenBookExportSheet参照)。
                    allowsCoverSelection: !viewModel.skipsPersistence
                ) { didExport in
                    openBookExport = nil
                    guard didExport else { return }
                    finishOpenBookExport(format: request.format)
                }
            }
            // 「書き出したあとの動作」が「毎回確認」のときのシート。「最後のページで」の
            // 毎回確認と同じ部品・同じ見た目で、選択肢だけが違う。
            .sheet(isPresented: $isShowingExportCompletionPrompt) {
                PageBoundaryChoiceSheet<BookExportCompletionBehavior>(
                    titleKey: "The book has been exported."
                ) { choice in
                    isShowingExportCompletionPrompt = false
                    performExportCompletionBehavior(choice)
                }
            }
            .sheet(isPresented: $showFavoriteFolderPicker) {
                FavoriteFolderPickerView(book: viewModel.book, favoritesStore: favoritesStore) {
                    showToast(
                        String(
                            format: String(localized: "Added “%@” to Favorites", locale: preferences.effectiveLocale),
                            viewModel.book.title
                        )
                    )
                }
            }
    }

    /// bodyのモディファイア連鎖のうち、確認アラート・伝播範囲ダイアログをまとめたグループ
    /// (mainZStack/applyLifecycleHandlersのコメント参照)。
    @ViewBuilder
    private func applyLayoutAlerts<Content: View>(to content: Content) -> some View {
        // お気に入り一覧(要望4)。以前はここに.popover(isPresented:)でFavoritesListPopoverContent
        // (List+DisclosureGroup)を表示していたが、フォルダを開くたびにクリックが必要で
        // 使い勝手が良くなかったため、メニューバー側と同じくホバーでサブフォルダが展開する
        // ネイティブNSMenu(FavoritesNSMenuBridge)へ置き換えた。ボタンのクリック・ショートカット
        // のどちらもshowFavoritesListMenu()を呼ぶだけでよく、SwiftUI側の状態(.popoverのbinding)
        // は不要になったため、ここには何も無い(showFavoritesListMenu()のコメント参照)。
        // 環境設定「本を開く」の「開始ページ」が「問い合わせる」のときだけ、
        // 前回位置から再開するかどうかを尋ねる(ViewerViewModel.init参照)。
        content
        .alert(
            "Resume from where you left off?",
            isPresented: Binding(
                get: { viewModel.needsResumeConfirmation },
                set: { isPresented in
                    if !isPresented {
                        viewModel.confirmResumeFromLastPage(true)
                    }
                }
            )
        ) {
            Button("Start from Beginning") {
                viewModel.confirmResumeFromLastPage(false)
            }
            Button("Resume") {
                viewModel.confirmResumeFromLastPage(true)
            }
        }
        // レイアウト操作(3.2節。「レイアウト情報を削除する」を除く)の後に表示する、
        // 伝播範囲選択ダイアログ(3.3節)。ツールバー・コンテキストメニュー・メニューバーの
        // どの経路から操作しても、いったんpendingLayoutStateChangeへ「対象ページ・新しい状態」を
        // 詰めるだけの共通の仕組みにしているため、ダイアログ自体はここ1箇所だけで済む。
        .confirmationDialog(
            "Apply Layout Change To…",
            isPresented: Binding(
                get: { pendingLayoutStateChange != nil },
                set: { isPresented in
                    if !isPresented { pendingLayoutStateChange = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            if let pending = pendingLayoutStateChange {
                ForEach(availableScopes(forPageIndex: pending.pageIndex)) { scope in
                    Button(scope.titleKey) {
                        pendingLayoutStateChange = nil
                        Task {
                            await viewModel.setPageLayout(atIndex: pending.pageIndex, to: pending.state, scope: scope)
                            syncMenuCheckmarkState()
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingLayoutStateChange = nil
            }
        } message: {
            Text("Choose how far this layout change should apply.")
        }
        // 見開き表示中、ツールバー/お気に入りメニュー/キーボードショートカットからブックマークを
        // 追加しようとしたとき、環境設定「Adding Bookmarks in Spread View」が「実行するたびに
        // 尋ねる」の場合に表示する、左右どちらを対象にするかの確認ダイアログ(ユーザー報告)。
        // コンテキストメニュー(右クリック)からの追加はクリック位置で一意に決まるため、この
        // ダイアログは経由しない(contextMenuContent参照)。
        .confirmationDialog(
            "Which page do you want to add to Bookmarks?",
            isPresented: $isShowingBookmarkSideDialog,
            titleVisibility: .visible
        ) {
            Button("Left Page") {
                addBookmarkWithToast(atIndex: spreadLeftPageIndex)
            }
            Button("Right Page") {
                addBookmarkWithToast(atIndex: spreadRightPageIndex)
            }
            Button("Cancel", role: .cancel) {}
        }
        // 本の内容が置き換わった可能性がある場合の確認(設計コンセプト2.5節)。
        // ViewerViewModel.prepareBookが指紋の不一致を検出すると
        // pendingLayoutReplacementStatusがセットされる。ここではアプリ内DBのレイアウト設定
        // (BookLayoutSettings/PageLayoutOverride)を維持するか破棄するかだけを尋ね、
        // 「エクスポートしてから破棄する」の3択目はJSON入出力(6節)実装後のPhase4で追加する。
        .alert(
            "This Book's Contents May Have Changed",
            isPresented: Binding(
                get: { viewModel.pendingLayoutReplacementStatus != nil },
                set: { _ in }
            )
        ) {
            Button("Keep Existing Settings") {
                viewModel.resolveLayoutReplacement(applyExisting: true)
                syncMenuCheckmarkState()
            }
            Button("Discard Settings", role: .destructive) {
                viewModel.resolveLayoutReplacement(applyExisting: false)
                syncMenuCheckmarkState()
            }
        } message: {
            Text(
                "qooViewer detected that this book's files may have changed since its saved layout settings (reading direction, page order, single/spread page settings) were recorded. Keep the existing settings, or discard them and start fresh?"
            )
        }
        // 「現在の表示を基準に自動でレイアウトする」(3.1節)の実行前確認。本全体を上書きする
        // 操作のため必ず確認を挟む。既存の「除外」ページの扱い(保持/解除)の追加確認は、
        // 3.3節の伝播範囲選択ダイアログ側と同じくPhase2では簡略化し、常に「保持」として扱う
        // (LayoutAutoCalculator.recalculateが除外ページを計算対象に含めないことで実現している)。
        .alert(
            "Auto-Layout the Whole Book?",
            isPresented: $isShowingAutoLayoutConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Auto-Layout") {
                Task {
                    await viewModel.autoLayoutFromCurrentView()
                    syncMenuCheckmarkState()
                }
            }
        } message: {
            Text(
                "This recalculates the layout of the entire book, based on the page (or spread) currently displayed. This cannot be undone."
            )
        }
        // 画像のエクスポート機能(要望)。読み込み・結合・書き込みのいずれかで失敗した場合のみ表示する
        // (NSSavePanelをキャンセルした場合はexportImage自体が早期リターンするため、ここには来ない)。
        .alert(
            "Couldn't Export Image",
            isPresented: Binding(
                get: { imageExportErrorMessage != nil },
                set: { isPresented in
                    if !isPresented { imageExportErrorMessage = nil }
                }
            )
        ) {
            Button("OK") {}
        } message: {
            Text(imageExportErrorMessage ?? "")
        }
    }

    /// 見開き表示中、実際に2枚組でペア表示されているときの「相方ページ」のインデックス
    /// (currentIndex + 1)。単ページ表示中、または見開き中でも横長画像の自動単ページ化や
    /// EPUBの見開き位置指定により実際には1枚しか表示されていない場合はnil(この場合、
    /// currentIndex + 1が有効なページ番号であっても「今画面に見えているページ」ではないため
    /// 対象に含めない)。viewModel.currentImages.count(実際に表示中の枚数)で判定する。
    private var partnerPageIndex: Int? {
        viewModel.currentImages.count > 1 ? viewModel.currentIndex + 1 : nil
    }

    /// 今実際に画面に表示されているページのsortKey(単ページ表示なら1件、見開きで2ページとも
    /// 表示中ならpartnerPageIndexも含めて2件、読み順)。AppState.currentVisiblePageSortKeysへ
    /// 橋渡しする(サイドパネル下段のハイライト/自動追従に使う。AppState.swiftのコメント参照)。
    private var currentVisiblePageSortKeys: [String] {
        let pages = viewModel.book.pages
        guard pages.indices.contains(viewModel.currentIndex) else { return [] }
        var keys = [pages[viewModel.currentIndex].sortKey]
        if let partnerPageIndex, pages.indices.contains(partnerPageIndex) {
            keys.append(pages[partnerPageIndex].sortKey)
        }
        return keys
    }

    /// 見開き中、画面上「左」に表示されているページのインデックス(読み方向を反映)。
    /// partnerPageIndexがnil(実際には1枚しか表示していない)の場合はcurrentIndexを返す
    /// (呼び出し側はこの場合そもそも左右の選択を必要としないため、単に安全なフォールバック)。
    /// Layoutサブメニュー(contextMenuContent内)と同じ考え方(isRightToLeftならpartnerPageIndexが
    /// 画面左)だが、こちらはブックマーク追加の左右選択ダイアログ(isShowingBookmarkSideDialog)
    /// から使う。
    private var spreadLeftPageIndex: Int {
        guard let partnerPageIndex else { return viewModel.currentIndex }
        return viewModel.readingDirection == .rightToLeft ? partnerPageIndex : viewModel.currentIndex
    }

    /// spreadLeftPageIndexと対になる、画面上「右」に表示されているページのインデックス。
    private var spreadRightPageIndex: Int {
        guard let partnerPageIndex else { return viewModel.currentIndex }
        return viewModel.readingDirection == .rightToLeft ? viewModel.currentIndex : partnerPageIndex
    }

    /// コンテキストメニュー「情報を見る」(ユーザー要望)向け、右クリック位置(isLastContextClickOnLeftHalf)
    /// から一意に決まる対象ページのインデックス。spreadLeftPageIndex/spreadRightPageIndexと同じ考え方
    /// だが、こちらはクリックされた側(左半分なら左ページ、右半分なら右ページ)を返す。
    private var infoContextPageIndex: Int {
        isLastContextClickOnLeftHalf ? spreadLeftPageIndex : spreadRightPageIndex
    }

    /// 現在の見開き(単ページ表示中は1枚だけ)に、ブックマークが1件でも付いているかどうか。
    /// ツールバー・コンテキストメニューの追加/削除トグルボタンの見た目・文言・動作を
    /// 切り替えるために使う。以前はcurrentIndex(見開きの起点ページ)だけを見ていたが、
    /// 相方ページ(partnerPageIndex)だけにブックマークが付いている場合も「登録済み」として
    /// 扱ってほしいというユーザー要望により、両方を確認するようにした(ユーザーからの指示)。
    /// viewModel(@StateObject)のbookmarks/currentIndex/currentImagesを読むだけなので、
    /// いずれかが変化すればこのビューの再描画に合わせて自動的に最新の値になる。
    private var isCurrentPageBookmarked: Bool {
        if viewModel.bookmarks.contains(where: { $0.pageIndex == viewModel.currentIndex }) {
            return true
        }
        guard let partnerPageIndex else { return false }
        return viewModel.bookmarks.contains { $0.pageIndex == partnerPageIndex }
    }

    /// 現在表示中の本がお気に入りに登録済みかどうか。isCurrentPageBookmarkedと同じ用途だが、
    /// こちらはfavoritesStore(EnvironmentObject。上のプロパティ宣言のコメント参照)を読む。
    private var isCurrentBookFavorited: Bool {
        favoritesStore.isFavorited(bookID: viewModel.book.id)
    }

    /// 追加/削除トグルボタン用のツールバーアイコン。「未登録(追加できる状態)」のときは
    /// 他のツールバーボタンと同じ見た目(背景なし、通常の前景色のアウトライン版シンボル)、
    /// 「登録済み(削除できる状態)」のときは塗りつぶし版のシンボルに切り替えつつ、前景色・
    /// 背景色を反転させる(背景を前景色で塗りつぶし、アイコン自体は背景色にする)ことで、
    /// 他のボタンと視覚的にはっきり見分けが付くようにする(ユーザー要望の「白黒反転」)。
    /// Color.primary/背景色はライト/ダークモードのどちらでも正しく反転して見えるよう、
    /// 固定の黒白ではなくシステムの前景色・コントロール背景色を使っている。
    /// 反転表示の大きさ・角丸は、他のツールバーボタンと同じPanelIconButtonLabel
    /// (サイドパネルのボタンと共通)に合わせてある。
    @ViewBuilder
    private func toggleToolbarIcon(outlineSystemName: String, filledSystemName: String, isRegistered: Bool) -> some View {
        Image(systemName: isRegistered ? filledSystemName : outlineSystemName)
            .panelIconButtonLabel(isHighlighted: isRegistered)
    }

    private var toolbar: some View {
        // ボタンはサイドパネルのボタンと同じ見た目(枠なし・15ptのアイコン・32x28のタップ領域。
        // panelIconButtonLabel参照)に揃えてある(ユーザー要望)。ボタン自身が広めの余白を
        // 持つようになったぶん、以前(グループ内4pt/グループ間12pt)のままでは間延びして
        // 見えるため、グループ内は0pt・グループ間は8ptに詰めている。
        HStack(spacing: 8) {
            // ページ移動・ファイル移動のボタン群。ブラウザの「戻る」「進む」ボタンのように、
            // ファイル名表示(アドレスバー相当)より左側に配置する。

            // 次の画像/前の画像(見開き時は2枚、単ページ時は1枚移動。読み方向によって左右の意味が入れ替わる)
            HStack(spacing: 0) {
                Button {
                    viewModel.advance(forward: viewModel.readingDirection == .rightToLeft)
                } label: {
                    Image(systemName: "chevron.left.2")
                        .panelIconButtonLabel()
                }
                .buttonStyle(.borderless)
                .help(viewModel.readingDirection == .rightToLeft ? "Next Image" : "Previous Image")

                Button {
                    viewModel.advance(forward: viewModel.readingDirection == .leftToRight)
                } label: {
                    Image(systemName: "chevron.right.2")
                        .panelIconButtonLabel()
                }
                .buttonStyle(.borderless)
                .help(viewModel.readingDirection == .leftToRight ? "Next Image" : "Previous Image")
            }

            // 1枚だけ次の画像/前の画像(見開きのページの組み合わせがずれたときの調整用)。
            // EPUBが見開き内の配置(page-spread-left/right/center)を明示している場合、
            // この調整でその組み合わせを崩してしまわないよう無効化する
            // (詳細はViewerViewModel.isPageShiftLocked参照)。
            HStack(spacing: 0) {
                Button {
                    viewModel.shiftByOnePage(forward: viewModel.readingDirection == .rightToLeft)
                } label: {
                    Image(systemName: "chevron.left")
                        .panelIconButtonLabel()
                }
                .buttonStyle(.borderless)
                .help(viewModel.readingDirection == .rightToLeft ? "Next Image by One" : "Previous Image by One")

                Button {
                    viewModel.shiftByOnePage(forward: viewModel.readingDirection == .leftToRight)
                } label: {
                    Image(systemName: "chevron.right")
                        .panelIconButtonLabel()
                }
                .buttonStyle(.borderless)
                .help(viewModel.readingDirection == .leftToRight ? "Next Image by One" : "Previous Image by One")
            }
            .disabled(viewModel.isPageShiftLocked)

            // 前の本へ/次の本へ(同じフォルダ内の、同じ種類[アーカイブ/PDFファイルまたはフォルダ]の
            // 本の間を移動する。読み方向に関係なく、上が前、下が次。詳細はSiblingFinder参照)
            HStack(spacing: 0) {
                Button {
                    appState.openSibling(before: viewModel.book.sourceURL)
                } label: {
                    Image(systemName: "chevron.up")
                        .panelIconButtonLabel()
                }
                .buttonStyle(.borderless)
                .help("Previous Book")

                Button {
                    appState.openSibling(after: viewModel.book.sourceURL)
                } label: {
                    Image(systemName: "chevron.down")
                        .panelIconButtonLabel()
                }
                .buttonStyle(.borderless)
                .help("Next Book")
            }

            Spacer()

            // ファイル名表示。ブラウザのアドレスバーのように、ツールバー中央に配置する
            // (前後のSpacerが左右の残り幅を均等に分け合うことで中央寄せになる)。
            //
            // ユーザー要望: メタデータとしてタイトル(と著者)が登録されている本については、
            // ファイル名の代わりに「[著者] タイトル」/「タイトル」を表示する。未登録の本は
            // 従来どおりファイル名のまま(判定はViewerViewModel.displayTitle参照)。
            //
            // ユーザー要望: タイトルの右に「(現在のページ / 総ページ数)」を出す。
            // ページ番号の書き方(「12 / 240」)はプログレスバーのバッジ・ホバー表示と
            // 同じ文字列カタログの項目を使う(同じものを別の形で見せないため)。
            // 見開き表示中でも数字は1つ ―― 現在位置を表すのはcurrentIndexだけ、という
            // 扱いもプログレスバーと揃えてある。
            //
            // 総ページ数は除外(非表示)ページを取り除いた後の数(ViewerViewModel.pageCount)。
            // 画面に出ないページを数に入れると、プログレスバーの表示とも食い違う。
            HStack(spacing: 6) {
                Text(viewModel.displayTitle)
                    .font(.headline)
                    .lineLimit(1)

                if viewModel.pageCount > 0 {
                    Text("(\(viewModel.currentIndex + 1) / \(viewModel.pageCount))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        // ページを送るたびに幅が動いてタイトルが左右に揺れないよう、
                        // 数字の字幅を固定する。
                        .monospacedDigit()
                        .lineLimit(1)
                        // ウインドウが狭いときに削られるのはタイトルのほう。
                        // 短くて位置の手がかりになるこちらを残す。
                        .layoutPriority(1)
                }
            }
            // 中身がテキストだけのまとまりなので、すりガラスの面に対する縁取りは
            // このHStackへまとめて掛ける(CLAUDE.mdのPanelSurfaceの約束)。
            .panelOutlinedContent()

            Spacer()

            // 「現在の表示を基準に自動でレイアウトする」ボタン(設計コンセプト8.5節)。
            // ブックマーク追加・削除ボタンの左に配置する。本全体を上書きする操作のため、
            // 実行前に確認ダイアログ(isShowingAutoLayoutConfirmation)を挟む(3.1節)。
            Button {
                isShowingAutoLayoutConfirmation = true
            } label: {
                Image(systemName: "rectangle.split.2x1")
                    .panelIconButtonLabel()
            }
            .buttonStyle(.borderless)
            .help("Auto-Layout Based on Current View")

            // 「現在のブックマーク一覧を表示」「お気に入り一覧を表示」のボタンは廃止した。一覧の
            // 表示自体はメニューバー(「お気に入り」メニュー)・キーボードショートカット
            // (showBookmarkList/showFavoritesList)からは引き続き行える。
            // 追加・削除は、別々の2つのボタンではなく、登録状態に応じて見た目・動作が切り替わる
            // 1つのトグルボタンにまとめている(ユーザー要望)。登録済みのときは背景色と前景色を
            // 反転させる(toggleToolbarIcon参照)ことで、他のツールバーボタンと視覚的にも
            // はっきり見分けが付くようにする。
            Button {
                perform(.toggleBookmark)
            } label: {
                toggleToolbarIcon(
                    outlineSystemName: "bookmark",
                    filledSystemName: "bookmark.fill",
                    isRegistered: isCurrentPageBookmarked
                )
            }
            .buttonStyle(.borderless)
            .help(isCurrentPageBookmarked ? "Remove This Page from Bookmarks" : "Add This Page to Bookmarks")

            Button {
                perform(.toggleFavorite)
            } label: {
                toggleToolbarIcon(
                    outlineSystemName: "star",
                    filledSystemName: "star.fill",
                    isRegistered: isCurrentBookFavorited
                )
            }
            .buttonStyle(.borderless)
            .help(isCurrentBookFavorited ? "Remove This Book from Favorites" : "Add This Book to Favorites…")

            Button {
                perform(.showThumbnailGrid)
            } label: {
                Image(systemName: "square.grid.2x2")
                    .panelIconButtonLabel()
            }
            .buttonStyle(.borderless)
            .help("Show Page Grid")

            Button {
                viewModel.toggleSlideshow()
            } label: {
                Image(systemName: viewModel.isSlideshowActive ? "pause.fill" : "play.fill")
                    .panelIconButtonLabel()
            }
            .buttonStyle(.borderless)
            .help("Start/Stop Slideshow")
        }
        .padding(10)
    }

    /// ページ表示エリアを右クリックしたときのコンテキストメニュー。ページ移動・ブック移動を
    /// サブメニューにまとめ、見開き・読み方向・ブックマーク追加・スライドショー・フルスクリーンを
    /// 単独の項目として並べる。メニューバー(QooViewerApp.swiftのCommandGroup/CommandMenu)とは
    /// 異なり、ここではこのビュー自身の@StateObjectであるviewModelを直接参照できるため、
    /// チェックマークの更新にFocusedValueの値型変換のような回避策は不要
    /// (bodyがviewModelの@Publishedプロパティの変化のたびに再評価されるため)。
    /// 各アクションは、キーボードショートカットやメニューバーと同じ経路(perform(_:))を
    /// そのまま呼ぶことで、実装の重複や挙動のズレを防いでいる。
    @ViewBuilder
    private var contextMenuContent: some View {
        let isRightToLeft = viewModel.readingDirection == .rightToLeft

        Menu("Page Navigation") {
            Button("Move to Next") {
                perform(isRightToLeft ? .spatialLeft : .spatialRight)
            }
            Button("Move to Previous") {
                perform(isRightToLeft ? .spatialRight : .spatialLeft)
            }

            Divider()

            Button("Shift One Page to Next") {
                perform(isRightToLeft ? .shiftOnePageLeft : .shiftOnePageRight)
            }
            .disabled(viewModel.isPageShiftLocked)
            Button("Shift One Page to Previous") {
                perform(isRightToLeft ? .shiftOnePageRight : .shiftOnePageLeft)
            }
            .disabled(viewModel.isPageShiftLocked)

            Divider()

            Button("Move to First") {
                perform(.firstPage)
            }
            Button("Move to Last") {
                perform(.lastPage)
            }
        }

        Menu("Book Navigation") {
            Button("Go to Previous Book") {
                perform(.previousBook)
            }
            Button("Go to Next Book") {
                perform(.nextBook)
            }
        }

        Divider()

        Toggle(
            "Spread",
            isOn: Binding(
                get: { viewModel.displayMode == .spread },
                set: { _ in perform(.toggleDisplayMode) }
            )
        )


        Toggle(
            "Right-to-Left",
            isOn: Binding(
                get: { viewModel.readingDirection == .rightToLeft },
                set: { _ in perform(.toggleReadingDirection) }
            )
        )


        Divider()

        // ユーザー要望: 画像を右クリックしたときにもページ一覧(サムネイルグリッド)を開けるように
        // する。ツールバーの田の字ボタン・メニューバー「表示」→「ページ一覧を表示」・キーボード
        // ショートカットとまったく同じ経路(perform(.showThumbnailGrid))を通るため、開いた
        // パネルの閉じ方(外側クリック/同じ操作の再実行)も他の経路と揃う。
        // 置き場所は、お気に入りグループのすぐ上に独立した1グループとして(ユーザーの指示)。
        Button("Show Page Grid") {
            perform(.showThumbnailGrid)
        }

        Divider()

        // お気に入りグループ・ブックマークグループ・レイアウトグループの並び順、および文言は
        // メニューバーの「編集」(Edit)メニュー内の対応するグループ(QooViewerApp.swiftの
        // CommandGroup(after: .pasteboard))に合わせている(お気に入り→ブックマーク→
        // レイアウトの順)。追加・削除は登録状態に応じて文言・動作が切り替わる1つのトグル項目に
        // まとめている(ツールバーと同じ考え方。ユーザー要望)。
        Button(isCurrentBookFavorited ? "Remove This Book from Favorites" : "Add This Book to Favorites…") {
            perform(.toggleFavorite)
        }
        .disabled(viewModel.skipsPersistence)
        Menu("Favorites List") {
            FavoritesMenuContent(
                favoritesStore: favoritesStore,
                onOpen: { favorite in openFavoriteAccordingToPreference(favorite) }
            )
        }

        Divider()

        // ユーザー報告: 見開き左の画像を右クリックして「現在のページをブックマークに追加」
        // しても見開き右がブックマークされてしまう。見開き表示中(実際に2ページ組で
        // ペア表示されているとき)は、Layoutサブメニューと同じくクリック位置
        // (isLastContextClickOnLeftHalf)で対象を一意に決め、「左のページ」「右のページ」を
        // 明示したラベルで、そのページ単体を追加/削除する(toggleBookmark(atIndex:)参照)。
        // 単一ページ表示中(見開きのペアがEPUB仕様上の空白ページの場合も含む)は、対象が
        // 1ページしかないため従来通りの汎用トグルのままにする(bug報告の明示的な要望)。
        if let partnerPageIndex {
            let leftPageIndex = isRightToLeft ? partnerPageIndex : viewModel.currentIndex
            let rightPageIndex = isRightToLeft ? viewModel.currentIndex : partnerPageIndex
            let clickedPageIndex = isLastContextClickOnLeftHalf ? leftPageIndex : rightPageIndex
            let isClickedPageBookmarked = viewModel.bookmarks.contains { $0.pageIndex == clickedPageIndex }
            Button(
                bookmarkContextMenuTitle(isLeft: isLastContextClickOnLeftHalf, isBookmarked: isClickedPageBookmarked)
            ) {
                toggleBookmark(atIndex: clickedPageIndex)
            }
            .disabled(viewModel.skipsPersistence)
        } else {
            Button(isCurrentPageBookmarked ? "Remove This Page from Bookmarks" : "Add This Page to Bookmarks") {
                perform(.toggleBookmark)
            }
            .disabled(viewModel.skipsPersistence)
        }
        // メニューバー側のBookmark Listサブメニュー(QooViewerApp.swift)と同じ内容。
        Menu("Bookmark List") {
            if appState.currentBookmarks.isEmpty {
                Text("(No Bookmarks)")
            } else {
                ForEach(appState.currentBookmarks, id: \.id) { bookmark in
                    Button("\(bookmark.name) (\(bookmark.pageIndex + 1))") {
                        appState.jumpToBookmark?(bookmark)
                    }
                }
            }
        }

        Divider()

        // レイアウト操作(設計コンセプト8.4節)。メニューバー版(QooViewerApp.swiftの
        // 「編集」(Edit)メニュー内のLayoutグループ)とほぼ同じ内容だが、こちらはこのビュー自身の
        // viewModelを直接参照できるため、FocusedValue/AppStateのブリッジを経由せず直接呼び出せる。
        //
        // 設計コンセプト8.4節の想定どおり、見開き表示中はこのメニューを開いた右クリックの
        // 位置(左右どちらのページの上か)によって対象を一意に決める。メニューバー版は
        // キーボードショートカット等クリック位置の情報が無い経路からも開けるため、そちらは
        // 引き続き「左のページ」「右のページ」を両方並べる形のままにしている
        // (コンテキストメニューだけがこの位置判定の恩恵を受けられる、という設計上の
        // 非対称性はそのため意図的なもの)。
        // isLastContextClickOnLeftHalfの検知の仕組みはcontextClickMonitor/
        // PageAreaFrameAccessorのコメント参照。
        Menu("Layout") {
            Button("Auto-Layout Based on Current View") {
                isShowingAutoLayoutConfirmation = true
            }

            Divider()

            if let partnerPageIndex {
                // 読み方向によって、画面上の左右とcurrentIndex/partnerPageIndexの前後関係が
                // 入れ替わる(orderedCurrentImagesと同じ考え方。isRightToLeftはこの
                // contextMenuContent冒頭で既に定義済みのものを再利用する)。
                let leftPageIndex = isRightToLeft ? partnerPageIndex : viewModel.currentIndex
                let rightPageIndex = isRightToLeft ? viewModel.currentIndex : partnerPageIndex

                layoutStateMenuItems(forPageIndex: isLastContextClickOnLeftHalf ? leftPageIndex : rightPageIndex)
            } else {
                layoutStateMenuItems(forPageIndex: viewModel.currentIndex)
            }
        }
        // DBへ書かない本(シークレットウインドウ、またはその場限りの本)ではレイアウトを
        // 保存できないので、サブメニューごと無効にする。
        .disabled(viewModel.skipsPersistence)

        Divider()

        // 画像のエクスポート機能(要望)。表示内容の切替はLayoutサブメニューと同じ考え方だが、
        // こちらは単一ページ表示中(partnerPageIndexがnil)は選択の余地が無いため「このページを
        // エクスポート」の1件のみとし、見開き表示中はクリック位置(isLastContextClickOnLeftHalf)で
        // 「左のページをエクスポート」「右のページをエクスポート」のどちらか一方のみを出し分けた
        // うえで、「見開きを結合してエクスポート」を両方の場合に共通で並べる(要望どおり)。
        Menu("Export Image") {
            if let partnerPageIndex {
                let leftPageIndex = isRightToLeft ? partnerPageIndex : viewModel.currentIndex
                let rightPageIndex = isRightToLeft ? viewModel.currentIndex : partnerPageIndex
                if isLastContextClickOnLeftHalf {
                    Button("Export Left Page…") {
                        exportImage(.singlePage(index: leftPageIndex))
                    }
                } else {
                    Button("Export Right Page…") {
                        exportImage(.singlePage(index: rightPageIndex))
                    }
                }
                Button("Combine Spread and Export…") {
                    exportImage(.mergedSpread(leftIndex: leftPageIndex, rightIndex: rightPageIndex))
                }
            } else {
                Button("Export This Page…") {
                    exportImage(.singlePage(index: viewModel.currentIndex))
                }
            }
        }

        // ユーザー要望: いま開いている本を、そのまま1冊まるごと書き出す。
        //
        // File メニューの「EPUB/PDF/CBZの書き出し」ウインドウとは対象の決め方が違う。
        // あちらは「レイアウト・ブックマーク・メタデータのいずれかを持つ本」の一覧から選ぶが、
        // ここはその有無に関わらず、いま開いている本をそのまま書き出す(ユーザーの明示的な指示)。
        // 保存先を環境設定「レイアウト」で固定してあれば何も尋ねずに書き出し、決めていなければ
        // 保存先とオプションだけの小さなシートを出す(OpenBookExportSheet参照)。
        Menu("Export Book") {
            ForEach(BookExportFormat.allCases) { format in
                Button(format.menuTitleKey) {
                    startOpenBookExport(format: format)
                }
            }
        }
        // 書き出しが二重に始まらないように、進行中は閉じておく。
        //
        // 画像を直接開いた「その場限りの本」(MangaBook.BookOrigin.imageFiles)も対象外にする。
        // あの本のsourceURLは渡された画像のうちの**1枚目**でしかなく、書き出しは
        // BookLoader.load(from: sourceURL)で本を読み直すため、5枚開いていても1ページだけの
        // ファイルが黙って出来上がってしまう(idも実在するパスではない)。項目を消さずに
        // グレーアウトするのは、このアプリで「その場限りの本・シークレットウインドウでは
        // 使えない操作」を示す共通の作法(AppState.isPrivateWindowのコメント参照)。
        // シークレットウインドウの普通の本は書き出せる ―― 書き出し自体は何も記録しないため。
        .disabled(openBookExport != nil || viewModel.book.isTransient)

        // ユーザー要望: 右クリックしたページの画像ファイル情報(ファイル名・フォーマット・
        // 解像度・色情報・ファイルサイズ、いずれもヘッダーから分かる範囲)を表示する。対象ページの
        // 特定は上のExport Imageサブメニューと同じ考え方(isLastContextClickOnLeftHalfで
        // クリック位置から一意に決める)。以前はサブメニュー内に「ラベル: 値」を1行ずつ
        // 並べていたが、ラベルの文字数がまちまちで値の開始位置が揃わず読みづらいという指摘
        // (ユーザー報告)を受け、Finderの「情報を見る」のように値の先頭が揃うオーバーレイ
        // パネル(PageInfoPanelView、mainZStack参照)に置き換えた。NSMenu項目はプレーンな
        // 文字列1本ずつしか持てず列揃えができないための変更。SwiftUIの.popoverはウインドウの
        // 外にはみ出す吹き出しとして表示され意図と異なる(ユーザー報告)ため使っていない。
        Button("Get Info") {
            isShowingPageInfoPanel = true
        }

        Divider()

        // ユーザー要望: 現在の本(ファイルまたはフォルダ)をFinderで開く。
        // ファイルメニュー(QooViewerApp.swift)と同じ実装(AppState.revealCurrentBookInFinder)を
        // 共有する。
        Button("Show in Finder") {
            appState.revealCurrentBookInFinder()
        }

        Divider()

        Toggle(
            "Slideshow",
            isOn: Binding(
                get: { viewModel.isSlideshowActive },
                set: { _ in perform(.toggleSlideshow) }
            )
        )

        Toggle(
            "Loupe",
            isOn: Binding(
                get: { viewModel.isLoupeActive },
                set: { _ in perform(.toggleLoupe) }
            )
        )

        Toggle(
            "Full Screen",
            isOn: Binding(
                get: { isFullScreen },
                set: { _ in hostWindow?.toggleFullScreen(nil) }
            )
        )
    }

    /// レイアウトサブメニュー(コンテキストメニュー・メニューバー共通の構成)の、1ページ分の
    /// 項目群(設計コンセプト3.2節)。「レイアウト情報を削除する」は、既にそのページへ
    /// レイアウト上書きが設定されている場合のみ表示する。
    @ViewBuilder
    private func layoutStateMenuItems(forPageIndex pageIndex: Int) -> some View {
        Button("Set as Single Page") {
            pendingLayoutStateChange = PendingLayoutStateChange(pageIndex: pageIndex, state: .single)
        }
        Button("Set as Spread Right Page") {
            pendingLayoutStateChange = PendingLayoutStateChange(pageIndex: pageIndex, state: .spreadRight)
        }
        Button("Set as Spread Left Page") {
            pendingLayoutStateChange = PendingLayoutStateChange(pageIndex: pageIndex, state: .spreadLeft)
        }
        Button("Set as Excluded (Hidden)") {
            pendingLayoutStateChange = PendingLayoutStateChange(pageIndex: pageIndex, state: .excluded)
        }
        if viewModel.hasPageLayoutOverride(atIndex: pageIndex) {
            Divider()
            Button("Delete Layout Info") {
                viewModel.clearPageLayout(atIndex: pageIndex)
                syncMenuCheckmarkState()
            }
        }
    }

    /// 読み方向(右開き/左開き)を反映した表示順の画像配列。
    /// pageArea と showActualSizeWindow の両方で同じ並び替えロジックが必要なため、
    /// ロジックの重複(将来どちらかだけ直し忘れるバグの元)を避けるために1箇所にまとめている。
    private var orderedCurrentImages: [CGImage] {
        viewModel.readingDirection == .rightToLeft
            ? Array(viewModel.currentImages.reversed())
            : viewModel.currentImages
    }

    /// pageAreaが実際に描画するスロット列(画面上の左→右の順)。
    ///
    /// 通常は orderedCurrentImages をそのまま実画像スロットへ変換するだけだが、1枚だけ
    /// 表示中で、そのページ自身にEPUB/DB由来の明示的な見開き左右指定があるとき
    /// (viewModel.currentSoleImageForcedSpreadPosition)は、EPUB Reading Systems 3.3
    /// 6.1.4節「page-spread-left/rightの指定は、相方が見つからない場合でも空白ページを
    /// 挿入してでも尊重しなければならない」に合わせ、指定側に実画像・反対側に空白を配置する
    /// (qooViewerの画像ビューアをEPUB出力前のプレビューとして機能させるための対応)。
    ///
    /// currentSoleImageForcedSpreadPositionが返す.left/.rightは画面上の絶対位置を表す
    /// (EPUB仕様のpage-spread-left/right自体がそうであり、DB由来のPageLayoutState.
    /// spreadLeft/spreadRightも常に画面上の左右と一致させる設計にしているため。
    /// ViewerViewModel側のコメント参照)。そのためここでも読み方向による変換は不要で、
    /// .leftならそのまま画面左に実画像・画面右に空白、という単純な対応でよい
    /// (orderedCurrentImagesは1要素の配列を反転しても変わらないため、この時点で
    /// 画像自体は既に正しい要素になっている)。
    private var orderedCurrentSlots: [SpreadPageSlot] {
        slots(forOrderedImages: orderedCurrentImages)
    }

    /// 高解像度ソース(viewModel.highResolutionSourceImages、currentImagesより高解像度。
    /// ViewerViewModel.scheduleHighResolutionSourceLoad参照)を、表示順に並べたスロット列。
    /// 拡大鏡(ルーペ)のサンプリング元と、ピンチ拡大中のページ本体の描画元の両方で使う。
    /// currentImagesと同じ枚数だけ揃っていればそちらを、まだ揃っていない(取得中/失敗)場合は
    /// orderedCurrentSlots(表示用の画像)にフォールバックする。空白スロットの挿入ロジックは
    /// orderedCurrentSlotsと共通(slots(forOrderedImages:)参照)なので、返る配列の要素数と
    /// 空白の位置は必ずorderedCurrentSlotsと一致する(renderSlots(for:)がその前提に依存する)。
    private var orderedHighResolutionSlots: [SpreadPageSlot] {
        guard viewModel.highResolutionSourceImages.count == viewModel.currentImages.count,
              !viewModel.highResolutionSourceImages.isEmpty
        else {
            return orderedCurrentSlots
        }
        let orderedSourceImages = viewModel.readingDirection == .rightToLeft
            ? Array(viewModel.highResolutionSourceImages.reversed())
            : viewModel.highResolutionSourceImages
        return slots(forOrderedImages: orderedSourceImages)
    }

    /// ページ本体を実際に描画するときに使うスロット列。ピンチ拡大中は、より高解像度の
    /// ソースがあればそれに差し替える(表示用画像は長辺4096px上限でデコードされているため、
    /// そのまま数倍に引き伸ばすと粗くなる。ImageDecoder参照)。
    ///
    /// **レイアウトの計算には決してこちらを使わないこと。** 各スロットの表示幅・contentSize・
    /// renderScaleは必ず表示用画像(orderedCurrentSlots)から求める必要がある。高解像度版は
    /// 画素数そのものが違うため、そちらでレイアウトすると「拡大縮小しない」モードの原寸表示が
    /// 高解像度版の読み込み完了と同時に飛び跳ねてしまう(縦横比は同じなので、他のモードでは
    /// 結果的に同じ表示になるが、モードによって意味が変わる作りは避ける)。
    ///
    /// 差し替え後も要素数と空白スロットの位置は元と一致する(orderedHighResolutionSlots参照)
    /// ため、呼び出し側は元のスロット列と同じ添字でそのまま引ける。
    private func renderSlots(for orderedSlots: [SpreadPageSlot]) -> [SpreadPageSlot] {
        guard viewModel.pinchZoomFactor > 1 else { return orderedSlots }
        let highResolution = orderedHighResolutionSlots
        guard highResolution.count == orderedSlots.count else { return orderedSlots }
        return highResolution
    }

    /// 拡大鏡(ルーペ)が実際に使う「スロット列」と「各スロットの表示幅」の組。見開き中に実画像が
    /// 2枚とも表示されている場合は、境目をまたいだ拡大ができるよう、2枚を結合した1枚の高解像度
    /// 画像(viewModel.loupeCombinedSourceImage、ViewerViewModel.scheduleHighResolutionSourceLoad参照)を
    /// 単一のスロットとして返す(ユーザー報告: 拡大鏡が見開きの境目をまたげない)。単ページ表示中・
    /// EPUB由来の空白スロットを含む見開き中(displaySlots.count != 2相当、currentImages.count != 2
    /// で判定)は、従来通りページごとに別々のスロットとして扱う。
    ///
    /// pageArea(GeometryReader)のローカル変数に依存する値(orderedSlots・スケール後の表示幅)を
    /// 引数で受け取る通常のSwift関数にしてある。同じ処理をpageArea内のSwiftUI ViewBuilder
    /// クロージャに直接(if/elseの代入文として)書くと、SwiftUIの結果ビルダーがView生成の
    /// buildEitherとして解釈しようとしてコンパイルエラーになるため、分岐そのものをViewBuilder
    /// コンテキストの外に出す必要がある。
    private func loupeLayout(
        for orderedSlots: [SpreadPageSlot],
        referenceHeight: CGFloat,
        scale: CGFloat,
        mirrorAspectRatio: CGFloat
    ) -> (slots: [SpreadPageSlot], slotWidths: [CGFloat]) {
        let displaySlotWidths = orderedSlots.map {
            displayWidth(for: $0, atHeight: referenceHeight, mirrorAspectRatio: mirrorAspectRatio) * scale
        }
        if viewModel.currentImages.count == 2, let combined = viewModel.loupeCombinedSourceImage {
            return ([.image(combined)], [displaySlotWidths.reduce(0, +)])
        }
        return (orderedHighResolutionSlots, displaySlotWidths)
    }

    /// 表示順(画面上の左→右)に並んだ画像配列から、見開きスロット列を組み立てる共通ロジック。
    /// orderedCurrentSlots/orderedHighResolutionSlotsの両方で使う(orderedCurrentSlotsのコメント
    /// 参照。空白スロットの挿入条件はどちらも同じ画像枚数・同じcurrentSoleImageForcedSpreadPosition
    /// に基づくため、対象の画像配列だけを差し替えて共通化できる)。
    private func slots(forOrderedImages images: [CGImage]) -> [SpreadPageSlot] {
        guard images.count == 1,
              let position = viewModel.currentSoleImageForcedSpreadPosition,
              let onlyImage = images.first else {
            return images.map { .image($0) }
        }
        switch position {
        case .left: return [.image(onlyImage), .blank]
        case .right: return [.blank, .image(onlyImage)]
        case .center: return [.image(onlyImage)]
        }
    }

    private var pageArea: some View {
        GeometryReader { geo in
            let orderedSlots = orderedCurrentSlots
            let referenceHeight = referenceHeight(for: orderedSlots)
            let contentSize = totalContentSize(for: orderedSlots, referenceHeight: referenceHeight)
            // ピンチ拡大(viewModel.pinchZoomFactor)は、そのモードでの通常の倍率にそのまま
            // 掛けるだけにしてある。こうすることで、以降のレイアウト ― 各スロットの表示幅、
            // ScrollViewの中身の大きさ、拡大鏡のサンプリング位置 ― はすべて従来どおり
            // このscaleを見るだけでよく、拡大への追従が自動的に効く。
            let scale = renderScale(contentSize: contentSize, containerSize: geo.size)
                * viewModel.pinchZoomFactor
            // 空白スロット(orderedCurrentSlotsのコメント参照)の幅は、同じ見開き内にある
            // 実画像のアスペクト比をそのまま流用する(相方が実在すればこのくらいの幅になる
            // はず、という近似。実際の本の見開きで白紙ページが対向ページと同じ判型になるのに
            // 近い見た目にするため)。
            let mirrorAspectRatio = referenceAspectRatio(for: orderedSlots)

            // 拡大鏡(ルーペ)が実際に使うスロット列・各スロットの表示幅。GeometryReaderの
            // ローカル変数(orderedSlots/referenceHeight/scale/mirrorAspectRatio)に依存するため
            // pageArea外の独立したcomputed varには切り出せず、ここで計算する。if/elseの分岐を
            // 素の代入文としてViewBuilderのクロージャ内に直接書くと、SwiftUIの結果ビルダーが
            // これをView生成のbuildEitherとして解釈しようとしてコンパイルエラーになるため、
            // 分岐自体は通常のSwift関数(loupeLayout(for:referenceHeight:scale:mirrorAspectRatio:))
            // に切り出し、ここでは単純な関数呼び出しの代入文として扱う。
            let loupeLayout = loupeLayout(
                for: orderedSlots,
                referenceHeight: referenceHeight,
                scale: scale,
                mirrorAspectRatio: mirrorAspectRatio
            )

            // 描画にだけ使うスロット列(ピンチ拡大中は高解像度版に差し替わる。renderSlots(for:)
            // 参照)。幅・高さの計算には引き続き表示用のorderedSlotsを使う。
            let renderSlots = renderSlots(for: orderedSlots)

            let imagesRow = HStack(spacing: 0) {
                ForEach(Array(orderedSlots.enumerated()), id: \.offset) { index, slot in
                    let width = displayWidth(for: slot, atHeight: referenceHeight, mirrorAspectRatio: mirrorAspectRatio)
                    switch renderSlots[index] {
                    case .image(let image):
                        Image(decorative: image, scale: 1)
                            .interpolation(preferences.interpolationQuality.swiftUIInterpolation)
                            .resizable()
                            .frame(width: width * scale, height: referenceHeight * scale)
                    case .blank:
                        // EPUB仕様の「相方が見つからない場合の空白ページ挿入」を再現する
                        // プレースホルダー。実際の本の白紙ページに近い見た目にするため、
                        // 環境設定の背景色に関わらず白で塗る(orderedCurrentSlots参照)。
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: width * scale, height: referenceHeight * scale)
                    }
                }
            }
            // 拡大鏡(ルーペ)。imagesRow自身に重ねることで、画面に収めるモードでの中央寄せ・
            // 横幅フィット/拡大縮小しないモードでのScrollView内スクロールのどちらでも、
            // SwiftUIのレイアウトが自動的に画像そのものと同じ位置・サイズに揃えてくれる
            // (LoupeOverlayView.swift参照)。
            .overlay {
                if viewModel.isLoupeActive {
                    LoupeOverlayView(
                        slots: loupeLayout.slots,
                        slotWidths: loupeLayout.slotWidths,
                        contentHeight: referenceHeight * scale,
                        magnification: CGFloat(preferences.loupeMagnificationPercent / 100),
                        diameter: preferences.loupeDiameter,
                        onDismiss: { viewModel.toggleLoupe() }
                    )
                }
            }

            // ScrollViewの中身(documentView)の大きさ。スクロールの可動範囲と、ピンチ拡大の
            // 位置合わせ(scrollTarget(for:metrics:))の両方がこの値を前提にするため、
            // 計算は1か所(scrollContentSize(contentSize:scale:viewport:))にまとめてある。
            let scrollContentSize = scrollContentSize(
                contentSize: contentSize, scale: scale, viewport: geo.size
            )

            ZStack {
                // 「画面内に収める」でも、ピンチ拡大中は画像が画面からはみ出すため
                // ScrollViewが要る(isPageAreaScrollable参照)。
                if !isPageAreaScrollable {
                    imagesRow
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
                } else {
                    ScrollView(scrollAxes) {
                        imagesRow
                            .frame(width: scrollContentSize.width, height: scrollContentSize.height)
                            // スクロール送り(scrollByOneScreen等)が現在位置と可動範囲を正確に
                            // 知るために、裏のNSScrollViewを控えておく(ScrollViewAccessor参照)。
                            // ScrollViewの**内側**(スクロールされる中身)に置く必要がある。
                            // 外側に付けると、祖先をたどってもNSScrollViewには行き当たらない。
                            .background(
                                ScrollViewAccessor(
                                    onResolve: {
                                        scrollGeometryBox.scrollView = $0
                                        // 「画面内に収める」をピンチ拡大したことでScrollViewが
                                        // **新しく現れた**場合、documentViewの大きさは購読を
                                        // 始める前に既に確定しているため、frameDidChangeが
                                        // 一度も来ない。この経路でも位置合わせを試みておく
                                        // (予約が無ければ何もしないので、通常の更新のたびに
                                        // 呼ばれても害はない)。
                                        applyPendingZoomAnchorIfNeeded()
                                    },
                                    onDocumentFrameChange: { handleDocumentFrameChange() }
                                )
                            )
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }

                // クリックでのページ送り(画面内に収めるモードのみ。他のモードはスクロール操作を優先する)
                //
                // 以前はSwiftUIのButtonで実装していたが、SwiftUIのNSHostingViewは
                // acceptsFirstMouse(for:)をtrueで実装しているため、このウインドウが
                // キーウインドウでない状態でここをクリックすると、ウインドウをアクティブに
                // するのと同時にボタンのアクションも発火してしまっていた。これにより、
                // 他のウインドウへフォーカスを戻す/移すためにこのウインドウをクリックした
                // だけのつもりが、意図せずページが送られてしまう不具合があった。
                // ClickZoneArea(下のNSViewRepresentable)を使い、素のNSViewで
                // acceptsFirstMouse(for:)を明示的にfalseにすることで、macOS標準の
                // 「非アクティブウインドウへの最初のクリックはウインドウをアクティブにする
                // だけで、そのクリック自体は無視する」という挙動に戻している
                // (詳細はClickZoneView参照)。
                // 素のNSViewのためSwiftUIのフォーカス管理の対象にもならず、以前Buttonに
                // 付けていた.focusable(false)(矢印キーがボタン間のフォーカス移動に
                // 奪われないようにするための対処)も不要になった。
                HStack(spacing: 0) {
                    // 素のNSViewはSwiftUIに対して「これくらいが望ましい」というサイズの
                    // 手がかり(intrinsicContentSize)を持たないため、以前のButton版と同じく
                    // 明示的にmaxWidth/maxHeightを.infinityにして、左右それぞれが利用可能な
                    // 領域いっぱいに広がるようにする(指定しないと、意図しない小さな
                    // ヒットテスト領域になってしまう)。
                    ClickZoneArea(
                        onClick: { button, modifiers in
                            perform(clickAction(button: button, zone: .leftHalf, modifiers: modifiers))
                        },
                        onGesture: { button, direction, modifiers in
                            perform(dragAction(button: button, direction: direction, modifiers: modifiers))
                        },
                        isDragScrollEnabled: isPageAreaScrollable
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    ClickZoneArea(
                        onClick: { button, modifiers in
                            perform(clickAction(button: button, zone: .rightHalf, modifiers: modifiers))
                        },
                        onGesture: { button, direction, modifiers in
                            perform(dragAction(button: button, direction: direction, modifiers: modifiers))
                        },
                        isDragScrollEnabled: isPageAreaScrollable
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // isClickZoneArmed: ウェルカム画面からのダブルクリックの2回目のクリックを
                // 読み捨てるため、本を開いた直後の一定時間はヒットテスト自体を無効にする
                // (詳細はisClickZoneArmedのコメント参照)。
                // 拡大鏡(ルーペ)表示中は、クリックをページ送りではなく拡大鏡を閉じる操作に
                // 使いたい(ユーザー要望)。ClickZoneAreaはimagesRow(のoverlayとして重ねている
                // LoupeOverlayView)よりもZStack内で後ろに宣言されているためヒットテストの
                // 優先度が高く、何もしないとクリックがここで奪われてLoupeOverlayView側の
                // mouseDown(拡大鏡を閉じる処理)まで届かない。拡大鏡表示中はここのヒット
                // テスト自体を無効化し、下にあるLoupeOverlayViewへクリックを通す。
                // 以前は「画面内に収める」モードでしかクリックゾーンを有効にしていなかったが、
                // スクロールするモードでもクリックでスクロール送り(1画面分下へ+次のページ)が
                // できるようにしたため、そのモードで実際に操作が割り当てられているかどうかで
                // 判定する(cooViewerもノースケール/見開き分割で左右クリックに
                // 「1画面分下へ+次のページ」を既定で割り当てている。
                // KeyBindingStore.defaultScrollableMouseBindings参照)。
                .allowsHitTesting(
                    isClickZoneArmed && !viewModel.isLoupeActive && hasClickZoneAction
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // コンテキストメニューの右クリック位置判定(設計コンセプト8.4節)のために、
        // pageArea自身のウインドウ座標系でのフレームを常に最新に保っておく
        // (contextClickMonitor/PageAreaFrameAccessor参照)。.backgroundなので、
        // pageAreaと全く同じ位置・サイズになる(ヒットテストやクリック処理には一切影響しない)。
        .background(
            PageAreaFrameAccessor { frame in
                pageAreaFrameInWindow = frame
            }
        )
    }

    /// 見開き内の各スロットを並べるときの基準の高さ(画素単位)。
    ///
    /// 見開き表示で左右のページの元画像の解像度が異なる(スキャン品質がページごとに
    /// バラバラな本などでよくある)場合でも、実際の本のように両ページの物理的な高さを
    /// 揃えて表示したい。画像そのものの画素数をそのまま使うと、解像度が低い方の画像は
    /// 相対的に小さく表示されてしまう(拡大されているように見えない)ため、含まれる
    /// 画像のうち最大の高さを基準にし、他の画像(空白スロットを含む)はアスペクト比を
    /// 保ったままその高さに合わせた幅で計算する。
    ///
    /// pageArea(GeometryReader内)だけでなく、ピンチ拡大の位置合わせ(currentPageLayoutMetrics)
    /// からも同じ計算が必要になるため、関数として切り出してある。
    private func referenceHeight(for slots: [SpreadPageSlot]) -> CGFloat {
        slots.compactMap { slot -> CGFloat? in
            if case .image(let image) = slot { return CGFloat(image.height) }
            return nil
        }.max() ?? 0
    }

    /// referenceHeight(見開き内で最大の高さ)に揃えたときの、このスロットのアスペクト比を
    /// 保った幅。単ページ表示(画像が1枚だけ、かつそれ自身が基準)のときはimage.widthと一致する。
    /// 空白スロットの場合はmirrorAspectRatio(orderedCurrentSlots参照)を使う。
    private func displayWidth(for slot: SpreadPageSlot, atHeight height: CGFloat, mirrorAspectRatio: CGFloat) -> CGFloat {
        switch slot {
        case .image(let image):
            guard image.height > 0 else { return 0 }
            return height * CGFloat(image.width) / CGFloat(image.height)
        case .blank:
            return height * mirrorAspectRatio
        }
    }

    /// スロット列の中に含まれる実画像のうち、最初に見つかったもののアスペクト比(幅/高さ)。
    /// 空白スロットの幅を決めるための近似値として使う(orderedCurrentSlots参照)。
    /// 実画像が1枚も無い場合は1(正方形)を返すが、この関数はorderedCurrentSlotsが空白を
    /// 生成する条件(必ず実画像が1枚存在する)の下でしか意味を持たないため、実際には
    /// 起こらない。
    private func referenceAspectRatio(for slots: [SpreadPageSlot]) -> CGFloat {
        for slot in slots {
            if case .image(let image) = slot, image.height > 0 {
                return CGFloat(image.width) / CGFloat(image.height)
            }
        }
        return 1
    }

    private func totalContentSize(for slots: [SpreadPageSlot], referenceHeight: CGFloat) -> CGSize {
        guard !slots.isEmpty, referenceHeight > 0 else { return .zero }
        let mirrorAspectRatio = referenceAspectRatio(for: slots)
        let width = slots.reduce(CGFloat(0)) { $0 + displayWidth(for: $1, atHeight: referenceHeight, mirrorAspectRatio: mirrorAspectRatio) }
        return CGSize(width: width, height: referenceHeight)
    }

    private func renderScale(contentSize: CGSize, containerSize: CGSize) -> CGFloat {
        guard contentSize.width > 0, contentSize.height > 0, containerSize.width > 0, containerSize.height > 0 else {
            return 1
        }
        let maxUpscale = CGFloat(preferences.maxUpscalePercent / 100)
        switch viewModel.scalingMode {
        case .fitToScreen:
            let fitScale = min(containerSize.width / contentSize.width, containerSize.height / contentSize.height)
            return min(fitScale, maxUpscale)
        case .fitWidth:
            let widthScale = containerSize.width / contentSize.width
            return min(widthScale, maxUpscale)
        case .fitWidthSplit:
            // 横幅に合わせる(単ページ): 表示中の内容の「横幅の半分」が画面幅いっぱいになる倍率まで拡大する
            // (はみ出した分は左右スクロールで読む)。cooViewerのfitScreenMode == 3が
            // rate = 画面幅 / (画像幅 / 2) としているのと同じ式。
            //
            // 分割する意味が無い内容(単ページ表示中の縦長ページなど)まで2倍に引き伸ばすと
            // ただ読みにくくなるだけなので、その場合はfitWidthと全く同じ結果になるよう
            // divisorを1に落とす。cooViewerも同じ考え方で、横長でない画像
            // (isSmallImageがtrue)のときはfitScreenMode == 1と同じ処理へ分岐している。
            //
            // 判定に使うのは個々のページの縦横比ではなく、実際に表示している内容(contentSize)を
            // 合成したあとの縦横比である点が重要。これにより「単ページ表示中の横長スキャン」と
            // 「見開き表示で縦長2ページを合成した状態」の両方が、追加の判定なしに等しく
            // 分割対象になる(どちらも合成後は横長になるため)。ViewerViewModelが持つ
            // ページ単位の横長判定(wideImageCache)は画像の読み込みを伴う非同期のキャッシュで、
            // 本を開いた直後は埋まっていないが、contentSizeは今まさに表示している画像から
            // 同期的に求まるため、そちらに依存せずに済むという利点もある。
            let contentAspectRatio = contentSize.width / contentSize.height
            let isDividable = contentAspectRatio >= CGFloat(preferences.singlePageAspectRatioThreshold)
            let widthScale = containerSize.width / (contentSize.width / (isDividable ? 2 : 1))
            return min(widthScale, maxUpscale)
        case .noScale:
            return 1
        }
    }

    /// 今、ページ画像をスクロールできる状態か。
    ///
    /// 「画面内に収める」は本来スクロールする余地が無いモードだが、ピンチ拡大中だけは
    /// 画像が画面からはみ出すため例外的にスクロールできる。ScrollViewを使うかどうか、
    /// ドラッグで画像を掴めるかどうか、キー/ホイールのスクロール操作を受け付けるかどうかは
    /// すべてこの1つの判定に集約する(モードだけを見る判定があちこちに残ると、
    /// ピンチ拡大中だけ挙動が食い違う箇所が生まれるため)。
    private var isPageAreaScrollable: Bool {
        viewModel.scalingMode != .fitToScreen || viewModel.pinchZoomFactor > 1
    }

    /// ScrollViewの中身(documentView)の大きさ。
    ///
    /// 画像が表示領域より小さい方向には、表示領域の大きさを下限にしておく。こうするとSwiftUIが
    /// その中で画像を中央に置いてくれるので、「画面内に収める」をピンチ拡大したときに片方の
    /// 辺だけまだ画面に収まっている、という状態でも画像が隅に寄らない。
    ///
    /// 縦を下限で持ち上げるのは「画面内に収める」のときだけである点に注意。他のモードは
    /// 従来どおり中身の高さをそのまま使う(縦が画面より短いときは上詰め)。表示の前提が
    /// 変わってしまうため、ピンチ拡大の追加を機に既存モードの見え方を変えることはしない。
    private func scrollContentSize(contentSize: CGSize, scale: CGFloat, viewport: CGSize) -> CGSize {
        let scaledWidth = contentSize.width * scale
        let scaledHeight = contentSize.height * scale
        return CGSize(
            width: max(scaledWidth, viewport.width),
            height: viewModel.scalingMode == .fitToScreen ? max(scaledHeight, viewport.height) : scaledHeight
        )
    }

    /// ScrollViewにスクロールを許す方向。
    /// - fitToScreen: 画像を画面内に収めるためScrollView自体を使わない(この値は参照されない)。
    ///   ただしピンチ拡大中は縦横ともはみ出しうるため、両方向を許す。
    /// - fitWidth: 横幅はぴったり画面に収まるため、縦だけ
    /// - fitWidthSplit / noScale: 画像が画面より横に広くなりうるため、縦横とも
    ///
    /// 「横幅に合わせる(単ページ)」で「半分にする意味が無い」と判定された内容(renderScale参照)では横幅が
    /// ぴったり収まるため、横を許していてもスクロールできる余地が無く、実害は無い
    /// (「横幅に合わせる」もピンチ拡大中は横にはみ出すが、同じ理由で常に横を許しておいて構わない)。
    private var scrollAxes: Axis.Set {
        switch viewModel.scalingMode {
        case .fitToScreen: return viewModel.pinchZoomFactor > 1 ? [.horizontal, .vertical] : []
        case .fitWidth: return viewModel.pinchZoomFactor > 1 ? [.horizontal, .vertical] : [.vertical]
        case .fitWidthSplit, .noScale: return [.horizontal, .vertical]
        }
    }

    // MARK: - スクロール送り(cooViewerの「1画面分下へ+次のページ」相当)

    /// 端に着いているかどうかの判定に使う許容誤差。拡大率の計算にはどうしても浮動小数の
    /// 誤差が乗るため、厳密比較にすると1px未満ずれているだけで「まだ動ける」と誤判定し、
    /// ページが送られずその場で止まってしまう。
    private static let scrollEdgeEpsilon: CGFloat = 1

    /// 「端まで」を表す十分大きな値。実際の可動範囲はSwiftUIがクランプしてくれるため、
    /// contentSizeがまだ新しいページのものに更新されていない瞬間に呼んでも、最終的に
    /// 正しい隅へ収まる。
    private static let scrollFarEdge: CGFloat = 1_000_000

    /// 1画面分スクロールし、それ以上動けなければページを送る
    /// (cooViewerのCustomImageView.next/prevと同じ3段階。ViewerAction.scrollAndMoveNext参照)。
    /// - allowPageChange: 縦にも横にも余地が無くなったときにページを送るかどうか。
    ///   falseだと、その場で止まる(ホイール動作「スクロール」= cooViewerのcanScrollMode == 1)。
    private func scrollByOneScreen(forward: Bool, allowPageChange: Bool = true) {
        // 画面内に収めるモードにはスクロールという概念が無いので、素直にページ送りへ縮退する。
        // この縮退があるおかげで、cooViewerがモード別のキー設定で実現していた既定の操作感を
        // 1つの割り当てで再現できる(ViewerAction.scrollAndMoveNextのコメント参照)。
        guard isPageAreaScrollable,
              let bounds = ScrollViewBounds(scrollGeometryBox.scrollView) else {
            if allowPageChange { viewModel.advance(forward: forward) }
            return
        }
        let epsilon = Self.scrollEdgeEpsilon
        let position = bounds.position
        let screen = bounds.visibleSize

        // 1. まだ縦に動けるなら、縦に1画面分動かすだけ
        if scrollVerticallyByOneScreen(down: forward, bounds: bounds) { return }

        // 2. 縦は端に着いている。横に余地があれば読み方向へ1画面分ずらし、縦は反対の端へ移す
        //    (進むときは次の列の最上部から、戻るときは前の列の最下部から読み始める)
        let forwardSign: CGFloat = viewModel.readingDirection == .rightToLeft ? -1 : 1
        let step = (forward ? forwardSign : -forwardSign) * screen.width
        let hasHorizontalRoom = step > 0
            ? position.x < bounds.maxX - epsilon
            : position.x > epsilon
        if hasHorizontalRoom {
            bounds.scroll(to: CGPoint(x: position.x + step, y: forward ? 0 : bounds.maxY))
            return
        }

        // 3. どちらにも余地が無い ― ページを送る。戻る場合は、移動先のページを
        //    読み終わり側の隅から表示し始める(cooViewerのsetStartFromEnd:YES相当)。
        guard allowPageChange else { return }
        pendingPageEntryAtEnd = !forward
        viewModel.advance(forward: forward)
    }

    /// 縦方向にだけ1画面分スクロールする(cooViewerの「1画面分下へ/上へ」相当)。
    /// 実際に動かせたらtrueを返す(横への回り込み・ページ送りは行わない)。
    @discardableResult
    private func scrollVerticallyByOneScreen(down: Bool, bounds: ScrollViewBounds?) -> Bool {
        guard isPageAreaScrollable, let bounds else { return false }
        let epsilon = Self.scrollEdgeEpsilon
        let position = bounds.position
        if down, position.y < bounds.maxY - epsilon {
            bounds.scroll(to: CGPoint(x: position.x, y: position.y + bounds.visibleSize.height))
            return true
        }
        if !down, position.y > epsilon {
            bounds.scroll(to: CGPoint(x: position.x, y: position.y - bounds.visibleSize.height))
            return true
        }
        return false
    }

    /// 決まった量だけスクロールする(cooViewerの「上/下/左/右へスクロール」= action 30〜33 相当)。
    /// dx/dyは向きだけを表す(-1/0/1)。1回あたりの移動量は表示モードごとの設定で決まる。
    ///
    /// 「1画面分」単位の送りとは別に、少しずつ動かす手段が要る。とくに横方向は、qooViewerの
    /// 既定では←/→がページ送りに割り当てられているため、これが無いと原寸表示や
    /// 「横幅に合わせる(単ページ)」でキーボードから横へ動かす手段が一切なくなる。
    private func scrollByStep(dx: CGFloat, dy: CGFloat) {
        guard isPageAreaScrollable,
              let bounds = ScrollViewBounds(scrollGeometryBox.scrollView) else { return }
        let step = CGFloat(keyBindingStore.scrollStep(in: viewModel.scalingMode))
        let position = bounds.position
        bounds.scroll(to: CGPoint(x: position.x + dx * step, y: position.y + dy * step))
    }

    /// ページを表示し始めるときのスクロール位置(cooViewerのfirstScroll相当)。
    /// 読み始め側の隅は読み方向で変わる ― 右開きなら右上、左開きなら左上。
    /// atEndがtrueなら読み終わり側の隅(右開きなら左下、左開きなら右下)。
    ///
    /// これが無いと、右開きの本で「横幅に合わせる(単ページ)」にしたときに毎回「左半分」から表示が始まり、
    /// ページをめくるたびに自分で右へスクロールし直すことになる。
    private func scrollToPageCorner(atEnd: Bool) {
        guard viewModel.scalingMode != .fitToScreen,
              let bounds = ScrollViewBounds(scrollGeometryBox.scrollView) else { return }
        let isRightToLeft = viewModel.readingDirection == .rightToLeft
        let startX: CGFloat = isRightToLeft ? bounds.maxX : 0
        let endX: CGFloat = isRightToLeft ? 0 : bounds.maxX
        bounds.scroll(to: CGPoint(x: atEnd ? endX : startX, y: atEnd ? bounds.maxY : 0))
    }

    // MARK: - ピンチ拡大(トラックパッドのピンチイン・ピンチアウト)

    /// スマートズーム(トラックパッドの2本指ダブルタップ)で拡大するときの倍率。
    /// 環境設定の上限のほうが低ければ、ViewerViewModel.setPinchZoomFactor側でそこまで丸められる。
    private static let smartZoomFactor: CGFloat = 2

    /// 拡大率を画面に出しておく時間。ピンチ操作中は連続で更新されるため、指を止めてから
    /// この時間が経つと消える。
    private static let zoomIndicatorDuration: Duration = .milliseconds(900)

    /// ピンチ拡大の前後で「カーソルの下にあった画像上の点」を動かさないための予約。
    ///
    /// 拡大率を変えた直後の時点では、ScrollViewの中身(documentView)はまだ拡大前の大きさの
    /// ままで、可動範囲も広がっていない。そのため位置合わせは、beginPageEntryScrollと同じ
    /// 2段構え ― その場で1回(前後で大きさが変わらないならこれで確定)+ 中身の大きさが実際に
    /// 変わった通知を受けてからもう1回(handleDocumentFrameChange)― で行う必要がある。
    private struct PendingZoomAnchor {
        /// 拡大の中心にしたい点。倍率1のときの画像上の座標(画素単位、左上が原点)で持つ。
        let contentPoint: CGPoint
        /// その点を画面上のどこへ留めたいか(ページ表示領域の左上を原点とする座標)。
        let viewportPoint: CGPoint
        /// この予約を作ったときの拡大率。適用しようとした時点の拡大率と食い違っていたら
        /// (ページが変わって拡大が解除された等)、その予約はもう意味を持たないので捨てる。
        let zoomFactor: CGFloat
    }

    /// ピンチ拡大の位置合わせに必要な、今のページ表示のレイアウト情報。
    ///
    /// pageArea(GeometryReader)の中でしか分からない値を、イベント処理側からも同じ計算で
    /// 組み立て直したもの。GeometryReaderのローカル変数を@Stateへ書き戻す方式は採っていない
    /// ― bodyの評価中に状態を書き換えることになり、際限のない再評価を招きうるため
    /// (ScrollGeometryBoxのコメントと同じ考え方)。表示領域の大きさは、pageAreaと常に同じ
    /// 大きさが報告されているpageAreaFrameInWindow(PageAreaFrameAccessor参照)から得る。
    private struct PageLayoutMetrics {
        /// 拡大率を掛ける前の、表示内容そのものの大きさ(画素単位)。
        let contentSize: CGSize
        /// ピンチ拡大を掛ける前の表示倍率(renderScaleが返す値)。
        let baseScale: CGFloat
        /// ページ表示領域(=ScrollViewの見えている部分)の大きさ。
        let viewportSize: CGSize

        /// ピンチ拡大まで含めた、実際の表示倍率。
        func scale(zoomFactor: CGFloat) -> CGFloat { baseScale * zoomFactor }
    }

    private var currentPageLayoutMetrics: PageLayoutMetrics? {
        let viewport = pageAreaFrameInWindow.size
        guard viewport.width > 0, viewport.height > 0 else { return nil }
        let slots = orderedCurrentSlots
        let contentSize = totalContentSize(for: slots, referenceHeight: referenceHeight(for: slots))
        guard contentSize.width > 0, contentSize.height > 0 else { return nil }
        let baseScale = renderScale(contentSize: contentSize, containerSize: viewport)
        guard baseScale > 0 else { return nil }
        return PageLayoutMetrics(contentSize: contentSize, baseScale: baseScale, viewportSize: viewport)
    }

    /// ScrollViewの中身(documentView)の座標系で、画像そのものが置かれる左上の位置。
    /// 画像が中身より小さい方向では中央に置かれるため、そのぶん原点がずれる
    /// (scrollContentSize参照)。
    private func contentOrigin(contentSize: CGSize, scale: CGFloat, scrollContentSize: CGSize) -> CGPoint {
        CGPoint(
            x: (scrollContentSize.width - contentSize.width * scale) / 2,
            y: (scrollContentSize.height - contentSize.height * scale) / 2
        )
    }

    /// ウインドウ座標系の点を、ページ表示領域の左上を原点とする座標へ変換する。
    /// 表示領域の外(ツールバーの上など)、または位置が分からない場合はnil。
    /// AppKitのウインドウ座標はウインドウ最下端が原点でY軸が上向きのため、上下を反転させる。
    private func viewportPoint(forWindowPoint point: CGPoint?) -> CGPoint? {
        guard let point, pageAreaFrameInWindow.contains(point) else { return nil }
        return CGPoint(
            x: point.x - pageAreaFrameInWindow.minX,
            y: pageAreaFrameInWindow.maxY - point.y
        )
    }

    /// ページ表示領域の中の点(左上が原点)を、倍率1のときの画像上の点へ変換する。
    private func contentPoint(
        forViewportPoint viewportPoint: CGPoint,
        metrics: PageLayoutMetrics,
        zoomFactor: CGFloat
    ) -> CGPoint {
        let scale = metrics.scale(zoomFactor: zoomFactor)
        guard scale > 0 else { return .zero }
        let scrollContent = scrollContentSize(
            contentSize: metrics.contentSize, scale: scale, viewport: metrics.viewportSize
        )
        // ScrollViewを使っていない(=「画面内に収める」で等倍)ときは、スクロール位置は常に原点。
        // このときのweak参照(scrollGeometryBox.scrollView)は当てにしない。
        let scrollPosition = isPageAreaScrollable
            ? (ScrollViewBounds(scrollGeometryBox.scrollView)?.position ?? .zero)
            : .zero
        let origin = contentOrigin(
            contentSize: metrics.contentSize, scale: scale, scrollContentSize: scrollContent
        )
        return CGPoint(
            x: (scrollPosition.x + viewportPoint.x - origin.x) / scale,
            y: (scrollPosition.y + viewportPoint.y - origin.y) / scale
        )
    }

    /// 予約(PendingZoomAnchor)を満たすスクロール位置。実際の可動範囲へのクランプは
    /// ScrollViewBounds.scroll(to:)が行うため、ここでは範囲外の値になっても構わない。
    private func scrollTarget(for anchor: PendingZoomAnchor, metrics: PageLayoutMetrics) -> CGPoint {
        let scale = metrics.scale(zoomFactor: viewModel.pinchZoomFactor)
        let scrollContent = scrollContentSize(
            contentSize: metrics.contentSize, scale: scale, viewport: metrics.viewportSize
        )
        let origin = contentOrigin(
            contentSize: metrics.contentSize, scale: scale, scrollContentSize: scrollContent
        )
        return CGPoint(
            x: origin.x + anchor.contentPoint.x * scale - anchor.viewportPoint.x,
            y: origin.y + anchor.contentPoint.y * scale - anchor.viewportPoint.y
        )
    }

    /// 予約どおりの位置へスクロールする。まだScrollViewが存在しない(「画面内に収める」から
    /// 拡大し始めた直後)場合はfalseを返し、呼び出し側は次の機会を待つ。
    @discardableResult
    private func applyZoomAnchor(_ anchor: PendingZoomAnchor) -> Bool {
        guard let metrics = currentPageLayoutMetrics,
              let bounds = ScrollViewBounds(scrollGeometryBox.scrollView) else { return false }
        bounds.scroll(to: scrollTarget(for: anchor, metrics: metrics))
        return true
    }

    /// ScrollViewの中身の大きさが確定したあとの位置合わせ(handleDocumentFrameChangeと、
    /// ScrollViewAccessorのonResolveから呼ばれる)。実際に位置を合わせたらtrueを返す。
    @discardableResult
    private func applyPendingZoomAnchorIfNeeded() -> Bool {
        guard let anchor = pendingZoomAnchor else { return false }
        guard anchor.zoomFactor == viewModel.pinchZoomFactor else {
            pendingZoomAnchor = nil
            return false
        }
        guard applyZoomAnchor(anchor) else { return false }
        pendingZoomAnchor = nil
        // 「画面内に収める」を拡大したことでScrollViewが初めて現れた場合、このページについては
        // まだ読み始め位置合わせ(finishPageEntryScrollIfNeeded)が済んでいない扱いになっている。
        // 済んだことにしておかないと、この後ウインドウをリサイズしたときなどに、拡大して見て
        // いた場所から読み始めの隅へ引き戻されてしまう。
        lastPageEntryScrollIndex = viewModel.currentIndex
        return true
    }

    /// ピンチ拡大の倍率を変更し、カーソルの下にあった点が動かないようにスクロール位置を合わせる。
    /// - Parameters:
    ///   - rawFactor: 希望する倍率。1未満・上限超えの丸めはViewerViewModel側で行う。
    ///   - anchorInWindow: ジェスチャーの位置(ウインドウ座標)。ページ表示領域の外や、
    ///     位置を問わない場合(Escでの解除など)はnilを渡すと、表示領域の中央を中心にする。
    private func applyPinchZoom(to rawFactor: CGFloat, anchorInWindow: CGPoint?) {
        guard let metrics = currentPageLayoutMetrics else { return }
        let previousZoomFactor = viewModel.pinchZoomFactor
        let viewportPoint = viewportPoint(forWindowPoint: anchorInWindow)
            ?? CGPoint(x: metrics.viewportSize.width / 2, y: metrics.viewportSize.height / 2)
        // 中心にしたい点は、必ず「拡大する前」の状態で求めておく。
        let contentPoint = contentPoint(
            forViewportPoint: viewportPoint, metrics: metrics, zoomFactor: previousZoomFactor
        )

        viewModel.setPinchZoomFactor(rawFactor)
        let zoomFactor = viewModel.pinchZoomFactor
        guard zoomFactor != previousZoomFactor else { return }

        showZoomIndicator(percent: Int((zoomFactor * 100).rounded()))

        let anchor = PendingZoomAnchor(
            contentPoint: contentPoint, viewportPoint: viewportPoint, zoomFactor: zoomFactor
        )
        pendingZoomAnchor = anchor
        // 1段目(その場で1回)。この時点ではScrollViewの中身がまだ拡大前の大きさのため、
        // 拡大した場合は可動範囲でクランプされて途中までしか効かない。2段目は
        // handleDocumentFrameChangeが受け持つ(PendingZoomAnchor参照)。
        applyZoomAnchor(anchor)
    }

    /// 拡大を解除して初期状態(等倍)へ戻す。
    private func resetPinchZoom() {
        guard viewModel.pinchZoomFactor > 1 else { return }
        applyPinchZoom(to: 1, anchorInWindow: nil)
    }

    /// トラックパッドのピンチイン・ピンチアウト(NSEventの.magnify)。
    ///
    /// SwiftUIのMagnifyGestureではなくNSEventを直接扱うのは、ページ表示領域がScrollViewと
    /// ClickZoneArea(素のNSView)を重ねた構成になっており、SwiftUIのジェスチャーだと
    /// それらとの取り合いになるため。ホイール・スワイプ・キー入力と同じローカルモニタで
    /// 受けることで、「宛先ウインドウが自分か」「サムネイル一覧/サイドパネル表示中は無視」と
    /// いった前処理もそのまま共有できる(makeScrollMonitor参照)。
    ///
    /// event.magnificationは1イベントぶんの**変化量**で、現在の倍率に(1 + magnification)を
    /// 掛けて積み上げるのが正しい(AppKitのNSScrollView.magnificationも同じ扱い)。倍率へ
    /// そのまま足し込むと、倍率が上がるほど同じ指の動きに対する変化が相対的に小さくなり、
    /// 指の動きに表示が付いてこなくなる。
    private func handleMagnify(_ event: NSEvent) {
        // 拡大鏡(ルーペ)表示中は拡大を拡大鏡に任せ、こちらは何もしない(役割を分ける)。
        guard !viewModel.isLoupeActive else { return }
        guard event.magnification != 0 else { return }
        applyPinchZoom(
            to: viewModel.pinchZoomFactor * (1 + CGFloat(event.magnification)),
            anchorInWindow: event.locationInWindow
        )
    }

    /// トラックパッドの2本指ダブルタップ(スマートズーム、NSEventの.smartMagnify)。
    /// 等倍なら既定の倍率まで拡大し、拡大中なら等倍へ戻す、というmacOS標準のトグル動作にならう。
    ///
    /// 拡大の途中経過をアニメーションさせていないのは、拡大に伴うスクロール位置の確定が
    /// ScrollViewの中身の大きさの確定を待つ必要がある(PendingZoomAnchor参照)ため、
    /// アニメーションの各フレームで正しい位置を保証できないからである。
    private func handleSmartMagnify(_ event: NSEvent) {
        guard !viewModel.isLoupeActive else { return }
        let target: CGFloat = viewModel.pinchZoomFactor > 1 ? 1 : Self.smartZoomFactor
        applyPinchZoom(to: target, anchorInWindow: event.locationInWindow)
    }

    /// 拡大率を短時間だけ画面に表示する(showToastと同じ考え方の、拡大操作専用の軽い版)。
    /// ピンチ操作中は指を動かすたびに呼ばれるため、表示中の再表示は時間を延長するだけになる。
    private func showZoomIndicator(percent: Int) {
        zoomIndicatorHideTask?.cancel()
        zoomIndicatorPercent = percent
        zoomIndicatorHideTask = Task { @MainActor in
            try? await Task.sleep(for: Self.zoomIndicatorDuration)
            guard !Task.isCancelled else { return }
            zoomIndicatorPercent = nil
        }
    }

    /// 今の表示モードで、この向き・修飾キーのホイール操作に割り当てられている操作。
    private func wheelAction(
        _ direction: MouseTrigger.WheelDirection,
        modifiers: MouseTrigger.Modifiers = []
    ) -> ViewerAction? {
        keyBindingStore.resolvedAction(
            for: MouseTrigger(input: .wheel(direction), modifiers: modifiers),
            in: viewModel.scalingMode
        )
    }

    /// 今の表示モードで、このボタン・位置・修飾キーの組み合わせに割り当てられている操作。
    /// 位置指定が「全体」より優先される(KeyBindingStore.resolvedClickAction参照)。
    private func clickAction(
        button: MouseTrigger.Button,
        zone: MouseTrigger.Zone,
        modifiers: MouseTrigger.Modifiers
    ) -> ViewerAction? {
        keyBindingStore.resolvedClickAction(
            button: button, zone: zone, modifiers: modifiers, in: viewModel.scalingMode
        )
    }

    /// 今の表示モードで、このボタン・向き・修飾キーのドラッグジェスチャーに
    /// 割り当てられている操作。ジェスチャーは位置(画面の左右)を区別しない
    /// (MouseTrigger のコメント参照)。
    private func dragAction(
        button: MouseTrigger.Button,
        direction: MouseTrigger.DragDirection,
        modifiers: MouseTrigger.Modifiers
    ) -> ViewerAction? {
        keyBindingStore.resolvedDragAction(
            button: button, direction: direction, modifiers: modifiers, in: viewModel.scalingMode
        )
    }

    /// 今の表示モードで、クリックに何か1つでも操作が割り当てられているか。
    /// 割り当てが無いのにヒットテストを有効にしてしまうと、下にあるScrollViewへクリックが
    /// 届かなくなるだけで何の利点も無いため、その場合は無効にする。
    ///
    /// 左右のクリックゾーンだけでなく、中ボタンや修飾キー付きの割り当ても数える
    /// (中ボタンにだけ割り当てた場合も当たり判定は必要なため)。
    private var hasClickZoneAction: Bool {
        keyBindingStore.hasAnyPointerAction(in: viewModel.scalingMode)
    }

    /// ページが変わった瞬間に、読み始め側の隅へスクロールする(cooViewerのfirstScroll相当)。
    ///
    /// バグ修正(実機で確認): これは**2段構え**にする必要がある。ページ番号が変わった時点では、
    /// まだ新しいページの画像がレイアウトへ反映されておらず、NSScrollViewのdocumentViewは
    /// 前のページの大きさのままだからである。右開きの本で縦長ページ(横の可動量ゼロ)から
    /// 横長ページ(単ページ幅に合わせると可動量=画面幅)へ進むと、ここでの「右端へ」という指示が
    /// 可動量ゼロでクランプされてx=0になり、左半分から表示が始まってしまっていた。
    /// DispatchQueue.main.asyncで1回遅らせるだけでは足りないことも実機で確認している。
    ///
    /// そこで、ここでの即時の位置合わせ(前後のページで大きさが同じならこれで確定)に加えて、
    /// documentViewの大きさが実際に変わった通知(ScrollViewAccessor.onDocumentFrameChange)を
    /// 受けてから、finishPageEntryScrollIfNeededで確定させる。
    private func beginPageEntryScroll() {
        pageEntryAtEnd = pendingPageEntryAtEnd
        pendingPageEntryAtEnd = false
        // ページが変わるとピンチ拡大は解除される(ViewerViewModel.currentIndexのdidSet)ため、
        // 拡大の位置合わせの予約も一緒に捨てる。
        pendingZoomAnchor = nil
        // 可動範囲が確定したら改めて合わせ直すため、このページの「済み」印を外す。
        lastPageEntryScrollIndex = nil
        scrollToPageCorner(atEnd: pageEntryAtEnd)
    }

    /// documentViewの大きさが変わり、可動範囲が確定したあとの位置合わせ
    /// (beginPageEntryScrollのコメント参照)。本を開いた直後(まだ1枚も表示していない状態から
    /// 最初のページが出た瞬間)も、ページ番号が変化しないためこちらが受け持つ。
    ///
    /// lastPageEntryScrollIndexにより、同じページについて2回は行わない。これにより、
    /// ウインドウのリサイズでdocumentViewの大きさが変わっても、読者のスクロール位置を
    /// 勝手に先頭へ戻してしまうことはない。
    private func finishPageEntryScrollIfNeeded() {
        guard lastPageEntryScrollIndex != viewModel.currentIndex else { return }
        lastPageEntryScrollIndex = viewModel.currentIndex
        scrollToPageCorner(atEnd: pageEntryAtEnd)
    }

    /// ScrollViewの中身(documentView)の大きさが変わったときの処理。
    /// 「ページを表示し始めるときの位置合わせ」と「ピンチ拡大に伴う位置合わせ」は、どちらも
    /// この通知(=可動範囲が確定した瞬間)を待たなければ正しく決まらない
    /// (beginPageEntryScroll/applyPinchZoom参照)。
    ///
    /// ピンチ拡大側を先に見る。拡大した直後に読み始めの隅へ飛ばされては、拡大した意味が
    /// 無くなってしまうため。
    private func handleDocumentFrameChange() {
        if applyPendingZoomAnchorIfNeeded() { return }
        finishPageEntryScrollIfNeeded()
    }

    /// スクロールできるモード(横幅に合わせる/同(単ページ)/拡大縮小しない)でホイールを回したときの処理。
    /// cooViewerの`wheelAction:`の`canScrollMode`による分岐をそのまま移植したもの
    /// (WheelScrollBehavior参照)。
    ///
    /// 「まだスクロールできるか」は、ScrollViewがこのイベントを処理する**前**の位置で判定する。
    /// そのため、端に着くまでは普通にスクロールし、端に着いた状態でもう一度回したときに初めて
    /// 横への回り込みやページ送りが起きる ― cooViewerと同じ操作感になる。
    /// - Parameter isInverted: 環境設定「2本指スクロールを反転」が、このイベントに効いているか
    ///   (AppPreferences.invertTwoFingerScrolling参照)。
    /// - Returns: 実際に何か操作を行った(=このイベントをスクロールに使わなかった)かどうか。
    @discardableResult
    private func handleScrollInScrollableMode(
        deltaY: CGFloat, isInverted: Bool, modifiers: MouseTrigger.Modifiers?
    ) -> Bool {
        // 割り当ての対象外の修飾キー(control/command/shift)が押されている場合は、何もせず
        // ScrollView標準のスクロールに任せる(handleScrollのmodifiers引数のコメント参照)。
        guard let modifiers else { return false }

        // 修飾キー付きのホイールは、スクロール操作ではなく**明示的な指示**なので、
        // 「スクロールできるとき」(WheelScrollBehavior)の判定を通さず、割り当てられた操作を
        // そのまま実行する。素のホイールでスクロールしたいモードでも、option+ホイールには
        // 別の操作を割り当てておける、という使い分けのため。割り当てが無ければ従来どおり
        // ScrollViewに任せる。
        if !modifiers.isEmpty {
            let direction: MouseTrigger.WheelDirection = deltaY > 0 ? .up : .down
            guard deltaY > 2 || deltaY < -2 else { return false }
            guard let action = wheelAction(direction, modifiers: modifiers), action != .none else {
                return false
            }
            let now = Date()
            if let lastWheelActionAt, now.timeIntervalSince(lastWheelActionAt) < wheelActionCooldown {
                return false
            }
            lastWheelActionAt = now
            perform(action)
            return true
        }

        // ピンチ拡大中は、どのモードでもホイールをスクロール専用にする(ユーザーの判断)。
        // 拡大して細部を読んでいる最中に端まで来たからといってページが送られると、
        // 拡大も一緒に解除されて読んでいた場所を見失う。拡大を解除すれば、そのモード本来の
        // 設定(WheelScrollBehavior)にそのまま戻る。
        let behavior: WheelScrollBehavior = viewModel.pinchZoomFactor > 1
            ? .scrollOnly
            : keyBindingStore.wheelBehavior(in: viewModel.scalingMode)
        // スクロールのみ: ScrollViewに任せる(何もしない)。
        guard behavior != .scrollOnly else { return false }

        guard deltaY > 2 || deltaY < -2 else { return false }
        let now = Date()
        if let lastWheelActionAt, now.timeIntervalSince(lastWheelActionAt) < wheelActionCooldown {
            return false
        }

        // NSEvent.scrollingDeltaYは、ホイールを上へ回すと正になる(handleScrollのコメント参照)。
        //
        // 向きの意味が2種類あることに注意。
        // - assignedForward: 「ホイール上/下」への**割り当て**を引くための向き。反転設定の
        //   影響を受けない(反転は画像が動く向きだけを変える設定であり、割り当ての上下まで
        //   入れ替えると「キー・マウス」設定側の入れ替えと二重になるため。
        //   AppPreferences.invertTwoFingerScrolling参照)。
        // - scrollForward: 実際にページの**内容が進む**向き。端まで来たときのスクロール送り
        //   /ページ送りは、いま行っているスクロールの延長なので、こちらを使う。
        let assignedForward = deltaY < 0
        let scrollForward = isInverted ? deltaY > 0 : deltaY < 0

        if behavior == .turnPage {
            // スクロールには使わず、常に割り当てられた操作を行う。
            lastWheelActionAt = now
            perform(wheelAction(assignedForward ? .down : .up))
            return true
        }

        // まだ縦に動ける間はScrollViewに任せ、端に着いてから初めてこちらが引き取る。
        guard let bounds = ScrollViewBounds(scrollGeometryBox.scrollView) else { return false }
        let epsilon = Self.scrollEdgeEpsilon
        let canStillScrollVertically =
            scrollForward ? bounds.position.y < bounds.maxY - epsilon : bounds.position.y > epsilon
        guard !canStillScrollVertically else { return false }

        lastWheelActionAt = now
        switch behavior {
        case .scrollAndTurnPage:
            scrollByOneScreen(forward: scrollForward)
        case .scrollAndWrap:
            // 横へは回り込むが、ページはめくらない(cooViewerのcanScrollMode == 1)。
            scrollByOneScreen(forward: scrollForward, allowPageChange: false)
        case .scrollOnly, .turnPage:
            break  // 上で処理済み
        }
        return true
    }

    /// - Parameter isInverted: 環境設定「2本指スクロールを反転」が、このイベントに効いているか
    ///   (AppPreferences.invertTwoFingerScrolling参照)。
    /// - Returns: 実際に何か操作を行った(=このイベントをスクロールに使わなかった)かどうか。
    ///   反転が有効なときの呼び出し側が、「操作したのでスクロールはしない」を判断するために使う。
    @discardableResult
    ///
    /// - Parameter modifiers: このイベントの修飾キー。**nilは「割り当ての対象外」を意味する**
    ///   (control/command、およびホイールにおけるshift。MouseTrigger.Modifiers.from参照)。
    ///   その場合はfalseを返すだけで何もせず、スクロール自体は呼び出し側の経路
    ///   (ScrollView標準、または反転が有効ならperformInvertedScroll)にそのまま任される。
    private func handleScroll(
        deltaY: CGFloat, isInverted: Bool = false, modifiers: MouseTrigger.Modifiers?
    ) -> Bool {
        // 「画面内に収める」モードにはスクロールする余地が無いため、従来どおりホイールの
        // 割り当て(既定はページ送り)をそのまま実行する。
        // それ以外のモードでは、環境設定「スクロールできるとき」(WheelScrollBehavior、
        // cooViewerのCanScrollMode相当)に従う。
        // 「画面内に収める」でもピンチ拡大中はスクロールできる余地があるため、そちらの経路に乗せる。
        if isPageAreaScrollable {
            return handleScrollInScrollableMode(
                deltaY: deltaY, isInverted: isInverted, modifiers: modifiers
            )
        }
        guard let modifiers else { return false }

        // NSEvent.scrollingDeltaYの符号は、ホイールを物理的に上へ回す(指を上に動かす)と
        // 正の値になる(以前の実装ではここが逆になっており、ホイールを上に回すと.wheelDownに
        // 割り当てた操作が実行されてしまっていた。設定画面の「Scroll Wheel Up」という表示と
        // 実際の動作が食い違うバグだったため、対応する分岐を入れ替えて修正している)。
        guard deltaY > 2 || deltaY < -2 else { return false }

        // 一部のマウス/ドライバでは、物理的には1ノッチしか回していなくても、その回転が
        // ごく短い間隔の複数のscrollWheelイベントに分かれて届くことがある。それらを
        // まとめて1回のページ送りとして扱うため、直前のページ送りからこの間隔未満での
        // 連続発火は無視する(意図的に素早く連続でノッチを回したときの間隔は、通常
        // これよりも空くため、そちらは取りこぼさない)。
        let now = Date()
        if let lastWheelActionAt, now.timeIntervalSince(lastWheelActionAt) < wheelActionCooldown {
            return false
        }
        lastWheelActionAt = now

        // ここは「向き→操作」の割り当てそのものなので、反転設定の影響を受けない
        // (AppPreferences.invertTwoFingerScrolling参照)。そもそもこの分岐に来るのは
        // スクロールする余地が無いときだけで、反転させる対象のスクロールが存在しない。
        if deltaY > 0 {
            perform(wheelAction(.up, modifiers: modifiers))
        } else {
            perform(wheelAction(.down, modifiers: modifiers))
        }
        return true
    }

    /// 環境設定「2本指スクロールを反転」が有効なときに、ScrollView標準のスクロールを
    /// 肩代わりして、上下左右とも反対向きに動かす。
    ///
    /// NSEventのスクロール量そのものは書き換えられないため、「イベントを消費したうえで、
    /// 自分で反対向きにスクロールする」という形にしている。指を離したあとの慣性
    /// (momentumPhase)のイベントも同じ経路を通るので、慣性スクロールはそのまま効く。
    /// 一方、端での跳ね返り(ラバーバンド)はNSScrollView標準のものが使えなくなり、
    /// 可動範囲でぴたりと止まる(ScrollViewBounds.scroll(to:)がクランプするため)。
    /// このアプリは端に着いたかどうかでページ送り・回り込みを判断する作りなので、
    /// 端が伸び縮みしないほうがむしろ挙動が読みやすい。
    ///
    /// 符号について(実機のスクロールイベントを約500件記録して確定させたもの)。
    /// AppKit標準のスクロールは、正規化後のposition(ScrollViewBounds.position)を
    /// **縦横とも** `position -= delta` の向きへ動かす。したがって反転はその逆、
    /// 縦横とも `position += delta` でよい。
    ///
    /// 経緯(ユーザー報告): 「縦は反転するが横だけ効かない」という報告に対し、当初は
    /// AppKitの符号規約が縦横で非対称なのだろうと考えて横の符号を入れ替え、さらには実機の
    /// 挙動から符号を自動較正する仕組みまで入れたが、いずれも外れだった。実際にイベントを
    /// 記録して測ったところ規約は完全に対称で、真の原因は較正が横について一度も完了せず、
    /// 既定値がたまたま標準と同じ向きだったことだった。規約が対称だと確定した以上、較正の
    /// 仕組みは不要な複雑さなので撤去してある。**この式を「直す」前に、まず実測すること。**
    /// - Returns: 実際にスクロールを引き受けたかどうか(スクロールできる状態でなければfalse)。
    @discardableResult
    private func performInvertedScroll(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        guard isPageAreaScrollable,
              let bounds = ScrollViewBounds(scrollGeometryBox.scrollView) else { return false }
        guard deltaX != 0 || deltaY != 0 else { return true }
        let position = bounds.position
        bounds.scroll(to: CGPoint(x: position.x + deltaX, y: position.y + deltaY))
        return true
    }

    /// トラックパッドの「ページ間をスワイプ」ジェスチャーが3本指/4本指設定になっている
    /// 場合の処理。この場合はNSEvent.swipeという専用のイベント種別で届く(2本指設定の
    /// 場合は専用イベントではなく通常の.scrollWheelイベントとして届くため、
    /// handleTrackpadScrollGestureで別途処理している。詳細は呼び出し元のコメント参照)。
    /// 設定がONのときだけ、ホイールと同じ割り当て(既定はページ送り)として扱う。
    ///
    /// 2本指設定の場合(handleTrackpadScrollGesture)は、ジェスチャー全体をまとめて
    /// 一度だけ判定する作りになっているため、1回のスワイプで複数回反応してしまう心配は
    /// 構造的にない。一方、この3本指/4本指設定の場合に.swipeイベントが1回のフリックに対して
    /// 実際に何回発生するのかは動作確認ができておらず不明なため、念のため
    /// swipeActionCooldownによる連続発火防止を残している(handleScrollのwheelActionCooldownと
    /// 同じ考え方)。
    private func handleSwipe(deltaX: CGFloat) {
        guard preferences.treatTrackpadFlickAsWheel else { return }

        let now = Date()
        if let lastSwipeActionAt, now.timeIntervalSince(lastSwipeActionAt) < swipeActionCooldown {
            return
        }
        lastSwipeActionAt = now

        // NSEvent.swipeのdeltaXは、指を左から右へ払う(スワイプする)と正の値になる。
        // 修飾キー付きのスワイプは扱わない(ホイールの素の割り当てをそのまま使う)。
        if deltaX > 0 {
            perform(wheelAction(.up))
        } else if deltaX < 0 {
            perform(wheelAction(.down))
        }
    }

    /// トラックパッドの「ページ間をスワイプ」ジェスチャーが2本指設定になっている場合の処理。
    /// 呼び出し元(scrollMonitorの.scrollWheelケース)のコメントに書いたとおり、この場合の
    /// ジェスチャーは専用のイベント種別ではなく、通常の.scrollWheelイベントの並びとして届く。
    /// 指が触れてから離れるまで(phaseが.beganで始まり.endedで終わる一連のイベント)を
    /// 1回のジェスチャーとしてまとめ、その間のdeltaX/deltaYを積算しておいて、ジェスチャーが
    /// 終わった時点で初めて「横方向優位だったか、縦方向優位だったか」を判定する。
    ///
    /// - 横方向優位だった場合: 意図的なページ送りスワイプとみなし、その時点で1回だけ
    ///   ページ送りを行う(1個ずつのイベントに反応するわけではないので、1回のスワイプで
    ///   複数回ページ送りされてしまうことはない)。
    /// - 縦方向優位だった場合: 2本指の縦スクロールとみなし、何もしない(完全に無視する)。
    ///
    /// 指を離した後の慣性スクロール(momentumPhase)中のイベントは、呼び出し元で
    /// phaseが空になるため、ここではそのまま無視される(判定は指を離した瞬間の
    /// ジェスチャーの向きだけで決まる)。
    private func handleTrackpadScrollGesture(phase: NSEvent.Phase, deltaX: CGFloat, deltaY: CGFloat) {
        if phase.contains(.began) {
            trackpadGestureDeltaX = 0
            trackpadGestureDeltaY = 0
        }
        guard !phase.isEmpty else { return }
        trackpadGestureDeltaX += deltaX
        trackpadGestureDeltaY += deltaY

        guard phase.contains(.ended) else { return }
        defer {
            trackpadGestureDeltaX = 0
            trackpadGestureDeltaY = 0
        }

        // 極端に小さい動き(触れただけ、など)まで反応しないよう、最低限の移動量を求める。
        guard abs(trackpadGestureDeltaX) >= 10 else { return }
        guard abs(trackpadGestureDeltaX) > abs(trackpadGestureDeltaY) else { return }

        // ジェスチャー全体につき、ここに到達するのは(.endedを受け取る)1回だけなので、
        // handleSwipeのような連続発火防止のクールダウンは不要。

        // 指を左から右へ払う(スワイプする)と、積算したdeltaXは正の値になる。
        // 修飾キー付きのスワイプは扱わない(handleSwipeと同じ)。
        if trackpadGestureDeltaX > 0 {
            perform(wheelAction(.up))
        } else {
            perform(wheelAction(.down))
        }
    }

    private func registerMouseActivity() {
        if isCursorHidden {
            NSCursor.unhide()
            isCursorHidden = false
        }
        cursorHideTask?.cancel()
        guard preferences.autoHideCursor else { return }
        let delaySeconds = max(preferences.cursorAutoHideDelay, 0.1)
        cursorHideTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // 念のための保険: このウインドウが今アクティブでなければ隠さない。
                // 通常はウインドウが非アクティブになった時点でdidResignKeyNotification
                // (setUpWindowObservers参照)によりこのタスク自体がキャンセルされるはずだが、
                // タイミングによっては間に合わない可能性があるため、発火時にも再確認する。
                guard hostWindow?.isKeyWindow == true else { return }
                // メニューバーのメニューを開いている間、またはカーソルがメニューバー上に
                // ある間は、マウスを動かさなくても隠さない。
                guard !isMenuTracking, !isCursorOverMenuBar() else { return }
                NSCursor.hide()
                isCursorHidden = true
            }
        }
    }

    /// 現在のマウスカーソルの位置(スクリーン座標)が、メニューバーの帯の中にあるかどうか。
    /// メニューバーはメニューが開いていなくてもカーソルを乗せて操作する対象なので、
    /// 自動非表示のタイマーが発火する瞬間にここにカーソルがあれば隠さないようにする。
    private func isCursorOverMenuBar() -> Bool {
        guard let screen = NSScreen.main else { return false }
        let mouseLocation = NSEvent.mouseLocation
        guard screen.frame.contains(mouseLocation) else { return false }
        // メニューバーの帯は、画面全体のframeのうち、Dock/メニューバーを除いたvisibleFrameの
        // 上端からframeの上端までの部分(Dockが画面上部にある設定の場合は理論上ズレるが、
        // メニューバー自体は常に画面最上部にあるため、実用上はこれで十分)。
        return mouseLocation.y >= screen.visibleFrame.maxY
    }

    /// このビューを表示しているウインドウのフルスクリーン入退場・キーウインドウからの離脱を
    /// 監視し、あわせてマウス移動イベントを受け取れるようにする。WindowAccessor経由で
    /// ウインドウを取得できた時点(1回だけ)で呼ばれる。
    private func setUpWindowObservers(for window: NSWindow?) {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers = []
        guard let window else { return }

        // 既定では、ウインドウはマウスのドラッグを伴わない単純な移動(.mouseMoved)の
        // イベントを受け取らない設定になっている。これが無効なままだと、カーソル自動非表示
        // 機能で「隠れたあとウインドウ内でマウスを動かしても再表示されない」不具合が起きる
        // (ウインドウの外に出て初めて、OS側の別の仕組みで再表示されたように見えてしまう)。
        window.acceptsMouseMovedEvents = true

        isFullScreen = window.styleMask.contains(.fullScreen)
        isToolbarAutoRevealed = true
        isProgressBarAutoRevealed = true

        // 「ブックマークの編集」ウインドウ・「お気に入りの整理」ウインドウの「現在の本を追加」が
        // 「今読んでいる本」を特定できるように、このウインドウが(本を表示しているウインドウとして)
        // キーウインドウになるたびにLaunchCoordinatorへ通知しておく。この時点で既にキーウインドウに
        // なっている可能性がある(setUpWindowObservers自体がonAppear経由で呼ばれるため)ので、
        // 通知を待たずにここでも一度呼んでおく。
        launchCoordinator.setActiveBookAppState(appState)

        // Fileメニューの標準「閉じる」(Cmd+W)を「本を閉じる」動作に変更する。既に何らかの
        // デリゲートが設定されている場合(SwiftUI/AppKitがタブ管理や状態復元のために設定して
        // いることがある)は、windowShouldClose以外のメソッドをすべてそちらへ転送するので、
        // 既存の機能を壊さない(BookClosingWindowDelegate参照)。
        //
        // バグ修正: 以前は`if bookClosingDelegate == nil`だけで判定していた。しかしこの
        // ViewerViewはContentView側の`.id(book.id)`により本を切り替えるたびに作り直され、
        // @Stateであるこのプロパティも毎回nilから始まるため、同じウインドウで本を切り替える
        // たびに新しいデリゲートを被せてしまい、originalDelegate(強参照)のチェーンが
        // 1段ずつ際限なく伸びていた。AppKitはresponds(to:)/forwardingTarget(for:)を高頻度で
        // 呼ぶため、伸びた段数がそのまま無駄なコストになる。既に自前のデリゲートが付いている
        // ウインドウでは、それを再利用して参照先だけ今の本のものへ差し替える。
        if let existing = window.delegate as? BookClosingWindowDelegate {
            existing.appState = appState
            existing.window = window
            existing.preferences = preferences
            bookClosingDelegate = existing
        } else if bookClosingDelegate == nil {
            let delegate = BookClosingWindowDelegate()
            delegate.appState = appState
            delegate.originalDelegate = window.delegate
            delegate.window = window
            delegate.preferences = preferences
            window.delegate = delegate
            bookClosingDelegate = delegate
        }
        // ウインドウ左上の赤い閉じるボタンは、標準では上のwindowShouldCloseを経由してしまい
        // (「本だけ閉じる」動作が優先されてしまう)、常にウインドウ自体を閉じてほしいという
        // 要望と食い違う。そのため、このボタンのtarget/actionだけを直接差し替えて、
        // windowShouldCloseを経由しない専用のforceCloseWindow(_:)を呼ぶようにする。
        if let closeButton = window.standardWindowButton(.closeButton) {
            closeButton.target = bookClosingDelegate
            closeButton.action = #selector(BookClosingWindowDelegate.forceCloseWindow(_:))
        }

        let enter = NotificationCenter.default.addObserver(
            forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main
        ) { _ in
            isFullScreen = true
            isToolbarAutoRevealed = true
            isProgressBarAutoRevealed = true
        }
        let exit = NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
        ) { _ in
            isFullScreen = false
            isToolbarAutoRevealed = true
            isProgressBarAutoRevealed = true
        }
        // NSCursor.hide()/unhide()はウインドウ単位ではなくアプリ全体に効く。そのため、
        // このウインドウがアクティブでなくなった(環境設定ウインドウや他のqooViewer
        // ウインドウに切り替わった)ときは、予約済みの「しばらくしたら隠す」タイマーを
        // 直ちにキャンセルし、隠れていたら再表示しておく。これがないと、バックグラウンドに
        // 回ったこのウインドウのタイマーが後から発火し、今操作している別のウインドウの
        // カーソルまで隠してしまう不具合が起きる。
        let resignKey = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { _ in
            cursorHideTask?.cancel()
            cursorHideTask = nil
            if isCursorHidden {
                NSCursor.unhide()
                isCursorHidden = false
            }
        }
        // メニューバーのメニュー(このアプリのもの)が開いている間は、マウスを動かさなくても
        // カーソルを隠さないようにする。object: nilなので、このアプリ内のどのメニュー
        // (メニューバーだけでなく右クリックメニュー等も含む)が開いても反応する。
        let menuBegin = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { _ in
            isMenuTracking = true
            cursorHideTask?.cancel()
            cursorHideTask = nil
            if isCursorHidden {
                NSCursor.unhide()
                isCursorHidden = false
            }
            // ここには以前、「メニューが開いたらページ一覧(サムネイルグリッド)を閉じる」
            // 予約(pendingThumbnailGridDismissAfterMenu)を置いていた。メニューバーを
            // クリックしても閉じたい、という当時の要望に対して、メニューを開くクリックだけは
            // NSEventのモニタに届かないため、ここで補っていたもの。
            //
            // その要望は撤回され、閉じる条件は「画像表示領域のクリック」等に限定された
            // (installThumbnailGridDismissMonitorIfNeededのコメント参照)。加えて、
            // サムネイルの右クリックにコンテキストメニューを付けた以上、
            // 「メニューが開いたら閉じる」を残すとパネル自身のメニューを出した瞬間に
            // パネルが消えてしまう。そのため予約ごと削除してある。
        }
        let menuEnd = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { _ in
            isMenuTracking = false
            registerMouseActivity()
        }
        // 「ブックマークの編集」ウインドウ・「お気に入りの整理」ウインドウの「現在の本を追加」用
        // (上のlaunchCoordinator.setActiveBookAppState(appState)の初回呼び出しと同じ理由。
        // このウインドウが後から再びキーウインドウになるたびに更新し直す)。
        // バグ修正(ビルド時のエラー): NotificationCenter.addObserverのクロージャ自体は
        // (queue: .mainで実行時には必ずメインスレッドだとしても)コンパイラの目には
        // メインアクターに隔離されたコンテキストとして見えないため、メインアクター隔離の
        // launchCoordinator.setActiveBookAppState(_:)をここで直接呼ぶとエラーになる
        // (Swift 6言語モード)。Task { @MainActor in ... }で明示的にメインアクターへ
        // 渡してから呼ぶ。
        let becomeKey = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { _ in
            Task { @MainActor in
                launchCoordinator.setActiveBookAppState(appState)
            }
        }
        windowObservers = [enter, exit, resignKey, menuBegin, menuEnd, becomeKey]

        // バグ修正(ユーザー報告): 上のenter/exit/resignKey/becomeKeyはobject: windowで
        // 登録しており、この購読はhandleOnDisappear()でも解除されるが、そちらはSwiftUIの
        // .onDisappearで駆動されるため、実際にこのウインドウが閉じる(NSWindowが破棄される)
        // タイミングより後になることがある(SwiftUIの状態変化→再描画は非同期で、
        // windowShouldCloseの中でappState.closeBook()を呼んでcurrentBookをnilにしても、
        // ViewerViewのonDisappearが実際に走ってこの購読を解除し終える前に、ウインドウ自体は
        // 閉じてしまいうる)。NotificationCenterのobject:によるフィルタはポインタ一致で
        // 行われるため、解除し損ねた購読が残っている間に、閉じたウインドウとたまたま同じ
        // メモリアドレスに新しいNSWindowが確保されると、その新しいウインドウ宛ての通知
        // (didBecomeKeyNotificationなど)にこの古い(本来ならもう無効な)購読が誤って反応して
        // しまう。実機で、これが原因と見られる「unrecognized selector」例外(ウインドウを
        // 閉じてすぐ外部から本を開き直すと発生)が確認された。
        // ここでウインドウが閉じる(NSWindow.willCloseNotification、実際に閉じる直前に
        // 同期的に発火する)タイミングで、自分自身を含めて確実に解除する。
        //
        // この購読自身もwindowObserversへ加えてから登録を終える。こうしておけば、下の
        // クロージャがwindowObserversを丸ごと解除する時点で自分自身も含まれるため、
        // 「自分のトークンを覚えておいて後で解除する」ためのローカル変数が要らなくなる
        // (ローカルのvarをエスケープするクロージャがキャプチャして読むと、Swift 6の
        // 並行性チェックが「mutated after capture by sendable closure」として警告する。
        // 詳細はNotificationObserverTokensの型コメント参照)。
        let closeToken = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            for observer in windowObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            windowObservers = []
            // 予防: appState/viewModelへ登録した橋渡しクロージャの解除も、ここで行っておく。
            // これらのクロージャはViewerView(struct)のコピーごとappState・viewModelを
            // 強参照しており、解除されるまでAppState/ViewerViewModelは解放されない
            // (clearAppStateBridgesIfStillOwnerのコメント参照)。通常は.onDisappearが
            // 解除するが、そちらは上の購読と同じ理由で、実際にウインドウが閉じるより後に
            // なることがある。ここで先に解除しておいても、後から走る.onDisappear側は
            // 同じ処理を繰り返すだけで副作用は無い。
            //
            // queue: .mainを指定しているため実行時には必ずMainActor上で呼ばれるが、
            // クロージャ自体の型は静的にMainActor隔離だと分からないため、MainActor隔離の
            // viewModelのプロパティへの代入をそのまま書くと警告になる(Swift 6言語モードでは
            // エラー)。プロジェクト内の他の箇所(BookmarkStore.init/ViewerViewModel.initなど)と
            // 同じくMainActor.assumeIsolatedで「実行時には既にMainActor上にいる」ことを伝える。
            MainActor.assumeIsolated {
                clearAppStateBridgesIfStillOwner()
                viewModel.onPageBoundaryRequest = nil
                // handleOnDisappearと同じ理由で、資源の解放もここから先に行っておく
                // (releaseResourcesは二度呼んでも何もしない)。
                viewModel.releaseResources()
            }
        }
        windowObservers.append(closeToken)
    }

    /// フルスクリーン表示中、または表示メニューの「ツールバーを隠す」「プログレスバーを隠す」の
    /// どちらかがONのウインドウ表示中に、マウスカーソルが画面(ウインドウ)の上端または下端に
    /// 近づいたときだけツールバー・プログレスバーを表示する。どちらの自動隠しも有効でない
    /// (フルスクリーンでなく、かつ両方の設定がOFFの)ときは何もしない(常に表示するため)。
    /// カーソルのx座標と同様、実際に表示が変わる(=真偽値が反転する)ときだけ@Stateを
    /// 書き換える(過去のプログレスバーの不具合の反省を踏まえた安全策)。
    ///
    /// 表示するのは、環境設定「表示までの時間」(ツールバーとプログレスバーで別々に設定できる。
    /// 既定はどちらも0=即時)ぶん待ってから(scheduleToolbarReveal参照)。隠すほうは待たない。
    private func updateAutoHiddenChromeVisibility(forMouseLocationInWindow location: CGPoint) {
        // 拡大鏡(ルーペ)表示中は、カーソルを画面の上下端に近づけてもツールバー/
        // プログレスバーを自動表示させない(ユーザー要望: 拡大鏡での閲覧を妨げないため)。
        guard !appState.isLoupeActive else {
            hideAutoRevealedChromeNow()
            return
        }
        guard toolbarAutoHides || progressBarAutoHides,
              hostWindow != nil else {
            // 自動隠し自体が無効なときは、サイドパネル側から見て「ツールバー/プログレスバーが
            // 今まさに表示されている」という誤情報にならないよう、必ず false に戻しておく。
            cancelPendingChromeReveal()
            if appState.isChromeAutoRevealed {
                appState.isChromeAutoRevealed = false
            }
            return
        }
        // 上端(ツールバー側)の判定には、window.contentView.frame.heightからツールバーの高さを
        // 引いて逆算する方式は使わない。タイトルバーの実装の都合でcontentHeightが実際の
        // ツールバーの表示位置と微妙にズレることがあり(タブバーの有無による影響とは別の要因)、
        // ツールバーの上のほうにカーソルがあるうちは表示されるのに、少し下(ボタンの下半分など)に
        // 動かすと反応領域から外れて隠れてしまう不具合があったため。代わりに、
        // toolbarBottomYInWindow(実際に表示されているツールバーの下端の、ウインドウ座標系での
        // Y座標。WindowYPositionAccessor経由でAppKitから直接取得。タイトルバー・タブバーの
        // 表示有無による位置のズレも自動的に反映される)より上にマウスがあるかどうかで判定する。
        // 下端(プログレスバー側)は、ウインドウ座標系の原点(y=0)がそのままウインドウ最下端に
        // 対応するため、実測したプログレスバーの高さ(progressBarHeight)とlocation.yを
        // そのまま比較すればよい。
        let shouldShow = location.y >= toolbarBottomYInWindow || location.y < progressBarHeight
        // サイドパネル(hideSidePanel == trueでホバー表示中)が既にカーソルの主導権を握って
        // いる場合、新たにツールバー/プログレスバーを表示させない(ユーザー報告: サイドパネルを
        // 表示した状態でカーソルを上へ動かすと、ツールバーまで表示されてしまっていた)。
        // 既に表示中のものを隠す方向(shouldShow == false)には影響しない。
        guard shouldShow else {
            hideAutoRevealedChromeNow()
            return
        }
        if !isToolbarAutoRevealed, !isProgressBarAutoRevealed, appState.isSidePanelRevealed {
            cancelPendingChromeReveal()
            return
        }
        // 表示するのは「表示までの時間」(環境設定、既定0=即時)が経ってから。
        // 帯に入っているあいだのマウス移動でここへ何度来ても、待機中のタスクは積み直さない。
        if toolbarAutoHides {
            scheduleToolbarReveal()
        }
        if progressBarAutoHides {
            scheduleProgressBarReveal()
        }
    }

    /// 自動表示中のツールバー/プログレスバーを、表示待ちのタスクごと今すぐ取り下げる。
    /// カーソルが帯から出たとき・ウインドウの外へ出たとき(AppState.hideAutoRevealedChrome
    /// 経由)・拡大鏡をONにしたときの、共通の後始末。
    ///
    /// 値が変わるときだけ書き戻す(@Publishedは同じ値の再代入でもobjectWillChangeを発火させ、
    /// マウスを動かすたびにウインドウ全体が無駄に再評価されてしまうため。
    /// ContentView.dismissAutoRevealedChromeIfCursorLeftWindowのコメント参照)。
    private func hideAutoRevealedChromeNow() {
        cancelPendingChromeReveal()
        if isToolbarAutoRevealed {
            isToolbarAutoRevealed = false
        }
        if isProgressBarAutoRevealed {
            isProgressBarAutoRevealed = false
        }
        if appState.isChromeAutoRevealed {
            appState.isChromeAutoRevealed = false
        }
    }

    /// 表示待ちのタスクをすべて取り消す。
    ///
    /// nilのときに何もしないのは意味の無い代入を避けるためだけではない。ここはカーソルが帯の
    /// 外にある間、マウスを動かすたびに呼ばれる経路にあり、@Stateへ代入すればTaskは
    /// Equatableでないため毎回ビューの再評価が走ってしまう。
    private func cancelPendingChromeReveal() {
        cancelToolbarRevealTask()
        cancelProgressBarRevealTask()
    }

    private func cancelToolbarRevealTask() {
        guard let task = toolbarRevealTask else { return }
        task.cancel()
        toolbarRevealTask = nil
    }

    private func cancelProgressBarRevealTask() {
        guard let task = progressBarRevealTask else { return }
        task.cancel()
        progressBarRevealTask = nil
    }

    /// ツールバーを「表示までの時間」(環境設定。ツールバー・プログレスバー・サイドパネルで
    /// それぞれ独立)だけ待ってから表示する。0(既定)ならその場で表示する。
    ///
    /// 待っている間にカーソルが帯から出れば、updateAutoHiddenChromeVisibilityが
    /// hideAutoRevealedChromeNow()を呼んでこのタスクを取り消すので、何も表示されないまま終わる
    /// (ユーザー要望: 別のウインドウやメニューバーへ移動したいだけのときに、通りすがりで
    /// 隠している部分が反応してしまうのを避けるため)。
    private func scheduleToolbarReveal() {
        guard !isToolbarAutoRevealed else { return }
        let delay = preferences.toolbarRevealDelayNanoseconds
        guard delay > 0 else {
            cancelToolbarRevealTask()
            revealToolbarNow()
            return
        }
        // 既に待機中なら積み直さない。積み直すと、帯の中でカーソルを動かし続けている限り
        // いつまでも表示されないことになる。
        guard toolbarRevealTask == nil else { return }
        toolbarRevealTask = Task {
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                toolbarRevealTask = nil
                guard isAutoRevealBandStillActive() else { return }
                revealToolbarNow()
            }
        }
    }

    /// プログレスバー側の同じもの(scheduleToolbarReveal参照)。待ち時間だけが別の設定値になる。
    private func scheduleProgressBarReveal() {
        guard !isProgressBarAutoRevealed else { return }
        let delay = preferences.progressBarRevealDelayNanoseconds
        guard delay > 0 else {
            cancelProgressBarRevealTask()
            revealProgressBarNow()
            return
        }
        guard progressBarRevealTask == nil else { return }
        progressBarRevealTask = Task {
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                progressBarRevealTask = nil
                guard isAutoRevealBandStillActive() else { return }
                revealProgressBarNow()
            }
        }
    }

    private func revealToolbarNow() {
        if !isToolbarAutoRevealed {
            isToolbarAutoRevealed = true
        }
        if !appState.isChromeAutoRevealed {
            appState.isChromeAutoRevealed = true
        }
    }

    private func revealProgressBarNow() {
        if !isProgressBarAutoRevealed {
            isProgressBarAutoRevealed = true
        }
        if !appState.isChromeAutoRevealed {
            appState.isChromeAutoRevealed = true
        }
    }

    /// 待ち時間が明けた瞬間に、「今もカーソルが上端/下端の帯の中にあり、表示してよい状態か」を
    /// 現在のカーソル位置から確かめ直す。
    ///
    /// 待っている間にカーソルがウインドウの外(メニューバー・他のアプリのウインドウ)へ抜けると、
    /// このビューのローカルモニタには.mouseMovedが届かず、タスクが取り消されないまま残ることが
    /// ある。「メニューバーへ移動したいだけなのに反応する」のを避けるための設定なので、ここで
    /// 取りこぼすと目的そのものを外す。判定内容はupdateAutoHiddenChromeVisibilityと同じで、
    /// 入力をイベントの座標ではなく現在のカーソル位置(NSEvent.mouseLocation)に替えただけ。
    private func isAutoRevealBandStillActive() -> Bool {
        guard !appState.isLoupeActive else { return false }
        guard toolbarAutoHides || progressBarAutoHides else { return false }
        // 待っている間にサイドパネルが先に開いたら、そちらに主導権を譲る
        // (updateAutoHiddenChromeVisibilityの同じ判定と揃えてある)。
        guard !appState.isSidePanelRevealed else { return false }
        guard let window = hostWindow, window.isKeyWindow else { return false }
        let screenLocation = NSEvent.mouseLocation
        guard window.frame.contains(screenLocation) else { return false }
        // locationInWindowと同じ座標系(ウインドウのフレーム左下が原点)へ変換してから、
        // 上端/下端の帯の判定にかける。
        let location = window.convertPoint(fromScreen: screenLocation)
        return location.y >= toolbarBottomYInWindow || location.y < progressBarHeight
    }

    /// メニューバーの各種チェックマーク・グレーアウト状態を、現在のviewModelの値で更新する。
    /// スライドショー/表示モード/読み方向/拡大縮小モード/現在ページ(EPUBによる各種ロック状態の
    /// 判定に必要)のいずれかが変化するたびに呼ぶ(onAppearでの初期反映、および各onChangeから
    /// 使う)。呼び出し箇所を1つにまとめることで、新しい状態を追加したときに一部のonChangeだけ
    /// 直し忘れる、というミスを防ぐ。
    private func syncMenuCheckmarkState() {
        appState.updateMenuCheckmarkState(
            isSlideshowActive: viewModel.isSlideshowActive,
            isLoupeActive: viewModel.isLoupeActive,
            displayMode: viewModel.displayMode,
            readingDirection: viewModel.readingDirection,
            scalingMode: viewModel.scalingMode,
            isContrastCorrectionEnabled: viewModel.isContrastCorrectionEnabled,
            isPageShiftLocked: viewModel.isPageShiftLocked,
            hasPartnerPageDisplayed: partnerPageIndex != nil,
            hasCurrentPageLayoutOverride: viewModel.hasPageLayoutOverride(atIndex: viewModel.currentIndex),
            hasPartnerPageLayoutOverride: partnerPageIndex.map { viewModel.hasPageLayoutOverride(atIndex: $0) } ?? false
        )
    }

    /// 操作(キー/マウス)に対応する実際の処理を行う
    private func perform(_ action: ViewerAction?) {
        guard let action else { return }
        switch action {
        case .spatialLeft:
            viewModel.advance(forward: viewModel.readingDirection == .rightToLeft)
        case .spatialRight:
            viewModel.advance(forward: viewModel.readingDirection == .leftToRight)
        case .moveNext:
            viewModel.advance(forward: true)
        case .movePrevious:
            viewModel.advance(forward: false)
        case .shiftOnePageLeft:
            viewModel.shiftByOnePage(forward: viewModel.readingDirection == .rightToLeft)
        case .shiftOnePageRight:
            viewModel.shiftByOnePage(forward: viewModel.readingDirection == .leftToRight)
        case .firstPage:
            viewModel.jump(toPageIndex: 0)
        case .lastPage:
            viewModel.jump(toPageIndex: viewModel.pageCount - 1)
        // 画面上の右端/左端に来る側へ飛ぶ。右開き(右→左に読み進む)なら右端が先頭ページ、
        // 左開きなら右端が最終ページになる(spatialLeft/spatialRightと同じ判定の仕方)。
        case .spatialEndRight:
            viewModel.jump(
                toPageIndex: viewModel.readingDirection == .rightToLeft
                    ? 0 : viewModel.pageCount - 1
            )
        case .spatialEndLeft:
            viewModel.jump(
                toPageIndex: viewModel.readingDirection == .rightToLeft
                    ? viewModel.pageCount - 1 : 0
            )
        case .jumpToPercentile0, .jumpToPercentile10, .jumpToPercentile20, .jumpToPercentile30,
             .jumpToPercentile40, .jumpToPercentile50, .jumpToPercentile60, .jumpToPercentile70,
             .jumpToPercentile80, .jumpToPercentile90:
            if let percentile = action.jumpPercentile {
                viewModel.jump(toPercentile: percentile)
            }
        case .scrollAndMoveNext:
            scrollByOneScreen(forward: true)
        case .scrollAndMovePrevious:
            scrollByOneScreen(forward: false)
        case .scrollScreenDown:
            scrollVerticallyByOneScreen(down: true, bounds: ScrollViewBounds(scrollGeometryBox.scrollView))
        case .scrollScreenUp:
            scrollVerticallyByOneScreen(down: false, bounds: ScrollViewBounds(scrollGeometryBox.scrollView))
        case .scrollToPageStart:
            scrollToPageCorner(atEnd: false)
        case .scrollToPageEnd:
            scrollToPageCorner(atEnd: true)
        case .scrollAndMoveSpatialLeft:
            scrollByOneScreen(forward: viewModel.readingDirection == .rightToLeft)
        case .scrollAndMoveSpatialRight:
            scrollByOneScreen(forward: viewModel.readingDirection == .leftToRight)
        case .scrollUp:
            scrollByStep(dx: 0, dy: -1)
        case .scrollDown:
            scrollByStep(dx: 0, dy: 1)
        case .scrollLeft:
            scrollByStep(dx: -1, dy: 0)
        case .scrollRight:
            scrollByStep(dx: 1, dy: 0)
        case .toggleDisplayMode:
            viewModel.toggleDisplayMode()
        case .toggleReadingDirection:
            viewModel.toggleReadingDirection()
        case .cycleScalingMode:
            viewModel.cycleScalingMode()
        case .toggleContrastCorrection:
            viewModel.toggleContrastCorrection()
        case .autoLayoutFromCurrentView:
            // ツールバーのボタン・メニューバー「Edit」のレイアウトのグループの項目と
            // 同じ経路(3.1節)。
            // DBへ書かない本ではレイアウトを保存できないので何もしない(以下の
            // ブックマーク/お気に入り系も同じ。キー割り当てから直接届く経路を塞ぐため)。
            guard !viewModel.skipsPersistence else { return }
            isShowingAutoLayoutConfirmation = true
        case .previousBook:
            appState.openSibling(before: viewModel.book.sourceURL)
        case .nextBook:
            appState.openSibling(after: viewModel.book.sourceURL)
        case .toggleBookmark:
            guard !viewModel.skipsPersistence else { return }
            toggleCurrentPageBookmark()
        case .nextBookmark:
            viewModel.jumpToNextBookmark()
        case .previousBookmark:
            viewModel.jumpToPreviousBookmark()
        case .showBookmarkList:
            guard !viewModel.skipsPersistence else { return }
            showBookmarkEditor()
        case .showThumbnailGrid:
            // トグル。開いたときと同じキー/マウス操作でそのまま閉じられるようにするため
            // (ユーザー要望)。以前はtrueを代入するだけで、閉じる手段はパネルの外側を
            // クリックするか、ページを選ぶかしかなかった。
            showThumbnailGrid.toggle()
        case .toggleSlideshow:
            viewModel.toggleSlideshow()
        case .toggleLoupe:
            viewModel.toggleLoupe()
        case .showActualSizeLeft:
            showActualSizeWindow(forLeftPage: true)
        case .showActualSizeRight:
            showActualSizeWindow(forLeftPage: false)
        case .toggleFavorite:
            guard !viewModel.skipsPersistence else { return }
            toggleCurrentBookFavorite()
        case .showFavoritesList:
            showFavoritesListMenu()
        case .showFavoritesOrganizer:
            guard !viewModel.skipsPersistence else { return }
            openWindow(id: "favoritesOrganizer")
        // ウインドウを閉じる: 赤い閉じるボタン・メニューバーの「ウインドウを閉じる」と
        // **同じ経路**を通す(複数タブの確認ダイアログもそちらの設定に従って出る)。
        // 差し替えた専用のデリゲートが見つからない場合だけ、素のperformCloseへ落とす
        // (QooViewerApp.swiftのCommandGroup(before: .windowArrangement)と同じ書き方)。
        case .closeWindow:
            guard let hostWindow else { return }
            if let delegate = hostWindow.delegate as? BookClosingWindowDelegate {
                delegate.forceCloseWindow(nil)
            } else {
                hostWindow.performClose(nil)
            }
        // タブを閉じる: このタブ(=このNSWindow)1枚だけを、確認なしで閉じる。
        //
        // **NSWindow.performClose(_:)は使えない。** このアプリはウインドウの赤い閉じるボタンの
        // target/actionをforceCloseWindow(_:)へ差し替えており(setUpWindowObservers参照)、
        // performCloseは「その閉じるボタンを押したのと同じ」振る舞いになる ―― 実機で、
        // タブを2枚開いた状態でこの操作を行うと**複数タブの確認ダイアログが出て、タブグループ
        // ごと閉じられる**ことを確認した(performCloseがwindowShouldCloseだけを通る、という
        // 前提は今のmacOSでは成り立っていない)。それでは上のcloseWindowと同じものになって
        // しまうので、closeを直接呼ぶ。
        //
        // 閉じる前にcloseBook()を呼ぶのは、開いていた本のセキュリティスコープ付きアクセスを
        // その場で手放すため(windowShouldCloseがやっているのと同じ後始末)。
        case .closeTab:
            guard let hostWindow else { return }
            if appState.currentBook != nil {
                appState.closeBook()
            }
            hostWindow.close()
        case .quitApplication:
            NSApp.terminate(nil)
        case .none:
            break
        }
    }

    /// 「お気に入り一覧」ポップオーバーからお気に入りをクリックしたときの実際の分岐処理。
    /// QooViewerApp.swiftの同名メソッドと同じ考え方(環境設定「本を開く」の「お気に入りから」
    /// favoriteOpenBehaviorに従って、そのまま開く/新しいタブ/新しいウインドウを判定する)だが、
    /// ViewerView自身はQooViewerApp側のprivateなヘルパーを直接呼べないため、こちらでも
    /// 同じ判定を実装している。ViewerViewが表示されている時点で必ず本を表示しているはずだが、
    /// 念のためcurrentBookがnilの場合は常にそのまま開く形にフォールバックする。
    private func openFavoriteAccordingToPreference(_ favorite: FavoriteBook) {
        guard appState.currentBook != nil else {
            appState.openFavorite(favorite)
            return
        }
        switch preferences.favoriteOpenBehavior {
        case .replaceCurrentBook:
            appState.openFavorite(favorite)
        case .newTab:
            openFavorite(favorite, to: .newTab)
        case .newWindow:
            openFavorite(favorite, to: .newWindow)
        }
    }

    /// 「ブックマークの編集」ウインドウ(独立ウインドウ)を開く。ツールバーのブックマークアイコン
    /// (枠線)・メニューバー「Edit」→「Edit Bookmarks…」・bキーのどこから呼んでも、
    /// このメソッドを経由する。launchCoordinator.setActiveBookAppState(appState)を明示的に
    /// 呼んでおくことで、setUpWindowObservers側のdidBecomeKeyNotification通知を待たずに
    /// (念のため)確実にこの本を対象にしてからウインドウを開く。
    private func showBookmarkEditor() {
        launchCoordinator.setActiveBookAppState(appState)
        // メニューバー「Edit Bookmarks…」(QooViewerApp.swift)と同じく、開く直前に
        // .bookmarksを設定しておく。これが無いと、ウインドウが既に開いている状態で
        // 別の本を表示中にこのメソッドを呼び直しても、BookmarkEditorView側の選択中の本
        // (selectedBookID)が新しく表示している本へ再同期されない
        // (applyInitialFocusのコメント参照。ユーザー報告)。
        launchCoordinator.pendingEditorInitialFocus = .bookmarks
        openWindow(id: "editBookmarks")
    }

    /// 現在の見開きのブックマークを追加/削除する(トグル)。すでにどちらかのページに
    /// 付いていれば削除、どちらにも付いていなければ追加する(isCurrentPageBookmarked参照)。
    /// 削除は、見開きの起点ページ(currentIndex)・相方ページ(partnerPageIndex)の両方を対象に
    /// 探し、付いているものをすべて削除する(両方に付いていれば両方削除する。ユーザー要望)。
    /// 追加はViewerViewModel.addBookmark()(重複チェック込み)で常にcurrentIndex側に1件だけ
    /// 追加する(相方ページへは追加しない。追加の対象を2ページに広げてほしいという要望では
    /// なかったため)。削除はすべての本を横断するBookmarkStore.delete(_:)を直接呼ぶ
    /// (ViewerViewModelは削除処理自体を持たない。理由はViewerViewModel.addBookmark()直後の
    /// コメント参照)。削除後はNotification.Name.bookmarksDidChange経由でviewModel.bookmarksが
    /// 自動的に読み直される(ViewerViewModelのbookmarksChangeObserver参照)。
    ///
    /// 【重要】削除は必ずbookmarkStore.bookmarks(forBookID:)で取得し直したBookmarkに対して
    /// bookmarkStore.delete(_:)を呼ぶ形にする(viewModel.bookmarksの要素をそのまま渡す実装には
    /// しない)。
    ///
    /// 以前はBookmarkStoreがViewerViewModelとは別のModelContextインスタンスを持っており
    /// (本を開いていなくても操作できるようにするため)、SwiftDataのモデルはフェッチ元の
    /// ModelContextに紐づく関係で、別コンテキストのオブジェクトをdelete(_:)へ渡しても実際には
    /// 削除されない(エラーにもならず、静かに何も起きない)という制約があった。現在は
    /// QooViewerApp.init()の通りBookmarkStore/ViewerViewModelとも同じmodelContainer.mainContextを
    /// 共有しているため、この制約自体はもう無く、viewModel.bookmarksの要素を直接渡しても
    /// 削除できる。それでもbookmarkStore.bookmarks(forBookID:)経由で取得し直す形を維持している
    /// のは、bookmarkStore.delete(_:)がこのストア自身のキャッシュ無効化・bookmarksDidChange通知
    /// までまとめて行う唯一の削除口だからで(ViewerViewModel側に独自の削除処理を重複して持たせ
    /// ない設計。ViewerViewModel.addBookmark()直後のコメント参照)、コンテキストの分裂とは無関係に
    /// 引き続きこの経路を使う。
    private func toggleCurrentPageBookmark() {
        guard let bookmarkStore = appState.bookmarkStore else { return }
        let candidateIndices = [viewModel.currentIndex, partnerPageIndex].compactMap { $0 }
        let toDelete = bookmarkStore.bookmarks(forBookID: viewModel.book.id)
            .filter { candidateIndices.contains($0.pageIndex) }
            .sorted { $0.pageIndex < $1.pageIndex }

        if !toDelete.isEmpty {
            let names = toDelete.map(\.name)
            for bookmark in toDelete {
                bookmarkStore.delete(bookmark)
            }
            showToast(bookmarkRemovalToastMessage(for: names))
        } else if partnerPageIndex != nil, preferences.spreadBookmarkTargetBehavior == .askEachTime {
            // 見開き表示中(実際に2ページ組でペア表示されているとき)で、環境設定
            // (「Adding Bookmarks in Spread View」)が「実行するたびに尋ねる」の場合は、
            // ここでは追加を実行せず、左右どちらを対象にするか尋ねる確認ダイアログ
            // (isShowingBookmarkSideDialog。applyLayoutAlerts参照)を表示するだけに留める
            // (ユーザー報告: ツールバー/お気に入りメニューからのブックマーク追加対象の切り替え)。
            isShowingBookmarkSideDialog = true
        } else {
            // 単一ページ表示中(partnerPageIndexがnil。EPUB仕様の空白ページ表示を含む)、または
            // 環境設定が既定側(読み方向に応じた既定側を常に対象にする)の場合は、従来通り
            // currentIndex(見開きの起点ページ)を対象にする。
            addBookmarkWithToast(atIndex: viewModel.currentIndex)
        }
    }

    /// 指定したページにブックマークを追加し、追加できた場合はトーストで知らせる。
    /// toggleCurrentPageBookmark・見開き左右選択ダイアログ・コンテキストメニューの片側専用
    /// トグル(toggleBookmark(atIndex:))が共通して使う、実際の追加処理本体。
    private func addBookmarkWithToast(atIndex index: Int) {
        viewModel.addBookmark(atIndex: index)
        // addBookmark(atIndex:)は同期的にmodelContext.save()・reloadBookmarks()まで行うため、
        // 呼び出し直後の時点でviewModel.bookmarksは既に新しいブックマークを含んでいる。
        if let added = viewModel.bookmarks.first(where: { $0.pageIndex == index }) {
            showToast(
                String(
                    format: String(localized: "Added “%@” to Bookmarks", locale: preferences.effectiveLocale),
                    added.name
                )
            )
        }
    }

    /// コンテキストメニューから、見開きの片側(クリックした側)のページ単体を対象に
    /// ブックマークを追加/削除する(contextMenuContent参照)。ツールバー等の経路
    /// (toggleCurrentPageBookmark)と異なり、常にクリックした1ページだけを対象にする
    /// (相方ページには触れない。ユーザー報告: 見開き左の画像を右クリックしても見開き右が
    /// ブックマークされてしまう不具合の修正)。
    private func toggleBookmark(atIndex index: Int) {
        guard let bookmarkStore = appState.bookmarkStore else { return }
        if let existing = bookmarkStore.bookmarks(forBookID: viewModel.book.id).first(where: { $0.pageIndex == index }) {
            let name = existing.name
            bookmarkStore.delete(existing)
            showToast(bookmarkRemovalToastMessage(for: [name]))
        } else {
            addBookmarkWithToast(atIndex: index)
        }
    }

    /// コンテキストメニューのブックマーク項目(見開き表示中)のラベル文言。クリックした側
    /// (isLeft)と、そのページが既にブックマーク済みかどうかで4通りに切り替える。
    private func bookmarkContextMenuTitle(isLeft: Bool, isBookmarked: Bool) -> LocalizedStringKey {
        if isBookmarked {
            return isLeft ? "Remove Left Page from Bookmarks" : "Remove Right Page from Bookmarks"
        }
        return isLeft ? "Add Left Page to Bookmarks" : "Add Right Page to Bookmarks"
    }

    /// ブックマーク削除時のトースト文言を組み立てる。見開きの両ページにブックマークが付いていて
    /// 2件同時に削除した場合は、両方の名前を含む専用の文言(ユーザー要望: 「削除メッセージは
    /// 2ページ分」)を使う。1件だけ削除した場合は、従来通り1件用の文言を使う。
    /// (namesはtoggleCurrentPageBookmark()側でpageIndex昇順にソート済みのため、見開き中は
    /// 常に「起点ページ→相方ページ」の順で名前が並ぶ)
    private func bookmarkRemovalToastMessage(for names: [String]) -> String {
        if names.count >= 2 {
            return String(
                format: String(localized: "Removed “%@” and “%@” from Bookmarks", locale: preferences.effectiveLocale),
                names[0], names[1]
            )
        }
        return String(
            format: String(localized: "Removed “%@” from Bookmarks", locale: preferences.effectiveLocale),
            names.first ?? ""
        )
    }

    /// 現在の本をお気に入りに追加/削除する(トグル)。すでに登録済みであれば(複数フォルダに
    /// 登録されている場合はすべて)削除し、未登録であれば登録先フォルダを選ぶダイアログ
    /// (showFavoriteFolderPicker)を開く。追加成功時のトースト表示は、フォルダ選択が絡む
    /// 非同期の操作になるため、ここではなくFavoriteFolderPickerViewのonAdded(sheet参照)から行う。
    private func toggleCurrentBookFavorite() {
        if isCurrentBookFavorited {
            let title = viewModel.book.title
            favoritesStore.removeFavorites(forBookID: viewModel.book.id)
            showToast(
                String(
                    format: String(localized: "Removed “%@” from Favorites", locale: preferences.effectiveLocale),
                    title
                )
            )
        } else {
            showFavoriteFolderPicker = true
        }
    }

    /// お気に入り・ブックマークの追加/削除トグルボタンを操作したときの結果を、画面中央下部に
    /// 一時的に表示する(ユーザー要望)。表示中に別の操作が行われた場合は、古い自動非表示
    /// タイマーをキャンセルしてから改めて表示時間を数え直す(短時間に連続して操作しても、
    /// 最後の1件が表示され続けている間に途中で消えてしまわないようにするため)。
    private func showToast(_ message: String) {
        toastDismissTask?.cancel()
        toastMessage = message
        toastDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            toastMessage = nil
        }
    }

    /// ツールバーの「お気に入り一覧」ボタン、およびキーボードショートカット
    /// (ViewerAction.showFavoritesList)のどちらからも呼ぶ、一覧の表示処理。
    /// ネイティブNSMenu(FavoritesNSMenuBridge)を組み立てて表示することで、メニューバー側と
    /// 同じくホバーでサブフォルダが展開する挙動になる(詳細はFavoritesNSMenuBridge.swiftの
    /// コメント参照)。項目をクリックしたときの実際の開き方は、他の入り口と同じく
    /// openFavoriteAccordingToPreference(環境設定「本を開く」の「お気に入りから」)に従う。
    private func showFavoritesListMenu() {
        let bridge = FavoritesNSMenuBridge(favoritesStore: favoritesStore) { favorite in
            openFavoriteAccordingToPreference(favorite)
        }
        favoritesMenuBridge = bridge
        bridge.show()
        // バグ修正: 以前はここで@Stateに入れたまま放置していた。onOpenに渡しているクロージャは
        // ViewerView(struct)のコピーを丸ごとキャプチャしており、そのコピーはこの@State自身
        // (favoritesMenuBridgeを保持している箱)を含むため、
        //   bridge → onOpen → ViewerViewのコピー → @Stateの箱 → bridge
        // という循環参照になっていた(handleOnAppearのonPageBoundaryRequestと同型で、
        // お気に入り一覧を一度でも開くと成立する)。show()内のNSMenu.popUpはメニューが
        // 閉じるまで戻らない同期呼び出しのため、ここへ戻ってきた時点でこのbridgeはもう不要。
        favoritesMenuBridge = nil
    }

    /// 「お気に入り一覧」ボタン(またはショートカット)から、指定したお気に入りを新しい
    /// ウインドウ/タブで開く。
    ///
    /// 以前はこの下に「ポーリングで増えたウインドウを見つけ、サイズと位置を整え、タブなら
    /// 親へ追加する」という手順を、ウインドウ用とタブ用に1つずつ、計2つ書いていた。
    /// 同じ手順がアプリ内に5つコピーされていた状態を解消するため、BookWindowOpenerへ
    /// 集約してある(そちらの型コメント参照)。移行にともなって、この経路にも
    /// 「すでに同じ本を開いているウインドウがあればそれを前面に出す」重複判定と、
    /// カスケード位置が画面からはみ出す場合の押し戻しが入る(メニューバー経由の
    /// 「新しいウインドウ/タブで開く」と挙動が揃う)。
    ///
    /// 見つからなかった場合は、通常の「開く」(AppState.openFavorite)と同じくアラートを出す。
    private func openFavorite(_ favorite: FavoriteBook, to destination: BookOpenDestination) {
        guard let url = favoritesStore.resolvedExistingURL(for: favorite) else {
            appState.missingFavorite = favorite
            return
        }
        // このウインドウから派生した操作なので、シークレットかどうか・タブの追加先は
        // このウインドウに揃える(BookWindowGroup / BookWindowOpener参照)。
        BookWindowOpener.open(
            BookOpenRequest(url),
            to: destination,
            from: appState,
            launchCoordinator: launchCoordinator,
            openWindow: openWindow
        )
    }

    /// 見開きの左/右ページを原寸大の別ウインドウで表示する(cooViewerの「実寸表示ウィンドウ」相当)。
    /// 対象のスロットが空白(orderedCurrentSlots参照。EPUB仕様に合わせた空白ページ挿入)の
    /// 場合は、実画像が存在しないため何もしない。
    private func showActualSizeWindow(forLeftPage: Bool) {
        let orderedSlots = orderedCurrentSlots
        guard !orderedSlots.isEmpty else { return }
        let index = forLeftPage ? 0 : orderedSlots.count - 1
        guard case .image(let image) = orderedSlots[index] else { return }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: min(CGFloat(image.width), 900), height: min(CGFloat(image.height), 700)),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(
            rootView: ActualSizePageView(image: image, backgroundColor: preferences.effectiveBackgroundColor)
        )
        // バグ修正(ビルド時の警告): window.titleはStringを受け取るため、以前はここに
        // "Actual Size"という生のリテラルを直接代入していた。これだとXcodeの文字列カタログの
        // 静的解析からは「LocalizedStringKeyとして使われていない」ため参照を検出できず、
        // 「References to this key could not be found in source code.」という警告が出続けて
        // いた(実際には日本語表示時にも常に英語のまま表示されてしまう不具合でもあった)。
        // String(localized:locale:)を明示的に使うことで、カタログから正しく参照が見つかる
        // ようになり、表示言語設定(preferences.effectiveLocale)にも従うようになる。
        window.title = String(localized: "Actual Size", locale: preferences.effectiveLocale)
        window.center()
        // このウインドウを閉じるとアプリ全体が強制終了してしまう不具合の原因はここ。
        // isReleasedWhenClosed(既定でtrue)がtrueのままだと、close()が呼ばれた瞬間に
        // AppKitがこのNSWindowインスタンスを即座に解放してしまう。しかし contentView に
        // 割り当てているNSHostingView(SwiftUIのビューをAppKitへ橋渡しする仕組み)は、
        // ウインドウが閉じられた直後にも後始末のための処理(SwiftUI側の状態更新の
        // 反映など)を次のRunLoopで行うことがあり、その処理が「AppKitにより既に解放済みの
        // ウインドウ」を参照しようとして解放済みメモリへアクセスし、クラッシュ
        // (結果としてアプリ全体が強制終了)していたと考えられる。
        // (このウインドウはSwiftUIのWindow/WindowGroup Sceneを使わず、ここで直接
        // NSWindow+NSHostingViewを組み立てている。他のウインドウ[本編ウインドウ・
        // お気に入り/ブックマーク編集ウインドウ等]はいずれもSwiftUIのScene経由でウインドウ
        // 自体のライフサイクルをSwiftUI側に管理させているため、このクラッシュは起きない)。
        //
        // isReleasedWhenClosedをfalseにすると、close()時にAppKitが即座に解放することは
        // なくなり、他に強い参照を保持していない(このwindow変数はこの関数を抜けると
        // スコープを外れる)ため、通常のARCのルール通り、NSHostingView側の後始末も含めて
        // 誰からも参照されなくなった時点で自然に解放されるようになる。これにより
        // メモリリークにはならず、かつ解放済みメモリへの参照によるクラッシュも防げる。
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private extension View {
    /// このビューが実際に描画された高さを、渡されたBindingへ書き込み続ける。自動隠し中の
    /// プログレスバーで、「マウスが近づいたら表示する」判定の反応領域(しきい値)を、
    /// 固定値ではなく実際の表示サイズに追従させるために使う(progressBarHeightの
    /// コメント、updateAutoHiddenChromeVisibility参照)。
    func measuringHeight(into height: Binding<CGFloat>) -> some View {
        onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { newHeight in
            height.wrappedValue = newHeight
        }
    }
}

/// SwiftUIのView階層から、それを表示しているNSWindowを取得するためのヘルパー。
/// 自身は何も描画しない透明な1x1のNSViewを差し込み、それがウインドウに追加された
/// タイミング(makeNSView/updateNSViewの両方)でwindowプロパティを読み取ってコールバックする。
/// フルスクリーンの入退場通知(NSWindow.didEnterFullScreenNotificationなど)を
/// 登録するために、対象ウインドウそのものへの参照が必要なので使っている。
/// ContentView.swiftでも(AppState.hostWindowを設定するために)このまま再利用する。
/// NSWindowをSwiftUIの@Stateへ弱参照で持つための箱。
///
/// @Stateは値型しか保持できず、プロパティ自体にweakを付けることもできないため、weak varを
/// 1つだけ持つ構造体を挟む(LaunchCoordinator.WeakAppStateBoxと同じ発想)。WindowAccessor
/// 経由で受け取ったNSWindowを保持する各ビュー(ViewerView・BookmarkListView・
/// FavoritesOrganizerView)が共通で使う。ウインドウ自体はAppKitが保持しているので、
/// ビュー側が強参照する必要はない。
struct WeakWindowBox {
    weak var window: NSWindow?
}

struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = true
        DispatchQueue.main.async {
            onResolve(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onResolve(nsView.window)
        }
    }
}

/// クリックでのページ送り(pageArea内の左右クリックゾーン)用の、透明な当たり判定領域。
/// 実体はClickZoneView(下記)というただのNSView。
///
/// SwiftUIのButton/onTapGestureをそのまま使わない理由: SwiftUIのNSHostingViewは
/// acceptsFirstMouse(for:)をtrueで実装しており、ウインドウがキーウインドウでない状態で
/// クリックすると、ウインドウをアクティブにするのと同時にSwiftUI側のアクションも
/// 発火してしまう。これにより「他のウインドウへフォーカスを移すためにこのウインドウを
/// クリックしただけなのに、意図せずページが送られる」という不具合があった。
/// 素のNSView(既定でacceptsFirstMouseがfalse)をこの領域にだけ差し込むことで、
/// macOS標準の「非アクティブウインドウへの最初のクリックはウインドウをアクティブにする
/// だけで、そのクリック自体は無視する」という挙動をこの領域だけに戻している。
/// スクロール送りが参照する、裏のNSScrollViewの入れ物。
///
/// @Stateに値を直接持たせると、スクロールのたびにbodyが再構築されてしまう
/// (実際、当初の実装ではそれが原因でホイールの縦スクロールが効かなくなっていた)。
/// bodyからは読まない参照型に入れることで、更新しても再描画を起こさない。
/// ページ一覧パネルの上で始まったマウス操作の押し始め(スクリーン座標・時刻・ボタン)を
/// 持つだけの入れ物。
///
/// `@State`にしていないのは、マウスのボタンを押す/離すたびに値が変わるため、そのたびに
/// bodyの再構築を誘発してしまうから。ページ一覧は数十〜数百セルを並べることがあり、
/// 無駄な再描画の影響が大きい。bodyから読まない参照型に入れて、更新が再描画を起こさない
/// ようにする(ScrollGeometryBoxと同じ理由・同じ作り)。
private final class ThumbnailGridGesturePressBox {
    var press: (location: NSPoint, timestamp: TimeInterval, button: MouseTrigger.Button)?
}

private struct ClickZoneArea: NSViewRepresentable {
    /// クリックされたときに、押されたボタンと修飾キーを渡して呼ばれる。
    /// 位置(画面の左半分/右半分)はこの領域そのものが表しているため、呼び出し側が補う。
    let onClick: (MouseTrigger.Button, MouseTrigger.Modifiers) -> Void
    /// ドラッグジェスチャー(cooViewerの「drag left/right/up/down」相当)が成立したときに、
    /// ボタン・向き・修飾キーを渡して呼ばれる。
    let onGesture: (MouseTrigger.Button, MouseTrigger.DragDirection, MouseTrigger.Modifiers) -> Void
    /// ドラッグで画像を掴んで動かせるようにするかどうか(スクロールできる表示モードのときだけ)。
    let isDragScrollEnabled: Bool

    func makeNSView(context: Context) -> ClickZoneView {
        let view = ClickZoneView()
        view.onClick = onClick
        view.onGesture = onGesture
        view.isDragScrollEnabled = isDragScrollEnabled
        return view
    }

    func updateNSView(_ nsView: ClickZoneView, context: Context) {
        nsView.isDragScrollEnabled = isDragScrollEnabled
        // onClick/onGestureはperform(...)を都度キャプチャしたクロージャのため、View再構築の
        // たびに(viewModel/keyBindingStoreの状態変化などで)新しいインスタンスに差し替わりうる。
        // 古いクロージャを握ったままにしないよう、更新のたびに必ず上書きする。
        nsView.onClick = onClick
        nsView.onGesture = onGesture
    }
}

/// ClickZoneAreaが実際に使うNSView本体。マウスの押下(mouseDown)と離す(mouseUp)が
/// どちらも自身の領域内で起きたときだけ「クリックされた」とみなしてonClickを呼ぶ
/// (押した位置と離した位置が両方とも領域内にあることを確認する、NSButtonの基本的な
/// クリック判定にならった実装)。
private final class ClickZoneView: NSView {
    var onClick: ((MouseTrigger.Button, MouseTrigger.Modifiers) -> Void)?
    var onGesture:
        ((MouseTrigger.Button, MouseTrigger.DragDirection, MouseTrigger.Modifiers) -> Void)?
    /// ドラッグスクロールを許すか(ClickZoneArea参照)。
    var isDragScrollEnabled = false

    /// いま押されている最中のボタン(この領域の中で押し始めた場合のみ)。
    /// 押し始めたボタンと離したボタンが一致しなければクリックとみなさない。
    private var trackingButton: MouseTrigger.Button?
    /// このマウス操作で実際に画像を動かしたかどうか。動かした場合、ボタンを離したときの
    /// クリック動作は行わない(下のmouseUp参照)。
    private var didDragScroll = false
    /// 直前のドラッグ位置(ウインドウ座標)。ドラッグスクロールの移動量を差分で求めるために持つ。
    private var lastDragLocationInWindow: NSPoint?
    /// ボタンを押した位置と時刻。ジェスチャーの判定は、途中経過ではなく
    /// **押した点から離した点までの合計の移動量**で行う(cooViewerと同じ)。
    private var pressLocationInWindow: NSPoint?
    private var pressTimestamp: TimeInterval = 0
    /// closedHandCursorをpushしたかどうか(pushとpopを対にするため)。
    private var didPushDragCursor = false

    /// 既定値(false)のままでも良いが、このクラスの存在意義そのものであるため、
    /// 意図を明示するためにあえて上書きしておく。falseにすることで、ウインドウが
    /// キーウインドウでない状態でのクリックは、ウインドウをアクティブにするだけに留まり、
    /// mouseDown/mouseUp自体がこのビューに届かなくなる(=onClickは呼ばれない)。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }

    /// バグ修正(実機で確認): クリックゾーンはScrollViewの上に全面を覆って重なるため、
    /// 何もしないとスクロールバーの上のクリックまで飲み込んでしまう。実際、単ページ幅に合わせた状態で
    /// スクロールバーを掴もうとすると、ドラッグではなくページ送り(1画面分進む+次のページ)が
    /// 実行されてしまい、**スクロールバーを操作できなくなっていた**。
    ///
    /// nilを返すとこのビューはヒットテストの対象外になり、クリックは下にあるScrollView
    /// (=スクロールバー)へ届く。オーバーレイ表示のスクロールバーは普段alphaValueが0で、
    /// 端にカーソルを寄せたときだけ現れる。見えていないときは従来どおりクリックゾーンとして
    /// 働き、見えているときだけ譲る形になるため、ページ送りの操作感は損なわれない。
    override func hitTest(_ point: NSPoint) -> NSView? {
        if isPointOverVisibleScroller(point) { return nil }
        return super.hitTest(point)
    }

    /// hitTestに渡される座標は**親ビューの座標系**である点に注意(自身のboundsではない)。
    private func isPointOverVisibleScroller(_ pointInSuperview: NSPoint) -> Bool {
        guard let superview else { return false }
        let pointInWindow = superview.convert(pointInSuperview, to: nil)
        guard let scrollView = siblingScrollView(covering: pointInWindow) else { return false }
        for scroller in [scrollView.verticalScroller, scrollView.horizontalScroller] {
            guard let scroller, !scroller.isHidden, scroller.alphaValue > 0 else { continue }
            if scroller.convert(scroller.bounds, to: nil).contains(pointInWindow) { return true }
        }
        return false
    }

    override func mouseDown(with event: NSEvent) {
        beginTracking(.left, with: event)
    }

    /// 中ボタン(ホイールクリック)。左ボタン以外はここへ来る。
    ///
    /// cooViewerはbutton0〜10までを割り当ての対象にしていたが、qooViewerが扱うのは
    /// 中ボタン(buttonNumber == 2)だけで、それ以外の拡張ボタンは素通しする
    /// (MouseTrigger.Button参照)。右ボタン(buttonNumber == 1)はrightMouseDownとして
    /// 届くのでここには来ず、従来どおりコンテキストメニューが開く。
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == MouseTrigger.Button.middle.eventButtonNumber else {
            super.otherMouseDown(with: event)
            return
        }
        beginTracking(.middle, with: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == MouseTrigger.Button.middle.eventButtonNumber else {
            super.otherMouseUp(with: event)
            return
        }
        finishTracking(.middle, with: event)
    }

    private func beginTracking(_ button: MouseTrigger.Button, with event: NSEvent) {
        trackingButton = bounds.contains(convert(event.locationInWindow, from: nil)) ? button : nil
        didDragScroll = false
        lastDragLocationInWindow = event.locationInWindow
        pressLocationInWindow = event.locationInWindow
        pressTimestamp = event.timestamp
    }

    /// 押した点から離した点までの移動量が、ドラッグジェスチャーとして成立するか調べる。
    /// 判定そのものは MouseTrigger.DragDirection.from が持つ(ページ一覧パネルの上での
    /// ジェスチャーを拾う側とまったく同じ規則にするため)。
    private func gestureDirection(for event: NSEvent) -> MouseTrigger.DragDirection? {
        guard let press = pressLocationInWindow else { return nil }
        return MouseTrigger.DragDirection.from(
            dx: event.locationInWindow.x - press.x,
            dy: event.locationInWindow.y - press.y,
            duration: event.timestamp - pressTimestamp
        )
    }

    /// ドラッグで画像を掴んで動かす(cooViewerのCustomImageView.dragScroll:相当)。
    ///
    /// バグ修正(実機で確認): クリックゾーンがScrollViewの上に重なっているため、これが無いと
    /// ドラッグしても画像はまったく動かず、しかもボタンを離した瞬間にクリックとみなされて
    /// ページ送りが発動していた ― 「画像を動かそうとするとページが進む」という誤動作になる。
    /// cooViewerは横幅フィット・原寸・見開き分割のいずれでもドラッグスクロールを既定で有効に
    /// しており(defaultMouseArrayMode2/Mode3のaction 41)、ドラッグした場合はmouseUpで
    /// クリック動作を抑止している(didDragScroll)。
    override func mouseDragged(with event: NSEvent) {
        // 転送先のScrollViewは、ホイールと同じく「カーソルの位置を覆っているもの」に限る
        // (scrollWheelのコメント参照。「画面内に収める」モードでサイドパネルの一覧を
        // ドラッグしてしまわないため)。
        guard isDragScrollEnabled, trackingButton == .left,
              let scrollView = siblingScrollView(covering: event.locationInWindow),
              let documentView = scrollView.documentView, let last = lastDragLocationInWindow
        else { return }
        let deltaX = event.locationInWindow.x - last.x
        let deltaY = event.locationInWindow.y - last.y
        lastDragLocationInWindow = event.locationInWindow
        guard deltaX != 0 || deltaY != 0 else { return }

        // 画像を掴んで動かす向きにする(カーソルの動きに中身が付いてくる)。ウインドウ座標は
        // 上へ動かすとyが増えるため、documentViewが上下反転しているかどうかで符号を合わせる。
        let clipView = scrollView.contentView
        let maxX = max(documentView.frame.width - clipView.bounds.width, 0)
        let maxY = max(documentView.frame.height - clipView.bounds.height, 0)
        let verticalSign: CGFloat = documentView.isFlipped ? 1 : -1
        let origin = clipView.bounds.origin
        let newOrigin = CGPoint(
            x: min(max(origin.x - deltaX, 0), maxX),
            y: min(max(origin.y + verticalSign * deltaY, 0), maxY)
        )
        guard newOrigin != origin else { return }
        clipView.scroll(to: newOrigin)
        scrollView.reflectScrolledClipView(clipView)

        didDragScroll = true
        if !didPushDragCursor {
            NSCursor.closedHand.push()
            didPushDragCursor = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        finishTracking(.left, with: event)
    }

    private func finishTracking(_ button: MouseTrigger.Button, with event: NSEvent) {
        defer {
            trackingButton = nil
            lastDragLocationInWindow = nil
            pressLocationInWindow = nil
            if didPushDragCursor {
                NSCursor.pop()
                didPushDragCursor = false
            }
        }
        // 実際に画像を動かした場合は、クリックともジェスチャーともみなさない。
        //
        // ドラッグスクロールとドラッグジェスチャーの棲み分けはこの1つのフラグで決まる。
        // didDragScrollが立つのは「スクロールできる表示モードで、実際に画像が動いたとき」
        // だけなので、
        //   - 画面内に収めるモード: 常にジェスチャーになる(掴んで動かす余地が無い)
        //   - スクロールできるモード: 画像が動いたならスクロール、動く余地が無かった
        //     (端に着いていた・画像が画面に収まっている)ならジェスチャー
        // という振り分けになる。表示モードで一律に切り分けるより、実際に起きたことに
        // 合わせるほうが「動かせないのにジェスチャーも効かない」死角ができない。
        guard !didDragScroll else {
            didDragScroll = false
            return
        }
        guard trackingButton == button else { return }
        // control(コンテキストメニュー)やcommand(メニューバーのショートカット)が
        // 押されている場合は、このアプリの割り当ての領分ではないので何もしない
        // (MouseTrigger.Modifiers.from参照)。
        guard let modifiers = MouseTrigger.Modifiers.from(event.modifierFlags, allowsShift: true)
        else { return }

        // ジェスチャーの判定が先。成立した時点でクリックではないので、離した位置が
        // この領域の中かどうかは問わない(画面を大きく横切るストロークは、始めた側の
        // 領域から出て終わるのが普通のため)。
        if let direction = gestureDirection(for: event) {
            onGesture?(button, direction, modifiers)
            return
        }
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?(button, modifiers)
    }

    /// バグ修正(実機で確認): クリックゾーンはSwiftUIのZStackの中でScrollViewの**上**に
    /// 重ねられているため、何もしないとホイールイベントをここで飲み込んでしまい、
    /// 横幅に合わせる/同(単ページ)/拡大縮小しないモードで画面をスクロールできなくなる。
    ///
    /// NSViewの既定実装はnextResponder(=親ビュー)へ送るだけだが、ScrollViewはこのビューの
    /// 祖先ではなく**兄弟**として置かれているため、その経路では決して届かない。そこで、
    /// 共通の祖先の下にあるNSScrollViewを探して明示的に転送する。
    ///
    /// この機能を追加するまではクリックゾーンが「画面内に収める」モード(ScrollViewを使わない
    /// モード)でしか有効にならなかったため、この衝突は表面化していなかった。
    ///
    /// バグ修正(ユーザー報告): 「画面内に収める」モードにはページ用のScrollViewが**無い**。
    /// それでも祖先を外へたどり続けると、最後はウインドウ全体の配下にある別のNSScrollView
    /// ―― サイドパネルのフォルダ一覧 ―― が見つかり、画像の上で回したホイールでフォルダ
    /// 一覧がスクロールしてしまっていた(矢印キーでのページ送りはこの経路を通らないため
    /// 無関係)。転送先は「ホイールを回した位置を実際に覆っているScrollView」に限る。
    /// ページ用のScrollViewはこのクリックゾーンと同じ領域を覆うので常に該当し、サイド
    /// パネルの一覧はカーソルが画像の上にある限り該当しない(ホバーで重なる設定のパネルは
    /// こちらより手前にあるので、その上で回したホイールはそもそもここへ来ない)。
    override func scrollWheel(with event: NSEvent) {
        if let scrollView = siblingScrollView(covering: event.locationInWindow) {
            scrollView.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    /// 自分の祖先を1段ずつ外へたどりながら、その配下にあり、かつウインドウ座標
    /// `locationInWindow`を覆っているNSScrollViewを探す。近い祖先から順に見るため、
    /// 最初に見つかるのは同じZStackに置かれたページ表示用のScrollViewになる。
    private func siblingScrollView(covering locationInWindow: NSPoint) -> NSScrollView? {
        var ancestor: NSView? = superview
        while let current = ancestor {
            if let found = Self.firstScrollView(in: current, skipping: self, covering: locationInWindow) {
                return found
            }
            ancestor = current.superview
        }
        return nil
    }

    private static func firstScrollView(
        in view: NSView, skipping excluded: NSView, covering locationInWindow: NSPoint
    ) -> NSScrollView? {
        for subview in view.subviews where subview !== excluded {
            if let scrollView = subview as? NSScrollView {
                let local = scrollView.convert(locationInWindow, from: nil)
                if scrollView.bounds.contains(local) { return scrollView }
                // 覆っていないScrollViewの中まで降りる必要は無い(その子も覆っていない)。
                continue
            }
            if let found = firstScrollView(in: subview, skipping: excluded, covering: locationInWindow) {
                return found
            }
        }
        return nil
    }
}

/// 取り付けた場所(自身の原点)が、ウインドウ座標系(NSEvent.locationInWindowと同じ基準。
/// 原点はウインドウ最下端、Y座標は上に行くほど大きい)のどこにあるかをコールバックで報告する、
/// 何も描画しない高さ0のヘルパービュー。
///
/// ツールバー自動隠しの「マウスが近づいたら表示する」判定(updateAutoHiddenChromeVisibility)で、
/// 実際に表示されているツールバーの下端の位置を正確に知るために使う。以前は
/// window.contentView.frame.height(ウインドウのコンテンツ領域の高さ)からツールバーの高さを
/// 引いて逆算していたが、タイトルバーの実装の都合でこのcontentHeightが実際のツールバーの
/// 表示位置と微妙にズレることがあった。convert(_:to:)はAppKit自身がイベント配信にも使っている
/// のと同じ座標変換なので、タイトルバー・タブバーの表示有無やスタイルの実装詳細によらず、
/// NSEvent.locationInWindowと直接比較できる正確な位置が得られる。
private struct WindowYPositionAccessor: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowYPositionReportingView()
        view.onPositionChange = onChange
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? WindowYPositionReportingView else { return }
        view.onPositionChange = onChange
        // SwiftUI側のレイアウト変更(ウインドウのリサイズ、タブバーの表示切り替えなど)で
        // このビューの位置が動いたときに、AppKitのlayout()が呼ばれるより前にここへ来ることが
        // あるため、念のため次のランループで再度位置を報告しておく
        // (WindowAccessorのDispatchQueue.main.asyncパターンにならった保険)。
        DispatchQueue.main.async {
            view.reportPosition()
        }
    }
}

/// WindowYPositionAccessorが差し込む実際のNSView。自身がウインドウに追加されたとき
/// (viewDidMoveToWindow)、または自身の位置・サイズが変わったとき(layout。ウインドウの
/// リサイズやタブバーの表示切り替えによる再レイアウトを含む)に、自動的に位置を再報告する。
private final class WindowYPositionReportingView: NSView {
    var onPositionChange: ((CGFloat) -> Void)?

    override func layout() {
        super.layout()
        reportPosition()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportPosition()
    }

    func reportPosition() {
        guard window != nil else { return }
        // 自身のbounds原点(左下)を、ウインドウ座標系(NSEvent.locationInWindowと同じ基準)へ
        // 変換する。このビューは高さ0で置いているので、この点がそのままツールバーの下端の
        // Y座標になる。
        let pointInWindow = convert(NSPoint.zero, to: nil)
        onPositionChange?(pointInWindow.y)
    }
}

/// 取り付けた場所(pageArea)自身のフレーム全体(原点+サイズ)が、ウインドウ座標系
/// (NSEvent.locationInWindowと同じ基準)のどこにあるかをコールバックで報告する、透明な
/// ヘルパービュー。WindowYPositionAccessorと同じ考え方だが、Y座標1点だけでなくフレーム
/// 全体(X座標・幅を含む)が必要なため別に用意している。
///
/// コンテキストメニュー(右クリック、またはControl+左クリック)を起動したクリックが、
/// 見開き表示中のpageAreaの左半分・右半分のどちらで起きたかを判定するために使う
/// (設計コンセプト8.4節。contextClickMonitorのコメント参照)。
private struct PageAreaFrameAccessor: NSViewRepresentable {
    let onChange: (CGRect) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = PageAreaFrameReportingView()
        view.onFrameChange = onChange
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? PageAreaFrameReportingView else { return }
        view.onFrameChange = onChange
        // WindowYPositionAccessorと同じ理由(SwiftUI側のレイアウト変更がAppKitのlayout()より
        // 先にここへ届くことがあるための保険)で、次のランループでも再度報告しておく。
        DispatchQueue.main.async {
            view.reportFrame()
        }
    }
}

/// PageAreaFrameAccessorが実際に使うNSView本体。自身がウインドウに追加されたとき
/// (viewDidMoveToWindow)、または自身の位置・サイズが変わったとき(layout。ウインドウの
/// リサイズや表示モードの切り替えによる再レイアウトを含む)に、自動的にフレームを再報告する。
/// 何も描画しない透明なビューで、.backgroundとして重ねているだけなのでヒットテストや
/// クリック処理には一切影響しない。
private final class PageAreaFrameReportingView: NSView {
    var onFrameChange: ((CGRect) -> Void)?

    override func layout() {
        super.layout()
        reportFrame()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportFrame()
    }

    func reportFrame() {
        guard window != nil else { return }
        // 自身のbounds全体を、ウインドウ座標系(NSEvent.locationInWindowと同じ基準)へ
        // 変換する。.backgroundとして重ねているため、boundsはpageAreaと全く同じサイズになる。
        let frameInWindow = convert(bounds, to: nil)
        onFrameChange?(frameInWindow)
    }
}

/// 取り付けた場所自身のフレーム全体が、スクリーン座標系(NSEvent.mouseLocationと同じ基準)の
/// どこにあるかをコールバックで報告する、透明なヘルパービュー。PageAreaFrameAccessorと同じ
/// 考え方だが、ウインドウ座標系ではなくスクリーン座標系まで変換する点が異なる
/// (ページ一覧パネルの内側/外側の判定を、NSEventのモニタ側と同じ基準で行うため。
/// installThumbnailGridDismissMonitorIfNeeded参照)。
/// ThumbnailGridViewからも使うためprivateにしていない。
struct PanelScreenFrameAccessor: NSViewRepresentable {
    let onChange: (CGRect) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = PanelScreenFrameReportingView()
        view.onFrameChange = onChange
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? PanelScreenFrameReportingView else { return }
        view.onFrameChange = onChange
        DispatchQueue.main.async {
            view.reportFrame()
        }
    }
}

private final class PanelScreenFrameReportingView: NSView {
    var onFrameChange: ((CGRect) -> Void)?

    override func layout() {
        super.layout()
        reportFrame()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportFrame()
    }

    func reportFrame() {
        guard let window else { return }
        let frameInWindow = convert(bounds, to: nil)
        let frameOnScreen = window.convertToScreen(frameInWindow)
        onFrameChange?(frameOnScreen)
    }
}
