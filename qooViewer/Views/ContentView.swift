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
            // すでに主ウインドウ(primaryAppState)が存在するのに、URLの指定なしで
            // 「main」ウインドウグループの新しいインスタンス(=このContentView)が
            // 生成された場合、それはこのアプリが意図して作ったものではない
            // (詳細はonAppear側のコメント参照)。WindowAccessorはonAppearより先に
            // (ウインドウ生成後すぐに)呼ばれるため、ここで即座に隠すことで、
            // ユーザーの目にウェルカム画面が一瞬映ってしまう時間をできるだけ短くする。
            //
            // 「primaryAppState === appState」も許可条件に含めているのは、WindowAccessorと
            // onAppearの実行順序がSwiftUI側で保証されていないため。もしonAppear(自分自身を
            // primaryAppStateとして登録する処理を含む)が先に走ったあとにこのWindowAccessorの
            // コールバックが呼ばれると、「primaryAppStateはすでにこの自分自身」という状態に
            // なる。これを「他の余分なウインドウ」と誤判定しないよう、自分自身が
            // primaryAppStateである場合は正規のウインドウとして扱う(これが無いと、アプリ起動時
            // の最初の1枚目のウインドウまで誤って閉じてしまい、「すべてのウインドウを閉じたら
            // 終了する」設定がONの場合にアプリが起動直後に終了してしまう不具合が起きる)。
            guard launchCoordinator.primaryAppState == nil
                || launchCoordinator.primaryAppState === appState
                || initialURL != nil
            else {
                window?.orderOut(nil)
                window?.close()
                return
            }
        })
        .onAppear {
            // 上のWindowAccessor側の早期チェックと同じ条件(理由も同上)。WindowAccessorが
            // 間に合わないごくまれなケースの保険として、ここでも同じ判定をもう一度行う(詳細は
            // WindowAccessor側のコメント参照。調査の結果、Finderの登録ファイルをDockアイコンへ
            // ドラッグ&ドロップして開いたときに、AppKit/SwiftUI側がapplication(_:open:)の
            // 呼び出しとは別に、原因不明のままこの「空のmainウインドウ」をもう1つ自動的に
            // 開いてしまうことがあると判明した。applicationShouldOpenUntitledFile /
            // applicationShouldHandleReopenをどちらもfalseにしても防げなかった)。
            guard launchCoordinator.primaryAppState == nil
                || launchCoordinator.primaryAppState === appState
                || initialURL != nil
            else {
                closeSpuriousUntitledWindow()
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

    /// 主ウインドウがすでに存在するのに現れてしまった、意図しない空の「main」ウインドウ
    /// (上のonAppear参照)を自動的に閉じる。appState.hostWindowは同じタイミングで動く
    /// .background(WindowAccessor{...})経由で設定されるため、設定が間に合っていない
    /// ごく短い間だけ待ってから閉じる。
    private func closeSpuriousUntitledWindow() {
        Task { @MainActor in
            for _ in 0..<20 {
                if let window = appState.hostWindow {
                    window.close()
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }
}
