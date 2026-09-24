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
    /// 保存先。**テストのための口**で、既定はこれまでどおり`.standard`(AppPreferences.
    /// init(defaults:)・KeyBindingStore.init(defaults:)と同じ作法)。テストは実物のアプリと
    /// 同じコンテナで走るため、利用者の記憶しているフォルダを書き換えてはいけない。
    private let defaults: UserDefaults

    /// 表示用のパスを保存するキー(lastFolderPath()参照)。ブックマークのキーから派生させて
    /// おくことで、用途を1つ足すたびに2つのキーを考えずに済む。
    private var pathDefaultsKey: String { defaultsKey + ".path" }
    /// フォルダを選ぶパネルを閉じた時点で見ていた場所のパス(`folderPanelStartDirectory(current:)`)。
    private var panelDirectoryDefaultsKey: String { defaultsKey + ".panelDirectory" }

    init(defaultsKey: String, defaults: UserDefaults = .standard) {
        self.defaultsKey = defaultsKey
        self.defaults = defaults
    }

    func lastFolder() -> URL? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        // パネルの最初の場所を決めるだけなので、繋がっていない共有へは繋ぎに行かない(BookmarkResolution)。
        return BookmarkResolution.resolve(data)
    }

    /// - Parameter panelDirectory: フォルダを選ぶパネルなら、閉じた時点で見ていた場所(`NSOpenPanel.directoryURL`)。
    ///   次に開くときの位置になる(`folderPanelStartDirectory(current:)`)。
    func remember(_ folderURL: URL, panelDirectory: URL? = nil) {
        guard let data = try? folderURL.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
        ) else { return }
        defaults.set(data, forKey: defaultsKey)
        // 表示用のパスも一緒に控える(lastFolderPath()のコメント参照)。
        defaults.set(folderURL.path, forKey: pathDefaultsKey)
        // 前の選択のときの場所を、新しい選択と組にして残さない。
        if let panelDirectory {
            defaults.set(panelDirectory.path, forKey: panelDirectoryDefaultsKey)
        } else {
            defaults.removeObject(forKey: panelDirectoryDefaultsKey)
        }
    }

    /// フォルダを選ぶパネル(`remember(_:panelDirectory:)` で覚えた用途)をどこから始めるか。
    ///
    /// 以前は覚えたフォルダそのものから始めていたので、FolderA の中で FolderB を選ぶと、次のパネルが FolderB の**中に入った状態**で
    /// 開いた(2026-09-17、ユーザー指摘)。よく使う項目の「＋」(FileBrowserActions.addFavoriteLocation)に揃えて、
    /// **前回パネルを閉じた時点で見ていた場所**から始める。FolderB の中まで入って何も選ばずに決めたなら FolderB の中から。
    ///
    /// - Parameter current: 呼び出し側がいま選ばれているとして持っているフォルダ(書き出しシートの保存先など)。前回このパネルで
    ///   選んだものと違えば(固定の保存先・別の経路で決まったもの)、その場所は前回のパネルと関係が無いので、その親から始める。
    /// - Returns: 覚えた場所が無い(この仕組みより前に選んだ)なら、覚えたフォルダの親。何も無ければ nil。
    ///
    /// 見ていた場所は**パスで**持つ: パネルは別のプロセスで動くので、開始位置に権限は要らない。親フォルダには権限が無いので、
    /// セキュリティスコープ付きのブックマークは作れない。
    func folderPanelStartDirectory(current: URL? = nil) -> URL? {
        let chosenPath = lastFolderPath()
        if let current, chosenPath.map({ Self.samePath($0, current.path) }) != true {
            return current.deletingLastPathComponent()
        }
        if let panelPath = defaults.string(forKey: panelDirectoryDefaultsKey) {
            return URL(fileURLWithPath: panelPath, isDirectory: true)
        }
        return (current ?? lastFolder())?.deletingLastPathComponent()
    }

    private static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).standardizedFileURL.path == URL(fileURLWithPath: rhs).standardizedFileURL.path
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
        defaults.string(forKey: pathDefaultsKey)
    }

    /// 記憶しているフォルダを忘れる(環境設定で「毎回確認」へ戻したときなど)。
    func forget() {
        defaults.removeObject(forKey: defaultsKey)
        defaults.removeObject(forKey: pathDefaultsKey)
        defaults.removeObject(forKey: panelDirectoryDefaultsKey)
    }

    /// 「初期設定に戻す」がこの記憶ごと消せるように、使っているキーを公開する
    /// (AppPreferences.keys(for:)参照)。
    var defaultsKeys: [String] { [defaultsKey, pathDefaultsKey, panelDirectoryDefaultsKey] }
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
