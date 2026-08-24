import SwiftUI
import SwiftData
import AppKit
import Combine

struct ContentView: View {
    /// このウインドウ(タブ)専用のAppState。ウインドウごとに独立して本を開けるように、
    /// アプリ全体で1つの共有インスタンスではなく、ContentViewのインスタンスごとに
    /// (つまりウインドウ/タブごとに)新しく作る。これにより、新しいウインドウ/タブは
    /// 必ず「何も開いていない」状態(WelcomeView)から始まる。
    @StateObject private var appState: AppState
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var recentFiles: RecentFilesStore
    @EnvironmentObject private var folderAccess: FolderAccessStore
    @EnvironmentObject private var favoritesStore: FavoritesStore
    @EnvironmentObject private var bookmarkStore: BookmarkStore
    @EnvironmentObject private var layoutStore: LayoutStore
    /// 書誌メタデータ。ツールバーのファイル名表示を登録済みのタイトル・著者に差し替えるため、
    /// ViewerView経由でViewerViewModelへ渡す。
    @EnvironmentObject private var metadataStore: BookMetadataStore
    @EnvironmentObject private var launchCoordinator: LaunchCoordinator
    @Environment(\.modelContext) private var modelContext
    /// サイドパネル(ブックマークモード)の「編集」ボタンから、お気に入り/ブックマークの
    /// 編集ウインドウを開くために使う(sidePanelView参照)。
    @Environment(\.openWindow) private var openWindow

    /// 「新しいウインドウで開く」「新しいタブで開く」、またはFinderからの「開く」で、
    /// このウインドウで最初から開いておきたい対象。通常の(何も指定しない)ウインドウではnil。
    /// URL1つではなくBookOpenRequestなのは、Finderで複数選択された画像を1冊として
    /// 新しいウインドウ/タブで開けるようにするため(BookOpenRequestのコメント参照)。
    var initialRequest: BookOpenRequest?
    /// このウインドウがシークレットウインドウかどうか(何を記録しないかの定義は
    /// `AppState.isPrivateWindow`のコメント参照)。
    ///
    /// **`appState`が持つ値を正典とし、ここでは持たない。** ContentViewは`struct`なので、
    /// SwiftUIがビューの値を作り直すたびに`init`が走り、そのたびに環境設定を読み直すことに
    /// なる。一方`appState`はウインドウの生成時に一度だけ作られる`@StateObject`で、
    /// `AppState.isPrivateWindow`は`let`である。両方を別々に持つと、
    /// **環境設定「シークレットモードで起動」を実行中に切り替えた瞬間に食い違う** ――
    /// タイトルの「(シークレット)」表記やメニューの有効/無効はContentView側の新しい値に、
    /// 履歴やディスクキャッシュへの書き込み可否はAppState側の古い値に従う、という
    /// 中途半端な状態になる(シークレットで開いたはずのウインドウが、設定を戻した途端に
    /// 読書位置を書き始める)。
    private var isPrivateWindow: Bool { appState.isPrivateWindow }

    /// このウインドウ/タブが「正当なもの」と確認できた(onAppearの通常セットアップ、または
    /// resolveAmbiguousNewMainWindowでのタブグループ判定を通過した)かどうか。
    /// falseの間はLastActiveBookStoreへの記録・クリアを行わない。これがないと、Finderからの
    /// ファイルオープン時にAppKit/SwiftUIが原因不明のまま追加してしまう不正な空ウインドウ
    /// (resolveAmbiguousNewMainWindow参照)が閉じられるまでの一瞬キーウインドウになった際、
    /// 「本を開いていない状態」として誤って記録を消してしまう(せっかく正しい本を開いている
    /// 元のウインドウの記録が消えてしまう)ことがあったため。
    @State private var isConfirmedLegitimateWindow = false

    /// サイドパネル上段(フォルダブラウザ)の閲覧状態。ウインドウ/タブの生存期間ずっと同じ
    /// インスタンスを使い回す(ViewerViewと違い、本の切替やウェルカム画面への出入りを
    /// またいで保持したいため)。本を開いていない状態でもパネルを使えるようにする要件上、
    /// ViewerView側ではなくこのContentView側にパネル本体・状態の両方を置いている。
    @StateObject private var sidePanelBrowser = SidePanelBrowserState()
    /// サイドパネル下段(本の中身ブラウザ)の閲覧状態。本ごとに作り直す
    /// (.onChange(of: appState.currentBook?.id)参照)。フォルダ/対応アーカイブ形式以外
    /// (PDF/EPUB)、または本を開いていないときはnil(下段セクション自体を表示しない)。
    @State private var bookContentsBrowser: BookContentsBrowserState?
    /// サイドパネル側のホバー検知用ローカルモニタ。ViewerView.makeScrollMonitorとは
    /// 完全に独立した、X座標の帯だけを見る単純なもの。
    @State private var sidePanelHoverMonitor: Any?
    /// カーソルがウインドウの外へ出たことを検知するためのグローバルモニタ(他のアプリ宛ての
    /// マウス移動を監視する)。自動表示中のもの(サイドパネル/ツールバー/プログレスバー)が
    /// 1つでもある間だけ取り付ける(updateOutsideWindowMonitor参照)。
    @State private var outsideWindowMonitor: Any?
    /// このアプリのメニューが今開かれているかどうか(installMenuTrackingObserversIfNeeded参照)。
    /// 開いている間は、ホバー表示中のサイドパネルを閉じない。
    @State private var isMenuTracking = false

    // MARK: - サイドパネルの行の右クリックからのリネーム・削除(ユーザー要望)

    /// リネーム中のお気に入りフォルダ / お気に入り(本) / ブックマーク。
    /// 3つが同時に開くことはないため、入力欄(sidePanelRenameText)は共用している
    /// (FavoritesOrganizerViewのrenameTextと同じ考え方)。
    ///
    /// **ダイアログをSidePanelViewではなくここに持たせている理由**: パネルを隠す設定で
    /// 使っている場合、ダイアログが出ている間はホバーによる自動非表示を止める必要がある
    /// (止めないと、カーソルをダイアログへ動かした拍子にパネルが引っ込み、閉じたときには
    /// 一覧が消えている)。その判断はホバーの監視を持っているこちらにしか書けない。
    @State private var renamingFavoriteFolder: FavoriteFolder?
    @State private var renamingFavoriteBook: FavoriteBook?
    @State private var renamingBookmark: Bookmark?
    @State private var sidePanelRenameText = ""
    /// 削除の確認待ち。お気に入りは元に戻せないため確認を挟む(「お気に入りの編集」ウインドウと
    /// 同じ流儀)。ブックマークは確認せずその場で消す(「ブックマーク・レイアウトの編集」
    /// ウインドウのゴミ箱ボタンと同じ流儀。SidePanelView側のコメント参照)。
    @State private var favoriteFolderPendingDeletion: FavoriteFolder?
    @State private var favoriteBookPendingDeletion: FavoriteBook?

    /// サイドパネル由来のリネーム・削除ダイアログが出ているかどうか。
    /// 出ている間は、ホバーによるパネルの自動非表示を止める(isMenuTrackingと同じ扱い)。
    private var isSidePanelEditingDialogPresented: Bool {
        renamingFavoriteFolder != nil || renamingFavoriteBook != nil || renamingBookmark != nil
            || favoriteFolderPendingDeletion != nil || favoriteBookPendingDeletion != nil
    }
    /// 上記を検知するためのNSMenu.didBeginTracking/didEndTrackingの購読。
    @State private var menuTrackingObservers: [NSObjectProtocol] = []
    /// サイドパネルが出現する、ウインドウ端(左右どちらに置いているかによる)からの反応領域の幅。
    private static let sidePanelRevealBandWidth: CGFloat = 20
    /// 「サイドパネルを隠す」ON時、表示中のパネルが閉じるまでの、パネルのビューア側の端
    /// (sidePanelWidth)から見た余裕幅。ゼロだと、そこにある幅調整ハンドル(widthDragHitArea)を
    /// つかもうとカーソルを境界ぎりぎりへ動かしただけで隠れてしまう(ユーザー報告)。
    private static let sidePanelHideMargin: CGFloat = 16
    /// サイドパネルの幅。ユーザーが右端のドラッグハンドルで調整できる
    /// (SidePanelView.widthDragHitArea参照)。常時表示・ホバー表示のどちらでも同じ値を
    /// 共有する。
    @State private var sidePanelWidth: CGFloat = SidePanelView.defaultWidth
    /// ファイル/フォルダがこのウインドウの上へドラッグされている最中かどうか
    /// (applyFileDropTarget参照)。
    @State private var isFileDropTargeted = false

    /// - Parameter isPrivateWindow: 明示的に決まっている場合だけ渡す(そのWindowGroupが
    ///   シークレット専用か通常専用かで決まる)。**nilを渡せるのは"main" WindowGroupだけ**で、
    ///   その場合は環境設定「シークレットモードで起動」に従う。
    ///
    ///   ここでUserDefaultsを直接読んでいるのは、`init`の時点ではまだ`@EnvironmentObject`が
    ///   注入されておらず`preferences`を参照できないため(`RecentFilesStore.maxCount`が
    ///   同じ理由で直接UserDefaultsを読んでいるのと同じ)。
    ///
    ///   ここで読んだ値は`AppState`を組み立てるためだけに使い、**このstructには残さない**
    ///   (残すとinitのたびに読み直されてAppStateと食い違う。`isPrivateWindow`のコメント参照)。
    ///   `@StateObject`のwrappedValueはウインドウにつき一度しか評価されないため、
    ///   `AppState.isPrivateWindow`はウインドウが閉じるまで変わらない。
    init(initialRequest: BookOpenRequest? = nil, isPrivateWindow: Bool? = nil) {
        self.initialRequest = initialRequest
        // 値を渡してこないのは"main" WindowGroupだけ(isMainWindowGroupのコメント参照)。
        self.isMainWindowGroup = (isPrivateWindow == nil)
        _appState = StateObject(
            wrappedValue: AppState(isPrivateWindow: isPrivateWindow ?? AppPreferences.isPrivateModeDefault)
        )
    }

    /// このウインドウが、起動時にSwiftUIが自動的に作る"main" WindowGroupのものかどうか。
    ///
    /// 「アプリのコードが明示的に開いたウインドウかどうか」を表す唯一の手掛かりでもある。
    /// "book"/"normal"/"private"はいずれも`openWindow(id:)`で明示的に開いたものなので、
    /// 素性が確かで、下のonAppearの「正当なウインドウか」の判定を通す必要が無い。
    /// 一方"main"は、ユーザーがタブバーの「+」で足した正当なものと、AppKit/SwiftUIが
    /// 原因不明のまま勝手に作ってしまう空ウインドウ(resolveAmbiguousNewMainWindow参照)の
    /// 区別が付かない ―― その判定が要るのはこのグループだけである。
    private let isMainWindowGroup: Bool

    /// ウインドウ/タブのタイトル(bodyの.navigationTitle参照)。シークレットウインドウは、
    /// 通常ウインドウと見分けがつくよう先頭に「(シークレット)」を付ける。
    private var windowTitle: String {
        let base = appState.currentBook.map {
            // displayNameは、複数枚の画像をまとめた本にだけ枚数を添える
            // (それ以外はtitleそのまま)。MangaBook.displayName(locale:)参照。
            FormatBadgeView.plainTextTitle(
                baseName: $0.displayName(locale: preferences.effectiveLocale), bookID: $0.id
            )
        } ?? "qooViewer"
        guard isPrivateWindow else { return base }
        return String(localized: "(Private) \(base)", locale: preferences.effectiveLocale)
    }

    /// ウインドウの中身そのもの(サイドパネル + ビューア/ウェルカム画面)。
    ///
    /// bodyへ直接書くと、bodyに連なる大量のモディファイア(メニューバー用のFocusedValue、
    /// 各種onChange、2つのalert)と合わせて1つの式として型チェックされ、コンパイラが
    /// 「時間内に型チェックできない」と諦めてしまうため、独立した計算プロパティへ切り出している。
    @ViewBuilder
    private var windowContent: some View {
        // サイドパネルを左右どちらに置くかは環境設定(AppPreferences.sidePanelPosition)で決まり、
        // 常時表示・ホバー表示のどちらにも同じ値が効く。
        let panelPosition = preferences.sidePanelPosition
        ZStack(alignment: panelPosition.alignment) {
            // サイドパネルが常時表示(既定、hideSidePanel == false)のときは、ツールバー/
            // プログレスバーがViewerView.mainZStack内のVStackに組み込まれて画像表示エリアを
            // 押しのけるのと同じ考え方で、HStackの実レイアウトとして組み込む(ここでの
            // GeometryReaderベースのpageAreaサイジングが自動的に縮んだ幅を拾ってくれるため、
            // ViewerView側の変更は不要)。ZStackのオーバーレイのままにしてしまうと、常時表示中
            // ずっと画像の端がパネルの下に隠れ続けてしまう(ユーザー報告の不具合)。
            HStack(spacing: 0) {
                if showsDockedSidePanel && panelPosition == .left {
                    sidePanelView(dismissesOnAction: false)
                }
                Group {
                    if let book = appState.currentBook {
                        // .id(book.id) を付けることで、次の本/前の本に切り替えたときに
                        // ViewerViewModel(StateObject)が確実に作り直され、ページ位置などが
                        // 新しい本の状態にリセットされるようにしている。
                        ViewerView(
                            book: book, modelContext: modelContext, preferences: preferences,
                            layoutStore: layoutStore, metadataStore: metadataStore,
                            // シークレットウインドウか、その場限りの本(直接渡された画像から
                            // 組み立てた本)のどちらかなら、DBへは一切書かない。
                            // 詳細はViewerViewModel.skipsPersistence / MangaBook.BookOrigin参照。
                            skipsPersistence: isPrivateWindow || book.isTransient,
                            // 「同じフォルダの画像をすべて開く」で着地したいページ。
                            // この本向けの指定でなければ渡さない(AppState.pendingInitialPage参照)。
                            // 実際に消費したかどうかに関わらず、ViewerViewのonAppearが
                            // appState.clearPendingInitialPage()で必ず後始末する。
                            initialPageID: appState.pendingInitialPage
                                .flatMap { $0.bookID == book.id ? $0.pageID : nil }
                        )
                            .id(book.id)
                    } else {
                        WelcomeView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showsDockedSidePanel && panelPosition == .right {
                    sidePanelView(dismissesOnAction: false)
                }
            }

            // hideSidePanel == trueのときの、ホバーによる一時的な表示。ツールバー/プログレス
            // バーの自動隠し(ViewerView.mainZStackのZStackオーバーレイ分岐)と同じ理由で、
            // こちらはあえてHStackに組み込まず画像の上に浮かべる(表示・非表示のたびに
            // 画像のサイズが変わってちらつくのを避けるため)。preferences.sidePanelFeatureEnabled
            // がOFF(環境設定「一般」タブ)のときは、サイドパネル機能自体を丸ごと無効化する。
            if preferences.sidePanelFeatureEnabled && appState.hideSidePanel && appState.isSidePanelRevealed {
                sidePanelView(dismissesOnAction: true)
                    // 浮かせている間の位置をViewerViewへ知らせる。ページ一覧パネルを閉じる
                    // クリックの判定から、このパネルへのクリックを除くために要る
                    // (AppState.sidePanelScreenFrameのコメント参照)。
                    .background(PanelScreenFrameAccessor { appState.sidePanelScreenFrame = $0 })
                    .transition(.move(edge: panelPosition.edge))
            }
        }
    }

    /// ウインドウへファイル/フォルダをドロップして本を開けるようにする(ユーザー要望。
    /// 従来はウェルカム画面にしかドロップ先が無く、本を表示している間は落とせなかった)。
    ///
    /// ウェルカム画面・ビューア画面・サイドパネルのどれかに個別に付けるのではなく、
    /// **ウインドウの中身全体に1か所だけ**付ける。ユーザーは「このウインドウに落とす」つもりで
    /// 操作するので、サイドパネルの帯の上だけ反応しない、といった死角を作らないため。
    /// 受け口の実装自体はBookFileDropTarget.swift、何をどう1冊にまとめるかの判定は
    /// BookOpenRequestが引き受ける。
    ///
    /// 落としたものは今のウインドウの内容を置き換える。環境設定の「Finderから開いたとき」
    /// (新しいタブ/ウインドウ)はその名のとおりFinder経由で渡された場合の設定で、
    /// ウインドウ自体を狙って落とす操作には適用しない(狙ったウインドウとは別の場所で
    /// 開くことになってしまうため)。
    ///
    /// bodyから切り出しているのは、windowContentと同じく型チェックが長くかかりすぎる不具合の
    /// 対策(windowContentのコメント参照)。
    private func applyFileDropTarget<Content: View>(to content: Content) -> some View {
        content
            .bookFileDropTarget(isTargeted: $isFileDropTargeted) { urls in
                appState.open(urls: urls)
            }
            // 表示中の画像やパネルの見え方を変えたくないので、背景を染めるのではなく縁だけを
            // 強調する。
            .overlay {
                if isFileDropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 4)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.12), value: isFileDropTargeted)
    }

    var body: some View {
        applyFileDropTarget(to: windowContent)
        .animation(.easeInOut(duration: 0.15), value: appState.isSidePanelRevealed)
        .animation(.easeInOut(duration: 0.15), value: appState.hideSidePanel)
        // サイドパネル追加後、ウインドウがキーのときだけタイトルバーにまで達する青い
        // アクセントカラーの縦線が報告された。原因はSidePanelView自身の背景ではなく、
        // ウインドウ内のどこか(サイドパネル/ViewerViewいずれのサブビューかまでは特定して
        // いない)がデフォルトのキーボードフォーカスを持ってしまい、AppKitがそのフォーカス
        // リングを描画していたため(SidePanelView.body単体への.focusEffectDisabled()や
        // NSScrollViewへの.focusable(false)だけでは解消しなかったことから、ContentView配下の
        // どこか別の場所が実際の対象だったと判明)。ContentView全体に適用することで解消する。
        .focusEffectDisabled()
        // 子ビュー(WelcomeView・ViewerViewなど)は、このウインドウ専用のappStateを
        // @EnvironmentObjectとして参照する。
        .environmentObject(appState)
        // メニューバー(アプリ全体で1つ)から「今アクティブなウインドウ」のAppStateを
        // 参照できるようにする(詳細はAppState.swiftのFocusedValues拡張のコメント参照)。
        .focusedSceneValue(\.qooViewerAppState, appState)
        // メニューバーのチェックマーク表示専用に、値型でも同じ内容を公開する
        // (AppStateというクラス参照だけではチェックマークの更新が効かなかったための対処。
        // 詳細はAppState.swiftのMenuCheckmarkStateのコメント参照)。
        .focusedSceneValue(
            \.qooViewerMenuCheckmarkState,
            MenuCheckmarkState(
                isPrivateWindow: appState.isPrivateWindow,
                isTransientBook: appState.currentBook?.isTransient == true,
                hideToolbar: appState.hideToolbar,
                hideProgressBar: appState.hideProgressBar,
                hideSidePanel: appState.hideSidePanel,
                isSlideshowActive: appState.isSlideshowActive,
                isLoupeActive: appState.isLoupeActive,
                isSpreadMode: appState.isSpreadMode,
                isRightToLeft: appState.isRightToLeft,
                scalingMode: appState.currentScalingMode,
                isPageShiftLocked: appState.isPageShiftLocked,
                // isCurrentBookFavorited/isCurrentPageBookmarkedは、AppState自身の@Publishedでは
                // なくここで都度計算する。favoritesStoreの変更(reload())はAppStateの
                // objectWillChangeを発火させないため、ContentViewが自分自身のfavoritesStore
                // (EnvironmentObject。この構造体自体がfavoritesStoreの変更のたびに作り直される
                // ことで、値型のFocusedValueとしてメニューバー側へ正しく伝わる)から直接算出する。
                isCurrentBookFavorited: appState.currentBook.map { favoritesStore.isFavorited(bookID: $0.id) } ?? false,
                // 以前はここでcurrentBookmarksとcurrentPageIndexから都度計算していたが、
                // currentPageIndexはサイドパネルの追従のため保留対象から外してあるため、その
                // ままではメニューを開いている最中(スライドショーのページ送り)に文言が変わり、
                // メニューの再構築でmacOS 26のクラッシュを引き起こしうる。AppState側で保留付きの
                // @Publishedとして持つ値をそのまま読む(AppState.isCurrentPageBookmarked参照)。
                isCurrentPageBookmarked: appState.isCurrentPageBookmarked,
                hasPartnerPageDisplayed: appState.hasPartnerPageDisplayed,
                hasCurrentPageLayoutOverride: appState.hasCurrentPageLayoutOverride,
                hasPartnerPageLayoutOverride: appState.hasPartnerPageLayoutOverride
            )
        )
        .frame(minWidth: 900, minHeight: 640)
        // ウインドウ/タブのタイトルバーおよびタブバーに表示される文字列。本を開いている間は
        // その本のタイトル(ファイル/フォルダ名)を表示し、どのタブが何の本を開いているか
        // 一目で分かるようにする。何も開いていない(ウェルカム画面)ときはアプリ名を表示する。
        // タイトル自体は拡張子を除いた名前のため、同名のcbz/epub版を両方開いていると
        // タブバーだけでは見分けがつかない(ユーザー報告)。ウインドウ/タブのタイトルは
        // プレーンテキストのみでFormatBadgeView(カスタムView)を表示できないため、
        // FavoritesMenuContent/FavoritesNSMenuBridgeと同じく括弧書きの拡張子で区別する。
        .navigationTitle(windowTitle)
        // このウインドウ自身への参照をappStateに持たせておく。Finderから別の本を開こうとした
        // ときに「新しいタブで開く」設定の場合、どのウインドウへタブを追加すべきかを
        // NSApp.keyWindow(その時点でたまたまキーウインドウだったもの、必ずしも正しいとは
        // 限らない)に頼らず、本を開いている当のAppStateが持つウインドウへ確実に追加できる
        // ようにするため(詳細はAppState.hostWindowのコメント参照)。
        .onChange(of: appState.currentBook?.id) { _, _ in
            updateLastActiveBookRecordIfKeyWindow()
            updateBookContentsBrowserForCurrentBook()
            // サイドパネル上段(フォルダブラウザ)を、新しく開いた本のフォルダへ再アンカーする。
            // 再アンカーの契機はこの「本の切り替わり」**だけ**にしてある。以前はパネルを
            // 隠す設定のとき、ホバーで表示されるたびにも再アンカーしていた
            // (installSidePanelHoverMonitorIfNeeded)が、それだとフォルダブラウザで奥へ
            // 移動した状態がパネルが隠れるたびに失われ、常時表示のときと挙動が食い違っていた。
            // ユーザーの指示で、隠す設定でも常時表示と同じ(移動した場所はそのまま保たれ、
            // 本が切り替わったときだけ本の場所へ移る)に揃えた。
            sidePanelBrowser.handlePanelRevealed(currentBook: appState.currentBook)
        }
        // サイドパネル下段(本の中身ブラウザ)を、今実際に表示されているページへ追従させる
        // (ユーザー要望: ページ送りのたびにハイライト・スクロールをリアルタイムに追従させ、
        // フォルダ/ネストした書庫の境界をまたいだら表示中のフォルダ/書庫も切り替える)。
        // 本の切替直後は、新しいViewerViewのonAppearがcurrentVisiblePageSortKeysを更新する
        // ことで**たいていは**ここが発火する。ただし**新旧の値が同じだと発火しない**ため、
        // それだけには頼れない(updateBookContentsBrowserForCurrentBook側で呼び直している。
        // 理由はあちらのコメント参照)。
        .onChange(of: appState.currentVisiblePageSortKeys) { _, newValue in
            bookContentsBrowser?.revealCurrentPage(sortKeys: newValue)
        }
        // サイドパネルの幅をユーザーがドラッグで調整するたびに、次回起動時にも再現できるよう
        // preferencesへ書き戻す(hideToolbar等と同じ「AppStateへの書き戻し」パターンだが、
        // sidePanelWidthはAppStateではなくContentView自身の@Stateのため、ここで直接行う)。
        .onChange(of: sidePanelWidth) { _, newValue in
            preferences.sidePanelWidth = Double(newValue)
        }
        // サイドパネルを左右どちらに置くかを変更したら、ホバー表示中のパネルはいったん閉じる。
        // そのまま反対側へ瞬間移動させると、カーソルは元の端に残ったままパネルだけが移りつつ、
        // 次のマウス移動で「パネルより内側にいる」と判定されて即座に閉じることになり、
        // ちらついて見えるため。常時表示中は表示位置が入れ替わるだけで、この値は使われない。
        .onChange(of: preferences.sidePanelPosition) { _, _ in
            appState.isSidePanelRevealed = false
        }
        // 「同じフォルダのファイルを開く」の一覧を、並び順に関わる設定が変わったその場で
        // 並べ直す(ユーザー要望: フォルダブラウザの並べ替えに合わせる)。siblingBookOrderは
        // 関係する4つの設定を束ねた値なので、パネル上部の並べ替えメニュー・環境設定の
        // トグル・サイドパネル機能自体のON/OFF、どこから変えてもここで拾える
        // (AppPreferences.siblingBookOrder参照)。
        //
        // フォルダブラウザ側(SidePanelBrowserState.applySortSettings)と違い、ディスクを
        // 読み直す。あちらは一覧を保持していて並べ替えるだけで済むのに対し、こちらが持って
        // いるのはURLの列だけで、サイズや日付といった並べ替えに要る値を持たないため。
        // 設定の変更はユーザーの操作に伴う稀な出来事で、そのときこのメニューは開かれていない
        // (メニューを開いている間の更新はMenuBarMenuGateが保留する)ので、走査を1回増やす
        // ことよりも、AppStateが並べ替え用の属性まで抱え込まないほうを取った。
        .onChange(of: preferences.siblingBookOrder) { _, _ in
            appState.reloadSiblingBooks()
        }
        // カーソルがウインドウの外へ出たことを検知するグローバルモニタは、閉じるべきものが
        // 表示されている間だけ取り付ける(updateOutsideWindowMonitor参照)。
        .onChange(of: hasAutoRevealedChrome) { _, _ in
            updateOutsideWindowMonitor()
        }
        .onAppear {
            installSidePanelHoverMonitorIfNeeded()
            updateOutsideWindowMonitor()
            installMenuTrackingObserversIfNeeded()
        }
        .onDisappear {
            removeSidePanelHoverMonitor()
            removeOutsideWindowMonitor()
            removeMenuTrackingObservers()
        }
        // カーソルがメニューバーの上へ抜けた場合は、ローカル/グローバルどちらのマウス移動
        // モニタにもイベントが届かないため、AppKitのNSTrackingAreaによる検知で補う
        // (WindowMouseExitAccessorのコメント参照)。誤検知の可能性があるため、実際に閉じるか
        // どうかはdismissAutoRevealedChromeIfCursorLeftWindow側でカーソル位置を見て判断する。
        .background(WindowMouseExitAccessor {
            guard let window = appState.hostWindow else { return }
            dismissAutoRevealedChromeIfCursorLeftWindow(window)
        })
        .background(WindowAccessor { window in
            // バグ修正(ユーザー報告): SwiftUIは、ウインドウが閉じた後もこのViewをすぐには
            // 破棄せず、WindowAccessorのコールバックを既に閉じられた(isVisible == false)
            // ウインドウの参照で改めて呼ぶことがある(実機で確認済み)。ここでガードせずに
            // appState.hostWindowへ代入してしまうと、observeWindowBecameKey内の
            // willCloseNotificationハンドラがせっかくnilへ戻したhostWindowが、この後から来る
            // コールバックによって「閉じたはずのウインドウ」へ逆戻りしてしまう。この結果、
            // ウインドウを閉じた後もLaunchCoordinator.openAppState(forBookAt:)がこのAppStateを
            // 「まだ開いている」と誤認し、外部から同じ本を開こうとしたときに、閉じたウインドウを
            // makeKeyAndOrderFrontしようとするだけで新しいウインドウが作られず、本が表示されない
            // (ように見える)不具合があった。既に閉じられたウインドウの参照は無視する。
            guard window == nil || window!.isVisible else { return }
            guard appState.hostWindow !== window else { return }
            appState.hostWindow = window
            // バグ修正(ユーザー報告): ツールバーを隠す設定で、「横幅に合わせる」などページを
            // スクロールする表示モードのとき、ツールバーが隠れた瞬間にタイトルバーが消えて
            // 画像がウインドウの最上端まで広がっていた。SwiftUIのScrollViewは、上端が
            // 安全領域(タイトルバー)に接すると自動的にその下まで広がり、タイトルバーを
            // 透明にする(実測: ページ用のNSScrollViewの高さが内容領域の1377ptではなく
            // ウインドウ全高の1409ptになり、safeAreaInsets.top=32が付いていた)。ツールバーが
            // 見えている間はツールバーが上端を占めるので起きず、「画面内に収める」モードは
            // ScrollViewを使わないので起きない。
            //
            // SwiftUIのWindowGroupがウインドウに付ける`.fullSizeContentView`を外すと、内容領域が
            // タイトルバーの下に存在しなくなり、ScrollViewが広がる先そのものが無くなる。
            // 内容をタイトルバーの下まで広げる用途はこのアプリには無いので、これで固定する。
            // (Appleのドキュメントどおり、このスタイルではタイトルバーが下の内容を透かす
            // 描画になる: https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/fullsizecontentview )
            window?.styleMask.remove(.fullSizeContentView)
            // このウインドウがキーウインドウになるたびに、「前回終了時にアクティブだった
            // 画面/タブの本を復元する」機能のために、今表示している本のURLを記録しておく
            // (すべてのウインドウ/タブが対象。「main」「book」どちらのウインドウグループでも
            // 同様に動作してよいため、下のフレーム記憶と違って主ウインドウ限定にはしない)。
            if let window {
                observeWindowBecameKey(window)
            }
            // ウインドウのサイズ・位置を次回起動時に記憶する。AppKit標準の
            // NSWindow.setFrameAutosaveName/setFrameUsingNameを試したが、Dockに寄せて
            // 終了しても次回起動時にDockから離れて復元される不具合があった(setFrameUsingName
            // 内部で、画面の「表示可能領域」を基準に位置を自動調整する処理が働き、想定より
            // 余分な余白ができてしまっていたと考えられる)。そのため、ここでは自前でUserDefaultsに
            // 生のフレーム座標(NSStringFromRect)を保存・復元する、より単純で予測可能な方式に
            // 切り替える。「新しいウインドウ/タブで開く」やタブバーの「+」で追加された新しいタブ
            // (下のonAppear参照)には適用したくないため、今このウインドウが主ウインドウ
            // (launchCoordinator.primaryAppState)自身の場合にだけ適用する。
            //
            // バグ修正(ユーザー報告): 以前は`initialRequest == nil`も条件に含め、「book」ウインドウ
            // グループ(newWindow/newTab、および開く対象付きで開く場合全般)を一律除外していた。
            // しかしウインドウをすべて閉じた状態から外部アプリ等で本を開く場合、主ウインドウの
            // 代わりに開く対象付きの「book」ウインドウが開かれることがあり(QooViewerApp.
            // application(_:open:)参照)、この場合に一律除外していたせいで前回のウインドウ位置・
            // サイズが復元されず、毎回既定の位置で開いてしまう不具合があった。
            // 「今このウインドウが主ウインドウかどうか」(launchCoordinator.primaryAppState ===
            // appState)だけで判定するようにすることで、mainウインドウグループかbookウインドウ
            // グループかに関わらず、実際に主ウインドウの役割を担っているウインドウにだけ正しく
            // 位置・サイズの復元が適用されるようにした(「新しいウインドウ/タブで開く」で
            // 追加される、主ウインドウではないbookウインドウは、この時点で
            // launchCoordinator.primaryAppStateが別のAppStateを指しているため、これまで通り
            // 対象外のまま)。
            //
            // 補足: bookウインドウグループは`.windowResizability(.contentSize)`のため、
            // この時点(発火が早い)で適用してもSwiftUI自身の自動リサイズに後から上書きされて
            // しまう。そのため実際に主ウインドウの役割を引き継いだbookウインドウについては、
            // QooViewerApp.swiftのopenInNewWindow側で(自動リサイズが収まった、より遅い
            // タイミングで)改めて復元している。ここでの呼び出しは、mainウインドウグループ
            // (.windowResizability(.automatic)で、この早いタイミングでも上書きされない)に対して
            // 意味を持つ。
            if launchCoordinator.primaryAppState === appState, let window {
                restoreMainWindowFrameIfNeeded(window)
                observeMainWindowFrameChanges(window)
            }
        })
        .onAppear {
            // すでに主ウインドウ(primaryAppState)が存在するのに、URLの指定なしで
            // 「main」ウインドウグループの新しいインスタンス(=このContentView)が
            // 生成されるケースには、実は2通りある。
            // (a) タブバーの「+」ボタンでユーザーが明示的に新しいタブを追加した(正当。
            //     ウェルカム画面のタブが増えることが期待される動作)
            // (b) Finderの登録ファイルをDockアイコンへドラッグ&ドロップして開いたときなどに、
            //     AppKit/SwiftUI側がapplication(_:open:)の呼び出しとは別に、原因不明のまま
            //     この「空のmainウインドウ」をもう1つ自動的に開いてしまう(不正。
            //     applicationShouldOpenUntitledFile/applicationShouldHandleReopenをどちらも
            //     falseにしても防げなかった)
            // この時点(初期化直後)ではどちらも見分けが付かないため、少し待って判定する
            // (resolveAmbiguousNewMainWindow参照)。
            // "main"以外のWindowGroup(book/normal/private)は常に正当なウインドウ。
            // 主ウインドウの有無とは無関係に、こちらのコードが明示的に開いたものだから
            // (isMainWindowGroupのコメント参照)。
            //
            // バグ修正(実機で確認): ここは以前`isPrivateWindow`を見ていた。当時は
            // シークレットウインドウが"private" WindowGroupからしか生まれず、
            // 「シークレット = 明示的に開かれた」が成り立っていたためである。
            // 環境設定「シークレットモードで起動」(ユーザー要望)を足したことで、
            // **"main"ウインドウもシークレットになりうる**ようになり、この前提が崩れた。
            // その結果、AppKitが勝手に作った空の"main"ウインドウまで「常に正当」と見なされ、
            // Finderから本を開くたびに空のウインドウが1枚残るようになっていた
            // (統合ログで、2つ目のonAppearがこの分岐を素通りしていることを確認済み)。
            guard launchCoordinator.primaryAppState == nil || launchCoordinator.primaryAppState === appState || initialRequest != nil || !isMainWindowGroup else {
                resolveAmbiguousNewMainWindow()
                return
            }
            isConfirmedLegitimateWindow = true
            appState.preferences = preferences
            appState.recentFiles = recentFiles
            appState.folderAccess = folderAccess
            appState.favoritesStore = favoritesStore
            appState.bookmarkStore = bookmarkStore
            appState.layoutStore = layoutStore
            appState.metadataStore = metadataStore
            // 「同じ本を二重に開かない」判定のため
            // (AppState.open(request:reusesExistingWindow:)参照)。
            appState.launchCoordinator = launchCoordinator
            sidePanelBrowser.folderAccess = folderAccess
            sidePanelBrowser.preferences = preferences
            // 「ツールバーを隠す」「プログレスバーを隠す」「サイドパネルを隠す」は、前回終了時
            // (またはこのセッション中に他のウインドウで変更された時点)の値をpreferencesから
            // 引き継ぐ。これにより、新しいウインドウ/タブや次回起動時にも同じ表示状態で始まる。
            appState.hideToolbar = preferences.hideToolbar
            appState.hideProgressBar = preferences.hideProgressBar
            appState.hideSidePanel = preferences.hideSidePanel
            // サイドパネルの幅も同様に、前回ユーザーがドラッグで調整した値を引き継ぐ。
            sidePanelWidth = CGFloat(preferences.sidePanelWidth)
            // シークレットウインドウは主ウインドウにはならない(主ウインドウは位置・サイズの記憶や
            // 「最後に開いていた本」の記録など、永続化と結びついた役割を持つため)。
            // ただし「シークレットモードで起動」がONのときは、主ウインドウ自身がシークレット
            // なので除外しない(除外すると主ウインドウが永遠に決まらず、ウインドウ位置の記憶も
            // 外部からの「開く」の受け皿も失われる。AppState.actsAsRegularWindow参照)。
            if launchCoordinator.primaryAppState == nil, appState.actsAsRegularWindow {
                launchCoordinator.primaryAppState = appState
            }
            // 「すでに開いている本を新しいウインドウ/タブで開こうとしたときに、既存の
            // ウインドウ/タブをアクティブにする」機能のために、このウインドウ/タブのAppStateを
            // 開いている一覧へ登録する(QooViewerApp.openInNewWindow参照)。
            launchCoordinator.registerOpenAppState(appState)
            if let initialRequest {
                // このウインドウはこの本のために作られたので、既に同じ本を開いている
                // ウインドウがあっても譲らない(譲ると中身の無いウインドウだけが残る。
                // そもそも作る前にBookWindowOpenerが同じ判定を済ませている)。
                appState.open(request: initialRequest, reusesExistingWindow: false)
            } else if appState.actsAsRegularWindow {
                // 起動時の動作(フルスクリーン・前回の本を開く)は、あとから開いた
                // シークレットウインドウでは行わない。「シークレットモードで起動」がONの
                // ときは主ウインドウ自身がシークレットなので、ここは通す ―― そのうえで、
                // 「前回の本を開く」だけはperformLaunchActionsIfNeededの中で改めて
                // シークレットかどうかを見て弾く(そちらのコメント参照)。
                performLaunchActionsIfNeeded()
            }
        }
        // サイドパネルの行の右クリックから開く、リネーム・削除のダイアログ一式
        // (ユーザー要望)。中身は下のSidePanelEditingDialogsを参照。
        .sidePanelEditingDialogs(
            renamingFolder: $renamingFavoriteFolder,
            renamingBook: $renamingFavoriteBook,
            renamingBookmark: $renamingBookmark,
            renameText: $sidePanelRenameText,
            folderPendingDeletion: $favoriteFolderPendingDeletion,
            bookPendingDeletion: $favoriteBookPendingDeletion
        )
        .alert(
            "Error",
            isPresented: Binding(
                get: { appState.errorMessage != nil },
                set: { isPresented in
                    if !isPresented { appState.errorMessage = nil }
                }
            )
        ) {
            Button("OK") { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "")
        }
        // お気に入りを開こうとしたが、対応するファイル/フォルダが実際には存在しなかった場合の
        // アラート(要望5)。「お気に入りから削除」を選ぶと、favoritesStoreからそのお気に入りを
        // 削除する(AppState自身はfavoritesStoreへweakにしかアクセスできないため、削除の実行は
        // ここ、環境オブジェクトを直接持つContentView側で行う)。
        .alert(
            "Favorite Not Found",
            isPresented: Binding(
                get: { appState.missingFavorite != nil },
                set: { isPresented in
                    if !isPresented { appState.missingFavorite = nil }
                }
            )
        ) {
            Button("OK") { appState.missingFavorite = nil }
            // シークレットウインドウでは「お気に入りから削除」を出さない。
            //
            // このウインドウはお気に入りの一覧を表示し、そこから本を開くこともできる(読み取りは
            // 通常どおり行う)ため、実体が消えているお気に入りを開こうとしてこのアラートに
            // たどり着ける。削除はDBへの書き込みで、しかも元に戻せない操作なので、
            // 「シークレットウインドウはお気に入り・ブックマーク・レイアウト・メタデータを
            // 登録も編集もしない」という約束から外れる(AppState.isPrivateWindowのコメント参照)。
            // 見つからなかったことを伝えるところまでは有用なので、アラート自体は出す。
            if !isPrivateWindow {
                Button("Remove from Favorites", role: .destructive) {
                    if let favorite = appState.missingFavorite {
                        favoritesStore.delete(favorite)
                    }
                    appState.missingFavorite = nil
                }
            }
        } message: {
            // 文字列補間をそのままText("...")に渡すと手書きのLocalizable.xcstringsでは翻訳と
            // 紐付かないため、FavoriteFolderPickerView.swiftの重複確認アラートと同じく、
            // 固定文字列の断片をText同士の+でつなぐ形にしている。
            Text("The file or folder for “") + Text(appState.missingFavorite?.title ?? "")
                + Text("” could not be found. It may have been moved or deleted.")
        }
    }

    /// アプリ起動時に一度だけ(最初のウインドウでだけ)、「前回開いていた本を自動的に開く」
    /// 「フルスクリーンで起動する」設定を反映する。「新しいウインドウで開く」などで
    /// あとから追加したウインドウでは行わない(LaunchCoordinator参照)。
    private func performLaunchActionsIfNeeded() {
        guard !launchCoordinator.didPerformInitialLaunchActions else { return }
        launchCoordinator.didPerformInitialLaunchActions = true

        // 「前回読んでいた本を開き直す」はシークレットウインドウでは行わない。記録を残さない
        // ウインドウが、前回の読書内容を勝手に映し出すのでは意味が通らない(Chromeの
        // シークレットウインドウが前回のセッションを復元しないのと同じ)。
        // 「シークレットモードで起動」がONのときは、そもそも記録が増えないので実質何も
        // 起きないが、モードをONにする前の記録が残っていることはありうるため明示的に弾く。
        if preferences.launchOpensLastBook, !isPrivateWindow, appState.currentBook == nil,
           let url = resolveLastActiveBookURLIfUnchanged() {
            appState.open(url: url)
        }

        if preferences.launchFullScreen {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000)
                if let window = NSApp.windows.first, !window.styleMask.contains(.fullScreen) {
                    window.toggleFullScreen(nil)
                }
            }
        }
    }

    /// 主ウインドウ以外に現れた、URL指定なしの新しい「main」ウインドウ(上のonAppear参照)を、
    /// 正当なもの(タブバーの「+」で追加された新しいタブ)か、不正なもの(Finderからの
    /// ファイルオープン時などにAppKit/SwiftUIが原因不明のまま追加してしまう余分な空
    /// ウインドウ)かを判別し、正当なら通常どおりセットアップして表示し、不正なら閉じる。
    ///
    /// 見分け方: 正当な新しいタブは、AppKitによってすぐに既存のウインドウのタブグループへ
    /// 自動的に追加される(NSWindow.tabbedWindowsが2つ以上になる)。不正な方はどのタブ
    /// グループにも属さない単独のウインドウのままなので、少し待っても2つ以上にならない。
    ///
    /// 判定が終わるまでウインドウを一瞬隠しておき(orderOut)、正当と分かればすぐに
    /// 表示し直す(makeKeyAndOrderFront)ことで、不正な場合に「一瞬だけ表示されてすぐ
    /// 消える空ウインドウ」がユーザーの目にできるだけ見えないようにする。
    private func resolveAmbiguousNewMainWindow() {
        Task { @MainActor in
            // appState.hostWindowはWindowAccessor経由で設定されるため、間に合っていない
            // ごく短い間だけ待つ。
            var window: NSWindow?
            for _ in 0..<20 {
                if let found = appState.hostWindow {
                    window = found
                    break
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            guard let window else { return }
            // ここでorderOut(隠す)をしてしまうと、タブグループへの参加自体が解除されて
            // しまうらしく、下のtabbedWindows判定が常に「単独」と誤判定されてしまうことが
            // 分かった。そのため、判定が終わるまで何もせずそのまま(表示された状態)で待つ
            // (不正なケースでは、閉じるまでのごく短い間だけ画面に映ってしまうが許容する)。

            // タブグループへの追加が完了するまで、少し待ちながら繰り返し確認する。
            for _ in 0..<20 {
                if (window.tabbedWindows?.count ?? 1) > 1 {
                    // 正当な新しいタブ。主ウインドウとして登録したりperformLaunchActionsIfNeeded
                    // を行ったりはせず、通常のウインドウ/タブと同様に最低限のセットアップだけ
                    // 行う(すでに表示されているので、あらためて表示し直す必要はない)。
                    isConfirmedLegitimateWindow = true
                    appState.preferences = preferences
                    appState.recentFiles = recentFiles
                    appState.folderAccess = folderAccess
                    appState.favoritesStore = favoritesStore
                    appState.bookmarkStore = bookmarkStore
                    appState.layoutStore = layoutStore
                    appState.metadataStore = metadataStore
                    appState.launchCoordinator = launchCoordinator
                    sidePanelBrowser.folderAccess = folderAccess
                    sidePanelBrowser.preferences = preferences
                    appState.hideToolbar = preferences.hideToolbar
                    appState.hideProgressBar = preferences.hideProgressBar
                    appState.hideSidePanel = preferences.hideSidePanel
                    sidePanelWidth = CGFloat(preferences.sidePanelWidth)
                    launchCoordinator.registerOpenAppState(appState)
                    return
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            // 最後までどのタブグループにも加わらなければ、不正な空ウインドウと判断して閉じる。
            window.close()
        }
    }

    /// 主ウインドウのサイズ・位置を記憶するためのUserDefaultsキー。値は
    /// NSStringFromRectで文字列化した生のフレーム座標をそのまま保存する。
    /// この文字列リテラルは、QooViewerApp.swiftのopenInNewWindow(actsAsPrimaryWindow:trueの
    /// 分岐)でも直接指定されている(ContentViewのインスタンスメソッドをAppDelegate側から
    /// 呼べないため)。変更する場合はそちらも合わせて変更すること。
    private static let mainWindowFrameDefaultsKey = "qooViewer.mainWindowFrame"

    /// 前回終了時に保存しておいたウインドウのフレーム(位置・サイズ)があれば、そのまま
    /// 適用する。AppKit標準のNSWindow.setFrameUsingNameも試したが、内部で「画面の
    /// 表示可能領域を基準に位置を自動調整する」処理が働くらしく、Dockに隙間なく
    /// 寄せて終了しても次回起動時にDockから離れて復元されてしまう不具合があったため、
    /// ここでは生のCGRectをそのまま渡す、より単純で予測可能な方式にしている。
    private func restoreMainWindowFrameIfNeeded(_ window: NSWindow) {
        guard let saved = UserDefaults.standard.string(forKey: Self.mainWindowFrameDefaultsKey) else { return }
        let rect = NSRectFromString(saved)
        guard rect.width > 0, rect.height > 0 else { return }
        window.setFrame(rect, display: true)
    }

    /// ウインドウの移動・リサイズのたびに、そのときのフレームをUserDefaultsへ保存する。
    ///
    /// バグ修正(ユーザー報告): 以前はこの2つの購読を登録するだけでremoveObserverを一切
    /// 呼んでおらず、コメントでは「windowはNotificationCenterへweakに保持されるだけなので、
    /// ウインドウが閉じられれば監視も自然に無意味になる(主ウインドウは通常アプリの生存中
    /// 1つだけ)」としていたが、これは下のobserveWindowBecameKeyと同じく誤りだった。
    /// object:に渡すwindowはweakに保持されフィルタに使われるだけで、クロージャ自体は
    /// removeObserverするまでNotificationCenterに強参照され続ける。しかも
    /// NotificationCenterのobject:によるフィルタはポインタ一致で行われるため、解除し損ねた
    /// 購読が残っている間に、閉じたウインドウとたまたま同じメモリアドレスに新しいNSWindowが
    /// 確保されると、その新しいウインドウの移動・リサイズが「主ウインドウのフレーム」として
    /// 保存されてしまう(ViewerView.setUpWindowObserversの末尾に記録されている、同じ原因に
    /// よる不具合と同型)。observeWindowBecameKeyと同じく、ウインドウが閉じる
    /// (NSWindow.willCloseNotification)タイミングで、自分自身を含めて確実に解除する。
    private func observeMainWindowFrameChanges(_ window: NSWindow) {
        // トークンをローカルのvarで持ち回さずNotificationObserverTokensへ預ける理由は、
        // そちらの型コメント参照(自分自身を解除する購読を素直に書くと、Swift 6の並行性
        // チェックが「mutated after capture by sendable closure」として警告するため)。
        let tokens = NotificationObserverTokens()
        let save: @Sendable (Notification) -> Void = { notification in
            // queue: .mainで登録するため実行時には必ずMainActor上にいる
            // (NSWindow.frame・Self.mainWindowFrameDefaultsKeyはどちらもMainActor隔離)。
            MainActor.assumeIsolated {
                guard let window = notification.object as? NSWindow else { return }
                UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.mainWindowFrameDefaultsKey)
            }
        }
        tokens.add(NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main, using: save
        ))
        tokens.add(NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main, using: save
        ))
        tokens.add(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            // queue: .mainのため実行時には必ずMainActor上だが、クロージャの型は静的には
            // MainActor隔離だと分からない(プロジェクト内の同種の箇所と同じ対処)。
            MainActor.assumeIsolated {
                tokens.removeAll()
            }
        })
    }

    /// このウインドウがキーウインドウになるたびに、今表示している本(なければ「本を
    /// 開いていない状態」)をLastActiveBookStoreに記録する。
    ///
    /// バグ修正(ユーザー報告): 以前はこの購読を登録するだけでremoveObserverを一切呼んでおらず、
    /// コメントでは「windowはNotificationCenterへweakに保持されるだけなので、ウインドウが
    /// 閉じられれば監視も自然に無意味になる」としていたが、これは誤りだった。object:に渡す
    /// windowはweakに保持されフィルタに使われるだけで、クロージャ自体(とそれが暗黙に
    /// キャプチャしているappStateを含むこのContentView)はremoveObserverするまで
    /// NotificationCenterに強参照され続ける。ここでウインドウが閉じる
    /// (NSWindow.willCloseNotification)タイミングで、自分自身を含む両方の購読を確実に
    /// removeObserverする。
    ///
    /// 合わせて、appState.hostWindow、およびこのウインドウがLaunchCoordinator.primaryAppState
    /// なら合わせてそちらもnilへ戻す。appStateがLaunchCoordinatorからweakに参照されている
    /// だけとはいえ、SwiftUIがこのContentViewインスタンス自体の解放をいつ行うかは保証されて
    /// いない(QooViewerApp.swiftの"main" WindowGroupに`.restorationBehavior(.disabled)`を
    /// 指定する前は、これが原因でappStateがウインドウを閉じてもすぐには解放されず、
    /// primaryAppStateが閉じたウインドウを指したまま残る不具合があった)。ここで明示的にnilへ
    /// 戻しておくことで、解放の実際のタイミングに関わらず即座に「主ウインドウが無い」状態を
    /// 正しく反映できる。
    private func observeWindowBecameKey(_ window: NSWindow) {
        // トークンの持ち方についてはNotificationObserverTokensの型コメント参照。
        let tokens = NotificationObserverTokens()
        tokens.add(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { _ in
            updateLastActiveBookRecordIfKeyWindow()
        })
        tokens.add(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            // queue: .mainを指定しているため実行時には必ずMainActor上で呼ばれるが、クロージャ
            // 自体の型は静的にMainActor隔離だと分からないため、MainActor隔離のappState.
            // hostWindow / launchCoordinator.primaryAppStateをそのまま読み書きすると警告になる
            // (BookmarkStore.init/ViewerViewModel.initなど、プロジェクト内の同種の箇所と同じ
            // 理由・同じ対処)。
            MainActor.assumeIsolated {
                if appState.hostWindow === window {
                    appState.hostWindow = nil
                }
                if launchCoordinator.primaryAppState === appState {
                    launchCoordinator.primaryAppState = nil
                }
                tokens.removeAll()
            }
        })
    }

    /// このウインドウがキーウインドウ(今アクティブな画面/タブ)のときにだけ、表示している
    /// 本のURLをLastActiveBookStoreへ記録する(バックグラウンドのタブ/ウインドウでの変化を
    /// 誤って記録しないようにするための判定)。本を開いていなければ記録をクリアする
    /// (終了時にウェルカム画面を見ていたなら、次回もウェルカム画面から始まるのが正しいため)。
    ///
    /// isConfirmedLegitimateWindowがtrueになるまでは何もしない(このウインドウがまだ
    /// 正当なものと確認できていない間に誤って記録をクリアしてしまうのを防ぐため。
    /// isConfirmedLegitimateWindowのコメント参照)。
    ///
    /// 「起動時に前回開いていた本を自動的に開く」設定がOFFのときは、この記録自体が
    /// 使われることがないため、無駄な書き込みをしないよう最初に確認する。
    private func updateLastActiveBookRecordIfKeyWindow() {
        // シークレットウインドウで開いている本は「最後に開いていた本」として記録しない
        // (クリアもしない。通常ウインドウの記録に干渉させないため)。
        guard preferences.launchOpensLastBook, !isPrivateWindow else { return }
        // その場限りの本(直接渡された画像から作った本)も同じ理由で記録しない。記録して
        // しまうと、そのsourceURL(複数枚のときは先頭の1枚)が「最後に開いていた本」として残り、
        // 次回起動時にその画像が勝手に開いてしまう(クリアもしない。直前まで開いていた
        // 通常の本の記録を消さないため)。
        guard appState.currentBook?.isTransient != true else { return }
        guard isConfirmedLegitimateWindow,
              let hostWindow = appState.hostWindow, NSApp.keyWindow === hostWindow else { return }
        if let url = appState.currentBook?.sourceURL {
            LastActiveBookStore.record(url: url)
        } else {
            LastActiveBookStore.clear()
        }
    }

    /// 「起動時に前回開いていた本を自動的に開く」の実際の判定(performLaunchActionsIfNeeded
    /// から呼ぶ)。前回終了時にアクティブだった画面/タブが表示していたファイルのURLを
    /// LastActiveBookStoreから取得し、次の両方を満たす場合にだけそのURLを返す。
    /// - まだ存在している(削除・移動されていない。LastActiveBookStore.resolve内で確認済み)
    /// - 前回開いたときと中身が変わっていなさそう(BookReadingStateに記録済みの、更新日時・
    ///   ファイルサイズの「指紋」と一致する。本の内容差し替え検知(ViewerViewModel.init参照)
    ///   と同じ考え方だが、実際に本を読み込む前に判定したいため、ここでは読み込みを伴わない
    ///   軽量なリソース情報だけで比較する)
    /// どちらかを満たさない場合は復元を断念してnilを返す(ウェルカム画面のまま。エラーは
    /// 表示しない)。
    private func resolveLastActiveBookURLIfUnchanged() -> URL? {
        guard let url = LastActiveBookStore.resolve() else { return nil }

        let bookID = url.path
        // #Predicateでの絞り込みフェッチが、レイアウト変更直後などに0件を誤って返すことがある
        // 不具合が実機で確認された(LayoutStore.pageOverrides(forBookID:)のコメント参照)ため、
        // 絞り込み無しで全件取得してからSwift側でfilterする。
        let allReadingStates = (try? modelContext.fetch(FetchDescriptor<BookReadingState>())) ?? []
        guard let state = allReadingStates.first(where: { $0.bookID == bookID }),
              let recordedModificationDate = state.recordedSourceModificationDate else {
            // 指紋の記録がまだない(初めて記録される、またはこの仕組みを導入する前の
            // データ)場合は、比較のしようがないので復元してよいものとして扱う。
            return url
        }

        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let resourceValues = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let currentModificationDate = resourceValues?.contentModificationDate
        let currentFileSize = resourceValues?.fileSize.map(Int64.init)

        guard recordedModificationDate == currentModificationDate,
              state.recordedSourceFileSize == currentFileSize else {
            return nil
        }
        return url
    }

    // MARK: - サイドパネル

    /// サイドパネルを、HStackの実レイアウトとして常時表示すべきかどうか(body参照)。
    /// 左右どちらに置くかによって組み込む位置が変わるため、条件式を1箇所にまとめてある。
    private var showsDockedSidePanel: Bool {
        preferences.sidePanelFeatureEnabled && !appState.hideSidePanel
    }

    /// カーソルの位置によって一時的に表示されているもの(ホバー表示中のサイドパネル、
    /// またはツールバー/プログレスバー)が1つでもあるかどうか。カーソルがウインドウの外へ
    /// 出たときに閉じる対象があるかの判定であり、ウインドウ外検知用のグローバルモニタを
    /// 取り付けておく条件そのもの(updateOutsideWindowMonitor参照)。
    private var hasAutoRevealedChrome: Bool {
        appState.isSidePanelRevealed || appState.isChromeAutoRevealed
    }

    /// サイドパネル本体を組み立てる。常時表示(HStackへの組み込み)・hideSidePanel時の
    /// ホバー表示(ZStackオーバーレイ)の両方から呼ばれ、違いはdismissesOnActionだけ。
    /// 常時表示中は「本を開く」「ページへジャンプする」操作をしてもパネル自体は消える
    /// 必要が無い(isSidePanelRevealedを操作しても常時表示の可視条件には影響しないため
    /// 実害は無いが、意味の無い代入を避けるため呼び分けている)。
    @ViewBuilder
    private func sidePanelView(dismissesOnAction: Bool) -> some View {
        SidePanelView(
            folderState: sidePanelBrowser,
            bookContentsState: bookContentsBrowser,
            mode: $preferences.sidePanelMode,
            width: $sidePanelWidth,
            position: preferences.sidePanelPosition,
            bookPages: appState.currentBookPages,
            fetchResourceSnapshot: appState.fetchResourceSnapshot,
            // 右クリックの「Finderで開く」「画像をエクスポート」用(ユーザー要望)。
            // どちらもViewerViewが持つ実装への橋渡し(AppState.exportPageImage参照)。
            bookSourceURL: appState.currentBook?.sourceURL,
            onExportPage: { index in appState.exportPageImage?(index) },
            onOpen: { url in
                if dismissesOnAction { appState.isSidePanelRevealed = false }
                appState.open(url: url)
            },
            onBrowseToFolder: { url in
                if dismissesOnAction { appState.isSidePanelRevealed = false }
                // 履歴には残さない(SidePanelView.onBrowseToFolderのコメント参照)。
                // 「開く」指示ではなく移動の結果そこが映るだけなので、同じ本を開いている
                // 別のウインドウへも譲らない(AppState.open(request:reusesExistingWindow:)参照)。
                appState.open(url: url, recordsInHistory: false, reusesExistingWindow: false)
            },
            onJumpToPage: { index in
                appState.jumpToPageIndex?(index)
                if dismissesOnAction { appState.isSidePanelRevealed = false }
            },
            // ページの右クリックからのブックマークの追加/削除(ユーザー要望)。実装は
            // ViewerViewが持つため橋渡し越しに呼ぶ(AppState.toggleBookmarkAtIndex参照)。
            // パネルは閉じない ―― 続けて別のページにも付けられるようにするため。
            onToggleBookmarkAtPage: { index in appState.toggleBookmarkAtIndex?(index) },
            // 行の右クリックからの「新規ノーマル/シークレットウインドウ・新規タブで開く」
            // (ユーザー要望)。開き方の判断も実際の手順もBookWindowOpenerが1箇所で持つ。
            // 派生元(from:)はこのウインドウのAppState ―― 新しいタブの追加先と、
            // 「新規タブで開く」がシークレットを引き継ぐかどうかがここで決まる。
            //
            // パネルは閉じない(SidePanelView.onOpenInNewWindowのコメント参照)。
            onOpenInNewWindow: { url, destination in
                BookWindowOpener.open(
                    BookOpenRequest(url),
                    to: destination,
                    from: appState,
                    launchCoordinator: launchCoordinator,
                    openWindow: openWindow
                )
            },
            bookmarks: appState.currentBookmarks,
            currentPageIndex: appState.currentPageIndex,
            hasBook: appState.currentBook != nil,
            currentBookPath: appState.currentBook?.id,
            loadPageThumbnail: appState.loadPageThumbnail,
            isPrivateWindow: isPrivateWindow,
            // ＋/鉛筆(お気に入り・ブックマークの追加/編集)は、履歴の非表示とは別条件。
            // その場限りの本でも無効にする必要があるが、履歴そのものは通常どおり見せる
            // (SidePanelViewのallowsLibraryEditingのコメント参照)。
            allowsLibraryEditing: !isPrivateWindow && appState.currentBook?.isTransient != true,
            loadPageImage: appState.loadPageImage,
            pageThumbnailGeneration: appState.pageThumbnailGeneration,
            // お気に入りへの追加(登録先フォルダの選択シート)はViewerViewが持っているため、
            // AppState経由の橋渡しを使う(AppState.addFavoriteActionのコメント参照)。
            // 本を開いていないときはnil = ボタン自体がhasBook: falseで無効化されている。
            onAddFavorite: { appState.addFavoriteAction?() },
            onEditFavorites: { openWindow(id: "favoritesOrganizer") },
            // お気に入りの行だけは、開く前にセキュリティスコープ付きブックマークを解決する
            // 必要がある。見つからなければ通常の「開く」(AppState.openFavorite)と同じく
            // アラートを出す(シークレットウインドウでは「お気に入りから削除」は出ない ――
            // 保存データへの変更にあたるため。missingFavoriteの扱いはViewerView側が持つ)。
            onOpenFavoriteInNewWindow: { favorite, destination in
                guard let url = favoritesStore.resolvedExistingURL(for: favorite) else {
                    appState.missingFavorite = favorite
                    return
                }
                BookWindowOpener.open(
                    BookOpenRequest(url),
                    to: destination,
                    from: appState,
                    launchCoordinator: launchCoordinator,
                    openWindow: openWindow
                )
            },
            onOpenFavorite: { favorite in
                if dismissesOnAction { appState.isSidePanelRevealed = false }
                // 環境設定「お気に入りを開くとき」(新しいタブ/ウインドウ)の判定はViewerViewが
                // 持っている。本を開いていない(=ViewerViewが無い)場合は、置き換える対象の本
                // 自体が無いためそのまま開く(AppState.openFavoriteActionのコメント参照)。
                if let action = appState.openFavoriteAction {
                    action(favorite)
                } else {
                    appState.openFavorite(favorite)
                }
            },
            // 行の右クリックからのリネーム・削除(ユーザー要望)。実際の入力欄・確認は
            // このビューが持つアラートで行う(isSidePanelEditingDialogPresentedのコメント参照)。
            //
            // 開く直前にrenameTextを一度空にしてから、次のランループで現在の名前を入れる。
            // 同じアラートを続けて開いた場合、@Stateへ同じ値を代入しても変化とみなされず
            // TextFieldに反映されないことがあるため(FavoritesOrganizerViewと同じ対処)。
            onRenameFavorite: { entry in
                sidePanelRenameText = ""
                switch entry {
                case .folder(let folder):
                    renamingFavoriteFolder = folder
                    DispatchQueue.main.async { sidePanelRenameText = folder.name }
                case .book(let book):
                    renamingFavoriteBook = book
                    DispatchQueue.main.async { sidePanelRenameText = book.title }
                }
            },
            onDeleteFavorite: { entry in
                switch entry {
                case .folder(let folder): favoriteFolderPendingDeletion = folder
                case .book(let book): favoriteBookPendingDeletion = book
                }
            },
            onAddBookmark: { appState.addBookmarkAction?() },
            onEditBookmarks: { showBookmarkEditorWindow() },
            onJumpToBookmark: { bookmark in
                appState.jumpToBookmark?(bookmark)
                if dismissesOnAction { appState.isSidePanelRevealed = false }
            },
            onRenameBookmark: { bookmark in
                sidePanelRenameText = ""
                renamingBookmark = bookmark
                DispatchQueue.main.async { sidePanelRenameText = bookmark.name }
            },
            // ブックマークだけは確認を挟まずその場で消す(SidePanelView側のコメント参照)。
            onDeleteBookmark: { bookmark in
                bookmarkStore.delete(bookmark)
            }
        )
    }

    /// 「ブックマーク・レイアウトの編集」ウインドウを、ブックマーク向けの絞り込みで開く
    /// (ViewerView.showBookmarkEditor、およびメニューバーの「Edit Bookmarks…」と同じ内容)。
    /// launchCoordinator.setActiveBookAppState(appState)を明示的に呼んでおくことで、ウインドウが
    /// キーになったときの通知を待たずに、確実にこのウインドウの本を対象にしてから開ける。
    private func showBookmarkEditorWindow() {
        if appState.currentBook != nil {
            launchCoordinator.setActiveBookAppState(appState)
        }
        launchCoordinator.pendingEditorInitialFocus = .bookmarks
        openWindow(id: "editBookmarks")
    }

    /// サイドパネルのホバー表示/非表示を検知する、ウインドウ内`.mouseMoved`のローカルモニタ。
    /// ViewerView.makeScrollMonitorとは完全に独立しており、カーソルのX座標だけを見て判定する。
    ///
    /// このウインドウ宛て以外のマウス移動(このアプリの他のウインドウ・環境設定ウインドウなど)は
    /// ホバー表示の判定には使わないが、そのときカーソルが幾何的にもこのウインドウの外にあれば、
    /// 自動表示中のものを閉じる対象になる(dismissAutoRevealedChromeIfCursorLeftWindow参照)。
    private func installSidePanelHoverMonitorIfNeeded() {
        guard sidePanelHoverMonitor == nil else { return }
        sidePanelHoverMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { event in
            guard let window = appState.hostWindow else { return event }
            // カーソルがウインドウの外へ出ていれば、ホバー表示の判定より先にすべて閉じる。
            if dismissAutoRevealedChromeIfCursorLeftWindow(window) { return event }
            guard event.window === window else { return event }
            updateSidePanelReveal(forMouseLocationInWindow: event.locationInWindow, window: window)
            return event
        }
    }

    /// マウスカーソルの位置に応じて、ホバー表示中のサイドパネルを表示/非表示する。
    ///
    /// 表示メニューの「サイドパネルを隠す」がOFF(既定)のときは、サイドパネルは常時表示
    /// されているため何もしない(hideToolbar/hideProgressBarのY座標版の自動隠しが
    /// フルスクリーン中またはON時にしか意味を持たないのと同じ考え方)。ONのときだけ、
    /// 表示前はウインドウ端の狭い帯(sidePanelRevealBandWidth)に入ったら表示し、表示後は
    /// パネル自体の表示幅(sidePanelWidth。ユーザーがドラッグで調整できるため固定値ではない。
    /// 表示前の帯よりずっと広い)よりビューア側へ出たら閉じる。もし表示後も同じ狭い帯を
    /// 非表示条件に使ってしまうと、パネル自体がその帯よりずっと広く描画されているため、
    /// パネルの上にカーソルがあるのに閉じてしまう(表示直後にちらつく)不具合になる。
    /// ユーザー要望により、クリックでは閉じない(ページ表示エリアをクリックしただけで本の
    /// 閲覧を妨げないようにするため)。
    ///
    /// 左右どちらの端を見るかは環境設定(sidePanelPosition)で決まる。判定はウインドウ座標系の
    /// X座標(常に左が原点)で行い、右側配置のときはウインドウの内容幅から見た距離に読み替える。
    ///
    /// ツールバー/プログレスバーの自動表示(Y座標の帯、ViewerView側)とは判定ロジック・
    /// 描画レイヤーともに独立しているが、パネル側の端の上下の角では両方の帯が同時に
    /// 成立し得る。何も対策しないと、表示中のツールバーの上をカーソルが横へ移動して
    /// 端に近づいただけでサイドパネルまで表示されてしまう(ユーザー報告)。
    /// appState.isChromeAutoRevealed(ツールバー/プログレスバーが今まさに表示されているか)を
    /// 見て、それらが既にカーソルの主導権を握っている間は新たに表示しない。
    private func updateSidePanelReveal(forMouseLocationInWindow location: CGPoint, window: NSWindow) {
        guard preferences.sidePanelFeatureEnabled, appState.hideSidePanel else { return }
        // 拡大鏡(ルーペ)表示中は、カーソルを端に近づけてもサイドパネルを表示させない
        // (ユーザー要望: 拡大鏡での閲覧を妨げないため。ONにした瞬間の強制非表示は
        // ViewerViewのisLoupeActiveのonChange側で行う)。
        guard !appState.isLoupeActive else { return }
        // メニューが開いている間は、表示も非表示も行わない
        // (installMenuTrackingObserversIfNeededのコメント参照)。
        guard !isMenuTracking else { return }
        // パネルの行から開いたリネーム・削除のダイアログが出ている間も同じ
        // (isSidePanelEditingDialogPresentedのコメント参照)。
        guard !isSidePanelEditingDialogPresented else { return }
        // パネルを置いている側のウインドウ端から、カーソルまでの距離。左配置ならX座標そのもの、
        // 右配置なら「内容の右端からの距離」。以降の判定は左右で完全に共通になる。
        let distanceFromPanelEdge: CGFloat
        switch preferences.sidePanelPosition {
        case .left:
            distanceFromPanelEdge = location.x
        case .right:
            // ウインドウ座標系のX座標は、タイトルバーの有無に関わらず内容ビューの左端が原点。
            // 右端の座標は内容ビューの幅そのものになる(取得できない場合のみフレーム幅で代用)。
            let contentWidth = window.contentView?.bounds.width ?? window.frame.width
            distanceFromPanelEdge = contentWidth - location.x
        }
        if appState.isSidePanelRevealed {
            // + sidePanelHideMargin: パネルのビューア側の端にある幅調整ハンドル
            // (widthDragHitArea)自体が境界(sidePanelWidth)ぎりぎりの位置にあるため、
            // 余裕を持たせないとハンドルをつかもうとしただけでここに引っかかり隠れてしまう
            // (ユーザー報告)。
            if distanceFromPanelEdge > sidePanelWidth + Self.sidePanelHideMargin {
                appState.isSidePanelRevealed = false
            }
        } else if distanceFromPanelEdge <= Self.sidePanelRevealBandWidth, !appState.isChromeAutoRevealed {
            // ここでフォルダブラウザを再アンカーしてはいけない(本の切り替わりを見ている
            // .onChange(of: appState.currentBook?.id)のコメント参照)。表示するだけ。
            appState.isSidePanelRevealed = true
        }
    }

    /// カーソルがこのウインドウの外に出ていれば、マウスの位置によって自動表示されているもの
    /// (ホバー表示中のサイドパネル、およびツールバー/プログレスバー)をすべて閉じ、trueを返す
    /// (ユーザー要望)。
    ///
    /// 呼び出し経路は3つあり、いずれも「カーソルが外に出たかもしれない」という通知でしかない。
    /// 実際に閉じるかどうかの判断はすべてここに集約している。
    /// - ローカルモニタ: このアプリ宛てのマウス移動(installSidePanelHoverMonitorIfNeeded)
    /// - グローバルモニタ: 他のアプリ宛てのマウス移動(updateOutsideWindowMonitor)
    /// - NSTrackingArea: メニューバーへ抜けた場合など、上の2つに届かない経路
    ///   (WindowMouseExitAccessor)
    ///
    /// 判定はウインドウのフレーム(スクリーン座標)に入っているかどうかだけで行う。他のアプリの
    /// ウインドウがこのウインドウの上に重なっており、その上をカーソルが通っている場合は「外」とは
    /// 見なさないが、その場合そもそもパネル自体が隠れて見えておらず実害が無いため、判定を
    /// 複雑にしてまで扱う必要は無いと判断した。
    ///
    /// ツールバー/プログレスバー側は、実際の表示状態(ViewerViewの@State)を直接触れないため
    /// AppState経由の橋渡し(hideAutoRevealedChrome)を呼ぶ。本を開いていない(ViewerViewが
    /// 無い)ときはnilで、閉じるべきものも無いため何も起きない。
    @discardableResult
    private func dismissAutoRevealedChromeIfCursorLeftWindow(_ window: NSWindow) -> Bool {
        guard !window.frame.contains(NSEvent.mouseLocation) else { return false }
        // メニューが開いている間は閉じない。開いたメニュー自体がウインドウの外へはみ出して
        // 表示されるため、その上へカーソルを動かしただけでここへ来てしまう
        // (installMenuTrackingObserversIfNeededのコメント参照)。カーソルが外に出ていること
        // 自体は事実なので、戻り値はtrueのまま返す。
        guard !isMenuTracking else { return true }
        // パネルの行から開いたダイアログが出ている間も閉じない。ダイアログはウインドウの
        // 外側にはみ出さないが、そこへカーソルを運ぶ途中でウインドウの外を通ることはある。
        guard !isSidePanelEditingDialogPresented else { return true }
        // 閉じるものが1つも無ければ、外に出ていること(戻り値)だけ伝えて何もしない。
        // このアプリの他のウインドウ(環境設定ウインドウなど)の上でマウスを動かしている間は
        // ローカルモニタがマウス移動のたびにここへ来るため、無条件に@Publishedへ書き戻すと、
        // 値が変わらなくてもobjectWillChangeが毎回発火し、ウインドウ全体が無駄に再評価される。
        guard hasAutoRevealedChrome else { return true }
        if appState.isSidePanelRevealed {
            appState.isSidePanelRevealed = false
        }
        appState.hideAutoRevealedChrome?()
        return true
    }

    /// カーソルがウインドウの外へ出たことを、他のアプリの上を通っている間も検知できるように
    /// するためのグローバルモニタを、必要に応じて付け外しする。
    ///
    /// ローカルモニタ(installSidePanelHoverMonitorIfNeeded)はこのアプリ宛てのイベントしか
    /// 見られないため、カーソルが他のアプリのウインドウやデスクトップの上へ出ていくと、
    /// そこから先のマウス移動が一切届かない。ページ一覧パネルの「外側クリックで閉じる」
    /// (ViewerView.installThumbnailGridOutsideClickMonitorsIfNeeded)と同じく、ローカルと
    /// グローバルの2本立てにすることで、どちらの経路でも確実に検知する。
    ///
    /// グローバルモニタはこのアプリの外で起きるマウス移動すべてで呼ばれるため、閉じるべきものが
    /// 1つでも表示されている間(isSidePanelRevealed / isChromeAutoRevealed)だけ取り付ける。
    /// なお、このモニタからはホバー表示の判定(updateSidePanelReveal)は行わない。他のアプリの
    /// ウインドウがこのウインドウに重なっている場合、カーソルはそのアプリの上にあるのに座標だけは
    /// このウインドウの内側、という状態があり得るため。
    private func updateOutsideWindowMonitor() {
        guard hasAutoRevealedChrome else {
            removeOutsideWindowMonitor()
            return
        }
        guard outsideWindowMonitor == nil else { return }
        outsideWindowMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { _ in
            guard let window = appState.hostWindow else { return }
            dismissAutoRevealedChromeIfCursorLeftWindow(window)
        }
    }

    /// このアプリのメニュー(メニューバー、右クリックメニュー、そしてサイドパネル上部の
    /// 並べ替えメニューのようなウインドウ内のポップアップ)が開いている間は、ホバー表示中の
    /// サイドパネルを閉じないようにするための購読を取り付ける。
    ///
    /// 開いたメニューはウインドウの外へはみ出して表示されるため、何もしないと、メニューの
    /// 項目を選ぼうとカーソルを動かした瞬間に「カーソルがウインドウの外へ出た」と判定され、
    /// メニューを載せているパネルごと消えてしまう(メニューも道連れに閉じる)。
    ///
    /// さらに、メニューのトラッキング中にSwiftUIのビューを消すと、macOS 26では
    /// トラッキング中のメインメニュー再構築(NSMenu setItemArray:)が走ってクラッシュすることが
    /// 分かっている(ViewerView.pendingThumbnailGridDismissAfterMenuのコメント参照)。
    /// つまりここで閉じないことは、見た目だけの問題ではない。
    ///
    /// object: nilなので、このアプリ内のどのメニューが開いても反応する(ViewerView側の
    /// カーソル自動非表示の抑止と同じ形)。メニューが閉じた時点でカーソルが本当にウインドウの
    /// 外にあれば、そこで改めて閉じる。
    private func installMenuTrackingObserversIfNeeded() {
        guard menuTrackingObservers.isEmpty else { return }
        let didBeginTracking = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { _ in
            isMenuTracking = true
        }
        let didEndTracking = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { _ in
            isMenuTracking = false
            // 閉じ直後のこの時点ではまだメニューの後始末が走っている可能性があるため、
            // ビューを消し得る判定は次のループへ回す(macOS 26のクラッシュを避けるための
            // ViewerView側の対処と同じ考え方)。
            DispatchQueue.main.async {
                guard let window = appState.hostWindow else { return }
                dismissAutoRevealedChromeIfCursorLeftWindow(window)
            }
        }
        menuTrackingObservers = [didBeginTracking, didEndTracking]
    }

    private func removeMenuTrackingObservers() {
        for token in menuTrackingObservers {
            NotificationCenter.default.removeObserver(token)
        }
        menuTrackingObservers = []
    }

    private func removeSidePanelHoverMonitor() {
        if let sidePanelHoverMonitor {
            NSEvent.removeMonitor(sidePanelHoverMonitor)
        }
        sidePanelHoverMonitor = nil
    }

    private func removeOutsideWindowMonitor() {
        if let outsideWindowMonitor {
            NSEvent.removeMonitor(outsideWindowMonitor)
        }
        outsideWindowMonitor = nil
    }

    /// 本が切り替わる(開く/閉じる/次の本・前の本へ移動する)たびに、サイドパネル下段
    /// (本の中身ブラウザ)を新しい本向けに作り直す。フォルダ/対応アーカイブ形式/直接渡された
    /// 画像ファイルのいずれでもない場合(PDF/EPUB)、または本を開いていない場合はnil
    /// (SidePanelViewが下段セクション自体を表示しない)。
    private func updateBookContentsBrowserForCurrentBook() {
        guard let book = appState.currentBook else {
            bookContentsBrowser = nil
            return
        }
        let newBrowser = BookContentsBrowserState(book: book)
        newBrowser?.preferences = preferences
        bookContentsBrowser = newBrowser
        // 作り直した直後の一覧に、今表示しているページのハイライト+スクロールを反映させる。
        //
        // ユーザー報告: 画像を直接開いた状態から、その画像が入っているフォルダを開くと、
        // 下段に一覧は出るのにどの行もハイライトされない(ページを1つ送ると初めて付く)。
        //
        // 原因は、これを普段駆動している.onChange(of: appState.currentVisiblePageSortKeys)が
        // **値が変わらないと発火しない**こと。sortKeyはページのフルパスなので、
        //   画像1枚の本  …/BookFolder/001.png
        //   そのフォルダの本の1ページ目  …/BookFolder/001.png
        // のように新旧が完全に一致することがあり、そのとき一度も呼ばれないまま終わる。
        //
        // ここで現在値をそのまま渡して1回呼んでおけば、値が変わる場合は従来どおりonChangeが、
        // 変わらない場合(=古い値と新しい値が同じ=この呼び出しで正しい)はここが受け持つ。
        // revealCurrentPageは冪等なので、両方走っても無害。
        newBrowser?.revealCurrentPage(sortKeys: appState.currentVisiblePageSortKeys)
    }
}


/// サイドパネルの行を右クリックして行う、お気に入り(本・フォルダ)とブックマークの
/// リネーム・削除のダイアログ一式(ユーザー要望)。
///
/// ■ なぜContentViewのbodyに直接書かないのか
/// 5つの`.alert`をbodyへ重ねたところ、Swiftの型チェックが時間内に終わらなくなった
/// (`the compiler is unable to type-check this expression in reasonable time`)。
/// SwiftUIのbodyは修飾子を重ねるたびに型が入れ子になって膨らむため、まとまった一式は
/// こうしてModifierへ切り出し、body側の式を短く保つ。
///
/// ■ なぜSidePanelViewではなくContentView側にあるのか
/// パネルを隠す設定のときパネル自体はホバーで出入りするが、このビューは常にある。
/// また、ダイアログが出ている間だけホバーによる自動非表示を止める必要があり、その判断は
/// ホバーの監視を持つContentViewにしか書けない(ContentView.isSidePanelEditingDialogPresented
/// のコメント参照)。
///
/// 削除の確認は**お気に入りだけ**。ブックマークは確認せずその場で消える(それぞれの編集
/// ウインドウでの流儀に合わせてある。SidePanelView側のコメント参照)。
private struct SidePanelEditingDialogs: ViewModifier {
    @EnvironmentObject private var favoritesStore: FavoritesStore
    @EnvironmentObject private var bookmarkStore: BookmarkStore
    @Binding var renamingFolder: FavoriteFolder?
    @Binding var renamingBook: FavoriteBook?
    @Binding var renamingBookmark: Bookmark?
    /// 3種類のリネームで共用する入力欄(同時には1つしか開かないため)。
    @Binding var renameText: String
    @Binding var folderPendingDeletion: FavoriteFolder?
    @Binding var bookPendingDeletion: FavoriteBook?

    func body(content: Content) -> some View {
        content
        .alert(
            "Rename Folder",
            isPresented: Binding(
                get: { renamingFolder != nil },
                set: { isPresented in if !isPresented { renamingFolder = nil } }
            )
        ) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let folder = renamingFolder {
                    favoritesStore.rename(folder, to: renameText)
                }
                renamingFolder = nil
            }
            Button("Cancel", role: .cancel) { renamingFolder = nil }
        }
        .alert(
            "Rename Favorite",
            isPresented: Binding(
                get: { renamingBook != nil },
                set: { isPresented in if !isPresented { renamingBook = nil } }
            )
        ) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let favorite = renamingBook {
                    favoritesStore.rename(favorite, to: renameText)
                }
                renamingBook = nil
            }
            Button("Cancel", role: .cancel) { renamingBook = nil }
        }
        .alert(
            "Rename Bookmark",
            isPresented: Binding(
                get: { renamingBookmark != nil },
                set: { isPresented in if !isPresented { renamingBookmark = nil } }
            )
        ) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let bookmark = renamingBookmark {
                    bookmarkStore.rename(bookmark, to: renameText)
                }
                renamingBookmark = nil
            }
            Button("Cancel", role: .cancel) { renamingBookmark = nil }
        }
        // 削除の確認。お気に入りは元に戻せないため必ず1枚挟む(「お気に入りの編集」ウインドウと
        // 同じ文面・同じ選択肢)。ブックマークはここを通らず、その場で消える。
        .alert(
            "Delete Folder?",
            isPresented: Binding(
                get: { folderPendingDeletion != nil },
                set: { isPresented in if !isPresented { folderPendingDeletion = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { folderPendingDeletion = nil }
            Button("Delete", role: .destructive) {
                if let folder = folderPendingDeletion {
                    favoritesStore.delete(folder)
                }
                folderPendingDeletion = nil
            }
        } message: {
            Text("This also deletes any subfolders and favorites inside it.")
        }
        .alert(
            "Remove from Favorites?",
            isPresented: Binding(
                get: { bookPendingDeletion != nil },
                set: { isPresented in if !isPresented { bookPendingDeletion = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { bookPendingDeletion = nil }
            Button("Remove", role: .destructive) {
                if let favorite = bookPendingDeletion {
                    favoritesStore.delete(favorite)
                }
                bookPendingDeletion = nil
            }
        }
    }
}

private extension View {
    func sidePanelEditingDialogs(
        renamingFolder: Binding<FavoriteFolder?>,
        renamingBook: Binding<FavoriteBook?>,
        renamingBookmark: Binding<Bookmark?>,
        renameText: Binding<String>,
        folderPendingDeletion: Binding<FavoriteFolder?>,
        bookPendingDeletion: Binding<FavoriteBook?>
    ) -> some View {
        modifier(SidePanelEditingDialogs(
            renamingFolder: renamingFolder,
            renamingBook: renamingBook,
            renamingBookmark: renamingBookmark,
            renameText: renameText,
            folderPendingDeletion: folderPendingDeletion,
            bookPendingDeletion: bookPendingDeletion
        ))
    }
}
