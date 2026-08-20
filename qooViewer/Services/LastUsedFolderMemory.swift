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
    }
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
}
