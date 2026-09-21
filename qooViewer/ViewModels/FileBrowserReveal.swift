import AppKit
import SwiftUI

/// 「ファイルブラウザで開く」(改善要望7 段階 8、2026-09-14)。既存の「Finder で開く」の隣に置いた項目が、
/// すべてここ(`AppState.revealInFileBrowser`)を通る。
///
/// ■ どこに出すか(決定事項 Q6)
/// - **本を開いていないウインドウ**(本棚のコレクションの中から): そのウインドウのウェルカム画面を
///   ファイルブラウザに切り替える。
/// - **本を開いているウインドウ**(ビューア・サイドパネル・ファイルメニュー): 環境設定「ファイルブラウザ」の
///   行き先(新規タブ / 新規ノーマルウインドウ / 新規シークレットウインドウ)に開く。読んでいる本の画面は壊さない。
///
/// ■ 何を見せるか
/// 「Finder で開く」(FinderReveal)と同じ規則: フォルダはその中を、ファイルは入っているフォルダでその項目を選ぶ。
/// フォルダかどうかは呼び出し側が分かっていれば渡してもらい、分からなければ `FileIO` の上で調べる
/// (履歴の表示用 URL のようにスコープの付かない URL では調べられない ―― FinderReveal.reveal のコメント)。
///
/// ■ 読む許可
/// ファイルブラウザが一覧を読めるのは、FolderAccessStore に許可のあるフォルダだけ(本を 1 冊開いた許可では
/// 隣のファイルは読めない。CLAUDE.md「Sandboxing」)。許可が無ければファイルブラウザ側が「アクセスを許可…」を出す。
@MainActor
enum FileBrowserReveal {
    /// 出す場所。
    enum Placement: Equatable {
        /// このウインドウのウェルカム画面をファイルブラウザにする。
        case thisWindow
        /// 新しいタブ/ウインドウのファイルブラウザ。
        case newWindow(BookOpenDestination)
    }

    /// 見せるもの。
    struct Target: Equatable {
        /// 表示するフォルダ(nil はコンピュータ ―― ボリュームのルートにあるファイルは無いので、実際にはボリュームそのものを
        /// 示したときだけ)。
        let folder: URL?
        /// 選ぶ項目(フォルダの中を見せるときは nil)。
        let selecting: URL?
    }

    static func placement(hasOpenBook: Bool, preference: FileBrowserRevealDestination) -> Placement {
        hasOpenBook ? .newWindow(preference.bookOpenDestination) : .thisWindow
    }

    nonisolated static func target(for url: URL, isDirectory: Bool) -> Target {
        if isDirectory {
            return Target(folder: FileBrowserState.folderURL(url), selecting: nil)
        }
        return Target(folder: FileBrowserState.parent(of: url), selecting: url)
    }

    /// フォルダかどうか。スコープ付きで解決された URL ならここで開いてから調べる(FinderReveal.reveal と同じ)。
    /// 見つからなければ nil。
    nonisolated static func isDirectory(at url: URL) async -> Bool? {
        await FileIO.perform {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
            return isDirectory.boolValue
        }
    }
}

extension AppState {
    /// 「ファイルブラウザで開く」。型コメントは FileBrowserReveal。
    ///
    /// - Parameter isDirectory: フォルダかどうかが分かっていれば渡す(履歴の項目など、スコープの付かない URL のとき)。
    /// - Parameter openWindow: 新しいタブ/ウインドウを開く口。**AppState に持たせない**: SwiftUI の中身を抱えうる値を
    ///   AppState(ContentView の `@StateObject`)が持つと、閉じたウインドウとの循環になりうる(CLAUDE.md の ViewerActionRelay の件)。
    func revealInFileBrowser(_ url: URL, isDirectory: Bool? = nil, openWindow: OpenWindowAction) {
        Task { [weak self] in
            let resolved: Bool?
            if let isDirectory {
                resolved = isDirectory
            } else {
                resolved = await FileBrowserReveal.isDirectory(at: url)
            }
            guard let self else { return }
            guard let resolved else {
                // 本が移動・削除された(Finder で開くも同じ場面では何も起きない)。
                NSSound.beep()
                return
            }
            self.showInFileBrowser(url, isDirectory: resolved, openWindow: openWindow)
        }
    }

    /// 開いている本(ファイルメニュー・ビューアの右クリック)。
    func revealCurrentBookInFileBrowser(openWindow: OpenWindowAction) {
        guard let url = currentBook?.sourceURL else { return }
        revealInFileBrowser(url, openWindow: openWindow)
    }

    /// フォルダかどうかが決まった後半(テストはここを直に呼ぶ。`OpenWindowAction` はテストで作れないので nil を許す)。
    func showInFileBrowser(_ url: URL, isDirectory: Bool, openWindow: OpenWindowAction?) {
        // ファイルブラウザ機能がOFFなら何もしない(入り口の項目は出していない。RevealInFileBrowserAction.isFeatureEnabled)。
        guard preferences?.fileBrowserFeatureEnabled ?? true else { return }
        let placement = FileBrowserReveal.placement(
            hasOpenBook: currentBook != nil,
            preference: preferences?.fileBrowserRevealDestination ?? .newTab
        )
        switch placement {
        case .thisWindow:
            guard let fileBrowser, let welcomeLibrary else { return }
            welcomeLibrary.endEditing()
            welcomeLibrary.mode = .browser
            fileBrowser.show(url, isDirectory: isDirectory)
        case .newWindow(let destination):
            guard let openWindow else { return }
            let target = FileBrowserReveal.target(for: url, isDirectory: isDirectory)
            // コンピュータ(ボリュームの一覧)を新しいウインドウで出す要求は作れない(`browse` はフォルダを持つ)。
            // ボリュームのルートを示したときは、そのボリュームの中を見せる。
            let folder = target.folder ?? FileBrowserState.folderURL(url)
            BookWindowOpener.openFolder(
                folder, selecting: target.folder == nil ? nil : target.selecting,
                to: destination, from: self, openWindow: openWindow
            )
        }
    }
}

/// 「ファイルブラウザで開く」をビューの右クリックメニューから呼ぶための口。ContentView がウインドウの中身全体に入れる。
///
/// ■ なぜ環境値か
/// 「Finder で開く」の隣の 9 箇所は、サイドパネルの奥の部品やページ一覧のセルにまで散っていて、閉包を引数で配ると
/// 経路が増えるだけになる。**AppState は weak で持つ**: メニュー項目の閉包は AppKit の側に渡ってウインドウより長生きしうる
/// (CLAUDE.md の ViewerActionRelay の件)ので、ここが AppState を強く掴むと閉じたウインドウが残る。
struct RevealInFileBrowserAction {
    weak var appState: AppState?
    var openWindow: OpenWindowAction?
    /// 環境設定「ファイルブラウザを有効にする」。false の間、呼び出し側は「ファイルブラウザで開く」の項目を**出さない**
    /// (淡色で残さない ―― 機能そのものが無い。2026-09-21)。
    var isFeatureEnabled = true

    /// 呼べる相手がいるか(ContentView の外 ―― 補助ウインドウ ―― では無い)。
    var isAvailable: Bool { appState != nil }

    @MainActor
    func callAsFunction(_ url: URL, isDirectory: Bool? = nil) {
        guard let openWindow else { return }
        appState?.revealInFileBrowser(url, isDirectory: isDirectory, openWindow: openWindow)
    }
}

extension EnvironmentValues {
    @Entry var revealInFileBrowser = RevealInFileBrowserAction()
}
