import SwiftUI
import SwiftData
import AppKit
import Combine

struct ContentView: View {
    /// このウインドウ(タブ)専用のAppState。ウインドウごとに独立して本を開けるように、
    /// アプリ全体で1つの共有インスタンスではなく、ContentViewのインスタンスごとに
    /// (つまりウインドウ/タブごとに)新しく作る。これにより、新しいウインドウ/タブは
    /// 必ず「何も開いていない」状態(WelcomeView)から始まる。
    @StateObject private var appState = AppState()
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var recentFiles: RecentFilesStore
    @EnvironmentObject private var folderAccess: FolderAccessStore
    @EnvironmentObject private var favoritesStore: FavoritesStore
    @EnvironmentObject private var bookmarkStore: BookmarkStore
    @EnvironmentObject private var layoutStore: LayoutStore
    @EnvironmentObject private var launchCoordinator: LaunchCoordinator
    @Environment(\.modelContext) private var modelContext

    /// 「新しいウインドウで開く」「新しいタブで開く」、またはFinderからの「開く」で、
    /// このウインドウで最初から開いておきたいファイル/フォルダ。通常の(何も指定しない)
    /// ウインドウではnil。
    var initialURL: URL?

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
    /// サイドパネル左端のホバー検知用ローカルモニタ。ViewerView.makeScrollMonitorとは
    /// 完全に独立した、X座標の帯だけを見る単純なもの。
    @State private var sidePanelHoverMonitor: Any?
    /// サイドパネルが出現する、ウインドウ左端からの反応領域の幅。
    private static let sidePanelRevealBandWidth: CGFloat = 20
    /// 「サイドパネルを隠す」ON時、表示中のパネルが閉じるまでの、パネル右端(sidePanelWidth)
    /// から見た余裕幅。ゼロだと、パネル右端の幅調整ハンドル(widthDragHitArea)をつかもうと
    /// カーソルを境界ぎりぎりへ動かしただけで隠れてしまう(ユーザー報告)。
    private static let sidePanelHideMargin: CGFloat = 16
    /// サイドパネルの幅。ユーザーが右端のドラッグハンドルで調整できる
    /// (SidePanelView.widthDragHitArea参照)。常時表示・ホバー表示のどちらでも同じ値を
    /// 共有する。
    @State private var sidePanelWidth: CGFloat = SidePanelView.defaultWidth

    init(initialURL: URL? = nil) {
        self.initialURL = initialURL
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // サイドパネルが常時表示(既定、hideSidePanel == false)のときは、ツールバー/
            // プログレスバーがViewerView.mainZStack内のVStackに組み込まれて画像表示エリアを
            // 押しのけるのと同じ考え方で、HStackの実レイアウトとして組み込む(ここでの
            // GeometryReaderベースのpageAreaサイジングが自動的に縮んだ幅を拾ってくれるため、
            // ViewerView側の変更は不要)。ZStackのオーバーレイのままにしてしまうと、常時表示中
            // ずっと画像の左端がパネルの下に隠れ続けてしまう(ユーザー報告の不具合)。
            HStack(spacing: 0) {
                if preferences.sidePanelFeatureEnabled && !appState.hideSidePanel {
                    sidePanelView(dismissesOnAction: false)
                }
                Group {
                    if let book = appState.currentBook {
                        // .id(book.id) を付けることで、次の本/前の本に切り替えたときに
                        // ViewerViewModel(StateObject)が確実に作り直され、ページ位置などが
                        // 新しい本の状態にリセットされるようにしている。
                        ViewerView(book: book, modelContext: modelContext, preferences: preferences, layoutStore: layoutStore)
                            .id(book.id)
                    } else {
                        WelcomeView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // hideSidePanel == trueのときの、ホバーによる一時的な表示。ツールバー/プログレス
            // バーの自動隠し(ViewerView.mainZStackのZStackオーバーレイ分岐)と同じ理由で、
            // こちらはあえてHStackに組み込まず画像の上に浮かべる(表示・非表示のたびに
            // 画像のサイズが変わってちらつくのを避けるため)。preferences.sidePanelFeatureEnabled
            // がOFF(環境設定「一般」タブ)のときは、サイドパネル機能自体を丸ごと無効化する。
            if preferences.sidePanelFeatureEnabled && appState.hideSidePanel && appState.isSidePanelRevealed {
                sidePanelView(dismissesOnAction: true)
                    .transition(.move(edge: .leading))
            }
        }
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
                hideToolbar: appState.hideToolbar,
                hideProgressBar: appState.hideProgressBar,
                hideSidePanel: appState.hideSidePanel,
                isSlideshowActive: appState.isSlideshowActive,
                isSpreadMode: appState.isSpreadMode,
                isRightToLeft: appState.isRightToLeft,
                scalingMode: appState.currentScalingMode,
                isReadingDirectionLocked: appState.isReadingDirectionLocked,
                isDisplayModeLocked: appState.isDisplayModeLocked,
                isPageShiftLocked: appState.isPageShiftLocked,
                // isCurrentBookFavorited/isCurrentPageBookmarkedは、AppState自身の@Publishedでは
                // なくここで都度計算する。favoritesStoreの変更(reload())はAppStateの
                // objectWillChangeを発火させないため、ContentViewが自分自身のfavoritesStore
                // (EnvironmentObject。この構造体自体がfavoritesStoreの変更のたびに作り直される
                // ことで、値型のFocusedValueとしてメニューバー側へ正しく伝わる)から直接算出する。
                isCurrentBookFavorited: appState.currentBook.map { favoritesStore.isFavorited(bookID: $0.id) } ?? false,
                isCurrentPageBookmarked: appState.currentBookmarks.contains { $0.pageIndex == appState.currentPageIndex },
                hasAuthoritativeSourceLayout: appState.hasAuthoritativeSourceLayout,
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
        .navigationTitle(
            appState.currentBook.map {
                FormatBadgeView.plainTextTitle(baseName: $0.title, bookID: $0.id)
            } ?? "qooViewer"
        )
        // このウインドウ自身への参照をappStateに持たせておく。Finderから別の本を開こうとした
        // ときに「新しいタブで開く」設定の場合、どのウインドウへタブを追加すべきかを
        // NSApp.keyWindow(その時点でたまたまキーウインドウだったもの、必ずしも正しいとは
        // 限らない)に頼らず、本を開いている当のAppStateが持つウインドウへ確実に追加できる
        // ようにするため(詳細はAppState.hostWindowのコメント参照)。
        .onChange(of: appState.currentBook?.id) { _, _ in
            updateLastActiveBookRecordIfKeyWindow()
            updateBookContentsBrowserForCurrentBook()
            // サイドパネル上段(フォルダブラウザ)を、新しく開いた本のフォルダへ再アンカーする。
            // サイドパネルが常時表示(既定、hideSidePanel == false)のときは、ホバーでの
            // 「表示される」タイミング自体が発生しないため、ここで本の切り替わりを直接検知
            // する必要がある(最近使ったファイル一覧などから本を開いた場合、ホバーで
            // パネルを開き直さない限りボリューム一覧のままになってしまっていた不具合の修正)。
            // hideSidePanel == trueでホバー表示中の場合も、installSidePanelHoverMonitorIfNeeded
            // 側の再アンカーと重複するが冪等なので問題ない。
            sidePanelBrowser.handlePanelRevealed(currentBook: appState.currentBook)
        }
        // サイドパネル下段(本の中身ブラウザ)を、今実際に表示されているページへ追従させる
        // (ユーザー要望: ページ送りのたびにハイライト・スクロールをリアルタイムに追従させ、
        // フォルダ/ネストした書庫の境界をまたいだら表示中のフォルダ/書庫も切り替える)。
        // 本の切替直後は新しいViewerViewのonAppearがcurrentVisiblePageSortKeysを更新する
        // ことでここが発火するため、updateBookContentsBrowserForCurrentBook側で明示的に
        // 呼び直す必要はない。
        .onChange(of: appState.currentVisiblePageSortKeys) { _, newValue in
            bookContentsBrowser?.revealCurrentPage(sortKeys: newValue)
        }
        // サイドパネルの幅をユーザーがドラッグで調整するたびに、次回起動時にも再現できるよう
        // preferencesへ書き戻す(hideToolbar等と同じ「AppStateへの書き戻し」パターンだが、
        // sidePanelWidthはAppStateではなくContentView自身の@Stateのため、ここで直接行う)。
        .onChange(of: sidePanelWidth) { _, newValue in
            preferences.sidePanelWidth = Double(newValue)
        }
        .onAppear {
            installSidePanelHoverMonitorIfNeeded()
        }
        .onDisappear {
            removeSidePanelHoverMonitor()
        }
        .background(WindowAccessor { window in
            guard appState.hostWindow !== window else { return }
            appState.hostWindow = window
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
            // 切り替える。"book"ウインドウグループ(新しいウインドウ/タブで開く。initialURLが
            // 入る)の方や、タブバーの「+」で追加された新しいタブ(下のonAppear参照)には
            // 適用したくないため、主ウインドウ自身(1枚目、またはすでにprimaryAppStateとして
            // 登録済みの自分自身)の場合にだけ適用する。
            if initialURL == nil,
               launchCoordinator.primaryAppState == nil || launchCoordinator.primaryAppState === appState,
               let window {
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
            guard launchCoordinator.primaryAppState == nil || launchCoordinator.primaryAppState === appState || initialURL != nil else {
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
            if launchCoordinator.primaryAppState == nil {
                launchCoordinator.primaryAppState = appState
            }
            // 「すでに開いている本を新しいウインドウ/タブで開こうとしたときに、既存の
            // ウインドウ/タブをアクティブにする」機能のために、このウインドウ/タブのAppStateを
            // 開いている一覧へ登録する(QooViewerApp.openURLInNewWindow参照)。
            launchCoordinator.registerOpenAppState(appState)
            if let initialURL {
                appState.open(url: initialURL)
            } else {
                performLaunchActionsIfNeeded()
            }
        }
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
            Button("Remove from Favorites", role: .destructive) {
                if let favorite = appState.missingFavorite {
                    favoritesStore.delete(favorite)
                }
                appState.missingFavorite = nil
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

        if preferences.launchOpensLastBook, appState.currentBook == nil,
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
    /// windowはNotificationCenterへweakに保持されるだけなので、ウインドウが閉じられれば
    /// 監視も自然に無意味になる(主ウインドウは通常アプリの生存中1つだけのため、
    /// 明示的なremoveObserverは行っていない)。
    private func observeMainWindowFrameChanges(_ window: NSWindow) {
        let save: (Notification) -> Void = { notification in
            guard let window = notification.object as? NSWindow else { return }
            UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.mainWindowFrameDefaultsKey)
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main, using: save
        )
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main, using: save
        )
    }

    /// このウインドウがキーウインドウになるたびに、今表示している本(なければ「本を
    /// 開いていない状態」)をLastActiveBookStoreに記録する。windowはNotificationCenterへ
    /// weakに保持されるだけなので、ウインドウが閉じられれば監視も自然に無意味になる。
    private func observeWindowBecameKey(_ window: NSWindow) {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { _ in
            updateLastActiveBookRecordIfKeyWindow()
        }
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
        guard preferences.launchOpensLastBook else { return }
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
            width: $sidePanelWidth,
            bookPages: appState.currentBookPages,
            onOpen: { url in
                if dismissesOnAction { appState.isSidePanelRevealed = false }
                appState.open(url: url)
            },
            onJumpToPage: { index in
                appState.jumpToPageIndex?(index)
                if dismissesOnAction { appState.isSidePanelRevealed = false }
            }
        )
    }

    /// サイドパネルのホバー表示/非表示を検知する、ウインドウ内`.mouseMoved`のローカルモニタ。
    /// ViewerView.makeScrollMonitorとは完全に独立しており、カーソルのX座標だけを見て判定する。
    ///
    /// 表示メニューの「サイドパネルを隠す」がOFF(既定)のときは、サイドパネルは常時表示
    /// されているため、このモニタは何もしない(hideToolbar/hideProgressBarのY座標版の
    /// 自動隠しがフルスクリーン中またはON時にしか意味を持たないのと同じ考え方)。ONのときだけ、
    /// 表示前はウインドウ左端の狭い帯(sidePanelRevealBandWidth)に入ったら表示し、表示後は
    /// パネル自体の表示幅(sidePanelWidth。ユーザーがドラッグで調整できるため固定値ではない。
    /// 表示前の帯よりずっと広い)より右へ出たら閉じる。もし表示後も同じ狭い帯を非表示条件に
    /// 使ってしまうと、パネル自体がその帯よりずっと広く描画されているため、パネルの上に
    /// カーソルがあるのに閉じてしまう(表示直後にちらつく)不具合になる。ユーザー要望により、
    /// クリックでは閉じない(ページ表示エリアをクリックしただけで本の閲覧を妨げないように
    /// するため)。
    ///
    /// ツールバー/プログレスバーの自動表示(Y座標の帯、ViewerView側)とは判定ロジック・
    /// 描画レイヤーともに独立しているが、ウインドウの左上・左下の角では両方の帯が同時に
    /// 成立し得る。何も対策しないと、表示中のツールバーの上をカーソルが左へ移動して
    /// 左端に近づいただけでサイドパネルまで表示されてしまう(ユーザー報告)。
    /// appState.isChromeAutoRevealed(ツールバー/プログレスバーが今まさに表示されているか)を
    /// 見て、それらが既にカーソルの主導権を握っている間は新たに表示しない。
    private func installSidePanelHoverMonitorIfNeeded() {
        guard sidePanelHoverMonitor == nil else { return }
        sidePanelHoverMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { event in
            guard let window = appState.hostWindow, event.window === window else { return event }
            guard preferences.sidePanelFeatureEnabled, appState.hideSidePanel else { return event }
            if appState.isSidePanelRevealed {
                // + sidePanelHideMargin: パネル右端の幅調整ハンドル(widthDragHitArea)自体が
                // 境界(sidePanelWidth)ぎりぎりの位置にあるため、余裕を持たせないとハンドルを
                // つかもうとしただけでここに引っかかり隠れてしまう(ユーザー報告)。
                if event.locationInWindow.x > sidePanelWidth + Self.sidePanelHideMargin {
                    appState.isSidePanelRevealed = false
                }
            } else if event.locationInWindow.x <= Self.sidePanelRevealBandWidth, !appState.isChromeAutoRevealed {
                appState.isSidePanelRevealed = true
                sidePanelBrowser.handlePanelRevealed(currentBook: appState.currentBook)
            }
            return event
        }
    }

    private func removeSidePanelHoverMonitor() {
        if let sidePanelHoverMonitor {
            NSEvent.removeMonitor(sidePanelHoverMonitor)
        }
        sidePanelHoverMonitor = nil
    }

    /// 本が切り替わる(開く/閉じる/次の本・前の本へ移動する)たびに、サイドパネル下段
    /// (本の中身ブラウザ)を新しい本向けに作り直す。フォルダ/対応アーカイブ形式以外
    /// (PDF/EPUB)、または本を開いていない場合はnil(SidePanelViewが下段セクション自体を
    /// 表示しない)。
    private func updateBookContentsBrowserForCurrentBook() {
        guard let book = appState.currentBook else {
            bookContentsBrowser = nil
            return
        }
        let newBrowser = BookContentsBrowserState(book: book)
        newBrowser?.preferences = preferences
        bookContentsBrowser = newBrowser
    }
}
