import Foundation

/// 本を開いていないウインドウ・タブのタイトル(2026-09-14、ユーザー要望)。
///
/// 以前は本を開いていなければ一律「qooViewer」で、「ファイルブラウザで開く」で新規タブを何枚も開くと、どれがどのフォルダか
/// 見分けが付かなかった。いま画面の上の段に出ている名前をそのままタイトルにする(新しく見せる情報は増やさない):
///
/// | 表示 | タイトル |
/// |---|---|
/// | ファイルブラウザ | いまのフォルダの名前(Finder と同じ)。コンピュータなら「コンピュータ」、起動ディスクの `/` はボリューム名 |
/// | 本棚(コレクションの一覧) | ライブラリの名前 |
/// | コレクションの中 | コレクションの名前 |
///
/// シークレットの印は呼び出し側(ContentView.windowTitle)が付ける。
nonisolated enum WindowTitle {
    /// 起動ディスクの名前(ローカルなので一度だけ引いて覚える)。ファイルブラウザの上の段と共有する。
    static let startupVolumeName: String =
        (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? "/"

    /// ファイルブラウザのいまのフォルダの名前。名前はパスの綴りのまま(パスバーと同じ。`FileManager.displayName(atPath:)` は
    /// ファイルシステムに問い合わせ、ネットワークで止まりうるので使わない)。
    static func folderName(_ folder: URL?, computerTitle: String, startupVolumeName: String = startupVolumeName) -> String {
        guard let folder else { return computerTitle }
        return folder.path == "/" ? startupVolumeName : folder.lastPathComponent
    }

    /// 本を開いていないウインドウのタイトル。名前が引けない(ライブラリがまだ無い一瞬など)ときはアプリ名。
    static func welcome(
        mode: WelcomeMode, folderName: String, libraryName: String?, collectionName: String?,
        smartLibraryName: String? = nil
    ) -> String {
        switch mode {
        case .browser:
            return folderName
        case .smart:
            return smartLibraryName ?? String(localized: "Smart Library", language: AppLanguage.currentLocale)
        case .shelf:
            let name = collectionName ?? libraryName
            guard let name, !name.isEmpty else { return appName }
            return name
        case .classic:
            return appName
        }
    }

    static let appName = "qooViewer"
}
