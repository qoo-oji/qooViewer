import Foundation

/// テスト 1 つぶんの作業フォルダ。生成フィクスチャ(フォルダの本・zip・EPUB・PDF)の置き場。
///
/// `FileManager.default.temporaryDirectory` の下に UUID 付きで作り、手放したときに消す。
/// サンドボックスの中ではコンテナの `tmp/` になる(TemporaryFileStore と同じ場所だが、
/// あちらの `qooViewer-<pid>/` とは名前が重ならない)。
nonisolated final class TemporaryDirectory {
    let url: URL

    init(_ label: String = "fixture") throws {
        // `temporaryDirectory` は `/var/...`(シンボリックリンク)で、FileManager の列挙は実体の
        // `/private/var/...` を返す。フォルダの本の sortKey は絶対パスなので、期待値を組む側と
        // 同じ形になるよう、最初から実体のパスにしておく。
        url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("qooViewerTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// 作業フォルダの中のパス(作りはしない)。
    func file(_ relativePath: String) -> URL {
        url.appendingPathComponent(relativePath)
    }

    /// 作業フォルダの中にサブフォルダを作って返す。
    @discardableResult
    func directory(_ relativePath: String) throws -> URL {
        let directory = url.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
