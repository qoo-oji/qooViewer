import Foundation

/// フォルダの本(画像ファイルが並んだフォルダ)を作る。
///
/// フォルダの本はコミットせず毎回作る。git はファイル名の正規化(NFC/NFD)や隠しファイルの扱いを
/// 環境に委ねるため、名前そのものを試すフィクスチャはリポジトリに置くと崩れうる。
nonisolated enum FixtureFolder {
    struct Page {
        let relativePath: String
        let number: UInt8
        var wide = false

        init(_ relativePath: String, number: UInt8, wide: Bool = false) {
            self.relativePath = relativePath
            self.number = number
            self.wide = wide
        }
    }

    /// `directory` を作り、ページ画像を置く。形式は拡張子で決まる(PageImageFactory)。
    @discardableResult
    static func make(at directory: URL, pages: [Page], extraFiles: [String: String] = [:]) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for page in pages {
            let url = directory.appendingPathComponent(page.relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = PageImageFactory.data(number: page.number, wide: page.wide, fileExtension: url.pathExtension)
            try data.write(to: url)
        }
        for (relativePath, text) in extraFiles {
            let url = directory.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: url)
        }
        return directory
    }
}
