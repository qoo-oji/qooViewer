import Foundation

enum ArchiveReaderError: Error {
    case cannotOpen
    case entryNotFound
}

/// zip / 7z / rar など、圧縮ファイルの中身を読み出すための共通インターフェース。
/// 形式ごとの違いは各 Reader(ZipArchiveReader など)の内部に閉じ込め、
/// 呼び出し側はこのプロトコルだけを見ればよいようにする。
// nonisolated: Xcode 26 (Swift 6.2)からの新規プロジェクトは既定で「Default Actor Isolation = MainActor」
// になっており、注釈のない型・関数は暗黙的にMainActor専用になる。ここから下のプロトコル・関数は
// すべてPageLoader(actor、メインスレッド外)から呼ばれるため、明示的にnonisolatedを付けている。
protocol ArchiveReading {
    /// アーカイブ内の全ファイルパス一覧(ディレクトリ自体は含まない)
    nonisolated func listFilePaths() throws -> [String]
    /// 指定パスのファイルをDataとして取り出す
    nonisolated func data(at path: String) throws -> Data
}

/// 対応する画像の拡張子。AVIFはmacOS Sonoma(14)以降でImageIOがシステム全体で
/// デコードに対応している(本アプリの対象macOS 15以降ではすべて対応)ため含めている。
let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "bmp", "webp", "heic", "tif", "tiff", "avif"]

/// 対応する圧縮アーカイブの拡張子
let archiveExtensions: Set<String> = ["zip", "cbz", "rar", "cbr", "7z", "cb7"]

nonisolated func isImageFile(_ path: String) -> Bool {
    imageExtensions.contains((path as NSString).pathExtension.lowercased())
}

nonisolated func isArchiveFile(_ path: String) -> Bool {
    archiveExtensions.contains((path as NSString).pathExtension.lowercased())
}

/// PDFファイルかどうか。PDFは中身を展開するアーカイブではなく、1ファイルの中に複数ページを
/// 直接持つ形式のため、アーカイブ(archiveExtensions)とは別に扱う(BookLoader.loadPDF、
/// PageLoader.renderPDFPage参照)。
nonisolated func isPDFFile(_ path: String) -> Bool {
    (path as NSString).pathExtension.lowercased() == "pdf"
}

/// 拡張子を見て、適切な ArchiveReading の実装を返す
nonisolated func makeArchiveReader(for url: URL) throws -> ArchiveReading {
    switch url.pathExtension.lowercased() {
    case "zip", "cbz":
        return try ZipArchiveReader(url: url)
    case "7z", "cb7":
        return try SevenZipArchiveReader(url: url)
    case "rar", "cbr":
        return try RarArchiveReader(url: url)
    default:
        throw ArchiveReaderError.cannotOpen
    }
}

/// アーカイブの拡張子から、そのアーカイブ内エントリ用の PageSource を作る
nonisolated func pageSource(for archiveURL: URL, entryPath: String) -> PageSource {
    switch archiveURL.pathExtension.lowercased() {
    case "zip", "cbz":
        return .zip(archiveURL: archiveURL, entryPath: entryPath)
    case "7z", "cb7":
        return .sevenZip(archiveURL: archiveURL, entryPath: entryPath)
    default:
        return .rar(archiveURL: archiveURL, entryPath: entryPath)
    }
}
