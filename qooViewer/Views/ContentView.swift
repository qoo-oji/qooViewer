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
        .onAppear {
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
}
