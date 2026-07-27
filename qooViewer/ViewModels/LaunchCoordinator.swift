import Foundation
import Combine

/// アプリ全体で一度だけ行いたい初期化と、Finderからの「開く」を受け取る最初のウインドウの
/// 参照を管理する。
///
/// qooViewerは「新しいウインドウで開く」「新しいタブで開く」により複数ウインドウ/タブを
/// 開けるが、次の2つはアプリを起動したときに最初に表示されるウインドウでだけ行いたい
/// (あとから追加したウインドウでは行いたくない)。
/// (1) 「前回開いていた本を自動的に開く」「起動時にフルスクリーンにする」設定の反映
/// (2) Finderで「このアプリケーションで開く」やダブルクリックをしたときに、そのURLを
///     どのウインドウで開くか
/// ContentViewのインスタンスごとに@Stateで管理すると、ウインドウ/タブごとに別々に
/// 判定されてしまう(たとえば新しいウインドウを開くたびに「前回の本」がまた自動的に
/// 開いてしまう)ため、アプリ全体で共有する1つのオブジェクトとして持つ。
@MainActor
final class LaunchCoordinator: ObservableObject {
    /// 上記(1)の初期化処理を既に行ったかどうか。
    @Published var didPerformInitialLaunchActions = false
    /// アプリ起動時、最初に作られたウインドウのAppState。2つ目以降の(新しいウインドウ/タブで
    /// 開いた)ウインドウでは上書きしない。
    weak var primaryAppState: AppState?

    /// 現在開いているすべてのウインドウ/タブのAppStateへの弱参照一覧。
    /// 「すでに開いている本を新しいウインドウ/タブで開こうとしたときに、それを開いている
    /// 既存のウインドウ/タブをアクティブにする」機能のために保持する
    /// (QooViewerApp.openURLInNewWindow参照)。ウインドウが閉じられればAppStateも解放される
    /// べきなので、配列の要素はweakで保持し、参照が外れたものは都度取り除く
    /// (明示的なunregisterは行わない)。
    private var openAppStates: [WeakAppStateBox] = []

    /// このウインドウ/タブのAppStateを、開いているウインドウの一覧に登録する。
    /// ContentView.onAppearで、このウインドウ/タブが正当なものと確認できた時点
    /// (isConfirmedLegitimateWindow参照)で呼ぶ。
    func registerOpenAppState(_ appState: AppState) {
        openAppStates.removeAll { $0.appState == nil }
        guard !openAppStates.contains(where: { $0.appState === appState }) else { return }
        openAppStates.append(WeakAppStateBox(appState: appState))
    }

    /// 指定したURLの本をすでに開いているウインドウ/タブがあれば、そのAppStateを返す。
    /// 「同じ本」かどうかは、プロジェクト内の他の同種の判定(RecentFilesStore・
    /// LastActiveBookStoreなど)に合わせて、URLを正規化などはせずURL.pathの文字列一致で行う。
    func openAppState(forBookAt url: URL) -> AppState? {
        openAppStates.removeAll { $0.appState == nil }
        return openAppStates.first { $0.appState?.currentBook?.sourceURL.path == url.path }?.appState
    }
}

/// 配列の要素自体をweakにはできないため、AppStateへの弱参照を1つ持つだけの箱として使う。
private struct WeakAppStateBox {
    weak var appState: AppState?
}
