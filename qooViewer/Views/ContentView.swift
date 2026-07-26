import SwiftUI
import SwiftData
import AppKit

struct ContentView: View {
    /// このウインドウ(タブ)専用のAppState。ウインドウごとに独立して本を開けるように、
    /// アプリ全体で1つの共有インスタンスではなく、ContentViewのインスタンスごとに
    /// (つまりウインドウ/タブごとに)新しく作る。これにより、新しいウインドウ/タブは
    /// 必ず「何も開いていない」状態(WelcomeView)から始まる。
    @StateObject private var appState = AppState()
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var recentFiles: RecentFilesStore
    @EnvironmentObject private var folderAccess: FolderAccessStore
    @EnvironmentObject private var launchCoordinator: LaunchCoordinator
    @Environment(\.modelContext) private var modelContext

    /// 「新しいウインドウで開く」「新しいタブで開く」、またはFinderからの「開く」で、
    /// このウインドウで最初から開いておきたいファイル/フォルダ。通常の(何も指定しない)
    /// ウインドウではnil。
    var initialURL: URL?

    init(initialURL: URL? = nil) {
        self.initialURL = initialURL
    }

    var body: some View {
        Group {
            if let book = appState.currentBook {
                // .id(book.id) を付けることで、次の本/前の本に切り替えたときに
                // ViewerViewModel(StateObject)が確実に作り直され、ページ位置などが
                // 新しい本の状態にリセットされるようにしている。
                ViewerView(book: book, modelContext: modelContext, preferences: preferences)
                    .id(book.id)
            } else {
                WelcomeView()
            }
        }
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
                isSlideshowActive: appState.isSlideshowActive,
                isSpreadMode: appState.isSpreadMode,
                isRightToLeft: appState.isRightToLeft,
                scalingMode: appState.currentScalingMode
            )
        )
        .frame(minWidth: 900, minHeight: 640)
        // ウインドウ/タブのタイトルバーおよびタブバーに表示される文字列。本を開いている間は
        // その本のタイトル(ファイル/フォルダ名)を表示し、どのタブが何の本を開いているか
        // 一目で分かるようにする。何も開いていない(ウェルカム画面)ときはアプリ名を表示する。
        .navigationTitle(appState.currentBook?.title ?? "qooViewer")
        // このウインドウ自身への参照をappStateに持たせておく。Finderから別の本を開こうとした
        // ときに「新しいタブで開く」設定の場合、どのウインドウへタブを追加すべきかを
        // NSApp.keyWindow(その時点でたまたまキーウインドウだったもの、必ずしも正しいとは
        // 限らない)に頼らず、本を開いている当のAppStateが持つウインドウへ確実に追加できる
        // ようにするため(詳細はAppState.hostWindowのコメント参照)。
        .background(WindowAccessor { window in
            guard appState.hostWindow !== window else { return }
            appState.hostWindow = window
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
            appState.preferences = preferences
            appState.recentFiles = recentFiles
            appState.folderAccess = folderAccess
            // 「ツールバーを隠す」「プログレスバーを隠す」は、前回終了時(またはこのセッション中に
            // 他のウインドウで変更された時点)の値をpreferencesから引き継ぐ。これにより、
            // 新しいウインドウ/タブや次回起動時にも同じ表示状態で始まる。
            appState.hideToolbar = preferences.hideToolbar
            appState.hideProgressBar = preferences.hideProgressBar
            if launchCoordinator.primaryAppState == nil {
                launchCoordinator.primaryAppState = appState
            }
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
    }

    /// アプリ起動時に一度だけ(最初のウインドウでだけ)、「前回開いていた本を自動的に開く」
    /// 「フルスクリーンで起動する」設定を反映する。「新しいウインドウで開く」などで
    /// あとから追加したウインドウでは行わない(LaunchCoordinator参照)。
    private func performLaunchActionsIfNeeded() {
        guard !launchCoordinator.didPerformInitialLaunchActions else { return }
        launchCoordinator.didPerformInitialLaunchActions = true

        if preferences.launchOpensLastBook, appState.currentBook == nil {
            var descriptor = FetchDescriptor<BookReadingState>(
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
            descriptor.fetchLimit = 1
            if let lastState = try? modelContext.fetch(descriptor).first {
                appState.open(url: URL(fileURLWithPath: lastState.bookID))
            }
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
                    appState.preferences = preferences
                    appState.recentFiles = recentFiles
                    appState.folderAccess = folderAccess
                    appState.hideToolbar = preferences.hideToolbar
                    appState.hideProgressBar = preferences.hideProgressBar
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
}
