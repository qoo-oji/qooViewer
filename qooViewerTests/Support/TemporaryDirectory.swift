import Foundation

/// テスト 1 つぶんの作業フォルダ。生成フィクスチャ(フォルダの本・zip・EPUB・PDF)の置き場。
///
/// `FileManager.default.temporaryDirectory` の下に UUID 付きで作り、手放したときに消す。
/// サンドボックスの中ではコンテナの `tmp/` になる(TemporaryFileStore と同じ場所だが、
/// あちらの `qooViewer-<pid>/` とは名前が重ならない)。
nonisolated final class TemporaryDirectory {
    let url: URL

    init(_ label: String = "fixture") throws {
        // フォルダの本の sortKey は絶対パスで、その値は `FileManager` の列挙が返す**実体の**
        // パスになる。期待値を組む側と食い違わないよう、置き場所を最初から実体にしておく。
        //
        // **`resolvingSymlinksInPath()` では足りない。** あれは symlink を解いた後で先頭の
        // `/private` を**外して**返す仕様(NSURL のドキュメントに明記がある)なので、
        // `/var/folders/…/T`(= `/private/var/folders/…/T` への symlink)はそのまま
        // `/var/…` で返ってくる。手元はサンドボックスの中でコンテナの `tmp/` が
        // `/Users/…/Library/Containers/…` と symlink を含まないため素通りしていたが、
        // サンドボックス無しで走る CI では `/var/…` と列挙結果の `/private/var/…` が
        // 食い違い、フォルダの本のテストが 2 件落ちた(2026-09-05、実測して確認)。
        // `canonicalPathKey` は `/private/var/…` を返すので、そちらを使う。
        let base = FileManager.default.temporaryDirectory
        let canonicalBase = (try? base.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? base.resolvingSymlinksInPath()
        url = canonicalBase.appendingPathComponent("qooViewerTests-\(label)-\(UUID().uuidString)", isDirectory: true)
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
