import Foundation

/// フォルダ選択パネル(NSOpenPanel、canChooseDirectories = true)が最後に開いたフォルダを、
/// セキュリティスコープ付きブックマークとしてUserDefaultsへ記憶する小さな仕組み。
///
/// AppPreferencesは既存のUserDefaultsキー(単純なBool/Double/enum rawValueのみ)のパターンに
/// 合わせているため、ブックマーク(Data)を保存するこの用途はあえて専用の仕組みとして分離して
/// いる(その判断自体は従来通り)。
///
/// 経緯: 以前は用途ごと(JSON入出力・EPUB出力先・PDF出力先)に、UserDefaultsキーだけが違う
/// 同じ実装のenumを3つコピーして持っていた(LibraryIOFolderMemory / EpubExportFolderMemory /
/// PDFExportFolderMemory)。用途ごとにキーを分けたい、という要件はキーを引数に取るだけで
/// 満たせるため、実装は1つにまとめて、用途ごとの違いはstaticなインスタンスとして表す。
struct LastUsedFolderMemory {
    private let defaultsKey: String

    /// 表示用のパスを保存するキー(lastFolderPath()参照)。ブックマークのキーから派生させて
    /// おくことで、用途を1つ足すたびに2つのキーを考えずに済む。
    private var pathDefaultsKey: String { defaultsKey + ".path" }

    init(defaultsKey: String) {
        self.defaultsKey = defaultsKey
    }

    func lastFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        var isStale = false
        return try? URL(
            resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale
        )
    }

    func remember(_ folderURL: URL) {
        guard let data = try? folderURL.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
        ) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
        // 表示用のパスも一緒に控える(lastFolderPath()のコメント参照)。
        UserDefaults.standard.set(folderURL.path, forKey: pathDefaultsKey)
    }

    /// 記憶しているフォルダのパス(**表示専用**)。
    ///
    /// ブックマークの解決(`lastFolder()`)は、対象が未接続の外付け/ネットワークボリュームを
    /// 指しているとボリュームの探索を試みて秒単位でブロックしうる。環境設定の画面に
    /// 「いまどのフォルダが設定されているか」を出すだけのために、その解決を走らせたくない
    /// (RecentFilesStore.Entry.pathと同じ考え方)。
    ///
    /// ここで返るのは`remember(_:)`した時点のパスなので、フォルダが後から移動・改名されていると
    /// 実際の場所とずれる。**このパスを使ってフォルダを開いてはいけない**(サンドボックス下では
    /// アクセス権も無い)。実際に書き出すときは必ず`lastFolder()`でブックマークを解決すること。
    func lastFolderPath() -> String? {
        UserDefaults.standard.string(forKey: pathDefaultsKey)
    }

    /// 記憶しているフォルダを忘れる(環境設定で「毎回確認」へ戻したときなど)。
    func forget() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        UserDefaults.standard.removeObject(forKey: pathDefaultsKey)
    }

    /// 「初期設定に戻す」がこの記憶ごと消せるように、使っているキーを公開する
    /// (AppPreferences.keys(for:)参照)。
    var defaultsKeys: [String] { [defaultsKey, pathDefaultsKey] }
}

extension LastUsedFolderMemory {
    /// エクスポート/インポート(JSON)のファイル選択パネル用。
    static let libraryIO = LastUsedFolderMemory(defaultsKey: "qooViewer.pref.lastLibraryIOFolderBookmark")
    /// EPUB出力先フォルダパネル用(7.3節)。
    static let epubExport = LastUsedFolderMemory(defaultsKey: "qooViewer.pref.lastEpubExportFolderBookmark")
    /// PDF出力先フォルダパネル用。
    static let pdfExport = LastUsedFolderMemory(defaultsKey: "qooViewer.pref.lastPdfExportFolderBookmark")
    /// CBZ出力先フォルダパネル用。
    static let cbzExport = LastUsedFolderMemory(defaultsKey: "qooViewer.pref.lastCbzExportFolderBookmark")

    // MARK: - 固定の保存先(環境設定「レイアウト」)

    /// 環境設定「レイアウト」で「固定の保存先」を選んだときの保存先フォルダ
    /// (ユーザー要望: 以降その形式で書き出すときは毎回このフォルダへ書き出す)。
    ///
    /// 上の3つ(パネルが最後に開いたフォルダ)とは**別のキー**にしてある。あちらは
    /// 「次にパネルを開いたときの初期位置」でしかなく、ユーザーが別のフォルダを選べば
    /// 黙って上書きされる。固定の保存先は明示的に設定したものなので、パネルの操作で
    /// 変わってしまってはいけない。
    static func fixedExportFolder(_ format: BookExportFormat) -> LastUsedFolderMemory {
        LastUsedFolderMemory(defaultsKey: "qooViewer.pref.fixedExportFolderBookmark.\(format.rawValue)")
    }
}
