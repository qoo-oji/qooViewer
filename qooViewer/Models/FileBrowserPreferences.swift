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

extension FileBrowserStartupLocation: SettingsOption {
    var shortTitleKey: LocalizedStringKey {
        switch self {
        case .home: "Home"
        case .favorite: "Favorite Location"
        case .lastFolder: "Last Viewed Folder"
        }
    }
}
