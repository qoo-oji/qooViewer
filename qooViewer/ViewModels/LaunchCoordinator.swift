import Foundation
import Combine
import AppKit

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

    /// 「ブックマーク・レイアウトの編集」ウインドウ(BookmarkEditorView)を開く直前に、
    /// どちらの呼び出し元から開かれたかをセットしておく値(設計コンセプト4.5節)。
    /// Windowシーン自体はid一意の単一インスタンス(WindowGroupと違いfor:による値の
    /// パラメータ化ができない)のため、値渡しの代わりにこの共有オブジェクト経由で伝える。
    /// BookmarkEditorView側は.onAppear(初回表示)と.onChange(既に開いている状態で
    /// もう一方の呼び出し元から改めて開かれた場合)の両方でこの値を読み、初期フィルタへ反映する。
    @Published var pendingEditorInitialFocus: EditorInitialFocus?

    /// 5節の一括リネームウインドウ(Window(id: "bulkRenameBookmarks"))を開く直前に、
    /// 対象のbookIDをセットしておく値。上のpendingEditorInitialFocusと同じ理由・同じ仕組み
    /// (Windowシーンはfor:による値のパラメータ化ができない単一インスタンスのため)。
    @Published var pendingBulkRenameBookID: String?

    /// アプリ起動時、最初に作られたウインドウのAppState。2つ目以降の(新しいウインドウ/タブで
    /// 開いた)ウインドウでは上書きしない。
    ///
    /// バグ修正(ユーザー報告): SwiftUIのWindowGroup(id:)はウインドウを閉じてもその中身
    /// (@StateObjectのappState)をすぐには解放しないことが実機で確認されており、この
    /// `weak var`が「ウインドウを閉じれば自然にnilへ戻る」という前提には頼れない。そのため、
    /// 「primaryAppStateが指すウインドウが今も実際に開いているか」は、appState自体のweak参照
    /// (いつnilになるか予測できない)ではなく、下のprimaryWindowIsOpenで明示的に管理する。
    weak var primaryAppState: AppState?

    /// primaryAppStateが指すウインドウが、今実際に開いているかどうか。ContentView.onAppearが
    /// 主ウインドウとして確定した瞬間にtrueへ、そのウインドウが閉じる瞬間
    /// (ContentView.observeWindowBecameKey)にfalseへ、それぞれ同期的に更新する。
    /// primaryAppState.hostWindowの有無で代用しようとしたことがあったが、hostWindowは
    /// WindowAccessor経由で非同期に設定されるため、ほぼ同時に複数の新しいウインドウが現れた
    /// 場合に「どちらもまだhostWindowが付いていない」タイミングが生じ、両方とも主ウインドウを
    /// 名乗ってしまう(=どちらも不正な余分ウインドウと判定されず、本を開いた方と別に空の
    /// ウインドウが残り続ける)不具合があった。この値はonAppear内で同期的に立てる/倒すため、
    /// そのような競合が起きない。
    var primaryWindowIsOpen = false

    /// 主ウインドウが1度でも閉じてゼロになったことがあるかどうか(このプロセスの生存中、
    /// 一度trueになったら以後ずっとtrueのまま)。application(_:open:)が、今のprimaryAppStateを
    /// どれだけ信用してよいかの判定に使う(詳細はQooViewerApp.application(_:open:)のコメント
    /// 参照)。falseなら、今のprimaryAppStateはこのプロセスの起動時に最初に作られたウインドウ
    /// そのものであり安全に信頼できる。trueの場合、今のprimaryAppStateはウインドウを一度
    /// すべて閉じた後、AppKit/SwiftUIが再アクティブ化のタイミングで自動的に開いたウインドウの
    /// 可能性があり、実機の調査で「閉じたはずの古いNSWindowをそのまま再利用してしまい、
    /// 中身が正しく描画されない(何も表示されない壊れたウインドウになる)」ケースが確認された
    /// ため、既に本を表示できている(=正しく描画できている証拠がある)場合を除いて信用しない。
    var primaryWindowHasEverClosed = false

    /// 現在開いているすべてのウインドウ/タブのAppStateへの弱参照一覧。
    /// 「すでに開いている本を新しいウインドウ/タブで開こうとしたときに、それを開いている
    /// 既存のウインドウ/タブをアクティブにする」機能のために保持する
    /// (QooViewerApp.openURLInNewWindow参照)。ウインドウが閉じられればAppStateも解放される
    /// べきなので、配列の要素はweakで保持し、参照が外れたものは都度取り除く
    /// (明示的なunregisterは行わない)。
    private var openAppStates: [WeakAppStateBox] = []

    /// 本を表示しているウインドウ(ContentView)のうち、最後にキーウインドウになったもののAppState。
    /// 「お気に入りの整理」ウインドウの「現在の本を追加」ボタン、および「ブックマークの編集」
    /// ウインドウ(どちらも特定の本のウインドウには属さない独立ウインドウ)が、
    /// 「今読んでいる本」を特定するために参照する。
    ///
    /// @Publishedとweakは同時に付けられない(Swiftの制約)ため、このプロパティ自体は
    /// 素のweak varにしておき、更新はsetActiveBookAppState(_:)経由でのみ行う。その中で
    /// objectWillChange.send()を手動で発行することで、これを@ObservedObject/@EnvironmentObjectで
    /// 観測しているSwiftUI側にも変化が伝わるようにしている。
    ///
    /// 「お気に入りの整理」「ブックマークの編集」自身がキーウインドウになってもこの値は
    /// 変わらない(本を表示しているウインドウ(ContentView)がキーウインドウになったときだけ
    /// ViewerView.setUpWindowObserversから更新されるため)。そのため、「ブックマークの編集」を
    /// 開いた後にそのウインドウを操作していても、直前まで読んでいた本の内容を表示し続けられる。
    private(set) weak var activeBookAppState: AppState?

    /// activeBookAppStateを更新する。同じインスタンスなら何もしない(不要なobjectWillChange
    /// 発行を避ける)。
    func setActiveBookAppState(_ appState: AppState) {
        guard activeBookAppState !== appState else { return }
        objectWillChange.send()
        activeBookAppState = appState
    }

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

    /// 指定したbookID(MangaBook.id、フォルダ/アーカイブファイルのパスと同じ文字列)の本を
    /// すでに開いているウインドウ/タブがあれば、そのAppStateを返す。「ブックマークの編集」
    /// ウインドウ(BookmarkStore)が、左ペインで選択中の本が今開いているかどうか
    /// (開いていればジャンプ・「Add This Page」ボタンを有効化できる)を判定するために使う。
    /// openAppState(forBookAt:)と役割は同じだが、こちらはURLではなくbookID文字列を直接比較する
    /// (MangaBook.id自体がパス文字列そのものであるため、URLを介さず直接比較できる)。
    func openAppState(forBookID bookID: String) -> AppState? {
        openAppStates.removeAll { $0.appState == nil }
        return openAppStates.first { $0.appState?.currentBook?.id == bookID }?.appState
    }

    /// 現在登録されているすべてのContentViewウインドウ/タブのAppState一覧(本を表示中か
    /// ウェルカム画面かを問わない。nilになった弱参照は都度取り除く)。
    /// 「ブックマークの編集」ウインドウのダブルクリックで、対象の本をまだどこにも開いていない
    /// 場合に「今一番手前にあるコンテンツウインドウ」を探すために使う
    /// (frontmostContentAppState参照)。
    var allOpenAppStates: [AppState] {
        openAppStates.removeAll { $0.appState == nil }
        return openAppStates.compactMap(\.appState)
    }

    /// 登録済みのContentViewウインドウ(本を表示中か、ウェルカム画面かを問わない)のうち、
    /// 現在いちばん手前にあるものを返す。「ブックマークの編集」ウインドウの
    /// ダブルクリックで本を開く/置き換える先を決めるために使う
    /// (BookmarkListView参照)。「ブックマークの編集」「お気に入りの整理」「環境設定」など、
    /// ContentView以外のウインドウはAppStateを持たないため、ここで手前にあると判定されることは
    /// ない(ダブルクリックした時点ではそれらのうちのどれかが最前面のはずだが、除外される)。
    /// コンテンツウインドウが1つも開いていない場合はnilを返す。
    func frontmostContentAppState() -> AppState? {
        let hostWindows = allOpenAppStates.compactMap { appState -> (AppState, NSWindow)? in
            guard let window = appState.hostWindow else { return nil }
            return (appState, window)
        }
        guard !hostWindows.isEmpty else { return nil }
        for window in NSApp.orderedWindows {
            if let match = hostWindows.first(where: { $0.1 === window }) {
                return match.0
            }
        }
        // NSApp.orderedWindowsに見つからない場合(通常は起こらないはずだが、念のためのフォール
        // バック)は、登録順の先頭を返す。
        return hostWindows.first?.0
    }
}

/// 配列の要素自体をweakにはできないため、AppStateへの弱参照を1つ持つだけの箱として使う。
private struct WeakAppStateBox {
    weak var appState: AppState?
}

/// 「ブックマーク・レイアウトの編集」ウインドウ(設計コンセプト4節)を、どちらの目的で
/// 開いたか。4.5節の通り、呼び出し元によって初期フィルタが異なる。
enum EditorInitialFocus: Equatable {
    /// 「ブックマークの編集」として開いた場合: 左ペイン=「ブックマークがある本のみ」、
    /// 右ペイン=「ブックマークがあるページのみ」。
    case bookmarks
    /// 「レイアウトの編集」として開いた場合: 左ペイン=「レイアウト情報がある本のみ」、
    /// 右ペイン=「すべて」。
    case layout
}
