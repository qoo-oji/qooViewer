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
    /// 「お気に入りに追加」シート(登録先フォルダを選ぶ。FavoriteFolderPickerView)の表示状態。
    @State private var showFavoriteFolderPicker = false
    /// 「お気に入り一覧」を表示中のネイティブNSMenuブリッジ(FavoritesNSMenuBridge)。
    /// ツールバーのボタンのクリック・ショートカット(showFavoritesList)のどちらからも
    /// showFavoritesListMenu()を呼び出す形に統一している。popUp自体は同期呼び出しで
    /// 閉じるまでブロックされるため、厳密には@Stateに保持しなくても呼び出し元のローカル変数の
    /// 生存期間だけで足りるはずだが、念のためこのビューの寿命に紐づけて保持している。
    @State private var favoritesMenuBridge: FavoritesNSMenuBridge?
    /// 「新しいウインドウで開く」「新しいタブで開く」(openFavoriteInNewWindow/openFavoriteInNewTab)
    /// で、指定したURLを持つ新しいウインドウをSwiftUIに作らせるための仕組み。
    @Environment(\.openWindow) private var openWindow
    /// このビューを表示しているウインドウ本体。フルスクリーンの入退場通知の登録・解除や、
    /// マウス位置と画面端との距離判定に使う。
    @State private var hostWindow: NSWindow?
    /// 現在フルスクリーン表示中かどうか。
    @State private var isFullScreen = false
    /// 自動隠し中のツールバー・プログレスバーを、マウスが画面端に近いために一時的に表示しているか
    /// どうか。フルスクリーン中、またはウインドウ表示でもhideToolbar/hideProgressBarが
    /// ONのときに使われる(自動隠しが有効でないときは常にtrue相当として扱う。bodyの表示条件参照)。
    @State private var isAutoHiddenChromeRevealed = true
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

    /// 画像のエクスポート機能(要望)。エクスポート中に画像の読み込み・結合・書き込みのいずれかで
    /// 失敗した場合のエラーメッセージ。nilなら非表示(applyLayoutAlerts参照)。
    @State private var imageExportErrorMessage: String?

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

    init(book: MangaBook, modelContext: ModelContext, preferences: AppPreferences, layoutStore: LayoutStore) {
        _viewModel = StateObject(
            wrappedValue: ViewerViewModel(
                book: book, modelContext: modelContext, preferences: preferences, layoutStore: layoutStore
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
        viewModel.onRequestSiblingBook = { forward in
            if forward {
                appState.openSibling(after: viewModel.book.sourceURL)
            } else {
                appState.openSibling(before: viewModel.book.sourceURL)
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
        appState.updateCurrentBookmarks(viewModel.bookmarks)
        appState.updateCurrentPageIndex(viewModel.currentIndex)
        // メニューバーの「表示モード切替」サブメニューから、特定のモードへ直接切り替える
        // ための橋渡し。
        appState.setScalingMode = { mode in
            viewModel.setScalingMode(mode)
        }
        // メニューバーの「Layout」メニュー(8.2節)からの操作の橋渡し。詳細はAppState.swiftの
        // performLayoutStateChange/performLayoutClear/performAutoLayoutのコメント参照。
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
            matching: [.scrollWheel, .swipe, .mouseMoved, .keyDown]
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
            guard !showThumbnailGrid else { return event }
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
                if preferences.treatTrackpadFlickAsWheel && isTrackpadOriginated {
                    handleTrackpadScrollGesture(
                        phase: event.phase,
                        deltaX: event.scrollingDeltaX,
                        deltaY: event.scrollingDeltaY
                    )
                    break
                }
                handleScroll(deltaY: event.scrollingDeltaY)
            case .swipe:
                // 「ページ間をスワイプ」が3本指/4本指設定の場合は、こちらの専用イベントで
                // 届く(2本指設定の場合の扱いは上のhandleTrackpadScrollGesture参照)。
                handleSwipe(deltaX: event.deltaX)
            case .keyDown:
                // キー入力の検知は、以前はSwiftUIの.onKeyPressで行っていたが、
                // 環境によっては矢印キーがそちらまで届かない(ビープ音が鳴るだけで
                // 何も起きない)不具合があったため、動作が確実なこちらのNSEventベースの
                // 経路に統合した(詳細はRemappableKey.from(nsEvent:)のコメント参照)。
                if let key = RemappableKey.from(nsEvent: event),
                   let action = keyBindingStore.action(for: key) {
                    perform(action)
                    // イベントをここで消費し、これ以上(標準のフォーカス移動や
                    // ビープ音などへ)伝播させない。
                    return nil
                }
            default:
                // .mouseMovedは上で早期リターン済みのため、マッチしている残りの型
                // (.scrollWheel/.swipe/.keyDown)はすべて明示的なcaseで処理されており、
                // ここには実質到達しない。
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
            guard !showThumbnailGrid else { return event }
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
        // appStateへの後始末(nilに戻す等)は、まだ自分自身が最後にappStateへ登録した
        // ViewerViewである場合にだけ行う。同じウインドウ内で本を切り替えた際、既に
        // 新しいViewerViewのonAppearが自分のトークンで上書きしていれば、ここでの
        // 後始末は行わない(誤って新しい本の正しい登録を消してしまわないため。
        // AppState.activeViewerTokenのコメント参照)。
        if appState.activeViewerToken == viewerToken {
            appState.performViewerAction = nil
            appState.jumpToBookmark = nil
            appState.jumpToPageIndex = nil
            appState.addBookmarkAction = nil
            appState.updateCurrentBookmarks([])
            appState.updateCurrentPageIndex(0)
            appState.setScalingMode = nil
            appState.performLayoutStateChange = nil
            appState.performLayoutClear = nil
            appState.performAutoLayout = nil
            appState.performImageExport = nil
            appState.resetMenuCheckmarkState()
        }
        viewModel.stopSlideshow()
        viewModel.flushPendingSave()
        cursorHideTask?.cancel()
        cursorHideTask = nil
        toastDismissTask?.cancel()
        toastDismissTask = nil
        if isCursorHidden {
            NSCursor.unhide()
            isCursorHidden = false
        }
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers = []
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

    /// 画像のエクスポート本体。まず既定のファイル名・許可する形式を(画像を読み込まずに、
    /// PageRefのメタデータだけから)同期的に決め、NSSavePanelで保存先を選んでもらってから、
    /// 実際の画像の読み込み・(結合が必要な場合は)合成・書き込みを非同期に行う
    /// (LibraryExportWindow.exportButtonTappedと同じ「パネル表示 → Task」の順序)。
    /// パネルをキャンセルした場合は何もしない。
    private func exportImage(_ request: ImageExportRequest) {
        switch request {
        case .singlePage(let index):
            guard viewModel.book.pages.indices.contains(index) else { return }
            let page = viewModel.book.pages[index]
            let ext = ImageExporter.fileExtension(for: page)
            guard let url = presentImageExportSavePanel(
                defaultFileName: ImageExporter.defaultFileName(for: page),
                contentType: ImageExporter.contentType(forExtension: ext)
            ) else { return }
            Task {
                guard let data = await viewModel.rawImageData(at: index) else {
                    imageExportErrorMessage = String(localized: "Couldn't read the image to export.")
                    return
                }
                do {
                    try ImageExporter.writeSinglePage(data: data, to: url)
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

    /// bodyから切り出したZStack本体(handleOnAppearのコメント参照)。
    private var mainZStack: some View {
        // フルスクリーン表示中は、表示メニューの「ツールバーを隠す」「プログレスバーを隠す」の
        // 設定に関わらず、常に自動隠しになる。ウインドウ表示のときは、それぞれの設定がONの
        // ときだけ自動隠しになる(OFFなら常に表示)。
        let toolbarAutoHides = isFullScreen || appState.hideToolbar
        let progressBarAutoHides = isFullScreen || appState.hideProgressBar
        // 自動隠し中のツールバー・プログレスバーを、マウスが画面端に近づいたことで
        // 一時的に表示している状態かどうか。
        let showToolbarOverlay = toolbarAutoHides && isAutoHiddenChromeRevealed
        let showProgressBarOverlay = progressBarAutoHides && isAutoHiddenChromeRevealed

        // 自動隠しでない(常に表示する)ときは、以前と同じくVStackの一部として組み込み、
        // 画像表示エリアはその分だけ縮んだ残りの領域を使う。
        // 一方、自動隠し中にマウスを近づけて一時的に表示するときは、画像表示エリアの
        // サイズを一切変えたくない(表示するたびに画像が拡大縮小されるのを避けるため)ので、
        // ZStackで画像の上に半透明のパネルとして重ねて表示する形にしている。
        return ZStack {
            VStack(spacing: 0) {
                if !toolbarAutoHides {
                    toolbar
                    Divider()
                }
                pageArea
                    .contextMenu {
                        contextMenuContent
                    }
                if !progressBarAutoHides {
                    ProgressBarView(viewModel: viewModel)
                        .measuringHeight(into: $progressBarHeight)
                }
            }

            if toolbarAutoHides {
                VStack(spacing: 0) {
                    toolbar
                        .background(.ultraThinMaterial)
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
                        .background(.ultraThinMaterial)
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
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                        .padding(.bottom, 48)
                }
                .allowsHitTesting(false)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
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
                    ThumbnailGridBackdropView(isPresented: $showThumbnailGrid)
                    ThumbnailGridView(viewModel: viewModel, isPresented: $showThumbnailGrid)
                }
                .transition(.opacity)
                .zIndex(2)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toastMessage)
        .animation(.easeInOut(duration: 0.15), value: showThumbnailGrid)
        .background(preferences.backgroundColorOption.color)
        .background(WindowAccessor { window in
            guard hostWindow !== window else { return }
            hostWindow = window
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
        // スライドショー実行中/表示モード/読み方向/拡大縮小モードが変わるたびに、
        // メニューバーの該当項目のチェックマークを最新の状態に更新する。
        .onChange(of: viewModel.isSlideshowActive) { _, _ in syncMenuCheckmarkState() }
        .onChange(of: viewModel.displayMode) { _, _ in syncMenuCheckmarkState() }
        .onChange(of: viewModel.readingDirection) { _, _ in syncMenuCheckmarkState() }
        .onChange(of: viewModel.scalingMode) { _, _ in syncMenuCheckmarkState() }
        // isPageShiftLocked(「1ページだけ送る」のグレーアウト判定)はcurrentIndexにも依存する
        // ため、ページ送り自体でもメニューバーの状態を更新し直す必要がある。「現在のページが
        // ブックマーク済みかどうか」の判定にも使うため、appState.currentPageIndexも合わせて更新する。
        .onChange(of: viewModel.currentIndex) { _, newValue in
            appState.updateCurrentPageIndex(newValue)
            syncMenuCheckmarkState()
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
            syncMenuCheckmarkState()
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
        // 環境設定「本を再度開いたときの動作」が「問い合わせる」のときだけ、
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
    @ViewBuilder
    private func toggleToolbarIcon(outlineSystemName: String, filledSystemName: String, isRegistered: Bool) -> some View {
        Image(systemName: isRegistered ? filledSystemName : outlineSystemName)
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isRegistered ? Color.primary : Color.clear)
            )
            .foregroundStyle(isRegistered ? Color(nsColor: .controlBackgroundColor) : Color.primary)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            // ページ移動・ファイル移動のボタン群。ブラウザの「戻る」「進む」ボタンのように、
            // ファイル名表示(アドレスバー相当)より左側に配置する。

            // 次の画像/前の画像(見開き時は2枚、単ページ時は1枚移動。読み方向によって左右の意味が入れ替わる)
            HStack(spacing: 4) {
                Button {
                    viewModel.advance(forward: viewModel.readingDirection == .rightToLeft)
                } label: {
                    Image(systemName: "chevron.left.2")
                }
                .help(viewModel.readingDirection == .rightToLeft ? "Next Image" : "Previous Image")

                Button {
                    viewModel.advance(forward: viewModel.readingDirection == .leftToRight)
                } label: {
                    Image(systemName: "chevron.right.2")
                }
                .help(viewModel.readingDirection == .leftToRight ? "Next Image" : "Previous Image")
            }

            // 1枚だけ次の画像/前の画像(見開きのページの組み合わせがずれたときの調整用)。
            // EPUBが見開き内の配置(page-spread-left/right/center)を明示している場合、
            // この調整でその組み合わせを崩してしまわないよう無効化する
            // (詳細はViewerViewModel.isPageShiftLocked参照)。
            HStack(spacing: 4) {
                Button {
                    viewModel.shiftByOnePage(forward: viewModel.readingDirection == .rightToLeft)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .help(viewModel.readingDirection == .rightToLeft ? "Next Image by One" : "Previous Image by One")

                Button {
                    viewModel.shiftByOnePage(forward: viewModel.readingDirection == .leftToRight)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .help(viewModel.readingDirection == .leftToRight ? "Next Image by One" : "Previous Image by One")
            }
            .disabled(viewModel.isPageShiftLocked)

            // 前の本へ/次の本へ(同じフォルダ内の、同じ種類[アーカイブ/PDFファイルまたはフォルダ]の
            // 本の間を移動する。読み方向に関係なく、上が前、下が次。詳細はSiblingFinder参照)
            HStack(spacing: 4) {
                Button {
                    appState.openSibling(before: viewModel.book.sourceURL)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .help("Previous Book")

                Button {
                    appState.openSibling(after: viewModel.book.sourceURL)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .help("Next Book")
            }

            Spacer()

            // ファイル名表示。ブラウザのアドレスバーのように、ツールバー中央に配置する
            // (前後のSpacerが左右の残り幅を均等に分け合うことで中央寄せになる)。
            Text(viewModel.book.title)
                .font(.headline)
                .lineLimit(1)

            Spacer()

            // 「現在の表示を基準に自動でレイアウトする」ボタン(設計コンセプト8.5節)。
            // ブックマーク追加・削除ボタンの左に配置する。本全体を上書きする操作のため、
            // 実行前に確認ダイアログ(isShowingAutoLayoutConfirmation)を挟む(3.1節)。
            Button {
                isShowingAutoLayoutConfirmation = true
            } label: {
                Image(systemName: "rectangle.split.2x1")
            }
            .help("Auto-Layout Based on Current View")
            .disabled(viewModel.hasAuthoritativeSourceLayout)

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
            .help(isCurrentBookFavorited ? "Remove This Book from Favorites" : "Add This Book to Favorites…")

            Button {
                showThumbnailGrid = true
            } label: {
                Image(systemName: "square.grid.2x2")
            }
            .help("Show Page Grid")

            Button {
                viewModel.toggleSlideshow()
            } label: {
                Image(systemName: viewModel.isSlideshowActive ? "pause.fill" : "play.fill")
            }
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
        .disabled(viewModel.isDisplayModeLocked)

        Toggle(
            "Right-to-Left",
            isOn: Binding(
                get: { viewModel.readingDirection == .rightToLeft },
                set: { _ in perform(.toggleReadingDirection) }
            )
        )
        .disabled(viewModel.isReadingDirectionLocked)

        Divider()

        // お気に入りグループ・ブックマークグループ・レイアウトグループの並び順、および文言は
        // メニューバーの「編集」(Edit)メニュー内の対応するグループ(QooViewerApp.swiftの
        // CommandGroup(after: .pasteboard))に合わせている(お気に入り→ブックマーク→
        // レイアウトの順)。追加・削除は登録状態に応じて文言・動作が切り替わる1つのトグル項目に
        // まとめている(ツールバーと同じ考え方。ユーザー要望)。
        Button(isCurrentBookFavorited ? "Remove This Book from Favorites" : "Add This Book to Favorites…") {
            perform(.toggleFavorite)
        }
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
        } else {
            Button(isCurrentPageBookmarked ? "Remove This Page from Bookmarks" : "Add This Page to Bookmarks") {
                perform(.toggleBookmark)
            }
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
            .disabled(viewModel.hasAuthoritativeSourceLayout)

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
        .disabled(viewModel.hasAuthoritativeSourceLayout)

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

        // ユーザー要望: 右クリックしたページの画像ファイル情報(ファイル名・フォーマット・
        // 解像度・色情報・ファイルサイズ、いずれもヘッダーから分かる範囲)をサブメニューとして
        // 表示する。対象ページの特定は上のExport Imageサブメニューと同じ考え方
        // (isLastContextClickOnLeftHalfでクリック位置から一意に決める)。
        // 実際の情報はviewModel.pageImageInfo(atIndex:)がバックグラウンドで取得済みの
        // キャッシュを同期的に読むだけ(ViewerViewModel.pageImageInfoCacheのコメント参照。
        // NSMenu backedのコンテキストメニューは開いている最中に内容を非同期更新できないため)。
        Menu("Get Info") {
            // Text(...)のままだと非活性(アクションを持たない)項目としてNSMenuに薄いグレーで
            // 描画され読みづらい(ユーザー報告)。Button(action: {})にして「実行可能な項目」
            // 扱いにすることで、通常の(白い)メニュー項目と同じ濃さで表示されるようにする
            // (クリックしても何も起きないだけで、情報表示という用途上問題ない)。
            if let info = viewModel.pageImageInfo(atIndex: infoContextPageIndex) {
                Button("File Name: \(info.fileName)") {}
                Button("Format: \(info.formatDescription)") {}
                Button("Resolution: \(info.pixelWidth) × \(info.pixelHeight) px") {}
                if let colorModel = info.colorModel {
                    if let bitDepth = info.bitDepth {
                        Button("Color: \(colorModel), \(bitDepth)-bit") {}
                    } else {
                        Button("Color: \(colorModel)") {}
                    }
                }
                if let fileSizeBytes = info.fileSizeBytes {
                    Button("File Size: \(ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file))") {}
                }
            } else {
                Text("Loading…")
            }
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
        let images = orderedCurrentImages
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
            // 見開き表示で左右のページの元画像の解像度が異なる(スキャン品質がページごとに
            // バラバラな本などでよくある)場合でも、実際の本のように両ページの物理的な高さを
            // 揃えて表示したい。画像そのものの画素数をそのまま使うと、解像度が低い方の画像は
            // 相対的に小さく表示されてしまう(拡大されているように見えない)ため、含まれる
            // 画像のうち最大の高さを基準にし、他の画像(空白スロットを含む)はアスペクト比を
            // 保ったままその高さに合わせた幅で計算する。
            let referenceHeight = orderedSlots.compactMap { slot -> CGFloat? in
                if case .image(let image) = slot { return CGFloat(image.height) }
                return nil
            }.max() ?? 0
            let contentSize = totalContentSize(for: orderedSlots, referenceHeight: referenceHeight)
            let scale = renderScale(contentSize: contentSize, containerSize: geo.size)
            // 空白スロット(orderedCurrentSlotsのコメント参照)の幅は、同じ見開き内にある
            // 実画像のアスペクト比をそのまま流用する(相方が実在すればこのくらいの幅になる
            // はず、という近似。実際の本の見開きで白紙ページが対向ページと同じ判型になるのに
            // 近い見た目にするため)。
            let mirrorAspectRatio = referenceAspectRatio(for: orderedSlots)

            let imagesRow = HStack(spacing: 0) {
                ForEach(Array(orderedSlots.enumerated()), id: \.offset) { _, slot in
                    let width = displayWidth(for: slot, atHeight: referenceHeight, mirrorAspectRatio: mirrorAspectRatio)
                    switch slot {
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

            ZStack {
                if viewModel.scalingMode == .fitToScreen {
                    imagesRow
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
                } else {
                    ScrollView(viewModel.scalingMode == .noScale ? [.horizontal, .vertical] : [.vertical]) {
                        imagesRow
                            .frame(
                                width: max(contentSize.width * scale, geo.size.width),
                                height: contentSize.height * scale
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
                    ClickZoneArea {
                        perform(keyBindingStore.action(for: .clickLeftZone))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    ClickZoneArea {
                        perform(keyBindingStore.action(for: .clickRightZone))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // isClickZoneArmed: ウェルカム画面からのダブルクリックの2回目のクリックを
                // 読み捨てるため、本を開いた直後の一定時間はヒットテスト自体を無効にする
                // (詳細はisClickZoneArmedのコメント参照)。
                .allowsHitTesting(viewModel.scalingMode == .fitToScreen && isClickZoneArmed)
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
        case .noScale:
            return 1
        }
    }

    private func handleScroll(deltaY: CGFloat) {
        // 横幅フィット/拡大縮小しないモードではScrollView自体がホイール操作を処理するため、
        // ここでのページ送りは「画面内に収める」モードのときだけ行う
        guard viewModel.scalingMode == .fitToScreen else { return }

        // NSEvent.scrollingDeltaYの符号は、ホイールを物理的に上へ回す(指を上に動かす)と
        // 正の値になる(以前の実装ではここが逆になっており、ホイールを上に回すと.wheelDownに
        // 割り当てた操作が実行されてしまっていた。設定画面の「Scroll Wheel Up」という表示と
        // 実際の動作が食い違うバグだったため、対応する分岐を入れ替えて修正している)。
        guard deltaY > 2 || deltaY < -2 else { return }

        // 一部のマウス/ドライバでは、物理的には1ノッチしか回していなくても、その回転が
        // ごく短い間隔の複数のscrollWheelイベントに分かれて届くことがある。それらを
        // まとめて1回のページ送りとして扱うため、直前のページ送りからこの間隔未満での
        // 連続発火は無視する(意図的に素早く連続でノッチを回したときの間隔は、通常
        // これよりも空くため、そちらは取りこぼさない)。
        let now = Date()
        if let lastWheelActionAt, now.timeIntervalSince(lastWheelActionAt) < wheelActionCooldown {
            return
        }
        lastWheelActionAt = now

        if deltaY > 0 {
            perform(keyBindingStore.action(for: .wheelUp))
        } else {
            perform(keyBindingStore.action(for: .wheelDown))
        }
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
        if deltaX > 0 {
            perform(keyBindingStore.action(for: .wheelUp))
        } else if deltaX < 0 {
            perform(keyBindingStore.action(for: .wheelDown))
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
        if trackpadGestureDeltaX > 0 {
            perform(keyBindingStore.action(for: .wheelUp))
        } else {
            perform(keyBindingStore.action(for: .wheelDown))
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
        isAutoHiddenChromeRevealed = true

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
        if bookClosingDelegate == nil {
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
            isAutoHiddenChromeRevealed = true
        }
        let exit = NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
        ) { _ in
            isFullScreen = false
            isAutoHiddenChromeRevealed = true
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
    }

    /// フルスクリーン表示中、または表示メニューの「ツールバーを隠す」「プログレスバーを隠す」の
    /// どちらかがONのウインドウ表示中に、マウスカーソルが画面(ウインドウ)の上端または下端に
    /// 近づいたときだけツールバー・プログレスバーを表示する。どちらの自動隠しも有効でない
    /// (フルスクリーンでなく、かつ両方の設定がOFFの)ときは何もしない(常に表示するため)。
    /// カーソルのx座標と同様、実際に表示が変わる(=真偽値が反転する)ときだけ@Stateを
    /// 書き換える(過去のプログレスバーの不具合の反省を踏まえた安全策)。
    private func updateAutoHiddenChromeVisibility(forMouseLocationInWindow location: CGPoint) {
        guard isFullScreen || appState.hideToolbar || appState.hideProgressBar,
              hostWindow != nil else { return }
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
        if isAutoHiddenChromeRevealed != shouldShow {
            isAutoHiddenChromeRevealed = shouldShow
        }
    }

    /// メニューバーの各種チェックマーク・グレーアウト状態を、現在のviewModelの値で更新する。
    /// スライドショー/表示モード/読み方向/拡大縮小モード/現在ページ(EPUBによる各種ロック状態の
    /// 判定に必要)のいずれかが変化するたびに呼ぶ(onAppearでの初期反映、および各onChangeから
    /// 使う)。呼び出し箇所を1つにまとめることで、新しい状態を追加したときに一部のonChangeだけ
    /// 直し忘れる、というミスを防ぐ。
    private func syncMenuCheckmarkState() {
        appState.updateMenuCheckmarkState(
            isSlideshowActive: viewModel.isSlideshowActive,
            displayMode: viewModel.displayMode,
            readingDirection: viewModel.readingDirection,
            scalingMode: viewModel.scalingMode,
            isReadingDirectionLocked: viewModel.isReadingDirectionLocked,
            isDisplayModeLocked: viewModel.isDisplayModeLocked,
            isPageShiftLocked: viewModel.isPageShiftLocked,
            hasAuthoritativeSourceLayout: viewModel.hasAuthoritativeSourceLayout,
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
        case .jumpToPercentile0, .jumpToPercentile10, .jumpToPercentile20, .jumpToPercentile30,
             .jumpToPercentile40, .jumpToPercentile50, .jumpToPercentile60, .jumpToPercentile70,
             .jumpToPercentile80, .jumpToPercentile90:
            if let percentile = action.jumpPercentile {
                viewModel.jump(toPercentile: percentile)
            }
        case .toggleDisplayMode:
            viewModel.toggleDisplayMode()
        case .toggleReadingDirection:
            viewModel.toggleReadingDirection()
        case .cycleScalingMode:
            viewModel.cycleScalingMode()
        case .autoLayoutFromCurrentView:
            // ツールバーのボタン・メニューバー「Layout」の項目と同じ経路(3.1節)。EPUB由来の
            // 権威的なレイアウト指定がある本ではボタン/メニュー項目自体を無効化しているため、
            // キーボードショートカット側でも同じ条件でここで弾く(viewModel.autoLayoutFromCurrentView
            // 自体にも同じガードがあるが、確認ダイアログが無意味に開いてしまわないようにするため)。
            guard !viewModel.hasAuthoritativeSourceLayout else { break }
            isShowingAutoLayoutConfirmation = true
        case .previousBook:
            appState.openSibling(before: viewModel.book.sourceURL)
        case .nextBook:
            appState.openSibling(after: viewModel.book.sourceURL)
        case .toggleBookmark:
            toggleCurrentPageBookmark()
        case .nextBookmark:
            viewModel.jumpToNextBookmark()
        case .previousBookmark:
            viewModel.jumpToPreviousBookmark()
        case .showBookmarkList:
            showBookmarkEditor()
        case .showThumbnailGrid:
            showThumbnailGrid = true
        case .toggleSlideshow:
            viewModel.toggleSlideshow()
        case .showActualSizeLeft:
            showActualSizeWindow(forLeftPage: true)
        case .showActualSizeRight:
            showActualSizeWindow(forLeftPage: false)
        case .toggleFavorite:
            toggleCurrentBookFavorite()
        case .showFavoritesList:
            showFavoritesListMenu()
        case .showFavoritesOrganizer:
            openWindow(id: "favoritesOrganizer")
        case .none:
            break
        }
    }

    /// 「お気に入り一覧」ポップオーバーからお気に入りをクリックしたときの実際の分岐処理。
    /// QooViewerApp.swiftの同名メソッドと同じ考え方(環境設定「お気に入りを開くとき」
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
            openFavoriteInNewTab(favorite)
        case .newWindow:
            openFavoriteInNewWindow(favorite)
        }
    }

    /// ツールバーの「お気に入り一覧」ボタン、およびキーボードショートカット
    /// (ViewerAction.showFavoritesList)のどちらからも呼ぶ、一覧の表示処理。
    /// ネイティブNSMenu(FavoritesNSMenuBridge)を組み立てて表示することで、メニューバー側と
    /// 同じくホバーでサブフォルダが展開する挙動になる(詳細はFavoritesNSMenuBridge.swiftの
    /// コメント参照)。項目をクリックしたときの実際の開き方は、他の入り口と同じく
    /// openFavoriteAccordingToPreference(環境設定「お気に入りを開くとき」)に従う。
    /// 「ブックマークの編集」ウインドウ(独立ウインドウ)を開く。ツールバーのブックマークアイコン
    /// (枠線)・メニューバー「Favorites」→「Edit Bookmarks…」・bキーのどこから呼んでも、
    /// このメソッドを経由する。launchCoordinator.setActiveBookAppState(appState)を明示的に
    /// 呼んでおくことで、setUpWindowObservers側のdidBecomeKeyNotification通知を待たずに
    /// (念のため)確実にこの本を対象にしてからウインドウを開く。
    private func showBookmarkEditor() {
        launchCoordinator.setActiveBookAppState(appState)
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

    private func showFavoritesListMenu() {
        let bridge = FavoritesNSMenuBridge(favoritesStore: favoritesStore) { favorite in
            openFavoriteAccordingToPreference(favorite)
        }
        favoritesMenuBridge = bridge
        bridge.show()
    }

    /// 「お気に入り一覧」ボタン(またはショートカット)から、指定したお気に入りを新しいウインドウで開く。
    /// QooViewerApp.openURLInNewWindowと同じポーリング方式で、開いたウインドウをこのウインドウと
    /// 同じサイズ・カスケード位置に整える(詳細はそちらのコメント参照)。ここではメニューバーの
    /// 実装と処理が重複するが、ViewerView自身はQooViewerApp側のprivateなヘルパーを直接呼べないため、
    /// 同じ考え方をこちらでも実装している。
    private func openFavoriteInNewWindow(_ favorite: FavoriteBook) {
        guard let url = favoritesStore.resolvedExistingURL(for: favorite) else {
            appState.missingFavorite = favorite
            return
        }
        _ = url.startAccessingSecurityScopedResource()
        let previousWindow = hostWindow
        let existingIDs = Set(NSApp.windows.map(ObjectIdentifier.init))
        openWindow(id: "book", value: url)
        Task { @MainActor in
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 25_000_000)
                if let newWindow = NSApp.windows.first(where: { !existingIDs.contains(ObjectIdentifier($0)) }) {
                    if let previousWindow {
                        var frame = newWindow.frame
                        frame.size = previousWindow.frame.size
                        frame.origin = CGPoint(
                            x: previousWindow.frame.origin.x + 48,
                            y: previousWindow.frame.origin.y - 48
                        )
                        newWindow.setFrame(frame, display: true)
                    }
                    newWindow.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    break
                }
            }
        }
    }

    /// 「お気に入り一覧」ボタン(またはショートカット)から、指定したお気に入りを新しいタブで開く。
    private func openFavoriteInNewTab(_ favorite: FavoriteBook) {
        guard let url = favoritesStore.resolvedExistingURL(for: favorite) else {
            appState.missingFavorite = favorite
            return
        }
        guard let hostWindow else {
            openFavoriteInNewWindow(favorite)
            return
        }
        _ = url.startAccessingSecurityScopedResource()
        let existingIDs = Set(NSApp.windows.map(ObjectIdentifier.init))
        openWindow(id: "book", value: url)
        Task { @MainActor in
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 25_000_000)
                if let newWindow = NSApp.windows.first(where: { !existingIDs.contains(ObjectIdentifier($0)) }) {
                    var frame = newWindow.frame
                    frame.size = hostWindow.frame.size
                    frame.origin = hostWindow.frame.origin
                    newWindow.setFrame(frame, display: true)
                    hostWindow.addTabbedWindow(newWindow, ordered: .above)
                    newWindow.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    break
                }
            }
        }
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
            rootView: ActualSizePageView(image: image, backgroundColor: preferences.backgroundColorOption.color)
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
private struct ClickZoneArea: NSViewRepresentable {
    let onClick: () -> Void

    func makeNSView(context: Context) -> ClickZoneView {
        let view = ClickZoneView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: ClickZoneView, context: Context) {
        // onClickはperform(...)を都度キャプチャしたクロージャのため、View再構築のたびに
        // (viewModel/keyBindingStoreの状態変化などで)新しいインスタンスに差し替わりうる。
        // 古いクロージャを握ったままにしないよう、更新のたびに必ず上書きする。
        nsView.onClick = onClick
    }
}

/// ClickZoneAreaが実際に使うNSView本体。マウスの押下(mouseDown)と離す(mouseUp)が
/// どちらも自身の領域内で起きたときだけ「クリックされた」とみなしてonClickを呼ぶ
/// (押した位置と離した位置が両方とも領域内にあることを確認する、NSButtonの基本的な
/// クリック判定にならった実装)。
private final class ClickZoneView: NSView {
    var onClick: (() -> Void)?
    private var isTrackingClickInside = false

    /// 既定値(false)のままでも良いが、このクラスの存在意義そのものであるため、
    /// 意図を明示するためにあえて上書きしておく。falseにすることで、ウインドウが
    /// キーウインドウでない状態でのクリックは、ウインドウをアクティブにするだけに留まり、
    /// mouseDown/mouseUp自体がこのビューに届かなくなる(=onClickは呼ばれない)。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }

    override func mouseDown(with event: NSEvent) {
        isTrackingClickInside = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        defer { isTrackingClickInside = false }
        guard isTrackingClickInside else { return }
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
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
