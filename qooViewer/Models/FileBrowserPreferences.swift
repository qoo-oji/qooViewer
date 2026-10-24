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
    /// スマートライブラリ(2026-09-21。条件で本を集める。SmartLibraryPane)。環境設定「スマートライブラリを有効にする」が ON のときだけ選べる。
    case smart
    /// 本棚を足す前のウェルカム画面(ClassicWelcomeView)。**選べるモードではない** ―― 環境設定でライブラリ・ファイルブラウザ・スマートライブラリの
    /// すべてをOFFにしている間だけ、WelcomeLibraryState がこの値にする(保存もしない)。`mode == .shelf` / `.browser` を見ている
    /// 場所が、どちらも出ていないときに自然に偽になるように、独立した値にしてある。
    case classic
}

/// ファイルブラウザの右ペインの見せ方。
///
/// **並びはアイコン → リスト**(Finder と同じ。2026-09-27 ―― それまではリスト → アイコンで、スマートライブラリの操作列と
/// 逆だった)。`allCases` の順が表示メニュー・空きスペースの右クリック「表示」の並びになる。
nonisolated enum FileBrowserViewMode: String, CaseIterable, Codable, Hashable, Sendable {
    /// アイコンを並べたグリッド(AppKit の NSCollectionView)。
    case icons
    /// 列のある一覧(NSTableView)。
    case list

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

/// ファイルブラウザの右ペイン(リスト・アイコン)で、画像フォルダ(**直下に画像があるフォルダ**。規則 1 ――
/// `DirectoryBrowser.directlyContainsImageFile`)をダブルクリック / Return(⌘↓ も)で開いたときにすること(環境設定「ファイルブラウザ」。
/// 2026-09-14、ユーザー要望)。直下に画像の無いフォルダ・ボリューム・マウントポイントはこの設定に関わらず中へ移動する。
/// 左のツリーの行の Return もこれに従う(`FileBrowserActions.openTreeRow`)。
///
/// **既定は「フォルダを開く」**: 段階 3 からの決まり(Finder の代わりに使うとき、フォルダの中を見られないと困る)を変えない。
///
/// **右クリックの「開く」「新規タブ/ウインドウで開く」はこの設定に関係なく常にファイルブラウザで開き、⌥ を押している間だけ
/// 「本として開く」系に入れ替わる**(2026-10-24、ユーザー決定)。それまでは右クリックの「開く」がこの設定の反対をし、新規タブ/ウインドウは
/// 規則 1・2(章ごとに画像フォルダを分けた本 ―― `ShelfFolderResolver.isSingleBookFolder`)で調べてから本として開いていたので、
/// 根に画像入りのフォルダが 1 つあり書庫が直下に無いだけのボリュームが、「新規タブで開く」で 1 冊の本として開いた(ユーザー報告)。
/// 判定もこのとき規則 1 だけにした(ツリーの Return・サイドパネルと同じ)。
enum FileBrowserImageFolderOpenAction: String, CaseIterable, Identifiable, Hashable {
    /// 中へ移動する(ほかのフォルダと同じ)。
    case openFolder
    /// 本としてビューアで開く。
    case openInViewer

    var id: String { rawValue }

    /// 画像フォルダを本として開くか(ダブルクリック / Return)。
    var opensAsBook: Bool { self == .openInViewer }
}

/// ファイルブラウザで画像ファイルを 1 つ開いたとき(ダブルクリック・Return・⌘↓・右クリックの「開く」「新規タブ/ウインドウで開く」・
/// メニューバーの「開く」。リンクの先が画像でも)に開くもの(環境設定「ファイルブラウザ」。2026-10-24、ユーザー決定)。
///
/// **既定は「フォルダ全体を本として」**: 右クリックの「開く」が常にフォルダを開くようになったので(`FileBrowserImageFolderOpenAction`)、
/// ⌥ を知らない人でも、画像フォルダに入って画像を開けば本として読めるように。1 枚だけで開きたい人はこの設定で戻せる。
/// 複数の画像を選んで開いたときは設定に関係なく、それらだけを 1 冊にまとめる(BookOpenRequest(openingCandidates:))。
/// フォルダにしない場合は `FileBrowserImageFileOpening.target` のコメント。
enum FileBrowserImageFileOpenAction: String, CaseIterable, Identifiable, Hashable {
    /// その画像 1 枚だけの本(その場限りの本。何も記録しない ―― MangaBook.BookOrigin.imageFiles)。
    case onlyThatImage
    /// その画像が入っているフォルダを、その画像のページから本として開く(メニューの「このフォルダの画像をすべて開く」と同じ本)。
    case wholeFolder

    var id: String { rawValue }
}

/// ファイルブラウザで画像ファイルを 1 つ開いたときに、実際に開くもの(`FileBrowserImageFileOpenAction`)。
nonisolated enum FileBrowserImageFileOpening {
    enum Target: Equatable, Sendable {
        /// その画像だけ。
        case image(URL)
        /// フォルダを本として、そのページ(`PageRef.id` = 画像のパス)から。
        case folder(URL, landingOn: URL)
    }

    /// 設定が「フォルダ全体を本として」でも、次のときは画像だけで開く(ファイルに触らない。マウント表とパスの文字列と許可の控えだけ):
    /// - 画像がボリュームの根(マウントポイントの直下)にある ―― ボリュームを 1 冊の本として読ませない(新規タブで開くの件と同じ決まり)
    /// - 画像がホーム・その標準のフォルダ(デスクトップ・書類・ダウンロード・ピクチャ…)・`/Users` などの直下にある
    ///   (`FileOperationService.isProtectedLocation`)―― フォルダの本はサブフォルダまで集めるので、ホームなら `~/Library` まで、
    ///   デスクトップ・書類なら中の TCC の保護下の場所まで降りて、許可のダイアログを出しうる(2026-10-24 のコードレビュー)
    /// - 隠しファイル(名前が `.` で始まる。「隠しファイルを表示」の間だけ一覧に出る)―― フォルダの本は隠しファイルを読まない
    ///   (`BookLoader` の `.skipsHiddenFiles`)ので、その画像に着地できない
    /// - そのフォルダを読む許可(`FolderAccessStore`)が無い ―― 開いても 1 枚も見つからず「対応する画像が見つかりません」になる。
    ///   許可のパネルは出さない(「このフォルダの画像をすべて開く」は出すが、あちらは利用者がフォルダ全体を名指しした操作)
    static func target(
        for image: URL, action: FileBrowserImageFileOpenAction, mounts: MountTable, isFolderAccessible: (URL) -> Bool
    ) -> Target {
        guard action == .wholeFolder, !image.lastPathComponent.hasPrefix(".") else { return .image(image) }
        let folder = image.deletingLastPathComponent()
        guard !mounts.isMounted(folder.path), !FileOperationService.isProtectedLocation(folder),
              isFolderAccessible(folder)
        else { return .image(image) }
        return .folder(folder, landingOn: image)
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

extension FileBrowserImageFileOpenAction: SettingsOption {
    var shortTitleKey: LocalizedStringKey {
        switch self {
        case .onlyThatImage: "Only That Image"
        case .wholeFolder: "Whole Folder as a Book"
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
