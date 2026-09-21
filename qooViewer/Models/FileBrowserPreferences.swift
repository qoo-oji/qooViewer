import SwiftUI

/// ウェルカム画面の2つのモード(改善要望7 段階3、2026-09-13)。帯の左端のボタンで切り替える。
///
/// **ウインドウごと**(WelcomeLibraryState.mode)で、最後に選んだものを保存して次のウインドウの
/// 始まりにする ―― Finderの代わりに使う人はいつもファイルブラウザから始めたい。
nonisolated enum WelcomeMode: String, CaseIterable, Codable, Hashable, Sendable {
    /// ライブラリ・コレクションの本棚(改善要望5)。
    case shelf
    /// ファイルブラウザ。
    case browser
    /// 本棚を足す前のウェルカム画面(ClassicWelcomeView)。**選べるモードではない** ―― 環境設定でライブラリとファイルブラウザの
    /// 両方をOFFにしている間だけ、WelcomeLibraryState がこの値にする(保存もしない)。`mode == .shelf` / `.browser` を見ている
    /// 場所が、どちらも出ていないときに自然に偽になるように、独立した値にしてある。
    case classic
}

/// ファイルブラウザの右ペインの見せ方。
nonisolated enum FileBrowserViewMode: String, CaseIterable, Codable, Hashable, Sendable {
    /// 列のある一覧(NSTableView)。
    case list
    /// アイコンを並べたグリッド(SwiftUIのLazyVGrid)。
    case icons

    /// 空きスペースの右クリック「表示」のサブメニューの項目名。
    var menuTitle: String.LocalizationValue {
        switch self {
        case .list: "as List"
        case .icons: "as Icons"
        }
    }
}

/// ファイルブラウザを最初に開いたときに表示するフォルダ(環境設定「ファイルブラウザ」)。
///
/// 「よく使う項目」のどれかを選ぶときは、どれを選んだかは別の設定
/// (AppPreferences.fileBrowserStartupFavoriteID)に持つ。ここに id を含めないのは、
/// ポップアップの選択肢を3つに保つため(よく使う項目の数だけ選択肢が増えると、1つを消したときに
/// 選ばれていた値が行き場を失う)。
enum FileBrowserStartupLocation: String, CaseIterable, Identifiable, Hashable {
    /// 実際のホーム(サンドボックスのコンテナではない。FileBrowserListing.realHomeDirectory)。
    case home
    /// よく使う項目のうち1つ。登録が無くなっていればホームへ読み替える。
    case favorite
    /// 最後に表示したフォルダ。まだ無ければホーム。
    case lastFolder

    var id: String { rawValue }
}

/// 他のアプリ(Finder など)からファイルブラウザへ項目をドロップしたときにすること
/// (環境設定「ファイルブラウザ」。改善要望7 段階4b、2026-09-13)。
///
/// **既定は「ビューアで開く」**: ファイルブラウザが入る前から、ウインドウへのドロップは本を開く操作だった
/// (ContentView.applyFileDropTarget)。ファイルブラウザを出しているときだけ黙ってコピーに変わると、
/// 本を開くつもりで落とした人の書庫が今のフォルダに複製される。アプリの中からのドラッグには効かない
/// (そちらは常にコピー・移動)。
enum FileBrowserExternalDropAction: String, CaseIterable, Identifiable, Hashable {
    /// 落とされたものを本として開く(ウインドウのほかの場所へ落としたときと同じ)。
    case openInViewer
    /// 落とした場所へコピー・移動する(Finder と同じ規則。FileDropPlan)。
    case copyOrMove

    var id: String { rawValue }
}

/// ファイルブラウザの右ペイン(リスト・アイコン)で、画像フォルダ(それ自体が1冊の本。`ShelfFolderResolver.role` が
/// `.book` と答えるフォルダ)をダブルクリック / Return(⌘↓ も)で開いたときにすること(環境設定「ファイルブラウザ」。
/// 2026-09-14、ユーザー要望)。本でないフォルダはこの設定に関わらず中へ移動し、左のツリーにも効かない。
///
/// **既定は「フォルダを開く」**: 段階 3 からの決まり(Finder の代わりに使うとき、フォルダの中を見られないと困る)を変えない。
/// **右クリックの「開く」は常にこの反対をする** ―― どちらを選んでも、もう片方の開き方が右ペインから手の届く所に残る
/// (`opensAsBook(fromMenu:)`)。
enum FileBrowserImageFolderOpenAction: String, CaseIterable, Identifiable, Hashable {
    /// 中へ移動する(ほかのフォルダと同じ)。
    case openFolder
    /// 本としてビューアで開く。
    case openInViewer

    var id: String { rawValue }

    /// 画像フォルダを本として開くか。`fromMenu` は右クリックの「開く」(ダブルクリックと反対になる)。
    func opensAsBook(fromMenu: Bool) -> Bool {
        (self == .openInViewer) != fromMenu
    }
}

/// ファイルブラウザの「圧縮」で作る書庫の拡張子(環境設定「ファイルブラウザ」。段階 6、2026-09-14)。
/// 中身はどちらも同じ zip。cbz にしておくと、qooViewer やほかの漫画ビューアが本として扱う。
enum FileBrowserCompressionFormat: String, CaseIterable, Identifiable, Hashable {
    case zip
    case cbz

    var id: String { rawValue }
    var fileExtension: String { rawValue }
}

/// 本を表示しているウインドウで「ファイルブラウザで開く」を選んだときの行き先(環境設定「ファイルブラウザ」。
/// 決定事項 Q6、段階 8、2026-09-14)。本を開いていないウインドウでは、この設定に関わらずそのウインドウの
/// ウェルカム画面がファイルブラウザに切り替わる(FileBrowserReveal.placement)。
///
/// **既定は新規タブ**: 「Finder で開く」と同じく、いま読んでいる本の画面を壊さない(検討メモ §11 Q6 の推奨)。
enum FileBrowserRevealDestination: String, CaseIterable, Identifiable, Hashable {
    case newTab
    case newNormalWindow
    case newPrivateWindow

    var id: String { rawValue }

    /// 新しいタブ/ウインドウの開き方(BookWindowOpener の行き先)。
    var bookOpenDestination: BookOpenDestination {
        switch self {
        case .newTab: .newTab
        case .newNormalWindow: .newNormalWindow
        case .newPrivateWindow: .newPrivateWindow
        }
    }
}

extension FileBrowserRevealDestination: SettingsOption {
    var shortTitleKey: LocalizedStringKey {
        switch self {
        case .newTab: "New Tab"
        case .newNormalWindow: "New Normal Window"
        case .newPrivateWindow: "New Private Window"
        }
    }
}

extension FileBrowserCompressionFormat: SettingsOption {
    var shortTitleKey: LocalizedStringKey {
        switch self {
        case .zip: "ZIP (.zip)"
        case .cbz: "Comic Book ZIP (.cbz)"
        }
    }
}

extension FileBrowserExternalDropAction: SettingsOption {
    var shortTitleKey: LocalizedStringKey {
        switch self {
        case .openInViewer: "Open in Viewer"
        case .copyOrMove: "Copy or Move"
        }
    }
}

extension FileBrowserImageFolderOpenAction: SettingsOption {
    var shortTitleKey: LocalizedStringKey {
        switch self {
        case .openFolder: "Open Folder"
        case .openInViewer: "Open in Viewer"
        }
    }
}

extension FileBrowserStartupLocation: SettingsOption {
    var shortTitleKey: LocalizedStringKey {
        switch self {
        case .home: "Home Folder"
        case .favorite: "Favorite Location"
        case .lastFolder: "Last Viewed Folder"
        }
    }
}
